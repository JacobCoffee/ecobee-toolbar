import AppKit
import EcobeeKit
import SwiftUI

struct ControlView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let thermostat = model.thermostat {
                VStack(alignment: .leading, spacing: 16) {
                    ThermostatIllustration(
                        temperature: model.format(thermostat.currentC),
                        activity: thermostat.activity,
                        isOn: model.isOn
                    )
                    .frame(maxWidth: .infinity)
                    setpoint(thermostat)
                    if thermostat.mode == .auto { thresholdPicker(thermostat) }
                    sliderRow(thermostat)
                    tiles(thermostat)
                    if !thermostat.sensors.isEmpty { sensorRow(thermostat.sensors) }
                }
                .disabled(!model.isLive)
                .opacity(model.isLive ? 1 : 0.5)
            } else {
                EmptyStateView(model: model)
            }
            footer
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
            if model.thermostats.count > 1 {
                Menu {
                    Picker("Thermostat", selection: $model.selectedID) {
                        ForEach(model.thermostats) { t in Text(model.label(for: t)).tag(Optional(t.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Text(model.thermostat.map(model.label) ?? "Thermostat").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch thermostat")
            } else {
                Text(model.thermostat?.name ?? "EcobeeBar")
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            if let t = model.thermostat {
                Text("\(model.format(t.currentC))\(model.unitSymbol)")
                    .fontWeight(.semibold)
                if let h = t.humidity {
                    Text("· \(Int(h))%").foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            if model.thermostat != nil {
                RoundIconButton(symbol: "power",
                                tint: model.isOn ? Theme.tint(for: model.activeField, mode: model.thermostat?.mode) : Theme.secondary,
                                glow: model.isOn, size: 40) {
                    model.togglePower()
                }
                .disabled(!model.isLive)
                .help(model.isOn ? "Turn off" : "Turn on")
            }
        }
        .font(.system(size: 15))
    }

    private func setpoint(_ t: Thermostat) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                if model.isOn {
                    if t.mode == .auto {
                        Text(model.editsCoolThreshold ? "Cool to" : "Heat to")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(model.format(model.setpointC))
                            .font(.system(size: 76, weight: .medium))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: model.setpointC)
                        Text(model.unitSymbol)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text("Off")
                        .font(.system(size: 76, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            statusPill(t)
        }
    }

    /// Away toggle on models with working comfort profiles, otherwise live HVAC activity.
    @ViewBuilder private func statusPill(_ t: Thermostat) -> some View {
        if t.supportsComfort {
            Toggle(isOn: Binding(
                get: { t.comfort == .away },
                set: { model.setComfort($0 ? .away : .home) }
            )) {
                Label("Away", systemImage: "leaf")
                    .font(.system(size: 15, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(Theme.cool)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .card(radius: 14)
        } else {
            Label(t.activity?.title ?? "--", systemImage: t.activity?.symbol ?? "pause.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.tint(for: t.activity))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .card(radius: 14)
        }
    }

    private func thresholdPicker(_ t: Thermostat) -> some View {
        HStack(spacing: 8) {
            thresholdChip(cool: false, value: t.heatThresholdC)
            thresholdChip(cool: true, value: t.coolThresholdC)
        }
    }

    private func thresholdChip(cool: Bool, value: Double?) -> some View {
        let selected = model.editsCoolThreshold == cool
        let tint = cool ? Theme.cool : Theme.heat
        return Button {
            model.editsCoolThreshold = cool
        } label: {
            HStack(spacing: 6) {
                Image(systemName: cool ? "snowflake" : "flame")
                Text("\(cool ? "Cool" : "Heat") \(model.format(value))°")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selected ? tint : Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? tint.opacity(0.15) : Theme.card))
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.5) : Theme.cardStroke))
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ t: Thermostat) -> some View {
        let range = model.displayRange
        let tint = Theme.tint(for: model.activeField, mode: t.mode)
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                RoundIconButton(symbol: "minus") { model.nudge(-1) }
                SetpointSlider(
                    value: model.setpointC.map(model.toDisplay) ?? range.lowerBound,
                    range: range,
                    tint: tint,
                    isEnabled: model.isOn,
                    onChange: { model.setDraft(display: $0) },
                    onCommit: { model.scheduleCommit() }
                )
                RoundIconButton(symbol: "plus") { model.nudge(1) }
            }
            .disabled(!model.isOn)
            HStack {
                Text("\(Int(range.lowerBound))°")
                Spacer()
                Text("\(Int(range.upperBound))°")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 58)
        }
    }

    private func tiles(_ t: Thermostat) -> some View {
        HStack(spacing: 10) {
            Tile(symbol: t.mode?.symbol ?? "power", label: "Mode", value: t.mode?.title ?? "--",
                 tint: Theme.tint(for: .target, mode: t.mode)) {
                ForEach(t.availableModes) { mode in
                    Button { model.setMode(mode) } label: { Label(mode.title, systemImage: mode.symbol) }
                }
            }
            if let fanAuto = t.fanAuto {
                Tile(symbol: t.fanRunning == true ? "fan.fill" : "fan", label: "Fan", value: fanAuto ? "Auto" : "On") {
                    Button("Auto") { model.setFan(auto: true) }
                    Button("Always On") { model.setFan(auto: false) }
                }
            }
            if t.supportsComfort {
                Tile(symbol: t.comfort?.symbol ?? "house", label: "Comfort", value: t.comfort?.title ?? "--") {
                    ForEach(Comfort.allCases) { c in
                        Button { model.setComfort(c) } label: { Label(c.title, systemImage: c.symbol) }
                    }
                }
            }
            Tile(symbol: "humidity", label: "Humidity", value: t.humidity.map { "\(Int($0))%" } ?? "--")
        }
    }

    private func sensorRow(_ sensors: [SensorReading]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sensors) { s in
                    HStack(spacing: 6) {
                        Image(systemName: s.occupied == true ? "person.fill" : "sensor")
                            .foregroundStyle(s.occupied == true ? Theme.cool : Theme.secondary)
                        Text(s.name).foregroundStyle(Theme.secondary)
                        if let temperature = s.temperatureC {
                            Text("\(model.format(temperature))°").fontWeight(.semibold)
                        }
                        if s.batteryLow == true {
                            Image(systemName: "battery.25").foregroundStyle(.yellow)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.card))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = model.commandError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).lineLimit(1).truncationMode(.tail)
            } else {
                switch model.bridge.status {
                case .ready where model.thermostat?.reachable == false:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("Not responding")
                case .ready:
                    Image(systemName: "house").foregroundStyle(Theme.secondary)
                    Text(model.thermostat?.room.map { "Apple Home · \($0)" } ?? "Apple Home")
                case .starting, .loading:
                    ProgressView().controlSize(.mini)
                    Text("Connecting to Apple Home…")
                case .awaitingPermission:
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                    Text("Waiting for Home access")
                case .notAuthorized, .missingEntitlement, .helperMissing:
                    Image(systemName: "lock").foregroundStyle(.orange)
                    Text("HomeKit unavailable")
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).lineLimit(1).truncationMode(.tail).help(message)
                }
            }
            Spacer()
            SettingsMenu(model: model)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondary)
    }
}

/// Shown instead of the controls when there's no thermostat to display.
struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let (label, action) = button {
                Button(label, action: action).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var symbol: String {
        switch model.bridge.status {
        case .starting, .loading: "house"
        case .ready: "thermometer.medium.slash"
        default: "lock"
        }
    }

    private var title: String {
        switch model.bridge.status {
        case .starting, .loading: "Connecting to Apple Home…"
        case .ready: "No Thermostats"
        case .awaitingPermission: "Allow Home Access"
        case .notAuthorized: "Home Access Needed"
        case .missingEntitlement: "HomeKit Signing Required"
        case .helperMissing: "HomeKit Helper Missing"
        case .failed: "Can't Reach Apple Home"
        }
    }

    private var message: String {
        switch model.bridge.status {
        case .starting, .loading: "Loading your homes from HomeKit."
        case .ready: "Add your ecobee to the Home app on your iPhone or Mac and it will show up here."
        case .awaitingPermission: "Click Allow in the system prompt so EcobeeBar can read your thermostats from Apple Home."
        case .notAuthorized: "Allow EcobeeBar to access your Home data in System Settings › Privacy & Security › Home."
        case .missingEntitlement: "The HomeKit helper must be signed with the HomeKit entitlement and a provisioning profile. See “Signing” in the README."
        case .helperMissing: "Rebuild with scripts/bundle.sh. The app has to run from its .app bundle."
        case let .failed(message): message
        }
    }

    private var button: (String, () -> Void)? {
        switch model.bridge.status {
        case .notAuthorized: ("Open Privacy Settings", model.openHomePrivacySettings)
        case .ready: ("Open Home", model.openHomeApp)
        default: nil
        }
    }
}

struct SettingsMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Units", selection: $model.unitPreference) {
                ForEach(UnitPreference.allCases) { Text($0.title).tag($0) }
            }
            Button("Open Home App") { model.openHomeApp() }
            Divider()
            Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            Button("Quit EcobeeBar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
