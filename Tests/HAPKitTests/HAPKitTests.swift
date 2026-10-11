import BigInt
import CryptoKit
import Foundation
@testable import HAPKit
import Testing

@Test func srpMultiplierMatchesHomeKitConstant() {
    // CLIENT_K_VALUE from aiohomekit: H(N | PAD(g)) for the 3072-bit group.
    let expected = "a9c2e2559bf0ebb53f0cbbf62282906bede7f2182f00678211fbd5bde5b285033a4993503b87397f9be5ec02080fedbc0835587ad039060879b8621e8c3659e0"
    #expect(SRPClient.k.serialize().hex == expected)
}

@Test func srpClientAgreesWithServerComputation() throws {
    // Simulate the accessory side of SRP-6a and check both derive the same K and proofs.
    let N = SRPClient.N, g = SRPClient.g
    let salt = randomBytes(16)
    let code = "123-45-678"
    let x = BigUInt(sha512(salt, sha512(Data("Pair-Setup:\(code)".utf8))))
    let v = g.power(x, modulus: N)
    let b = BigUInt(randomBytes(32))
    let B = SRPClient.pad((SRPClient.k * v + g.power(b, modulus: N)) % N, to: 384)

    let client = SRPClient(password: code)
    let session = try client.session(salt: salt, serverPublicKey: B)

    let u = BigUInt(sha512(client.A, B))
    let S = (BigUInt(client.A) * v.power(u, modulus: N)).power(b, modulus: N)
    #expect(session.K == sha512(SRPClient.pad(S, to: 384)))
}

@Test func tlvFragmentsLongValuesAndRoundTrips() throws {
    let key = randomBytes(384)
    var tlv = TLV8()
    tlv.append(.state, byte: 3)
    tlv.append(.publicKey, key)
    tlv.append(.proof, Data(repeating: 7, count: 64))
    let encoded = tlv.encoded()
    #expect(encoded.count == 3 + (2 + 255) + (2 + 129) + (2 + 64))
    let decoded = try TLV8.decode(encoded)
    #expect(decoded.byte(.state) == 3)
    #expect(decoded[.publicKey] == key)
    #expect(decoded[.proof]?.count == 64)
}

@Test func tlvRejectsTruncatedInput() {
    #expect(throws: HAPError.malformedTLV) { try TLV8.decode(Data([0x06, 0x05, 0x01])) }
}

@Test func sessionCryptoFramesRoundTripAcrossChunkBoundaries() throws {
    let secret = randomBytes(32)
    var controller = SessionCrypto(sharedSecret: secret)
    // Accessory side: its read key is our write key.
    let mirror = SessionCrypto(sharedSecret: secret)
    var accessory = SessionCrypto(writeKey: mirror.readKey, readKey: mirror.writeKey)

    let message = randomBytes(2500)
    var wire = controller.seal(message)
    #expect(wire.count == 2500 + 3 * (2 + 16))
    // Deliver in two partial pieces; the partial frame must stay buffered.
    var buffer = wire.prefix(1500)
    var received = try accessory.open(&buffer)
    buffer += wire.dropFirst(1500)
    received += try accessory.open(&buffer)
    #expect(received == message)
    #expect(buffer.isEmpty)

    wire = controller.seal(Data("second".utf8))
    var tampered = wire
    tampered[tampered.startIndex + 3] ^= 0xFF
    #expect(throws: HAPError.decryptionFailed) { try accessory.open(&tampered) }
}

@Test func httpParserHandlesEventsChunkedAndPartialMessages() throws {
    var parser = HTTPParser()
    let eventBody = #"{"characteristics":[{"aid":1,"iid":9,"value":2}]}"#
    let event = "EVENT/1.0 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: \(eventBody.utf8.count)\r\n\r\n" + eventBody
    let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
    let noContent = "HTTP/1.1 204 No Content\r\n\r\n"
    let all = Data((event + chunked + noContent).utf8)

    parser.append(all.prefix(30))
    #expect(try parser.next() == nil)
    parser.append(all.dropFirst(30))

    let first = try #require(try parser.next())
    #expect(first.isEvent && first.body == Data(eventBody.utf8))
    let second = try #require(try parser.next())
    #expect(second.status == 200 && String(decoding: second.body, as: UTF8.self) == "hello world")
    let third = try #require(try parser.next())
    #expect(third.status == 204 && third.body.isEmpty)
    #expect(try parser.next() == nil)
}

@Test func pairingDecodesEcobeeLocalFile() throws {
    let json = """
    {"AccessoryPairingID": "AA:BB:CC:DD:EE:FF", "AccessoryLTPK": "00", "iOSPairingId": "c0ffee",
     "iOSDeviceLTSK": "11", "iOSDeviceLTPK": "22", "AccessoryIP": "10.0.0.5", "AccessoryPort": 1200,
     "Connection": "IP", "_label": "main", "_name": "Main Floor"}
    """
    let url = FileManager.default.temporaryDirectory.appending(path: "pair-\(UUID()).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let pairing = try #require(try Pairing.load(from: url).first)
    #expect(pairing.id == "AA:BB:CC:DD:EE:FF")
    #expect(pairing.displayName == "Main Floor")
    #expect(pairing.accessoryPort == 1200)
}
