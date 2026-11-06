import Testing
import Foundation
import AudioToolbox
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }

/// Records what the engine hands to its sink.
private final class RecordingSink: AudioSink {
    enum Call: Equatable {
        case open(UInt8, AudioStreamFormat, AudioFormatCode)
        case write(UInt8, Int)
        case close(UInt8)
        case suspend, resume, stop
    }
    var calls: [Call] = []
    var samples: [Float] = []
    func audioOpen(device: UInt8, stream: AudioStreamFormat, code: AudioFormatCode) { calls.append(.open(device, stream, code)) }
    func audioWrite(device: UInt8, samples: [Float]) {
        calls.append(.write(device, samples.count))
        self.samples += samples
    }
    func audioClose(device: UInt8) { calls.append(.close(device)) }
    func audioSuspend() { calls.append(.suspend) }
    func audioResume() { calls.append(.resume) }
    func audioStop() { calls.append(.stop) }
}

/// Inline engine with a manual idle-flush clock; every channel write it makes, in order.
private final class AudioHarness {
    let engine: AudioEngine
    let sink = RecordingSink()
    var sent: [[UInt8]] = []
    var timers: [(delay: TimeInterval, block: () -> Void)] = []

    init(opus: Set<UInt16> = Set(AudioFormatCode.opusSubformats), codecs: Set<AudioCodecKind> = Set(AudioCodecKind.allCases),
         idleTimer: Bool = true) {
        var config = AudioEngine.Config()
        config.opusSubformats = opus
        config.codecs = codecs
        engine = AudioEngine(config: config)
        engine.output = { [unowned self] out in
            guard case .channel(let d) = out else { Issue.record("unexpected WD packet"); return }
            sent.append([UInt8](d))
        }
        engine.sink = sink
        if idleTimer { engine.scheduleAfter = { [unowned self] delay, block in timers.append((delay, block)) } }
    }

    @discardableResult
    func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        let before = sent.count
        engine.receive(Data(bytes))
        return Array(sent[before...])
    }

    @discardableResult
    func feed(_ command: AudioHostCommand) -> [[UInt8]] { feed([UInt8](command.encode())) }

    /// Fires the pending idle timers (as the session queue would after 200 ms).
    @discardableResult
    func fireTimers() -> [[UInt8]] {
        let before = sent.count
        let pending = timers
        timers = []
        pending.forEach { $0.block() }
        return Array(sent[before...])
    }
}

private let credit1 = hex("80 01 00 01 00")
private let buffer1 = hex("80 02 00 01 00")

private func pcmWrite(_ bytes: [UInt8], device: UInt8 = 1) -> AudioHostCommand {
    .write(device: device, dataOffset: 8, pad: 0, data: Data(bytes))
}

// MARK: - Module

@Suite struct AudioModuleTests {
    /// 2026-11-05 12:00:00 local time, the date of the worked example.
    static let exampleDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!

    @Test func moduleGolden55BytesAsTheSpecExample() {
        let m = WDModules.audio(date: Self.exampleDate)
        // docs/98 §1.4, the one-line form with xx = 00 (one module, nothing remaining).
        let expected = hex("37 00 00 03 01 02") + [UInt8](repeating: 0, count: 13) + hex("49 43 41") + [UInt8](repeating: 0, count: 6)
            + hex("65 5D 00 60 00 00 00 00 13 00 00 00 00 00 00 00 00 00 00 00 D8 FF 01 10 00 00 00")
        #expect(expected.count == 55)
        #expect(m.count == 55)
        let packet = WDModules.initResponsePackets([m])[0]
        #expect(Array(packet.prefix(3)) == hex("01 37 00"))
        #expect(Array(packet.dropFirst(3)) == expected)
    }

    @Test func vdDataTruncationAndOddCapsOffset() {
        let m = WDModules.audio(capabilities: 0x11, date: Self.exampleDate)
        #expect(AudioWire.bufferBudget == 0xFFD8)
        #expect(Array(m[48...50]) == hex("D8 FF 01"))
        // The caps u32 starts at the odd offset 51 and ends the module; never `D8 FF 13 00`.
        #expect(Array(m[51...54]) == hex("11 00 00 00"))
        #expect(!(m[48...51].elementsEqual(hex("D8 FF 13 00"))))
        #expect(m[41] == 0)  // flow type 0
        #expect(m[3] == 3 && m[4] == 1 && m[5] == 2)
    }

    @Test func engineProvidesWholeModuleInInitResponseAndBindTable() throws {
        let wd = WinstationDriver(configuration: {
            var c = WinstationDriver.Configuration()
            c.logon.initialProgram = "#Notepad"
            return c
        }())
        wd.register(ThinwireEngine())
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        let engine = AudioEngine()
        var events: [String] = []
        engine.onEvent = { events.append("\($0)") }
        #expect(wd.register(engine) == 19)
        let (modules, names) = try wd.buildModules()
        let index = try #require(names.firstIndex(of: "CTXCAM "))
        #expect(index > names.firstIndex(of: "CTXCLIP")!)
        let module = modules[index]
        // Not the generic 48-byte VD (versions 1/1, no VD data) the WD would build without the hook (§1.4 traps).
        #expect(module.count == 55)
        #expect(module[4] == 1 && module[5] == 2 && Array(module[48...54]) == hex("D8 FF 01 10 00 00 00"))
        #expect(engine.diagnostics.moduleBytes == module)
        #expect(events.first?.hasPrefix("module 55 B: ") == true)
        // WD module bind table: "CTXCAM " NUL 13 00 (§1.5).
        let bind = hex("43 54 58 43 41 4D 20 00 13 00")
        #expect(modules[0].indices.contains { i in i + bind.count <= modules[0].count && Array(modules[0][i..<i + bind.count]) == bind })
    }
}

// MARK: - Wire

@Suite struct AudioWireTests {
    static let samples: [AudioHostCommand] = [
        .initialize(version: 2, reserved: 0, caps: nil),
        .initialize(version: 3, reserved: 1, caps: 0x10),
        .open(device: 1, format: AudioFormatCode(6, 0x14), extra: [0, 0, 0, 0]),
        .close(device: 1),
        .write(device: 1, dataOffset: 8, pad: 0, data: Data([1, 2, 3])),
        .write(device: 1, dataOffset: 11, pad: 7, data: Data([9, 8])),
        .resetAck(device: 2),
        .requestCapInfo(device: 1, listOffset: 6, formats: [AudioFormatCode(1, 0x113), AudioFormatCode(5, 0x118)]),
        .requestCapInfo(device: 1, listOffset: 9, formats: [AudioFormatCode(6, 4)]),
        .readRequest(device: 2, size: 640, count: 4),
        .startRecord(device: 2), .stopRecord(device: 2), .resetRecord(device: 2),
        .setControl(a: 1, b: 2, c: 3, value: 0xFFFF_0000),
        .writeV2(device: 1, offset: 12, sequence: 0xFFFF, reserved: [0, 0, 0, 0], data: Data([5, 6, 7, 8])),
        .unknown(0x42),
    ]

    @Test func layouts() {
        #expect([UInt8](AudioHostCommand.initialize(version: 2, reserved: 0, caps: nil).encode()) == hex("00 02 00"))
        #expect([UInt8](AudioHostCommand.initialize(version: 3, reserved: 0, caps: 0x10).encode()) == hex("00 03 00 10 00 00 00"))
        #expect([UInt8](AudioHostCommand.open(device: 1, format: AudioFormatCode(6, 0x14), extra: []).encode()) == hex("01 01 06 00 14 00 00 00 00 00"))
        // WRITE: header 8, data at max(offset, 8); offset 10 skips two bytes.
        #expect([UInt8](AudioHostCommand.write(device: 1, dataOffset: 10, pad: 0, data: Data([0xAA])).encode())
                == hex("03 01 0A 00 01 00 00 00 00 00 AA"))
        #expect([UInt8](AudioHostCommand.writeV2(device: 1, offset: 12, sequence: 7, reserved: [], data: Data([0xAA])).encode())
                == hex("0B 01 0C 00 01 00 07 00 00 00 00 00 AA"))
        #expect([UInt8](AudioHostCommand.setControl(a: 1, b: 2, c: 3, value: 4).encode()) == hex("0A 01 02 03 04 00 00 00"))
    }

    @Test func specCapInfoExampleParses() {
        var p = AudioStreamParser()
        let items = p.feed(Data(hex("05 01 06 00 03 00 01 00 13 01 05 00 18 01 06 00 14 00")))
        #expect(items.count == 1 && items[0].length == 18)
        #expect(items[0].command == .requestCapInfo(device: 1, listOffset: 6,
                                                   formats: [AudioFormatCode(1, 0x113), AudioFormatCode(5, 0x118), AudioFormatCode(6, 0x14)]))
    }

    @Test func roundTripWholeAndByteByByte() {
        let stream = Self.samples.flatMap { [UInt8]($0.encode()) }
        var whole = AudioStreamParser()
        #expect(whole.feed(Data(stream)).map(\.command) == Self.samples)
        #expect(whole.pendingBytes == 0)
        var bytewise = AudioStreamParser()
        var got: [AudioHostCommand] = []
        for b in stream { got += bytewise.feed(Data([b])).map(\.command) }
        #expect(got == Self.samples)
        #expect(bytewise.pendingBytes == 0)
        for c in Self.samples {
            var single = AudioStreamParser()
            #expect(single.feed(c.encode()).map(\.length) == [c.encode().count])
        }
    }

    @Test func incompleteCommandsWait() {
        var p = AudioStreamParser()
        #expect(p.feed(Data(hex("00 03 00 10"))).isEmpty)   // version 3 needs the caps u32
        #expect(p.feed(Data(hex("00 00 00"))).map(\.command) == [.initialize(version: 3, reserved: 0, caps: 0x10)])
        #expect(p.feed(Data(hex("03 01 08 00 04 00 00 00 01 02 03"))).isEmpty)
        #expect(p.pendingBytes == 11)
        #expect(p.feed(Data(hex("04 02"))).count == 1)        // the WRITE; CLOSE needs its device byte
        #expect(p.feed(Data(hex("01"))).map(\.command) == [.close(device: 1)])
        #expect(p.pendingBytes == 0)
    }

    @Test func replies() {
        #expect(AudioReply.initialCredits == [hex("80 01 00 80 00"), hex("80 02 00 80 00")])
        #expect(AudioReply.credit(.command, count: 32) == hex("80 01 00 20 00"))
        #expect(AudioReply.credit(.buffer, device: 3, count: 256) == hex("80 02 03 00 01"))
        #expect(AudioReply.resetDevice(1, reason: 3) == hex("81 01 03"))
        #expect(AudioReply.capInfo(device: 1, formats: [AudioFormatCode(1, 0x113), AudioFormatCode(6, 0x14)])
                == hex("82 01 06 00 02 00 01 00 13 01 06 00 14 00"))
        #expect(AudioReply.capInfo(device: 2, formats: []) == hex("82 02 06 00 00 00"))
        #expect(AudioReply.openResponse(device: 2, status: 0) == hex("84 02 80 02 40 00 00"))
    }

    @Test func formatCodes() {
        #expect(AudioFormatCode.pcmSubformats.count == 16 && AudioFormatCode.opusSubformats.count == 10)
        let p = AudioFormatCode(1, 0x113).pcm
        #expect(p?.stream == AudioStreamFormat(sampleRate: 44100, channels: 2) && p?.bits == 16)
        #expect(AudioFormatCode(1, 0x001).pcm?.stream == AudioStreamFormat(sampleRate: 11025, channels: 1))
        #expect(AudioFormatCode(1, 0x001).pcm?.bits == 8)
        #expect(AudioFormatCode(1, 0x200).pcm == nil)     // unknown bit
        #expect(AudioFormatCode(6, 0x14).opus == AudioStreamFormat(sampleRate: 48000, channels: 2))
        #expect(AudioFormatCode(6, 0x02).opus == AudioStreamFormat(sampleRate: 16000, channels: 1))
        #expect(AudioFormatCode(6, 0x05).opus == nil)
        #expect(AudioFormatCode(5, 0x118).description == "Speex WB mono q8")
    }
}

// MARK: - Engine

@Suite struct AudioEngineTests {
    /// docs/98 §5.2 worked bytes, with INIT first (§4.1).
    @Test func workedExchange() {
        let h = AudioHarness()
        #expect(h.feed(hex("00 02 00")) == [hex("80 01 00 80 00"), hex("80 02 00 80 00")])
        #expect(h.engine.diagnostics.initialCreditsSent)
        #expect(h.feed(hex("05 01 06 00 03 00 01 00 13 01 05 00 18 01 06 00 14 00"))
                == [hex("82 01 06 00 02 00 01 00 13 01 06 00 14 00"), credit1, buffer1])
        #expect(h.feed(hex("01 01 06 00 14 00 00 00 00 00")) == [credit1])
        #expect(h.engine.openDevices == [1])
        #expect(h.sink.calls == [.open(1, AudioStreamFormat(sampleRate: 48000, channels: 2), AudioFormatCode(6, 0x14))])
    }

    @Test func pcmOnlyWithoutOpusDecoder() {
        let h = AudioHarness(opus: [])
        h.feed(hex("00 02 00"))
        #expect(h.feed(hex("05 01 06 00 03 00 01 00 13 01 05 00 18 01 06 00 14 00")).first == hex("82 01 06 00 01 00 01 00 13 01"))
        let limited = AudioHarness(codecs: [.opus])
        limited.feed(hex("00 02 00"))
        #expect(limited.feed(hex("05 01 06 00 02 00 01 00 13 01 06 00 14 00")).first == hex("82 01 06 00 01 00 06 00 14 00"))
    }

    @Test func captureDeviceAndOtherCommands() {
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        #expect(h.feed(hex("05 02 06 00 01 00 05 00 18 01")) == [hex("82 02 06 00 00 00"), credit1, buffer1])
        #expect(h.feed(hex("01 02 05 00 18 01 00 00 00 00")) == [hex("84 02 80 02 40 00 FF"), credit1])
        #expect(h.feed(hex("03 02 08 00 01 00 00 00 AA")) == [hex("81 02 03"), credit1, buffer1])
        #expect(h.feed(hex("07 01")) == [hex("81 01 03"), credit1])
        #expect(h.feed(hex("06 01 80 02 04 00")) == [hex("81 01 03"), credit1])
        #expect(h.feed(hex("07 02")) == [credit1])
        #expect(h.feed(hex("04 02")) == [credit1])
        #expect(h.feed(hex("0A 01 02 03 04 05 06 07")) == [credit1])
        #expect(h.engine.diagnostics.setControlCount == 1 && h.engine.diagnostics.recentSetControls == [hex("0A 01 02 03 04 05 06 07")])
        #expect(h.feed(hex("7F")) == [credit1])
        #expect(h.feed(hex("01 05 01 00 13 01 00 00 00 00")) == [credit1])   // unknown device
        #expect(h.feed(hex("02 01")) == [credit1])                           // CLOSE of a device that is not open
        #expect(h.sink.calls.isEmpty)
    }

    @Test func undecodableOpenStillCredits() {
        let h = AudioHarness(opus: [])
        h.feed(hex("00 02 00"))
        #expect(h.feed(hex("01 01 06 00 14 00 00 00 00 00")) == [credit1])
        #expect(h.engine.openDevices.isEmpty)
        h.feed(hex("03 01 08 00 02 00 00 00 01 00"))
        #expect(h.sink.calls.isEmpty)
        #expect(h.engine.diagnostics.recentOpens.map(\.decoder) == [false])
        #expect(h.engine.diagnostics.openCount == 1 && h.engine.diagnostics.decodableOpenCount == 0)
    }

    @Test func writeCreditsBatchAt32AndIdleFlush() {
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        h.feed(hex("01 01 01 00 10 01 00 00 00 00"))   // PCM 8 kHz stereo 16-bit
        var out: [[UInt8]] = []
        for _ in 0..<31 { out += h.feed(pcmWrite([0, 0, 0, 0])) }
        #expect(out.isEmpty)
        #expect(h.timers.count == 1 && h.timers[0].delay == 0.2)
        #expect(h.feed(pcmWrite([0, 0, 0, 0])) == [hex("80 01 00 20 00"), hex("80 02 00 20 00")])
        // The timer armed for the full batch is stale now.
        #expect(h.fireTimers().isEmpty)
        h.feed(pcmWrite([0, 0, 0, 0]))
        #expect(h.fireTimers() == [credit1, buffer1])
        #expect(h.fireTimers().isEmpty)
        // A CLOSE returns the partial batch before its own credit.
        h.feed(pcmWrite([0, 0, 0, 0]))
        h.feed(pcmWrite([0, 0, 0, 0]))
        #expect(h.feed(hex("02 01")) == [hex("80 01 00 02 00"), hex("80 02 00 02 00"), credit1])
        #expect(h.fireTimers().isEmpty)
        let d = h.engine.diagnostics
        #expect(d.creditsSent[1] == 128 + 1 + 32 + 1 + 2 + 1)
        #expect(d.creditsSent[2] == 128 + 32 + 1 + 2)
    }

    @Test func sixtyFiveWritesGiveTwoBatchesAndOneFlush() {
        let h = AudioHarness(idleTimer: false)
        h.feed(hex("00 02 00"))
        h.feed(hex("01 01 01 00 00 00 00 00 00 00"))   // PCM 8 kHz mono 8-bit
        var out: [[UInt8]] = []
        for _ in 0..<65 { out += h.feed(pcmWrite([0x80])) }
        #expect(out == [hex("80 01 00 20 00"), hex("80 02 00 20 00"), hex("80 01 00 20 00"), hex("80 02 00 20 00")])
        #expect(h.feed(hex("02 01")) == [credit1, buffer1, credit1])
    }

    @Test func splitAndMergedWritesGiveIdenticalOutput() {
        var stream = hex("00 02 00") + hex("05 01 06 00 02 00 01 00 11 01 06 00 14 00") + hex("01 01 01 00 11 01 00 00 00 00")
        var rng = SystemRandomNumberGenerator()
        for i in 0..<40 {
            let samples = (0..<(20 + i)).flatMap { _ in [UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng)] }
            let offset: UInt16 = i % 5 == 0 ? 10 : 8
            stream += [UInt8](AudioHostCommand.write(device: 1, dataOffset: offset, pad: 0, data: Data(samples)).encode())
        }
        stream += hex("0A 00 00 00 00 00 00 00") + hex("02 01") + hex("7E")

        let whole = AudioHarness()
        whole.feed(stream)
        let bytewise = AudioHarness()
        for b in stream { bytewise.feed([b]) }
        let chunked = AudioHarness()
        var i = 0
        while i < stream.count {
            let n = min(stream.count - i, Int.random(in: 1...97))
            chunked.feed(Array(stream[i..<(i + n)]))
            i += n
        }
        #expect(!whole.sent.isEmpty)
        for other in [bytewise, chunked] {
            #expect(other.sent == whole.sent)
            #expect(other.sink.samples == whole.sink.samples)
            #expect(other.engine.diagnostics.writes == 40)
        }
        #expect(whole.engine.diagnostics.decodedFrames > 0)
    }

    @Test func pcmFrameSplitAcrossWrites() {
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        h.feed(hex("01 01 01 00 10 01 00 00 00 00"))   // PCM 8 kHz stereo 16-bit: 4-byte frames
        h.feed(pcmWrite([0x00, 0x40, 0x00]))             // 3 bytes: no complete frame yet
        #expect(h.sink.samples.isEmpty)
        h.feed(pcmWrite([0xC0, 0xFF, 0x7F]))             // completes frame 1; 2 bytes wait
        #expect(h.sink.samples == [0.5, -0.5])
    }

    @Test func repeatedInitStartsOver() {
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        h.feed(hex("01 01 01 00 00 00 00 00 00 00"))
        #expect(h.feed(hex("00 03 00 10 00 00 00")) == AudioReply.initialCredits)
        #expect(h.engine.openDevices.isEmpty)
        #expect(h.engine.diagnostics.readWriteV2)
        #expect(h.sink.calls.last == .close(1))
    }

    @Test func writeV2DecodesAndTracksSequence() {
        let h = AudioHarness()
        h.feed(hex("00 03 00 10 00 00 00"))
        h.feed(hex("01 01 01 00 00 00 00 00 00 00"))
        for seq: UInt16 in [0xFFFE, 0xFFFF, 0, 2] {
            h.feed(.writeV2(device: 1, offset: 12, sequence: seq, reserved: [], data: Data([0xFF, 0x00])))
        }
        #expect(h.engine.diagnostics.sequenceGaps == 1)
        #expect(h.sink.samples.count == 8)
        #expect(h.sink.samples.first == 1 && h.sink.samples[1] == -1)
    }

    @Test func suspendResumeAndShutdown() {
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        h.feed(hex("01 01 01 00 00 00 00 00 00 00"))
        h.engine.suspend()
        h.engine.resume()
        h.engine.shutdown()
        h.engine.shutdown()
        #expect(h.sink.calls.suffix(3) == [.suspend, .resume, .stop])
        #expect(h.feed(hex("00 02 00")).isEmpty)
        #expect(h.fireTimers().isEmpty)
    }

    @Test func diagnosticsKeepCountsAndOnlyTheLastEntries() {
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        for i in 0..<40 {
            h.feed(hex("01 01 01 00 00 00 00 00 00 00"))
            h.feed(.setControl(a: UInt8(i), b: 0, c: 0, value: 0))
        }
        let d = h.engine.diagnostics
        #expect(d.openCount == 40 && d.decodableOpenCount == 40 && d.recentOpens.count == AudioDiagnostics.recentLimit)
        #expect(d.setControlCount == 40 && d.recentSetControls.count == AudioDiagnostics.recentLimit)
        #expect(d.recentSetControls.last?[1] == 39 && d.recentSetControls.first?[1] == UInt8(40 - AudioDiagnostics.recentLimit))
    }

    @Test func verdicts() {
        var d = AudioDiagnostics()
        #expect(d.verdict(soundTriggered: true).hasPrefix("no CTXCAM module"))
        d.moduleBytes = [0]
        #expect(d.verdict(soundTriggered: true).hasPrefix("D6"))
        let h = AudioHarness()
        _ = h.engine.module(channel: 19, date: Date())
        h.feed(hex("00 02 00"))
        #expect(h.engine.diagnostics.verdict(soundTriggered: false).contains("no CAPINFO"))
        h.feed(hex("05 01 06 00 01 00 05 00 18 01"))
        #expect(h.engine.diagnostics.verdict(soundTriggered: true).contains("D4"))
        h.feed(hex("05 01 06 00 01 00 01 00 00 00"))
        #expect(h.engine.diagnostics.verdict(soundTriggered: true).contains("D4: a sound was triggered"))
        h.feed(hex("01 01 01 00 00 00 00 00 00 00"))
        #expect(h.engine.diagnostics.verdict(soundTriggered: true).contains("no WRITE"))
        h.feed(pcmWrite([0x80, 0x80]))
        #expect(h.engine.diagnostics.verdict(soundTriggered: true).contains("playback works"))
    }
}

// MARK: - Decoders and WAV

@Suite struct AudioDecoderTests {
    @Test func pcm8BitUnsigned() throws {
        let d = try #require(PCMDecoder(AudioFormatCode(1, 0)))
        let out = d.decode(Data([0, 255, 128]))
        #expect(out[0] == -1 && out[1] == 1)
        #expect(abs(out[2] - (128 / 127.5 - 1)) < 1e-6)
    }

    @Test func pcm16BitSignedLE() throws {
        let d = try #require(PCMDecoder(AudioFormatCode(1, 0x103)))
        #expect(d.stream == AudioStreamFormat(sampleRate: 44100, channels: 1))
        #expect(d.decode(Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00])) == [-1, Float(32767) / 32768, 0])
    }

    @Test func opusPacketFraming() {
        let (packets, truncated) = OpusDecoder.packets(in: Data(hex("02 00 AA BB 01 00 CC 05 00 01")))
        #expect(packets == [Data([0xAA, 0xBB]), Data([0xCC])])
        #expect(truncated)
        #expect(OpusDecoder.packets(in: Data(hex("01 00 AA"))).truncated == false)
        #expect(OpusDecoder.packets(in: Data()).packets.isEmpty)
    }

    /// RFC 6716 §3.1: config → frame size, count code → frames.
    @Test func opusTOCDurations() {
        #expect(OpusDecoder.samplesAt48k(Data([0x00])) == 480)          // SILK NB 10 ms, 1 frame
        #expect(OpusDecoder.samplesAt48k(Data([0x08 | 1])) == 1920)     // SILK 20 ms, 2 frames
        #expect(OpusDecoder.samplesAt48k(Data([UInt8(13 << 3)])) == 960) // hybrid 20 ms
        #expect(OpusDecoder.samplesAt48k(Data([UInt8(31 << 3)])) == 960) // CELT FB 20 ms
        #expect(OpusDecoder.samplesAt48k(Data([UInt8(16 << 3)])) == 120) // CELT 2.5 ms
        #expect(OpusDecoder.samplesAt48k(Data([UInt8(31 << 3) | 3, 6])) == 5760)
        #expect(OpusDecoder.samplesAt48k(Data([UInt8(31 << 3) | 3, 7])) == nil)   // 140 ms
        #expect(OpusDecoder.samplesAt48k(Data([UInt8(31 << 3) | 3])) == nil)
        #expect(OpusDecoder.samplesAt48k(Data()) == nil)
    }

    @Test func pcmPathToWAVWriter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ica-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audiotest.wav")
        let writer = AudioWAVWriter(url: url, queue: nil)
        let h = AudioHarness()
        h.engine.sink = writer
        h.feed(hex("00 02 00"))
        h.feed(hex("01 01 01 00 12 01 00 00 00 00"))   // PCM 22050 Hz stereo 16-bit
        let frame: [UInt8] = [0x00, 0x40, 0x00, 0xC0]  // +0.5, -0.5
        for _ in 0..<10 { h.feed(pcmWrite(Array([[UInt8]](repeating: frame, count: 100).joined()))) }
        h.feed(hex("02 01"))
        h.feed(hex("01 01 01 00 00 00 00 00 00 00"))   // another format: second file
        h.feed(pcmWrite([255, 128, 0]))
        h.engine.shutdown()
        writer.finish()

        let files = writer.written
        #expect(files.count == 2)
        #expect(files[0].url == url && files[0].frames == 1000 && abs(files[0].peak - 0.5) < 1e-6)
        #expect(files[1].url.lastPathComponent == "audiotest-2.wav" && files[1].frames == 3 && files[1].peak == 1)
        let data = [UInt8](try Data(contentsOf: url))
        #expect(data.count == 44 + 4000)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8) && Array(data[8..<16]) == Array("WAVEfmt ".utf8))
        #expect(Array(data[4..<8]) == [0xC4, 0x0F, 0, 0])            // 36 + 4000
        #expect(Array(data[22..<28]) == [2, 0, 0x22, 0x56, 0, 0])    // 2 channels, 22050 Hz
        #expect(Array(data[34..<36]) == [16, 0])
        #expect(Array(data[40..<44]) == [0xA0, 0x0F, 0, 0])          // 4000 data bytes
        let first = Int16(bitPattern: UInt16(data[44]) | UInt16(data[45]) << 8)
        let second = Int16(bitPattern: UInt16(data[46]) | UInt16(data[47]) << 8)
        #expect(first == 16384 && second == -16384)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let second8 = [UInt8](try Data(contentsOf: files[1].url))
        #expect(second8.count == 44 + 6 && Array(second8[24..<28]) == [0x40, 0x1F, 0, 0])   // 8000 Hz
    }
}

// MARK: - Opus via AudioToolbox

/// Encodes interleaved Float32 into Opus packets with AudioToolbox (test helper only).
private func opusEncode(_ samples: [Float], stream: AudioStreamFormat, frameDuration: Double) -> [Data]? {
    var pcm = OpusSupport.floatDescription(stream)
    var opus = OpusSupport.opusDescription(stream, framesPerPacket: UInt32(stream.sampleRate * frameDuration))
    var converter: AudioConverterRef?
    guard AudioConverterNew(&pcm, &opus, &converter) == noErr, let converter else { return nil }
    defer { AudioConverterDispose(converter) }
    var maxPacket: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
    final class Feed {
        let data: UnsafeMutablePointer<Float>
        let count: Int
        let channels: Int
        var position = 0
        init(_ s: [Float], channels: Int) {
            data = .allocate(capacity: max(1, s.count))
            data.initialize(from: s, count: s.count)
            count = s.count
            self.channels = channels
        }
        deinit { data.deallocate() }
    }
    let feed = Feed(samples, channels: stream.channels)
    let proc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, user in
        let f = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
        let left = (f.count - f.position) / f.channels
        guard left > 0 else { ioPackets.pointee = 0; return -1 }
        let n = min(Int(ioPackets.pointee), left)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(f.data + f.position)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(n * f.channels * 4)
        ioData.pointee.mBuffers.mNumberChannels = UInt32(f.channels)
        f.position += n * f.channels
        ioPackets.pointee = UInt32(n)
        return noErr
    }
    var packets: [Data] = []
    while true {
        var out = [UInt8](repeating: 0, count: Int(maxPacket))
        var description = AudioStreamPacketDescription()
        var n: UInt32 = 1
        _ = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(stream.channels),
                                                                                 mDataByteSize: maxPacket, mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, proc, Unmanaged.passUnretained(feed).toOpaque(), &n, &list, &description)
        }
        guard n > 0 else { break }
        let start = Int(description.mStartOffset)
        packets.append(Data(out[start..<(start + Int(description.mDataByteSize))]))
    }
    return packets
}

private func sine(_ stream: AudioStreamFormat, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    let frames = Int(stream.sampleRate * seconds)
    return (0..<frames).flatMap { i in
        [Float](repeating: amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / stream.sampleRate)), count: stream.channels)
    }
}

/// The Opus tests need AudioToolbox's Opus encoder (to make packets) and decoder. Without them they FAIL; set
/// ICA_TEST_SKIP_OPUS=<reason> to skip them explicitly (the reason is printed).
private func opusReady(_ subformat: UInt16) -> Bool {
    if let reason = ProcessInfo.processInfo.environment["ICA_TEST_SKIP_OPUS"] {
        print("Opus test skipped explicitly (ICA_TEST_SKIP_OPUS): \(reason)")
        return false
    }
    #expect(OpusSupport.systemEncoderListed, "AudioToolbox lists no Opus encoder; set ICA_TEST_SKIP_OPUS=<reason> to skip")
    #expect(OpusSupport.decodableSubformats.contains(subformat),
            "no AudioToolbox Opus decoder for subformat \(subformat); set ICA_TEST_SKIP_OPUS=<reason> to skip")
    return OpusSupport.systemEncoderListed && OpusSupport.decodableSubformats.contains(subformat)
}

/// WRITE payloads of `perWrite` packets each (`u16 len` + packet), as the host frames them (§6.2).
private func opusWrites(_ packets: [Data], perWrite: Int) -> [Data] {
    stride(from: 0, to: packets.count, by: perWrite).map { start in
        var w = ByteWriter()
        for p in packets[start..<min(packets.count, start + perWrite)] { w.u16(UInt16(p.count)); w.raw(p) }
        return w.data
    }
}

/// RFC 6716 §3.2.5: one code-3 VBR packet from code-0 packets with the same TOC (lengths of all but the last).
private func code3Packet(_ frames: [Data]) -> Data {
    var out: [UInt8] = [frames[0][frames[0].startIndex] & 0xFC | 3, 0x80 | UInt8(frames.count)]
    for f in frames.dropLast() {
        let n = f.count - 1
        if n < 252 { out.append(UInt8(n)) } else {
            let first = 252 + (n & 3)
            out += [UInt8(first), UInt8((n - first) / 4)]
        }
    }
    for f in frames { out += f.dropFirst() }
    return Data(out)
}

@Suite(.serialized) struct AudioOpusTests {
    /// The runtime check alone: a subset of the 10 Opus subformats, empty unless AudioToolbox lists a decoder.
    @Test func availabilityCheckIsConsistent() {
        let probed = OpusSupport.probe()
        #expect(probed.isSubset(of: Set(AudioFormatCode.opusSubformats)))
        if !OpusSupport.systemDecoderListed { #expect(probed.isEmpty) }
        #expect(OpusSupport.decodableSubformats == probed)
        #expect(AudioEngine.Config().opusSubformats == probed)
        for sub in AudioFormatCode.opusSubformats {
            #expect((OpusDecoder(AudioFormatCode(6, sub)) != nil) == probed.contains(sub))
        }
        #expect(OpusDecoder(AudioFormatCode(1, 0x113)) == nil)
    }

    /// Opus WRITEs (three `u16 len` + packet per payload, a truncated tail on the last) through the engine, for
    /// every frame duration and rate; each packet's TOC duration must match what the encoder made.
    @Test(arguments: [
        (UInt16(0x14), 0.0025), (0x14, 0.005), (0x14, 0.01), (0x14, 0.02), (0x14, 0.04), (0x14, 0.06),
        (0x01, 0.02), (0x11, 0.01), (0x03, 0.02), (0x13, 0.06), (0x02, 0.02), (0x10, 0.01), (0x04, 0.04),
    ])
    func roundTripThroughEngine(subformat: UInt16, frame: Double) throws {
        guard opusReady(subformat) else { return }
        let code = AudioFormatCode(6, subformat)
        let stream = try #require(code.opus)
        let seconds = 0.48   // a whole number of packets for every duration
        let packets = try #require(opusEncode(sine(stream, seconds: seconds), stream: stream, frameDuration: frame))
        #expect(!packets.isEmpty)
        for p in packets { #expect(OpusDecoder.samplesAt48k(p) == Int((48000 * frame).rounded())) }
        let h = AudioHarness()
        h.feed(hex("00 02 00"))
        h.feed(.open(device: 1, format: code, extra: []))
        var writes = opusWrites(packets, perWrite: 3)
        writes[writes.count - 1].append(contentsOf: [0x10, 0x00, 0x01])
        for w in writes { h.feed(.write(device: 1, dataOffset: 8, pad: 0, data: w)) }
        h.feed(hex("02 01"))
        let frames = h.sink.samples.count / stream.channels
        let expected = Int(stream.sampleRate * seconds)
        #expect(frames > expected * 9 / 10 && frames <= expected + Int(stream.sampleRate * frame))
        let peak = h.sink.samples.map(abs).max() ?? 0
        #expect(peak > 0.3 && peak < 0.8)
        #expect(h.engine.diagnostics.decodeErrors == 1)   // only the truncated tail
    }

    /// Code-3 packets (several frames in one packet, VBR lengths) decode like the frames one by one.
    @Test(arguments: [(UInt16(0x14), 0.01, 6), (0x14, 0.0025, 48), (0x02, 0.02, 3), (0x13, 0.005, 12)])
    func code3PacketsMatchSingleFrames(subformat: UInt16, frame: Double, perPacket: Int) throws {
        guard opusReady(subformat) else { return }
        let code = AudioFormatCode(6, subformat)
        let stream = try #require(code.opus)
        let singles = try #require(opusEncode(sine(stream, seconds: 0.48), stream: stream, frameDuration: frame))
        for p in singles { try #require(p[p.startIndex] & 3 == 0, "the encoder made a code \(p[p.startIndex] & 3) packet") }
        var merged: [Data] = []
        var made = 0
        var i = 0
        while i < singles.count {
            let group = Array(singles[i..<min(singles.count, i + perPacket)])
            if group.count == perPacket, Set(group.map { $0[$0.startIndex] }).count == 1 {
                merged.append(code3Packet(group))
                made += 1
            } else {
                merged += group
            }
            i += perPacket
        }
        #expect(made > 0)
        for p in merged where p[p.startIndex] & 3 == 3 {
            #expect(OpusDecoder.samplesAt48k(p) == Int((48000 * frame).rounded()) * perPacket)
        }
        let one = try #require(OpusDecoder(code)), other = try #require(OpusDecoder(code))
        let a = opusWrites(singles, perWrite: 4).flatMap { one.decode($0) }
        let b = opusWrites(merged, perWrite: 1).flatMap { other.decode($0) }
        #expect(one.errors == 0 && other.errors == 0)
        #expect(a.count == b.count && !a.isEmpty)
        #expect(zip(a, b).map { abs($0 - $1) }.max() ?? 1 < 1e-4)
    }

    /// A zero-length packet is a lost frame: silence as long as the previous frame, not an error.
    @Test func zeroLengthPacketIsSilenceOfThePreviousFrame() throws {
        guard opusReady(0x14) else { return }
        let code = AudioFormatCode(6, 0x14)
        let stream = try #require(code.opus)
        let d = try #require(OpusDecoder(code))
        #expect(d.decode(Data([0, 0])).count == 480 * 2)   // before any packet: 10 ms
        let packets = try #require(opusEncode(sine(stream, seconds: 0.1), stream: stream, frameDuration: 0.02))
        _ = d.decode(opusWrites(Array(packets.prefix(2)), perWrite: 2)[0])
        let lost = d.decode(Data([0, 0, 0, 0]))
        #expect(lost.count == 2 * 960 * 2 && lost.allSatisfy { $0 == 0 })
        #expect(d.lostPackets == 3 && d.errors == 0)
        #expect(!d.decode(opusWrites([packets[2]], perWrite: 1)[0]).isEmpty)
    }
}

// MARK: - Jitter buffer and settings

@Suite struct AudioJitterTests {
    let policy = AudioJitterPolicy(preRoll: 0.06, lagThreshold: 0.6)

    @Test func prerollHoldsThenReleases() {
        var j = AudioJitterBuffer<Int>(sampleRate: 1000, policy: policy)
        #expect(j.targetFrames == 80)
        for i in 0..<7 {
            guard case .hold = j.push(i, frames: 10) else { Issue.record("expected hold at \(i)"); return }
        }
        guard case .schedule(let chunks) = j.push(7, frames: 10) else { Issue.record("expected release"); return }
        #expect(chunks == Array(0...7))
        #expect(j.queuedFrames == 80 && !j.prerolling)
        guard case .schedule(let next) = j.push(8, frames: 10) else { Issue.record("expected pass-through"); return }
        #expect(next == [8])
    }

    @Test func underrunPrerollsAgain() {
        var j = AudioJitterBuffer<Int>(sampleRate: 1000, policy: policy)
        _ = j.push(0, frames: 60)
        _ = j.push(1, frames: 60)   // target max(80, 1.5 × 60) = 90
        #expect(!j.prerolling && j.queuedFrames == 120 && j.queuedChunks == 2)
        let first = j.played(), second = j.played()
        #expect(!first && second)
        #expect(j.underruns == 1 && j.prerolling)
        guard case .hold = j.push(1, frames: 10) else { Issue.record("expected hold"); return }
    }

    @Test func overrunDropsQueue() {
        var j = AudioJitterBuffer<Int>(sampleRate: 1000, policy: policy)
        _ = j.push(0, frames: 80)
        for i in 1...52 { _ = j.push(i, frames: 10) }
        #expect(j.queuedFrames == 600 && j.targetFrames == 120)
        // §10.2: the oldest audio goes, down to the pre-roll target; the newest keeps playing at once.
        guard case .replaceQueue(let newest) = j.push(99, frames: 10) else { Issue.record("expected replace"); return }
        #expect(newest == Array(42...52) + [99])
        #expect(j.overruns == 1 && !j.prerolling && j.queuedFrames == 120 && j.queuedChunks == 12)
        let dry = j.played()
        #expect(!dry && j.queuedFrames == 110)
    }

    @Test func drainReleasesShortSoundWithoutUnderrun() {
        var j = AudioJitterBuffer<Int>(sampleRate: 1000, policy: policy)
        _ = j.push(0, frames: 30)
        let drained = j.drain()
        #expect(drained == [0])
        let dry = j.played()
        #expect(!dry)
        #expect(j.underruns == 0)
        #expect(j.drain().isEmpty)
    }

    @Test func largeChunksRaiseTargetAndLimit() {
        var j = AudioJitterBuffer<Int>(sampleRate: 1000, policy: policy)
        guard case .hold = j.push(0, frames: 500) else { Issue.record("expected hold"); return }
        #expect(j.targetFrames == 750 && j.lagFrames == 1750)
        guard case .schedule = j.push(1, frames: 500) else { Issue.record("expected release"); return }
        guard case .schedule = j.push(2, frames: 500) else { Issue.record("expected no overrun"); return }
        let results = (0..<4).map { _ in j.played() }
        #expect(results == [false, false, true, false])   // the last: nothing queued any more
    }

    @Test func policyPerCodecAndEnv() {
        #expect(AudioJitterPolicy.for(AudioFormatCode(6, 0x14), env: [:]) == AudioJitterPolicy(preRoll: 0.06, lagThreshold: 0.6))
        #expect(AudioJitterPolicy.for(AudioFormatCode(1, 0x113), env: [:]) == AudioJitterPolicy(preRoll: 0.08, lagThreshold: 1.0))
        let p = AudioJitterPolicy.for(AudioFormatCode(1, 0), env: ["ICA_AUDIO_PREROLL_MS": "200", "ICA_AUDIO_LAG_MS": "1500"])
        #expect(p.preRoll == 0.2 && p.lagThreshold == 1.5)
    }
}

@Suite struct AudioSettingsTests {
    @Test func defaultsAndOverrides() throws {
        let name = "ica.audio.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AudioSettings.load(defaults: defaults, env: [:]).enabled == AudioSettings.defaultEnabled)
        #expect(AudioSettings.defaultEnabled)
        #expect(AudioSettings.load(defaults: defaults, env: ["ICA_AUDIO": "0"]).engineConfig == nil)
        var s = AudioSettings()
        s.enabled = false
        s.save(to: defaults)
        #expect(!AudioSettings.load(defaults: defaults, env: [:]).enabled)
        #expect(AudioSettings.load(defaults: defaults, env: ["ICA_AUDIO": "on"]).enabled)
        let limited = AudioSettings.load(defaults: defaults, env: ["ICA_AUDIO": "1", "ICA_AUDIO_CODECS": "PCM, speex"])
        #expect(limited.codecs == [.pcm])
        #expect(limited.engineConfig?.codecs == [.pcm])
    }
}

@Suite struct AudioFallbackTests {
    @Test func omitsCTXCAMOnceAfterAnUnestablishedDrop() {
        var f = AudioFallback()
        let none = f.takeOmission("Notepad")
        #expect(!none)
        // Dropped after the module went out, before the seamless channel / Thinwire INIT: omit once.
        var r = [f.relaunching("Notepad", announcedAudio: true, established: false),
                 f.takeOmission("Calculator"), f.takeOmission("Notepad"), f.takeOmission("Notepad")]
        #expect(r == [true, false, true, false])
        // The omitted launch dropped too (no CTXCAM in it): the next relaunch announces it again.
        r = [f.relaunching("Notepad", announcedAudio: false, established: false), f.takeOmission("Notepad")]
        #expect(r == [false, false])
        // Early drops before the INIT_RESPONSE, or established sessions, never omit it; clear forgets it.
        r = [f.relaunching("Notepad", announcedAudio: true, established: true),
             f.relaunching("Notepad", announcedAudio: true, established: false)]
        #expect(r == [false, true])
        f.clear("Notepad")
        let after = f.takeOmission("Notepad")
        #expect(!after)
    }
}

@Suite struct AudioTestKeysTests {
    @Test func parsesTheExampleSequence() throws {
        let steps = try AudioTestKeys.parse("ctrl+tab, tab ,Alt+T,esc", keyboardLayout: 0x0407)
        #expect(steps.map(\.text) == ["ctrl+tab", "tab", "alt+t", "esc"])
        #expect(steps.map(\.scancode) == [0x0F, 0x0F, 0x14, 0x01])
        #expect(steps[0].modifiers == [0x1D] && steps[1].modifiers.isEmpty && steps[2].modifiers == [0x38])
        #expect(!steps.contains { $0.scancode == 0x1C || $0.scancode == 0x39 })   // no Enter/Space unless written
    }

    @Test func keysAndLayouts() throws {
        let us = try AudioTestKeys.parse("y,z,0,1,9,f1,f10,f11,f12,enter,space,shift+ctrl+alt+a", keyboardLayout: 0x0409)
        #expect(us.map(\.scancode) == [0x15, 0x2C, 0x0B, 0x02, 0x0A, 0x3B, 0x44, 0x57, 0x58, 0x1C, 0x39, 0x1E])
        #expect(us.last?.modifiers == [0x1D, 0x38, 0x2A])
        let de = try AudioTestKeys.parse("y,z", keyboardLayout: 0x0407)
        #expect(de.map(\.scancode) == [0x2C, 0x15])   // QWERTZ: the keys that type y and z
        let nav = try AudioTestKeys.parse("up,down,left,right,home,end,pgup,pgdn", keyboardLayout: 0x0409)
        #expect(nav.allSatisfy(\.extended) && nav.map(\.scancode) == [0x48, 0x50, 0x4B, 0x4D, 0x47, 0x4F, 0x49, 0x51])
    }

    @Test func invalidSequencesSendNothing() {
        let bad: [(String, AudioTestKeys.Failure)] = [
            ("", .empty), ("tab,,esc", .badStep("")), ("ctrl+", .badStep("ctrl+")), ("meta+a", .badStep("meta+a")),
            ("tab,returnx", .unknownKey("returnx")), ("f13", .unknownKey("f13")), ("ä", .unknownKey("ä")),
            (Array(repeating: "tab", count: 31).joined(separator: ","), .tooLong(31)),
        ]
        for (text, failure) in bad {
            #expect(throws: failure) { try AudioTestKeys.parse(text, keyboardLayout: 0x0407) }
        }
    }
}
