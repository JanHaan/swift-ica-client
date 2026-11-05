import Foundation

/// Wire format of client audio mapping `CTXCAM ` (channel 19, docs/98-audio.md §1–§5). The channel is a
/// byte stream without length prefixes (§2): each host command's length follows from its fields, and a
/// command may be split across VC writes or share one with others. All integers LE.
public enum AudioWire {
    public static let channelName = "CTXCAM "
    public static let channelNumber: UInt8 = 19
    /// Min / max version as the browser reference announces them (§1.1, §1.3); 4 would enable enumeration.
    public static let versionLow: UInt8 = 1
    public static let versionHigh: UInt8 = 2
    /// VD data at module offset 48: 5·8·0x7FFF = 0x13FFD8 written with a u16 writer, so only 0xFFD8 is
    /// sent (§1.3). Never `D8 FF 13 00`.
    public static let bufferBudget = UInt16(truncatingIfNeeded: 5 * 8 * 0x7FFF)
    /// VD data at module offset 50.
    public static let vdFlag: UInt8 = 1

    /// Client capability bits (module offset 51, unaligned; §1.3).
    public enum Caps {
        /// Audio input (microphone); needs max version ≥ 2.
        public static let audioInput: UInt32 = 0x01
        /// Read/write V2 (WRITE_V2 0x0B, READ_DATA_V2 0x88), effective only if the host's INIT caps have it too.
        public static let readWriteV2: UInt32 = 0x10
        /// Playback only: what this client announces (§11 step 1).
        public static let playback: UInt32 = readWriteV2
    }

    /// The fixed devices of legacy mode (host version ≤ 3, §4.1).
    public static let playbackDevice: UInt8 = 1
    public static let captureDevice: UInt8 = 2

    /// Initial credits after INIT in legacy mode: 128 commands, 128 buffers (§4.1).
    public static let initialCredits: UInt16 = 0x80
    /// WRITE credits go back in batches of 32 (§6.3).
    public static let creditBatch = 32
    /// A partial batch is returned after this idle time (§6.3 [P]: 200 ms instead of the reference's 120 s).
    public static let creditIdleFlush: TimeInterval = 0.2

    public enum CreditKind: UInt8, Sendable {
        case command = 1, buffer = 2
    }

    /// RESET_DEVICE reasons (§3.2).
    public enum ResetReason {
        public static let wrongDeviceType: UInt8 = 3
        public static let streamError: UInt8 = 0xFF
    }

    /// Format codes (§5.1).
    public enum Format {
        public static let pcm: UInt16 = 1
        public static let vorbis: UInt16 = 4
        public static let speex: UInt16 = 5
        public static let opus: UInt16 = 6
    }

    /// OPEN_RESPONSE constants for a capture device (§7.1): the reference always sends 640 and 64.
    public static let openResponseBytesPer20ms: UInt16 = 640
    public static let openResponseBuffers: UInt16 = 64
}

/// Codecs this client can be allowed to accept (`ICA_AUDIO_CODECS`, docs/98 §10.4). Speex and Vorbis would
/// need third-party libraries and are not implemented.
public enum AudioCodecKind: String, CaseIterable, Sendable {
    case pcm, opus
}

/// The stream a decoder produces: interleaved Float32 at this rate and channel count.
public struct AudioStreamFormat: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var description: String { "\(Int(sampleRate)) Hz \(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) ch")" }
}

/// One `(format, subformat)` pair as CAPINFO and OPEN carry it (§5.1).
public struct AudioFormatCode: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var format: UInt16
    public var subformat: UInt16

    public init(_ format: UInt16, _ subformat: UInt16) {
        self.format = format
        self.subformat = subformat
    }

    /// PCM: bits 0–1 rate (8000, 11025, 22050, 44100), 0x10 stereo, 0x100 16-bit signed LE (else 8-bit
    /// unsigned). The 16 combinations the reference understands; anything with other bits is not PCM to us.
    public var pcm: (stream: AudioStreamFormat, bits: Int)? {
        guard format == AudioWire.Format.pcm, subformat & ~0x113 == 0 else { return nil }
        let rates: [Double] = [8000, 11025, 22050, 44100]
        return (AudioStreamFormat(sampleRate: rates[Int(subformat & 3)], channels: subformat & 0x10 != 0 ? 2 : 1),
                subformat & 0x100 != 0 ? 16 : 8)
    }

    /// Opus: bits 0–2 rate (8000, 12000, 16000, 24000, 48000), 0x10 stereo; 10 values.
    public var opus: AudioStreamFormat? {
        guard format == AudioWire.Format.opus, subformat & ~0x17 == 0, subformat & 7 <= 4 else { return nil }
        let rates: [Double] = [8000, 12000, 16000, 24000, 48000]
        return AudioStreamFormat(sampleRate: rates[Int(subformat & 7)], channels: subformat & 0x10 != 0 ? 2 : 1)
    }

    /// All subformats of the reference's PCM row (§5.1) and Opus row.
    public static let pcmSubformats: [UInt16] = (0..<4).flatMap { r in [0, 0x10].flatMap { s in [0, 0x100].map { b in UInt16(r) | s | b } } }
    public static let opusSubformats: [UInt16] = (0..<5).flatMap { r in [UInt16(r), UInt16(r) | 0x10] }

    public var description: String {
        if let p = pcm { return "PCM \(p.stream) \(p.bits)-bit" }
        if let o = opus { return "Opus \(o)" }
        switch format {
        case AudioWire.Format.vorbis:
            return String(format: "Vorbis %@ q%d", subformat & 0x20 != 0 ? "stereo" : "mono", subformat & 0xF)
        case AudioWire.Format.speex:
            return String(format: "Speex %@%@ q%d", subformat & 0x100 != 0 ? "WB" : subformat & 0x200 != 0 ? "UWB" : "NB",
                          subformat & 0x10 != 0 ? " mono" : "", subformat & 0xF)
        default:
            return String(format: "format %d/0x%04x", format, subformat)
        }
    }
}

/// A host → client command (§3.1).
public enum AudioHostCommand: Equatable, Sendable {
    /// 0x00: `u8 version, u8 ?`, then `u32 caps` only if version ≥ 3.
    case initialize(version: UInt8, reserved: UInt8, caps: UInt32?)
    /// 0x01: `u8 dev, u16 format, u16 subformat, 4 × u8` (skipped by the reference).
    case open(device: UInt8, format: AudioFormatCode, extra: [UInt8])
    /// 0x02: `u8 dev`.
    case close(device: UInt8)
    /// 0x03: `u8 dev, u16 dataOffset, u16 length, u16 pad`; data at max(dataOffset, 8).
    case write(device: UInt8, dataOffset: UInt16, pad: UInt16, data: Data)
    /// 0x04: `u8 dev`.
    case resetAck(device: UInt8)
    /// 0x05: `u8 dev, u16 listOffset, u16 n`; list at max(listOffset, 6), n × (u16 format, u16 subformat).
    case requestCapInfo(device: UInt8, listOffset: UInt16, formats: [AudioFormatCode])
    /// 0x06: `u8 dev, u16 size, u16 count`.
    case readRequest(device: UInt8, size: UInt16, count: UInt16)
    /// 0x07 / 0x08 / 0x09: `u8 dev`.
    case startRecord(device: UInt8)
    case stopRecord(device: UInt8)
    case resetRecord(device: UInt8)
    /// 0x0A: `u8, u8, u8, u32`; ignored by the reference (§9).
    case setControl(a: UInt8, b: UInt8, c: UInt8, value: UInt32)
    /// 0x0B: `u8 dev, u16 offset (not used for skipping), u16 length, u16 seq, 4 × 00`, then the data.
    case writeV2(device: UInt8, offset: UInt16, sequence: UInt16, reserved: [UInt8], data: Data)
    /// Any other byte: only the command byte is consumed (§3.1 "other").
    case unknown(UInt8)

    public var commandByte: UInt8 {
        switch self {
        case .initialize: return 0x00
        case .open: return 0x01
        case .close: return 0x02
        case .write: return 0x03
        case .resetAck: return 0x04
        case .requestCapInfo: return 0x05
        case .readRequest: return 0x06
        case .startRecord: return 0x07
        case .stopRecord: return 0x08
        case .resetRecord: return 0x09
        case .setControl: return 0x0A
        case .writeV2: return 0x0B
        case .unknown(let b): return b
        }
    }

    /// The reference's names (`AudioEngine.js` log table) where it has one, else ours.
    public var name: String {
        switch self {
        case .initialize: return "INIT"
        case .open: return "OPEN"
        case .close: return "CLOSE"
        case .write: return "WRITE"
        case .resetAck: return "RESET_ACK"
        case .requestCapInfo: return "REQUEST_CAPINFO"
        case .readRequest: return "READ_REQUEST"
        case .startRecord: return "START_RECORD"
        case .stopRecord: return "STOP_RECORD"
        case .resetRecord: return "RESET_RECORD"
        case .setControl: return "SET_CONTROL"
        case .writeV2: return "WRITE_V2"
        case .unknown(let b): return String(format: "UNKNOWN_%02x", b)
        }
    }

    /// The bytes as the host sends them (tests; offsets larger than the header add zero padding).
    public func encode() -> Data {
        var w = ByteWriter()
        w.u8(commandByte)
        switch self {
        case let .initialize(version, reserved, caps):
            w.u8(version); w.u8(reserved)
            if version >= 3 { w.u32(caps ?? 0) }
        case let .open(device, format, extra):
            w.u8(device); w.u16(format.format); w.u16(format.subformat)
            w.raw(Array((extra + [0, 0, 0, 0]).prefix(4)))
        case .close(let d), .resetAck(let d), .startRecord(let d), .stopRecord(let d), .resetRecord(let d):
            w.u8(d)
        case let .write(device, dataOffset, pad, data):
            w.u8(device); w.u16(dataOffset); w.u16(UInt16(data.count)); w.u16(pad)
            if dataOffset > 8 { w.raw([UInt8](repeating: 0, count: Int(dataOffset) - 8)) }
            w.raw([UInt8](data))
        case let .requestCapInfo(device, listOffset, formats):
            w.u8(device); w.u16(listOffset); w.u16(UInt16(formats.count))
            if listOffset > 6 { w.raw([UInt8](repeating: 0, count: Int(listOffset) - 6)) }
            for f in formats { w.u16(f.format); w.u16(f.subformat) }
        case let .readRequest(device, size, count):
            w.u8(device); w.u16(size); w.u16(count)
        case let .setControl(a, b, c, value):
            w.u8(a); w.u8(b); w.u8(c); w.u32(value)
        case let .writeV2(device, offset, sequence, reserved, data):
            w.u8(device); w.u16(offset); w.u16(UInt16(data.count)); w.u16(sequence)
            w.raw(Array((reserved + [0, 0, 0, 0]).prefix(4)))
            w.raw([UInt8](data))
        case .unknown:
            break
        }
        return w.data
    }

    /// Parses one command at `start`; nil if the bytes are not complete yet (the caller waits, §2).
    static func parse(_ b: [UInt8], at start: Int) -> (command: AudioHostCommand, length: Int)? {
        let n = b.count - start
        guard n >= 1 else { return nil }
        func u8(_ i: Int) -> UInt8 { b[start + i] }
        func u16(_ i: Int) -> UInt16 { UInt16(b[start + i]) | UInt16(b[start + i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        func data(_ from: Int, _ count: Int) -> Data { Data(b[(start + from)..<(start + from + count)]) }
        switch b[start] {
        case 0x00:
            guard n >= 3 else { return nil }
            let version = u8(1)
            if version >= 3 {
                guard n >= 7 else { return nil }
                return (.initialize(version: version, reserved: u8(2), caps: u32(3)), 7)
            }
            return (.initialize(version: version, reserved: u8(2), caps: nil), 3)
        case 0x01:
            guard n >= 10 else { return nil }
            return (.open(device: u8(1), format: AudioFormatCode(u16(2), u16(4)), extra: Array(b[(start + 6)..<(start + 10)])), 10)
        case 0x02, 0x04, 0x07, 0x08, 0x09:
            guard n >= 2 else { return nil }
            let d = u8(1)
            switch b[start] {
            case 0x02: return (.close(device: d), 2)
            case 0x04: return (.resetAck(device: d), 2)
            case 0x07: return (.startRecord(device: d), 2)
            case 0x08: return (.stopRecord(device: d), 2)
            default: return (.resetRecord(device: d), 2)
            }
        case 0x03:
            guard n >= 8 else { return nil }
            let offset = u16(2), length = Int(u16(4))
            let dataStart = max(Int(offset), 8)
            guard n >= dataStart + length else { return nil }
            return (.write(device: u8(1), dataOffset: offset, pad: u16(6), data: data(dataStart, length)), dataStart + length)
        case 0x05:
            guard n >= 6 else { return nil }
            let offset = u16(2), count = Int(u16(4))
            let listStart = max(Int(offset), 6)
            guard n >= listStart + 4 * count else { return nil }
            let formats = (0..<count).map { AudioFormatCode(u16(listStart + 4 * $0), u16(listStart + 4 * $0 + 2)) }
            return (.requestCapInfo(device: u8(1), listOffset: offset, formats: formats), listStart + 4 * count)
        case 0x06:
            guard n >= 6 else { return nil }
            return (.readRequest(device: u8(1), size: u16(2), count: u16(4)), 6)
        case 0x0A:
            guard n >= 8 else { return nil }
            return (.setControl(a: u8(1), b: u8(2), c: u8(3), value: u32(4)), 8)
        case 0x0B:
            guard n >= 12 else { return nil }
            let length = Int(u16(4))
            guard n >= 12 + length else { return nil }
            return (.writeV2(device: u8(1), offset: u16(2), sequence: u16(6), reserved: Array(b[(start + 8)..<(start + 12)]),
                             data: data(12, length)), 12 + length)
        default:
            return (.unknown(b[start]), 1)
        }
    }
}

/// Splits the channel stream into complete commands; incomplete bytes wait for the next `feed` (§2).
/// The longest command is 0xFFFF + 0xFFFF bytes (WRITE with the largest offset and length), so the
/// buffer stays bounded.
public struct AudioStreamParser {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Bytes received but not yet part of a complete command.
    public var pendingBytes: Int { buffer.count - start }

    public mutating func feed(_ data: Data) -> [(command: AudioHostCommand, length: Int)] {
        if start > 0, start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        buffer += data
        var out: [(AudioHostCommand, Int)] = []
        while let item = AudioHostCommand.parse(buffer, at: start) {
            out.append(item)
            start += item.length
        }
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 4096, start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return out
    }

    public mutating func reset() {
        buffer = []
        start = 0
    }
}

/// Client → host messages (§3.2).
public enum AudioReply {
    /// `80 <kind> <dev> <u16 count>`; dev 0 = channel-wide.
    public static func credit(_ kind: AudioWire.CreditKind, device: UInt8 = 0, count: UInt16) -> [UInt8] {
        [0x80, kind.rawValue, device, UInt8(count & 0xff), UInt8(count >> 8)]
    }

    /// The legacy initial credits after INIT: `80 01 00 80 00`, `80 02 00 80 00` (§4.1).
    public static var initialCredits: [[UInt8]] {
        [credit(.command, count: AudioWire.initialCredits), credit(.buffer, count: AudioWire.initialCredits)]
    }

    /// `81 <dev> <reason>`.
    public static func resetDevice(_ device: UInt8, reason: UInt8) -> [UInt8] { [0x81, device, reason] }

    /// `82 <dev> 06 00 <u16 m> m × (format, subformat)`, the pairs in the host's order (§5.2).
    public static func capInfo(device: UInt8, formats: [AudioFormatCode]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0x82); w.u8(device); w.u16(6); w.u16(UInt16(formats.count))
        for f in formats { w.u16(f.format); w.u16(f.subformat) }
        return [UInt8](w.data)
    }

    /// `84 <dev> <u16 bytesPer20ms> <u16 64> <status>`; status 0 ok, 0xFF failed (§3.2, §7.1).
    public static func openResponse(device: UInt8, status: UInt8, bytesPer20ms: UInt16 = AudioWire.openResponseBytesPer20ms,
                                    buffers: UInt16 = AudioWire.openResponseBuffers) -> [UInt8] {
        [0x84, device, UInt8(bytesPer20ms & 0xff), UInt8(bytesPer20ms >> 8), UInt8(buffers & 0xff), UInt8(buffers >> 8), status]
    }
}
