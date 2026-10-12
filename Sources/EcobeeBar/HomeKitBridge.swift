import AppKit
import EcobeeKit
import Observation
import Security

/// Launches the embedded Catalyst HomeKit helper, keeps a socket connection
/// to it, and relaunches it if it goes away.
@MainActor @Observable
final class HomeKitBridge {
    enum Status: Equatable {
        /// Launching or connecting to the helper.
        case starting
        /// Connected; HomeKit hasn't delivered the home yet.
        case loading
        case ready
        /// Waiting for the user to answer the system's Home access prompt.
        case awaitingPermission
        case notAuthorized
        /// The helper isn't signed with `com.apple.developer.homekit`; homed would reject it.
        case missingEntitlement
        case helperMissing
        case failed(String)
    }

    enum BridgeError: LocalizedError {
        case notConnected, timedOut, helper(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to HomeKit"
            case .timedOut: "HomeKit didn't respond"
            case let .helper(message): message
            }
        }
    }

    private(set) var status: Status = .starting
    private(set) var thermostats: [Thermostat] = []

    private typealias Channel = MessageChannel<HelperMessage, AppMessage>
    private var channel: Channel?
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextRequestID = 0
    private var relaunchAttempts = 0
    private var loadingWatchdog: Task<Void, Never>?

    private var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/EcobeeBar HomeKit.app", directoryHint: .isDirectory)
    }

    func start() {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            status = .helperMissing
            return
        }
        guard Self.hasHomeKitEntitlement(helperURL) else {
            status = .missingEntitlement
            return
        }
        launchHelper()
    }

    func stop() {
        channel?.close()
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == helperURL.standardizedFileURL {
            app.terminate()
        }
    }

    func send(_ command: Command) async throws {
        guard let channel else { throw BridgeError.notConnected }
        nextRequestID += 1
        let id = nextRequestID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[id] = continuation
            channel.send(.request(id: id, command: command))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.pending.removeValue(forKey: id)?.resume(throwing: BridgeError.timedOut)
            }
        }
    }

    // MARK: Helper lifecycle

    private func launchHelper() {
        if status != .ready { status = .starting }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.helperStopped("Couldn't start the HomeKit helper: \(error.localizedDescription)")
                } else {
                    self?.connect(retries: 40)
                }
            }
        }
    }

    /// The helper may still be creating its socket; retry briefly before giving up.
    private func connect(retries: Int) {
        let channel = Channel(path: IPC.socketPath)
        var connected = false
        channel.onReady = { [weak self] in
            connected = true
            self?.relaunchAttempts = 0
            self?.armLoadingWatchdog()
        }
        channel.onMessage = { [weak self] in self?.handle($0) }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.channel = nil
            for continuation in self.pending.values { continuation.resume(throwing: BridgeError.notConnected) }
            self.pending.removeAll()
            if !connected, retries > 0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    self.connect(retries: retries - 1)
                }
            } else {
                self.helperStopped("Lost connection to the HomeKit helper")
            }
        }
        self.channel = channel
        channel.start()
    }

    private func helperStopped(_ message: String) {
        status = .failed(message)
        relaunchAttempts += 1
        let delay = min(pow(2, Double(relaunchAttempts)), 30)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            launchHelper()
        }
    }

    private func handle(_ message: HelperMessage) {
        switch message {
        case let .snapshot(snapshot):
            thermostats = snapshot.thermostats
            switch snapshot.status {
            case .loading:
                if case .failed = status { break }  // keep the watchdog's explanation
                status = .loading
            case .ready:
                loadingWatchdog?.cancel()
                status = .ready
            case .awaitingPermission:
                loadingWatchdog?.cancel()
                status = .awaitingPermission
            case .notAuthorized:
                loadingWatchdog?.cancel()
                status = .notAuthorized
            }
        case let .reply(id, error):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error { continuation.resume(throwing: BridgeError.helper(error)) } else { continuation.resume() }
        }
    }

    private func armLoadingWatchdog() {
        if status == .starting { status = .loading }
        loadingWatchdog?.cancel()
        loadingWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.status == .loading else { return }
            self.status = .failed("HomeKit isn't responding. Is this Mac signed in to iCloud with Home turned on?")
        }
    }

    // MARK: Signing check

    /// homed silently drops clients without the HomeKit entitlement, so check up front.
    private static func hasHomeKitEntitlement(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.developer.homekit"] as? Bool == true
    }
}
