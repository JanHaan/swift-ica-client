import Testing
import Foundation
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }
private let credit1 = hex("80 01 00 01 00")
private let openOK = hex("84 02 80 02 40 00 00")
private let openFailed = hex("84 02 80 02 40 00 FF")

/// A capture source driven by the test: permission answers and samples on demand.
private final class FakeSource: AudioCaptureSource {
    var permissionRequests: [(Bool) -> Void] = []
    var deliver: (([Float]) -> Void)?
    var format: AudioStreamFormat?
    var starts = 0
    var stops = 0
    var failStart = false
    struct StartFailure: Error {}

    func requestPermission(_ completion: @escaping (Bool) -> Void) { permissionRequests.append(completion) }
    func start(format: AudioStreamFormat, deliver: @escaping ([Float]) -> Void) throws {
        if failStart { throw StartFailure() }
        starts += 1
        self.format = format
        self.deliver = deliver
    }
    func stop() {
        stops += 1
        deliver = nil
    }
    var running: Bool { deliver != nil }
}

/// Frames of `frameCount` frames; each packet is `[index, sample count low byte]`.
private final class FakeEncoder: AudioPacketEncoder {
    let stream: AudioStreamFormat
    let frameCount: Int
    var count = 0
    init(stream: AudioStreamFormat, frameCount: Int) {
        self.stream = stream
        self.frameCount = frameCount
    }
    func encode(_ frame: [Float]) -> [Data]? {
        count += 1
        return [Data([UInt8(count), UInt8(truncatingIfNeeded: frame.count)])]
    }
}

private final class CaptureHarness {
    let engine: AudioEngine
    let source = FakeSource()
    var sent: [[UInt8]] = []
    var events: [String] = []

    init(microphone: Bool = true, withSource: Bool = true, encodable: Set<UInt16> = Set(AudioFormatCode.opusSubformats)) {
        var config = AudioEngine.Config()
        config.microphone = microphone
        config.opusEncodeSubformats = encodable
        config.opusSubformats = Set(AudioFormatCode.opusSubformats)
        engine = AudioEngine(config: config)
        engine.output = { [unowned self] out in
            if case .channel(let d) = out { sent.append([UInt8](d)) }
        }
        engine.onEvent = { [unowned self] e in
            switch e {
            case .microphoneDenied: events.append("denied")
            case .recording(let on): events.append(on ? "rec on" : "rec off")
            default: break
            }
        }
        if withSource { engine.captureSource = source }
        engine.makeEncoder = { code in code.opus.map { FakeEncoder(stream: $0, frameCount: Int($0.sampleRate / 100)) } }
    }

    @discardableResult
    func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        let before = sent.count
        engine.receive(Data(bytes))
        return Array(sent[before...])
    }

    @discardableResult
    func answerPermission(_ granted: Bool) -> [[UInt8]] {
        let before = sent.count
        source.permissionRequests.removeFirst()(granted)
        return Array(sent[before...])
    }

    @discardableResult
    func deliver(_ samples: Int) -> [[UInt8]] {
        let before = sent.count
        source.deliver?([Float](repeating: 0.1, count: samples))
        return Array(sent[before...])
    }
}

/// OPEN dev 2, Opus 16 kHz mono (subformat 0x02): 160-frame packets.
private let openOpus16 = hex("01 02 06 00 02 00 00 00 00 00")

@Suite struct AudioCaptureWireTests {
    @Test func uplinkLayoutsAreByteExact() {
        // §3.2, §7.1: READ_DATA's length is L + 2, then u16 L and the packet.
        #expect(AudioReply.readData(device: 2, packet: Data([0xAA, 0xBB])) == hex("83 02 06 00 04 00 02 00 AA BB"))
        #expect(AudioReply.readData(device: 2, packet: Data()) == hex("83 02 06 00 00 00"))   // silent frame
        #expect(AudioReply.readDataV2(device: 2, sequence: 0x1234, packet: Data([0xAA]))
                == hex("88 02 0C 00 03 00 34 12 00 00 00 00 01 00 AA"))
        #expect(AudioReply.readDataV2(device: 2, sequence: 7, packet: Data()) == hex("88 02 0C 00 00 00 07 00 00 00 00 00"))
        #expect(AudioReply.openResponse(device: 2, status: 0) == openOK)
        #expect(AudioReply.resetDevice(2, reason: 0xFF) == hex("81 02 FF"))
    }

    @Test func moduleAnnouncesTheMicrophoneBit() {
        var c = AudioEngine.Config()
        #expect(c.announcedCapabilities == 0x10)
        c.microphone = true
        #expect(c.announcedCapabilities == 0x11)
        let m = AudioEngine(config: c).module(channel: 19, date: Date())
        #expect(m.count == 55 && Array(m[51...54]) == hex("11 00 00 00") && m[5] == 2)
    }

    @Test func captureCapInfoListsEncodableOpusPairsInHostOrder() {
        let h = CaptureHarness(encodable: [0x02, 0x14])
        h.feed(hex("00 02 00"))
        // Host: Speex WB mono, Opus 48k stereo, Opus 16k mono, Opus 8k mono (not encodable here).
        #expect(h.feed(hex("05 02 06 00 04 00 05 00 18 01 06 00 14 00 06 00 02 00 06 00 00 00"))
                == [hex("82 02 06 00 02 00 06 00 14 00 06 00 02 00"), credit1, hex("80 02 00 01 00")])
        let off = CaptureHarness(microphone: false)
        off.feed(hex("00 02 00"))
        #expect(off.feed(hex("05 02 06 00 01 00 06 00 14 00")).first == hex("82 02 06 00 00 00"))
    }
}

@Suite struct AudioCaptureStateTests {
    @Test func openStartFramesStopClose() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        #expect(h.feed(openOpus16).isEmpty)                 // waits for the permission answer
        #expect(h.engine.captureState == .awaitingPermission(AudioFormatCode(6, 2)))
        #expect(h.answerPermission(true) == [openOK, credit1])
        #expect(h.feed(hex("07 02")) == [credit1])
        #expect(h.source.starts == 1 && h.source.format == AudioStreamFormat(sampleRate: 16000, channels: 1))
        // 2.5 frames of 160 samples: two packets now, each as READ_DATA plus a command credit.
        #expect(h.deliver(400) == [hex("83 02 06 00 04 00 02 00 01 A0"), credit1, hex("83 02 06 00 04 00 02 00 02 A0"), credit1])
        #expect(h.deliver(80) == [hex("83 02 06 00 04 00 02 00 03 A0"), credit1])   // the rest completes frame 3
        #expect(h.feed(hex("06 02 80 02 04 00")) == [credit1])   // READ_REQUEST: ignored (push-based)
        #expect(h.feed(hex("09 02")) == [credit1])               // RESET_RECORD: no-op
        #expect(h.feed(hex("08 02")) == [credit1])
        #expect(!h.source.running && h.source.stops == 1)
        #expect(h.engine.captureState == .open(AudioFormatCode(6, 2)))
        #expect(h.feed(hex("02 02")) == [credit1])
        #expect(h.engine.captureState == .closed)
        #expect(h.events == ["rec on", "rec off"])
        #expect(h.engine.diagnostics.captureFramesSent == 3 && h.engine.diagnostics.captureOpenResults == ["ok"])
    }

    @Test func framesAfterStopAreDropped() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        h.feed(hex("07 02"))
        let late = h.source.deliver!
        h.feed(hex("08 02"))
        let before = h.sent.count
        late([Float](repeating: 0, count: 320))   // a callback already on its way
        #expect(h.sent.count == before)
    }

    @Test func permissionDenied() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        #expect(h.answerPermission(false) == [openFailed, credit1])
        #expect(h.events == ["denied"])
        #expect(h.engine.captureState == .closed)
        #expect(h.feed(hex("07 02")) == [credit1])
        #expect(h.source.starts == 0)
    }

    @Test func startBeforeThePermissionAnswerAndCloseBeforeIt() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        #expect(h.feed(hex("07 02")) == [credit1])
        #expect(h.source.starts == 0)
        #expect(h.answerPermission(true) == [openOK, credit1])
        #expect(h.source.starts == 1)

        let c = CaptureHarness()
        c.feed(hex("00 02 00"))
        c.feed(openOpus16)
        // CLOSE first: the OPEN is answered "failed", then CLOSE is credited; a late grant changes nothing.
        #expect(c.feed(hex("02 02")) == [openFailed, credit1, credit1])
        #expect(c.answerPermission(true).isEmpty)
        #expect(c.engine.captureState == .closed && c.source.starts == 0)
    }

    @Test func openFailsWithoutMicrophoneSourceOrEncoder() {
        for h in [CaptureHarness(microphone: false), CaptureHarness(withSource: false), CaptureHarness(encodable: [])] {
            h.feed(hex("00 02 00"))
            #expect(h.feed(openOpus16) == [openFailed, credit1])
            #expect(h.source.permissionRequests.isEmpty)
        }
        let speex = CaptureHarness()
        speex.feed(hex("00 02 00"))
        #expect(speex.feed(hex("01 02 05 00 18 01 00 00 00 00")) == [openFailed, credit1])
    }

    @Test func sourceErrorResetsUntilResetAck() {
        let h = CaptureHarness()
        h.source.failStart = true
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        #expect(h.feed(hex("07 02")) == [hex("81 02 FF"), credit1])
        #expect(h.engine.captureState == .reset)
        #expect(h.feed(openOpus16) == [credit1])   // ignored until RESET_ACK
        #expect(h.source.permissionRequests.isEmpty)
        #expect(h.feed(hex("04 02")) == [credit1])
        #expect(h.engine.captureState == .closed)
        h.feed(openOpus16)
        #expect(h.source.permissionRequests.count == 1)
    }

    @Test func suspendStopsAndResumeRestarts() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        h.feed(hex("07 02"))
        h.engine.suspend()
        #expect(!h.source.running && h.source.stops == 1)
        h.engine.resume()
        #expect(h.source.running && h.source.starts == 2)
        h.engine.shutdown()
        #expect(!h.source.running && h.source.stops == 2)
    }

    /// Review item 1: a permission granted (or a START) while the link is down never starts the microphone.
    @Test func noCaptureWhileTheLinkIsDown() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.engine.suspend()                       // link drops while the prompt is open
        #expect(h.answerPermission(true) == [openOK, credit1])
        h.feed(hex("07 02"))
        #expect(h.source.starts == 0 && h.engine.captureState == .recording(AudioFormatCode(6, 2)))
        h.engine.resume()
        #expect(h.source.starts == 1 && h.source.running)
        // A second drop: stopped at once; frames already on their way are dropped.
        let late = h.source.deliver!
        h.engine.suspend()
        #expect(!h.source.running)
        let before = h.sent.count
        late([Float](repeating: 0, count: 320))
        #expect(h.sent.count == before)
        // STOP and START while down: still nothing until the resume.
        h.feed(hex("08 02"))
        h.feed(hex("07 02"))
        #expect(h.source.starts == 1)
        h.engine.resume()
        #expect(h.source.starts == 2)
    }

    /// Review item 4: after STOP_RECORD (and a pause) capture starts with an empty buffer and a new encoder.
    @Test func stopStartsAFreshFrameBuffer() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        h.feed(hex("07 02"))
        #expect(h.deliver(100).isEmpty)          // 100 of 160 samples wait in the buffer
        h.feed(hex("08 02"))
        h.feed(hex("07 02"))
        #expect(h.deliver(100).isEmpty)          // not 200: the 100 pre-STOP samples are gone
        // The new encoder starts counting again: packet index 1.
        #expect(h.deliver(60) == [hex("83 02 06 00 04 00 02 00 01 A0"), credit1])
        h.engine.suspend()
        h.engine.resume()
        #expect(h.deliver(100).isEmpty)
        #expect(h.deliver(60) == [hex("83 02 06 00 04 00 02 00 01 A0"), credit1])
    }

    @Test func disableMicrophoneForTheSession() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        h.feed(hex("07 02"))
        let before = h.sent.count
        h.engine.disableMicrophone(notifyHost: true, reason: "test")
        #expect(Array(h.sent[before...]) == [hex("81 02 FF")])
        #expect(!h.source.running && h.engine.captureState == .reset && h.engine.microphoneDisabled)
        h.feed(hex("04 02"))
        #expect(h.feed(openOpus16) == [openFailed, credit1])
        #expect(h.source.permissionRequests.isEmpty)
        // A pending OPEN is answered failed; a late grant starts nothing.
        let p = CaptureHarness()
        p.feed(hex("00 02 00"))
        p.feed(openOpus16)
        p.feed(hex("07 02"))
        let mark = p.sent.count
        p.engine.disableMicrophone(notifyHost: true, reason: "test")
        #expect(Array(p.sent[mark...]) == [openFailed, credit1])
        #expect(p.answerPermission(true).isEmpty && p.source.starts == 0)
    }

    @Test func readDataV2WithSequenceWhenRWV2IsOn() {
        let h = CaptureHarness()
        h.feed(hex("00 03 00 10 00 00 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        h.feed(hex("07 02"))
        let out = h.deliver(320)
        #expect(out == [hex("88 02 0C 00 04 00 00 00 00 00 00 00 02 00 01 A0"), credit1,
                        hex("88 02 0C 00 04 00 01 00 00 00 00 00 02 00 02 A0"), credit1])
    }

    @Test func reOpenAndInitStopCapture() {
        let h = CaptureHarness()
        h.feed(hex("00 02 00"))
        h.feed(openOpus16)
        h.answerPermission(true)
        h.feed(hex("07 02"))
        h.feed(hex("01 02 06 00 14 00 00 00 00 00"))   // re-OPEN with Opus 48k stereo
        #expect(!h.source.running)
        #expect(h.answerPermission(true) == [openOK, credit1])
        h.feed(hex("07 02"))
        #expect(h.source.format == AudioStreamFormat(sampleRate: 48000, channels: 2))
        h.feed(hex("00 02 00"))
        #expect(!h.source.running && h.engine.captureState == .closed)
    }
}

@Suite(.serialized) struct AudioCaptureOpusTests {
    private func ready(_ sub: UInt16) -> Bool {
        if let reason = ProcessInfo.processInfo.environment["ICA_TEST_SKIP_OPUS"] {
            print("Opus encoder test skipped explicitly (ICA_TEST_SKIP_OPUS): \(reason)")
            return false
        }
        #expect(OpusSupport.encodableSubformats.contains(sub), "no AudioToolbox Opus encoder for \(sub); set ICA_TEST_SKIP_OPUS=<reason> to skip")
        #expect(OpusSupport.decodableSubformats.contains(sub), "no AudioToolbox Opus decoder for \(sub)")
        return OpusSupport.encodableSubformats.contains(sub) && OpusSupport.decodableSubformats.contains(sub)
    }

    @Test func encodableProbeIsConsistent() {
        #expect(OpusSupport.probeEncoder() == OpusSupport.encodableSubformats)
        #expect(OpusSupport.encodableSubformats.isSubset(of: Set(AudioFormatCode.opusSubformats)))
        if !OpusSupport.systemEncoderListed { #expect(OpusSupport.encodableSubformats.isEmpty) }
        #expect(AudioEngine.Config().opusEncodeSubformats == OpusSupport.encodableSubformats)
    }

    /// The tone through the real encoder in odd-sized chunks: one 10 ms packet per frame, decodable to the tone.
    @Test(arguments: [UInt16(0x14), 0x02, 0x10, 0x03])
    func tenMillisecondPacketsDecodeToTheTone(subformat: UInt16) throws {
        guard ready(subformat) else { return }
        let code = AudioFormatCode(6, subformat)
        let stream = try #require(code.opus)
        let encoder = try #require(OpusEncoder(code))
        #expect(encoder.frameCount == Int(stream.sampleRate / 100))
        let uplink = AudioUplink(encoder: encoder)
        let tone = AudioToneSource(amplitude: 0.3)
        var packets: [Data] = []
        var remaining = Int(stream.sampleRate)   // 1 s
        var chunk = 37
        while remaining > 0 {
            let n = min(remaining, chunk)
            packets += uplink.push(tone.generate(frames: n, format: stream))
            remaining -= n
            chunk = chunk * 7 % 997 + 1
        }
        #expect(uplink.errors == 0 && uplink.framesEncoded == 100 && uplink.pendingSamples == 0)
        #expect(packets.count >= 95 && packets.count <= 100)
        for p in packets { #expect(OpusDecoder.samplesAt48k(p) == 480) }
        // READ_DATA frames as the engine sends them carry `u16 L` + packet; the playback decoder reads the same.
        let decoder = try #require(OpusDecoder(code))
        var w = ByteWriter()
        for p in packets { w.u16(UInt16(p.count)); w.raw(p) }
        let samples = decoder.decode(w.data)
        #expect(decoder.errors == 0)
        #expect(samples.count / stream.channels > Int(stream.sampleRate * 0.9))
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.2 && peak < 0.45)
    }

    @Test func toneSourceThroughTheEngineWithTheRealEncoder() throws {
        guard ready(0x14) else { return }
        var config = AudioEngine.Config()
        config.microphone = true
        let engine = AudioEngine(config: config)
        var sent: [[UInt8]] = []
        engine.output = { if case .channel(let d) = $0 { sent.append([UInt8](d)) } }
        final class Tone: AudioCaptureSource {
            let tone = AudioToneSource()
            var deliver: (([Float]) -> Void)?
            var format: AudioStreamFormat?
            func requestPermission(_ completion: @escaping (Bool) -> Void) { tone.requestPermission(completion) }
            func start(format: AudioStreamFormat, deliver: @escaping ([Float]) -> Void) throws { self.format = format; self.deliver = deliver }
            func stop() { deliver = nil }
        }
        let source = Tone()
        engine.captureSource = source
        engine.receive(Data(hex("00 02 00")))
        engine.receive(Data(hex("01 02 06 00 14 00 00 00 00 00")))
        engine.receive(Data(hex("07 02")))
        let stream = try #require(source.format)
        for _ in 0..<10 { source.deliver?(source.tone.generate(frames: 480, format: stream)) }
        let frames = sent.filter { $0.first == 0x83 }
        #expect(frames.count >= 9)
        for f in frames {
            let total = Int(f[4]) | Int(f[5]) << 8, packet = Int(f[6]) | Int(f[7]) << 8
            #expect(Array(f[0...3]) == hex("83 02 06 00") && total == packet + 2 && f.count == 6 + total)
        }
    }
}

@Suite struct AudioToneSourceTests {
    @Test func generateIsContinuousAndInRange() {
        let tone = AudioToneSource(frequency: 1000, amplitude: 0.5)
        let s = AudioStreamFormat(sampleRate: 8000, channels: 2)
        let a = tone.generate(frames: 3, format: s), b = tone.generate(frames: 5, format: s)
        let fresh = AudioToneSource(frequency: 1000, amplitude: 0.5).generate(frames: 8, format: s)
        #expect(zip(a + b, fresh).allSatisfy { abs($0 - $1) < 1e-5 })
        #expect(fresh.max()! <= 0.5 && fresh.min()! >= -0.5)
        #expect(fresh[0] == fresh[1])   // both channels
        var permitted = false
        tone.requestPermission { permitted = $0 }
        #expect(permitted)
    }

    @Test func timerDeliversUntilStopped() async throws {
        let tone = AudioToneSource()
        let lock = NSLock()
        var samples = 0
        try tone.start(format: AudioStreamFormat(sampleRate: 16000, channels: 1)) { s in
            lock.withLock { samples += s.count }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        tone.stop()
        let atStop = lock.withLock { samples }
        #expect(atStop > 0 && atStop <= 16000 * 3 / 10)
        try await Task.sleep(nanoseconds: 60_000_000)
        let later = lock.withLock { samples }
        #expect(later == atStop)
    }
}

/// Review item 2: the microphone stops when a disconnect or logoff starts, before it completes.
@Suite struct AudioCaptureSessionEndTests {
    private func session() throws -> (ICASession, FakeSource) {
        let text = "[ApplicationServers]\nX=\n[X]\nSSLProxyHost=gw.example:443\nAddress=ticket\nCGPSecurityTicket=On\nTWIMode=On\nInitialProgram=#Test\n"
        let ica = try #require(ICAFile(text: text))
        var config = WinstationDriver.Configuration()
        config.logon = WDLogon(ica: ica)
        var audio = AudioEngine.Config()
        audio.microphone = true
        audio.opusEncodeSubformats = Set(AudioFormatCode.opusSubformats)
        let s = try ICASession(ica: ica, configuration: config, audio: audio)
        let source = FakeSource()
        let engine = try #require(s.audio)
        engine.captureSource = source
        engine.makeEncoder = { code in code.opus.map { FakeEncoder(stream: $0, frameCount: Int($0.sampleRate / 100)) } }
        return (s, source)
    }

    /// Drives the engine on the session queue to recording.
    private func record(_ s: ICASession, _ source: FakeSource) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.perform {
                s.audio!.receive(Data(hex("00 02 00") + openOpus16))
                source.permissionRequests.removeFirst()(true)
                s.audio!.receive(Data(hex("07 02")))
                c.resume()
            }
        }
    }

    private func state(_ s: ICASession, _ source: FakeSource) async -> (Bool, Bool, Bool) {
        await withCheckedContinuation { c in s.perform { c.resume(returning: (source.running, s.audio!.microphoneDisabled, s.isClosed)) } }
    }

    @Test func logoffStopsTheMicrophoneBeforeItCompletes() async throws {
        let (s, source) = try session()
        await record(s, source)
        #expect(source.running)
        // The TWI channel is not up, so the logoff itself cannot be sent; the microphone stops anyway.
        let sent: Bool = await withCheckedContinuation { c in s.logoff { c.resume(returning: $0) } }
        let (running, disabled, closed) = await state(s, source)
        #expect(!sent && !running && disabled && !closed)
    }

    @Test func closeStopsTheMicrophoneFirst() async throws {
        let (s, source) = try session()
        await record(s, source)
        #expect(source.running)
        s.disableMicrophone()   // the menu item; also checks the public path
        let (running, disabled, _) = await state(s, source)
        #expect(!running && disabled)

        let (t, other) = try session()
        await record(t, other)
        // close() queues the stop ahead of FINISH on the session queue. `microphoneDisabled` is set only by that
        // path (the session end's shutdown does not set it), so it shows the stop came from close() itself.
        await t.close(timeout: 0.2)
        let (running2, disabled2, closed2) = await state(t, other)
        #expect(!running2 && disabled2 && closed2)
        #expect(other.stops == 1)
    }
}
