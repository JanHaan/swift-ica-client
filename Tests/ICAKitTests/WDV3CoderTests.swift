import Testing
import Foundation
@testable import ICAKit

/// V3 coder (docs/30-winstation.md §12.3): encoder → decoder round trips with state comparison, plus a
/// few bit-exact pins of the spec readings.

private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next()) } }
    /// Skewed bytes (roughly geometric ranks), few long repeats: exercises literal classes and rebuilds.
    mutating func skewed(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8(min(255, (next() | 1 << 12).trailingZeroBitCount * 20 + Int(next() % 20))) }
    }
}

private func expectSameState(_ a: WDV3Coder, _ b: WDV3Coder, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a.position == b.position, sourceLocation: sourceLocation)
    #expect(a.history == b.history, sourceLocation: sourceLocation)
    #expect(a.tables == b.tables, sourceLocation: sourceLocation)
    #expect(a.matches.map(\.remaining) == b.matches.map(\.remaining), sourceLocation: sourceLocation)
    #expect(a.matches.map(\.source) == b.matches.map(\.source), sourceLocation: sourceLocation)
    #expect(a.models.count == b.models.count, sourceLocation: sourceLocation)
    for (x, y) in zip(a.models, b.models) {
        #expect(x.rankToByte == y.rankToByte && x.byteToRank == y.byteToRank, sourceLocation: sourceLocation)
        #expect(x.counts == y.counts && x.targets == y.targets, sourceLocation: sourceLocation)
        #expect(x.countdown == y.countdown && x.period == y.period, sourceLocation: sourceLocation)
        #expect(x.codeBits == y.codeBits && x.codeLength == y.codeLength, sourceLocation: sourceLocation)
    }
}

/// Encodes each (model, data) segment with one coder and decodes it with another, checking output,
/// consumed size and full state after every segment. Returns the compressed segments.
@discardableResult
private func roundTrip(power: Int, models: Int = 4, _ segments: [(Int, [UInt8])],
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> [[UInt8]] {
    var enc = try WDV3Coder(power: power, models: models)
    var dec = try WDV3Coder(power: power, models: models)
    var out: [[UInt8]] = []
    for (m, data) in segments {
        let z = try enc.encode(model: m, data)
        // Trailing garbage after the segment must not be consumed.
        let (plain, used) = try dec.decode(model: m, length: data.count, from: z + [0xA5, 0x5A, 0xFF], offset: 0, end: z.count + 3)
        #expect(plain == data, sourceLocation: sourceLocation)
        #expect(used == z.count, sourceLocation: sourceLocation)
        expectSameState(enc, dec, sourceLocation: sourceLocation)
        out.append(z)
    }
    return out
}

@Test func v3CoderRoundTripRandomAndRepetitive() throws {
    var rng = SplitMix(state: 1)
    let random = rng.bytes(3000)
    let text = Array(String(repeating: "Vorbereiten der Verbindung... Bitte warten. ", count: 40).utf8)
    let zeros = [UInt8](repeating: 0, count: 5000)
    let z = try roundTrip(power: 16, [(0, random), (1, text), (0, zeros), (2, random), (1, text + random.prefix(100))])
    #expect(z[1].count < text.count / 8)  // the repeats became matches
    #expect(z[2].count < 16)
    #expect(z[3].count < 200)  // the second copy of `random` is one long match
}

@Test func v3CoderRoundTripManySmallSegmentsInterleavedModels() throws {
    var rng = SplitMix(state: 2)
    var segments: [(Int, [UInt8])] = []
    let phrases = (0..<8).map { _ in rng.bytes(Int(rng.next() % 40) + 1) }
    for i in 0..<400 {
        let n = Int(rng.next() % 5)
        var data: [UInt8] = []
        for _ in 0...n { data += phrases[Int(rng.next() % 8)] }
        if i % 7 == 0 { data += rng.bytes(Int(rng.next() % 30)) }
        segments.append((Int(rng.next() % 4), data))
    }
    segments.append((3, []))
    try roundTrip(power: 16, segments)
}

@Test func v3CoderMatchPendingAcrossSegments() throws {
    var rng = SplitMix(state: 3)
    let r = rng.bytes(200)
    var enc = try WDV3Coder(power: 16, models: 2)
    var dec = try WDV3Coder(power: 16, models: 2)
    func step(_ m: Int, _ data: [UInt8]) throws -> [UInt8] {
        let z = try enc.encode(model: m, data)
        let (plain, used) = try dec.decode(model: m, length: data.count, from: z, offset: 0, end: z.count)
        #expect(plain == data && used == z.count)
        expectSameState(enc, dec)
        return z
    }
    // Segment 1 ends inside a repeat of r: the match is left pending (remaining 0 at the segment end).
    _ = try step(0, r + r[0..<120])
    #expect(enc.matches[0].remaining == 0)
    // Segment 2 (another model: the match state is shared) continues the repeat: bit 0 + one length.
    let z2 = try step(1, Array(r[120..<180]))
    #expect(z2.count <= 3)
    #expect(enc.matches[0].remaining == 0)  // ended at the segment end again
    // Segment 3 does not continue it: bit 1, then a literal without context.
    _ = try step(0, [r[180] ^ 0xFF] + rng.bytes(20))
    #expect(enc.matches[0].remaining == -1)
}

@Test func v3CoderPendingMatchStatePerModelOption() throws {
    var options = WDV3CoderOptions()
    options.sharedMatchState = false
    var rng = SplitMix(state: 4)
    let r = rng.bytes(100)
    var enc = try WDV3Coder(power: 16, models: 2, options: options)
    var dec = try WDV3Coder(power: 16, models: 2, options: options)
    for (m, data) in [(0, r + r[0..<50]), (1, rng.bytes(30)), (0, Array(r[50..<90]))] {
        let z = try enc.encode(model: m, data)
        #expect(try dec.decode(model: m, length: data.count, from: z, offset: 0, end: z.count).output == data)
        expectSameState(enc, dec)
    }
}

@Test func v3CoderHistoryWrapsAtSegmentStart() throws {
    var rng = SplitMix(state: 5)
    let block = rng.bytes(300)
    var enc = try WDV3Coder(power: 12, models: 1)  // usable history 4 ..< 4096
    var dec = try WDV3Coder(power: 12, models: 1)
    var positions: [Int] = []
    for i in 0..<12 {
        // Repeats of `block` leave context entries that point past the write position after a wrap.
        let data = Array((0..<4).flatMap { _ in block }.prefix(1000)) + rng.bytes(i)
        let z = try enc.encode(model: 0, data)
        #expect(try dec.decode(model: 0, length: data.count, from: z, offset: 0, end: z.count).output == data)
        expectSameState(enc, dec)
        positions.append(enc.position)
    }
    #expect(positions.prefix(4) == [1004, 2005, 3007, 1007])  // 4th segment: free 1089 ≤ 2048 → back to 4
    #expect(positions.allSatisfy { $0 <= 4096 })
    // Without a wrap, a segment larger than the free space is an error.
    var c = try WDV3Coder(power: 12, models: 1)
    try c.encode(model: 0, rng.bytes(1500))
    #expect(throws: WDV3CoderError.historyOverflow(needed: 2600, free: 2592)) { try c.encode(model: 0, rng.bytes(2600)) }
}

@Test func v3CoderHuffmanRebuildsAndPeriodGrowth() throws {
    var rng = SplitMix(state: 6)
    var segments: [(Int, [UInt8])] = []
    for _ in 0..<12 { segments.append((0, rng.skewed(4000))) }
    for _ in 0..<4 { segments.append((1, rng.bytes(3000))) }
    try roundTrip(power: 16, models: 2, segments)
    var enc = try WDV3Coder(power: 16, models: 2)
    for (m, d) in segments { try enc.encode(model: m, d) }
    #expect(enc.models[0].period == 500)
    // The skewed source moved the code away from the initial one.
    #expect(enc.models[0].codeLength != [8, 8, 7, 6, 5, 4, 3, 2, 1])
}

@Test func v3LiteralModelInitialStateAndSchedule() {
    var model = WDV3LiteralModel(WDV3CoderOptions())
    #expect(model.codeLength == [8, 8, 7, 6, 5, 4, 3, 2, 1])
    #expect(model.codeBits[8] == 0b1 && model.codeBits[7] == 0b10 && model.codeBits[0] == 0b1000_0000)
    #expect(model.counts == [1, 1, 2, 3, 5, 9, 17, 33, 65])  // halved by the initial build
    var countdowns: [Int] = []
    for _ in 0..<3000 {
        let before = model.countdown
        model.tick(WDV3CoderOptions())
        if before == 0 { countdowns.append(model.countdown) }
    }
    #expect(countdowns.prefix(7) == [75, 112, 168, 252, 378, 500, 500])
    // Swap targets: class 3 (ranks 4-7) rotates through class 2 (ranks 2, 3).
    var m = WDV3LiteralModel(WDV3CoderOptions())
    m.update(rank: 5, start: 0, end: 8, WDV3CoderOptions())
    #expect(m.rankToByte[2] == 5 && m.rankToByte[5] == 2 && m.targets[3] == 3)
    m.update(rank: 6, start: 8, end: 15, WDV3CoderOptions())
    #expect(m.rankToByte[3] == 6 && m.targets[3] == 2)
}

@Test func v3CoderFirstLiteralIsBitExact() throws {
    // Fresh coder: the all-zero context matches the zero entry (tag 0) predicting 0x00 → miss flag 1, then
    // 'A' = rank 65, class 7: code 0,1 and 6 offset bits 000001 (LSB first) → 9 bits.
    var c = try WDV3Coder(power: 16, models: 1)
    #expect(try c.encode(model: 0, [0x41]) == [0x0D, 0x00])
    // A fresh zero byte is a hit on that zero entry: flag 0, history[4] (still 0) equals the prediction,
    // so it is a match of length 1 (gamma "1").
    var d = try WDV3Coder(power: 16, models: 1)
    #expect(try d.encode(model: 0, [0x00]) == [0x02])
}

@Test func v3LengthCodeEscapeGroups() throws {
    for v in Array(1...300) + [16383, 16384, 40000, 65535, 65536] {
        var w = WDV3BitWriter()
        WDV3Coder.writeLength(v, &w)
        var r = WDV3BitReader(w.bytes, start: 0, end: w.bytes.count)
        #expect(try WDV3Coder.readLength(&r) == v)
        #expect(r.bit == w.bit)
    }
    var w = WDV3BitWriter()
    WDV3Coder.writeLength(128, &w)
    #expect(w.bit == 15)  // 7 zero bits, low group 0000000, gamma(1)
    var big = WDV3BitWriter()
    WDV3Coder.writeLength(65537, &big)
    var r = WDV3BitReader(big.bytes, start: 0, end: big.bytes.count)
    #expect(throws: WDV3CoderError.badLength) { try WDV3Coder.readLength(&r) }
    var four = WDV3BitWriter()
    for _ in 0..<4 { four.write(0, 7); four.write(1, 7) }
    four.write(1, 1)
    var r4 = WDV3BitReader(four.bytes, start: 0, end: four.bytes.count)
    #expect(throws: WDV3CoderError.badLength) { try WDV3Coder.readLength(&r4) }
}

/// Builds a V3 frame: data segments in order, then the descriptors (given in read order) reversed.
struct V3FrameBuilder {
    var data: [UInt8] = []
    var readOrder: [UInt8] = []
    mutating func special(_ cmd: UInt8, _ args: [UInt8]) { readOrder += [0xF8, UInt8(args.count), cmd] + args }
    mutating func segment(channel: UInt8, complete: Bool, compressed: Bool, value: Int, _ bytes: [UInt8]) {
        readOrder.append(channel << 2 | (complete ? 2 : 0) | (compressed ? 1 : 0))
        readOrder += WDV3Reducer.varint(value)
        data += bytes
    }
    var frame: [UInt8] { data + readOrder.reversed() }
}

@Test func v3ExpanderDecodesCompressedAndRecompressSegments() throws {
    var rng = SplitMix(state: 7)
    var sender = try WDV3Coder(power: 16, models: 4)  // plays the peer's reducer
    var expander = try WDV3Expander(power: 16)
    let command: [UInt8] = [0x37, 0x40]
    let vc = Array("hello thinwire, hello thinwire, hello".utf8) + rng.bytes(50)
    // Frame 1: DEFINE(4), ASSIGN(0x3F → 1), ASSIGN(9 → 2); recompress WD bytes; compressed VC; compressed WD.
    var f1 = V3FrameBuilder()
    f1.special(0, [4])
    f1.special(1, [0x3F, 1])
    f1.special(1, [9, 2])
    try sender.encode(model: 1, command)  // recompress: model update only, output discarded
    f1.segment(channel: 0x3F, complete: true, compressed: false, value: command.count << 1 | 1, command)
    f1.segment(channel: 9, complete: true, compressed: true, value: vc.count, try sender.encode(model: 2, vc))
    f1.segment(channel: 0x3F, complete: true, compressed: true, value: 2, try sender.encode(model: 1, command))
    #expect(try expander.expand(f1.frame) == command + WDBuild.virtualWrite(channel: 9, vc) + command)
    #expect(expander.assignments == [0x3F: 1, 9: 2] && expander.coder?.modelCount == 4)
    // Frame 2: a VC write in two compressed fragments, the second one continuing a match of the first.
    let long = Array((0..<6).flatMap { _ in vc })
    var f2 = V3FrameBuilder()
    f2.segment(channel: 9, complete: false, compressed: true, value: 200, try sender.encode(model: 2, Array(long[0..<200])))
    f2.segment(channel: 9, complete: true, compressed: true, value: long.count - 200,
               try sender.encode(model: 2, Array(long[200...])))
    #expect(try expander.expand(f2.frame) == WDBuild.virtualWrite(channel: 9, long))
    #expect(expander.compressedSegments == 4 && expander.recompressSegments == 1)
    expectSameState(sender, expander.coder!)
}

@Test func v3ExpanderWithoutCoderStillRejectsCompression() throws {
    var expander = WDV3Expander()
    var f = V3FrameBuilder()
    f.segment(channel: 9, complete: true, compressed: false, value: 2 << 1 | 1, [1, 2])
    #expect(throws: WDV3Expander.Failure.recompressRequested(channel: 9)) { _ = try expander.expand(f.frame) }
    var coded = try WDV3Expander(power: 16)
    var g = V3FrameBuilder()
    g.segment(channel: 0x3D, complete: true, compressed: true, value: 4, [0, 0, 0])
    #expect(throws: WDV3Expander.Failure.thinwireAwareSegment) { _ = try coded.expand(g.frame) }
}
