import Foundation

extension HAPConnection {
    public func accessories() async throws -> AccessoryDatabase {
        let response = try await request("GET", "/accessories")
        guard response.status == 200 else { throw HAPError.http(status: response.status) }
        return try JSONDecoder().decode(AccessoryDatabase.self, from: response.body)
    }

    public func read(_ ids: [CharacteristicID]) async throws -> [CharacteristicValue] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(\.description).joined(separator: ",")
        let response = try await request("GET", "/characteristics?id=\(list)")
        // 207 Multi-Status still carries per-characteristic values.
        guard response.status == 200 || response.status == 207 else { throw HAPError.http(status: response.status) }
        return try JSONDecoder().decode(CharacteristicsBody.self, from: response.body).characteristics
    }

    public func write(_ values: [CharacteristicID: HAPValue]) async throws {
        try await put(values.map { WriteItem(aid: $0.key.aid, iid: $0.key.iid, value: $0.value, ev: nil) })
    }

    public func subscribe(_ ids: [CharacteristicID], enabled: Bool = true) async throws {
        guard !ids.isEmpty else { return }
        try await put(ids.map { WriteItem(aid: $0.aid, iid: $0.iid, value: nil, ev: enabled) })
    }

    private struct WriteItem: Encodable {
        let aid: Int
        let iid: Int
        let value: HAPValue?
        let ev: Bool?
    }

    private struct WriteBody: Encodable {
        let characteristics: [WriteItem]
    }

    private func put(_ items: [WriteItem]) async throws {
        let body = try JSONEncoder().encode(WriteBody(characteristics: items))
        let response = try await request("PUT", "/characteristics", body: body)
        switch response.status {
        case 204, 200:
            return
        case 207:
            let result = try JSONDecoder().decode(CharacteristicsBody.self, from: response.body)
            if let failure = result.characteristics.first(where: { ($0.status ?? 0) != 0 }) {
                throw HAPError.characteristicStatus(failure.status ?? -1)
            }
        default:
            throw HAPError.http(status: response.status)
        }
    }
}
