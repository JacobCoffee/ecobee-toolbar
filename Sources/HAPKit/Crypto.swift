import CryptoKit
import Foundation

enum HAPCrypto {
    static func hkdf(_ ikm: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Pairing messages use an 8-byte ASCII nonce ("PS-Msg05") left-padded to 12 bytes.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8))
    }

    /// Session frames use a little-endian 64-bit counter left-padded to 12 bytes.
    static func nonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var le = counter.littleEndian
        return try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &le, count: 8))
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) -> Data {
        let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ data: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw HAPError.decryptionFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw HAPError.decryptionFailed
        }
    }
}

/// Per-direction ChaCha20-Poly1305 framing for an established HAP session.
/// Frame: UInt16 LE length (≤1024) | ciphertext | 16-byte tag; the length is the AAD.
struct SessionCrypto {
    static let maxFrame = 1024

    let writeKey: SymmetricKey
    let readKey: SymmetricKey
    private var writeCounter: UInt64 = 0
    private var readCounter: UInt64 = 0

    init(sharedSecret: Data) {
        writeKey = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
        readKey = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
    }

    mutating func seal(_ plaintext: Data) -> Data {
        var out = Data()
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: Self.maxFrame, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            var length = UInt16(end - offset).littleEndian
            let aad = Data(bytes: &length, count: 2)
            out += aad
            out += HAPCrypto.seal(plaintext[offset..<end], key: writeKey, nonce: HAPCrypto.nonce(counter: writeCounter), aad: aad)
            writeCounter += 1
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    init(writeKey: SymmetricKey, readKey: SymmetricKey) {
        self.writeKey = writeKey
        self.readKey = readKey
    }

    /// Decrypts and removes every complete frame at the front of `buffer`.
    mutating func open(_ buffer: inout Data) throws -> Data {
        var out = Data()
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8
            let total = 2 + length + 16
            guard buffer.count >= total else { break }
            let aad = buffer[start..<start + 2]
            let sealed = buffer[start + 2..<start + total]
            out += try HAPCrypto.open(Data(sealed), key: readKey, nonce: HAPCrypto.nonce(counter: readCounter), aad: Data(aad))
            readCounter += 1
            buffer = Data(buffer[(start + total)...])
        }
        return out
    }
}
