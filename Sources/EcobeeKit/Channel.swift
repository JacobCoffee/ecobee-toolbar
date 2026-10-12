import Foundation
import Network

/// Splits a byte stream into newline-terminated records.
public struct LineFramer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }
}

/// Newline-delimited JSON over a local socket. All callbacks run on the main queue.
@MainActor
public final class MessageChannel<Incoming: Decodable, Outgoing: Encodable> {
    public var onReady: (() -> Void)?
    public var onMessage: ((Incoming) -> Void)?
    /// Called once, when the connection fails or closes.
    public var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private var framer = LineFramer()
    private var closed = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    /// Client side: connect to a listening Unix socket.
    public convenience init(path: String) {
        self.init(connection: NWConnection(to: .unix(path: path), using: .tcp))
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onReady?()
                case let .failed(error), let .waiting(error): self?.finish(error)
                case .cancelled: self?.finish(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    public func send(_ message: Outgoing) {
        guard !closed, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish(error) }
        })
    }

    public func close() {
        finish(nil)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                for line in self.framer.append(data ?? Data()) {
                    if let message = try? JSONDecoder().decode(Incoming.self, from: line) {
                        self.onMessage?(message)
                    }
                }
                if let error {
                    self.finish(error)
                } else if isComplete {
                    self.finish(nil)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
        onClose = nil
        onMessage = nil
    }
}

/// Listens on a Unix socket and hands each client to `onConnection`.
@MainActor
public final class MessageServer<Incoming: Decodable, Outgoing: Encodable> {
    public var onConnection: ((MessageChannel<Incoming, Outgoing>) -> Void)?
    private let listener: NWListener

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)  // stale socket from a previous run
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                let channel = MessageChannel<Incoming, Outgoing>(connection: connection)
                self.onConnection?(channel)
                channel.start()
            }
        }
        listener.start(queue: .main)
    }

    public func cancel() {
        listener.cancel()
    }
}
