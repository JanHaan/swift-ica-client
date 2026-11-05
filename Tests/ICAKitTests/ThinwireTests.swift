import CoreGraphics
import Foundation
import Testing
@testable import ICAKit

// MARK: Primitives

@Test func thinwirePackedSizeForms() throws {
    let bytes: [UInt8] = [0x1D,                     // form 0: y=3, x=5
                          0x45, 0xC8,               // form 1: y=5, x=200
                          0x84, 0x38, 0x07, 0x80,   // form 2: y=0x438=1080, x=0x780=1920
                          0xC0, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00] // form 3: y=0x100, x=0x10000
    try bytes.withUnsafeBufferPointer { buf throws in
        var r = TWReader(buf)
        #expect(try r.packedSize() == (5, 3))
        #expect(try r.packedSize() == (200, 5))
        #expect(try r.packedSize() == (1920, 1080))
        #expect(try r.packedSize() == (0x10000, 0x100))
        #expect(r.remaining == 0)
    }
}

@Test func thinwireDeltaPointForms() throws {
    let bytes: [UInt8] = [0x1F,             // dx=-1
                          0x25,             // dy=5
                          0x43, 0xF0,       // dx=3, dy=-16
                          0x7E, 0x40,       // dy=-2, dx=64
                          0xBF, 0xFE, 0x01, 0x00, // dy=-2, dx=256
                          0x81, 0x00, 0xFF, 0x00] // dy=256, dx=-256
    try bytes.withUnsafeBufferPointer { buf throws in
        var r = TWReader(buf)
        #expect(try r.rawDelta() == TWPoint(-1, 0))
        #expect(try r.rawDelta() == TWPoint(0, 5))
        #expect(try r.rawDelta() == TWPoint(3, -16))
        #expect(try r.rawDelta() == TWPoint(64, -2))
        #expect(try r.rawDelta() == TWPoint(256, -2))
        #expect(try r.rawDelta() == TWPoint(-256, 256))
    }
    // Builder round trip through the accumulating current point.
    var b = ThinwireStreamBuilder()
    let points = [(10, 20), (5, 20), (5, 3), (300, -40), (1919, 1079), (0, 0)]
    for p in points { b.point(p.0, p.1) }
    try b.bytes.withUnsafeBufferPointer { buf throws in
        var r = TWReader(buf)
        var cur = TWPoint.zero
        for p in points { #expect(try r.point(&cur) == TWPoint(p.0, p.1)) }
    }
}

@Test func thinwireVarintAndUnderflow() throws {
    try [0xE5, 0x8E, 0x26, 0x80].withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) throws in
        var r = TWReader(buf)
        #expect(try r.varint() == 624_485)
        #expect(throws: TWError.self) { try r.varint() }
    }
}

@Test func thinwireRGB555Expansion() {
    #expect(TWColor.expand555(0x7C00) == 0xFF0000)
    #expect(TWColor.expand555(0x03E0) == 0x00FF00)
    #expect(TWColor.expand555(0x001F) == 0x0000FF)
    #expect(TWColor.expand555(0x4210) == 0x848484)
}

@Test func thinwireRecommendedCapabilityBlob() {
    let blob = [UInt8](ThinwireCapabilities.recommendedBlob())
    let expected: [UInt8] = [0x00, 0x0F, 0x04, 0x00,
                             0x0A, 0x00, 0x20, 0x00, 0x02, 0x00, 0x01, 0x00, 0x64, 0x00,
                             0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03, 0x00, 0x04, 0x00, 0x08, 0x00,
                             0x04, 0x00, 0x0E, 0x00, 0x04, 0x00, 0x19, 0x00,
                             0x06, 0x00, 0x10, 0x00, 0x0F, 0x00,
                             0x04, 0x00, 0x15, 0x00, 0x04, 0x00, 0x22, 0x00,
                             0x08, 0x00, 0x0D, 0x00, 0x04, 0x00, 0x00, 0x00,
                             0x04, 0x00, 0x16, 0x00,
                             0x08, 0x00, 0x18, 0x00, 0x01, 0x00, 0x01, 0x00,
                             0x04, 0x00, 0x1C, 0x00,
                             0x08, 0x00, 0x17, 0x00, 0x02, 0x00, 0x00, 0x00,
                             0x05, 0x00, 0x1A, 0x00, 0x00]
    #expect(blob == expected)
    #expect(blob == WDModules.thinwireCapabilities())   // identical to what the WD sends
    let p3 = [UInt8](ThinwireCapabilities.recommendedBlob(profile: 3))
    #expect(p3[1] == 16)
    #expect(p3.suffix(6) == [0x06, 0x00, 0x1B, 0x00, 0x00, 0x00])
}

@Test func thinwireRedrawPacking() {
    guard case let .wdPacket(type, body) = ThinwireCapabilities.redraw(TWRect(0x123, 0x456, 0x100, 0x200)) else {
        Issue.record("not a WD packet"); return
    }
    #expect(type == 0x06)
    // right = 0x223, bottom = 0x656
    #expect([UInt8](body) == [0x06, 0x00, 0x23, 0x61, 0x45, 0x23, 0x62, 0x65])
}

// MARK: Cache

@Test func thinwireCacheRingHandlesExtendAndPurge() throws {
    let c = TWCache()
    try c.configure(log2Bytes: 6, handleLog2: 2, maxObjectSize: 40)
    func add(_ b: [UInt8]) { b.withUnsafeBufferPointer { c.newObject($0) } }
    add([1, 2, 3])          // handle 0
    add([4, 5])             // handle 1
    [6, 7].withUnsafeBufferPointer { c.extendLast($0) }
    #expect(c.object(0) == [1, 2, 3])
    #expect(c.object(1) == [4, 5, 6, 7])
    // Purge walk: bit0 = 1 re-inserts handle 0 as handle 2; bit1 = 0 drops only the decoded copy of 1.
    c.purge(bits: [0b01], count: 2)
    #expect(c.object(2) == [1, 2, 3])
    #expect(c.object(1) == [4, 5, 6, 7])
    add([9])                // handle 3
    add([10, 11])           // handle 4 → slot 0 (4 slots)
    #expect(c.object(4) == [10, 11])
    #expect(c.object(0) == [10, 11])
    // Ring wrap: 64-byte ring, objects keep their bytes contiguous through the overflow tail.
    for i in 0..<20 { add([UInt8](repeating: UInt8(i), count: 30)) }
    #expect(c.object(4 + 20) == [UInt8](repeating: 19, count: 30))
}

// MARK: Bitmap codecs

@Test func thinwireRLEv1Direct24() throws {
    // 8x2, 24 bpp: [explicit fill: 1 literal (B,G,R order) + run 7], then [explicit copy-above run 8].
    let payload: [UInt8] = [0x5E, 0x33, 0x22, 0x11, 0xC7]
    let bmp = try payload.withUnsafeBufferPointer { buf throws -> TWBitmap in
        var r = TWReader(buf)
        return try TWBitmapCodec.decode(format: 0x15, width: 8, height: 2, reader: &r)
    }
    guard case .rgb(let px) = bmp.pixels else { Issue.record("not direct"); return }
    #expect(px == [UInt32](repeating: 0x112233, count: 16))
}

@Test func thinwireRLEAlternatingLiteralsAndBreakPixels() throws {
    // 8x2 24bpp. Op 1: explicit fill, 1 literal red, run 1 → red red.
    // Op 2: non-explicit fill, 3 alternating literals (prev,cur,prev), run 1 → see below.
    var d = TWRLEDecoder(mode: .direct24, v2: false, width: 8, height: 2)
    let payload: [UInt8] = [0x58, 0x00, 0x00, 0xFF,  // 0x40|0x18: L=1 R=0 → literal red (B,G,R), fill 1
                            0x3C]                    // k=0x3C → L=3, R=2 → run 3, non-explicit fill
    try payload.withUnsafeBufferPointer { buf throws in
        var r = TWReader(buf)
        // Run the two ops by hand to keep the bitmap partially filled.
        let h1 = try r.u8()
        let l1 = try TWRLEDecoder.lengths(h1 & 0x3f, &r)
        try d.explicitV1(&r, l1.0)
        d.fill(l1.1 + 1, explicit: true)
        #expect(Array(d.out[0..<2]) == [0xFF0000, 0xFF0000])
        #expect(d.cur == 0xFF0000 && d.prev == 0)          // single literal: prev ← old cur (0)
        let h2 = try r.u8()
        let l2 = try TWRLEDecoder.lengths(h2 & 0x3f, &r)
        #expect(l2 == (3, 2))
        d.alternating(l2.0)          // prev, cur, prev; then swap → cur = 0, prev = red
        d.fill(l2.1 + 1, explicit: false) // 3 × cur, then swap and break pixel = red
        #expect(Array(d.out[2..<9]) == [0, 0xFF0000, 0, 0, 0, 0, 0xFF0000])
    }
}

@Test func thinwireRLEv2CacheAndNewColour() throws {
    // 4x3 24bpp, codec 2. Op 1: explicit fill, L=2 (new colour 0x123456, cache[33]), run 1.
    // Op 2: explicit copy-above, run 9.
    let payload: [UInt8] = [0x64, 0x80, 0x56, 0x34, 0x12, 0x21, 0xC8]
    let bmp = try payload.withUnsafeBufferPointer { buf throws -> TWBitmap in
        var r = TWReader(buf)
        return try TWBitmapCodec.decode(format: 0x25, width: 4, height: 3, reader: &r)
    }
    guard case .rgb(let px) = bmp.pixels else { Issue.record("not direct"); return }
    let a: UInt32 = 0x123456, b: UInt32 = 0xB8B8B8
    #expect(px == [a, b, b, 0, a, b, b, 0, a, b, b, 0])
}

@Test func thinwireRLEv2Deltas() throws {
    var d = TWRLEDecoder(mode: .direct24, v2: true, width: 4, height: 4)
    d.mode2Counter = 1
    d.emit(0x102030)
    // 1-byte form: r=1 (−1), g=2 (+1), b=0; then 2-byte form 0x00..0x7F: b=4 (+2), g=0, r=0.
    try [0x98, 0x04, 0x00].withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) throws in
        var r = TWReader(buf)
        try d.explicitV2(&r, 2)
    }
    #expect(Array(d.out[0..<3]) == [0x102030, 0x0F2130, 0x0F2132])
    // 16 bpp: previous 0x808080, 1-byte form b=1 (−1 step of 8), g=0, r=0.
    var e = TWRLEDecoder(mode: .direct16, v2: true, width: 4, height: 4)
    e.mode2Counter = 1
    e.emit(TWColor.expand555(0x4210))
    try [0x01].withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) throws in
        var r = TWReader(buf)
        try e.explicitV2(&r, 1)
    }
    // The fields form one integer delta: −1 in blue carries into green, as in the reference (§9.3.2).
    #expect(e.out[1] == 0x848C7B)
}

@Test func thinwirePackedRLE1bpp() throws {
    // 16x16 1bpp (32 bytes → RLE). Copy-above op with 2 literal bytes and an escaped run of 30 units.
    let payload: [UInt8] = [0xAF, 29, 0xF0, 0x0F]
    let px = try payload.withUnsafeBufferPointer { buf throws -> [UInt8] in
        var r = TWReader(buf)
        return try TWBitmapCodec.packedRLE(&r, width: 16, height: 16, bpp: 1)
    }
    let row: [UInt8] = [1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1]
    #expect(px == Array([[UInt8]](repeating: row, count: 16).joined()))
    // Repeat-previous-unit op: literal 0xAB then 31 repeats, 4bpp 4x16 (2 bytes/row, 32 bytes).
    let p2: [UInt8] = [0x1F, 30, 0xAB]
    let px2 = try p2.withUnsafeBufferPointer { buf throws -> [UInt8] in
        var r = TWReader(buf)
        return try TWBitmapCodec.packedRLE(&r, width: 4, height: 16, bpp: 4)
    }
    #expect(px2 == Array([[UInt8]](repeating: [0xA, 0xB], count: 32).joined()))
}

// MARK: Engine

private func thinwireEngine(_ sink: ThinwireTestSink) -> ThinwireEngine {
    let e = ThinwireEngine()
    sink.attach(e)
    return e
}

@Test func thinwireInitRepliesAndSolidFill() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 64, height: 48)
    e.receive(Data(b.bytes))
    let info = try #require(e.sessionInfo)
    #expect(info.width == 64 && info.height == 48 && info.profile == 2 && info.endOfFrameSupported)
    #expect(sink.wdPackets.count == 2)
    #expect(sink.wdPackets[0].0 == 0x3A && sink.wdPackets[0].1 == [0x05, 0x00, 0x15, 0x78, 0x56, 0x34, 0x12])
    #expect(sink.wdPackets[1].0 == 0x06 && sink.wdPackets[1].1 == [0x06, 0x00, 0, 0, 0, 64, 0, 3])

    var c = ThinwireStreamBuilder()
    c.u8(0x9F); c.rgb(0xFF0000); c.rect(10, 10, 20, 10)
    c.u8(0x9E); c.rect(40, 30, 4, 4)       // same colour, unclipped
    c.endOfFrame()
    e.receive(Data(c.bytes))
    let fb = try #require(e.framebuffer)
    #expect(fb.pixel(x: 15, y: 15) == 0xFFFF0000)
    #expect(fb.pixel(x: 42, y: 32) == 0xFFFF0000)
    #expect(fb.pixel(x: 5, y: 5) == 0xFF000000)
    #expect(fb.pixel(x: 30, y: 15) == 0xFF000000)
    #expect(sink.updates.count == 1)
    #expect(sink.updates[0].sorted { $0.minX < $1.minX } == [CGRect(x: 10, y: 10, width: 20, height: 10), CGRect(x: 40, y: 30, width: 4, height: 4)])
}

/// A stream touching most of the parser: INIT, cache objects (with extend), blits, fills, clip, text, EOF.
private func thinwireSampleStream() -> [UInt8] {
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 64, height: 32)
    let px: [UInt32] = [0x00FF00, 0x0000FF, 0xFFFFFF, 0x808080, 0x112233, 0x445566]
    let obj = ThinwireStreamBuilder.rawBitmap24(width: 3, height: 2, pixels: px)
    b.u8(0xA6); b.varint(10); b.raw(Array(obj.prefix(10)))      // handle 0, completed by extend
    b.u8(0xA8); b.varint(obj.count - 10); b.raw(Array(obj.dropFirst(10)))
    b.u8(0xA1); b.u16(0); b.point(5, 6)                          // whole bitmap at (5,6)
    b.u8(0xA0); b.packedSize(x: 1, y: 1); b.packedSize(x: 2, y: 1); b.u16(0); b.point(20, 20) // (1,1,2,1) at (20,20)
    b.u8(0x9D); b.rgb(0x0000FF); b.rect(30, 0, 10, 10)           // clipped fill, no clip set
    b.u8(0x94); b.rect(50, 0, 2, 2)                              // clip to (50,0,2,2)
    b.u8(0x9C); b.rect(48, 0, 10, 10)                            // clipped → only 2x2
    b.u8(0x93)
    b.u8(0xC0); b.u8(5); b.u8(0x03); b.u8(7); b.u32(1000); b.varint(300); b.varint(2) // frame metrics, consumed
    b.u8(0xBB); b.raw([UInt8](repeating: 0, count: 17))
    // Glyph: 3x2, bits 101 / 010, d1 = (0,1), d2 = (0,0); TEXTOUT two copies.
    var glyph: [UInt8] = [0x02] + ThinwireStreamBuilder.packedSize(x: 2, y: 1)
    glyph += ThinwireStreamBuilder.delta(dx: 0, dy: 1) + ThinwireStreamBuilder.delta(dx: 1, dy: 0)
    glyph += [0b1010_0000, 0b0100_0000]
    b.cacheObject(glyph)                                         // handle 1
    b.u8(0x99); b.rgb(0xFFFF00)
    b.u8(0xA4); b.rect(0, 20, 10, 4); b.u8(1); b.point(1, 20); b.u16(1); b.u16(1)
    b.endOfFrame()
    return b.bytes
}

private func thinwireRun(_ chunks: [[UInt8]]) -> (pixels: [UInt32], outputs: Int, updates: Int, errors: Int) {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    for c in chunks { e.receive(Data(c)) }
    guard let fb = e.framebuffer else { return ([], sink.outputs.count, sink.updates.count, e.stats.errors) }
    var px: [UInt32] = []
    for y in 0..<fb.height { for x in 0..<fb.width { px.append(fb.pixel(x: x, y: y)) } }
    return (px, sink.outputs.count, sink.updates.count, e.stats.errors + e.stats.resyncs)
}

@Test func thinwireSampleStreamPixels() throws {
    let r = thinwireRun([thinwireSampleStream()])
    #expect(r.errors == 0)
    #expect(r.updates == 1)
    func px(_ x: Int, _ y: Int) -> UInt32 { r.pixels[y * 64 + x] & 0xFFFFFF }
    // Blit of the 3x2 bitmap at (5,6).
    #expect(px(5, 6) == 0x00FF00 && px(6, 6) == 0x0000FF && px(7, 6) == 0xFFFFFF)
    #expect(px(5, 7) == 0x808080 && px(7, 7) == 0x445566)
    // Partial blit of (1,1,2,1) at (20,20).
    #expect(px(20, 20) == 0x112233 && px(21, 20) == 0x445566 && px(22, 20) == 0)
    // Fills.
    #expect(px(30, 0) == 0x0000FF && px(39, 9) == 0x0000FF && px(40, 0) == 0)
    #expect(px(50, 0) == 0x0000FF && px(51, 1) == 0x0000FF && px(48, 0) == 0 && px(52, 0) == 0 && px(50, 2) == 0)
    // TEXTOUT: glyph 1 at pen (1,20)+d1 = (1,21); glyph 2 at pen (1+3+1, 20)+d1 = (5,21).
    #expect(px(1, 21) == 0xFFFF00 && px(2, 21) == 0 && px(3, 21) == 0xFFFF00 && px(2, 22) == 0xFFFF00)
    #expect(px(5, 21) == 0xFFFF00 && px(7, 21) == 0xFFFF00 && px(6, 22) == 0xFFFF00 && px(4, 21) == 0)
}

@Test func thinwireCommandsSplitAcrossPayloads() {
    let stream = thinwireSampleStream()
    let whole = thinwireRun([stream])
    // Every single split point.
    for cut in 1..<stream.count {
        let r = thinwireRun([Array(stream[..<cut]), Array(stream[cut...])])
        #expect(r.pixels == whole.pixels, "split at \(cut)")
        #expect(r.outputs == whole.outputs && r.errors == 0)
    }
    // Byte by byte.
    let bytewise = thinwireRun(stream.map { [$0] })
    #expect(bytewise.pixels == whole.pixels)
    #expect(bytewise.updates == 1)
}

@Test func thinwireUnknownOpcodeRequestsRedrawAndResyncs() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32)
    e.receive(Data(b.bytes))
    let before = sink.wdPackets.count
    e.receive(Data([0x9F, 0x00, 0xFF, 0x00, 0x00, 0x11, 0xB1, 0x01, 0x02, 0x03]))   // fill, then unknown 0xB1
    #expect(sink.wdPackets.count == before + 1)
    #expect(sink.wdPackets.last?.0 == 0x06)
    #expect(e.stats.resyncs == 1)
    #expect(sink.logs.contains { $0.contains("0xB1") })
    // The next payload parses normally.
    var c = ThinwireStreamBuilder()
    c.u8(0x9F); c.rgb(0x0000FF); c.rect(8, 8, 2, 2); c.endOfFrame()
    e.receive(Data(c.bytes))
    let fb = try #require(e.framebuffer)
    #expect(fb.pixel(x: 0, y: 0) == 0xFF00FF00)
    #expect(fb.pixel(x: 8, y: 8) == 0xFF0000FF)
    #expect(sink.updates.count == 1)
}

@Test func thinwireStopwatchReply() {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    e.receive(Data([0xAE, 0x07, 0x00, 0xAF, 0x07, 0x00]))
    #expect(sink.wdPackets.count == 1)
    #expect(sink.wdPackets[0].0 == 0x3A)
    #expect(Array(sink.wdPackets[0].1.prefix(5)) == [0x07, 0x00, 0x14, 0x07, 0x00])
}

// MARK: Pointer

@Test func thinwireMonochromePointer() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32)
    // 8x4 1bpp raw: AND rows 0x0F, 0x00; XOR rows 0xCC, 0xFF → 8x2 cursor.
    b.cacheObject([0x01, 0x01] + ThinwireStreamBuilder.packedSize(x: 7, y: 3) + [0x0F, 0x00, 0xCC, 0xFF])
    b.u8(0x91); b.u8(0x01); b.packedSize(x: 3, y: 1); b.u16(0)
    b.u8(0x92)
    b.u8(0xBC)
    e.receive(Data(b.bytes))
    #expect(sink.pointers.count == 3)
    let (img, hot) = sink.pointers[0]
    let image = try #require(img)
    #expect(image.width == 8 && image.height == 2)
    #expect(hot == CGPoint(x: 3, y: 1))
    let rgba = thinwireRGBA(image)
    func p(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * 8 + x) * 4..<(y * 8 + x) * 4 + 4]) }
    #expect(p(0, 0) == [255, 255, 255, 255])   // AND 0, XOR 1 → white
    #expect(p(2, 0) == [0, 0, 0, 255])         // AND 0, XOR 0 → black
    #expect(p(4, 0) == [0, 0, 0, 255])         // AND 1, XOR 1 → invert, drawn black
    #expect(p(6, 0) == [0, 0, 0, 0])           // AND 1, XOR 0 → transparent
    #expect(p(5, 1) == [255, 255, 255, 255])
    #expect(sink.pointers[1].0 == nil)
    #expect(sink.pointers[2].0 === image)
}

@Test func thinwireColourPointerWithMask() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32)
    b.cacheObject(ThinwireStreamBuilder.rawBitmap24(width: 2, height: 2, pixels: [0xFF0000, 0, 0x00FF00, 0x123456])) // 0
    b.cacheObject([0x01, 0x01] + ThinwireStreamBuilder.packedSize(x: 1, y: 1) + [0x40, 0x00])                      // 1: mask 01 / 00
    b.u8(0x91); b.u8(0x00); b.packedSize(x: 0, y: 0); b.u8(0x00); b.u16(0); b.u16(1)
    e.receive(Data(b.bytes))
    let image = try #require(sink.pointers.first?.0)
    let rgba = thinwireRGBA(image)
    #expect(Array(rgba[0..<4]) == [255, 0, 0, 255])
    #expect(Array(rgba[4..<8]) == [0, 0, 0, 0])
    #expect(Array(rgba[8..<12]) == [0, 255, 0, 255])
    #expect(Array(rgba[12..<16]) == [0x12, 0x34, 0x56, 255])
}

@Test func thinwireTextTrackingOverlays() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32, profile: 3)
    b.cacheObject(ThinwireStreamBuilder.rawBitmap24(width: 2, height: 1, pixels: [0xABCDEF, 0xABCDEF]))
    b.u8(0xC6); b.u16(0); b.point(4, 4)
    b.endOfFrame()
    e.receive(Data(b.bytes))
    let fb = try #require(e.framebuffer)
    #expect(fb.pixel(x: 4, y: 4) & 0xFFFFFF == 0xABCDEF)
    // Paint over it, delete the overlay, present again without video: stays painted over.
    var c = ThinwireStreamBuilder()
    c.current = b.current
    c.u8(0x9F); c.rgb(0x010203); c.rect(0, 0, 8, 8)
    c.u8(0xC7); c.packedSize(x: 2, y: 1); c.point(4, 4)
    c.endOfFrame()
    e.receive(Data(c.bytes))
    #expect(fb.pixel(x: 4, y: 4) & 0xFFFFFF == 0x010203)
}

// MARK: Double buffering

@Test func thinwireFrontSurfaceNeverShowsIntermediateFrameState() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32)
    b.cacheObject(ThinwireStreamBuilder.rawBitmap24(width: 2, height: 2, pixels: [0x00FF00, 0x00FF00, 0x00FF00, 0x00FF00]))
    e.receive(Data(b.bytes))
    let fb = try #require(e.framebuffer)
    let seed0 = fb.seed
    // Frame 1: fill red, then blit green over part of it, each in its own payload, then EOF.
    var fill = ThinwireStreamBuilder(); fill.current = b.current
    fill.u8(0x9F); fill.rgb(0xFF0000); fill.rect(0, 0, 8, 8)
    var blit = ThinwireStreamBuilder(); blit.current = fill.current
    blit.u8(0xA1); blit.u16(0); blit.point(2, 2)
    var eof = ThinwireStreamBuilder(); eof.endOfFrame()
    e.onUpdate = { rects in
        sink.updates.append(rects)
        // Whenever the app is told about a frame, the front surface holds all of it.
        #expect(fb.pixel(x: 0, y: 0) == 0xFFFF0000 && fb.pixel(x: 2, y: 2) == 0xFF00FF00)
    }
    for part in [fill.bytes, blit.bytes] {
        e.receive(Data(part))
        #expect(fb.pixel(x: 0, y: 0) == 0xFF000000, "front changed before END_OF_FRAME")
        #expect(fb.pixel(x: 2, y: 2) == 0xFF000000)
        #expect(sink.updates.isEmpty && fb.seed == seed0)
    }
    #expect(fb.backPixel(x: 0, y: 0) == 0xFFFF0000 && fb.backPixel(x: 2, y: 2) == 0xFF00FF00)
    e.receive(Data(eof.bytes))
    #expect(sink.updates.count == 1 && fb.seed != seed0)
    #expect(fb.pixel(x: 0, y: 0) == 0xFFFF0000 && fb.pixel(x: 3, y: 3) == 0xFF00FF00 && fb.pixel(x: 8, y: 8) == 0xFF000000)
    // The update reports exactly the rects copied to the front.
    #expect(sink.updates[0] == [CGRect(x: 0, y: 0, width: 8, height: 8)])
}

@Test func thinwireIdenticalRepaintIsNotPresented() throws {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32)
    e.receive(Data(b.bytes))
    let fb = try #require(e.framebuffer)
    func frame(_ rgb: UInt32, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        var c = ThinwireStreamBuilder()
        c.current = b.current
        c.u8(0x9F); c.rgb(rgb); c.rect(x, y, w, h); c.endOfFrame()
        b.current = c.current
        e.receive(Data(c.bytes))
    }
    frame(0x112233, 0, 0, 16, 16)
    #expect(sink.updates.count == 1)
    let seed = fb.seed
    frame(0x112233, 0, 0, 16, 16)           // identical repaint: no IOSurface write, no update
    #expect(sink.updates.count == 1 && fb.seed == seed)
    frame(0x112233, 0, 0, 16, 4)
    frame(0x445566, 0, 8, 16, 2)            // changed rows only
    #expect(sink.updates.count == 2 && fb.seed != seed)
    #expect(sink.updates[1] == [CGRect(x: 0, y: 8, width: 16, height: 2)])
    // A rect where only some rows differ is shrunk to the differing rows.
    var c = ThinwireStreamBuilder()
    c.current = b.current
    c.u8(0x9F); c.rgb(0x112233); c.rect(0, 0, 16, 16)   // rows 8..9 revert, others unchanged
    c.endOfFrame()
    e.receive(Data(c.bytes))
    #expect(sink.updates.last == [CGRect(x: 0, y: 8, width: 16, height: 2)])
}

@Test func thinwireSendsFPSLimitWhenEchoed() {
    let sink = ThinwireTestSink()
    let e = thinwireEngine(sink)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 32, height: 32, extraCaps: [0x1C])
    e.receive(Data(b.bytes))
    #expect(sink.wdPackets.map(\.0) == [0x3A, 0x3A, 0x06])
    #expect(sink.wdPackets[1].1 == [0x03, 0x00, 0x1F, 15, 0])
    let quiet = ThinwireEngine(config: { var c = ThinwireEngine.Config(); c.fpsLimit = nil; return c }())
    let sink2 = ThinwireTestSink()
    sink2.attach(quiet)
    quiet.receive(Data(b.bytes))
    #expect(sink2.wdPackets.count == 2)
}
