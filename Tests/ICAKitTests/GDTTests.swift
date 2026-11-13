import Testing
import Foundation
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { UInt8($0, radix: 16)! } }
private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    haystack.indices.contains { i in i + needle.count <= haystack.count && Array(haystack[i..<i + needle.count]) == needle }
}

@Suite struct GDTModuleTests {
    static let exampleDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!

    @Test func module48BytesVersion1HostICAChannel29() {
        let m = GDTEngine().module(channel: GDTWire.channelNumber, date: Self.exampleDate)
        let expected = hex("30 00 00 03 01 01") + zeros(13) + hex("49 43 41") + zeros(6)
            + hex("66 5D 00 60 00 00 00 00 1D 00 00 00 00 00 00 00 00 00 00 00")
        #expect(m.count == 48)
        let packet = WDModules.initResponsePackets([m])[0]
        #expect(Array(packet.prefix(3)) == hex("01 30 00"))
        #expect(Array(packet.dropFirst(3)) == expected)
        // The same bytes as the generic VD the WD would build without the engine's module.
        #expect(m == WDModules.vdHeader(WDModuleIdentity(moduleClass: .vd, versionLow: 1, versionHigh: 1, name: "", hostName: "ICA"),
                                        channel: 29, date: Self.exampleDate).bytes())
    }

    @Test func versionFromEnvironment() throws {
        #expect(GDTEngine.Config.fromEnvironment([:]) == nil)
        #expect(GDTEngine.Config.fromEnvironment(["ICA_GDT": "0"]) == nil)
        let c = try #require(GDTEngine.Config.fromEnvironment(["ICA_GDT": "1", "ICA_GDT_VERSION": "2"]))
        #expect(c.versionLow == 2 && c.versionHigh == 2 && c.initReply == nil)
        let m = GDTEngine(config: c).module(channel: 29, date: Self.exampleDate)
        #expect(m[4] == 2 && m[5] == 2)
    }

    static func driver() -> WinstationDriver {
        WinstationDriver(configuration: {
            var c = WinstationDriver.Configuration()
            c.logon.initialProgram = "#Explorer Citrix ABC"
            return c
        }())
    }

    @Test func registeredLastOnChannel29WithBindEntry() throws {
        let wd = Self.driver()
        wd.register(ThinwireEngine())
        wd.register(SeamlessEngine(config: SeamlessEngine.Config()))
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        wd.register(AudioEngine(config: AudioEngine.Config()))
        #expect(wd.register(ControlEngine()) == 20)
        let engine = GDTEngine()
        #expect(wd.register(engine, number: GDTWire.channelNumber) == 29)
        #expect(wd.channelNumber(GDTWire.channelName) == 29)
        let (modules, names) = try wd.buildModules()
        #expect(names.suffix(2) == ["CTXGDT", "UI"])
        let index = try #require(names.firstIndex(of: "CTXGDT"))
        #expect(modules[index].count == 48)
        #expect(Array(modules[index][36...39]) == hex("1D 00 00 00"))
        #expect(engine.moduleBytes == modules[index])
        // `CTXGDT` + NUL in 7 bytes, NUL, u16 29.
        #expect(contains(modules[0], hex("43 54 58 47 44 54 00 00 1D 00")))
    }

    @Test func absentByDefault() throws {
        let wd = Self.driver()
        wd.register(ThinwireEngine())
        wd.register(SeamlessEngine(config: SeamlessEngine.Config()))
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        let (modules, names) = try wd.buildModules()
        #expect(!names.contains("CTXGDT"))
        #expect(!contains(modules[0], Array("CTXGDT".utf8)))
    }

    @Test func requestedNumberFallsBackWhenTakenOrFixed() {
        let wd = Self.driver()
        #expect(wd.register(RecordingEngine("CTXAAA "), number: 29) == 29)
        #expect(wd.register(GDTEngine(), number: 29) == 20)
        #expect(wd.register(RecordingEngine("CTXBBB "), number: 17) == 21)   // 17 is CTXCLIP's
    }
}

@Suite struct GDTRoutingTests {
    /// The handshake of `handshakeAndFramedTraffic` (WDTests), with CTXGDT registered on 29.
    @Test func hostWriteOnChannel29ReachesEngineAndInitReplyGoesBack() throws {
        var config = WinstationDriver.Configuration()
        config.logon.initialProgram = "#Explorer Citrix ABC"
        let wd = WinstationDriver(configuration: config, encryptionKey: 0x42, obfuscationSeed: 0x11)
        wd.register(RecordingEngine("CTXTW  "))
        wd.register(RecordingEngine("CTXTWI\0"))
        var gdtConfig = GDTEngine.Config()
        gdtConfig.initReply = .incrementByte(offset: 0)
        let gdt = GDTEngine(config: gdtConfig)
        #expect(wd.register(gdt, number: 29) == 29)
        var events: [GDTEngine.Event] = []
        gdt.onEvent = { events.append($0) }
        var sent: [[UInt8]] = []
        wd.transmit = { sent.append($0) }
        // As ICASession does: the WD packet type goes to the engine before its payload.
        wd.onEvent = { event in
            if case .packet(let p) = event, p.channel == 29 { gdt.noteWDPacketType(p.type) }
        }

        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        var pd = [UInt8](repeating: 0, count: 12)
        pd[2] = 1; pd[3] = 4; pd[8] = 0x0B
        var wdConnect = [UInt8](repeating: 0, count: 40)
        wdConnect[3] = 2
        wdConnect[32] = 4; wdConnect[34] = 36
        wdConnect[38] = 4
        // The encryption PD's init request (framed 0x02) follows in the same chunk; we answer 04 00 <key>.
        wd.receive(Data([0x02, 12, 0] + pd + [0x02, 40, 0] + wdConnect + WDFraming.frame([0x02])))
        #expect(wd.phase == .connected)
        #expect(sent.last == WDFraming.frame([0x04, 0x00, 0x42]))

        var server = WDBasicCipher(key: 0x42)
        sent = []
        var vc: [UInt8] = [0x30, 0x05, 0x1D, 0x00, 0x01, 0x04, 0x00]
        server.encrypt(&vc)
        wd.receive(Data(WDFraming.frame([0x01] + vc)))
        #expect(gdt.history == [GDTHostWrite(index: 1, elapsed: gdt.history.first?.elapsed ?? 0, wdType: 0x30, bytes: [0x00, 0x01, 0x04, 0x00])])
        #expect(gdt.statistics.packets == 1)

        // The init reply (command byte + 1) goes out on channel 29.
        #expect(sent.count == 1 && sent.first?[2] == 0x01)
        var out = Array(sent[0].dropFirst(3))
        server.decrypt(&out)
        #expect(out == [0x30, 0x05, 0x1D, 0x01, 0x01, 0x04, 0x00])
        #expect(gdt.sentCount == 1)

        // A second host write: logged, no reply (the init reply answers #1 only; no other responder).
        sent = []
        var second: [UInt8] = [0x30, 0x03, 0x1D, 0x07, 0x08]
        server.encrypt(&second)
        wd.receive(Data(WDFraming.frame([0x01] + second)))
        #expect(gdt.history.count == 2 && gdt.history[1].bytes == [0x07, 0x08])
        #expect(sent.isEmpty)
        let kinds = events.map { event -> String in
            switch event {
            case .module: return "module"
            case .hostWrite(let w): return "host#\(w.index)"
            case .sent(let w, _): return "sent#\(w.index)"
            case .log: return "log"
            }
        }
        #expect(kinds == ["module", "host#1", "sent#1", "host#2"])
    }

    @Test func silentByDefaultAndRespondersInOrder() {
        let engine = GDTEngine()
        var out: [Data] = []
        engine.output = { if case .channel(let d) = $0 { out.append(d) } }
        engine.receive(Data([0x00, 0x01]))
        #expect(out.isEmpty)
        engine.responders.append(GDTEngine.Responder(name: "never") { _, _ in nil })
        engine.responders.append(GDTEngine.Responder(name: "ack") { write, history in [0xAA, UInt8(write.index), UInt8(history.count)] })
        engine.responders.append(GDTEngine.Responder(name: "shadowed") { _, _ in [0xBB] })
        engine.receive(Data([0x05]))
        #expect(out == [Data([0xAA, 2, 2])])
    }

    @Test func initReplyModesFromEnvironment() {
        #expect(GDTEngine.InitReply(environment: nil) == nil)
        #expect(GDTEngine.InitReply(environment: "0") == nil)
        #expect(GDTEngine.InitReply(environment: "1") == .echo)
        #expect(GDTEngine.InitReply(environment: "inc") == .incrementByte(offset: 0))
        #expect(GDTEngine.InitReply(environment: "inc@2") == .incrementByte(offset: 2))
        #expect(GDTEngine.InitReply(environment: "hex:01 00 2c00") == .literal([0x01, 0x00, 0x2C, 0x00]))
        #expect(GDTEngine.InitReply(environment: "hex:0") == nil)
        #expect(GDTEngine.InitReply(environment: "yes") == nil)
        #expect(GDTEngine.InitReply.incrementByte(offset: 2).reply(to: [1, 2, 0xFF]) == [1, 2, 0])
        #expect(GDTEngine.InitReply.echo.reply(to: [9]) == [9])
    }

    @Test func initReplyOnlyForASmallFirstWrite() {
        var c = GDTEngine.Config()
        c.initReply = .echo
        c.initMaxSize = 4
        let engine = GDTEngine(config: c)
        var out: [Data] = []
        engine.output = { if case .channel(let d) = $0 { out.append(d) } }
        engine.receive(Data(zeros(5)))   // too big for an init
        engine.receive(Data([1, 2]))     // not the first write
        #expect(out.isEmpty)
    }
}

@Suite struct GDTHexLogTests {
    @Test func lineHasHeaderWordsTotalAndCappedHex() {
        let payload: [UInt8] = [0x01, 0x00, 0x2C, 0x00, 0x78, 0x56, 0x34, 0x12] + (0..<300).map { UInt8($0 & 0xFF) }
        let w = GDTHostWrite(index: 3, elapsed: 1.25, wdType: 0x31, bytes: payload)
        let line = GDTHexLog.line(w)
        #expect(line.hasPrefix("← GDT #3 +1.250s wd 0x31 total 308 B | u16 [0001 002c 5678 1234 0100 0302 0504 0706] " +
                               "u32 [0x002c0001 0x12345678 0x03020100 0x07060504] | 01 00 2c 00 78 56 34 12 00 01"))
        #expect(line.contains(" …"))
        // 256 bytes shown: 256 hex pairs in the payload part.
        let hexPart = line.components(separatedBy: " | ")[2]
        #expect(hexPart.split(separator: " ").count == 256 + 1)   // + the ellipsis
        #expect(GDTHexLog.line(GDTHostWrite(index: 1, elapsed: 0, wdType: nil, bytes: [])) == "← GDT #1 +0.000s total 0 B")
    }

    @Test func dumpRowsAndRemainder() {
        let w = GDTHostWrite(index: 1, elapsed: 0, wdType: nil, bytes: Array("ABCDEFGHIJKLMNOPQR".utf8))
        let lines = GDTHexLog.dump(w, limit: 17)
        #expect(lines.count == 4)
        #expect(lines[1] == "    0000  41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50  |ABCDEFGHIJKLMNOP|")
        #expect(lines[2].hasPrefix("    0010  51") && lines[2].hasSuffix("|Q|"))
        #expect(lines[3] == "    … 1 more bytes not shown")
    }

    @Test func stringsFindASCIIAndUTF16() {
        let utf16 = Array("FileContents".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let bytes: [UInt8] = [0x09] + utf16 + [0x00, 0x00, 0xFF] + Array("a.txt".utf8) + [0x00, 0x41, 0x42]
        let found = GDTHexLog.strings(bytes)
        #expect(found.contains("w@1 \"FileContents\""))
        #expect(found.contains("a@28 \"a.txt\""))
        #expect(!found.contains { $0.contains("AB") })
    }

    @Test func statisticsSummary() {
        var s = GDTStatistics()
        #expect(s.summary == "0 host GDT packets")
        s.add([0x01, 0x00, 0x10])
        s.add([0x01, 0x00])
        s.add([0x05])
        s.add([])
        #expect(s.packets == 4 && s.bytes == 6 && s.minSize == 0 && s.maxSize == 3)
        #expect(s.summary == "4 host GDT packets, 6 B, sizes 0…3 [3 2 1 0], leading bytes {01×2 05×1}, leading u16 {0001×2}")
    }

    @Test func logFileIsPrivateAndTimestamped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdt-test-\(UUID().uuidString)/gdt")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let log = try GDTLogFile(directory: dir, runID: "run1")
        log.write(["first", "second"])
        log.write("third")
        let text = try String(contentsOf: log.url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix(" first") && lines[1].hasSuffix(" second") && lines[1].trimmingCharacters(in: .whitespaces) == "second")
        #expect(lines[2].hasSuffix(" third"))
        let fileMode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600 && dirMode == 0o700)
        #expect(log.url.lastPathComponent == "run1.log")
    }

    @Test func parseHex() {
        #expect(GDTEngine.parseHex("01 00 2c 00") == [1, 0, 0x2C, 0])
        #expect(GDTEngine.parseHex("0x01,0x02") == [1, 2])
        #expect(GDTEngine.parseHex("abc") == nil)
        #expect(GDTEngine.parseHex("zz") == nil)
    }
}

/// docs/76 §7.1 discovery variants (V1 VD data, V2 HT, V3 versions, V5 CLIP_INIT_REPLY).
@Suite struct GDTVariantTests {
    @Test func vdDataAndVersionRangeFromEnvironment() throws {
        let c = try #require(GDTEngine.Config.fromEnvironment(["ICA_GDT": "1", "ICA_GDT_VDDATA": "8713", "ICA_GDT_VERSION": "0-1"]))
        #expect(c.vdData == [0x87, 0x13] && c.versionLow == 0 && c.versionHigh == 1)
        let m = GDTEngine(config: c).module(channel: 29, date: GDTModuleTests.exampleDate)
        #expect(m.count == 50)
        #expect(m[4] == 0 && m[5] == 1)
        #expect(Array(m[36...39]) == hex("1D 00 00 00") && Array(m[48...49]) == hex("87 13"))
        let r = try #require(GDTEngine.Config.fromEnvironment(["ICA_GDT": "1", "ICA_GDT_VERSION": "1-2"]))
        #expect(r.versionLow == 1 && r.versionHigh == 2 && r.vdData.isEmpty)
    }

    @Test func clipInitReplyVariants() {
        #expect([UInt8](ClipboardWire.initReply(version: 4)) == hex("02 00 00 00 04 00 00 00 00 00 00 00"))
        #expect([UInt8](ClipboardWire.initReply(version: 4, word2: 1)) == hex("02 00 01 00 04 00 00 00 00 00 00 00"))
        #expect([UInt8](ClipboardWire.initReply(version: 4, tail: [1, 0, 0, 0, 0, 0])) == hex("02 00 00 00 04 00 01 00 00 00 00 00"))
    }

    @Test func clipEngineSendsConfiguredInitReply() {
        var c = ClipboardEngine.Config()
        c.maxVersion = 4
        c.initReplyWord2 = 1
        let engine = ClipboardEngine(config: c)
        var out: [UInt8] = []
        engine.output = { if case .channel(let d) = $0 { out += d } }
        engine.receive(Data(hex("01 00 01 00 04 00")))
        #expect(Array(out.prefix(12)) == hex("02 00 01 00 04 00 00 00 00 00 00 00"))
    }

    @Test func highThroughputNegotiatedOnlyWhenEnabled() throws {
        // Packet `00 06 02`, then the payload: WD level 7 and the capability block (docs/30 "Live findings").
        let server = try WDInitRequest(payload: Array(bytes(hex: liveInitRequestHex).dropFirst(3))).capabilities
        #expect(server.contains { $0.id == WDCapability.highThroughput })
        #expect(!WDCapabilityPolicy().negotiate(server: server).contains { $0.id == WDCapability.highThroughput })
        var policy = WDCapabilityPolicy()
        policy.highThroughput = true
        let cap = try #require(policy.negotiate(server: server).first { $0.id == WDCapability.highThroughput })
        #expect(cap.body == hex("00 00 00 00 B4 05 00 00"))
    }

    @Test func htHeaderStrip() {
        #expect(WDHighThroughput.strip([0x00, 0x30])! == ([0x30], 0x00))
        #expect(WDHighThroughput.strip([0x18, 1, 2, 3, 4, 0x30])! == ([0x30], 0x18))
        #expect(WDHighThroughput.strip([0x10, 1]) == nil)
        #expect(WDHighThroughput.strip([]) == nil)
    }

    /// With cap 0x10 negotiated, host frames lose their HT header before parsing, flag 0x04 is answered with
    /// `3F 01 04`, and every client frame starts with HT flags 0 inside the encryption.
    @Test func highThroughputFramesBothWays() throws {
        var config = WinstationDriver.Configuration()
        config.logon.initialProgram = "#Explorer Citrix ABC"
        config.policy.highThroughput = true
        let wd = WinstationDriver(configuration: config, encryptionKey: 0x42, obfuscationSeed: 0x11)
        wd.register(RecordingEngine("CTXTW  "))
        wd.register(RecordingEngine("CTXTWI\0"))
        let gdt = GDTEngine()
        wd.register(gdt, number: 29)
        var sent: [[UInt8]] = []
        wd.transmit = { sent.append($0) }
        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        #expect(wd.negotiated.contains { $0.id == WDCapability.highThroughput })
        var pd = [UInt8](repeating: 0, count: 12)
        pd[2] = 1; pd[3] = 4; pd[8] = 0x0B
        var wdConnect = [UInt8](repeating: 0, count: 40)
        wdConnect[3] = 2
        wdConnect[32] = 4; wdConnect[34] = 36
        wdConnect[38] = 4
        wd.receive(Data([0x02, 12, 0] + pd + [0x02, 40, 0] + wdConnect + WDFraming.frame([0x02])))
        #expect(wd.phase == .connected && wd.highThroughput)

        var server = WDBasicCipher(key: 0x42)
        sent = []
        // HT flags 0x04 (answer) with a bandwidth field (0x10): 1 + 2 header bytes, then a VC write on 29.
        var frame: [UInt8] = [0x14, 0xAA, 0xBB, 0x30, 0x03, 0x1D, 0x07, 0x08]
        server.encrypt(&frame)
        wd.receive(Data(WDFraming.frame([0x01] + frame)))
        #expect(gdt.history.map(\.bytes) == [[0x07, 0x08]])
        #expect(sent.count == 1)
        var out = Array(sent[0].dropFirst(3))
        server.decrypt(&out)
        #expect(out == [0x00, 0x3F, 0x01, 0x04])
    }
}

/// docs/76 §7.2 V7: CTXCTL echoes listed host capability ids it otherwise skips.
@Suite struct ControlAcceptTests {
    // u16 offset 4, count 2, then cap 1 (len 8) and cap 9 (len 8, data 01 00 00 00) as in the sharetest request.
    static let request = hex("04 00 02 00  01 00 08 00 01 00 00 00  09 00 08 00 01 00 00 00")

    @Test func capability9SkippedByDefaultAndEchoedWhenAccepted() {
        let caps = ControlCapability.parseList(Self.request)
        #expect(caps.map(\.id) == [1, 9])
        let plain = ControlCapability.response(to: caps, hasLaunchData: false)
        #expect(plain.answered.map(\.id) == [1])
        let echoed = ControlCapability.response(to: caps, hasLaunchData: false, echo: [9])
        #expect(echoed.answered.map(\.id) == [1, 9])
        #expect(echoed.payload == hex("04 00 02 00  01 00 08 00 01 00 00 00  09 00 08 00 01 00 00 00"))
        // Cap 7 (webcam PnP): skipped unless listed, then echoed like any other (V13).
        let pnp = ControlCapability.parseList(hex("04 00 01 00  07 00 08 00 01 00 00 00"))
        #expect(ControlCapability.response(to: pnp, hasLaunchData: false).answered.isEmpty)
        #expect(ControlCapability.response(to: pnp, hasLaunchData: false, echo: [7]).answered.map(\.data) == [hex("01 00 00 00")])
    }

    @Test func engineUsesAcceptList() {
        var c = ControlEngine.Config()
        c.acceptCapabilities = [9]
        let engine = ControlEngine(config: c)
        var out: [UInt8] = []
        engine.output = { if case .channel(let d) = $0 { out += d } }
        engine.receive(Data(ControlWire.message(ControlWire.Command.capabilityRequest, Self.request)))
        #expect(engine.diagnostics.answeredCapabilities.map(\.id) == [1, 9])
        #expect(out == ControlWire.message(ControlWire.Command.capabilityResponse, Self.request))
    }
}

/// docs/76 §7.4: stock-client channel set (V12), stubs (V11), channel overrides.
@Suite struct StockChannelTests {
    @Test func catalogIsConsistent() {
        let all = StockChannels.all
        #expect(all.count == 27)
        #expect(Set(all.map(\.channel)).count == all.count)
        #expect(all.allSatisfy { $0.name.utf8.count == 7 && $0.channel < 0x3A })
        #expect(all.first { $0.name == "CTXGDT\0" }?.channel == 29)
        #expect(StockChannels.stubs().count == 27 - StockChannels.engineBacked.count)
        #expect(StockChannels.engineBacked.isSubset(of: Set(all.map(\.name))))
    }

    @Test func stubModuleAndParse() throws {
        let stub = try #require(StubChannelEngine.parse("CTXFILE:1-2"))
        #expect(stub.channelName == "CTXFILE" && stub.versionLow == 1 && stub.versionHigh == 2)
        let m = stub.module(channel: 31, date: GDTModuleTests.exampleDate)
        #expect(m.count == 48 && m[3] == 3 && m[4] == 1 && m[5] == 2 && Array(m[36...39]) == hex("1F 00 00 00"))
        #expect(StubChannelEngine.parse("CTXF")?.channelName == "CTXF   ")
        #expect(StubChannelEngine.parse("CTXFILE:x") == nil)
        #expect(StubChannelEngine.parse("TOOLONGNAME") == nil)
        var out = 0
        stub.output = { _ in out += 1 }
        stub.receive(Data([1, 2, 3]))
        #expect(stub.hostWrites == 1 && stub.hostBytes == 3 && out == 0)
    }

    @Test func overridesGiveStockNumbers() throws {
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Explorer Citrix ABC"
        c.channelOverrides = StockChannels.channelMap
        let wd = WinstationDriver(configuration: c)
        #expect(wd.register(ThinwireEngine()) == 9)
        #expect(wd.register(SeamlessEngine(config: SeamlessEngine.Config())) == 7)
        #expect(wd.register(ClipboardEngine(config: ClipboardEngine.Config())) == 17)
        #expect(wd.register(AudioEngine(config: AudioEngine.Config())) == 14)
        #expect(wd.register(ControlEngine()) == 16)
        #expect(wd.register(GDTEngine(), number: 29) == 29)
        let stubs = StockChannels.stubs()
        for stub in stubs { wd.register(stub) }
        #expect(wd.channelNumber("CTXTUI\0") == 12 && wd.channelNumber("ctxdt\0\0") == 3 && wd.channelNumber("MSTEAM2") == 33)
        let (modules, names) = try wd.buildModules()
        #expect(names.contains("CTXTUI") && names.contains("ctxdt") && names.last == "UI")
        #expect(contains(modules[0], hex("43 54 58 54 57 49 00 00 07 00")))   // CTXTWI\0 → 7
        #expect(contains(modules[0], hex("63 74 78 64 74 00 00 00 03 00")))   // ctxdt → 3
        // The TWI module carries its new channel number.
        let twi = try #require(names.firstIndex(of: "CTXTWI"))
        #expect(Array(modules[twi][36...39]) == hex("07 00 00 00"))
        // Without overrides nothing moves.
        let plain = Self.driver()
        #expect(plain.register(SeamlessEngine(config: SeamlessEngine.Config())) == 12)
    }

    static func driver() -> WinstationDriver {
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Explorer Citrix ABC"
        return WinstationDriver(configuration: c)
    }
}

/// docs/76 §7.6: module-header name/version overrides (V14–V17).
@Suite struct ModuleOverrideTests {
    @Test func environmentParse() {
        let (o, errors) = WDModuleOverride.fromEnvironment([
            "ICA_MODNAME_CTXGDT": "ClientGDT", "ICA_MODVER_CTXGDT": "1-1", "ICA_MODVER_ctxcdm": "1-9",
            "ICA_MODVER_CTXCLIP": "x", "ICA_MODNAME_CTXCTL": "Contr\u{e4}l", "OTHER": "1",
        ])
        #expect(o["CTXGDT"] == WDModuleOverride(name: "ClientGDT", versionLow: 1, versionHigh: 1))
        #expect(o["CTXCDM"] == WDModuleOverride(versionLow: 1, versionHigh: 9))
        #expect(o["CTXCLIP"] == nil && o["CTXCTL"] == nil && errors.count == 2)
    }

    @Test func applyWritesNameFieldAndVersions() {
        var m = GDTEngine().module(channel: 29, date: GDTModuleTests.exampleDate)
        let before = m
        WDModuleOverride(name: "ClientGDT", versionLow: 1, versionHigh: 1).apply(to: &m)
        #expect(Array(m[6..<19]) == Array("ClientGDT".utf8) + zeros(4))
        #expect(Array(m[19...]) == Array(before[19...]) && m.count == 48)
        // 14 characters: cut to 12, NUL kept at 18.
        WDModuleOverride(name: "ControlChannel", versionLow: 1, versionHigh: 2).apply(to: &m)
        #expect(Array(m[6..<19]) == Array("ControlChann".utf8) + [0] && m[4] == 1 && m[5] == 2)
        #expect(Array(m[19..<22]) == Array("ICA".utf8))
    }

    @Test func driverAppliesOverridesByVCName() throws {
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Explorer Citrix ABC"
        c.moduleOverrides = ["CTXGDT": StockChannels.moduleNames["CTXGDT"]!, "CTXCDM": StockChannels.moduleNames["CTXCDM"]!,
                             "CTXCLIP": StockChannels.moduleNames["CTXCLIP"]!]
        let wd = WinstationDriver(configuration: c)
        wd.register(ThinwireEngine())
        wd.register(SeamlessEngine(config: SeamlessEngine.Config()))
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("modov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        wd.register(CDMEngine(config: CDMEngine.Config(fileSystem: try CDMPOSIXFileSystem(root: dir, readOnly: true))))
        wd.register(GDTEngine(), number: 29)
        let (modules, names) = try wd.buildModules()
        func module(_ name: String) throws -> [UInt8] { modules[try #require(names.firstIndex(of: name))] }
        let gdt = try module("CTXGDT"), cdm = try module("CTXCDM "), clip = try module("CTXCLIP"), twi = try module("CTXTWI")
        #expect(Array(gdt[4...5]) == [1, 1] && Array(gdt[6..<15]) == Array("ClientGDT".utf8))
        #expect(Array(cdm[4...5]) == [1, 9] && Array(cdm[6..<17]) == Array("ClientDrive".utf8) && cdm.count == 70)
        #expect(Array(clip[4...5]) == [0, 3] && Array(clip[6..<15]) == Array("Clipboard".utf8))
        #expect(Array(twi[6..<19]) == zeros(13))   // untouched
    }

    @Test func stockNamesCoverEveryNamedStockChannel() {
        #expect(StockChannels.moduleNames.count == 26)
        let keys = Set(StockChannels.all.map { WDModuleOverride.key($0.name) }).union(["WD", "TD", "PDRFRAME", "PDCRYPT1", "UI"])
        #expect(Set(StockChannels.moduleNames.keys).isSubset(of: keys))
        for entry in StockChannels.all {
            guard let o = StockChannels.moduleNames[WDModuleOverride.key(entry.name)], let low = entry.versionLow else { continue }
            #expect(o.versionLow == low && o.versionHigh == entry.versionHigh, "\(entry.name)")
        }
    }
}

/// docs/76 §7.8: identity fields (V18) and overrides on non-VD modules.
@Suite struct IdentityVariantTests {
    @Test func hostNameOverrideAndEnvironment() {
        var m = GDTEngine().module(channel: 29, date: GDTModuleTests.exampleDate)
        WDModuleOverride(hostName: "vdtw30").apply(to: &m)
        #expect(Array(m[19..<28]) == Array("vdtw30".utf8) + zeros(3))
        WDModuleOverride(hostName: "").apply(to: &m)
        #expect(Array(m[19..<28]) == zeros(9))
        let (o, errors) = WDModuleOverride.fromEnvironment(["ICA_MODHOST_CTXTWI": "-", "ICA_MODHOST_CTXTW": "vdtw30"])
        #expect(errors.isEmpty && o["CTXTWI"]?.hostName == "" && o["CTXTW"]?.hostName == "vdtw30")
    }

    @Test func stockNamesApplyToEveryModuleIncludingUI() throws {
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Explorer Citrix ABC"
        c.moduleOverrides = StockChannels.moduleNames
        let wd = WinstationDriver(configuration: c)
        wd.register(ThinwireEngine())
        wd.register(SeamlessEngine(config: SeamlessEngine.Config()))
        let (modules, names) = try wd.buildModules()
        #expect(names == ["WD", "TD", "PDRFRAME", "PDCRYPT1", "CTXTW  ", "CTXTWI", "UI"])
        func field(_ m: [UInt8], _ r: Range<Int>) -> String { String(decoding: m[r].prefix { $0 != 0 }, as: UTF8.self) }
        let expected: [(String, UInt8, UInt8, String)] = [("ICA 3.0", 1, 9, "WDICA"), ("TCP", 1, 2, ""), ("RFrame", 1, 2, "PDRFRAME"),
                                                          ("Encrypt", 1, 1, "PDCRYPT1"), ("Thinwire3.0", 4, 5, "vdtw30"),
                                                          ("TWI", 1, 1, ""), ("ui", 1, 8, "")]
        for (m, e) in zip(modules, expected) {
            #expect(field(m, 6..<19) == e.0 && m[4] == e.1 && m[5] == e.2 && field(m, 19..<28) == e.3, "\(e.0)")
        }
        // The UI module's string pool is untouched (same length as without overrides).
        let plain = try WinstationDriver(configuration: { var p = c; p.moduleOverrides = [:]; return p }()).buildModules()
        #expect(plain.0.last?.count == modules.last?.count)
    }

    @Test func hostOSCapabilityOnlyWhenSet() throws {
        let server = try WDInitRequest(payload: Array(bytes(hex: liveInitRequestHex).dropFirst(3))).capabilities
        #expect(!WDCapabilityPolicy().negotiate(server: server).contains { $0.id == WDCapability.hostOS })
        var policy = WDCapabilityPolicy()
        policy.hostOSReply = 3
        let cap = try #require(policy.negotiate(server: server).first { $0.id == WDCapability.hostOS })
        #expect(cap.body == hex("03 00 00 00 00 00"))
    }
}

/// docs/76 §7.9: V21 (VD channel as bit mask, no cap 0x21) and V22 (echo of server caps 0x2A/0x2C).
@Suite struct ChannelMaskVariantTests {
    static func server() throws -> [WDCapability] {
        try WDInitRequest(payload: Array(bytes(hex: liveInitRequestHex).dropFirst(3))).capabilities
    }

    @Test func maskModeDropsVCCountAndWritesBitMasks() throws {
        var policy = WDCapabilityPolicy()
        #expect(policy.negotiate(server: try Self.server()).contains { $0.id == WDCapability.vcCount })
        policy.vcCountCapability = false
        #expect(!policy.negotiate(server: try Self.server()).contains { $0.id == WDCapability.vcCount })
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Explorer Citrix ABC"
        c.policy = policy
        let wd = WinstationDriver(configuration: c)
        wd.register(ThinwireEngine())
        wd.register(SeamlessEngine(config: SeamlessEngine.Config()))
        wd.register(GDTEngine(), number: 29)
        let (modules, names) = try wd.buildModules()
        func channel(_ name: String) throws -> [UInt8] { Array(modules[try #require(names.firstIndex(of: name))][36...39]) }
        #expect(try channel("CTXTW  ") == hex("00 02 00 00"))
        #expect(try channel("CTXTWI") == hex("00 10 00 00"))
        #expect(try channel("CTXGDT") == hex("00 00 00 20"))
    }

    @Test func echoesListedServerCapabilities() throws {
        var policy = WDCapabilityPolicy()
        #expect(!policy.negotiate(server: try Self.server()).contains { $0.id == 0x2A })
        policy.echoCapabilities = [0x2A, 0x2C]
        let out = policy.negotiate(server: try Self.server())
        let a = try #require(out.first { $0.id == 0x2A }), c = try #require(out.first { $0.id == 0x2C })
        #expect(a.body == [0x01] + [UInt8](repeating: 0xFF, count: 12) + zeros(4))
        #expect(c.body == hex("01 00") + [UInt8](repeating: 0xFF, count: 12) + hex("01 00 00 00"))
        #expect(out.last?.id == WDCapability.vcPriority)
    }
}
