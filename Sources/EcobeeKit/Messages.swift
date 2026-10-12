import Foundation

public enum HelperStatus: Codable, Equatable, Sendable {
    /// The system's "access your Home data" prompt hasn't been answered yet.
    case awaitingPermission
    /// Waiting for HomeKit to deliver the home configuration.
    case loading
    case ready
    /// The user declined (or revoked) Home access for EcobeeBar.
    case notAuthorized
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var status: HelperStatus
    public var thermostats: [Thermostat]

    public init(status: HelperStatus, thermostats: [Thermostat]) {
        self.status = status
        self.thermostats = thermostats
    }
}

public enum Command: Codable, Equatable, Sendable {
    case setTemperature(thermostat: String, field: SetpointField, celsius: Double)
    case setMode(thermostat: String, mode: HVACMode)
    case setFan(thermostat: String, auto: Bool)
    case setComfort(thermostat: String, comfort: Comfort)
    case setDisplayUnits(thermostat: String, fahrenheit: Bool)

    public var thermostatID: String {
        switch self {
        case let .setTemperature(id, _, _), let .setMode(id, _), let .setFan(id, _),
             let .setComfort(id, _), let .setDisplayUnits(id, _):
            id
        }
    }
}

/// Menu bar app → helper.
public enum AppMessage: Codable, Sendable {
    case request(id: Int, command: Command)
}

/// Helper → menu bar app.
public enum HelperMessage: Codable, Sendable {
    case snapshot(Snapshot)
    case reply(id: Int, error: String?)
}

public enum IPC {
    /// Unix socket the helper listens on. Both processes are unsandboxed and
    /// run as the same user; the directory is created with mode 0700.
    public static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/EcobeeBar/homekit.sock"
    }
}
