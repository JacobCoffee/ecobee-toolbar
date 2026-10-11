import Foundation

/// HAP TLV8 item types (HAP spec, table 5-6).
public enum TLVType: UInt8, Sendable {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
    case separator = 0xFF
}

/// Ordered TLV8 list. Values longer than 255 bytes are split into consecutive
/// fragments of the same type on encode and merged on decode.
public struct TLV8: Sendable {
    public private(set) var items: [(TLVType.RawValue, Data)] = []

    public init() {}

    public init(_ pairs: [(TLVType, Data)]) {
        for (type, value) in pairs { append(type, value) }
    }

    public mutating func append(_ type: TLVType, _ value: Data) {
        items.append((type.rawValue, value))
    }

    public mutating func append(_ type: TLVType, byte: UInt8) {
        append(type, Data([byte]))
    }

    public subscript(type: TLVType) -> Data? {
        items.first { $0.0 == type.rawValue }?.1
    }

    public func byte(_ type: TLVType) -> UInt8? {
        self[type]?.first
    }

    public func encoded() -> Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty {
                out.append(contentsOf: [type, 0])
                continue
            }
            var offset = value.startIndex
            while offset < value.endIndex {
                let end = value.index(offset, offsetBy: 255, limitedBy: value.endIndex) ?? value.endIndex
                out.append(type)
                out.append(UInt8(end - offset))
                out.append(value[offset..<end])
                offset = end
            }
        }
        return out
    }

    public static func decode(_ data: Data) throws -> TLV8 {
        var tlv = TLV8()
        var index = data.startIndex
        var lastType: UInt8?
        var lastWasFull = false
        while index < data.endIndex {
            guard data.endIndex - index >= 2 else { throw HAPError.malformedTLV }
            let type = data[index]
            let length = Int(data[index + 1])
            let start = index + 2
            guard data.endIndex - start >= length else { throw HAPError.malformedTLV }
            let value = data[start..<start + length]
            if lastWasFull, type == lastType, !tlv.items.isEmpty {
                tlv.items[tlv.items.count - 1].1.append(value)
            } else {
                tlv.items.append((type, Data(value)))
            }
            lastType = type
            lastWasFull = length == 255
            index = start + length
        }
        return tlv
    }
}
