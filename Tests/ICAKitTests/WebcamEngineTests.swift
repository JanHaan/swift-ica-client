import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }

/// A frame source that never opens anything: records permission requests (answered by the test), starts and stops,
/// and lets the test push frames.
private final class FakeCamera: WebcamFrameSource {
    let sourceDescription = "fake"
    var permissionRequests: [(Bool) -> Void] = []
    var autoGrant: Bool?
    var starts = 0
    var stops = 0
    var running = false
    var failStart = false
    private var deliver: ((CVPixelBuffer, CMTime) -> Void)?
    private var failed: ((String) -> Void)?
    let frameBuffer: CVPixelBuffer

    init() {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 352, 288, WebcamPixelBuffers.pixelFormat, nil, &b)
        frameBuffer = b!
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if let autoGrant { completion(autoGrant) } else { permissionRequests.append(completion) }
    }

    func start(format: WebcamFormat, deliver: @escaping (CVPixelBuffer, CMTime) -> Void, failed: @escaping (String) -> Void) throws {
        if failStart { throw NSError(domain: "fake", code: 1) }
        starts += 1
        running = true
        self.deliver = deliver
        self.failed = failed
        lastFailed = failed
    }

    /// The last run's failure callback, kept after `stop` (to check the engine ignores stale reports).
    var lastFailed: ((String) -> Void)?

    /// A later failure (runtime error, interruption, the device gone), as the camera reports it.
    func fail(_ why: String) {
        let f = failed
        running = false
        deliver = nil
        failed = nil
        f?(why)
    }

    func stop() {
        stops += 1
        running = false
        deliver = nil
        failed = nil
    }

    /// One frame at `seconds`, if the source runs.
    func push(_ seconds: Double) {
        deliver?(frameBuffer, CMTime(seconds: seconds, preferredTimescale: 600))
    }
}

/// Answers synchronously (or holds the completion with `hold`); a key frame exactly when forced (unless
/// `nonKeyEvenIfForced` says otherwise).
private final class FakeEncoder: WebcamVideoEncoder {
    var forced: [Bool] = []
    var hold = false
    var held: [() -> Void] = []
    var nonKeyEvenIfForced = 0
    var invalidated = false
    var sampleSize = 10

    func encode(_ frame: CVPixelBuffer, time: CMTime, forceKeyFrame: Bool, completion: @escaping (WebcamEncodedSample?) -> Void) {
        forced.append(forceKeyFrame)
        var key = forceKeyFrame
        if nonKeyEvenIfForced > 0 {
            nonKeyEvenIfForced -= 1
            key = false
        }
        let body = [UInt8](repeating: 0xAB, count: max(0, sampleSize - 5))
        let sample = WebcamEncodedSample(data: Data(hex(key ? "00 00 00 01 65" : "00 00 00 01 41") + body), isKeyFrame: key, time: time.seconds)
        if hold { held.append { completion(sample) } } else { completion(sample) }
    }

    func flush() {}
    func invalidate() { invalidated = true }
}

private final class WebcamHarness {
    let engine: WebcamEngine
    let camera = FakeCamera()
    let encoder = FakeEncoder()
    var sent: [[UInt8]] = []
    var events: [String] = []
    var capturing: [Bool] = []
    var denied = 0
    var timers: [(TimeInterval, () -> Void)] = []
    var backlogBytes = 0

    init(source: Bool = true, encoderFails: Bool = false) {
        engine = WebcamEngine()
        engine.output = { [unowned self] out in
            guard case .channel(let d) = out else { Issue.record("unexpected WD packet"); return }
            sent.append([UInt8](d))
        }
        engine.onEvent = { [unowned self] e in
            events.append("\(e)")
            if case .capturing(let on) = e { capturing.append(on) }
            if case .cameraDenied = e { denied += 1 }
        }
        if source { engine.source = camera }
        engine.makeEncoder = { [unowned self] _ in
            if encoderFails { throw NSError(domain: "fake", code: 2) }
            return encoder
        }
        engine.scheduleAfter = { [unowned self] delay, block in timers.append((delay, block)) }
        engine.backlog = { [unowned self] in backlogBytes }
        // As the WD does at INIT_RESPONSE time (the verdict needs the module).
        _ = engine.module(channel: WebcamWire.channelNumber, date: Date())
    }

    @discardableResult
    func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        let before = sent.count
        engine.receive(Data(bytes))
        return Array(sent[before...])
    }

    /// BIND_REQUEST + BIND_COMMIT, then the §5.1 CREATE_CONTEXT (1/1).
    func bound() {
        feed(webcamBindRequest)
        var commit = webcamBindRequest
        commit[2] = 1
        feed(commit)
    }

    func ready() {
        bound()
        feed(webcamCreateContext)
    }

    func playing() {
        ready()
        camera.autoGrant = true
        feed(webcamPlay)
    }

    /// TRANSMIT messages among `out`.
    func transmits(_ out: [[UInt8]]) -> [[UInt8]] { out.filter { $0[2] == 0x85 } }
}

@Suite struct WebcamEngineTests {
    @Test func bindExchangeFromTheEngine() {
        let h = WebcamHarness()
        #expect(h.feed(webcamBindRequest) == [webcamBindResponse])
        var commit = webcamBindRequest
        commit[2] = 1
        #expect(h.feed(commit).isEmpty)  // BIND_COMMIT gets no reply
        #expect(h.engine.diagnostics.bindRequests == 1 && h.engine.diagnostics.bindCommits == 1)
        // The W4 timer finds the commit and logs nothing.
        h.timers.forEach { $0.1() }
        #expect(!h.engine.diagnostics.bindCommitMissing)
        #expect(h.engine.diagnostics.verdict().contains("W3"))
    }

    @Test func bindSplitAcrossReceivesAndTwoMessagesInOne() {
        let h = WebcamHarness()
        #expect(h.feed(Array(webcamBindRequest[0..<10])).isEmpty)
        #expect(h.feed(Array(webcamBindRequest[10...])) == [webcamBindResponse])
        var commit = webcamBindRequest
        commit[2] = 1
        let out = h.feed(webcamBindRequest + commit)
        #expect(out == [webcamBindResponse] && h.engine.diagnostics.bindCommits == 1)
    }

    @Test func missingCommitIsLoggedAsW4() {
        let h = WebcamHarness()
        h.feed(webcamBindRequest)
        h.timers.forEach { $0.1() }
        #expect(h.engine.diagnostics.bindCommitMissing)
        #expect(h.events.contains { $0.hasPrefix("W4:") })
        #expect(h.engine.diagnostics.verdict().contains("W4"))
    }

    @Test func createContextExampleAnswersThe208BytesWithoutTouchingTheCamera() {
        let h = WebcamHarness()
        h.bound()
        #expect(h.feed(webcamCreateContext) == [webcamCaptureSuccess])
        #expect(h.engine.state == .ready && h.engine.context?.major == 1)
        // No permission request, no start: the camera is not touched before PLAY.
        #expect(h.camera.permissionRequests.isEmpty && h.camera.starts == 0 && h.capturing.isEmpty)
        // W12: no PLAY within the timeout is logged.
        h.timers.forEach { $0.1() }
        #expect(h.engine.diagnostics.playWithoutAnswer && h.events.contains { $0.hasPrefix("W12:") })
    }

    @Test func rejectsPerSpec() {
        let h = WebcamHarness()
        // Before BIND: a device context gets the 0x86 error 0x40001; a non-device one 0x81 with 0x40001.
        #expect(h.feed(webcamCreate()) == [hex("18 00 86 00 01 00 00 00 01 00 00 00 01 00 04 00 00 00 00 00 18 00 00 00")])
        #expect(h.feed(webcamCreate(devicePath: nil)) == [hex("14 00 81 00 01 00 00 00 01 00 00 00 01 00 04 00 00 00 00 00")])
        h.bound()
        // After BIND: minor 0 → 0x81 with E_FAIL (the §5.4 bytes); no DEVICE → 0x81 too.
        #expect(h.feed(webcamCreate(major: 1, minor: 0)) == [hex("14 00 81 00 01 00 00 00 00 00 00 00 05 40 00 80 00 00 00 00")])
        #expect(h.feed(webcamCreate(major: 3, minor: 4, devicePath: nil))
                == [hex("14 00 81 00 03 00 00 00 04 00 00 00 05 40 00 80 00 00 00 00")])
        #expect(h.engine.context == nil && h.engine.diagnostics.rejects == 3)
        // The pre-BIND device context counts as a device context answered with the error.
        #expect(h.engine.diagnostics.verdict().contains("0x86 error only"))
    }

    @Test func refusalAfterBindUsesEFailBytes() {
        let h = WebcamHarness()
        h.ready()
        #expect(h.feed(webcamCreate(major: 1, minor: 2))
                == [hex("18 00 86 00 01 00 00 00 02 00 00 00 05 40 00 80 00 00 00 00 18 00 00 00")])
    }

    @Test func truncatedPropertiesStillGetAnAnswer() {
        let h = WebcamHarness()
        h.bound()
        // A TYPE property of 20 bytes (the three GUIDs do not fit) and an empty DEVICE: TYPE skipped, success.
        var w = ByteWriter()
        let type = WebcamElement(type: 1, [UInt8](repeating: 0x11, count: 12)).encoded
        let device = WebcamElement(type: 3, hex("0C 00 00 00 00 00 00 00 00 00 00 00")).encoded
        w.u16(UInt16(20 + type.count + device.count)); w.u8(2); w.u8(0); w.u32(1); w.u32(1); w.u32(0); w.u16(16); w.u8(2); w.u8(0)
        w.raw(type + device)
        #expect(h.feed([UInt8](w.data)) == [webcamCaptureSuccess])
        #expect(h.events.contains { $0.contains("TYPE property of 12 B truncated") })
        // A DEVICE cut short still marks a device context (the second context gets the E_FAIL refusal, not 0x81).
        var d = ByteWriter()
        let shortDevice = WebcamElement(type: 3, hex("0C 00 00 00 00 00")).encoded
        d.u16(UInt16(20 + shortDevice.count)); d.u8(2); d.u8(0); d.u32(2); d.u32(2); d.u32(0); d.u16(16); d.u8(1); d.u8(0)
        d.raw(shortDevice)
        #expect(h.feed([UInt8](d.data)) == [WebcamMessage.captureContextError(major: 2, minor: 2, status: WebcamWire.Status.failed)])
        // A broken element list (length past the end) after the handles: answered (0x81, no DEVICE parsed), not dropped.
        let broken = hex("1C 00 02 00 03 00 00 00 03 00 00 00 00 00 00 00 10 00 01 00 FF 00 00 00 03 00 00 00")
        #expect(h.feed(broken) == [WebcamMessage.contextReject(major: 3, minor: 3, status: WebcamWire.Status.failed)])
        #expect(h.engine.diagnostics.malformed == 0)
    }

    @Test func laterSourceFailureTellsTheHost() {
        let h = WebcamHarness()
        h.playing()
        let before = h.sent.count
        h.camera.fail("interrupted")
        #expect(Array(h.sent[before...]) == [WebcamMessage.captureContextError(major: 1, minor: 1)])
        #expect(h.engine.state == .failed && h.capturing == [true, false] && h.engine.diagnostics.captureErrors == 1)
        // A stale failure after a stop does nothing.
        h.feed(webcamPlay)
        h.feed(webcamControl(WebcamWire.Control.stop))
        let after = h.sent.count
        h.camera.lastFailed?("late")
        #expect(h.sent.count == after && h.engine.state == .ready)
    }

    @Test func noEncoderAnswersTheError() {
        let h = WebcamHarness(encoderFails: true)
        h.bound()
        #expect(h.feed(webcamCreateContext) == [WebcamMessage.captureContextError(major: 1, minor: 1, status: WebcamWire.Status.failed)])
        #expect(h.engine.context == nil)
    }

    @Test func secondContextGetsTheErrorAndDestroyForgetsTheWholeMajor() {
        let h = WebcamHarness()
        h.ready()
        #expect(h.feed(webcamCreate(major: 1, minor: 2)) == [WebcamMessage.captureContextError(major: 1, minor: 2, status: WebcamWire.Status.failed)])
        #expect(h.engine.context?.minor == 1)
        h.camera.autoGrant = true
        h.feed(webcamPlay)
        #expect(h.camera.running)
        // DESTROY(1, 2) forgets every context with major 1, so 1/1 stops too (§3.1).
        #expect(h.feed(hex("0C 00 04 00 01 00 00 00 02 00 00 00")).isEmpty)
        #expect(!h.camera.running && h.engine.context == nil && h.engine.state == .idle && h.encoder.invalidated)
        // PLAY for the forgotten context does nothing.
        h.feed(webcamPlay)
        #expect(h.camera.starts == 1)
        // DESTROY of another major leaves a context alone.
        h.feed(webcamCreateContext)
        h.feed(hex("0C 00 04 00 02 00 00 00 01 00 00 00"))
        #expect(h.engine.context?.major == 1)
    }

    @Test func playAsksPermissionThenStartsAndSendsAKeyFrameFirst() {
        let h = WebcamHarness()
        h.ready()
        h.feed(webcamPlay)
        #expect(h.camera.permissionRequests.count == 1 && h.camera.starts == 0 && h.engine.state == .awaitingPermission)
        h.camera.permissionRequests.removeFirst()(true)
        #expect(h.camera.starts == 1 && h.engine.state == .playing && h.capturing == [true])
        let before = h.sent.count
        h.camera.push(0)
        h.camera.push(1.0 / 15)
        let out = h.transmits(Array(h.sent[before...]))
        #expect(out.count == 2 && h.encoder.forced == [true, false])
        // The first sample is the key frame, in the §7 layout for 1/1.
        #expect(Array(out[0][0..<16]) == hex("42 00 85 00 01 00 00 00 01 00 00 00 0C 00 01 00"))
        #expect(Array(out[0][56..<61]) == hex("00 00 00 01 65"))
        #expect(h.engine.diagnostics.samplesSent == 2 && h.engine.diagnostics.keyFramesSent == 1)
    }

    @Test func noCaptureWithoutPlayOrWithDeniedPermission() {
        let h = WebcamHarness()
        h.ready()
        h.camera.push(0)
        #expect(h.camera.starts == 0 && h.transmits(h.sent).isEmpty)
        h.camera.autoGrant = false
        #expect(h.feed(webcamPlay) == [WebcamMessage.captureContextError(major: 1, minor: 1)])
        #expect(h.camera.starts == 0 && h.engine.state == .failed && h.denied == 1)
        #expect(h.engine.diagnostics.permissionDenied == 1)
    }

    @Test func noSourceAnswersTheErrorAtPlay() {
        let h = WebcamHarness(source: false)
        h.ready()
        #expect(h.feed(webcamPlay) == [WebcamMessage.captureContextError(major: 1, minor: 1)])
    }

    @Test func sourceFailureAnswersTheError() {
        let h = WebcamHarness()
        h.ready()
        h.camera.failStart = true
        h.camera.autoGrant = true
        #expect(h.feed(webcamPlay) == [WebcamMessage.captureContextError(major: 1, minor: 1)])
        #expect(h.engine.state == .failed && h.capturing.isEmpty)
    }

    @Test func pauseAndStopTurnTheCameraOffAndReplayForcesAKeyFrame() {
        let h = WebcamHarness()
        h.playing()
        h.camera.push(0)
        h.camera.push(0.1)
        h.feed(webcamControl(WebcamWire.Control.pause))
        #expect(!h.camera.running && h.engine.state == .ready && h.capturing == [true, false])
        h.camera.push(0.2)  // nothing: the source was stopped
        h.feed(webcamPlay)
        #expect(h.camera.running && h.camera.starts == 2)
        h.camera.push(0.3)
        #expect(h.encoder.forced == [true, false, true])
        h.feed(webcamControl(WebcamWire.Control.stop))
        #expect(!h.camera.running && h.camera.stops == 2 && !h.encoder.invalidated)  // the encoder stays
        // FLUSH / END_OF_STREAM: no action.
        h.feed(webcamControl(WebcamWire.Control.flush))
        #expect(h.engine.state == .ready)
    }

    @Test func stopWhilePermissionPendingNeverStarts() {
        let h = WebcamHarness()
        h.ready()
        h.feed(webcamPlay)
        h.feed(webcamControl(WebcamWire.Control.stop))
        h.camera.permissionRequests.removeFirst()(true)
        #expect(h.camera.starts == 0 && h.engine.state == .ready)
    }

    @Test func keyFrameAtLeastEveryTwoSeconds() {
        let h = WebcamHarness()
        h.playing()
        for i in 0..<12 { h.camera.push(Double(i) * 0.25) }  // 0 … 2.75 s
        // Forced at 0, then again at 2.0 s (index 8).
        #expect(h.encoder.forced.enumerated().filter(\.element).map(\.offset) == [0, 8])
        #expect(h.engine.diagnostics.keyFramesSent == 2)
    }

    @Test func nonKeySamplesBeforeTheFirstKeyFrameAreDropped() {
        let h = WebcamHarness()
        h.encoder.nonKeyEvenIfForced = 2
        h.playing()
        h.camera.push(0)
        h.camera.push(0.07)
        h.camera.push(0.14)
        #expect(h.encoder.forced == [true, true, true])
        #expect(h.engine.diagnostics.samplesDroppedBeforeKeyFrame == 2 && h.engine.diagnostics.samplesSent == 1)
        #expect(h.transmits(h.sent).count == 1)
    }

    @Test func oneFrameInFlightAndBacklogSkipBeforeEncoding() {
        let h = WebcamHarness()
        h.encoder.hold = true
        h.playing()
        h.camera.push(0)
        h.camera.push(0.07)
        #expect(h.encoder.forced.count == 1 && h.engine.diagnostics.framesSkippedInFlight == 1)
        h.encoder.held.removeFirst()()
        #expect(h.transmits(h.sent).count == 1)
        h.encoder.hold = false
        h.backlogBytes = 100 << 10
        h.camera.push(0.14)
        #expect(h.encoder.forced.count == 1 && h.engine.diagnostics.framesSkippedBacklog == 1)
        h.backlogBytes = 0
        h.camera.push(0.21)
        #expect(h.encoder.forced.count == 2)
    }

    @Test func largeSamplesAreFragmented() {
        let h = WebcamHarness()
        h.encoder.sampleSize = 9000
        h.playing()
        h.camera.push(0)
        #expect(h.transmits(h.sent).map(\.count) == [4056, 4004, 1004])
        #expect(h.engine.diagnostics.fragmentsSent == 3)
    }

    @Test func linkDownStopsAndTheCameraStaysOffUntilTheNextPlay() {
        let h = WebcamHarness()
        h.playing()
        h.engine.suspend()
        #expect(!h.camera.running && h.engine.state == .ready)
        h.camera.push(0)
        h.engine.resume()
        #expect(!h.camera.running && h.camera.starts == 1)
        h.feed(webcamPlay)
        #expect(h.camera.running && h.camera.starts == 2)
    }

    @Test func permissionGrantedWhileTheLinkIsDownDoesNotStart() {
        let h = WebcamHarness()
        h.ready()
        h.feed(webcamPlay)
        h.engine.suspend()
        #expect(h.engine.state == .ready)
        h.camera.permissionRequests.removeFirst()(true)   // stale: the run was cancelled
        #expect(h.camera.starts == 0)
        // A PLAY while the link is still down asks, but the grant does not start the camera.
        h.feed(webcamPlay)
        h.camera.permissionRequests.removeFirst()(true)
        #expect(h.camera.starts == 0 && h.engine.state == .ready)
        h.engine.resume()
        #expect(h.camera.starts == 0)
    }

    @Test func disableCameraStopsTellsTheHostAndRefusesLaterContexts() {
        let h = WebcamHarness()
        h.playing()
        let before = h.sent.count
        h.engine.disableCamera(notifyHost: true, reason: "disabled by the user")
        #expect(Array(h.sent[before...]) == [WebcamMessage.captureContextError(major: 1, minor: 1)])
        #expect(!h.camera.running && h.engine.cameraDisabled && h.engine.context == nil && h.encoder.invalidated)
        #expect(h.capturing == [true, false])
        h.feed(webcamPlay)
        #expect(h.camera.starts == 1)
        #expect(h.feed(webcamCreateContext) == [WebcamMessage.captureContextError(major: 1, minor: 1, status: WebcamWire.Status.failed)])
        #expect(h.camera.starts == 1)
    }

    @Test func disableWithoutNotifySendsNothing() {
        let h = WebcamHarness()
        h.playing()
        let before = h.sent.count
        h.engine.disableCamera(notifyHost: false, reason: "logoff")
        #expect(h.sent.count == before && !h.camera.running)
    }

    @Test func disableDuringPendingPermissionNeverStarts() {
        let h = WebcamHarness()
        h.ready()
        h.feed(webcamPlay)
        h.engine.disableCamera(notifyHost: true, reason: "test")
        h.camera.permissionRequests.removeFirst()(true)
        #expect(h.camera.starts == 0)
    }

    @Test func shutdownStopsAndSendsNothingMore() {
        let h = WebcamHarness()
        h.playing()
        h.engine.shutdown()
        #expect(!h.camera.running && h.encoder.invalidated && h.events.last == "stopped")
        let before = h.sent.count
        h.feed(webcamBindRequest)
        h.camera.push(1)
        #expect(h.sent.count == before)
    }

    @Test func repeatedBindDropsTheContext() {
        let h = WebcamHarness()
        h.playing()
        h.feed(webcamBindRequest)
        #expect(!h.camera.running && h.engine.context == nil)
    }

    @Test func malformedAndUnknownMessagesAreSkipped() {
        let h = WebcamHarness()
        h.bound()
        let out = h.feed(hex("08 00 04 00 01 00 00 00") + hex("04 00 42 00") + webcamCreateContext)
        #expect(out == [webcamCaptureSuccess])
        #expect(h.engine.diagnostics.malformed == 1 && h.engine.diagnostics.unknownCommands == 1)
    }

    @Test func verdictLadder() {
        var d = WebcamDiagnostics()
        #expect(d.verdict().hasPrefix("no CTXMM module"))
        d.moduleBytes = [0]
        #expect(d.verdict().hasPrefix("W5"))
        d.hostBytes = 10
        d.commandCounts = ["CONTROL": 1]
        #expect(d.verdict().contains("no BIND_REQUEST"))
        d.bindRequests = 1
        #expect(d.verdict().contains("W4"))
        d.bindCommits = 1
        #expect(d.verdict().contains("normal: no host app"))
        #expect(d.verdict(appOpenedCamera: true).contains("W9"))
        d.contextRequests = 1
        #expect(d.verdict().contains("W11"))
        d.deviceContexts = 1
        d.contextSuccesses = 1
        #expect(d.verdict().contains("W12"))
        d.controls["PLAY"] = 1
        #expect(d.verdict().contains("no frame sent"))
        d.samplesSent = 3
        #expect(d.verdict().contains("frames flowing"))
    }
}

/// The camera stops when a disconnect or logoff starts, before it completes (as the microphone, D43 item 2).
@Suite struct WebcamSessionEndTests {
    private func session() throws -> (ICASession, FakeCamera, Box) {
        let text = "[ApplicationServers]\nX=\n[X]\nSSLProxyHost=gw.example:443\nAddress=ticket\nCGPSecurityTicket=On\nTWIMode=On\nInitialProgram=#Test\n"
        let ica = try #require(ICAFile(text: text))
        var config = WinstationDriver.Configuration()
        config.logon = WDLogon(ica: ica)
        let s = try ICASession(ica: ica, configuration: config, webcam: WebcamEngine.Config())
        let camera = FakeCamera()
        camera.autoGrant = true
        let engine = try #require(s.webcam)
        engine.source = camera
        engine.makeEncoder = { _ in FakeEncoder() }
        let box = Box()
        engine.onEvent = { box.lines.append("\($0)") }
        return (s, camera, box)
    }

    final class Box: @unchecked Sendable { var lines: [String] = [] }

    private func play(_ s: ICASession) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.perform {
                var commit = webcamBindRequest
                commit[2] = 1
                s.webcam!.receive(Data(webcamBindRequest + commit + webcamCreateContext + webcamPlay))
                c.resume()
            }
        }
    }

    private func state(_ s: ICASession, _ camera: FakeCamera) async -> (Bool, Bool) {
        await withCheckedContinuation { c in s.perform { c.resume(returning: (camera.running, s.webcam!.cameraDisabled)) } }
    }

    @Test func logoffStopsTheCamera() async throws {
        let (s, camera, _) = try session()
        await play(s)
        #expect(await state(s, camera).0)
        let sent: Bool = await withCheckedContinuation { c in s.logoff { c.resume(returning: $0) } }
        let (running, disabled) = await state(s, camera)
        #expect(!sent && !running && disabled)
    }

    @Test func menuDisableAndCloseStopTheCamera() async throws {
        let (s, camera, _) = try session()
        await play(s)
        s.disableCamera()
        let (running, disabled) = await state(s, camera)
        #expect(!running && disabled)

        let (t, other, box) = try session()
        await play(t)
        #expect(await state(t, other).0)
        await t.close(timeout: 0.2)
        let (running2, _) = await state(t, other)
        #expect(!running2 && other.stops == 1)
        // The stop came from close() itself, before the session end.
        let lines = await withCheckedContinuation { c in t.perform { c.resume(returning: box.lines) } }
        #expect(lines.contains { $0.contains("camera disabled for this session (disconnect)") })
    }
}

// MARK: - Encoder, scaler, test pattern (VideoToolbox, synthetic frames only)

@Suite struct WebcamEncoderTests {
    @Test func testPatternFramesAreNV12AndMove() throws {
        let pattern = WebcamTestPattern()
        let a = try #require(pattern.frame(0)), b = try #require(pattern.frame(5))
        #expect(CVPixelBufferGetWidth(a) == 352 && CVPixelBufferGetHeight(a) == 288)
        #expect(CVPixelBufferGetPixelFormatType(a) == WebcamPixelBuffers.pixelFormat)
        func luma(_ p: CVPixelBuffer) -> [UInt8] {
            CVPixelBufferLockBaseAddress(p, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
            let base = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: base, count: CVPixelBufferGetBytesPerRowOfPlane(p, 0) * 288))
        }
        #expect(luma(a) != luma(b))
        var permitted = false
        pattern.requestPermission { permitted = $0 }
        #expect(permitted)
    }

    @Test func cropKeepsElevenToNine() {
        #expect(WebcamFrameScaler.crop(width: 1920, height: 1080, to: .standard) == (1320, 1080))
        #expect(WebcamFrameScaler.crop(width: 640, height: 480, to: .standard) == (586, 480))
        #expect(WebcamFrameScaler.crop(width: 480, height: 640, to: .standard) == (480, 392))
        #expect(WebcamFrameScaler.crop(width: 352, height: 288, to: .standard) == (352, 288))
    }

    @Test func scalerMakes352x288() throws {
        var source: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        CVPixelBufferCreate(nil, 1280, 720, WebcamPixelBuffers.pixelFormat, attributes as CFDictionary, &source)
        let input = try #require(source)
        let scaled = try #require(WebcamFrameScaler().scale(input))
        #expect(CVPixelBufferGetWidth(scaled) == 352 && CVPixelBufferGetHeight(scaled) == 288)
    }

    /// VideoToolbox with synthetic frames: the first sample is a forced IDR with SPS and PPS in front, all samples
    /// are Annex B, and the TRANSMIT fragments reassemble to the samples.
    @Test func videoToolboxEncodesAnnexBWithParameterSetsOnKeyFrames() throws {
        let encoder = try WebcamH264Encoder()
        defer { encoder.invalidate() }
        let pattern = WebcamTestPattern()
        let lock = NSLock()
        var samples: [WebcamEncodedSample] = []
        for n in 0..<40 {
            let frame = try #require(pattern.frame(n))
            encoder.encode(frame, time: CMTime(value: CMTimeValue(n), timescale: 15), forceKeyFrame: n == 0 || n == 20) { sample in
                guard let sample else { return }
                lock.lock()
                samples.append(sample)
                lock.unlock()
            }
        }
        encoder.flush()
        let out = lock.withLock { samples }
        #expect(out.count >= 35)
        let first = try #require(out.first)
        #expect(first.isKeyFrame)
        let types = AnnexB.units(first.data).compactMap(AnnexB.nalType)
        #expect(Array(types.prefix(2)) == [AnnexB.NALType.sps, AnnexB.NALType.pps] && types.contains(AnnexB.NALType.idr))
        for s in out {
            #expect(Array(s.data.prefix(4)) == AnnexB.startCode)
            let t = AnnexB.units(s.data).compactMap(AnnexB.nalType)
            #expect(s.isKeyFrame == t.contains(AnnexB.NALType.idr))
            if s.isKeyFrame { #expect(t.first == AnnexB.NALType.sps) } else { #expect(!t.contains(AnnexB.NALType.sps)) }
            // Baseline/Constrained Baseline: profile_idc 66 in the SPS.
            if let sps = AnnexB.units(s.data).first(where: { AnnexB.nalType($0) == 7 }) { #expect(sps.dropFirst().first == 66) }
            let fragments = WebcamMessage.transmit(major: 1, minor: 1, sample: s.data)
            let data = Array(fragments[0][56...]) + fragments.dropFirst().flatMap { $0[4...] }
            #expect(Data(data) == s.data && fragments.allSatisfy { $0.count <= 4056 })
        }
        // The forced key frame at 20 (and the 30-frame maximum interval) give at least two key frames.
        #expect(out.filter(\.isKeyFrame).count >= 2)
    }
}
