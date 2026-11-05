import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// H.264 elementary-stream decoder for Thinwire image payloads (docs/40-thinwire.md §3.5, §9.4).
/// Accepts Annex-B or 4-byte length-prefixed (AVCC) payloads, detected per payload, and feeds
/// VideoToolbox AVCC samples. Parameter sets come from the stream; a change recreates the session.
/// Decoding is synchronous: `decode` returns the picture for the payload, if any.
final class TWH264Decoder {
    enum Framing: String { case annexB = "Annex-B", avcc = "AVCC" }

    private(set) var framing: Framing?
    private var sps: [UInt8]?
    private var pps: [[UInt8]] = []
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parametersChanged = false
    var log: ((String) -> Void)?
    private(set) var framesDecoded = 0

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: NAL parsing

    /// Splits a payload into NAL units, detecting the framing.
    /// An exact chain of 4-byte lengths wins (an AVCC length of 256..511 starts with `00 00 01`),
    /// unless the stream is already known to be Annex-B and the payload starts with a start code.
    static func nalUnits(_ data: UnsafeBufferPointer<UInt8>, previous: Framing? = nil) -> (Framing, [Range<Int>])? {
        let n = data.count
        guard n >= 4 else { return nil }
        let startsWithStartCode = (data[0] == 0 && data[1] == 0 && data[2] == 1)
            || (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1)
        if !(startsWithStartCode && previous == .annexB), let units = avccUnits(data) { return (.avcc, units) }
        let units = annexBUnits(data)
        return units.isEmpty ? nil : (.annexB, units)
    }

    static func avccUnits(_ data: UnsafeBufferPointer<UInt8>) -> [Range<Int>]? {
        var units: [Range<Int>] = []
        var i = 0
        while i < data.count {
            guard i + 4 <= data.count else { return nil }
            let len = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            i += 4
            guard len > 0, i + len <= data.count else { return nil }
            // Forbidden-zero bit must be clear in a NAL header.
            guard data[i] & 0x80 == 0 else { return nil }
            units.append(i..<(i + len))
            i += len
        }
        return units.isEmpty ? nil : units
    }

    static func annexBUnits(_ data: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var starts: [Int] = []   // index of the first NAL byte after each start code
        var i = 0
        let n = data.count
        while i + 2 < n {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : n
            while e > s && data[e - 1] == 0 { e -= 1 }   // zero byte of a 4-byte start code / trailing zeros
            if e > s { units.append(s..<e) }
        }
        return units
    }

    // MARK: Decoding

    /// Decodes one complete image payload. Returns the decoded picture, or nil if the payload
    /// held no picture or decoding failed.
    func decode(_ payload: [UInt8]) -> CVPixelBuffer? {
        var sample = [UInt8]()
        var sliceCount = 0
        let ok: Bool = payload.withUnsafeBufferPointer { buf in
            guard let (fr, units) = TWH264Decoder.nalUnits(buf, previous: framing) else { return false }
            if framing != fr {
                if framing != nil { log?("Thinwire H.264: framing changed to \(fr.rawValue)") }
                framing = fr
            }
            for u in units {
                let nal = Array(buf[u])
                let type = nal[0] & 0x1f
                switch type {
                case 7:
                    if nal != sps { sps = nal; pps = []; parametersChanged = true }
                case 8:
                    if !pps.contains(nal) { pps.append(nal); parametersChanged = true }
                case 9, 10, 11, 12:
                    continue
                default:
                    if type >= 1 && type <= 5 { sliceCount += 1 }
                    let len = UInt32(nal.count)
                    sample.append(contentsOf: [UInt8(len >> 24), UInt8((len >> 16) & 0xff), UInt8((len >> 8) & 0xff), UInt8(len & 0xff)])
                    sample.append(contentsOf: nal)
                }
            }
            return true
        }
        guard ok else { log?("Thinwire H.264: payload of \(payload.count) bytes has no NAL units"); return nil }
        guard sliceCount > 0 else { return nil }
        if parametersChanged || session == nil {
            guard rebuildSession() else { return nil }
        }
        guard let session, let formatDescription else { return nil }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        status = sample.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count) }
        guard status == noErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var size = sample.count
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
                                           sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        var picture: CVPixelBuffer?
        var decodeStatus: OSStatus = noErr
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
            decodeStatus = st
            if st == noErr { picture = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status != noErr || decodeStatus != noErr {
            log?("Thinwire H.264: decode failed (\(status), \(decodeStatus))")
            if status == kVTInvalidSessionErr { invalidate() }
            return nil
        }
        if picture != nil { framesDecoded += 1 }
        return picture
    }

    private func rebuildSession() -> Bool {
        parametersChanged = false
        guard let sps, !pps.isEmpty else {
            log?("Thinwire H.264: slice before SPS/PPS")
            return false
        }
        invalidate()
        formatDescription = nil
        let sets = [sps] + pps
        var fd: CMVideoFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else {
            log?("Thinwire H.264: parameter sets rejected (\(status))")
            return false
        }
        formatDescription = fd
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else {
            log?("Thinwire H.264: VTDecompressionSessionCreate failed (\(st))")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        log?("Thinwire H.264: decoder session \(dims.width)x\(dims.height), \(framing?.rawValue ?? "?") framing")
        return true
    }

    private func withPointers<R>(_ sets: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
        }
    }
}
