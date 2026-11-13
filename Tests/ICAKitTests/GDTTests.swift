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
