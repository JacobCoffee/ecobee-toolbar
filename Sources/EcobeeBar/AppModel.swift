import AppKit
import EcobeeKit
import Foundation
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
    let bridge = HomeKitBridge()
    /// Transient command error shown in the footer.
    private(set) var commandError: String?
    /// Setpoint being edited (°C), shown instead of the device value until it lands.
    private(set) var draftC: Double?
    var editsCoolThreshold = false

    var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "selectedThermostat")
            if oldValue != selectedID { draftC = nil }
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

    private var commitTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    init() {
        unitPreference = UnitPreference(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .thermostat
        selectedID = UserDefaults.standard.string(forKey: "selectedThermostat")
        bridge.start()
    }

    var thermostats: [Thermostat] { bridge.thermostats }

    /// The selected thermostat, falling back to the first one in the Home.
    var thermostat: Thermostat? {
        thermostats.first { $0.id == selectedID } ?? thermostats.first
    }

    /// Live data is showing and controls can be used.
    var isLive: Bool { bridge.status == .ready && thermostat?.reachable == true }

    /// Show "Name · Home" in pickers when thermostats span several homes.
    func label(for t: Thermostat) -> String {
        Set(thermostats.map(\.home)).count > 1 ? "\(t.name) · \(t.home)" : t.name
    }

    // MARK: Units

    var useFahrenheit: Bool {
        switch unitPreference {
        case .fahrenheit: true
        case .celsius: false
        case .thermostat: thermostat?.prefersFahrenheit ?? (Locale.current.measurementSystem == .us)
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

    /// The setpoint the big number and slider control in the current mode.
    var activeField: SetpointField {
        guard thermostat?.mode == .auto else { return .target }
        return editsCoolThreshold ? .cool : .heat
    }

    var setpointC: Double? { draftC ?? thermostat?.value(activeField) }

    /// Slider bounds in display units.
    var displayRange: ClosedRange<Double> {
        let r = thermostat?.range(activeField) ?? TemperatureRange(minC: 10, maxC: 32, stepC: 0.1)
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
        guard let draft = draftC, let id = thermostat?.id else { return }
        do {
            try await bridge.send(.setTemperature(thermostat: id, field: activeField, celsius: draft))
            // Hold the draft briefly so the number doesn't flick back before the new snapshot arrives.
            try? await Task.sleep(for: .milliseconds(600))
        } catch {
            flash(error.localizedDescription)
        }
        if draftC == draft { draftC = nil }
    }

    // MARK: Commands

    var isOn: Bool { (thermostat?.mode ?? .off) != .off }

    func togglePower() {
        guard let t = thermostat else { return }
        if isOn, let mode = t.mode {
            UserDefaults.standard.set(mode.rawValue, forKey: "lastMode")
            setMode(.off)
        } else {
            let last = HVACMode(rawValue: UserDefaults.standard.integer(forKey: "lastMode")) ?? .heat
            setMode(t.availableModes.contains(last) && last != .off ? last : t.availableModes.first { $0 != .off } ?? .heat)
        }
    }

    func setMode(_ mode: HVACMode) { send { .setMode(thermostat: $0, mode: mode) } }
    func setFan(auto: Bool) { send { .setFan(thermostat: $0, auto: auto) } }
    func setComfort(_ comfort: Comfort) { send { .setComfort(thermostat: $0, comfort: comfort) } }

    private func send(_ make: (String) -> Command) {
        guard let id = thermostat?.id else { return }
        let command = make(id)
        Task {
            do { try await bridge.send(command) } catch { flash(error.localizedDescription) }
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

    // MARK: System

    func openHomeApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Home") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func openHomePrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_HomeKit")!)
    }
}
