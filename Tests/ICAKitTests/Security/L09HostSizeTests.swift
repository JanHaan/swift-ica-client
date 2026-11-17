import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-09: host-sized allocations and loops are
// bounded (Thinwire framebuffer and glyphs, RLE literal runs, nested RTF picture groups). Offline.

@Suite struct L09HostSizeTests {
    @Test func framebufferRefusesHostSizesBeyondTheCap() {
        #expect(Framebuffer(width: 1 << 32, height: 1 << 30) == nil)          // INIT's packed size maximum: no trap
        #expect(Framebuffer(width: 20000, height: 20000) == nil)              // 1.6 GB per buffer
        #expect(Framebuffer(width: Framebuffer.maxSide, height: Framebuffer.maxPixels / Framebuffer.maxSide + 1) == nil)
        #expect(Framebuffer(width: 5120, height: 4096) != nil)                // our module's maximum mode
    }

    @Test func glyphSizesAreBounded() {
        #expect(ThinwireEngine.glyphFits(width: 64, height: 96))
        #expect(!ThinwireEngine.glyphFits(width: 4096, height: 8))
        #expect(!ThinwireEngine.glyphFits(width: 2048, height: 2048 + 1))
    }

    @Test func rleLiteralRunOfFourBillionStopsAtTheBitmapEnd() throws {
        // codec 1, 24 bpp: header 0x35 = literals by extended count (ff ffff ffffffff = 2^32 - 1), alternating colours.
        let stream: [UInt8] = [0x35, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let start = Date()
        let bitmap = try stream.withUnsafeBufferPointer { buf -> TWBitmap in
            var r = TWReader(buf)
            return try TWBitmapCodec.decode(format: 0x15, width: 64, height: 1, reader: &r)
        }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(bitmap.width == 64)
    }

    @Test func rleAlternatingKeepsItsPatternForOrdinaryRuns() throws {
        // 0x2a…0x34: literal count k - 0x27 (3…13) with run 0; 0x2d = 6 literals, alternating prev/cur from black.
        var stream: [UInt8] = []
        for _ in 0..<11 { stream.append(0x2d) }                                // 11 × (6 + 1) = 77 ≥ 64 pixels
        let a = try stream.withUnsafeBufferPointer { buf -> TWBitmap in
            var r = TWReader(buf)
            return try TWBitmapCodec.decode(format: 0x15, width: 64, height: 1, reader: &r)
        }
        guard case .rgb(let px) = a.pixels else { Issue.record("not rgb"); return }
        #expect(px.count == 64)
    }

    @Test func nestedUnconvertiblePictureGroupsAreLinear() {
        let n = 20_000
        let rtf = "{\\rtf1 " + String(repeating: "{\\pict\\emfblip 00", count: n) + "}"
        let start = Date()
        #expect(ClipboardRichText.flatRTFD(fromRTF: Data(rtf.utf8)) == nil)    // no convertible picture
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func convertiblePictureAfterAMetafileIsStillFound() {
        let png = ClipboardRichText.png(width: 1, height: 1, rgba: Data([0, 255, 0, 255]))!
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let rtf = "{\\rtf1 {\\pict\\emfblip 0102}text{\\pict\\pngblip\\picwgoal300\\pichgoal300 \(hex)}}"
        #expect(ClipboardRichText.flatRTFD(fromRTF: Data(rtf.utf8))?.pictures == 1)
    }
}
