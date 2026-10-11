import CryptoKit
import Foundation

/// Long-term HAP pairing credentials. The JSON keys match aiohomekit's pairing
/// data, so files written by `ecobee-pair` (ecobee-local) load unchanged and
/// files written here work with aiohomekit / ecobee-local.
public struct Pairing: Codable, Sendable, Identifiable, Equatable {
    public var accessoryPairingID: String
    public var accessoryLTPK: String
    public var controllerPairingID: String
    public var controllerLTSK: String
    public var controllerLTPK: String
    public var accessoryIP: String?
    public var accessoryPort: Int?
    public var connection: String?
    public var label: String?
    public var name: String?

    public var id: String { accessoryPairingID }
    public var displayName: String { name ?? label ?? accessoryPairingID }

    enum CodingKeys: String, CodingKey {
        case accessoryPairingID = "AccessoryPairingID"
        case accessoryLTPK = "AccessoryLTPK"
        case controllerPairingID = "iOSPairingId"
        case controllerLTSK = "iOSDeviceLTSK"
        case controllerLTPK = "iOSDeviceLTPK"
        case accessoryIP = "AccessoryIP"
        case accessoryPort = "AccessoryPort"
        case connection = "Connection"
        case label = "_label"
        case name = "_name"
    }

    func signingKey() throws -> Curve25519.Signing.PrivateKey {
        guard let raw = Data(hex: controllerLTSK) else { throw HAPError.malformedTLV }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    func accessoryKey() throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(hex: accessoryLTPK) else { throw HAPError.malformedTLV }
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Accepts a single aiohomekit pairing object, or an aiohomekit
    /// `pairings.json` map of alias → pairing object.
    public static func load(from url: URL) throws -> [Pairing] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(Pairing.self, from: data) { return [single] }
        let map = try decoder.decode([String: Pairing].self, from: data)
        return map.sorted { $0.key < $1.key }.map { alias, pairing in
            var p = pairing
            if p.label == nil { p.label = alias }
            return p
        }
    }
}

/// Stores one JSON file per pairing (mode 0600) under Application Support.
public struct PairingStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "EcobeeBar/pairings", directoryHint: .isDirectory)
    }

    /// ecobee-local's default credentials folder.
    public static var ecobeeLocalDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "ecobee-local", directoryHint: .isDirectory)
    }

    public init(directory: URL = PairingStore.defaultDirectory) {
        self.directory = directory
    }

    public func all() -> [Pairing] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { (try? Pairing.load(from: $0)) ?? [] }
    }

    public func save(_ pairing: Pairing) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = fileURL(for: pairing.accessoryPairingID)
        try encoder.encode(pairing).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(_ pairing: Pairing) throws {
        let url = fileURL(for: pairing.accessoryPairingID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Pairing files found in ecobee-local's folder that are not stored here yet.
    public func importableFromEcobeeLocal() -> [Pairing] {
        let known = Set(all().map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.ecobeeLocalDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .flatMap { (try? Pairing.load(from: $0)) ?? [] }
            .filter { !known.contains($0.id) }
    }

    private func fileURL(for id: String) -> URL {
        directory.appending(path: id.replacingOccurrences(of: ":", with: "") + ".json")
    }
}
