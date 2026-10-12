import Foundation

// Shared between the menu bar app (macOS) and the HomeKit helper (Mac Catalyst).
// Foundation only, so it compiles for both.

public enum HVACMode: Int, Codable, CaseIterable, Sendable, Identifiable {
    case off = 0, heat = 1, cool = 2, auto = 3
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .heat: "Heat"
        case .cool: "Cool"
        case .auto: "Auto"
        }
    }
}

public enum HVACActivity: Int, Codable, Sendable {
    case idle = 0, heating = 1, cooling = 2
    public var title: String {
        switch self {
        case .idle: "Idle"
        case .heating: "Heating"
        case .cooling: "Cooling"
        }
    }
}

/// ecobee comfort profile (vendor characteristic; not on every model).
public enum Comfort: Int, Codable, CaseIterable, Sendable, Identifiable {
    case home = 0, sleep = 1, away = 2, hold = 3
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
        case .sleep: "Sleep"
        case .away: "Away"
        case .hold: "Hold"
        }
    }
}

/// Which setpoint a temperature command targets.
public enum SetpointField: String, Codable, Sendable {
    /// Single target in Heat / Cool mode.
    case target
    /// Auto-mode lower bound.
    case heat
    /// Auto-mode upper bound.
    case cool
}

public struct TemperatureRange: Codable, Sendable, Equatable {
    public var minC: Double
    public var maxC: Double
    public var stepC: Double

    public init(minC: Double, maxC: Double, stepC: Double) {
        self.minC = minC
        self.maxC = maxC
        self.stepC = stepC
    }

    /// Snap to the characteristic's step and clamp to its bounds.
    public func clamp(_ celsius: Double) -> Double {
        let step = stepC > 0 ? stepC : 0.1
        let stepped = (celsius / step).rounded() * step
        return (min(max(stepped, minC), maxC) * 1000).rounded() / 1000
    }
}

public struct SensorReading: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var temperatureC: Double?
    public var occupied: Bool?
    public var batteryLow: Bool?

    public init(id: String, name: String, temperatureC: Double?, occupied: Bool?, batteryLow: Bool?) {
        self.id = id
        self.name = name
        self.temperatureC = temperatureC
        self.occupied = occupied
        self.batteryLow = batteryLow
    }
}

public struct Thermostat: Codable, Sendable, Identifiable, Equatable {
    /// `HMAccessory.uniqueIdentifier`.
    public var id: String
    public var name: String
    public var home: String
    public var room: String?
    public var model: String?
    public var reachable: Bool

    public var currentC: Double?
    public var targetC: Double?
    public var heatThresholdC: Double?
    public var coolThresholdC: Double?
    public var humidity: Double?
    public var mode: HVACMode?
    public var activity: HVACActivity?
    /// TemperatureDisplayUnits set on the thermostat.
    public var prefersFahrenheit: Bool?
    /// TargetFanState: true = auto, false = always on. Nil when unsupported.
    public var fanAuto: Bool?
    public var fanRunning: Bool?
    /// Nil when the model has no (working) comfort profiles.
    public var comfort: Comfort?
    public var supportsComfort: Bool

    public var availableModes: [HVACMode]
    public var targetRange: TemperatureRange
    public var heatRange: TemperatureRange
    public var coolRange: TemperatureRange
    public var sensors: [SensorReading]

    public init(id: String, name: String, home: String) {
        self.id = id
        self.name = name
        self.home = home
        reachable = true
        supportsComfort = false
        availableModes = HVACMode.allCases
        // HAP defaults when the accessory doesn't publish metadata.
        targetRange = TemperatureRange(minC: 10, maxC: 38, stepC: 0.1)
        heatRange = TemperatureRange(minC: 0, maxC: 25, stepC: 0.1)
        coolRange = TemperatureRange(minC: 10, maxC: 35, stepC: 0.1)
        sensors = []
    }

    public var supportsFan: Bool { fanAuto != nil }

    public func value(_ field: SetpointField) -> Double? {
        switch field {
        case .target: targetC
        case .heat: heatThresholdC
        case .cool: coolThresholdC
        }
    }

    public func range(_ field: SetpointField) -> TemperatureRange {
        switch field {
        case .target: targetRange
        case .heat: heatRange
        case .cool: coolRange
        }
    }
}
