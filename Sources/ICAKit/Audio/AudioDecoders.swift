import AudioToolbox
import Foundation

/// Turns the payload of one WRITE into interleaved Float32 samples (docs/98 §6.2, §10.2). Decoders are
/// used on the session queue only; they are cheap (PCM conversion, one Opus packet per 2.5–60 ms).
public protocol AudioDecoder: AnyObject {
    var code: AudioFormatCode { get }
    var stream: AudioStreamFormat { get }
    /// Interleaved samples in [-1, 1]; may be empty (e.g. an incomplete PCM frame waits for the next WRITE).
    func decode(_ payload: Data) -> [Float]
    /// Payload parts that could not be decoded (bad Opus packets, truncated tails).
    var errors: Int { get }
}

public enum AudioDecoders {
    /// A decoder for an OPEN's `(format, subformat)`, or nil if the codec is not allowed or not available.
    public static func make(_ code: AudioFormatCode, codecs: Set<AudioCodecKind>, opusSubformats: Set<UInt16>) -> AudioDecoder? {
        if code.pcm != nil, codecs.contains(.pcm) { return PCMDecoder(code) }
        if code.opus != nil, codecs.contains(.opus), opusSubformats.contains(code.subformat) { return OpusDecoder(code) }
        return nil
    }

    /// Whether the client would answer CAPINFO with this pair for the playback device (§5.2, §11 step 3).
    public static func understands(_ code: AudioFormatCode, codecs: Set<AudioCodecKind>, opusSubformats: Set<UInt16>) -> Bool {
        if code.pcm != nil { return codecs.contains(.pcm) }
        if code.opus != nil { return codecs.contains(.opus) && opusSubformats.contains(code.subformat) }
        return false
    }
}

/// PCM (§6.2): 16-bit signed LE, or 8-bit **unsigned** (`x / 127.5 − 1`), interleaved if stereo. A frame split
/// across two WRITEs is kept until its rest arrives.
public final class PCMDecoder: AudioDecoder {
    public let code: AudioFormatCode
    public let stream: AudioStreamFormat
    public let bits: Int
    public private(set) var errors = 0
    private var carry: [UInt8] = []

    public init?(_ code: AudioFormatCode) {
        guard let p = code.pcm else { return nil }
        self.code = code
        stream = p.stream
        bits = p.bits
    }

    public func decode(_ payload: Data) -> [Float] {
        let bytes = carry.isEmpty ? [UInt8](payload) : carry + payload
        let frameBytes = bits / 8 * stream.channels
        let usable = bytes.count / frameBytes * frameBytes
        carry = Array(bytes[usable...])
        var out = [Float](repeating: 0, count: usable / (bits / 8))
        if bits == 16 {
            for i in 0..<out.count {
                out[i] = Float(Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)) / 32768
            }
        } else {
            for i in 0..<out.count { out[i] = Float(bytes[i]) / 127.5 - 1 }
        }
        return out
    }
}

/// Opus via AudioToolbox (§6.2, §10.1). A WRITE payload is a sequence of `u16 len` + Opus packet until the
/// payload ends; a truncated tail is dropped. Each packet's duration comes from its TOC byte (RFC 6716 §3.1),
/// so 2.5–120 ms packets all decode (the converter's input format has no fixed frames per packet). A
/// zero-length packet is a lost frame (§6.2 [P]): silence as long as the previous frame, not a decode error.
public final class OpusDecoder: AudioDecoder {
    public let code: AudioFormatCode
    public let stream: AudioStreamFormat
    public private(set) var errors = 0
    public private(set) var packets = 0
    /// Zero-length packets: the host marks a lost frame; it becomes silence of the previous frame's length.
    public private(set) var lostPackets = 0
    /// Frames (per channel, stream rate) of the last packet, from its TOC; 10 ms before the first.
    private var lastFrames: Int
    private var converter: AudioConverterRef?
    private let input: OpusInput
    /// 120 ms (the longest Opus packet) at the stream rate.
    private let capacityFrames: Int

    public init?(_ code: AudioFormatCode) {
        guard let s = code.opus, let c = OpusSupport.makeDecoder(s) else { return nil }
        self.code = code
        stream = s
        converter = c
        input = OpusInput(channels: UInt32(s.channels))
        capacityFrames = Int(s.sampleRate * 0.12)
        lastFrames = Int(s.sampleRate / 100)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    /// The Opus packets of one WRITE payload (`u16 len` + packet …). `truncated` is true if the last
    /// length field or packet did not fit.
    static func packets(in payload: Data) -> (packets: [Data], truncated: Bool) {
        let b = [UInt8](payload)
        var out: [Data] = []
        var i = 0
        while i + 2 <= b.count {
            let len = Int(b[i]) | Int(b[i + 1]) << 8
            i += 2
            guard i + len <= b.count else { return (out, true) }
            out.append(Data(b[i..<(i + len)]))
            i += len
        }
        return (out, i != b.count)
    }

    /// Samples per channel at 48 kHz of one packet from its TOC (RFC 6716 §3.1), or nil if malformed.
    static func samplesAt48k(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int  // samples at 48 kHz
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config & 3]
        case 12...15: frame = config & 1 == 0 ? 480 : 960
        default: frame = [120, 240, 480, 960][config & 3]
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return nil }
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        let total = frame * count
        guard count > 0, total <= 5760 else { return nil }
        return total
    }

    public func decode(_ payload: Data) -> [Float] {
        let (list, truncated) = Self.packets(in: payload)
        if truncated { errors += 1 }
        var out: [Float] = []
        for packet in list {
            if packet.isEmpty {
                lostPackets += 1
                out += [Float](repeating: 0, count: lastFrames * stream.channels)
                continue
            }
            guard let frames48 = Self.samplesAt48k(packet), let converter else {
                errors += 1
                continue
            }
            packets += 1
            let frames = max(1, Int((Double(frames48) * stream.sampleRate / 48000).rounded()))
            input.set(packet, frames: UInt32(frames))
            var buffer = [Float](repeating: 0, count: capacityFrames * stream.channels)
            var produced = UInt32(capacityFrames)
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, OpusInput.proc, Unmanaged.passUnretained(input).toOpaque(),
                                                       &produced, &list, nil)
            }
            if status != noErr && status != OpusInput.drained { errors += 1 }
            out += buffer.prefix(Int(produced) * stream.channels)
            lastFrames = frames   // the packet's nominal length (the first output may be shorter: decoder delay)
        }
        return out
    }
}

/// The input side of one Opus decode call: hands the converter one packet, then reports "no more data".
/// Stable allocations, because the converter keeps the pointers until the call returns.
final class OpusInput {
    /// Returned with 0 packets once the packet was taken: "nothing more for now", not an error.
    static let drained: OSStatus = 0x6D6F7265  // 'more'
    private let data = UnsafeMutableRawPointer.allocate(byteCount: 0x10000, alignment: 8)
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private let channels: UInt32
    private var size = 0
    private var frames: UInt32 = 0
    private var taken = true

    init(channels: UInt32) { self.channels = channels }

    deinit {
        data.deallocate()
        description.deallocate()
    }

    func set(_ packet: Data, frames: UInt32) {
        size = min(packet.count, 0x10000)
        packet.prefix(size).withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: size) }
        self.frames = frames
        taken = false
    }

    static let proc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDescription, user in
        let input = Unmanaged<OpusInput>.fromOpaque(user!).takeUnretainedValue()
        guard !input.taken else {
            ioPackets.pointee = 0
            return OpusInput.drained
        }
        input.taken = true
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = input.data
        ioData.pointee.mBuffers.mDataByteSize = UInt32(input.size)
        ioData.pointee.mBuffers.mNumberChannels = input.channels
        input.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: input.frames,
                                                                 mDataByteSize: UInt32(input.size))
        outDescription?.pointee = input.description
        ioPackets.pointee = 1
        return noErr
    }
}

/// Runtime check for the AudioToolbox Opus decoder (§10.1): the system lists `opus` in
/// `kAudioFormatProperty_DecodeFormatIDs`, and a converter can be created for the subformat's rate and
/// channels. Only the subformats that pass are offered in CAPINFO; with none, the client offers PCM only.
public enum OpusSupport {
    /// The decodable Opus subformats of §5.1, probed once per process.
    public static let decodableSubformats: Set<UInt16> = probe()

    /// True if AudioToolbox lists an Opus decoder at all.
    public static var systemDecoderListed: Bool { formatIDs(kAudioFormatProperty_DecodeFormatIDs).contains(kAudioFormatOpus) }

    /// True if AudioToolbox lists an Opus encoder (tests use it to make packets; the microphone would need it).
    public static var systemEncoderListed: Bool { formatIDs(kAudioFormatProperty_EncodeFormatIDs).contains(kAudioFormatOpus) }

    /// Every Opus subformat whose decoder can be created (no data is decoded).
    public static func probe() -> Set<UInt16> {
        guard systemDecoderListed else { return [] }
        var out: Set<UInt16> = []
        for sub in AudioFormatCode.opusSubformats {
            guard let s = AudioFormatCode(AudioWire.Format.opus, sub).opus, let c = makeDecoder(s) else { continue }
            AudioConverterDispose(c)
            out.insert(sub)
        }
        return out
    }

    /// The Opus input description: variable frames per packet (each packet description carries its count).
    public static func opusDescription(_ s: AudioStreamFormat, framesPerPacket: UInt32 = 0) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: s.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                    mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(s.channels),
                                    mBitsPerChannel: 0, mReserved: 0)
    }

    /// Interleaved Float32 at the stream's rate and channels.
    public static func floatDescription(_ s: AudioStreamFormat) -> AudioStreamBasicDescription {
        let bytes = UInt32(4 * s.channels)
        return AudioStreamBasicDescription(mSampleRate: s.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                           mChannelsPerFrame: UInt32(s.channels), mBitsPerChannel: 32, mReserved: 0)
    }

    static func makeDecoder(_ s: AudioStreamFormat) -> AudioConverterRef? {
        var source = opusDescription(s)
        var destination = floatDescription(s)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&source, &destination, &converter) == noErr else { return nil }
        return converter
    }

    static func formatIDs(_ property: AudioFormatPropertyID) -> [AudioFormatID] {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
