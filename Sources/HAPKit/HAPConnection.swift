import Foundation
import Network

/// One TCP connection to a HAP accessory. Plaintext until `pairVerify`
/// succeeds, then every byte is framed with `SessionCrypto`. Requests are
/// serialized (one in flight); EVENT/1.0 notifications go to `events`.
public actor HAPConnection {
    public nonisolated let events: AsyncStream<[CharacteristicValue]>
    private let eventsContinuation: AsyncStream<[CharacteristicValue]>.Continuation
    public nonisolated let closed: AsyncStream<Error?>
    private let closedContinuation: AsyncStream<Error?>.Continuation

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "hap.connection")
    private var parser = HTTPParser()
    private var encryptedBuffer = Data()
    private var crypto: SessionCrypto?
    private var pending: CheckedContinuation<HTTPMessage, Error>?
    private var pendingID = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    public private(set) var isEncrypted = false

    public init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 8
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        (events, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (closed, closedContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public static func connect(to endpoint: NWEndpoint, timeout: Duration = .seconds(8)) async throws -> HAPConnection {
        let conn = HAPConnection(endpoint: endpoint)
        try await conn.start(timeout: timeout)
        return conn
    }

    /// The resolved remote address, once connected.
    public var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    private func start(timeout: Duration) async throws {
        let once = OnceFlag()
        let connection = connection
        let queue = queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if once.fire() { cont.resume() }
                    case let .failed(error):
                        if once.fire() { cont.resume(throwing: error) }
                        Task { await self?.shutdown(error) }
                    case let .waiting(error):
                        if once.fire() { cont.resume(throwing: error) }
                        Task { await self?.shutdown(error) }
                    case .cancelled:
                        if once.fire() { cont.resume(throwing: CancellationError()) }
                        Task { await self?.shutdown(nil) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                Task {
                    try? await Task.sleep(for: timeout)
                    if once.fire() {
                        cont.resume(throwing: HAPError.timeout)
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        receiveLoop()
    }

    public func close() {
        connection.cancel()
        shutdown(nil)
    }

    private func shutdown(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        pending?.resume(throwing: error ?? HAPError.connectionClosed)
        pending = nil
        eventsContinuation.finish()
        closedContinuation.yield(error)
        closedContinuation.finish()
        connection.cancel()
    }

    private nonisolated func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !isClosed else { return }
        if let data, !data.isEmpty {
            do {
                if crypto != nil {
                    encryptedBuffer += data
                    parser.append(try crypto!.open(&encryptedBuffer))
                } else {
                    parser.append(data)
                }
                while let message = try parser.next() {
                    dispatch(message)
                }
            } catch {
                shutdown(error)
                return
            }
        }
        if let error {
            shutdown(error)
        } else if isComplete {
            shutdown(HAPError.connectionClosed)
        } else {
            receiveLoop()
        }
    }

    private func dispatch(_ message: HTTPMessage) {
        if message.isEvent {
            if let values = try? JSONDecoder().decode(CharacteristicsBody.self, from: message.body) {
                eventsContinuation.yield(values.characteristics)
            }
            return
        }
        pending?.resume(returning: message)
        pending = nil
    }

    // MARK: Requests

    public func request(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
                        timeout: Duration = .seconds(10)) async throws -> HTTPMessage {
        await acquire()
        defer { release() }
        guard !isClosed else { throw HAPError.connectionClosed }
        let raw = HTTPRequest.encode(method: method, path: path, body: body, contentType: contentType)
        let wire = crypto != nil ? crypto!.seal(raw) : raw
        pendingID += 1
        let id = pendingID
        return try await withCheckedThrowingContinuation { cont in
            pending = cont
            connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.shutdown(error) }
            })
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        guard id == pendingID, pending != nil else { return }
        shutdown(HAPError.timeout)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func postTLV(_ path: String, _ tlv: TLV8) async throws -> TLV8 {
        let response = try await request("POST", path, body: tlv.encoded(), contentType: "application/pairing+tlv8")
        guard response.status == 200 else { throw HAPError.http(status: response.status) }
        return try TLV8.decode(response.body)
    }

    /// Switch to the encrypted transport. Called by pair-verify between requests.
    func enableEncryption(sharedSecret: Data) {
        crypto = SessionCrypto(sharedSecret: sharedSecret)
        isEncrypted = true
    }
}

/// Thread-safe one-shot latch for resuming a continuation exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
