import Foundation

/// Where decoded audio goes: the app's player (`AudioPlayer`), icactl's WAV writer, or both
/// (`AudioSinkGroup`). Called on the session queue; implementations must not block it.
public protocol AudioSink: AnyObject {
    /// A playback device was opened (or re-opened with a new format).
    func audioOpen(device: UInt8, stream: AudioStreamFormat, code: AudioFormatCode)
    /// Decoded samples of one WRITE, interleaved.
    func audioWrite(device: UInt8, samples: [Float])
    /// CLOSE: what is buffered may still play out.
    func audioClose(device: UInt8)
    /// The link is down (CGP suspended): drop buffered audio, release the output.
    func audioSuspend()
    /// The link is back; new WRITEs follow.
    func audioResume()
    /// The session ended: stop for good.
    func audioStop()
}

public extension AudioSink {
    func audioSuspend() {}
    func audioResume() {}
}

/// Forwards to several sinks in order.
public final class AudioSinkGroup: AudioSink {
    public let sinks: [AudioSink]
    public init(_ sinks: [AudioSink]) { self.sinks = sinks }
    public func audioOpen(device: UInt8, stream: AudioStreamFormat, code: AudioFormatCode) {
        sinks.forEach { $0.audioOpen(device: device, stream: stream, code: code) }
    }
    public func audioWrite(device: UInt8, samples: [Float]) { sinks.forEach { $0.audioWrite(device: device, samples: samples) } }
    public func audioClose(device: UInt8) { sinks.forEach { $0.audioClose(device: device) } }
    public func audioSuspend() { sinks.forEach { $0.audioSuspend() } }
    public func audioResume() { sinks.forEach { $0.audioResume() } }
    public func audioStop() { sinks.forEach { $0.audioStop() } }
}

/// What the channel saw, for the §13 diagnosis ("module rejected" vs "policy disabled" vs "we didn't send
/// credits"). Session queue.
public struct AudioDiagnostics: Sendable {
    /// The module as built for the INIT_RESPONSE (count and caps), once the WD asked for it.
    public var moduleBytes: [UInt8] = []
    public var hostBytes = 0
    public var hostWrites = 0
    public var firstHostBytes: Date?
    public var commandCounts: [String: Int] = [:]
    /// INIT: version, the second byte, the caps (version ≥ 3).
    public var initVersion: UInt8?
    public var initReserved: UInt8?
    public var initCaps: UInt32?
    public var initialCreditsSent = false
    /// Sums of the credits sent, by kind.
    public var creditsSent: [UInt8: Int] = [:]
    public var hostCapInfo: [UInt8: [AudioFormatCode]] = [:]
    public var replyCapInfo: [UInt8: [AudioFormatCode]] = [:]
    /// How many entries the `recent…` lists keep: a long session never grows them.
    public static let recentLimit = 16
    public var openCount = 0
    public var decodableOpenCount = 0
    /// The last `recentLimit` OPENs.
    public var recentOpens: [(device: UInt8, code: AudioFormatCode, decoder: Bool)] = []
    public var writes = 0
    public var writeBytes = 0
    public var decodedFrames = 0
    public var decodeErrors = 0
    /// WRITE_V2 sequence numbers that did not follow the previous one.
    public var sequenceGaps = 0
    public var setControlCount = 0
    /// The last `recentLimit` SET_CONTROL commands, as sent.
    public var recentSetControls: [[UInt8]] = []
    public var readWriteV2 = false
    /// Uplink: READ_DATA frames sent, their packet bytes, encode errors, and the OPEN answers.
    public var captureFramesSent = 0
    public var captureBytesSent = 0
    public var captureEncodeErrors = 0
    public var captureOpenResults: [String] = []

    mutating func noteOpen(_ device: UInt8, _ code: AudioFormatCode, decoder: Bool) {
        openCount += 1
        if decoder { decodableOpenCount += 1 }
        recentOpens.append((device, code, decoder))
        if recentOpens.count > Self.recentLimit { recentOpens.removeFirst(recentOpens.count - Self.recentLimit) }
    }

    mutating func noteSetControl(_ bytes: [UInt8]) {
        setControlCount += 1
        recentSetControls.append(bytes)
        if recentSetControls.count > Self.recentLimit { recentSetControls.removeFirst(recentSetControls.count - Self.recentLimit) }
    }

    /// The §13 verdict for the end of a run. `soundTriggered`: the test tried to make the host play a sound.
    public func verdict(soundTriggered: Bool) -> String {
        if moduleBytes.isEmpty { return "no CTXCAM module was built (audio off, or the WD never sent an INIT_RESPONSE)" }
        guard hostBytes > 0 else {
            return "D6: zero bytes on ch 19 — the host ignored the module or audio is disabled by policy (§12); "
                + "rule out the module with D7 (golden bytes, INIT_RESPONSE dump), then D8 (versions 1/4), D9, D10"
        }
        guard let version = initVersion else {
            return "host sent \(hostBytes) B on ch 19 but no INIT: unexpected first command (\(commandCounts.keys.sorted().joined(separator: ", ")))"
        }
        let initText = "D2: INIT version \(version) — module accepted and channel opened, so audio policy is on"
        guard initialCreditsSent else { return initText + "; D3: initial credits NOT sent (client bug)" }
        guard !hostCapInfo.isEmpty else {
            return initText + "; credits sent; no CAPINFO followed (host waits for something else, or its audio service is idle)"
        }
        let accepted = replyCapInfo[AudioWire.playbackDevice] ?? []
        if openCount == 0 {
            if accepted.isEmpty { return initText + "; D4: CAPINFO answered with no format we decode — add codecs (§11 step 6)" }
            return initText + "; CAPINFO answered with \(accepted.count) format(s); "
                + (soundTriggered ? "D4: a sound was triggered but no OPEN (format mismatch, or the host sound scheme is silent)"
                                  : "no OPEN (no sound was played)")
        }
        if decodableOpenCount == 0 { return initText + "; OPEN only with formats we cannot decode: \(recentOpens.map(\.code))" }
        if writes == 0 { return initText + "; OPEN \(recentOpens.map(\.code)) but no WRITE" }
        if decodedFrames == 0 { return initText + "; D5: \(writes) WRITEs but nothing decoded (decoder bug; check the dump)" }
        return initText + "; playback works: \(openCount) OPEN, \(writes) WRITEs (\(writeBytes) B), \(decodedFrames) frames decoded"
    }
}

/// Virtual channel engine for client audio mapping, `CTXCAM ` (channel 19, docs/98-audio.md): playback, and the
/// microphone when `Config.microphone` is set (caps 0x11 instead of 0x10; versions 1/2).
///
/// - The module (§1.4) is 55 bytes: the common VD header (no flow control) and the VD data `D8 FF 01` +
///   caps u32 at the odd offset 51.
/// - The host speaks first (INIT). The client then sends the initial credits `80 01 00 80 00`, `80 02 00 80 00`
///   (§4.1); without them the host would stay silent and it would look like policy.
/// - Every complete command is credited exactly once (§4.2 [P]): WRITEs in batches of 32 or after 200 ms idle
///   (`80 01 00 n`, `80 02 00 n`), CAPINFO with `80 01 00 01 00` + `80 02 00 01 00` after the reply, every
///   other command (also failures, unknown ids and unknown bytes) with `80 01 00 01 00`. INIT gets none.
/// - CAPINFO for the playback device: every offered PCM pair and every Opus pair AudioToolbox decodes, in the
///   host's order (§5.2). The capture device gets the Opus pairs AudioToolbox encodes, or m = 0 without the
///   microphone. Recording commands for the playback device answer RESET_DEVICE `81 dev 03` (§3.1).
/// - Capture (§7): OPEN of the capture device asks the source for permission (the app's first OPEN prompts),
///   then answers `84 02 80 02 40 00 00` (or `… FF`: denied, no source, no encoder) with one command credit.
///   START_RECORD starts the source; every 10 ms Opus packet goes out as READ_DATA (READ_DATA_V2 with RW V2)
///   followed by `80 01 00 01 00`. STOP_RECORD, CLOSE, suspend and the session end stop the source at once. A
///   source that fails sends `81 02 FF`; the device then ignores commands until RESET_ACK.
/// - SET_CONTROL (volume) is logged and ignored (§9): the session's mixer already applied it, and the Mac's
///   volume applies on output.
///
/// Call everything on the session queue; `onEvent` and the sink are called there.
public final class AudioEngine: VirtualChannelEngine, VirtualChannelModule {
    public struct Config: Sendable {
        /// Codecs offered in CAPINFO (`ICA_AUDIO_CODECS`).
        public var codecs: Set<AudioCodecKind> = Set(AudioCodecKind.allCases)
        /// The Opus subformats AudioToolbox decodes on this Mac (§10.1); empty = PCM only.
        public var opusSubformats: Set<UInt16> = OpusSupport.decodableSubformats
        public var capabilities: UInt32 = AudioWire.Caps.playback
        public var creditBatch = AudioWire.creditBatch
        public var creditIdleFlush = AudioWire.creditIdleFlush
        /// Announce and serve the capture device (caps bit 0x01). Needs `captureSource` at OPEN time.
        public var microphone = false
        /// The Opus subformats AudioToolbox encodes (capture CAPINFO reply).
        public var opusEncodeSubformats: Set<UInt16> = OpusSupport.encodableSubformats

        public init() {}

        /// The module's capability bits.
        public var announcedCapabilities: UInt32 { capabilities | (microphone ? AudioWire.Caps.audioInput : 0) }
    }

    public enum Event: CustomStringConvertible {
        /// The module as handed to the WD (hex in the description, for §13 D7).
        case module([UInt8])
        /// One handled host command (WRITEs are summarised at CLOSE and every 500th).
        case command(String)
        /// The capture source started (true) or stopped (false).
        case recording(Bool)
        /// The microphone permission was denied at a capture OPEN (the app shows a one-time note).
        case microphoneDenied
        case stopped

        public var description: String {
            switch self {
            case .module(let bytes): return "module \(bytes.count) B: " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            case .command(let text): return text
            case .recording(let on): return on ? "capture started" : "capture stopped"
            case .microphoneDenied: return "microphone permission denied"
            case .stopped: return "stopped"
            }
        }
    }

    public let channelName = AudioWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((Event) -> Void)?
    /// Decoded audio goes here; nil = decode and credit only.
    public var sink: AudioSink?
    /// Runs a block on the session queue after a delay (the idle credit flush). Nil: partial batches are
    /// only returned at the next batch boundary or at CLOSE.
    public var scheduleAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    public let config: Config
    public private(set) var diagnostics = AudioDiagnostics()

    /// The capture device's state (§7.1).
    public enum CaptureState: Equatable, Sendable {
        case closed
        /// OPEN received; waiting for the permission answer.
        case awaitingPermission(AudioFormatCode)
        case open(AudioFormatCode)
        case recording(AudioFormatCode)
        /// After `81 02 FF`: commands are ignored until RESET_ACK.
        case reset
    }

    /// Uplink audio: the microphone (app) or a tone (icactl, tests). Nil: capture OPENs fail.
    public var captureSource: AudioCaptureSource?
    /// Brings work back onto the session queue (permission answers, encoded frames). Nil: inline (tests).
    public var schedule: ((@escaping () -> Void) -> Void)?
    /// Where captured samples are encoded. Nil: inline in the source's callback (tests).
    public var captureQueue: DispatchQueue?
    /// The uplink encoder for an OPEN's format (tests inject their own).
    public var makeEncoder: (AudioFormatCode) -> AudioPacketEncoder? = { OpusEncoder($0) }
    public private(set) var captureState = CaptureState.closed
    private var captureGeneration = 0
    private var uplink: AudioUplink?
    private var startAfterOpen = false
    private var captureSequence: UInt16 = 0
    /// The CGP link is down (between suspend and resume): the source never runs, whatever the state.
    private var linkDown = false
    private var sourceRunning = false
    /// The user disabled the microphone for this session, or the session is ending: no source starts again and
    /// capture OPENs fail.
    public private(set) var microphoneDisabled = false

    private var parser = AudioStreamParser()
    private var decoders: [UInt8: AudioDecoder] = [:]
    /// Per open playback device: WRITEs, bytes and frames since OPEN, and the last WRITE_V2 sequence.
    private var streamStats: [UInt8: (writes: Int, bytes: Int, frames: Int, lastSequence: UInt16?)] = [:]
    private var uncreditedWrites = 0
    private var flushGeneration = 0
    private var ended = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The 55-byte module (§1.4).
    public func module(channel: UInt8, date: Date) -> [UInt8] {
        let bytes = WDModules.audio(capabilities: config.announcedCapabilities, channel: channel, date: date)
        diagnostics.moduleBytes = bytes
        onEvent?(.module(bytes))
        return bytes
    }

    public func receive(_ data: Data) {
        guard !ended else { return }
        if diagnostics.firstHostBytes == nil { diagnostics.firstHostBytes = Date() }
        diagnostics.hostBytes += data.count
        diagnostics.hostWrites += 1
        for item in parser.feed(data) {
            diagnostics.commandCounts[item.command.name, default: 0] += 1
            handle(item.command)
        }
    }

    /// The CGP link went down: buffered audio is stale.
    public func suspend() {
        guard !ended else { return }
        sink?.audioSuspend()
        linkDown = true
        if sourceRunning {
            stopSource()
            log("capture paused (link down)")
        }
    }

    public func resume() {
        guard !ended else { return }
        sink?.audioResume()
        linkDown = false
        if case .recording(let code) = captureState, !sourceRunning, !microphoneDisabled {
            startSource(code)
            log("capture resumed (link back)")
        }
    }

    /// Stops the microphone now and keeps it off for the rest of this session: the session is closing or
    /// logging off, or the user chose "Disable microphone". With `notifyHost`, a running capture is ended with
    /// `81 02 FF` (the host then RESET_ACKs; later OPENs are answered "failed").
    public func disableMicrophone(notifyHost: Bool, reason: String) {
        guard !microphoneDisabled else { return }
        microphoneDisabled = true
        var note = ""
        switch captureState {
        case .awaitingPermission:
            if notifyHost, !ended { answerOpen(ok: false, "microphone disabled"); note = " → pending OPEN answered failed" }
            stopCapture(to: .closed)
        case .open, .recording:
            if notifyHost, !ended {
                stopCapture(to: .reset)
                send(AudioReply.resetDevice(AudioWire.captureDevice, reason: AudioWire.ResetReason.streamError))
                note = " → RESET_DEVICE 0xFF"
            } else {
                stopCapture(to: .closed)
            }
        case .closed, .reset:
            break
        }
        log("microphone disabled for this session (\(reason))" + note)
    }

    /// Session end: nothing is sent any more, the sink stops.
    public func shutdown() {
        guard !ended else { return }
        ended = true
        for device in decoders.keys.sorted() { logClose(device, reason: "session ended") }
        decoders.removeAll()
        parser.reset()
        stopCapture(to: .closed)
        sink?.audioStop()
        onEvent?(.stopped)
    }

    /// Open playback devices (tests, diagnostics).
    public var openDevices: [UInt8] { decoders.keys.sorted() }

    // MARK: Commands

    private func send(_ bytes: [UInt8]) {
        if bytes.first == 0x80, bytes.count == 5 {
            diagnostics.creditsSent[bytes[1], default: 0] += Int(bytes[3]) | Int(bytes[4]) << 8
        }
        output?(.channel(Data(bytes)))
    }

    private func creditCommand() { send(AudioReply.credit(.command, count: 1)) }

    private func log(_ text: String) { onEvent?(.command(text)) }

    private func handle(_ command: AudioHostCommand) {
        switch command {
        case let .initialize(version, reserved, caps):
            diagnostics.initVersion = version
            diagnostics.initReserved = reserved
            diagnostics.initCaps = caps
            // A repeated INIT starts over: the host forgot its devices and credits.
            for device in decoders.keys.sorted() {
                logClose(device, reason: "INIT")
                sink?.audioClose(device: device)
            }
            decoders.removeAll()
            stopCapture(to: .closed)
            uncreditedWrites = 0
            flushGeneration += 1
            diagnostics.readWriteV2 = version >= 3 && (caps ?? 0) & AudioWire.Caps.readWriteV2 != 0
                && config.capabilities & AudioWire.Caps.readWriteV2 != 0
            for credit in AudioReply.initialCredits { send(credit) }
            diagnostics.initialCreditsSent = true
            var text = String(format: "INIT version %d byte2 0x%02x", version, reserved)
            if let caps { text += String(format: " caps 0x%08x", caps) }
            text += " → credits 128 commands / 128 buffers sent"
            if diagnostics.readWriteV2 { text += "; RW V2 on" }
            if version >= 4 { text += "; NOTE: version ≥ 4 although we announced max 2, kept legacy devices 1/2" }
            log(text)

        case let .requestCapInfo(device, listOffset, formats):
            diagnostics.hostCapInfo[device] = formats
            let accepted: [AudioFormatCode]
            if device == AudioWire.playbackDevice {
                accepted = formats.filter { AudioDecoders.understands($0, codecs: config.codecs, opusSubformats: config.opusSubformats) }
            } else if device == AudioWire.captureDevice {
                accepted = formats.filter(canCapture)
            } else {
                accepted = []
            }
            diagnostics.replyCapInfo[device] = accepted
            send(AudioReply.capInfo(device: device, formats: accepted))
            send(AudioReply.credit(.command, count: 1))
            send(AudioReply.credit(.buffer, count: 1))
            log("REQUEST_CAPINFO dev \(device) offset \(listOffset): host [\(formats.map(\.description).joined(separator: ", "))] → "
                + "reply [\(accepted.map(\.description).joined(separator: ", "))]")

        case let .open(device, code, extra):
            let extraHex = extra.map { String(format: "%02x", $0) }.joined()
            if device == AudioWire.playbackDevice {
                if decoders[device] != nil {
                    logClose(device, reason: "re-OPEN")
                    sink?.audioClose(device: device)
                    decoders[device] = nil
                }
                let decoder = AudioDecoders.make(code, codecs: config.codecs, opusSubformats: config.opusSubformats)
                diagnostics.noteOpen(device, code, decoder: decoder != nil)
                if let decoder {
                    decoders[device] = decoder
                    streamStats[device] = (0, 0, 0, nil)
                    sink?.audioOpen(device: device, stream: decoder.stream, code: code)
                    log("OPEN dev \(device) \(code) (extra \(extraHex)) → decoder ready")
                } else {
                    log("OPEN dev \(device) \(code) (extra \(extraHex)) → NOT decodable here; its WRITEs are dropped")
                }
                creditCommand()
            } else if device == AudioWire.captureDevice {
                diagnostics.noteOpen(device, code, decoder: false)
                openCapture(code)
            } else {
                diagnostics.noteOpen(device, code, decoder: false)
                creditCommand()
                log("OPEN unknown dev \(device) \(code) → ignored")
            }

        case .close(let device) where device == AudioWire.captureDevice:
            closeCapture()
            creditCommand()

        case .close(let device):
            if decoders[device] != nil {
                logClose(device, reason: "CLOSE")
                decoders[device] = nil
                sink?.audioClose(device: device)
            } else {
                log("CLOSE dev \(device) (not open)")
            }
            flushWriteCredits()
            creditCommand()

        case let .write(device, _, _, data):
            write(device: device, data: data, sequence: nil)

        case let .writeV2(device, _, sequence, _, data):
            write(device: device, data: data, sequence: sequence)

        case .readRequest(let device, _, _), .startRecord(let device), .stopRecord(let device), .resetRecord(let device):
            if device == AudioWire.playbackDevice {
                send(AudioReply.resetDevice(device, reason: AudioWire.ResetReason.wrongDeviceType))
                log("\(command.name) for playback dev \(device) → RESET_DEVICE 3")
            } else if device == AudioWire.captureDevice {
                recordingCommand(command)
            } else {
                log("\(command.name) dev \(device) → ignored (unknown device)")
            }
            creditCommand()

        case .resetAck(let device):
            if device == AudioWire.captureDevice, captureState == .reset {
                captureState = .closed
                log("RESET_ACK dev \(device): capture device usable again")
            } else {
                log("RESET_ACK dev \(device)")
            }
            creditCommand()

        case let .setControl(a, b, c, value):
            let bytes = [UInt8](command.encode())
            diagnostics.noteSetControl(bytes)
            log(String(format: "SET_CONTROL %02x %02x %02x value 0x%08x → ignored (volume follows macOS)", a, b, c, value))
            creditCommand()

        case .unknown(let byte):
            log(String(format: "unknown command 0x%02x: 1 byte consumed", byte))
            creditCommand()
        }
    }

    private func write(device: UInt8, data: Data, sequence: UInt16?) {
        diagnostics.writes += 1
        diagnostics.writeBytes += data.count
        if device == AudioWire.captureDevice {
            // A WRITE to the capture device: wrong type, credited at once (§3.1).
            send(AudioReply.resetDevice(device, reason: AudioWire.ResetReason.wrongDeviceType))
            send(AudioReply.credit(.command, count: 1))
            send(AudioReply.credit(.buffer, count: 1))
            log("WRITE to capture dev \(device) (\(data.count) B) → RESET_DEVICE 3")
            return
        }
        if let decoder = decoders[device] {
            let errorsBefore = decoder.errors
            let samples = decoder.decode(data)
            let frames = samples.count / max(1, decoder.stream.channels)
            diagnostics.decodedFrames += frames
            diagnostics.decodeErrors += decoder.errors - errorsBefore
            var stats = streamStats[device] ?? (0, 0, 0, nil)
            if stats.writes == 0 { log("first WRITE dev \(device): \(data.count) B → \(frames) frames") }
            if let sequence {
                if let last = stats.lastSequence, sequence != last &+ 1 { diagnostics.sequenceGaps += 1 }
                stats.lastSequence = sequence
            }
            stats.writes += 1
            stats.bytes += data.count
            stats.frames += frames
            streamStats[device] = stats
            if stats.writes % 500 == 0 { log("dev \(device): \(stats.writes) WRITEs, \(stats.bytes) B, \(stats.frames) frames so far") }
            if !samples.isEmpty { sink?.audioWrite(device: device, samples: samples) }
        } else if diagnostics.writes == 1 || diagnostics.writes % 500 == 0 {
            log("WRITE dev \(device) (\(data.count) B) without a decoder → dropped")
        }
        uncreditedWrites += 1
        if uncreditedWrites >= config.creditBatch {
            flushWriteCredits()
        } else if uncreditedWrites == 1, let scheduleAfter {
            // The first WRITE of a batch arms the idle flush; a full batch or a CLOSE cancels it.
            let generation = flushGeneration
            scheduleAfter(config.creditIdleFlush) { [weak self] in
                guard let self, !self.ended, self.flushGeneration == generation else { return }
                self.flushWriteCredits()
            }
        }
    }

    /// Returns the credits of the WRITEs since the last batch: `80 01 00 n`, `80 02 00 n` (§6.3).
    private func flushWriteCredits() {
        flushGeneration += 1
        guard uncreditedWrites > 0 else { return }
        let n = UInt16(uncreditedWrites)
        uncreditedWrites = 0
        send(AudioReply.credit(.command, count: n))
        send(AudioReply.credit(.buffer, count: n))
    }

    // MARK: Capture (§7)

    private func canCapture(_ code: AudioFormatCode) -> Bool {
        config.microphone && config.codecs.contains(.opus) && code.opus != nil && config.opusEncodeSubformats.contains(code.subformat)
    }

    private func onSession(_ block: @escaping () -> Void) {
        if let schedule { schedule(block) } else { block() }
    }

    private func answerOpen(ok: Bool, _ why: String) {
        send(AudioReply.openResponse(device: AudioWire.captureDevice, status: ok ? 0 : 0xFF))
        creditCommand()
        diagnostics.captureOpenResults.append(ok ? "ok" : why)
        if diagnostics.captureOpenResults.count > AudioDiagnostics.recentLimit { diagnostics.captureOpenResults.removeFirst() }
    }

    private func openCapture(_ code: AudioFormatCode) {
        if captureState == .reset {
            creditCommand()
            log("OPEN capture \(code) → ignored (device in reset state until RESET_ACK)")
            return
        }
        // A re-OPEN replaces the previous one; a still unanswered OPEN is answered "failed" first.
        if case .awaitingPermission = captureState { answerOpen(ok: false, "replaced by another OPEN") }
        stopCapture(to: .closed)
        guard !microphoneDisabled else {
            answerOpen(ok: false, "microphone disabled")
            log("OPEN capture \(code) → OPEN_RESPONSE failed (microphone disabled for this session)")
            return
        }
        guard canCapture(code) else {
            answerOpen(ok: false, config.microphone ? "format not encodable" : "microphone off")
            log("OPEN capture \(code) → OPEN_RESPONSE failed (\(config.microphone ? "format not encodable here" : "microphone off"))")
            return
        }
        guard let source = captureSource, let encoder = makeEncoder(code) else {
            answerOpen(ok: false, captureSource == nil ? "no capture source" : "no encoder")
            log("OPEN capture \(code) → OPEN_RESPONSE failed (\(captureSource == nil ? "no capture source" : "encoder not available"))")
            return
        }
        captureGeneration += 1
        let generation = captureGeneration
        captureState = .awaitingPermission(code)
        startAfterOpen = false
        log("OPEN capture \(code) → asking for microphone permission")
        source.requestPermission { [weak self] granted in
            self?.onSession {
                guard let self, !self.ended, self.captureGeneration == generation,
                      self.captureState == .awaitingPermission(code) else { return }
                guard granted, !self.microphoneDisabled else {
                    self.captureState = .closed
                    self.answerOpen(ok: false, "permission denied")
                    self.log("OPEN capture \(code) → OPEN_RESPONSE failed (microphone permission denied)")
                    self.onEvent?(.microphoneDenied)
                    return
                }
                self.uplink = AudioUplink(encoder: encoder)
                self.captureSequence = 0
                self.captureState = .open(code)
                self.answerOpen(ok: true, "")
                self.log("OPEN capture \(code) → OPEN_RESPONSE ok (640/64), \(encoder.frameCount)-frame packets")
                if self.startAfterOpen { self.startRecording(code) }
            }
        }
    }

    private func closeCapture() {
        switch captureState {
        case .reset:
            log("CLOSE capture → ignored (device in reset state until RESET_ACK)")
        case .awaitingPermission:
            answerOpen(ok: false, "closed before the permission answer")
            stopCapture(to: .closed)
            log("CLOSE capture before the permission answer → OPEN answered failed")
        case .closed:
            log("CLOSE capture (not open)")
        default:
            stopCapture(to: .closed)
            log("CLOSE capture: \(diagnostics.captureFramesSent) frames sent so far")
        }
    }

    private func recordingCommand(_ command: AudioHostCommand) {
        switch (command, captureState) {
        case (_, .reset):
            log("\(command.name) capture → ignored (device in reset state until RESET_ACK)")
        case (.startRecord, .open(let code)):
            startRecording(code)
        case (.startRecord, .awaitingPermission):
            startAfterOpen = true
            log("START_RECORD while the permission is pending → starts once granted")
        case (.startRecord, .recording):
            log("START_RECORD (already recording)")
        case (.stopRecord, .recording(let code)):
            stopCapture(to: .open(code))
            log("STOP_RECORD: \(diagnostics.captureFramesSent) frames sent so far")
        case (.stopRecord, .awaitingPermission):
            startAfterOpen = false
            log("STOP_RECORD while the permission is pending")
        default:
            // READ_REQUEST is ignored (push-based recorder), RESET_RECORD is a no-op, others do not apply.
            log("\(command.name) capture → no-op")
        }
    }

    private func startRecording(_ code: AudioFormatCode) {
        captureState = .recording(code)
        startAfterOpen = false
        if linkDown {
            log("START_RECORD while the link is down → capture starts after the resume")
        } else if !microphoneDisabled {
            startSource(code)
        }
    }

    /// Starts the source with a fresh frame buffer and encoder: nothing captured before a STOP, a pause or a
    /// re-OPEN is ever sent (§7.1).
    private func startSource(_ code: AudioFormatCode) {
        guard !linkDown, !microphoneDisabled, !sourceRunning else { return }
        if uplink == nil { uplink = makeEncoder(code).map { AudioUplink(encoder: $0) } }
        guard let source = captureSource, let uplink, let stream = code.opus else { return streamError("no source or encoder") }
        let generation = captureGeneration
        let queue = captureQueue
        let deliver: ([Float]) -> Void = { [weak self] samples in
            let work = {
                let packets = uplink.push(samples)
                let errors = uplink.errors
                guard !packets.isEmpty || errors > 0 else { return }
                self?.onSession { self?.sendFrames(packets, encodeErrors: errors, generation: generation) }
            }
            if let queue { queue.async(execute: work) } else { work() }
        }
        do {
            try source.start(format: stream, deliver: deliver)
            sourceRunning = true
            onEvent?(.recording(true))
            log("START_RECORD → capture started (\(stream), 10 ms Opus packets)")
        } catch {
            streamError("\(error)")
        }
    }

    private func sendFrames(_ packets: [Data], encodeErrors: Int, generation: Int) {
        guard !ended, generation == captureGeneration, case .recording = captureState, sourceRunning, !linkDown else { return }
        diagnostics.captureEncodeErrors = encodeErrors
        for packet in packets {
            if diagnostics.readWriteV2 {
                send(AudioReply.readDataV2(device: AudioWire.captureDevice, sequence: captureSequence, packet: packet))
                captureSequence &+= 1
            } else {
                send(AudioReply.readData(device: AudioWire.captureDevice, packet: packet))
            }
            creditCommand()
            diagnostics.captureFramesSent += 1
            diagnostics.captureBytesSent += packet.count
            if diagnostics.captureFramesSent == 1 { log("first capture frame: \(packet.count) B packet") }
        }
    }

    /// The source failed: `81 02 FF`, stop, ignore commands until RESET_ACK (§7.1).
    private func streamError(_ why: String) {
        stopCapture(to: .reset)
        send(AudioReply.resetDevice(AudioWire.captureDevice, reason: AudioWire.ResetReason.streamError))
        log("capture error (\(why)) → RESET_DEVICE 0xFF; waiting for RESET_ACK")
    }

    /// Stops the source and drops its frame buffer, and frames still on their way (generation).
    private func stopSource() {
        guard sourceRunning else { return }
        sourceRunning = false
        captureSource?.stop()
        captureGeneration += 1
        uplink = nil
        onEvent?(.recording(false))
    }

    /// Stops the source (if it runs), drops frames still on their way, and sets the state.
    private func stopCapture(to state: CaptureState) {
        stopSource()
        captureGeneration += 1
        startAfterOpen = false
        uplink = nil
        captureState = state
    }

    private func logClose(_ device: UInt8, reason: String) {
        let s = streamStats[device] ?? (0, 0, 0, nil)
        let rate = decoders[device]?.stream.sampleRate ?? 0
        let seconds = rate > 0 ? Double(s.frames) / rate : 0
        log(String(format: "%@ dev %d: %d WRITEs, %d B, %d frames (%.2f s)", reason, device, s.writes, s.bytes, s.frames, seconds))
        streamStats[device] = nil
    }
}
