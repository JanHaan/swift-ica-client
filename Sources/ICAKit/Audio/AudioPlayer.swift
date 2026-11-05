import AVFoundation
import Foundation

/// Pre-roll and lag limits of the playback queue (docs/98 §6.4, §10.2).
public struct AudioJitterPolicy: Equatable, Sendable {
    /// Audio held before playback starts (and after an underrun), plus `startMargin`.
    public var preRoll: TimeInterval
    /// More than this queued: drop the queue and pre-roll again.
    public var lagThreshold: TimeInterval
    /// The reference's extra 20 ms on (re)start.
    public var startMargin: TimeInterval = 0.02

    public init(preRoll: TimeInterval, lagThreshold: TimeInterval) {
        self.preRoll = preRoll
        self.lagThreshold = lagThreshold
    }

    /// [P] 60–100 ms targets instead of the reference's 250 ms for PCM: Opus 60 + 20 ms (as the reference),
    /// PCM 80 + 20 ms. Overridable with ICA_AUDIO_PREROLL_MS / ICA_AUDIO_LAG_MS (like the reference's
    /// HTML5_Audio_Buffer_Duration / _Lag_Threshold).
    public static func `for`(_ code: AudioFormatCode, env: [String: String] = ProcessInfo.processInfo.environment) -> AudioJitterPolicy {
        var p = code.opus != nil ? AudioJitterPolicy(preRoll: 0.06, lagThreshold: 0.6) : AudioJitterPolicy(preRoll: 0.08, lagThreshold: 1.0)
        if let ms = env["ICA_AUDIO_PREROLL_MS"].flatMap(Double.init), ms >= 0 { p.preRoll = ms / 1000 }
        if let ms = env["ICA_AUDIO_LAG_MS"].flatMap(Double.init), ms > 0 { p.lagThreshold = ms / 1000 }
        return p
    }
}

/// The playback queue's decisions, without any audio API (tests drive it directly). Chunks are decoded
/// WRITEs; "queued" means handed to the output and not yet played (completions arrive in order).
///
/// - Pre-roll: chunks are held until `target` frames are buffered, then released together.
/// - Underrun: the output ran dry while playing; the next chunks pre-roll again.
/// - Overrun (§10.2): queued + new > lag limit; the oldest queued audio is dropped down to the pre-roll
///   target and the output restarts with the newest chunks, so playback catches up without a gap.
/// - Drain (CLOSE, or a short sound that never reaches the target): held chunks are released at once, and
///   running dry afterwards is not an underrun.
/// The target is at least 1.5 chunks and the lag limit at least target + 2 chunks, so large WRITEs (PCM)
/// neither starve nor trip the limit.
public struct AudioJitterBuffer<Chunk> {
    public enum Decision {
        case hold
        /// Hand these to the output, in order.
        case schedule([Chunk])
        /// Stop the output (dropping what it has queued) and hand it these, the newest audio, in order.
        case replaceQueue([Chunk])
    }

    public let sampleRate: Double
    public let policy: AudioJitterPolicy
    public private(set) var prerolling = true
    public private(set) var draining = false
    public private(set) var pendingFrames = 0
    public private(set) var queuedFrames = 0
    public private(set) var underruns = 0
    public private(set) var overruns = 0
    public private(set) var largestChunk = 0
    private var pending: [Chunk] = []
    private var queued: [(chunk: Chunk, frames: Int)] = []
    private var pendingSizes: [Int] = []

    public init(sampleRate: Double, policy: AudioJitterPolicy) {
        self.sampleRate = sampleRate
        self.policy = policy
    }

    public var targetFrames: Int {
        max(Int(((policy.preRoll + policy.startMargin) * sampleRate).rounded()), largestChunk * 3 / 2)
    }

    public var lagFrames: Int { max(Int((policy.lagThreshold * sampleRate).rounded()), targetFrames + 2 * largestChunk) }

    public var heldChunks: Int { pending.count }
    public var queuedChunks: Int { queued.count }

    public mutating func push(_ chunk: Chunk, frames: Int) -> Decision {
        draining = false
        largestChunk = max(largestChunk, frames)
        if prerolling {
            pending.append(chunk)
            pendingSizes.append(frames)
            pendingFrames += frames
            return pendingFrames >= targetFrames ? release() : .hold
        }
        queued.append((chunk, frames))
        queuedFrames += frames
        guard queuedFrames > lagFrames else { return .schedule([chunk]) }
        overruns += 1
        while let first = queued.first, queuedFrames - first.frames >= targetFrames {
            queued.removeFirst()
            queuedFrames -= first.frames
        }
        return .replaceQueue(queued.map(\.chunk))
    }

    /// Releases what is held without waiting for the target (CLOSE, pre-roll timeout).
    public mutating func drain() -> [Chunk] {
        draining = true
        guard prerolling, !pending.isEmpty else { return [] }
        guard case .schedule(let chunks) = release() else { return [] }
        return chunks
    }

    /// The output finished the oldest queued chunk. True if this was an underrun (played dry while not draining).
    @discardableResult
    public mutating func played() -> Bool {
        guard !queued.isEmpty else { return false }
        queuedFrames -= queued.removeFirst().frames
        guard queued.isEmpty, !prerolling else { return false }
        queuedFrames = 0
        prerolling = true
        if draining { return false }
        underruns += 1
        return true
    }

    /// Everything dropped (stop, suspend, format change, configuration change).
    public mutating func reset() {
        pending = []
        pendingSizes = []
        pendingFrames = 0
        queued = []
        queuedFrames = 0
        prerolling = true
        draining = false
    }

    private mutating func release() -> Decision {
        let chunks = pending
        queued += zip(pending, pendingSizes).map { ($0, $1) }
        queuedFrames += pendingFrames
        pending = []
        pendingSizes = []
        pendingFrames = 0
        prerolling = false
        return .schedule(chunks)
    }
}

/// Plays session audio through the Mac's default output (docs/98 §10.2): AVAudioEngine with one
/// AVAudioPlayerNode connected to the main mixer **in the stream's format**, so the mixer converts the
/// rate and channel count; no sample-rate code of our own. Volume follows macOS (SET_CONTROL is ignored).
///
/// Everything runs on its own serial queue: the session queue only hands over decoded samples and
/// never waits for the audio hardware. The engine starts on the first data and stops 10 s after the last
/// sound played out, on suspend and on stop, so an idle session keeps no audio device busy.
public final class AudioPlayer: AudioSink {
    /// Diagnostics (audio queue): underruns, overruns, engine start failures, configuration changes.
    public var log: ((String) -> Void)?
    /// Idle time after the last played chunk before the engine stops.
    public var idleStop: TimeInterval = 10

    private let queue = DispatchQueue(label: "ica.audio", qos: .userInteractive)
    private let env: [String: String]
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var code: AudioFormatCode?
    private var jitter: AudioJitterBuffer<AVAudioPCMBuffer>?
    /// Completions of buffers scheduled before the last stop are ignored.
    private var generation = 0
    private var idleWork: DispatchWorkItem?
    private var prerollWork: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?
    private var stopped = false
    private var suspended = false
    private var startFailures = 0
    private var stats = Stats()

    private struct Stats {
        public var buffers = 0
        public var frames = 0
        public var underruns = 0
        public var overruns = 0
        public var engineStarts = 0
    }

    public init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // MARK: AudioSink (session queue → audio queue)

    public func audioOpen(device: UInt8, stream: AudioStreamFormat, code: AudioFormatCode) {
        guard device == AudioWire.playbackDevice else { return }
        queue.async { [self] in open(stream: stream, code: code) }
    }

    public func audioWrite(device: UInt8, samples: [Float]) {
        guard device == AudioWire.playbackDevice else { return }
        queue.async { [self] in write(samples) }
    }

    public func audioClose(device: UInt8) {
        guard device == AudioWire.playbackDevice else { return }
        queue.async { [self] in close() }
    }

    public func audioSuspend() {
        queue.async { [self] in
            suspended = true
            log?("suspended: queued audio dropped, output released")
            halt()
        }
    }

    public func audioResume() { queue.async { [self] in suspended = false } }

    public func audioStop() {
        queue.async { [self] in
            stopped = true
            halt()
            if let engine, let player {
                engine.detach(player)
            }
            player = nil
            engine = nil
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            log?("stopped: \(stats.buffers) buffers, \(stats.frames) frames, \(stats.underruns) underruns, \(stats.overruns) overruns")
        }
    }

    // MARK: Audio queue

    private func open(stream: AudioStreamFormat, code: AudioFormatCode) {
        guard !stopped else { return }
        guard let f = AVAudioFormat(standardFormatWithSampleRate: stream.sampleRate, channels: AVAudioChannelCount(stream.channels)) else {
            log?("no AVAudioFormat for \(stream)")
            return
        }
        let policy = AudioJitterPolicy.for(code, env: env)
        self.code = code
        if let format, format == f, let jitter, jitter.policy == policy {
            // Same format again (CLOSE, then OPEN for the next sound): the previous tail keeps playing.
            return
        }
        haltPlayer()
        if format != f {
            format = f
            if let engine, let player {
                engine.stop()
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: f)
            }
        }
        jitter = AudioJitterBuffer(sampleRate: stream.sampleRate, policy: policy)
        log?(String(format: "open %@: pre-roll %.0f ms, lag limit %.0f ms", code.description, (policy.preRoll + policy.startMargin) * 1000,
                    policy.lagThreshold * 1000))
    }

    private func write(_ samples: [Float]) {
        guard !stopped, !suspended, let format, jitter != nil else { return }
        let channels = Int(format.channelCount)
        let frames = samples.count / channels
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let out = data[c]
            for i in 0..<frames { out[i] = samples[i * channels + c] }
        }
        idleWork?.cancel()
        switch jitter!.push(buffer, frames: frames) {
        case .hold:
            armPrerollTimeout()
        case .schedule(let buffers):
            schedule(buffers)
        case .replaceQueue(let newest):
            stats.overruns += 1
            if stats.overruns <= 5 || stats.overruns % 50 == 0 {
                log?("overrun #\(stats.overruns): more than \(jitter!.lagFrames) frames queued; oldest dropped, \(jitter!.queuedFrames) kept")
            }
            haltPlayer(keepJitter: true)
            schedule(newest)
        }
    }

    private func close() {
        guard jitter != nil else { return }
        let held = jitter!.drain()
        if !held.isEmpty { schedule(held) }
        if jitter!.queuedFrames == 0 { armIdleStop() }
    }

    /// A short sound that stays below the pre-roll target still plays: release it once no more data came.
    private func armPrerollTimeout() {
        prerollWork?.cancel()
        guard let jitter else { return }
        let delay = jitter.policy.preRoll + jitter.policy.startMargin + 0.05
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.jitter?.prerolling == true, (self.jitter?.heldChunks ?? 0) > 0 else { return }
            let held = self.jitter!.drain()
            if !held.isEmpty { self.schedule(held) }
        }
        prerollWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func armIdleStop() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let engine = self.engine, engine.isRunning, (self.jitter?.queuedFrames ?? 0) == 0 else { return }
            self.player?.stop()
            engine.stop()
            self.log?("idle: output stopped")
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + idleStop, execute: work)
    }

    private func schedule(_ buffers: [AVAudioPCMBuffer]) {
        prerollWork?.cancel()
        guard !buffers.isEmpty, ensureRunning(), let player else {
            // No output: forget the queue so the next data pre-rolls again.
            jitter?.reset()
            return
        }
        let gen = generation
        for buffer in buffers {
            let frames = Int(buffer.frameLength)
            stats.buffers += 1
            stats.frames += frames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.played(generation: gen) }
            }
        }
        startPlayer()
    }

    /// `play()` on a node whose engine is not running raises an exception. The engine can stop between
    /// `ensureRunning` and here (a device change stops it on another thread), so check again right before,
    /// try one restart, and otherwise drop the queue: the next data pre-rolls and starts it again.
    private func startPlayer() {
        guard let player, !player.isPlaying else { return }
        if engine?.isRunning != true {
            guard ensureRunning(), engine?.isRunning == true else {
                log?("output stopped before playback started; queue dropped")
                haltPlayer()
                return
            }
        }
        player.play()
    }

    private func played(generation gen: Int) {
        guard gen == generation, jitter != nil else { return }
        if jitter!.played() {
            stats.underruns += 1
            if stats.underruns <= 5 || stats.underruns % 50 == 0 { log?("underrun #\(stats.underruns): pre-rolling again") }
        }
        if jitter!.queuedFrames == 0 { armIdleStop() }
    }

    /// Creates and starts the engine if needed. False if the output cannot start (no device, …).
    private func ensureRunning() -> Bool {
        guard let format else { return false }
        if engine == nil {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            engine = e
            player = p
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e,
                                                                    queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.configurationChanged() }
            }
        }
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            stats.engineStarts += 1
            return true
        } catch {
            startFailures += 1
            if startFailures <= 3 { log?("output did not start: \(error)") }
            return false
        }
    }

    /// The output device changed (or went away): the engine stopped and its queue is gone; the next data
    /// starts it again on the new default output.
    private func configurationChanged() {
        guard !stopped, let engine, let player, let format else { return }
        log?("output configuration changed: restarting on the next data")
        generation += 1
        jitter?.reset()
        prerollWork?.cancel()
        player.stop()
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Stops the player (dropping its queue) and, unless kept, the jitter state.
    private func haltPlayer(keepJitter: Bool = false) {
        generation += 1
        prerollWork?.cancel()
        player?.stop()
        if !keepJitter { jitter?.reset() }
    }

    private func halt() {
        haltPlayer()
        idleWork?.cancel()
        engine?.stop()
    }
}
