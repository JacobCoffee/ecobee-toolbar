import Foundation
import HAPKit

/// Thermostat-relevant characteristics located by HomeKit type, so the same
/// code works across ecobee models (and any HomeKit thermostat).
public struct ThermostatMap: Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case currentTemperature = "11"
        case targetTemperature = "35"
        case targetMode = "33"
        case currentMode = "0F"
        case coolThreshold = "0D"
        case heatThreshold = "12"
        case humidity = "10"
        case targetHumidity = "34"
        case displayUnits = "36"
        case targetFan = "BF"
        case currentFan = "AF"
        /// ecobee vendor characteristic: active comfort profile (read).
        case comfortRead = "B7DDB9A3-54BB-4572-91D2-F1F5B0510F8C"
        /// ecobee vendor characteristic: select comfort profile (write-only).
        case comfortWrite = "1B300BC2-CFFC-47FF-89F9-BD6CCF5F2853"
    }

    public struct Sensor: Sendable, Identifiable {
        public let aid: Int
        public let name: String
        public let temperature: CharacteristicID?
        public let occupancy: CharacteristicID?
        public let motion: CharacteristicID?
        public let battery: CharacteristicID?
        public let lowBattery: CharacteristicID?

        public var id: Int { aid }
    }

    public let name: String
    public let ids: [Field: CharacteristicID]
    public let metadata: [Field: Characteristic]
    public let sensors: [Sensor]
    /// Characteristics that support event notifications.
    public let notifiable: Set<CharacteristicID>

    static let thermostatService = "4A"
    static let fanServices = ["B7", "40"]

    public init?(_ db: AccessoryDatabase) {
        guard let accessory = db.accessories.first(where: { !$0.services(Self.thermostatService).isEmpty }),
              let service = accessory.services(Self.thermostatService).first
        else { return nil }

        var ids: [Field: CharacteristicID] = [:]
        var metadata: [Field: Characteristic] = [:]
        // Thermostat service first; fan / vendor characteristics may live in
        // sibling services of the same accessory.
        let ordered = [service] + accessory.services.filter { $0.iid != service.iid }
        for field in Field.allCases {
            let candidates = field == .targetFan || field == .currentFan
                ? [service] + accessory.services.filter { Self.fanServices.map(HAPUUID.normalize).contains($0.uuid) }
                : ordered
            for s in candidates {
                // Sibling sensor services also have CurrentTemperature; only
                // take core fields from the thermostat service itself.
                if s.iid != service.iid, [.currentTemperature, .humidity].contains(field) { continue }
                if let c = s.characteristic(field.rawValue) {
                    ids[field] = CharacteristicID(aid: accessory.aid, iid: c.iid)
                    metadata[field] = c
                    break
                }
            }
        }
        self.ids = ids
        self.metadata = metadata
        name = accessory.name ?? "Thermostat"
        sensors = db.accessories.compactMap { Self.sensor(in: $0) }
        notifiable = Set(db.accessories.flatMap { a in
            a.services.flatMap { s in s.characteristics.filter(\.notifies).map { CharacteristicID(aid: a.aid, iid: $0.iid) } }
        })
    }

    private static func sensor(in accessory: Accessory) -> Sensor? {
        func find(_ service: String, _ char: String) -> (Service, Characteristic)? {
            for s in accessory.services(service) {
                if let c = s.characteristic(char) { return (s, c) }
            }
            return nil
        }
        let temperature = find("8A", "11")
        let occupancy = find("86", "71")
        let motion = find("85", "22")
        guard temperature != nil || occupancy != nil || motion != nil else { return nil }
        let battery = find("96", "68")
        let lowBattery = find("96", "79")
        let id = { (pair: (Service, Characteristic)?) in pair.map { CharacteristicID(aid: accessory.aid, iid: $0.1.iid) } }
        let serviceName = [temperature, occupancy, motion].compactMap { $0?.0.characteristic(HAPUUID.name)?.value?.string }.first
        return Sensor(
            aid: accessory.aid,
            name: serviceName ?? accessory.name ?? "Sensor \(accessory.aid)",
            temperature: id(temperature),
            occupancy: id(occupancy),
            motion: id(motion),
            battery: id(battery),
            lowBattery: id(lowBattery)
        )
    }

    /// Everything worth reading (write-only characteristics excluded).
    public var readableIDs: [CharacteristicID] {
        let core = Field.allCases.compactMap { f in metadata[f]?.readable == true ? ids[f] : nil }
        let sensorIDs = sensors.flatMap { [$0.temperature, $0.occupancy, $0.motion, $0.battery, $0.lowBattery].compactMap { $0 } }
        return core + sensorIDs
    }

    public func supports(_ field: Field) -> Bool { ids[field] != nil }
}
