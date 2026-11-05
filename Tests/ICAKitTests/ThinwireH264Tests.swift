import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import ICAKit

/// Encoded test frame: parameter sets and slice NAL units (no length prefixes or start codes).
private struct ThinwireEncodedFrame {
    var sps: [UInt8]
    var pps: [UInt8]
    var slices: [[UInt8]]

    var annexB: [UInt8] {
        var b: [UInt8] = [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps
        for s in slices { b += [0, 0, 1] + s }
        return b
    }

    var avcc: [UInt8] {
        var b: [UInt8] = []
        for n in [sps, pps] + slices {
            let l = UInt32(n.count)
            b += [UInt8(l >> 24), UInt8(l >> 16 & 0xff), UInt8(l >> 8 & 0xff), UInt8(l & 0xff)] + n
        }
        return b
    }
}

private let thinwireQuadrants: [(Int, Int, Int)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]

/// Encodes one key frame of a four-quadrant pattern (TL red, TR green, BL blue, BR white).
private func thinwireEncodePattern(width: Int, height: Int) throws -> ThinwireEncodedFrame {
    var sessionOut: VTCompressionSession?
    var st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                        outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
    let session = try #require(sessionOut, "VTCompressionSessionCreate \(st)")
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.9 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)

    var pbOut: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pbOut)
    let pb = try #require(pbOut)
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let rb = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<height {
        for x in 0..<width {
            let q = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
            let (r, g, b) = thinwireQuadrants[q]
            let p = base + y * rb + x * 4
            p[0] = UInt8(b); p[1] = UInt8(g); p[2] = UInt8(r); p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)

    var sample: CMSampleBuffer?
    st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: .zero, duration: .invalid,
                                         frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                                         infoFlagsOut: nil) { status, _, sbuf in
        if status == noErr { sample = sbuf }
    }
    #expect(st == noErr)
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    let sbuf = try #require(sample, "encoder produced no sample")
    let fd = try #require(CMSampleBufferGetFormatDescription(sbuf))

    func parameterSet(_ i: Int) throws -> [UInt8] {
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                    nalUnitHeaderLengthOut: nil)
        #expect(s == noErr)
        return Array(UnsafeBufferPointer(start: try #require(ptr), count: size))
    }
    let block = try #require(CMSampleBufferGetDataBuffer(sbuf))
    var length = 0
    var dataPtr: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
    let bytes = Array(UnsafeRawBufferPointer(start: try #require(dataPtr), count: length).bindMemory(to: UInt8.self))
    var slices: [[UInt8]] = []
    var i = 0
    while i + 4 <= bytes.count {
        let l = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        slices.append(Array(bytes[(i + 4)..<(i + 4 + l)]))
        i += 4 + l
    }
    return ThinwireEncodedFrame(sps: try parameterSet(0), pps: try parameterSet(1), slices: slices)
}

/// Thinwire image command(s) for one payload: a header command plus a 0xC3 continuation.
private func thinwireImageCommands(_ payload: [UInt8], op: UInt8, x: Int, y: Int, width: Int, height: Int,
                                   rects: [TWRect], fullFrame: Bool = false) -> [UInt8] {
    var b = ThinwireStreamBuilder()
    let first = payload.count / 3
    b.u8(op)
    b.u32(payload.count)
    b.u8(0x65)
    b.u16(x); b.u16(y); b.u16(width); b.u16(height)
    if op == 0xC8 { b.u32(0x06) }
    if op == 0xC5 || op == 0xC8 {
        b.u16(rects.count | (fullFrame ? 0x8000 : 0))
        for r in rects { b.u16(r.x); b.u16(r.y); b.u16(r.maxX); b.u16(r.maxY) }
    }
    b.varint(first)
    b.raw(Array(payload[..<first]))
    b.u8(0xC3)
    b.varint(payload.count - first)
    b.raw(Array(payload[first...]))
    return b.bytes
}

private func thinwireExpectColour(_ fb: Framebuffer, _ x: Int, _ y: Int, _ c: (Int, Int, Int), tolerance: Int = 16,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
    let (r, g, b) = fb.pixel(x: x, y: y).rgbTriple
    #expect(abs(r - c.0) <= tolerance && abs(g - c.1) <= tolerance && abs(b - c.2) <= tolerance,
            "pixel (\(x),\(y)) = (\(r),\(g),\(b)), expected \(c)", sourceLocation: sourceLocation)
}

@Test func thinwireH264AnnexBRoundTrip() throws {
    let w = 256, h = 128
    let frame = try thinwireEncodePattern(width: w, height: h)
    let sink = ThinwireTestSink()
    let e = ThinwireEngine()
    sink.attach(e)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: w, height: h)
    b.raw(thinwireImageCommands(frame.annexB, op: 0xC5, x: 0, y: 0, width: w, height: h, rects: [TWRect(0, 0, w, h)]))
    b.endOfFrame()
    // Deliver in uneven payloads to exercise chunk reassembly across receives.
    var i = 0
    var size = 7
    while i < b.bytes.count {
        let n = min(size, b.bytes.count - i)
        e.receive(Data(b.bytes[i..<(i + n)]))
        i += n
        size = size * 3 + 1
    }
    #expect(e.stats.pictures == 1, "logs: \(sink.logs)")
    #expect(e.stats.errors == 0 && e.stats.resyncs == 0)
    let fb = try #require(e.framebuffer)
    thinwireExpectColour(fb, w / 4, h / 4, thinwireQuadrants[0])
    thinwireExpectColour(fb, 3 * w / 4, h / 4, thinwireQuadrants[1])
    thinwireExpectColour(fb, w / 4, 3 * h / 4, thinwireQuadrants[2])
    thinwireExpectColour(fb, 3 * w / 4, 3 * h / 4, thinwireQuadrants[3])
    #expect(sink.updates.count == 1)
    #expect(sink.updates.first == [CGRect(x: 0, y: 0, width: w, height: h)])
}

@Test func thinwireH264AVCCWithDirtyRectsAtOffset() throws {
    let w = 256, h = 128
    let frame = try thinwireEncodePattern(width: w, height: h)
    let sink = ThinwireTestSink()
    let e = ThinwireEngine()
    sink.attach(e)
    var b = ThinwireStreamBuilder()
    b.initCommand(width: w + 32, height: h + 16)
    // Only the top-left and bottom-right quadrants are dirty; the frame sits at (16, 8).
    let dirty = [TWRect(0, 0, w / 2, h / 2), TWRect(w / 2, h / 2, w / 2, h / 2)]
    b.raw(thinwireImageCommands(frame.avcc, op: 0xC8, x: 16, y: 8, width: w, height: h, rects: dirty))
    // A solid fill after the picture in the same frame lands on top of it.
    b.u8(0x9F); b.rgb(0x00FFFF); b.rect(20, 10, 4, 4)
    b.endOfFrame()
    e.receive(Data(b.bytes))
    #expect(e.stats.pictures == 1, "logs: \(sink.logs)")
    let fb = try #require(e.framebuffer)
    thinwireExpectColour(fb, 16 + w / 4, 8 + h / 4, thinwireQuadrants[0])
    thinwireExpectColour(fb, 16 + 3 * w / 4, 8 + 3 * h / 4, thinwireQuadrants[3])
    // Not dirty → untouched (black).
    thinwireExpectColour(fb, 16 + 3 * w / 4, 8 + h / 4, (0, 0, 0), tolerance: 0)
    thinwireExpectColour(fb, 16 + w / 4, 8 + 3 * h / 4, (0, 0, 0), tolerance: 0)
    thinwireExpectColour(fb, 8, 4, (0, 0, 0), tolerance: 0)
    thinwireExpectColour(fb, 21, 11, (0, 255, 255), tolerance: 0)

    // A second key frame with the full-frame bit copies everything.
    var c = ThinwireStreamBuilder()
    c.current = b.current
    c.raw(thinwireImageCommands(frame.avcc, op: 0xC8, x: 16, y: 8, width: w, height: h, rects: [TWRect(0, 0, 2, 2)], fullFrame: true))
    c.endOfFrame()
    e.receive(Data(c.bytes))
    #expect(e.stats.pictures == 2)
    thinwireExpectColour(fb, 16 + 3 * w / 4, 8 + h / 4, thinwireQuadrants[1])
    thinwireExpectColour(fb, 16 + w / 4, 8 + 3 * h / 4, thinwireQuadrants[2])
}

@Test func thinwireNALFramingDetection() {
    let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 1, 0x65, 9, 9, 0]
    annexB.withUnsafeBufferPointer { buf in
        let r = TWH264Decoder.nalUnits(buf)
        #expect(r?.0 == .annexB)
        #expect(r?.1.map { Array(buf[$0]) } == [[0x67, 1, 2], [0x68, 3], [0x65, 9, 9]])
    }
    // AVCC whose first length (0x000001_0x05 = 261) starts with 00 00 01: still AVCC.
    var avcc: [UInt8] = [0, 0, 1, 5, 0x65] + [UInt8](repeating: 7, count: 260)
    avcc += [0, 0, 0, 2, 0x41, 1]
    avcc.withUnsafeBufferPointer { buf in
        let r = TWH264Decoder.nalUnits(buf)
        #expect(r?.0 == .avcc)
        #expect(r?.1.count == 2)
    }
}
