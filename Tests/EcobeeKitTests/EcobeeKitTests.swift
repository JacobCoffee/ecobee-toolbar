import EcobeeKit
import Foundation
import Testing

@Test func framerReassemblesLinesSplitAcrossReads() {
    var framer = LineFramer()
    let stream = Data(#"{"a":1}"#.utf8) + [0x0A] + Data(#"{"b":2}"#.utf8) + [0x0A, 0x0A] + Data(#"{"c""#.utf8)
    // Feed one byte at a time, as a worst-case socket would.
    var lines: [String] = []
    for byte in stream {
        lines += framer.append(Data([byte])).map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(lines == [#"{"a":1}"#, #"{"b":2}"#])
    // The partial third record completes on the next read.
    #expect(framer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"c":3}"#])
}

@Test func rangeSnapsToStepAndClampsToBounds() {
    let range = TemperatureRange(minC: 7.2, maxC: 33.3, stepC: 0.5)
    #expect(range.clamp(21.26) == 21.5)
    #expect(range.clamp(2) == 7.2)
    #expect(range.clamp(40) == 33.3)
    // Zero step from sloppy metadata must not divide by zero.
    #expect(TemperatureRange(minC: 10, maxC: 30, stepC: 0).clamp(22.04) == 22.0)
}
