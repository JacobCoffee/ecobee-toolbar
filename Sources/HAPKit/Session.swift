import Foundation
import Network

public enum HAPSession {
    /// Connect and pair-verify. Races the stored address against a Bonjour
    /// lookup by device ID (the accessory may have a new address) and uses
    /// whichever TCP connection comes up first.
    public static func open(_ pairing: Pairing, discoveryTimeout: Duration = .seconds(3)) async throws -> HAPConnection {
        let connection = try await firstConnection(to: pairing, discoveryTimeout: discoveryTimeout)
        do {
            try await connection.pairVerify(pairing)
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    private static func firstConnection(to pairing: Pairing, discoveryTimeout: Duration) async throws -> HAPConnection {
        let stored = pairing.accessoryIP.flatMap { ip in
            pairing.accessoryPort.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) }.map { NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: $0) }
        }
        return try await withThrowingTaskGroup(of: HAPConnection?.self) { group in
            if let stored {
                group.addTask { try? await HAPConnection.connect(to: stored, timeout: .seconds(4)) }
            }
            group.addTask {
                guard let found = await HAPBrowser.find(id: pairing.accessoryPairingID, timeout: discoveryTimeout) else { return nil }
                return try? await HAPConnection.connect(to: found.endpoint)
            }
            var winner: HAPConnection?
            for try await result in group {
                guard let result else { continue }
                if winner == nil {
                    winner = result
                    group.cancelAll()
                } else {
                    await result.close()
                }
            }
            guard let winner else { throw HAPError.notConnected }
            return winner
        }
    }

    /// Run Pair Setup against a discovered accessory and return the new pairing,
    /// with its current address recorded for fallback reconnects.
    public static func pair(_ accessory: DiscoveredAccessory, code: String) async throws -> Pairing {
        try await pair(endpoint: accessory.endpoint, name: accessory.name, withAuth: accessory.wantsAuthPairing, code: code)
    }

    /// Pair Setup against an explicit endpoint (e.g. `host:port` when mDNS is unavailable).
    public static func pair(endpoint: NWEndpoint, name: String?, withAuth: Bool, code: String) async throws -> Pairing {
        let connection = try await HAPConnection.connect(to: endpoint)
        defer { Task { await connection.close() } }
        var pairing = try await connection.pairSetup(code: code, withAuth: withAuth)
        pairing.name = name
        if let (ip, port) = await address(of: connection) {
            pairing.accessoryIP = ip
            pairing.accessoryPort = port
        }
        return pairing
    }

    /// Current address of an open connection, for refreshing `Pairing.accessoryIP`.
    public static func address(of connection: HAPConnection) async -> (String, Int)? {
        guard case let .hostPort(host, port) = await connection.remoteEndpoint else { return nil }
        return (hostString(host), Int(port.rawValue))
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(a): "\(a)"
        case let .ipv6(a): "\(a)"
        case let .name(n, _): n
        @unknown default: "\(host)"
        }
    }
}
