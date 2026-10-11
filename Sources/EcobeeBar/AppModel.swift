import AppKit
import EcobeeKit
import Foundation
import HAPKit
import Observation
import ServiceManagement

enum UnitPreference: String, CaseIterable, Identifiable {
    case thermostat, fahrenheit, celsius
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thermostat: "Match Thermostat"
        case .fahrenheit: "Fahrenheit"
        case .celsius: "Celsius"
        }
    }
}

@MainActor @Observable
final class AppModel {
    let store = PairingStore()
    private(set) var pairings: [Pairing] = []
    private(set) var state: ThermostatState?
    private(set) var status: ThermostatClient.Status = .connecting
    /// Transient command error shown in the footer.
    private(set) var commandError: String?
    /// Setpoint being edited (°C), shown instead of the device value until committed.
    private(set) var draftC: Double?
    var editsCoolThreshold = false
    var showingPairing = false

    var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "selectedPairing")
            if oldValue != selectedID { connect() }
        }
    }

    var unitPreference: UnitPreference {
        didSet { UserDefaults.standard.set(unitPreference.rawValue, forKey: "units") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    private var client: ThermostatClient?
    private var updatesTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    init() {
        unitPreference = UnitPreference(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .thermostat
        pairings = store.all()
        let saved = UserDefaults.standard.string(forKey: "selectedPairing")
        selectedID = pairings.first { $0.id == saved }?.id ?? pairings.first?.id
        connect()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.client?.reconnect() }
        }
    }

    var selectedPairing: Pairing? { pairings.first { $0.id == selectedID } }

    // MARK: Connection

    private func connect() {
        updatesTask?.cancel()
        let old = client
        Task { await old?.stop() }
        client = nil
        state = nil
        draftC = nil
        status = .connecting
        guard let pairing = selectedPairing else { return }

        let store = store
        let client = ThermostatClient(pairing: pairing) { ip, port in
            // Remember the latest address for fast reconnects / ecobee-local interop.
            guard pairing.accessoryIP != ip || pairing.accessoryPort != port else { return }
            var updated = pairing
            updated.accessoryIP = ip
            updated.accessoryPort = port
            try? store.save(updated)
        }
        self.client = client
        updatesTask = Task { [weak self] in
            await client.start()
            for await update in client.updates {
                guard let self, !Task.isCancelled else { return }
                self.status = update.status
                if let s = update.state { self.state = s }
            }
        }
    }

    // MARK: Units

    var useFahrenheit: Bool {
        switch unitPreference {
        case .fahrenheit: true
        case .celsius: false
        case .thermostat: state?.prefersFahrenheit ?? (Locale.current.measurementSystem == .us)
        }
    }

    var unitSymbol: String { useFahrenheit ? "°F" : "°C" }
    private var displayStep: Double { useFahrenheit ? 1 : 0.5 }

    func toDisplay(_ c: Double) -> Double { useFahrenheit ? c * 9 / 5 + 32 : c }
    func toCelsius(_ d: Double) -> Double { useFahrenheit ? (d - 32) * 5 / 9 : d }

    /// Display-unit value snapped to whole °F or half °C.
    func display(_ c: Double) -> Double { (toDisplay(c) / displayStep).rounded() * displayStep }

    func format(_ c: Double?) -> String {
        guard let c else { return "--" }
        let d = display(c)
        return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }

    // MARK: Setpoint

    /// The characteristic the big number and slider control in the current mode.
    var activeField: ThermostatMap.Field {
        guard state?.mode == .auto else { return .targetTemperature }
        return editsCoolThreshold ? .coolThreshold : .heatThreshold
    }

    var setpointC: Double? { draftC ?? state?.value(activeField)?.double }

    /// Slider bounds in display units.
    var displayRange: ClosedRange<Double> {
        let r = state?.range(activeField) ?? TemperatureRange(minC: 10, maxC: 32, stepC: 0.1)
        let lo = (toDisplay(r.minC) / displayStep).rounded(.up) * displayStep
        let hi = (toDisplay(r.maxC) / displayStep).rounded(.down) * displayStep
        return lo...max(hi, lo + displayStep)
    }

    func setDraft(display value: Double) {
        let snapped = min(max((value / displayStep).rounded() * displayStep, displayRange.lowerBound), displayRange.upperBound)
        draftC = toCelsius(snapped)
    }

    func nudge(_ steps: Int) {
        guard let current = setpointC else { return }
        setDraft(display: display(current) + Double(steps) * displayStep)
        scheduleCommit(after: .milliseconds(700))
    }

    func scheduleCommit(after delay: Duration = .zero) {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commitDraft()
        }
    }

    private func commitDraft() async {
        guard let draft = draftC, let client else { return }
        let field = activeField
        do {
            try await client.setTemperature(field, celsius: draft)
        } catch {
            flash(error.localizedDescription)
        }
        if draftC == draft { draftC = nil }
    }

    // MARK: Commands

    var isOn: Bool { (state?.mode ?? .off) != .off }

    func togglePower() {
        if isOn, let mode = state?.mode {
            UserDefaults.standard.set(mode.rawValue, forKey: "lastMode")
            setMode(.off)
        } else {
            let last = HVACMode(rawValue: UserDefaults.standard.integer(forKey: "lastMode")) ?? .heat
            let available = state?.availableModes ?? []
            setMode(available.contains(last) && last != .off ? last : available.first { $0 != .off } ?? .heat)
        }
    }

    func setMode(_ mode: HVACMode) { run { try await $0.setMode(mode) } }
    func setFan(auto: Bool) { run { try await $0.setFan(auto: auto) } }
    func setComfort(_ comfort: Comfort) { run { try await $0.setComfort(comfort) } }

    private func run(_ body: @escaping @Sendable (ThermostatClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do { try await body(client) } catch { flash(error.localizedDescription) }
        }
    }

    private func flash(_ message: String) {
        commandError = message
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.commandError = nil
        }
    }

    // MARK: Pairing management

    func pair(_ accessory: DiscoveredAccessory, code: String) async throws {
        add(try await HAPSession.pair(accessory, code: code))
    }

    func pair(host: String, port: UInt16, code: String) async throws {
        add(try await HAPSession.pair(endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!),
                                      name: nil, withAuth: false, code: code))
    }

    func importPairings(from url: URL) throws {
        let loaded = try Pairing.load(from: url)
        guard let last = loaded.last else { return }
        for p in loaded { try store.save(p) }
        reloadPairings(select: last.id)
    }

    func importEcobeeLocal() throws {
        let found = store.importableFromEcobeeLocal()
        for p in found { try store.save(p) }
        reloadPairings(select: found.first?.id)
    }

    var ecobeeLocalImportCount: Int { store.importableFromEcobeeLocal().count }

    private func add(_ pairing: Pairing) {
        do {
            try store.save(pairing)
            reloadPairings(select: pairing.id)
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func reloadPairings(select id: String?) {
        pairings = store.all()
        showingPairing = false
        if let id, selectedID != id { selectedID = id } else if selectedID == nil { selectedID = pairings.first?.id }
    }

    /// Unpair from the thermostat (if reachable) and delete local credentials.
    func remove(_ pairing: Pairing, unpairFromDevice: Bool) async {
        if unpairFromDevice, pairing.id == selectedID, let client {
            do { try await client.unpair() } catch { flash("Couldn't unpair from thermostat: \(error.localizedDescription)") }
        }
        try? store.delete(pairing)
        pairings = store.all()
        if selectedID == pairing.id { selectedID = pairings.first?.id }
    }

    func reconnect() {
        Task { await client?.reconnect() }
    }
}
