import AppKit
import HAPKit
import SwiftUI
import UniformTypeIdentifiers

struct PairingView: View {
    @Bindable var model: AppModel

    @State private var accessories: [DiscoveredAccessory] = []
    @State private var selection: DiscoveredAccessory?
    @State private var code = ""
    @State private var manualAddress = ""
    @State private var showManual = false
    @State private var busy = false
    @State private var error: String?

    private var digits: String { String(code.filter(\.isNumber).prefix(8)) }
    private var thermostats: [DiscoveredAccessory] { accessories.filter(\.isThermostat) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add a Thermostat").font(.system(size: 20, weight: .semibold))
                Spacer()
                if !model.pairings.isEmpty {
                    Button("Cancel") { model.showingPairing = false }.buttonStyle(.link)
                }
            }
            Text("EcobeeBar talks to your ecobee directly over HomeKit on your network. No cloud account is involved. "
                + "A thermostat that's already in Apple Home has to be reset first: on the thermostat, go to Menu → Settings → HomeKit → Reset.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            deviceList

            if !showManual {
                Button("Enter address manually") { showManual = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            } else {
                TextField("192.168.1.50:1200", text: $manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: manualAddress) { if !manualAddress.isEmpty { selection = nil } }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("HomeKit setup code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                TextField("1234 5678", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .onSubmit(pair)
                Text("You'll find the 8-digit code on the thermostat under Menu → Settings → HomeKit.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Menu("Import…") {
                    let count = model.ecobeeLocalImportCount
                    Button(count > 0 ? "From ecobee-local (\(count) found)" : "From ecobee-local (none found)") {
                        attempt { try model.importEcobeeLocal() }
                    }
                    .disabled(count == 0)
                    Button("Pairing File…", action: importFile)
                }
                .fixedSize()
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || digits.count != 8 || (selection == nil && parsedManual == nil))
            }
        }
        .padding(20)
        .frame(width: 400)
        .task {
            for await list in HAPBrowser().results() {
                accessories = list
                if selection == nil, manualAddress.isEmpty {
                    selection = list.first { $0.isThermostat && $0.isPairable }
                }
            }
        }
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            if thermostats.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for HomeKit thermostats…").foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(12)
            }
            ForEach(thermostats) { a in
                let added = model.pairings.contains { $0.id == a.id }
                Button {
                    if added {
                        model.selectedID = a.id
                        model.showingPairing = false
                    } else {
                        selection = a
                        manualAddress = ""
                    }
                } label: {
                    HStack {
                        Image(systemName: added ? "checkmark.circle.fill" : selection == a ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(added || selection == a ? Theme.cool : Theme.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).foregroundStyle(.white)
                            Text(a.model ?? a.id).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if added {
                            Text("Added · Switch").font(.system(size: 11)).foregroundStyle(Theme.cool)
                        } else if !a.isPairable {
                            Text("In another HomeKit home").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                .help("Paired to another home (usually Apple Home). Reset HomeKit on the thermostat to pair it here.")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!added && !a.isPairable)
                .opacity(added || a.isPairable ? 1 : 0.5)
            }
        }
        .card(radius: 12)
    }

    private var parsedManual: (String, UInt16)? {
        let parts = manualAddress.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    private func pair() {
        guard digits.count == 8, !busy else { return }
        busy = true
        error = nil
        let code = digits
        Task {
            do {
                if let (host, port) = parsedManual {
                    try await model.pair(host: host, port: port, code: code)
                } else if let selection {
                    try await model.pair(selection, code: code)
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = PairingStore.ecobeeLocalDirectory
        panel.message = "Choose an ecobee-local or aiohomekit pairing file"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try model.importPairings(from: url) }
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { self.error = error.localizedDescription }
    }
}
