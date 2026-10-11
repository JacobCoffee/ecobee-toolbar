import CryptoKit
import Foundation

private enum Method: UInt8 {
    case pairSetup = 0
    case pairSetupWithAuth = 1
    case removePairing = 4
}

extension HAPConnection {
    /// Pair Setup (M1–M6) over a fresh plaintext connection. Returns new
    /// long-term credentials; the connection should be closed afterwards.
    public func pairSetup(code rawCode: String, withAuth: Bool) async throws -> Pairing {
        let digits = rawCode.filter(\.isNumber)
        guard digits.count == 8 else { throw HAPError.invalidSetupCode }
        let d = Array(digits)
        let code = "\(String(d[0..<3]))-\(String(d[3..<5]))-\(String(d[5..<8]))"

        // M1 → M2
        var m1 = TLV8()
        m1.append(.state, byte: 1)
        m1.append(.method, byte: (withAuth ? Method.pairSetupWithAuth : .pairSetup).rawValue)
        let m2 = try await postTLV("/pair-setup", m1)
        try check(m2, state: 2)
        guard let salt = m2[.salt], let serverKey = m2[.publicKey] else { throw HAPError.malformedTLV }

        // M3 → M4
        let srp = SRPClient(password: code)
        let session = try srp.session(salt: salt, serverPublicKey: serverKey)
        var m3 = TLV8()
        m3.append(.state, byte: 3)
        m3.append(.publicKey, srp.A)
        m3.append(.proof, session.M1)
        let m4 = try await postTLV("/pair-setup", m3)
        try check(m4, state: 4)
        guard m4[.proof] == session.expectedM2 else { throw HAPError.invalidProof }

        // M5 → M6
        let encryptKey = HAPCrypto.hkdf(session.K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let controllerID = UUID().uuidString.uppercased()
        let ltsk = Curve25519.Signing.PrivateKey()
        let ltpk = ltsk.publicKey.rawRepresentation
        let controllerX = HAPCrypto.hkdf(session.K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let signature = try ltsk.signature(for: controllerX.data + Data(controllerID.utf8) + ltpk)
        let sub = TLV8([(.identifier, Data(controllerID.utf8)), (.publicKey, ltpk), (.signature, signature)])
        var m5 = TLV8()
        m5.append(.state, byte: 5)
        m5.append(.encryptedData, HAPCrypto.seal(sub.encoded(), key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg05")))
        let m6 = try await postTLV("/pair-setup", m5)
        try check(m6, state: 6)
        guard let encrypted = m6[.encryptedData] else { throw HAPError.malformedTLV }
        let accessory = try TLV8.decode(HAPCrypto.open(encrypted, key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg06")))
        guard let accID = accessory[.identifier], let accLTPK = accessory[.publicKey], let accSig = accessory[.signature]
        else { throw HAPError.malformedTLV }
        let accessoryX = HAPCrypto.hkdf(session.K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let accKey = try Curve25519.Signing.PublicKey(rawRepresentation: accLTPK)
        guard accKey.isValidSignature(accSig, for: accessoryX.data + accID + accLTPK) else { throw HAPError.invalidSignature }

        return Pairing(
            accessoryPairingID: String(decoding: accID, as: UTF8.self),
            accessoryLTPK: accLTPK.hex,
            controllerPairingID: controllerID,
            controllerLTSK: ltsk.rawRepresentation.hex,
            controllerLTPK: ltpk.hex,
            connection: "IP"
        )
    }

    /// Pair Verify (M1–M4); on success the connection is encrypted.
    public func pairVerify(_ pairing: Pairing) async throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let myPub = ephemeral.publicKey.rawRepresentation

        var m1 = TLV8()
        m1.append(.state, byte: 1)
        m1.append(.publicKey, myPub)
        let m2 = try await postTLV("/pair-verify", m1)
        try check(m2, state: 2)
        guard let accPub = m2[.publicKey], let encrypted = m2[.encryptedData] else { throw HAPError.malformedTLV }

        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: accPub)
        ).withUnsafeBytes { Data($0) }
        let sessionKey = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = try TLV8.decode(HAPCrypto.open(encrypted, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg02")))
        guard let accID = sub[.identifier], let accSig = sub[.signature] else { throw HAPError.malformedTLV }
        guard String(decoding: accID, as: UTF8.self) == pairing.accessoryPairingID else { throw HAPError.identifierMismatch }
        guard try pairing.accessoryKey().isValidSignature(accSig, for: accPub + accID + myPub) else {
            throw HAPError.invalidSignature
        }

        let controllerID = Data(pairing.controllerPairingID.utf8)
        let signature = try pairing.signingKey().signature(for: myPub + controllerID + accPub)
        let reply = TLV8([(.identifier, controllerID), (.signature, signature)])
        var m3 = TLV8()
        m3.append(.state, byte: 3)
        m3.append(.encryptedData, HAPCrypto.seal(reply.encoded(), key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg03")))
        let m4 = try await postTLV("/pair-verify", m3)
        try check(m4, state: 4)
        enableEncryption(sharedSecret: shared)
    }

    /// Remove our own pairing so the accessory can be paired again.
    /// Requires an encrypted (verified) connection.
    public func removePairing(_ pairing: Pairing) async throws {
        var m1 = TLV8()
        m1.append(.state, byte: 1)
        m1.append(.method, byte: Method.removePairing.rawValue)
        m1.append(.identifier, Data(pairing.controllerPairingID.utf8))
        let m2 = try await postTLV("/pairings", m1)
        try check(m2, state: 2)
    }

    private func check(_ tlv: TLV8, state: UInt8) throws {
        if let error = tlv.byte(.error) { throw HAPError.accessory(code: error) }
        guard tlv.byte(.state) == state else { throw HAPError.unexpectedState(expected: state, got: tlv.byte(.state)) }
    }
}

extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}
