import Foundation
import Network

/// A `_hap._tcp` service advertised on the local network.
public struct DiscoveredAccessory: Sendable, Identifiable, Hashable {
    public let name: String
    /// Device ID from the TXT record; equals `Pairing.accessoryPairingID`.
    public let id: String
    public let model: String?
    /// HAP category identifier (9 = thermostat).
    public let category: Int?
    /// sf bit 0: accessory is not paired and accepts Pair Setup.
    public let statusFlags: Int
    /// ff bits: 1 = MFi coprocessor, 2 = software authentication.
    public let featureFlags: Int
    public let endpoint: NWEndpoint

    public var isPairable: Bool { statusFlags & 1 != 0 }
    public var isThermostat: Bool { category == 9 }
    /// aiohomekit pairs with Method 1 when either auth feature flag is set.
    public var wantsAuthPairing: Bool { featureFlags & 0b11 != 0 }
}

/// Browses `_hap._tcp` and yields the full current set whenever it changes.
public final class HAPBrowser: @unchecked Sendable {
    private let browser: NWBrowser

    public init() {
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hap._tcp", domain: nil), using: NWParameters())
    }

    public func results() -> AsyncStream<[DiscoveredAccessory]> {
        AsyncStream { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results.compactMap(Self.parse).sorted { $0.name < $1.name })
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { [browser] _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "hap.browser"))
        }
    }

    /// Browse for up to `timeout`, returning early once `id` is seen.
    public static func find(id: String, timeout: Duration = .seconds(3)) async -> DiscoveredAccessory? {
        await withTaskGroup(of: DiscoveredAccessory?.self) { group in
            group.addTask {
                for await list in HAPBrowser().results() {
                    if let match = list.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { return match }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Snapshot of everything visible after `duration`.
    public static func scan(for duration: Duration = .seconds(3)) async -> [DiscoveredAccessory] {
        let latest = LatestBox()
        let task = Task {
            for await list in HAPBrowser().results() { latest.value = list }
        }
        try? await Task.sleep(for: duration)
        task.cancel()
        return latest.value
    }

    private static func parse(_ result: NWBrowser.Result) -> DiscoveredAccessory? {
        guard case let .service(name, _, _, _) = result.endpoint,
              case let .bonjour(txt) = result.metadata,
              let id = txt["id"]
        else { return nil }
        return DiscoveredAccessory(
            name: name,
            id: id.uppercased(),
            model: txt["md"],
            category: txt["ci"].flatMap { Int($0) },
            statusFlags: txt["sf"].flatMap { Int($0) } ?? 0,
            featureFlags: txt["ff"].flatMap { Int($0) } ?? 0,
            endpoint: result.endpoint
        )
    }
}

private final class LatestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [DiscoveredAccessory] = []
    var value: [DiscoveredAccessory] {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
