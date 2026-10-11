import Foundation

/// A HAP characteristic value as it appears in JSON.
public enum HAPValue: Codable, Sendable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var double: Double? {
        switch self {
        case let .double(v): v
        case let .int(v): Double(v)
        case let .bool(v): v ? 1 : 0
        case let .string(v): Double(v)
        case .null: nil
        }
    }

    public var int: Int? { double.map { Int($0.rounded()) } }
    public var bool: Bool? { int.map { $0 != 0 } }

    public var string: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    public var description: String {
        switch self {
        case let .bool(v): "\(v)"
        case let .int(v): "\(v)"
        case let .double(v): "\(v)"
        case let .string(v): "\"\(v)\""
        case .null: "null"
        }
    }
}

/// Address of a characteristic: accessory id + instance id.
public struct CharacteristicID: Hashable, Sendable, CustomStringConvertible {
    public let aid: Int
    public let iid: Int

    public init(aid: Int, iid: Int) {
        self.aid = aid
        self.iid = iid
    }

    public var description: String { "\(aid).\(iid)" }
}

public struct CharacteristicValue: Codable, Sendable {
    public let aid: Int
    public let iid: Int
    public let value: HAPValue?
    public let status: Int?

    public var id: CharacteristicID { CharacteristicID(aid: aid, iid: iid) }
}

struct CharacteristicsBody: Codable {
    let characteristics: [CharacteristicValue]
}

public struct Characteristic: Codable, Sendable {
    public let iid: Int
    public let type: String
    public let perms: [String]
    public let format: String?
    public var value: HAPValue?
    public let unit: String?
    public let minValue: Double?
    public let maxValue: Double?
    public let minStep: Double?
    public let validValues: [Int]?
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case iid, type, perms, format, value, unit, minValue, maxValue, minStep, description
        case validValues = "valid-values"
    }

    public var uuid: String { HAPUUID.normalize(type) }
    public var readable: Bool { perms.contains("pr") }
    public var writable: Bool { perms.contains("pw") }
    public var notifies: Bool { perms.contains("ev") }
}

public struct Service: Codable, Sendable {
    public let iid: Int
    public let type: String
    public var characteristics: [Characteristic]

    public var uuid: String { HAPUUID.normalize(type) }

    public func characteristic(_ type: String) -> Characteristic? {
        let wanted = HAPUUID.normalize(type)
        return characteristics.first { $0.uuid == wanted }
    }
}

public struct Accessory: Codable, Sendable {
    public let aid: Int
    public var services: [Service]

    public func services(_ type: String) -> [Service] {
        let wanted = HAPUUID.normalize(type)
        return services.filter { $0.uuid == wanted }
    }

    /// Name from the Accessory Information service.
    public var name: String? {
        services(HAPUUID.accessoryInformation).first?.characteristic(HAPUUID.name)?.value?.string
    }
}

public struct AccessoryDatabase: Codable, Sendable {
    public var accessories: [Accessory]
}

public enum HAPUUID {
    static let baseSuffix = "-0000-1000-8000-0026BB765291"

    /// "4A" / "0000004A" / full UUID → upper-case full UUID.
    public static func normalize(_ type: String) -> String {
        let t = type.uppercased()
        if t.count == 36 { return t }
        return String(repeating: "0", count: max(0, 8 - t.count)) + t + baseSuffix
    }

    public static let accessoryInformation = "3E"
    public static let name = "23"
}
