import Foundation

public enum HAPError: Error, LocalizedError, Sendable, Equatable {
    case malformedTLV
    case malformedHTTP
    case unexpectedState(expected: UInt8, got: UInt8?)
    /// TLV kTLVType_Error from the accessory.
    case accessory(code: UInt8)
    case invalidSetupCode
    case invalidProof
    case invalidSignature
    case identifierMismatch
    case decryptionFailed
    case connectionClosed
    case notConnected
    case timeout
    case http(status: Int)
    case characteristicStatus(Int)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .malformedTLV: "Malformed TLV8 payload"
        case .malformedHTTP: "Malformed HTTP response"
        case let .unexpectedState(expected, got): "Unexpected pairing state \(got.map(String.init) ?? "nil"), expected \(expected)"
        case let .accessory(code): Self.describe(accessoryError: code)
        case .invalidSetupCode: "Setup code must be 8 digits"
        case .invalidProof: "Accessory proof did not verify (wrong setup code?)"
        case .invalidSignature: "Accessory signature did not verify"
        case .identifierMismatch: "Accessory identity does not match the stored pairing"
        case .decryptionFailed: "Failed to decrypt accessory message"
        case .connectionClosed: "Connection closed"
        case .notConnected: "Not connected"
        case .timeout: "Timed out"
        case let .http(status): "HTTP \(status)"
        case let .characteristicStatus(status): "Characteristic write failed (HAP status \(status))"
        case let .unsupported(what): "Unsupported: \(what)"
        }
    }

    static func describe(accessoryError code: UInt8) -> String {
        switch code {
        case 0x01: "Accessory reported an unknown error"
        case 0x02: "Authentication failed (wrong setup code?)"
        case 0x03: "Accessory asked to back off; wait and retry"
        case 0x04: "Accessory has no room for more pairings"
        case 0x05: "Too many failed attempts; reset HomeKit on the thermostat"
        case 0x06: "Accessory is already paired (reset HomeKit on the thermostat to pair again)"
        case 0x07: "Accessory is busy pairing with another controller"
        default: "Accessory error \(code)"
        }
    }
}
