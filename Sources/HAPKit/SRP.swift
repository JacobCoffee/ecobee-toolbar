import BigInt
import CryptoKit
import Foundation

/// SRP-6a client with the HomeKit parameters: RFC 5054 3072-bit group, g = 5,
/// SHA-512, username "Pair-Setup". Byte padding matches aiohomekit, which is
/// proven against ecobee firmware: A and S padded to 384 bytes, salt to 16.
struct SRPClient {
    static let N = BigUInt(Data(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510\
        15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
        BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)!)
    static let g = BigUInt(5)
    static let length = 384
    static let username = "Pair-Setup"

    /// k = H(N | PAD(g))
    static let k = BigUInt(sha512(N.serialize(), pad(g, to: length)))

    let password: String
    let a: BigUInt
    let A: Data

    init(password: String, privateKey: BigUInt? = nil) {
        self.password = password
        a = privateKey ?? BigUInt(randomBytes(32))
        A = Self.pad(Self.g.power(a, modulus: Self.N), to: Self.length)
    }

    struct Session {
        let K: Data
        let M1: Data
        let expectedM2: Data
    }

    func session(salt rawSalt: Data, serverPublicKey B: Data) throws -> Session {
        let Bn = BigUInt(B)
        guard Bn % Self.N != 0 else { throw HAPError.invalidProof }
        let salt = Self.pad(BigUInt(rawSalt), to: 16)
        let u = BigUInt(sha512(A, B))
        guard u != 0 else { throw HAPError.invalidProof }
        let x = BigUInt(sha512(salt, sha512(Data("\(Self.username):\(password)".utf8))))
        let v = Self.g.power(x, modulus: Self.N)
        let kv = (Self.k * v) % Self.N
        let base = (Bn % Self.N + Self.N - kv) % Self.N
        let S = base.power(a + u * x, modulus: Self.N)
        let K = sha512(Self.pad(S, to: Self.length))

        let hN = sha512(Self.N.serialize())
        let hg = sha512(Self.g.serialize())
        let hGroup = Data(zip(hN, hg).map { $0 ^ $1 })
        let M1 = sha512(hGroup, sha512(Data(Self.username.utf8)), salt, A, B, K)
        return Session(K: K, M1: M1, expectedM2: sha512(A, M1, K))
    }

    static func pad(_ n: BigUInt, to length: Int) -> Data {
        let bytes = n.serialize()
        return bytes.count >= length ? bytes : Data(count: length - bytes.count) + bytes
    }
}

func sha512(_ parts: Data...) -> Data {
    var h = SHA512()
    for p in parts { h.update(data: p) }
    return Data(h.finalize())
}

func randomBytes(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.filter { !$0.isWhitespace })
        guard chars.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
