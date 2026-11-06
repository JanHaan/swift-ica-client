import AudioToolbox
import Foundation

/// Where uplink audio comes from (docs/98 §7, §10.3): the Mac microphone in the app (`Microphone` in
/// ICAViewer; icactl has none) or the synthetic `AudioToneSource`. The engine asks for permission only on the
/// host's first OPEN of the capture device and starts the source only on START_RECORD.
public protocol AudioCaptureSource: AnyObject {
    /// Asks for microphone permission (prompting at most once). Completion on any thread.
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    /// Starts delivering interleaved Float32 at `format`, on any thread, in chunks of any size.
    func start(format: AudioStreamFormat, deliver: @escaping ([Float]) -> Void) throws
    /// Stops at once; no `deliver` call starts after it returns.
    func stop()
}

/// A 440 Hz sine instead of a microphone (`ICA_AUDIOTEST_MIC=tone`, tests): always permitted, never opens an
/// input device. Delivers 10 ms chunks paced by the clock on its own queue.
public final class AudioToneSource: AudioCaptureSource {
    public let frequency: Double
    public let amplitude: Float
    private let queue = DispatchQueue(label: "ica.audio.tone")
    private var timer: DispatchSourceTimer?
    private var phase = 0.0
    private let lock = NSLock()

    public init(frequency: Double = 440, amplitude: Float = 0.3) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    public func requestPermission(_ completion: @escaping (Bool) -> Void) { completion(true) }

    /// `frames` frames of the tone, continuing the phase (also used by tests without a timer).
    public func generate(frames: Int, format: AudioStreamFormat) -> [Float] {
        var out = [Float](repeating: 0, count: frames * format.channels)
        let step = 2 * Double.pi * frequency / format.sampleRate
        for i in 0..<frames {
            let v = amplitude * Float(sin(phase))
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            for c in 0..<format.channels { out[i * format.channels + c] = v }
        }
        return out
    }

    public func start(format: AudioStreamFormat, deliver: @escaping ([Float]) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let started = DispatchTime.now()
        var produced = 0
        t.schedule(deadline: .now() + 0.01, repeating: 0.01, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            let due = Int(elapsed * format.sampleRate) - produced
            guard due > 0 else { return }
            produced += due
            deliver(self.generate(frames: due, format: format))
        }
        lock.lock()
        timer = t
        lock.unlock()
        t.resume()
    }

    public func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        guard let t else { return }
        t.cancel()
        // A tick already running finishes before stop returns.
        queue.sync {}
    }
}

/// Encodes fixed-size frames of interleaved Float32 into codec packets.
public protocol AudioPacketEncoder: AnyObject {
    var stream: AudioStreamFormat { get }
    /// Frames (per channel) per packet.
    var frameCount: Int { get }
    /// One frame of `frameCount × channels` samples; returns the packets it completed (normally one), or nil on error.
    func encode(_ frame: [Float]) -> [Data]?
}

/// Opus via AudioToolbox (§7.2): rate and channels from the OPEN subformat, **10 ms** frames (rate / 100).
/// The reference's VOIP application and DTX are libopus settings AudioToolbox does not expose [P]: the
/// encoder runs with its defaults, so every 10 ms frame produces a packet (no silent frames).
public final class OpusEncoder: AudioPacketEncoder {
    public let code: AudioFormatCode
    public let stream: AudioStreamFormat
    public let frameCount: Int
    private var converter: AudioConverterRef?
    private let input: PCMInput
    private let maxPacket: Int

    public init?(_ code: AudioFormatCode) {
        guard let s = code.opus else { return nil }
        var pcm = OpusSupport.floatDescription(s)
        var opus = OpusSupport.opusDescription(s, framesPerPacket: UInt32(s.sampleRate / 100))
        var c: AudioConverterRef?
        guard AudioConverterNew(&pcm, &opus, &c) == noErr, let c else { return nil }
        var size = UInt32(MemoryLayout<UInt32>.size)
        var max: UInt32 = 0
        AudioConverterGetProperty(c, kAudioConverterPropertyMaximumOutputPacketSize, &size, &max)
        self.code = code
        stream = s
        frameCount = Int(s.sampleRate / 100)
        converter = c
        maxPacket = Int(max > 0 ? max : 1500)
        input = PCMInput(capacity: frameCount * s.channels, channels: UInt32(s.channels))
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    public func encode(_ frame: [Float]) -> [Data]? {
        guard let converter, frame.count == frameCount * stream.channels else { return nil }
        input.set(frame)
        var packets: [Data] = []
        while true {
            var out = [UInt8](repeating: 0, count: maxPacket)
            var description = AudioStreamPacketDescription()
            var n: UInt32 = 1
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, PCMInput.proc, Unmanaged.passUnretained(input).toOpaque(),
                                                       &n, &list, &description)
            }
            if status != noErr && status != PCMInput.drained { return nil }
            guard n > 0 else { break }
            let start = Int(description.mStartOffset), size = Int(description.mDataByteSize)
            guard size > 0, start + size <= out.count else { break }
            packets.append(Data(out[start..<(start + size)]))
            if status == PCMInput.drained { break }
        }
        return packets
    }
}

/// The input side of one encode call: one frame, then "no more data for now". Stable allocation.
final class PCMInput {
    static let drained: OSStatus = 0x6D6F7265  // 'more'
    private let data: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let channels: UInt32
    private var count = 0
    private var taken = true

    init(capacity: Int, channels: UInt32) {
        self.capacity = capacity
        self.channels = channels
        data = .allocate(capacity: capacity)
    }

    deinit { data.deallocate() }

    func set(_ samples: [Float]) {
        count = min(samples.count, capacity)
        samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: count) }
        taken = false
    }

    static let proc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, user in
        let input = Unmanaged<PCMInput>.fromOpaque(user!).takeUnretainedValue()
        guard !input.taken else {
            ioPackets.pointee = 0
            return PCMInput.drained
        }
        input.taken = true
        let frames = input.count / Int(input.channels)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(input.data)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(input.count * 4)
        ioData.pointee.mBuffers.mNumberChannels = input.channels
        ioPackets.pointee = UInt32(frames)
        return noErr
    }
}

/// Cuts captured samples into encoder frames and encodes them (§7.1: push-based, one READ_DATA per packet).
/// Used on the capture queue only.
public final class AudioUplink {
    public let encoder: AudioPacketEncoder
    public private(set) var errors = 0
    public private(set) var framesEncoded = 0
    private var pending: [Float] = []

    public init(encoder: AudioPacketEncoder) { self.encoder = encoder }

    /// Samples not yet encoded (less than one frame after each `push`).
    public var pendingSamples: Int { pending.count }

    public func push(_ samples: [Float]) -> [Data] {
        pending += samples
        let n = encoder.frameCount * encoder.stream.channels
        var out: [Data] = []
        var i = 0
        while pending.count - i >= n {
            if let packets = encoder.encode(Array(pending[i..<(i + n)])) { out += packets } else { errors += 1 }
            framesEncoded += 1
            i += n
        }
        if i > 0 { pending.removeFirst(i) }
        return out
    }
}

extension OpusSupport {
    /// The Opus subformats AudioToolbox can encode at 10 ms frames (the capture device's CAPINFO reply).
    public static let encodableSubformats: Set<UInt16> = probeEncoder()

    public static func probeEncoder() -> Set<UInt16> {
        guard systemEncoderListed else { return [] }
        var out: Set<UInt16> = []
        for sub in AudioFormatCode.opusSubformats {
            guard let s = AudioFormatCode(AudioWire.Format.opus, sub).opus else { continue }
            var pcm = floatDescription(s)
            var opus = opusDescription(s, framesPerPacket: UInt32(s.sampleRate / 100))
            var c: AudioConverterRef?
            if AudioConverterNew(&pcm, &opus, &c) == noErr, let c {
                AudioConverterDispose(c)
                out.insert(sub)
            }
        }
        return out
    }
}
