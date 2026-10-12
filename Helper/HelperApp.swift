import UIKit

/// Headless Mac Catalyst app: the only process holding the HomeKit
/// entitlement. Serves thermostat snapshots and executes commands for the
/// EcobeeBar menu bar app over a Unix socket, and quits once that app is gone.
@main
final class HelperDelegate: UIResponder, UIApplicationDelegate {
    private typealias Channel = MessageChannel<AppMessage, HelperMessage>

    private let store = HomeStore()
    private var server: MessageServer<AppMessage, HelperMessage>?
    private var clients: [ObjectIdentifier: Channel] = [:]
    private var lastSnapshot: Snapshot?
    private var broadcastScheduled = false
    private var idleExit: DispatchWorkItem?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        store.onChange = { [weak self] in self?.scheduleBroadcast() }
        do {
            let server = try MessageServer<AppMessage, HelperMessage>(path: IPC.socketPath)
            server.onConnection = { [weak self] in self?.accept($0) }
            self.server = server
        } catch {
            NSLog("EcobeeBar HomeKit: cannot listen on \(IPC.socketPath): \(error)")
            exit(1)
        }
        // Launched without the menu bar app (e.g. by hand): don't linger.
        scheduleIdleExit(after: 60)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = WindowlessSceneDelegate.self
        return configuration
    }

    private func accept(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        clients[id] = channel
        idleExit?.cancel()
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(.snapshot(self.makeSnapshot()))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard case let .request(requestID, command) = message else { return }
            self?.store.perform(command) { error in
                channel?.send(.reply(id: requestID, error: error?.localizedDescription))
            }
        }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.clients[id] = nil
            if self.clients.isEmpty { self.scheduleIdleExit(after: 10) }
        }
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(status: store.status, thermostats: store.thermostats())
    }

    /// Coalesce bursts of HomeKit callbacks into one snapshot.
    private func scheduleBroadcast() {
        guard !broadcastScheduled else { return }
        broadcastScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.broadcastScheduled = false
            let snapshot = self.makeSnapshot()
            guard snapshot != self.lastSnapshot else { return }
            self.lastSnapshot = snapshot
            for client in self.clients.values { client.send(.snapshot(snapshot)) }
        }
    }

    private func scheduleIdleExit(after seconds: Double) {
        idleExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.clients.isEmpty ?? true { exit(0) }
        }
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Catalyst requires a scene; this one never creates a window.
final class WindowlessSceneDelegate: UIResponder, UIWindowSceneDelegate {}
