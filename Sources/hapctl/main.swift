import EcobeeKit
import Foundation
import HAPKit
import Network

let usage = """
usage: hapctl [--dir PATH] <command> [args]

  scan                         list HomeKit accessories on the network
  pair <id|name|host:port> <code>
                               pair with an accessory (8-digit setup code)
  import <file>                import an ecobee-local / aiohomekit pairing file
  list                         list stored pairings
  dump [id]                    print every service and characteristic
  status [id]                  print thermostat state
  watch [id]                   stream thermostat updates
  set-temp <°C> [id]           set target temperature
  set-heat <°C> [id]           set auto-mode heat threshold
  set-cool <°C> [id]           set auto-mode cool threshold
  set-mode <off|heat|cool|auto> [id]
  set-fan <auto|on> [id]
  set-comfort <home|sleep|away|hold> [id]
  unpair [id]                  remove the pairing from the accessory and delete it
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
var storeDirectory = PairingStore.defaultDirectory
if let i = arguments.firstIndex(of: "--dir"), i + 1 < arguments.count {
    storeDirectory = URL(filePath: arguments[i + 1])
    arguments.removeSubrange(i...i + 1)
}
let store = PairingStore(directory: storeDirectory)
let args = arguments
guard let command = args.first else { fail(usage) }
let rest = Array(args.dropFirst())

func pairing(_ id: String?) -> Pairing {
    let all = store.all()
    if let id {
        guard let p = all.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame || $0.label == id || $0.name == id })
        else { fail("no pairing matching \(id)") }
        return p
    }
    guard let first = all.first else { fail("no pairings stored in \(store.directory.path)") }
    return first
}

func fmt(_ c: Double?) -> String {
    guard let c else { return "--" }
    return String(format: "%.1f°C / %.0f°F", c, c * 9 / 5 + 32)
}

func printState(_ s: ThermostatState) {
    print("\(s.name)")
    print("  current   \(fmt(s.currentC))   humidity \(s.humidity.map { "\(Int($0))%" } ?? "--")")
    print("  mode      \(s.mode?.title ?? "--")   activity \(s.activity?.title ?? "--")")
    print("  target    \(fmt(s.targetC))")
    print("  heat/cool \(fmt(s.heatThresholdC))  ..  \(fmt(s.coolThresholdC))")
    print("  fan       \(s.fanAuto.map { $0 ? "auto" : "on" } ?? "--")   running \(s.fanRunning.map(String.init) ?? "--")")
    print("  comfort   \(s.supportsComfort ? (s.comfort?.title ?? "--") : "unsupported")")
    print("  units     \(s.prefersFahrenheit.map { $0 ? "F" : "C" } ?? "--")")
    for sensor in s.sensors {
        print("  sensor    \(sensor.name): \(fmt(sensor.temperatureC)) occupied=\(sensor.occupied.map(String.init) ?? "--")")
    }
}

/// Connect a client, wait for the first connected state, run `body`, stop.
func withClient(_ id: String?, _ body: (ThermostatClient, ThermostatState) async throws -> Void) async throws {
    let p = pairing(id)
    let client = ThermostatClient(pairing: p)
    await client.start()
    for await update in client.updates {
        switch update.status {
        case .connected:
            guard let state = update.state else { continue }
            try await body(client, state)
            await client.stop()
            return
        case let .failed(message):
            await client.stop()
            fail("connection failed: \(message)")
        case .connecting:
            continue
        }
    }
}

func parseC(_ s: String?) -> Double {
    guard let s, let v = Double(s) else { fail(usage) }
    return v
}

do {
    switch command {
    case "scan":
        for a in await HAPBrowser.scan(for: .seconds(4)) {
            print("\(a.id)  \(a.name)  model=\(a.model ?? "?") ci=\(a.category.map(String.init) ?? "?") "
                + "\(a.isPairable ? "PAIRABLE" : "paired") ff=\(a.featureFlags)")
        }

    case "pair":
        guard rest.count >= 2 else { fail(usage) }
        let p: Pairing
        let parts = rest[0].split(separator: ":")
        if parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) {
            p = try await HAPSession.pair(endpoint: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port),
                                          name: nil, withAuth: false, code: rest[1])
        } else {
            let found = await HAPBrowser.scan(for: .seconds(4))
            guard let target = found.first(where: { $0.id.caseInsensitiveCompare(rest[0]) == .orderedSame || $0.name == rest[0] })
            else { fail("accessory \(rest[0]) not found") }
            p = try await HAPSession.pair(target, code: rest[1])
        }
        try store.save(p)
        print("paired \(p.displayName) (\(p.id)) → \(store.directory.path)")

    case "import":
        guard let path = rest.first else { fail(usage) }
        for p in try Pairing.load(from: URL(filePath: path)) {
            try store.save(p)
            print("imported \(p.displayName) (\(p.id))")
        }

    case "list":
        for p in store.all() {
            print("\(p.id)  \(p.displayName)  \(p.accessoryIP ?? "?"):\(p.accessoryPort.map(String.init) ?? "?")")
        }

    case "dump":
        let conn = try await HAPSession.open(pairing(rest.first))
        let db = try await conn.accessories()
        for a in db.accessories {
            print("accessory \(a.aid) \(a.name ?? "")")
            for s in a.services {
                print("  service \(s.type) iid=\(s.iid)")
                for c in s.characteristics {
                    let range = [c.minValue.map { "min=\($0)" }, c.maxValue.map { "max=\($0)" }, c.minStep.map { "step=\($0)" }]
                        .compactMap { $0 }.joined(separator: " ")
                    print("    \(c.iid) \(c.type) [\(c.perms.joined(separator: ","))] \(c.format ?? "") = \(c.value?.description ?? "-") \(range)")
                }
            }
        }
        await conn.close()

    case "status":
        try await withClient(rest.first) { _, state in printState(state) }

    case "watch":
        let client = ThermostatClient(pairing: pairing(rest.first))
        await client.start()
        for await update in client.updates {
            print("[\(Date().formatted(date: .omitted, time: .standard))] \(update.status)")
            if let s = update.state, update.status == .connected { printState(s) }
        }

    case "set-temp", "set-heat", "set-cool":
        let field: ThermostatMap.Field = command == "set-temp" ? .targetTemperature : command == "set-heat" ? .heatThreshold : .coolThreshold
        let c = parseC(rest.first)
        try await withClient(rest.dropFirst().first) { client, _ in
            try await client.setTemperature(field, celsius: c)
            print("ok")
        }

    case "set-mode":
        guard let m = rest.first, let mode = HVACMode.allCases.first(where: { $0.title.lowercased() == m }) else { fail(usage) }
        try await withClient(rest.dropFirst().first) { client, _ in try await client.setMode(mode); print("ok") }

    case "set-fan":
        guard let f = rest.first, ["auto", "on"].contains(f) else { fail(usage) }
        try await withClient(rest.dropFirst().first) { client, _ in try await client.setFan(auto: f == "auto"); print("ok") }

    case "set-comfort":
        guard let m = rest.first, let comfort = Comfort.allCases.first(where: { $0.title.lowercased() == m }) else { fail(usage) }
        try await withClient(rest.dropFirst().first) { client, _ in try await client.setComfort(comfort); print("ok") }

    case "unpair":
        let p = pairing(rest.first)
        try await withClient(p.id) { client, _ in try await client.unpair() }
        try store.delete(p)
        print("unpaired \(p.displayName)")

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
