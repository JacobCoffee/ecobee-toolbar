import Foundation
import HAPKit

/// Keeps a verified HAP session to one thermostat alive: connects, maps
/// characteristics, subscribes to events, polls as a safety net, and
/// reconnects with backoff. Emits a fresh `Update` on every change.
public actor ThermostatClient {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        case failed(String)
    }

    public struct Update: Sendable {
        public let status: Status
        public let state: ThermostatState?
    }

    public nonisolated let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private let pairing: Pairing
    private let onAddress: @Sendable (String, Int) -> Void
    private let pollInterval: Duration

    private var connection: HAPConnection?
    private var map: ThermostatMap?
    private var values: [CharacteristicID: HAPValue] = [:]
    private var status: Status = .connecting
    private var runTask: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?

    public init(pairing: Pairing, pollInterval: Duration = .seconds(60),
                onAddress: @escaping @Sendable (String, Int) -> Void = { _, _ in }) {
        self.pairing = pairing
        self.pollInterval = pollInterval
        self.onAddress = onAddress
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        wake?.resume()
        wake = nil
        await connection?.close()
        connection = nil
        continuation.finish()
    }

    /// Drop the current connection (if any) and reconnect immediately,
    /// e.g. after the Mac wakes from sleep.
    public func reconnect() async {
        if let connection {
            await connection.close()
        } else {
            wake?.resume()
            wake = nil
        }
    }

    // MARK: Commands

    public func write(_ field: ThermostatMap.Field, _ value: HAPValue) async throws {
        try await write([field: value])
    }

    public func write(_ fields: [ThermostatMap.Field: HAPValue]) async throws {
        guard let connection, let map else { throw HAPError.notConnected }
        var payload: [CharacteristicID: HAPValue] = [:]
        for (field, value) in fields {
            guard let id = map.ids[field] else { throw HAPError.unsupported(field.rawValue) }
            payload[id] = value
        }
        try await connection.write(payload)
        // HAP does not echo events to the controller that made the change.
        for (field, value) in fields {
            let target: ThermostatMap.Field = field == .comfortWrite ? .comfortRead : field
            if let id = map.ids[target] { values[id] = value }
        }
        emit()
    }

    public func setTemperature(_ field: ThermostatMap.Field, celsius: Double) async throws {
        guard let map else { throw HAPError.notConnected }
        let state = ThermostatState(map: map, values: values)
        let range = state.range(field)
        let stepped = (celsius / range.stepC).rounded() * range.stepC
        let clamped = min(max(stepped, range.minC), range.maxC)
        try await write(field, .double((clamped * 1000).rounded() / 1000))
    }

    public func setMode(_ mode: HVACMode) async throws { try await write(.targetMode, .int(mode.rawValue)) }
    public func setFan(auto: Bool) async throws { try await write(.targetFan, .int(auto ? 1 : 0)) }
    public func setComfort(_ comfort: Comfort) async throws { try await write(.comfortWrite, .int(comfort.rawValue)) }
    public func setDisplayUnits(fahrenheit: Bool) async throws { try await write(.displayUnits, .int(fahrenheit ? 1 : 0)) }

    /// Remove our pairing from the thermostat so it can be paired elsewhere.
    public func unpair() async throws {
        guard let connection else { throw HAPError.notConnected }
        try await connection.removePairing(pairing)
    }

    // MARK: Lifecycle

    private func emit() {
        continuation.yield(Update(status: status, state: map.map { ThermostatState(map: $0, values: values) }))
    }

    private func run() async {
        var backoff = 1.0
        while !Task.isCancelled {
            status = .connecting
            emit()
            do {
                let conn = try await HAPSession.open(pairing)
                connection = conn
                if let (ip, port) = await HAPSession.address(of: conn) { onAddress(ip, port) }
                let db = try await conn.accessories()
                guard let newMap = ThermostatMap(db) else { throw HAPError.unsupported("no Thermostat service") }
                map = newMap
                values = Self.initialValues(db)
                try await conn.subscribe(newMap.readableIDs.filter(newMap.notifiable.contains))
                status = .connected
                emit()
                backoff = 1

                let poller = Task { [pollInterval] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollInterval)
                        if Task.isCancelled { return }
                        await self.poll()
                    }
                }
                for await batch in conn.events {
                    for item in batch { if let v = item.value { values[item.id] = v } }
                    emit()
                }
                poller.cancel()
                connection = nil
                if Task.isCancelled { return }
                status = .failed("Connection lost")
                emit()
                await sleep(seconds: 1)
                continue  // established session dropped: reconnect without backoff
            } catch {
                await connection?.close()
                connection = nil
                status = .failed(error.localizedDescription)
                emit()
            }
            await sleep(seconds: backoff)
            backoff = min(backoff * 2, 30)
        }
    }

    private func poll() async {
        guard let connection, let map else { return }
        do {
            for item in try await connection.read(map.readableIDs) {
                if let v = item.value { values[item.id] = v }
            }
            emit()
        } catch {
            await connection.close()
        }
    }

    private func sleep(seconds: Double) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wake = cont
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                self.fireWake()
            }
        }
    }

    private func fireWake() {
        wake?.resume()
        wake = nil
    }

    private static func initialValues(_ db: AccessoryDatabase) -> [CharacteristicID: HAPValue] {
        var out: [CharacteristicID: HAPValue] = [:]
        for a in db.accessories {
            for s in a.services {
                for c in s.characteristics {
                    if let v = c.value { out[CharacteristicID(aid: a.aid, iid: c.iid)] = v }
                }
            }
        }
        return out
    }
}
