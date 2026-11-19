import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The fields of an H.264 sequence parameter set that pick the decoder output (docs/40-thinwire.md §3.5.1).
/// The VDA sends YUV 4:4:4 as H.264 High 4:4:4 Predictive (profile_idc 244, chroma_format_idc 3, 8 bit), and
/// 4:2:0 as Baseline/High (chroma_format_idc 1).
struct H264SPSInfo: Equatable {
    var profileIdc: UInt8
    var levelIdc: UInt8
    /// 0 = monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    var chromaFormatIdc: Int
    var bitDepthLuma: Int
    var bitDepthChroma: Int

    /// Parses an SPS NAL unit (with its one-byte NAL header). Nil if it is not an SPS or is truncated.
    static func parse(_ nal: [UInt8]) -> H264SPSInfo? {
        guard nal.count >= 4, nal[0] & 0x1f == 7 else { return nil }
        let profile = nal[1], level = nal[3]
        var r = ExpGolombReader(rbsp: Array(nal[4...]))
        guard r.ue() != nil else { return nil }   // seq_parameter_set_id
        var info = H264SPSInfo(profileIdc: profile, levelIdc: level, chromaFormatIdc: 1, bitDepthLuma: 8, bitDepthChroma: 8)
        // The profiles that carry chroma_format_idc and bit depths (H.264 7.3.2.1.1).
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let cf = r.ue(), cf <= 3 else { return nil }
            info.chromaFormatIdc = cf
            if cf == 3 { guard r.bit() != nil else { return nil } }   // separate_colour_plane_flag
            guard let bl = r.ue(), let bc = r.ue(), bl <= 6, bc <= 6 else { return nil }
            info.bitDepthLuma = 8 + bl
            info.bitDepthChroma = 8 + bc
        }
        return info
    }
}

/// Bit reader over an RBSP (emulation-prevention bytes removed) with Exp-Golomb codes.
struct ExpGolombReader {
    private let bytes: [UInt8]
    private var pos = 0

    init(rbsp ebsp: [UInt8]) {
        var out = [UInt8](); out.reserveCapacity(ebsp.count)
        var zeros = 0
        for b in ebsp {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        bytes = out
    }

    mutating func bit() -> Int? {
        guard pos < bytes.count * 8 else { return nil }
        let v = Int(bytes[pos >> 3] >> (7 - UInt8(pos & 7))) & 1
        pos += 1
        return v
    }

    /// Unsigned Exp-Golomb (ue(v)); nil when truncated or longer than 31 bits.
    mutating func ue() -> Int? {
        var zeros = 0
        while true {
            guard let b = bit() else { return nil }
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        var v = 0
        for _ in 0..<zeros { guard let b = bit() else { return nil }; v = v << 1 | b }
        return (1 << zeros) - 1 + v
    }
}

/// What this Mac's VideoToolbox can decode for Thinwire, tested once per process with a real decode (backlog 2.2).
/// Advertise a format only when it decodes here: Thinwire cap 0x1E (YUV 4:4:4) follows `h264YUV444`.
public enum VideoDecodeSupport {
    /// H.264 High 4:4:4 Predictive decodes with per-pixel chroma. On Apple silicon only the hardware decoder does
    /// 4:4:4 (Apple's software H.264 decoder refuses it), so a Mac or VM without it gets false.
    public static let h264YUV444: Bool = probeH264YUV444().ok

    /// Whether the Thinwire caps offer YUV 4:4:4 by default: when it decodes here, unless `ICA_TW_YUV444=0`.
    public static var advertiseYUV444: Bool {
        ProcessInfo.processInfo.environment["ICA_TW_YUV444"] != "0" && h264YUV444
    }

    /// The probe behind `h264YUV444`, with a reason for the log.
    public static func probeH264YUV444() -> (ok: Bool, detail: String) {
        let decoder = TWH264Decoder()
        var lines: [String] = []
        decoder.log = { lines.append($0) }
        guard let picture = decoder.decode(probe444) else {
            return (false, "H.264 4:4:4 probe did not decode" + (lines.last.map { ": \($0)" } ?? ""))
        }
        defer { decoder.invalidate() }
        let format = CVPixelBufferGetPixelFormatType(picture)
        guard format == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange else {
            return (false, "H.264 4:4:4 probe decoded to \(format), not 4:4:4")
        }
        // The probe picture is 64×64 of alternating red/blue columns: Cr must swing between neighbours.
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let c = CVPixelBufferGetBaseAddressOfPlane(picture, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return (false, "H.264 4:4:4 probe: no chroma plane")
        }
        let rb = CVPixelBufferGetBytesPerRowOfPlane(picture, 1)
        var swings = 0, samples = 0
        for y in stride(from: 8, to: 56, by: 8) {
            for x in stride(from: 8, to: 56, by: 2) {
                samples += 1
                let p = c + y * rb + x * 2
                let crRed = Int(p[1]), crBlue = Int(p[3]), cbRed = Int(p[0]), cbBlue = Int(p[2])
                if crRed - crBlue > 100 && cbBlue - cbRed > 100 { swings += 1 }
            }
        }
        return swings * 10 >= samples * 9 ? (true, "H.264 4:4:4 decodes (\(decoder.usingHardware.map { $0 ? "hardware" : "software" } ?? "?"))")
                             : (false, "H.264 4:4:4 probe lost per-pixel chroma (\(swings)/\(samples))")
    }

    /// 64×64 alternating red (230,20,20) / blue (20,20,230) columns, H.264 High 4:4:4 Predictive, one IDR at qp 12,
    /// Annex-B, SEI removed; our own encode (x264), BT.601 limited range. The hardware decoder refuses pictures much
    /// smaller than this (64×48 is refused; 56×56 is accepted).
    static let probe444: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x67, 0xf4, 0x10, 0x0a, 0x91, 0x97, 0x10, 0x9a, 0x6a, 0x04, 0x04, 0x0a, 0x80, 0x00,
        0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x19, 0x02, 0x00, 0x00, 0x00, 0x01, 0x68, 0xee, 0x03, 0xb1, 0x12, 0x11,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x3a, 0xcf, 0x8d, 0xb4, 0xc9, 0xf6, 0xa7, 0x5c, 0x29, 0xe3, 0x1e,
        0x5c, 0xf8, 0x61, 0xc6, 0x2b, 0xed, 0x09, 0xab, 0x0b, 0x58, 0xeb, 0x10, 0x6f, 0x88, 0xd6, 0x20, 0x49, 0x09,
        0xae, 0x3c, 0xfd, 0x4f, 0x37, 0x52, 0xcd, 0x34, 0x09, 0x16, 0xf1, 0x22, 0x31, 0x60, 0x1a, 0x44, 0xf7, 0xf6,
        0x36, 0x3a, 0xec, 0xff, 0x03, 0x92, 0xea, 0xd2, 0xcf, 0x2d, 0xb1, 0x0e, 0x86, 0xde, 0x6a, 0x45, 0x3c, 0xdd,
        0x4b, 0x2b, 0x66, 0x78, 0x79, 0x5a, 0x68, 0xc5, 0x80, 0x2c, 0xa1, 0xbf, 0xd0, 0x0c, 0xbb, 0x3f, 0xbb, 0xef,
        0x39, 0xed, 0x8a, 0xcd, 0xb0, 0x01, 0x93, 0x65, 0x8c, 0xb2, 0x55, 0x81, 0xaa, 0x3e, 0xab, 0x86, 0x57, 0x3c,
        0x83, 0x57, 0xe2, 0xd4, 0x18, 0x49, 0x77, 0x48, 0x7e, 0x48, 0x5b, 0xd2, 0x9a, 0x36, 0x6c, 0xf8, 0x8e, 0xb2,
        0xf8, 0x5a, 0xfc, 0xb0, 0x4a, 0xd4, 0x00, 0x2f, 0x1d, 0x47, 0xa4, 0x2f, 0x43, 0xc1, 0x03, 0x9c, 0xfe, 0xd4,
        0x8a, 0x46, 0xca, 0x95, 0x91, 0xcf, 0x55, 0x2d, 0x6d, 0x19, 0x44, 0xca, 0xb9, 0x78, 0xa2, 0x15, 0x5c, 0xe8,
        0x98, 0x1b, 0x7b, 0x89, 0x4d, 0xb2, 0xdd, 0x0a, 0x48, 0x78, 0xe0, 0x38, 0x6e, 0x5d, 0xf9, 0x49, 0x22, 0xc9,
        0xd7, 0xfe, 0x5d, 0x3b, 0xba, 0xa0, 0x56, 0x38, 0x1c, 0xf3, 0x1e, 0x76, 0x81, 0x10, 0x57, 0x84, 0x21, 0x87,
        0xc9, 0xdb, 0x56, 0x48, 0x93, 0xcd, 0x4c, 0x90, 0x53, 0x80, 0xae, 0x44, 0xde, 0x4a, 0xda, 0xc4, 0xf9, 0xdf,
        0x6f, 0x95, 0x00, 0xcf, 0xf3, 0xc7, 0x54, 0xe5, 0x9b, 0xad, 0x2a, 0x4c, 0xa3, 0xd9, 0xfe, 0x00, 0xdc, 0xb2,
        0x3a, 0xbc, 0xab, 0x28, 0xa2, 0x23, 0x12, 0x7f, 0x13, 0xfe, 0x84, 0x5a, 0xcd, 0x75, 0x3d, 0x92, 0x0b, 0x5f,
        0x0c, 0x26, 0x3c, 0x57, 0x15, 0x34, 0x4d, 0xbf, 0x95, 0xb4, 0x72, 0xf2, 0x82, 0x5a, 0x19, 0xf8, 0x69, 0x86,
        0x0e, 0xa4, 0xd1, 0x6e, 0x71, 0x41, 0x99, 0x20, 0x88, 0x9e, 0xbf, 0x97, 0x39, 0xc1, 0x18, 0x2c, 0x90, 0x02,
        0xea, 0x5f, 0x83, 0x98, 0x06, 0xda, 0xfe, 0xf5, 0x6f, 0x09, 0x76, 0x8e, 0xd7, 0x18, 0x84, 0xd0, 0x71, 0x07,
        0x98, 0x9e, 0x11, 0x3c, 0x8a, 0x94, 0x8e, 0xb8, 0x53, 0xcf, 0x15, 0x87, 0x33, 0x36, 0x15, 0x3e, 0x36, 0x4f,
        0x42, 0x2c, 0xc5, 0x77, 0xbb, 0x50, 0x07, 0x08, 0xa4, 0x67, 0xf4, 0x86, 0xb9, 0xcc, 0xea, 0x90, 0xa1
    ]
}
