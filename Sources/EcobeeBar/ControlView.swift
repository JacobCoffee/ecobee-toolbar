import AppKit
import EcobeeKit
import HAPKit
import SwiftUI

struct ControlView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 16) {
                ThermostatIllustration(
                    temperature: model.format(model.state?.currentC),
                    activity: model.state?.activity,
                    isOn: model.isOn
                )
                .frame(maxWidth: .infinity)
                setpoint
                if model.state?.mode == .auto { thresholdPicker }
                sliderRow
                tiles
                if let sensors = model.state?.sensors, !sensors.isEmpty { sensorRow(sensors) }
            }
            .disabled(model.state == nil)
            .opacity(model.state == nil ? 0.5 : 1)
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
            Menu {
                Picker("Thermostat", selection: $model.selectedID) {
                    ForEach(model.pairings) { p in Text(p.displayName).tag(Optional(p.id)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Add Thermostat…") { model.showingPairing = true }
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedPairing?.displayName ?? model.state?.name ?? "Thermostat")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch thermostat")
            Text("\(model.format(model.state?.currentC))\(model.unitSymbol)")
                .fontWeight(.semibold)
            if let h = model.state?.humidity {
                Text("· \(Int(h))%")
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            RoundIconButton(symbol: "power", tint: model.isOn ? Theme.tint(for: model.activeField, mode: model.state?.mode) : Theme.secondary,
                            glow: model.isOn, size: 40) {
                model.togglePower()
            }
            .help(model.isOn ? "Turn off" : "Turn on")
        }
        .font(.system(size: 15))
    }

    private var setpoint: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                if model.isOn {
                    if model.state?.mode == .auto {
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
            statusPill
        }
    }

    /// Away toggle on models with comfort profiles, otherwise live HVAC status.
    @ViewBuilder private var statusPill: some View {
        if let state = model.state, state.supportsComfort {
            Toggle(isOn: Binding(
                get: { state.comfort == .away },
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
            let activity = model.state?.activity
            Label(activity?.title ?? "--", systemImage: activity?.symbol ?? "pause.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.tint(for: activity))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .card(radius: 14)
        }
    }

    private var thresholdPicker: some View {
        HStack(spacing: 8) {
            thresholdChip(cool: false)
            thresholdChip(cool: true)
        }
    }

    private func thresholdChip(cool: Bool) -> some View {
        let selected = model.editsCoolThreshold == cool
        let tint = cool ? Theme.cool : Theme.heat
        let value = cool ? model.state?.coolThresholdC : model.state?.heatThresholdC
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

    private var sliderRow: some View {
        let range = model.displayRange
        let tint = Theme.tint(for: model.activeField, mode: model.state?.mode)
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

    private var tiles: some View {
        let state = model.state
        return HStack(spacing: 10) {
            Tile(symbol: state?.mode?.symbol ?? "power", label: "Mode", value: state?.mode?.title ?? "--",
                 tint: Theme.tint(for: .targetTemperature, mode: state?.mode)) {
                ForEach(state?.availableModes ?? HVACMode.allCases) { mode in
                    Button { model.setMode(mode) } label: { Label(mode.title, systemImage: mode.symbol) }
                }
            }
            if state?.map.supports(.targetFan) ?? false {
                Tile(symbol: state?.fanRunning == true ? "fan.fill" : "fan", label: "Fan",
                     value: state?.fanAuto.map { $0 ? "Auto" : "On" } ?? "--") {
                    Button("Auto") { model.setFan(auto: true) }
                    Button("Always On") { model.setFan(auto: false) }
                }
            }
            if let state, state.supportsComfort {
                Tile(symbol: state.comfort?.symbol ?? "house", label: "Comfort", value: state.comfort?.title ?? "--") {
                    ForEach(Comfort.allCases) { c in
                        Button { model.setComfort(c) } label: { Label(c.title, systemImage: c.symbol) }
                    }
                }
            }
            Tile(symbol: "humidity", label: "Humidity", value: state?.humidity.map { "\(Int($0))%" } ?? "--")
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
                        if let t = s.temperatureC {
                            Text("\(model.format(t))°").fontWeight(.semibold)
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
                switch model.status {
                case .connected:
                    Image(systemName: "checkmark.shield").foregroundStyle(Theme.secondary)
                    Text("Connected locally")
                case .connecting:
                    ProgressView().controlSize(.mini)
                    Text("Connecting…")
                case let .failed(message):
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    Text(message).lineLimit(1).truncationMode(.tail)
                    Button("Retry") { model.reconnect() }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            SettingsMenu(model: model)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondary)
    }
}

struct SettingsMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Units", selection: $model.unitPreference) {
                ForEach(UnitPreference.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Add Thermostat…") { model.showingPairing = true }
            if let pairing = model.selectedPairing {
                Button("Remove \(pairing.displayName)…") { confirmRemove(pairing) }
            }
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

    private func confirmRemove(_ pairing: Pairing) {
        let alert = NSAlert()
        alert.messageText = "Remove \(pairing.displayName)?"
        alert.informativeText = "Unpairing tells the thermostat to forget EcobeeBar so it can be added to Apple Home or paired again. "
            + "Remove Only deletes the local credentials and leaves the thermostat paired."
        alert.addButton(withTitle: "Unpair & Remove")
        alert.addButton(withTitle: "Remove Only")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await model.remove(pairing, unpairFromDevice: true) }
        case .alertSecondButtonReturn: Task { await model.remove(pairing, unpairFromDevice: false) }
        default: break
        }
    }
}
