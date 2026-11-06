import CoreMedia
import CoreVideo
import Foundation

/// What the channel saw, for the §13 diagnosis (W1–W14: module rejected vs policy off vs never opened vs our
/// format/encoder). Session queue. No picture data, only counts, the host's capability list, its TYPE format blocks
/// and device paths.
public struct WebcamDiagnostics: Sendable {
    /// The module as built for the INIT_RESPONSE, once the WD asked for it (W6).
    public var moduleBytes: [UInt8] = []
    public var hostBytes = 0
    public var hostWrites = 0
    public var firstHostBytes: Date?
    public var commandCounts: [String: Int] = [:]
    public var bindRequests = 0
    public var bindCommits = 0
    /// The host's last BIND_REQUEST capability list and our answer (W2, W4).
    public var hostCapabilities: [WebcamElement] = []
    public var answeredCapabilities: [WebcamElement] = []
    public var bindResponseSent: [UInt8] = []
    public var bindCommitMissing = false
    public var contextRequests = 0
    public var deviceContexts = 0
    public var rejects = 0
    public var contextErrors = 0
    public var contextSuccesses = 0
    /// ORed "VDA Supported Encoder Formats" of the CREATE_CONTEXTs (H.264 = 2, legacy = 1).
    public var hostEncoderBits: UInt32 = 0
    public static let recentLimit = 8
    public var recentDevicePaths: [String] = []
    /// The host's TYPE format blocks, hex (W12, L4).
    public var recentFormatBlocks: [String] = []
    public var playWithoutAnswer = false
    public var controls: [String: Int] = [:]
    public var destroys = 0
    public var permissionRequests = 0
    public var permissionDenied = 0
    public var captureStarts = 0
    public var captureErrors = 0
    public var samplesSent = 0
    public var keyFramesSent = 0
    public var sampleBytesSent = 0
    public var fragmentsSent = 0
    public var largestSample = 0
    public var framesSkippedInFlight = 0
    public var framesSkippedBacklog = 0
    public var samplesDroppedBeforeKeyFrame = 0
    public var encodeErrors = 0
    public var malformed = 0
    public var unknownCommands = 0
    public var protocolErrors = 0

    mutating func noteFormatBlock(_ text: String) {
        recentFormatBlocks.append(text)
        if recentFormatBlocks.count > Self.recentLimit { recentFormatBlocks.removeFirst(recentFormatBlocks.count - Self.recentLimit) }
    }

    mutating func noteDevicePath(_ path: String) {
        recentDevicePaths.append(path)
        if recentDevicePaths.count > Self.recentLimit { recentDevicePaths.removeFirst(recentDevicePaths.count - Self.recentLimit) }
    }

    /// The §13 verdict for the end of a run. `appOpenedCamera`: a host app was made to open the camera.
    public func verdict(appOpenedCamera: Bool = false) -> String {
        if moduleBytes.isEmpty { return "no CTXMM module was built (camera off, or the WD never sent an INIT_RESPONSE)" }
        guard hostBytes > 0 else {
            return "W5: zero bytes on ch 18 — the host ignored the module or policy is off (Multimedia conferencing / "
                + "Windows Media Redirection, §12); rule out the module with W6 (INIT_RESPONSE dump, bind entry, 3/3 variant), then W7, W8"
        }
        guard bindRequests > 0 else {
            return "host sent \(hostBytes) B on ch 18 but no BIND_REQUEST: unexpected first command (\(commandCounts.keys.sorted().joined(separator: ", ")))"
        }
        var text = "W2: BIND_REQUEST [\(hostCapabilities.map(\.description).joined(separator: ", "))] — module accepted, the multimedia channel is open"
        guard bindCommits > 0 else {
            return text + "; W4: no BIND_COMMIT after our BIND_RESPONSE — compare it byte by byte with §4 (dropped type 2, answers 0/1/echo, no padding)"
        }
        text += "; W3: BIND_COMMIT, channel established"
        guard contextRequests > 0 else {
            return text + (appOpenedCamera
                ? "; no CREATE_CONTEXT although an app opened the camera (W9: most likely a 64-bit app; W10 if the app lists no camera)"
                : "; no CREATE_CONTEXT (normal: no host app opened the camera)")
        }
        if deviceContexts == 0 {
            return text + "; W11: \(contextRequests) CREATE_CONTEXT without DEVICE or with minor 0, answered 0x81 (media redirection or helper contexts)"
        }
        guard contextSuccesses > 0 else {
            return text + "; \(deviceContexts) device context(s) answered with the 0x86 error only (camera disabled, a second context, or no encoder)"
        }
        text += String(format: "; 0x86 success (H.264 352×288) for %d device context(s), host encoder bits 0x%x", contextSuccesses, hostEncoderBits)
        guard (controls["PLAY"] ?? 0) > 0 else {
            return text + "; W12: no PLAY — the host may have rejected our format answer (check §5.3: FOURCC 30 32 34 49, offset 24, 0x4A400); "
                + "host format blocks: \(recentFormatBlocks.isEmpty ? "none" : recentFormatBlocks.joined(separator: " | "))"
        }
        guard samplesSent > 0 else {
            return text + "; PLAY \(controls["PLAY"] ?? 0)× but no frame sent (permission denied \(permissionDenied), capture errors \(captureErrors), "
                + "encode errors \(encodeErrors))"
        }
        return text + "; frames flowing: \(samplesSent) samples (\(keyFramesSent) key), \(sampleBytesSent) B in \(fragmentsSent) fragments; "
            + "if the picture is wrong see W13 (Annex B, SPS/PPS, fragments) and W14 (IDR after PLAY)"
    }
}

/// Virtual channel engine for HDX webcam redirection over `CTXMM  ` (channel 18, docs/98b-webcam.md).
///
/// - The module (§1.3) is 50 bytes: the common VD header with versions 3/0, flow type 0, VD data `84 13`.
/// - The host speaks first (BIND_REQUEST); the client answers BIND_RESPONSE per §4 and the host sends BIND_COMMIT.
///   No credits, no flow control.
/// - CREATE_CONTEXT: only DEVICE contexts with minor ≠ 0 after BIND are served. The encoder is created and the
///   208-byte 0x86 success (H.264 352×288 15 fps 160 kbit/s) goes out; **the camera is not touched**. Others get
///   0x81 (non-device) or the 24-byte 0x86 error (0x40001: before BIND, a second context, camera disabled, no encoder).
/// - CONTROL PLAY: camera permission is asked for at the first PLAY only; then the source starts and every frame is
///   encoded (key frame first and at least every 2 s) and sent as TRANSMIT fragments of ≤ 4000 B. A denied
///   permission or a failing source answers the 0x86 error. PAUSE/STOP stop the source (the encoder stays);
///   DESTROY releases everything of that major.
/// - Privacy: the source never runs while the link is down; after a link drop it stays off until the next PLAY.
///   Logoff, disconnect, the session end and "Disable Camera for This Session" stop it at once.
/// - Backpressure (§8): one frame in flight; a camera frame is skipped (before encoding) while the transport holds
///   more than `backlogLimit` unacknowledged bytes.
///
/// Call everything on the session queue; `onEvent` is called there.
public final class WebcamEngine: VirtualChannelEngine, VirtualChannelModule {
    public struct Config: Sendable {
        public var format = WebcamFormat.standard
        /// Skip camera frames while the transport holds more unacknowledged bytes than this (§8: ~64 KB).
        public var backlogLimit = 64 << 10
        /// A key frame at least this often (§7.2 [P]).
        public var keyFrameInterval: Double = 2
        /// W4: log when no BIND_COMMIT follows our BIND_RESPONSE within this time.
        public var bindCommitTimeout: TimeInterval = 10
        /// W12: log when no PLAY follows a 0x86 success within this time.
        public var playTimeout: TimeInterval = 10
        /// The module's max version: 0 as the reference (§1.1); 3 only for the W6 diagnostic run (icactl camtest).
        public var moduleVersionHigh = WebcamWire.versionHigh

        public init() {}
    }

    public enum Event: CustomStringConvertible {
        /// The module as handed to the WD (hex in the description, for §13 W6).
        case module([UInt8])
        /// One handled host message or state change.
        case command(String)
        /// The frame source started (true) or stopped (false): the "camera in use" indicator.
        case capturing(Bool)
        /// The camera permission was denied at a PLAY (the app shows a one-time note).
        case cameraDenied
        case stopped

        public var description: String {
            switch self {
            case .module(let bytes): return "module \(bytes.count) B: " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            case .command(let text): return text
            case .capturing(let on): return on ? "camera on" : "camera off"
            case .cameraDenied: return "camera permission denied"
            case .stopped: return "stopped"
            }
        }
    }

    public enum CaptureState: Equatable, Sendable {
        /// No context.
        case idle
        /// A context with its encoder; the camera is off.
        case ready
        /// PLAY received; waiting for the permission answer.
        case awaitingPermission
        /// The source runs (between PLAY and PAUSE/STOP/DESTROY).
        case playing
        /// Permission denied or the source failed; the host got the 0x86 error.
        case failed
    }

    public struct Context: Equatable, Sendable {
        public var major: UInt32
        public var minor: UInt32
        public var device: WebcamDeviceProperty?
    }

    public let channelName = WebcamWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((Event) -> Void)?
    public let config: Config
    public private(set) var diagnostics = WebcamDiagnostics()

    /// The camera (app) or the test pattern (icactl, tests). Nil: PLAY answers the 0x86 error.
    public var source: WebcamFrameSource?
    /// Brings work back onto the session queue (permission answers, frames, encoded samples). Nil: inline (tests).
    public var schedule: ((@escaping () -> Void) -> Void)?
    /// Runs a block on the session queue after a delay (the W4/W12 checks). Nil: no timed checks.
    public var scheduleAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    /// Unacknowledged transport bytes (§8 backpressure). Nil: no backlog check.
    public var backlog: (() -> Int)?
    /// The encoder for a new context (tests inject their own).
    public var makeEncoder: (WebcamFormat) throws -> WebcamVideoEncoder = { try WebcamH264Encoder(format: $0) }
    /// Every sample as it goes out (icactl writes the synthetic stream to a file; the app never sets it).
    public var sampleTap: ((WebcamEncodedSample) -> Void)?

    public private(set) var state = CaptureState.idle
    public private(set) var context: Context?
    /// The user disabled the camera for this session, or the session is ending: no source starts again.
    public private(set) var cameraDisabled = false
    public private(set) var sourceRunning = false
    private var encoder: WebcamVideoEncoder?
    private var parser = WebcamStreamParser()
    private var bindSeen = false
    private var linkDown = false
    private var ended = false
    private var generation = 0
    private var inFlight = false
    private var needKeyFrame = true
    private var lastKeyFrameTime: Double?
    private var samplesThisRun = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The 50-byte module (§1.3).
    public func module(channel: UInt8, date: Date) -> [UInt8] {
        let bytes = WDModules.webcam(channel: channel, versionHigh: config.moduleVersionHigh, date: date)
        diagnostics.moduleBytes = bytes
        onEvent?(.module(bytes))
        return bytes
    }

    public func receive(_ data: Data) {
        guard !ended else { return }
        if diagnostics.firstHostBytes == nil { diagnostics.firstHostBytes = Date() }
        diagnostics.hostBytes += data.count
        diagnostics.hostWrites += 1
        let messages = parser.feed(data) { [self] error in
            diagnostics.protocolErrors += 1
            log("protocol error: \(error)")
        }
        for message in messages {
            let parsed = WebcamMessage.parse(message)
            diagnostics.commandCounts[parsed.name, default: 0] += 1
            if case .transmit = parsed {} else { log("← \(parsed.name) \(message.count) B: " + hex(message, limit: 64)) }
            handle(parsed)
        }
    }

    /// The CGP link went down: the camera goes off and stays off until the next PLAY (§10.4).
    public func suspend() {
        guard !ended else { return }
        linkDown = true
        if state == .playing || state == .awaitingPermission {
            stopCapture(to: .ready, reason: "link down; stays off until the next PLAY")
        }
    }

    public func resume() {
        guard !ended else { return }
        linkDown = false
        if context != nil { log("link back; the camera stays off until the host sends PLAY") }
    }

    /// Stops the camera now and keeps it off for the rest of this session: the session is closing or logging off,
    /// or the user chose "Disable Camera for This Session". With `notifyHost`, an open context gets the 0x86 error
    /// (§10.4) and is forgotten; later device contexts are answered with the error.
    public func disableCamera(notifyHost: Bool, reason: String) {
        guard !cameraDisabled else { return }
        cameraDisabled = true
        var note = ""
        if let context {
            stopCapture(to: .idle, reason: reason)
            if notifyHost, !ended {
                send(WebcamMessage.captureContextError(major: context.major, minor: context.minor))
                diagnostics.contextErrors += 1
                note = " → 0x86 error for \(context.major)/\(context.minor)"
            }
            releaseContext()
        }
        log("camera disabled for this session (\(reason))" + note)
    }

    /// Session end: nothing is sent any more.
    public func shutdown() {
        guard !ended else { return }
        ended = true
        cameraDisabled = true
        stopCapture(to: .idle, reason: "session ended")
        releaseContext()
        parser.reset()
        onEvent?(.stopped)
    }

    // MARK: Messages

    private func send(_ bytes: [UInt8]) { output?(.channel(Data(bytes))) }

    private func log(_ text: String) { onEvent?(.command(text)) }

    private func hex(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ") + (data.count > limit ? " …" : "")
    }

    private func handle(_ message: WebcamHostMessage) {
        switch message {
        case .bindRequest(let caps):
            diagnostics.bindRequests += 1
            if context != nil {
                // A repeated BIND starts over: the host forgot its contexts.
                stopCapture(to: .idle, reason: "BIND_REQUEST again")
                releaseContext()
            }
            bindSeen = true
            let answers = WebcamMessage.bindAnswers(caps)
            let reply = WebcamMessage.bindResponse(answers: answers)
            diagnostics.hostCapabilities = caps
            diagnostics.answeredCapabilities = answers
            diagnostics.bindResponseSent = reply
            send(reply)
            log("BIND_REQUEST [\(caps.map(\.description).joined(separator: ", "))] → BIND_RESPONSE \(reply.count) B: "
                + hex(Data(reply), limit: 64))
            if let scheduleAfter {
                let commits = diagnostics.bindCommits
                scheduleAfter(config.bindCommitTimeout) { [weak self] in
                    guard let self, !self.ended, self.diagnostics.bindCommits == commits else { return }
                    self.diagnostics.bindCommitMissing = true
                    self.log("W4: no BIND_COMMIT within \(Int(self.config.bindCommitTimeout)) s of our BIND_RESPONSE")
                }
            }

        case .bindCommit(let caps):
            diagnostics.bindCommits += 1
            log("BIND_COMMIT [\(caps.map(\.description).joined(separator: ", "))]: channel established (W3)")

        case .createContext(let request):
            createContext(request)

        case .updateContext(let length):
            log("UPDATE_CONTEXT (\(length) B) → ignored")

        case let .destroyContext(major, minor):
            diagnostics.destroys += 1
            if let context, context.major == major {
                stopCapture(to: .idle, reason: "DESTROY_CONTEXT \(major)/\(minor)")
                releaseContext()
                log("DESTROY_CONTEXT \(major)/\(minor): context \(context.major)/\(context.minor) released")
            } else {
                log("DESTROY_CONTEXT \(major)/\(minor): no context with that major")
            }

        case .transmit(let length):
            if diagnostics.commandCounts["TRANSMIT"] == 1 { log("host TRANSMIT (\(length) B) → ignored") }

        case let .control(major, minor, controls):
            for type in controls { control(type, major: major, minor: minor) }
            if controls.isEmpty { log("CONTROL \(major)/\(minor) without controls") }

        case let .unknown(command, length):
            diagnostics.unknownCommands += 1
            log(String(format: "unknown command 0x%02x (%d B) → skipped", command, length))

        case let .malformed(command, length, reason):
            diagnostics.malformed += 1
            log(String(format: "malformed command 0x%02x (%d B, %@) → skipped", command, length, reason))
        }
    }

    private func createContext(_ request: WebcamContextRequest) {
        diagnostics.contextRequests += 1
        diagnostics.hostEncoderBits |= request.encoderBits
        for type in request.mediaTypes where !type.formatBlock.isEmpty {
            diagnostics.noteFormatBlock("cbFormat \(type.formatSize): " + hex(type.formatBlock, limit: 96))
        }
        let ids = "\(request.major)/\(request.minor)"
        let types = request.mediaTypes.map { WebcamMediaType.guidString($0.subtype) }.joined(separator: ", ")
        var text = "CREATE_CONTEXT \(ids): \(request.properties.count) properties, subtypes [\(types)], "
            + String(format: "VDA Supported Encoder Formats 0x%x", request.encoderBits)
        if let device = request.device {
            diagnostics.noteDevicePath(device.path)
            text += ", DEVICE \"\(device.friendlyName)\"" + (device.deviceID.map { " id \($0)" } ?? "")
        }
        if !request.issues.isEmpty { text += " (parse: \(request.issues.joined(separator: "; ")))" }
        guard request.isDeviceContext else {
            let status = bindSeen ? WebcamWire.Status.failed : WebcamWire.Status.deviceFailure
            send(WebcamMessage.contextReject(major: request.major, minor: request.minor, status: status))
            diagnostics.rejects += 1
            return log(text + String(format: " → 0x81 reject (%@, status 0x%08x; W11)", request.device == nil ? "no DEVICE" : "minor 0", status))
        }
        diagnostics.deviceContexts += 1
        // Status of a refused device context (docs/98b §5.4): this is the answer to the request, so the §5.4 rule
        // applies — E_FAIL once BIND has been seen, 0x40001 before. That covers our added refusals too (a second
        // context, the camera disabled for this session, no encoder). Failures after the 0x86 success are
        // unsolicited and always 0x40001 (`deviceFailure`, `disableCamera`).
        let status = bindSeen ? WebcamWire.Status.failed : WebcamWire.Status.deviceFailure
        func fail(_ why: String) {
            send(WebcamMessage.captureContextError(major: request.major, minor: request.minor, status: status))
            diagnostics.contextErrors += 1
            log(text + String(format: " → 0x86 error 0x%08x (%@)", status, why))
        }
        if !bindSeen { return fail("before BIND") }
        if cameraDisabled { return fail("camera disabled for this session") }
        if let context {
            guard context.major == request.major, context.minor == request.minor else {
                return fail("context \(context.major)/\(context.minor) is active; one at a time")
            }
            // The same handles again: replace the old context.
            stopCapture(to: .idle, reason: "context \(ids) re-created")
            releaseContext()
        }
        let made: WebcamVideoEncoder
        do { made = try makeEncoder(config.format) } catch { return fail("no encoder: \(error)") }
        encoder = made
        context = Context(major: request.major, minor: request.minor, device: request.device)
        state = .ready
        send(WebcamMessage.captureContextSuccess(major: request.major, minor: request.minor, format: config.format))
        diagnostics.contextSuccesses += 1
        var extra = ""
        if let vt = made as? WebcamH264Encoder {
            extra = vt.lowLatency ? ", low-latency rate control" : ""
            if !vt.refusedProperties.isEmpty { extra += ", encoder refused \(vt.refusedProperties.joined(separator: "/"))" }
        }
        log(text + " → 0x86 success (\(config.format)\(extra)); camera not opened until PLAY")
        if let scheduleAfter {
            let plays = diagnostics.controls["PLAY"] ?? 0
            scheduleAfter(config.playTimeout) { [weak self] in
                guard let self, !self.ended, self.context?.major == request.major, self.context?.minor == request.minor,
                      (self.diagnostics.controls["PLAY"] ?? 0) == plays else { return }
                self.diagnostics.playWithoutAnswer = true
                self.log("W12: no PLAY within \(Int(self.config.playTimeout)) s of the 0x86 success for \(ids)")
            }
        }
    }

    private func control(_ type: UInt32, major: UInt32, minor: UInt32) {
        let name = WebcamWire.Control.name(type)
        diagnostics.controls[name, default: 0] += 1
        guard let context, context.major == major, context.minor == minor else {
            return log("CONTROL \(name) \(major)/\(minor): unknown context → skipped")
        }
        switch type {
        case WebcamWire.Control.play:
            play(context)
        case WebcamWire.Control.pause, WebcamWire.Control.stop:
            if state == .playing || state == .awaitingPermission {
                stopCapture(to: .ready, reason: name)
            } else {
                log("CONTROL \(name): camera already off")
            }
        default:
            log("CONTROL \(name) → no action")
        }
    }

    private func play(_ context: Context) {
        switch state {
        case .playing: return log("PLAY: already capturing")
        case .awaitingPermission: return log("PLAY: the permission answer is pending")
        default: break
        }
        guard !cameraDisabled else { return deviceFailure(context, "camera disabled for this session") }
        guard let source else { return deviceFailure(context, "no frame source") }
        generation += 1
        let run = generation
        state = .awaitingPermission
        diagnostics.permissionRequests += 1
        log("PLAY \(context.major)/\(context.minor) → asking for camera permission (\(source.sourceDescription))")
        source.requestPermission { [weak self] granted in
            self?.onSession {
                guard let self, !self.ended, self.generation == run, self.state == .awaitingPermission,
                      self.context == context else { return }
                guard granted, !self.cameraDisabled else {
                    self.diagnostics.permissionDenied += 1
                    self.deviceFailure(context, "camera permission denied")
                    self.onEvent?(.cameraDenied)
                    return
                }
                if self.linkDown {
                    self.state = .ready
                    return self.log("camera permission granted while the link is down → stays off until the next PLAY")
                }
                self.startSource(source)
            }
        }
    }

    /// A client-side device failure after the 0x86 success: the 0x86 error (0x40001), camera off (§5.4, §8).
    private func deviceFailure(_ context: Context, _ why: String) {
        stopCapture(to: .failed, reason: why)
        send(WebcamMessage.captureContextError(major: context.major, minor: context.minor))
        diagnostics.contextErrors += 1
        log("\(why) → 0x86 error 0x00040001 for \(context.major)/\(context.minor)")
    }

    private func onSession(_ block: @escaping () -> Void) {
        if let schedule { schedule(block) } else { block() }
    }

    private func startSource(_ source: WebcamFrameSource) {
        guard !ended, !linkDown, !cameraDisabled, !sourceRunning, let context, encoder != nil else { return }
        generation += 1
        let run = generation
        inFlight = false
        needKeyFrame = true
        lastKeyFrameTime = nil
        samplesThisRun = 0
        do {
            try source.start(format: config.format, deliver: { [weak self] frame, time in
                self?.onSession { self?.frameArrived(frame, time: time, run: run) }
            }, failed: { [weak self] why in
                self?.onSession { self?.sourceFailed(why, run: run) }
            })
        } catch {
            diagnostics.captureErrors += 1
            return deviceFailure(context, "camera failed to start: \(error)")
        }
        sourceRunning = true
        state = .playing
        diagnostics.captureStarts += 1
        onEvent?(.capturing(true))
        log("camera on (\(source.sourceDescription)); first sample is a key frame")
    }

    /// The running source failed later (runtime error, interruption, device gone): camera off, unsolicited 0x86 error.
    private func sourceFailed(_ why: String, run: Int) {
        guard !ended, run == generation, sourceRunning, let context else { return }
        diagnostics.captureErrors += 1
        deviceFailure(context, "camera failed: \(why)")
    }

    /// Stops the source (if it runs), drops frames and samples still on their way, and sets the state.
    private func stopCapture(to newState: CaptureState, reason: String) {
        generation += 1
        inFlight = false
        let wasRunning = sourceRunning
        if sourceRunning {
            sourceRunning = false
            source?.stop()
            onEvent?(.capturing(false))
        }
        state = context == nil ? .idle : newState
        if wasRunning { log("camera off (\(reason)): \(samplesThisRun) samples this run, \(diagnostics.samplesSent) in total") }
    }

    private func releaseContext() {
        encoder?.invalidate()
        encoder = nil
        context = nil
        state = .idle
    }

    // MARK: Frames (§7, §8)

    private func gatesOpen(_ run: Int) -> Bool {
        !ended && run == generation && state == .playing && sourceRunning && !linkDown && !cameraDisabled && context != nil && encoder != nil
    }

    private func frameArrived(_ frame: CVPixelBuffer, time: CMTime, run: Int) {
        guard gatesOpen(run), let encoder else { return }
        if inFlight {
            diagnostics.framesSkippedInFlight += 1
            return
        }
        if let backlog, backlog() > config.backlogLimit {
            diagnostics.framesSkippedBacklog += 1
            if diagnostics.framesSkippedBacklog == 1 || diagnostics.framesSkippedBacklog % 100 == 0 {
                log("backlog above \(config.backlogLimit) B: \(diagnostics.framesSkippedBacklog) camera frames skipped before encoding so far")
            }
            return
        }
        let seconds = time.seconds
        let force = needKeyFrame || lastKeyFrameTime.map { seconds - $0 >= config.keyFrameInterval } ?? true
        inFlight = true
        encoder.encode(frame, time: time, forceKeyFrame: force) { [weak self] sample in
            self?.onSession { self?.sampleEncoded(sample, run: run) }
        }
    }

    private func sampleEncoded(_ sample: WebcamEncodedSample?, run: Int) {
        guard gatesOpen(run), let context else { return }
        inFlight = false
        guard let sample else {
            diagnostics.encodeErrors += 1
            return
        }
        if needKeyFrame && !sample.isKeyFrame {
            // The stream must start with an IDR (§7.2): the next frame is forced again.
            diagnostics.samplesDroppedBeforeKeyFrame += 1
            return
        }
        if sample.isKeyFrame {
            needKeyFrame = false
            lastKeyFrameTime = sample.time
            diagnostics.keyFramesSent += 1
        }
        let fragments = WebcamMessage.transmit(major: context.major, minor: context.minor, sample: sample.data)
        for fragment in fragments { send(fragment) }
        sampleTap?(sample)
        diagnostics.samplesSent += 1
        diagnostics.sampleBytesSent += sample.data.count
        diagnostics.fragmentsSent += fragments.count
        diagnostics.largestSample = max(diagnostics.largestSample, sample.data.count)
        samplesThisRun += 1
        if samplesThisRun == 1 {
            let types = AnnexB.units(sample.data).compactMap(AnnexB.nalType).map(String.init).joined(separator: ",")
            log("first sample: \(sample.data.count) B, key \(sample.isKeyFrame), NAL types [\(types)], \(fragments.count) fragment(s)")
        } else if samplesThisRun % 150 == 0 {
            log("\(samplesThisRun) samples this run (\(diagnostics.sampleBytesSent) B in total, \(diagnostics.keyFramesSent) key)")
        }
    }
}
