import Foundation
import HAPKit

public enum HVACMode: Int, CaseIterable, Sendable, Identifiable {
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

public enum HVACActivity: Int, Sendable {
    case idle = 0, heating = 1, cooling = 2
    public var title: String {
        switch self {
        case .idle: "Idle"
        case .heating: "Heating"
        case .cooling: "Cooling"
        }
    }
}

public enum Comfort: Int, CaseIterable, Sendable, Identifiable {
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

public struct SensorReading: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let temperatureC: Double?
    public let occupied: Bool?
    public let batteryLow: Bool?
}

public struct TemperatureRange: Sendable {
    public let minC: Double
    public let maxC: Double
    public let stepC: Double

    public init(minC: Double, maxC: Double, stepC: Double) {
        self.minC = minC
        self.maxC = maxC
        self.stepC = stepC
    }
}

/// Typed view over the raw characteristic values of one thermostat.
public struct ThermostatState: Sendable {
    public let map: ThermostatMap
    public let values: [CharacteristicID: HAPValue]

    public init(map: ThermostatMap, values: [CharacteristicID: HAPValue]) {
        self.map = map
        self.values = values
    }

    public func value(_ field: ThermostatMap.Field) -> HAPValue? {
        map.ids[field].flatMap { values[$0] }
    }

    public var name: String { map.name }
    public var currentC: Double? { value(.currentTemperature)?.double }
    public var targetC: Double? { value(.targetTemperature)?.double }
    public var heatThresholdC: Double? { value(.heatThreshold)?.double }
    public var coolThresholdC: Double? { value(.coolThreshold)?.double }
    public var humidity: Double? { value(.humidity)?.double }
    public var targetHumidity: Double? { value(.targetHumidity)?.double }
    public var mode: HVACMode? { value(.targetMode)?.int.flatMap(HVACMode.init) }
    public var activity: HVACActivity? { value(.currentMode)?.int.flatMap(HVACActivity.init) }
    /// TemperatureDisplayUnits: 1 = Fahrenheit.
    public var prefersFahrenheit: Bool? { value(.displayUnits)?.int.map { $0 == 1 } }
    /// TargetFanState: 1 = auto, 0 = manual (always on).
    public var fanAuto: Bool? { value(.targetFan)?.int.map { $0 == 1 } }
    /// CurrentFanState: 2 = blowing.
    public var fanRunning: Bool? { value(.currentFan)?.int.map { $0 == 2 } }
    public var comfort: Comfort? { value(.comfortRead)?.int.flatMap(Comfort.init) }
    public var supportsComfort: Bool { map.supports(.comfortRead) && map.supports(.comfortWrite) }

    public var availableModes: [HVACMode] {
        guard let valid = map.metadata[.targetMode]?.validValues else { return HVACMode.allCases }
        return valid.compactMap(HVACMode.init)
    }

    public func range(_ field: ThermostatMap.Field) -> TemperatureRange {
        let meta = map.metadata[field]
        // HAP defaults: target 10–38 °C, thresholds 10–35 / 0–25 °C.
        let defaults: (Double, Double) = switch field {
        case .heatThreshold: (0, 25)
        case .coolThreshold: (10, 35)
        default: (10, 38)
        }
        return TemperatureRange(minC: meta?.minValue ?? defaults.0, maxC: meta?.maxValue ?? defaults.1, stepC: meta?.minStep ?? 0.1)
    }

    public var sensors: [SensorReading] {
        map.sensors.map { s in
            SensorReading(
                id: s.aid,
                name: s.name,
                temperatureC: s.temperature.flatMap { values[$0]?.double },
                occupied: (s.occupancy.flatMap { values[$0]?.bool }) ?? (s.motion.flatMap { values[$0]?.bool }),
                batteryLow: s.lowBattery.flatMap { values[$0]?.bool }
            )
        }
    }
}
