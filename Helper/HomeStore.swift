import Foundation
import HomeKit

/// Owns `HMHomeManager`, keeps notifications enabled for every thermostat
/// (and its bridged room sensors), and turns HomeKit objects into `Thermostat`
/// snapshots. Main thread only.
final class HomeStore: NSObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    /// Called whenever anything visible in a snapshot may have changed.
    var onChange: (() -> Void)?

    private let manager = HMHomeManager()
    private var loaded = false

    // ecobee vendor characteristics; Apple Home ignores them but HomeKit exposes them.
    private static let comfortRead = "B7DDB9A3-54BB-4572-91D2-F1F5B0510F8C"
    private static let comfortWrite = "1B300BC2-CFFC-47FF-89F9-BD6CCF5F2853"
    /// ecobee3 lite firmware reports a constant comfort value (per ecobee-local), so hide it there.
    private static let brokenComfortModels = ["ecobee3 lite"]

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: HelperStatus {
        let auth = manager.authorizationStatus
        if !auth.contains(.determined) { return loaded ? .ready : .awaitingPermission }
        if !auth.contains(.authorized) { return .notAuthorized }
        return loaded ? .ready : .loading
    }

    // MARK: Snapshot

    func thermostats() -> [Thermostat] {
        manager.homes.flatMap { home in
            home.accessories.compactMap { accessory in
                thermostatService(of: accessory).map { makeThermostat(accessory, service: $0, home: home) }
            }
        }
    }

    private func thermostatService(of accessory: HMAccessory) -> HMService? {
        accessory.services.first { $0.serviceType == HMServiceTypeThermostat }
    }

    private func makeThermostat(_ accessory: HMAccessory, service: HMService, home: HMHome) -> Thermostat {
        var t = Thermostat(id: accessory.uniqueIdentifier.uuidString, name: accessory.name, home: home.name)
        t.room = accessory.room?.name
        t.model = accessory.model
        t.reachable = accessory.isReachable

        let core = characteristics(of: accessory, service: service)
        t.currentC = core[HMCharacteristicTypeCurrentTemperature]?.double
        t.targetC = core[HMCharacteristicTypeTargetTemperature]?.double
        t.heatThresholdC = core[HMCharacteristicTypeHeatingThreshold]?.double
        t.coolThresholdC = core[HMCharacteristicTypeCoolingThreshold]?.double
        t.humidity = core[HMCharacteristicTypeCurrentRelativeHumidity]?.double
        t.mode = core[HMCharacteristicTypeTargetHeatingCooling]?.int.flatMap(HVACMode.init)
        t.activity = core[HMCharacteristicTypeCurrentHeatingCooling]?.int.flatMap(HVACActivity.init)
        t.prefersFahrenheit = core[HMCharacteristicTypeTemperatureUnits]?.int.map { $0 == 1 }
        t.fanAuto = core[HMCharacteristicTypeTargetFanState]?.int.map { $0 == 1 }
        t.fanRunning = core[HMCharacteristicTypeCurrentFanState]?.int.map { $0 == 2 }

        if let valid = core[HMCharacteristicTypeTargetHeatingCooling]?.metadata?.validValues {
            t.availableModes = valid.compactMap { HVACMode(rawValue: $0.intValue) }
        }
        if let c = core[HMCharacteristicTypeTargetTemperature] { t.targetRange = range(c, default: t.targetRange) }
        if let c = core[HMCharacteristicTypeHeatingThreshold] { t.heatRange = range(c, default: t.heatRange) }
        if let c = core[HMCharacteristicTypeCoolingThreshold] { t.coolRange = range(c, default: t.coolRange) }

        let model = accessory.model?.lowercased() ?? ""
        if core[Self.comfortRead] != nil, core[Self.comfortWrite] != nil,
           !Self.brokenComfortModels.contains(where: model.contains) {
            t.supportsComfort = true
            t.comfort = core[Self.comfortRead]?.int.flatMap(Comfort.init)
        }

        t.sensors = bridgedAccessories(of: accessory, in: home).compactMap(sensorReading)
        return t
    }

    /// Thermostat characteristics by type. Core fields come from the thermostat
    /// service; fan and vendor characteristics may sit in sibling services.
    private func characteristics(of accessory: HMAccessory, service: HMService) -> CharacteristicMap {
        var map = CharacteristicMap()
        for c in service.characteristics { map.insert(c) }
        let siblingTypes = [
            HMCharacteristicTypeTargetFanState, HMCharacteristicTypeCurrentFanState,
            HMCharacteristicTypeCurrentRelativeHumidity, Self.comfortRead, Self.comfortWrite,
        ]
        for s in accessory.services where s != service {
            for c in s.characteristics where siblingTypes.contains(where: { $0.caseInsensitiveCompare(c.characteristicType) == .orderedSame }) {
                map.insert(c)
            }
        }
        return map
    }

    private func range(_ c: HMCharacteristic, default fallback: TemperatureRange) -> TemperatureRange {
        TemperatureRange(
            minC: c.metadata?.minimumValue?.doubleValue ?? fallback.minC,
            maxC: c.metadata?.maximumValue?.doubleValue ?? fallback.maxC,
            stepC: c.metadata?.stepValue?.doubleValue ?? fallback.stepC
        )
    }

    private func bridgedAccessories(of accessory: HMAccessory, in home: HMHome) -> [HMAccessory] {
        guard let ids = accessory.uniqueIdentifiersForBridgedAccessories, !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        return home.accessories.filter { wanted.contains($0.uniqueIdentifier) }
    }

    private func sensorReading(_ accessory: HMAccessory) -> SensorReading? {
        func value(_ service: String, _ type: String) -> HMCharacteristic? {
            accessory.services.first { $0.serviceType == service }?.characteristics.first { $0.characteristicType == type }
        }
        let temperature = value(HMServiceTypeTemperatureSensor, HMCharacteristicTypeCurrentTemperature)
        let occupancy = value(HMServiceTypeOccupancySensor, HMCharacteristicTypeOccupancyDetected)
        let motion = value(HMServiceTypeMotionSensor, HMCharacteristicTypeMotionDetected)
        guard temperature != nil || occupancy != nil || motion != nil else { return nil }
        let lowBattery = accessory.services.lazy.flatMap(\.characteristics)
            .first { $0.characteristicType == HMCharacteristicTypeStatusLowBattery }
        return SensorReading(
            id: accessory.uniqueIdentifier.uuidString,
            name: accessory.name,
            temperatureC: temperature?.double,
            occupied: (occupancy ?? motion)?.int.map { $0 != 0 },
            batteryLow: lowBattery?.int.map { $0 != 0 }
        )
    }

    // MARK: Subscriptions

    /// Enable notifications and refresh values for every thermostat and its sensors.
    private func attach() {
        for home in manager.homes {
            home.delegate = self
            for accessory in home.accessories {
                accessory.delegate = self
                guard thermostatService(of: accessory) != nil else { continue }
                for target in [accessory] + bridgedAccessories(of: accessory, in: home) {
                    target.delegate = self
                    subscribe(target)
                }
            }
        }
    }

    private func subscribe(_ accessory: HMAccessory) {
        for c in accessory.services.flatMap(\.characteristics) {
            if c.properties.contains(HMCharacteristicPropertySupportsEventNotification), !c.isNotificationEnabled {
                c.enableNotification(true) { error in
                    if let error { NSLog("EcobeeBar: notify \(c.characteristicType) on \(accessory.name): \(error.localizedDescription)") }
                }
            }
            if c.properties.contains(HMCharacteristicPropertyReadable) {
                c.readValue { [weak self] _ in self?.onChange?() }
            }
        }
    }

    // MARK: Commands

    func perform(_ command: Command, completion: @escaping (Error?) -> Void) {
        guard let (accessory, service, home) = locate(command.thermostatID) else {
            return completion(StoreError.unknownThermostat)
        }
        let core = characteristics(of: accessory, service: service)
        let thermostat = makeThermostat(accessory, service: service, home: home)

        let write: (String, NSNumber) -> Void = { type, value in
            guard let c = core[type] else { return completion(StoreError.unsupported) }
            c.writeValue(value) { [weak self] error in
                completion(error)
                self?.onChange?()
            }
        }

        switch command {
        case let .setTemperature(_, field, celsius):
            let type = switch field {
            case .target: HMCharacteristicTypeTargetTemperature
            case .heat: HMCharacteristicTypeHeatingThreshold
            case .cool: HMCharacteristicTypeCoolingThreshold
            }
            write(type, NSNumber(value: thermostat.range(field).clamp(celsius)))
        case let .setMode(_, mode):
            write(HMCharacteristicTypeTargetHeatingCooling, NSNumber(value: mode.rawValue))
        case let .setFan(_, auto):
            write(HMCharacteristicTypeTargetFanState, NSNumber(value: auto ? 1 : 0))
        case let .setDisplayUnits(_, fahrenheit):
            write(HMCharacteristicTypeTemperatureUnits, NSNumber(value: fahrenheit ? 1 : 0))
        case let .setComfort(_, comfort):
            guard thermostat.supportsComfort else { return completion(StoreError.unsupported) }
            write(Self.comfortWrite, NSNumber(value: comfort.rawValue))
            // The read-side characteristic lags the write; refresh it shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                core[Self.comfortRead]?.readValue { _ in self?.onChange?() }
            }
        }
    }

    private func locate(_ id: String) -> (HMAccessory, HMService, HMHome)? {
        for home in manager.homes {
            for accessory in home.accessories where accessory.uniqueIdentifier.uuidString == id {
                if let service = thermostatService(of: accessory) { return (accessory, service, home) }
            }
        }
        return nil
    }

    enum StoreError: LocalizedError {
        case unknownThermostat, unsupported
        var errorDescription: String? {
            switch self {
            case .unknownThermostat: "Thermostat is no longer in your Home"
            case .unsupported: "This thermostat doesn't support that"
            }
        }
    }

    // MARK: HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        loaded = true
        attach()
        onChange?()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) { onChange?() }
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) { attach(); onChange?() }
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) { onChange?() }

    // MARK: HMHomeDelegate

    func home(_ home: HMHome, didAdd accessory: HMAccessory) { attach(); onChange?() }
    func home(_ home: HMHome, didRemove accessory: HMAccessory) { onChange?() }
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) { onChange?() }
    func homeDidUpdateName(_ home: HMHome) { onChange?() }

    // MARK: HMAccessoryDelegate

    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) { onChange?() }
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        if accessory.isReachable { subscribe(accessory) }
        onChange?()
    }
    func accessoryDidUpdateName(_ accessory: HMAccessory) { onChange?() }
    func accessoryDidUpdateServices(_ accessory: HMAccessory) { attach(); onChange?() }
}

private extension HMCharacteristic {
    var double: Double? { (value as? NSNumber)?.doubleValue }
    var int: Int? { (value as? NSNumber)?.intValue }
}

/// Characteristics keyed by type UUID, compared case-insensitively. First insert wins.
private struct CharacteristicMap {
    private var byType: [String: HMCharacteristic] = [:]

    mutating func insert(_ c: HMCharacteristic) {
        let key = c.characteristicType.uppercased()
        if byType[key] == nil { byType[key] = c }
    }

    subscript(type: String) -> HMCharacteristic? { byType[type.uppercased()] }
}
