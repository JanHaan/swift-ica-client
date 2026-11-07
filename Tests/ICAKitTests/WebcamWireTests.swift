import Testing
import Foundation
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { UInt8($0, radix: 16)! } }
private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

/// docs/98b §4.3: the host's BIND_REQUEST (63 bytes) and our BIND_RESPONSE (51 bytes).
let webcamBindRequest = hex("""
    3F 00 00 00 04 00 05 00
    0C 00 00 00 00 00 00 00 04 00 00 00
    0C 00 00 00 01 00 00 00 02 00 00 00
    0C 00 00 00 02 00 00 00 07 00 00 00
    09 00 00 00 03 00 00 00 01
    0A 00 00 00 06 00 00 00 01 00
    """)
let webcamBindResponse = hex("""
    33 00 80 00 04 00 04 00
    0C 00 00 00 00 00 00 00 04 00 00 00
    0C 00 00 00 01 00 00 00 01 00 00 00
    09 00 00 00 03 00 00 00 00
    0A 00 00 00 06 00 00 00 01 00
    """)
/// docs/98b §5.1: CREATE_CONTEXT 1/1 with a TYPE (H.264, no format block) and an empty DEVICE, 112 bytes.
let webcamCreateContext = hex("""
    70 00 02 00 01 00 00 00 01 00 00 00 00 00 00 00
    10 00 02 00
    48 00 00 00 01 00 00 00
    76 69 64 73 00 00 10 00 80 00 00 AA 00 38 9B 71
    48 32 36 34 00 00 10 00 80 00 00 AA 00 38 9B 71
    80 9F 58 05 56 C3 CE 11 BF 01 00 AA 00 55 59 5A
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    14 00 00 00 03 00 00 00
    0C 00 00 00 00 00 00 00 00 00 00 00
    """)
/// docs/98b §5.3: the 208-byte 0x86 success for 1/1.
let webcamCaptureSuccess = hex("""
    D0 00 86 00 01 00 00 00 01 00 00 00 00 00 00 00
    00 A4 04 00 18 00 02 00 18 00 00 00 00 00 00 00
    08 00 00 00 00 A4 04 00 01 00 00 00 00 00 00 00
    A0 00 00 00 01 00 00 00 76 69 64 73 00 00 10 00
    80 00 00 AA 00 38 9B 71 48 32 36 34 00 00 10 00
    80 00 00 AA 00 38 9B 71 80 9F 58 05 56 C3 CE 11
    BF 01 00 AA 00 55 59 5A 58 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 71 02 00 00 00 00 00
    00 00 00 00 00 00 00 00 28 00 00 00 60 01 00 00
    20 01 00 00 01 00 0C 00 30 32 34 49 00 52 02 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """)
/// docs/98b §6: CONTROL PLAY for 1/1 (24 bytes).
let webcamPlay = hex("18 00 06 00 01 00 00 00 01 00 00 00 0C 00 01 00 08 00 00 00 00 00 00 00")

/// A CONTROL message with one control of `type`.
func webcamControl(_ type: UInt32, major: UInt32 = 1, minor: UInt32 = 1) -> [UInt8] {
    var w = ByteWriter()
    w.u16(24); w.u8(6); w.u8(0); w.u32(major); w.u32(minor); w.u16(12); w.u8(1); w.u8(0); w.u32(8); w.u32(type)
    return [UInt8](w.data)
}

/// A CREATE_CONTEXT with the given handles and, optionally, a DEVICE property with a UTF-16 path.
func webcamCreate(major: UInt32 = 1, minor: UInt32 = 1, devicePath: String? = "", type: Bool = true) -> [UInt8] {
    var props: [[UInt8]] = []
    if type {
        props.append(WebcamElement(type: 1, WebcamWire.GUID.mediaTypeVideo + WebcamWire.GUID.subtypeH264 + WebcamWire.GUID.formatVideoInfo
            + [UInt8](repeating: 0, count: 16)).encoded)
    }
    if let devicePath {
        let path = devicePath.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        var w = ByteWriter()
        w.u16(12); w.u16(0); w.u32(0); w.u32(UInt32(path.count)); w.raw(path)
        props.append(WebcamElement(type: 3, payload: w.data).encoded)
    }
    let list = props.flatMap { $0 }
    var w = ByteWriter()
    w.u16(UInt16(20 + list.count)); w.u8(2); w.u8(0); w.u32(major); w.u32(minor); w.u32(0); w.u16(16); w.u8(UInt8(props.count)); w.u8(0)
    w.raw(list)
    return [UInt8](w.data)
}

// MARK: - Module (§1.3)

@Suite struct WebcamModuleTests {
    /// 2026-11-06 12:00:00 local time, the date of the worked example.
    static let exampleDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!

    @Test func moduleGolden50BytesAsTheSpecExample() {
        let m = WDModules.webcam(date: Self.exampleDate)
        // §1.3, the one-line form with xx = 00.
        let expected = hex("32 00 00 03 03 00") + zeros(13) + hex("49 43 41") + zeros(6)
            + hex("66 5D 00 60 00 00 00 00 12 00 00 00 00 00 00 00 00 00 00 00 84 13")
        #expect(expected.count == 50)
        #expect(m.count == 50)
        let packet = WDModules.initResponsePackets([m])[0]
        #expect(Array(packet.prefix(3)) == hex("01 32 00"))
        #expect(Array(packet.dropFirst(3)) == expected)
        // Versions 3 then 0, flow type 0, VD data a u16 (not 52 bytes).
        #expect(m[4] == 3 && m[5] == 0 && m[41] == 0 && Array(m[48...49]) == hex("84 13"))
        // The W6 variant differs only in byte 5.
        var variant = WebcamEngine.Config()
        variant.moduleVersionHigh = 3
        let v = WebcamEngine(config: variant).module(channel: 18, date: Self.exampleDate)
        #expect(v[5] == 3 && Array(v[..<5]) == Array(m[..<5]) && Array(v[6...]) == Array(m[6...]))
    }

    @Test func engineProvidesWholeModuleAfterClipboardBeforePrinterWithBindEntry() throws {
        let wd = WinstationDriver(configuration: {
            var c = WinstationDriver.Configuration()
            c.logon.initialProgram = "#Notepad Demo"
            return c
        }())
        wd.register(ThinwireEngine())
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        let engine = WebcamEngine()
        var events: [String] = []
        engine.onEvent = { events.append("\($0)") }
        #expect(wd.register(engine) == 18)
        wd.register(PrinterEngine(config: PrinterEngine.Config()))
        let (modules, names) = try wd.buildModules()
        let index = try #require(names.firstIndex(of: "CTXMM  "))
        #expect(index > names.firstIndex(of: "CTXCLIP")! && index < names.firstIndex(of: "CTXCPM ")!)
        // Not the generic 48-byte VD with versions 1/1 (§1.3 traps).
        #expect(modules[index].count == 50)
        #expect(modules[index][4] == 3 && modules[index][5] == 0 && Array(modules[index][48...49]) == hex("84 13"))
        #expect(engine.diagnostics.moduleBytes == modules[index])
        #expect(events.first?.hasPrefix("module 50 B: ") == true)
        let bind = hex("43 54 58 4D 4D 20 20 00 12 00")
        #expect(modules[0].indices.contains { i in i + bind.count <= modules[0].count && Array(modules[0][i..<i + bind.count]) == bind })
    }

    @Test func settingDefaultsOffAndAnnouncesNothing() {
        let defaults = UserDefaults(suiteName: "webcam-test-\(UUID().uuidString)")!
        #expect(!WebcamSettings.defaultEnabled)
        #expect(WebcamSettings.load(defaults: defaults, env: [:]).engineConfig == nil)
        #expect(WebcamSettings.load(defaults: defaults, env: ["ICA_WEBCAM": "1"]).engineConfig != nil)
        var on = WebcamSettings()
        on.enabled = true
        on.save(to: defaults)
        #expect(WebcamSettings.load(defaults: defaults, env: [:]).enabled)
        #expect(WebcamSettings.load(defaults: defaults, env: ["ICA_WEBCAM": "off"]).engineConfig == nil)
        #expect(WebcamSettings.load(defaults: defaults, env: ["ICA_WEBCAM_SOURCE": "synthetic"]).source == .synthetic)
        #expect(WebcamSettings.load(defaults: defaults, env: [:]).source == .camera)
        // The camera choice: stored by unique id with its name; automatic (nil) removes both.
        #expect(WebcamSettings.load(defaults: defaults, env: [:]).deviceID == nil)
        on.deviceID = "0x1420000005ac8600"
        on.deviceName = "FaceTime HD Camera"
        on.save(to: defaults)
        let chosen = WebcamSettings.load(defaults: defaults, env: [:])
        #expect(chosen.deviceID == "0x1420000005ac8600" && chosen.deviceName == "FaceTime HD Camera")
        on.deviceID = nil
        on.save(to: defaults)
        let automatic = WebcamSettings.load(defaults: defaults, env: [:])
        #expect(automatic.deviceID == nil && automatic.deviceName == nil && automatic.enabled)
    }

    @Test func sessionWithoutWebcamConfigHasNoCTXMM() throws {
        let text = "[ApplicationServers]\nX=\n[X]\nSSLProxyHost=gw.example:443\nAddress=ticket\nCGPSecurityTicket=On\nTWIMode=On\nInitialProgram=#Test\n"
        let ica = try #require(ICAFile(text: text))
        var config = WinstationDriver.Configuration()
        config.logon = WDLogon(ica: ica)
        let plain = try ICASession(ica: ica, configuration: config)
        #expect(plain.webcam == nil && plain.wd.channelNumber(WebcamWire.channelName) == nil)
        let with = try ICASession(ica: ica, configuration: config, webcam: WebcamEngine.Config())
        #expect(with.webcam != nil && with.wd.channelNumber(WebcamWire.channelName) == 18)
    }
}

// MARK: - Messages (§2–§7)

@Suite struct WebcamMessageTests {
    @Test func bindExampleRequestToResponseByteExact() throws {
        guard case .bindRequest(let caps) = WebcamMessage.parse(Data(webcamBindRequest)) else { Issue.record("not BIND_REQUEST"); return }
        #expect(caps.map(\.type) == [0, 1, 2, 3, 6])
        // Type 3 (length 9) puts type 6 at an odd offset (body offset 4 + 36 + 9 = 49).
        #expect(caps[3].payload == Data([1]) && caps[4].payload == Data([1, 0]))
        let answers = WebcamMessage.bindAnswers(caps)
        #expect(answers.map(\.type) == [0, 1, 3, 6])
        let reply = WebcamMessage.bindResponse(answers: answers)
        #expect(reply == webcamBindResponse)
        #expect(reply.count == 51 && reply[41] == 0x0A)  // the type 6 element starts at the odd offset 41
    }

    @Test func bindAnswersAllTypes() {
        let host: [WebcamElement] = [
            .init(type: 7, [1]), .init(type: 0, hex("09 00 00 00")), .init(type: 5, [1]), .init(type: 99, [1, 2]),
            .init(type: 4, [1]), .init(type: 1, hex("05 00 00 00")), .init(type: 6, [3, 0]), .init(type: 2, hex("07 00 00 00")),
        ]
        let answers = WebcamMessage.bindAnswers(host)
        #expect(answers == [.init(type: 7, [0]), .init(type: 0, hex("09 00 00 00")), .init(type: 5, [0]), .init(type: 4, [0]),
                            .init(type: 1, hex("01 00 00 00")), .init(type: 6, [3, 0])])
        #expect(answers.map(\.encoded.count) == [9, 12, 9, 9, 12, 10])
    }

    @Test func listOffsetLargerThanTheFixedPartSkipsTheExcess() {
        // BIND_REQUEST with list offset 6: two junk bytes, then one type 1 element.
        let m = hex("12 00 00 00 06 00 01 00 EE EE 0C 00 00 00 01 00 00 00 02 00 00 00")
        var fixed = m
        fixed[0] = UInt8(m.count)
        guard case .bindRequest(let caps) = WebcamMessage.parse(Data(fixed)) else { Issue.record("not parsed"); return }
        #expect(caps == [.init(type: 1, hex("02 00 00 00"))])
    }

    @Test func bindCommitParses() {
        var commit = webcamBindRequest
        commit[2] = 1
        guard case .bindCommit(let caps) = WebcamMessage.parse(Data(commit)) else { Issue.record("not BIND_COMMIT"); return }
        #expect(caps.count == 5)
    }

    @Test func createContextExampleParses() throws {
        #expect(webcamCreateContext.count == 112)
        guard case .createContext(let r) = WebcamMessage.parse(Data(webcamCreateContext)) else { Issue.record("not CREATE_CONTEXT"); return }
        #expect(r.major == 1 && r.minor == 1 && r.properties.map(\.type) == [1, 3])
        #expect(r.mediaTypes.count == 1 && r.mediaTypes[0].subtype == WebcamWire.GUID.subtypeH264)
        #expect(r.mediaTypes[0].formatSize == 0 && r.mediaTypes[0].formatBlock.isEmpty)
        #expect(r.encoderBits == WebcamWire.EncoderBits.h264)
        #expect(r.device == WebcamDeviceProperty(path: "") && r.isDeviceContext)
        #expect(WebcamMediaType.guidString(WebcamWire.GUID.subtypeH264) == "34363248-0000-0010-8000-00AA00389B71")
    }

    @Test func deviceUTF16PathSplitsNameAndID() throws {
        let path = "Citrix HDX Web Camera@device:pnp:\\\\?\\x"
        let m = webcamCreate(devicePath: path + "\0\0")
        guard case .createContext(let r) = WebcamMessage.parse(Data(m)) else { Issue.record("not CREATE_CONTEXT"); return }
        let device = try #require(r.device)
        #expect(device.path == path)
        #expect(device.friendlyName == "Citrix HDX Web Camera")
        #expect(device.deviceID == "\\\\?\\x")
        #expect(WebcamDeviceProperty(path: "Some Camera").deviceID == nil)
        // A longer sub-header is skipped by its excess.
        var w = ByteWriter()
        w.u16(16); w.u16(0); w.u32(0); w.u32(4); w.raw([0xAA, 0xBB, 0xCC, 0xDD]); w.raw(hex("41 00 42 00"))
        let element = WebcamElement(type: 3, payload: w.data).encoded
        var c = ByteWriter()
        c.u16(UInt16(20 + element.count)); c.u8(2); c.u8(0); c.u32(1); c.u32(2); c.u32(0); c.u16(16); c.u8(1); c.u8(0); c.raw(element)
        guard case .createContext(let r2) = WebcamMessage.parse(c.data) else { Issue.record("not parsed"); return }
        #expect(r2.device?.path == "AB")
    }

    @Test func captureContextSuccessIsThe208ByteExample() {
        let m = WebcamMessage.captureContextSuccess(major: 1, minor: 1)
        #expect(m.count == 208)
        #expect(m == webcamCaptureSuccess)
        #expect(Array(m[152..<156]) == hex("00 71 02 00") && Array(m[172..<176]) == hex("60 01 00 00"))
        #expect(Array(m[184..<188]) == hex("30 32 34 49"))
        #expect(WebcamMessage.formatBlock(.standard).count == 88)
    }

    @Test func rejectsAndErrorsAreTheSpecBytes() {
        #expect(WebcamMessage.contextReject(major: 1, minor: 0, status: WebcamWire.Status.failed)
                == hex("14 00 81 00 01 00 00 00 00 00 00 00 05 40 00 80 00 00 00 00"))
        #expect(WebcamMessage.captureContextError(major: 1, minor: 1)
                == hex("18 00 86 00 01 00 00 00 01 00 00 00 01 00 04 00 00 00 00 00 18 00 00 00"))
    }

    @Test func playStopDestroyParse() {
        #expect(WebcamMessage.parse(Data(webcamPlay)) == .control(major: 1, minor: 1, controls: [0]))
        #expect(WebcamMessage.parse(Data(webcamControl(2, major: 7, minor: 9))) == .control(major: 7, minor: 9, controls: [2]))
        #expect(WebcamMessage.parse(Data(hex("0C 00 04 00 01 00 00 00 02 00 00 00"))) == .destroyContext(major: 1, minor: 2))
        #expect(WebcamMessage.parse(Data(hex("06 00 03 00 AA BB"))) == .updateContext(length: 6))
        #expect(WebcamMessage.parse(Data(hex("05 00 05 00 AA"))) == .transmit(length: 5))
        #expect(WebcamMessage.parse(Data(hex("04 00 42 00"))) == .unknown(command: 0x42, length: 4))
        // A field read past L is malformed (skipped by L), not a crash.
        if case .malformed = WebcamMessage.parse(Data(hex("08 00 04 00 01 00 00 00"))) {} else { Issue.record("expected malformed") }
        // An element longer than the message.
        if case .malformed = WebcamMessage.parse(Data(hex("10 00 00 00 04 00 01 00 FF 00 00 00 01 00 00 00"))) {} else { Issue.record("expected malformed") }
    }

    @Test func transmitWorkedExample() {
        let sample = Data(hex("00 00 00 01 67 42 C0 1E AB CD"))
        let f = WebcamMessage.transmit(major: 1, minor: 1, sample: sample)
        let expected = hex("""
            42 00 85 00 01 00 00 00 01 00 00 00 0C 00 01 00
            32 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 0A 00 00 00 00 00 00 01 67 42 C0 1E
            AB CD
            """)
        #expect(f == [expected])
    }

    @Test(arguments: [3999, 4000, 4001, 9000])
    func transmitFragmentation(size: Int) {
        let sample = Data((0..<size).map { UInt8($0 & 0xff) })
        let f = WebcamMessage.transmit(major: 5, minor: 6, sample: sample)
        let n = (size + 3999) / 4000
        #expect(f.count == n)
        for (i, m) in f.enumerated() {
            let length = Int(m[0]) | Int(m[1]) << 8
            #expect(length == m.count && m[2] == 0x85)
            #expect(m[3] == (i < n - 1 ? 1 : 0))
            #expect(m.count <= 4056)
        }
        let first = f[0]
        let elementLength = UInt32(first[16]) | UInt32(first[17]) << 8 | UInt32(first[18]) << 16 | UInt32(first[19]) << 24
        let sampleLength = UInt32(first[52]) | UInt32(first[53]) << 8 | UInt32(first[54]) << 16 | UInt32(first[55]) << 24
        #expect(elementLength == UInt32(8 + 32 + size) && sampleLength == UInt32(size))
        #expect(Array(first[4..<12]) == hex("05 00 00 00 06 00 00 00") && Array(first[12..<16]) == hex("0C 00 01 00"))
        #expect(first[20..<52].allSatisfy { $0 == 0 })
        // Reassembled data is the sample.
        let data = Array(first[56...]) + f.dropFirst().flatMap { $0[4...] }
        #expect(data == [UInt8](sample))
        if size == 9000 { #expect(f.map(\.count) == [4056, 4004, 1004] && elementLength == 9040) }
        if size == 4000 { #expect(f.map(\.count) == [4056]) }
    }
}

// MARK: - Framing (§2)

@Suite struct WebcamFramingTests {
    @Test func splitAcrossWritesAndMergedInOne() {
        var p = WebcamStreamParser()
        #expect(p.feed(Data(webcamBindRequest[0..<3])).isEmpty)
        #expect(p.feed(Data(webcamBindRequest[3..<40])).isEmpty)
        let one = p.feed(Data(webcamBindRequest[40...]))
        #expect(one == [Data(webcamBindRequest)] && p.buffered == 0)
        var commit = webcamBindRequest
        commit[2] = 1
        let both = p.feed(Data(webcamBindRequest + commit + webcamPlay.prefix(5)))
        #expect(both == [Data(webcamBindRequest), Data(commit)] && p.buffered == 5)
        #expect(p.feed(Data(webcamPlay.dropFirst(5))) == [Data(webcamPlay)])
    }

    @Test func lengthBelowFourDropsTheBuffer() {
        var p = WebcamStreamParser()
        var errors: [String] = []
        let out = p.feed(Data(hex("02 00 00 00 AA BB CC")) + Data(webcamPlay)) { errors.append($0) }
        #expect(out.isEmpty && p.buffered == 0 && errors.count == 1 && p.protocolErrors == 1)
        #expect(p.feed(Data(webcamPlay)) == [Data(webcamPlay)])
    }
}

// MARK: - Annex B (§7.1, §10.3)

@Suite struct WebcamAnnexBTests {
    let sps = Data(hex("67 42 C0 1E 95 A0"))
    let pps = Data(hex("68 CE 3C 80"))

    @Test func syncSampleGetsParameterSetsAndStartCodes() throws {
        let idr = hex("65 88 84 00 33"), sei = hex("06 05 01 AA")
        let avcc = Data(hex("00 00 00 04") + sei + hex("00 00 00 05") + idr)
        let out = try #require(AnnexB.fromAVCC(avcc, lengthSize: 4, sync: true, parameterSets: [sps, pps]))
        #expect([UInt8](out) == hex("00 00 00 01") + [UInt8](sps) + hex("00 00 00 01") + [UInt8](pps) + hex("00 00 00 01") + sei
                + hex("00 00 00 01") + idr)
        #expect(AnnexB.units(out).compactMap(AnnexB.nalType) == [7, 8, 6, 5])
    }

    @Test func nonSyncHasNoParameterSetsAndShortLengths() throws {
        let p = hex("41 9A 02"), q = hex("41 9A 03 04")
        let out = try #require(AnnexB.fromAVCC(Data(hex("00 03") + p + hex("00 04") + q), lengthSize: 2, sync: false, parameterSets: [sps, pps]))
        #expect([UInt8](out) == hex("00 00 00 01") + p + hex("00 00 00 01") + q)
    }

    @Test func spsAlreadyInTheSampleIsNotDuplicated() throws {
        let avcc = Data(hex("00 00 00 06") + [UInt8](sps) + hex("00 00 00 02 65 88"))
        let out = try #require(AnnexB.fromAVCC(avcc, lengthSize: 4, sync: true, parameterSets: [sps, pps]))
        #expect(AnnexB.units(out).compactMap(AnnexB.nalType) == [7, 5])
    }

    @Test func malformedAVCCIsRejected() {
        #expect(AnnexB.fromAVCC(Data(hex("00 00 00 09 65 88")), lengthSize: 4, sync: false, parameterSets: []) == nil)
        #expect(AnnexB.fromAVCC(Data(hex("00 00 00 00")), lengthSize: 4, sync: false, parameterSets: []) == nil)
        #expect(AnnexB.fromAVCC(Data(), lengthSize: 4, sync: false, parameterSets: []) == nil)
        #expect(AnnexB.fromAVCC(Data(hex("01 65")), lengthSize: 3, sync: false, parameterSets: []) == nil)
    }
}
