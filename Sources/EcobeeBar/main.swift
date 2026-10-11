import AppKit
import EcobeeKit
import Observation
import SwiftUI

struct PopoverRoot: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.pairings.isEmpty || model.showingPairing {
                PairingView(model: model)
            } else {
                ControlView(model: model)
            }
        }
        .background(Color.black.opacity(0.72))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: PopoverRoot(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        observeStatusItem()
        if model.pairings.isEmpty { DispatchQueue.main.async { self.togglePopover() } }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Re-render the menu bar item whenever the observed model state changes.
    private func observeStatusItem() {
        withObservationTracking {
            updateStatusItem()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeStatusItem() }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let state = model.state
        let symbol: String = switch (model.status, state?.activity) {
        case (.connected, .heating): "flame.fill"
        case (.connected, .cooling): "snowflake"
        case (.connected, _): "thermometer.medium"
        default: "thermometer.medium.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Thermostat")
        image?.isTemplate = true
        button.image = image
        if model.status == .connected, let c = state?.currentC {
            button.title = " \(model.format(c))°"
        } else {
            button.title = ""
        }
        button.toolTip = state.map { "\($0.name): \($0.activity?.title ?? "Idle")" } ?? "EcobeeBar"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
