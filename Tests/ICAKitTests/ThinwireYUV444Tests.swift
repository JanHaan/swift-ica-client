import CoreVideo
import Foundation
import Testing
@testable import ICAKit

// Backlog 2.2: YUV 4:4:4 H.264 (cap 0x1E, 0xC8 colour format 8, High 4:4:4 Predictive), docs/40 §3.5.1.
// SPS fixtures are our own x264 encodes of an ffmpeg test pattern.

private let spsBaseline420: [UInt8] = [0x67, 0x42, 0xc0, 0x0d, 0xd9, 0x01, 0x41, 0xfb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10,
                                       0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x42, 0xa4, 0x80]
private let spsHigh420: [UInt8] = [0x67, 0x64, 0x00, 0x0d, 0xac, 0xb2, 0x02, 0x83, 0xf6, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x20,
                                   0x00, 0x00, 0x07, 0x81, 0xe2, 0x85, 0x49]
private let spsHigh444: [UInt8] = [0x67, 0xf4, 0x00, 0x0d, 0x91, 0x96, 0x40, 0x50, 0x7e, 0xc0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04,
                                   0x00, 0x00, 0x03, 0x00, 0xf0, 0x3c, 0x50, 0xa9, 0x20]
private let spsHigh444Bit10: [UInt8] = [0x67, 0xf4, 0x00, 0x0a, 0x90, 0xd9, 0xb2, 0x88, 0x4d, 0x80, 0x88, 0x00, 0x00, 0x03, 0x00,
                                        0x08, 0x00, 0x00, 0x03, 0x01, 0x90, 0x78, 0x91, 0x2c, 0xb0]

@Test func h264SPSChromaFormat() throws {
    let base = try #require(H264SPSInfo.parse(spsBaseline420))
    #expect(base.profileIdc == 66 && base.chromaFormatIdc == 1 && base.bitDepthLuma == 8)
    let high = try #require(H264SPSInfo.parse(spsHigh420))
    #expect(high.profileIdc == 100 && high.chromaFormatIdc == 1 && high.bitDepthChroma == 8)
    let p444 = try #require(H264SPSInfo.parse(spsHigh444))
    #expect(p444 == H264SPSInfo(profileIdc: 244, levelIdc: 13, chromaFormatIdc: 3, bitDepthLuma: 8, bitDepthChroma: 8))
    let p444b10 = try #require(H264SPSInfo.parse(spsHigh444Bit10))
    #expect(p444b10.chromaFormatIdc == 3 && p444b10.bitDepthLuma == 10 && p444b10.bitDepthChroma == 10)
    // The embedded capability probe is High 4:4:4 too.
    let probeSPS = Array(VideoDecodeSupport.probe444[4..<(4 + 21)])
    #expect(H264SPSInfo.parse(probeSPS)?.chromaFormatIdc == 3)
    // Not an SPS, or cut short.
    #expect(H264SPSInfo.parse([0x68, 0xee, 0x3c, 0x80]) == nil)
    #expect(H264SPSInfo.parse(Array(spsHigh444.prefix(4))) == nil)
}

@Test func expGolombSkipsEmulationPrevention() {
    // 00 00 03 01 → RBSP 00 00 01: 23 zero bits, then 1 → ue = 2^23 - 1 + 0.
    var r = ExpGolombReader(rbsp: [0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00])
    #expect(r.ue() == (1 << 23) - 1)
    var s = ExpGolombReader(rbsp: [0b1010_0110])   // ue: 0, 1, 2 → bits 1 | 010 | 011 | 0
    #expect(s.ue() == 0 && s.ue() == 1 && s.ue() == 2)
}

@Test func thinwireCapsAdvertiseYUV444OnlyWithH264() {
    let plain = WDModules.thinwireCapabilities(scalePercent: 100, monitors: [], h264: true)
    let with444 = WDModules.thinwireCapabilities(scalePercent: 100, monitors: [], h264: true, yuv444: true)
    #expect(with444[1] == plain[1] + 1)
    #expect(Array(with444.suffix(6)) == [0x06, 0x00, 0x1E, 0x00, 0x05, 0x00])
    #expect(Array(with444.dropLast(6)).dropFirst(2) == plain.dropFirst(2))
    let entries = ThinwireCapabilities.parseServerBlob(with444)
    #expect(entries.count == Int(with444[1]) && entries.last?.id == 0x1E && entries.last?.data == [0x05, 0x00])
    // Without the H.264 group there is no colour-format entry.
    #expect(WDModules.thinwireCapabilities(scalePercent: 100, monitors: [], h264: false, yuv444: true)
            == WDModules.thinwireCapabilities(scalePercent: 100, monitors: [], h264: false))
    // The documented blob and the WD's agree.
    #expect([UInt8](ThinwireCapabilities.recommendedBlob(yuv444: true)) == with444)
    // The module honours an explicit setting either way.
    var display = WDDisplay(width: 1920, height: 1080)
    display.yuv444 = true
    #expect(WDModules.thinwire(display: display, channel: 9, date: Date(timeIntervalSince1970: 0)).suffix(6)
            == [0x06, 0x00, 0x1E, 0x00, 0x05, 0x00])
    display.yuv444 = false
    #expect(WDModules.thinwire(display: display, channel: 9, date: Date(timeIntervalSince1970: 0)).suffix(5)
            == [0x05, 0x00, 0x1A, 0x00, 0x00])
}

@Test func yuv444ToBGRAMatchesBT601() {
    // Limited range: white, black, and BT.601 red/green/blue (Y, Cb, Cr) per pixel; full range: mid grey.
    let y: [UInt8] = [235, 16, 81, 145, 41]
    let cbcr: [UInt8] = [128, 128, 128, 128, 90, 240, 54, 34, 240, 110]
    var out = [UInt8](repeating: 0, count: 5 * 4)
    y.withUnsafeBufferPointer { yp in cbcr.withUnsafeBufferPointer { cp in out.withUnsafeMutableBufferPointer { op in
        Framebuffer.convert444(y: yp.baseAddress!, yRowBytes: 5, cbcr: cp.baseAddress!, cbcrRowBytes: 10,
                               bgra: op.baseAddress!, bgraRowBytes: 20, width: 5, height: 1, fullRange: false)
    } } }
    func rgb(_ i: Int) -> (Int, Int, Int) { (Int(out[4 * i + 2]), Int(out[4 * i + 1]), Int(out[4 * i])) }
    func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int = 3) -> Bool {
        abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
    }
    #expect(near(rgb(0), (255, 255, 255)) && near(rgb(1), (0, 0, 0)))
    #expect(near(rgb(2), (255, 0, 0)) && near(rgb(3), (0, 255, 0)) && near(rgb(4), (0, 0, 255)))
    #expect(out[3] == 255 && out[19] == 255)
    // Exchanged red and blue (colour format 8): the red sample comes out blue.
    var swapped = [UInt8](repeating: 0, count: 4)
    [UInt8(81)].withUnsafeBufferPointer { yp in [UInt8(90), 240].withUnsafeBufferPointer { cp in swapped.withUnsafeMutableBufferPointer { op in
        Framebuffer.convert444(y: yp.baseAddress!, yRowBytes: 1, cbcr: cp.baseAddress!, cbcrRowBytes: 2,
                               bgra: op.baseAddress!, bgraRowBytes: 4, width: 1, height: 1, fullRange: false, swapRedBlue: true)
    } } }
    #expect(swapped[0] >= 252 && swapped[1] <= 3 && swapped[2] <= 3)   // B, G, R = 255, 0, 0: blue
    var full = [UInt8](repeating: 0, count: 4)
    [UInt8(128)].withUnsafeBufferPointer { yp in [UInt8(128), 128].withUnsafeBufferPointer { cp in full.withUnsafeMutableBufferPointer { op in
        Framebuffer.convert444(y: yp.baseAddress!, yRowBytes: 1, cbcr: cp.baseAddress!, cbcrRowBytes: 2,
                               bgra: op.baseAddress!, bgraRowBytes: 4, width: 1, height: 1, fullRange: true)
    } } }
    #expect(full == [128, 128, 128, 255])
}

/// A 0xC8 image (colour format 8) carrying `payload` in one chunk at (x, y).
private func yuv444Image(_ payload: [UInt8], x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
    var b = ThinwireStreamBuilder()
    b.u8(0xC8)
    b.u32(payload.count)
    b.u8(0x65)
    b.u16(x); b.u16(y); b.u16(width); b.u16(height)
    b.u32(0x08)
    b.u16(0x8000)   // full frame, no rects
    b.varint(payload.count)
    b.raw(payload)
    return b.bytes
}

@Test func yuv444FrameKeepsPerPixelChroma() throws {
    // Hardware dependent: Apple's software H.264 decoder has no 4:4:4, so a Mac without the hardware decoder (or a VM
    // without one) does not advertise cap 0x1E and this check does not apply.
    let probe = VideoDecodeSupport.probeH264YUV444()
    guard probe.ok else {
        #expect(!VideoDecodeSupport.h264YUV444)
        print("yuv444FrameKeepsPerPixelChroma: skipped, \(probe.detail)")
        return
    }
    let e = ThinwireEngine()
    let sink = ThinwireTestSink()
    sink.attach(e)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: 128, height: 96)
    b.raw(yuv444Image(VideoDecodeSupport.probe444, x: 32, y: 16, width: 64, height: 64))
    b.endOfFrame()
    e.receive(Data(b.bytes))
    #expect(e.stats.pictures == 1 && e.stats.errors == 0, "logs: \(sink.logs)")
    #expect(sink.logs.contains { $0.contains("profile 244, 4:4:4") }, "logs: \(sink.logs)")
    let fb = try #require(e.framebuffer)
    // Alternating columns survive pixel by pixel (4:2:0 would blur them to purple). The probe is a standard encode of
    // red (230,20,20) / blue (20,20,230) columns; colour format 8 means red and blue arrive exchanged (the VDA's 4:4:4
    // video, docs/40 §3.5.1), so the engine shows them swapped back: blue at even columns.
    var worst = 0
    for y in stride(from: 4, to: 60, by: 7) {
        for x in 4..<60 {
            let (r, g, bl) = fb.pixel(x: 32 + x, y: 16 + y).rgbTriple
            let want = x % 2 == 0 ? (20, 20, 230) : (230, 20, 20)
            worst = max(worst, abs(r - want.0), abs(g - want.1), abs(bl - want.2))
        }
    }
    #expect(worst <= 24, "largest channel error \(worst)")
}
