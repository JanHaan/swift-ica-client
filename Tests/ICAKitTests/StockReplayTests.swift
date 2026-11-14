import Testing
import Foundation
@testable import ICAKit

/// docs/76 §7.14 (round 9): replay of a recorded stock module list, V3 decompression in the live receive path, the
/// version-2 credential reply and the stock-form UI module. Synthetic data only: no recorded bytes in the tests.
private func hex(_ text: String) -> [UInt8] { text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { UInt8($0, radix: 16)! } }

private let date = Date(timeIntervalSince1970: 1_790_000_000)

/// A recorded-looking list: UI placeholder, TD, two PDs, a WD module with HT, credential v2 and powers 16/19, and VD
/// modules on non-default numbers (TWI on 7, CTXGDT on 29, a channel without an engine on 12).
private func syntheticReplay() throws -> WDStockReplay {
    let caps = [WDCapability(id: 0x05), WDCapability(id: 0x10, body: [7, 0, 0, 0, 0, 0, 0, 0]),
                WDCapability(id: 0x12, body: [2, 0]), WDCapability(id: 0x21, body: [0x40, 0])]
    var wd = try WDModuleLayout(WDModules.wd(capabilities: caps, channels: [("CTXTW  ", 9), ("CTXTWI\0", 7), ("CTXTUI\0", 12), ("CTXGDT\0", 29)],
                                             reducerVersion: 3, productID: 82, date: date))
    wd.setPowers(reducer: 16, expander: 19)
    func vd(_ channel: UInt8, _ extra: [UInt8] = []) -> [UInt8] {
        var w = WDModules.vdHeader(WDModuleIdentity(moduleClass: .vd, versionLow: 1, versionHigh: 1, name: "Rec\(channel)", hostName: "ICA"),
                                   channel: channel, date: date)
        w.raw(extra)
        var m = w.bytes()
        m[0] = UInt8(m.count); m[1] = 0
        return m
    }
    let ui = (try? WDModules.ui(logon: { var l = WDLogon(); l.initialProgram = "#X"; return l }(), credentialsInModule: false,
                                longCredentials: false, seed: 1, date: date))!
    let text = WDStockReplay.fileText(modules: [ui, WDModules.td(date: date), WDModules.framing(date: date), WDModules.encryption(date: date),
                                                wd.bytes, vd(9, [1, 2, 3]), vd(7), vd(12, [0xFF, 0x07]), vd(29, [0x87, 0x13, 0])],
                                      comment: "synthetic")
    return try WDStockReplay.parse(text)
}

@Suite struct StockReplayTests {
    @Test func fileNeverHoldsTheUIModuleAndKeysFollowTheBindTable() throws {
        let replay = try syntheticReplay()
        #expect(replay.slots.first == .ui)
        #expect(replay.slots.count == 9)
        #expect(replay.modules.map { replay.key(of: $0) } == ["TD", "PDRFRAME", "PDCRYPT1", "WD", "CTXTW", "CTXTWI", "CTXTUI", "CTXGDT"])
        let wd = try #require(replay.wdLayout)
        #expect(wd.reducerPower == 16 && wd.expanderPower == 19 && wd.maxReducerVersion == 3 && wd.productID == 82)
        #expect(wd.bindTable.map(\.number) == [9, 7, 12, 29])
        #expect(wd.capabilities.map(\.id) == [0x05, 0x10, 0x12, 0x21])
        #expect(throws: WDStockReplay.Failure.noUISlot) { _ = try WDStockReplay.parse("# none\n" + replay.modules.map { $0.map { String(format: "%02x", $0) }.joined() }.joined(separator: "\n")) }
        #expect(throws: WDStockReplay.Failure.badLine(2)) { _ = try WDStockReplay.parse("UI\nzz\n") }
    }

    @Test func replacingTheCapabilityBlockKeepsTheModuleConsistent() throws {
        var wd = try #require(try syntheticReplay().wdLayout)
        let before = wd.bindTable.map(\.name)
        wd.replaceCapabilities([WDCapability(id: 0x05)])
        #expect(wd.capabilities == [WDCapability(id: 0x05)])
        #expect(wd.bindTable.map(\.name) == before)
        #expect(Int(wd.bytes[0]) | Int(wd.bytes[1]) << 8 == wd.bytes.count)
        #expect(try WDModuleLayout(wd.bytes) == wd)
    }

    static func driver(_ edit: (inout WinstationDriver.Configuration) -> Void = { _ in }) throws -> (WinstationDriver, [String: RecordingEngine]) {
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Files App"
        let replay = try syntheticReplay()
        c.stockReplay = replay
        c.channelOverrides = Dictionary(replay.wdLayout!.bindTable.map { ($0.name, $0.number) }, uniquingKeysWith: { a, _ in a })
        c.v3Decompression = true
        c.credentialsV2 = true
        edit(&c)
        let wd = WinstationDriver(configuration: c, encryptionKey: 0x42)
        var engines: [String: RecordingEngine] = [:]
        for name in ["CTXTW  ", "CTXTWI\0", "CTXTUI\0", "CTXGDT\0"] {
            let e = RecordingEngine(name)
            engines[name] = e
            wd.register(e)
        }
        return (wd, engines)
    }

    @Test func recordedModulesGoOutWithOurUIInItsSlot() throws {
        let (wd, engines) = try Self.driver()
        #expect(wd.channelNumber("CTXTWI\0") == 7 && wd.channelNumber("CTXTUI\0") == 12 && wd.channelNumber("CTXGDT\0") == 29)
        #expect(engines.count == 4)
        var sent: [[UInt8]] = []
        wd.transmit = { sent.append($0) }
        var names: [String] = []
        wd.onEvent = { if case .initResponseSent(let n, _) = $0 { names = n } }
        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        let replay = try syntheticReplay()
        #expect(sent.count == replay.slots.count)
        #expect(sent[0][6] == WDModuleClass.ui.rawValue)
        for (i, m) in replay.modules.enumerated() {
            #expect(Array(sent[i + 1][3...].dropFirst(3)) == Array(m.dropFirst(3)), "module \(i)")
        }
        #expect(sent.map { $0[5] } == (0..<9).reversed().map { UInt8($0) })   // modules remaining, patched
        #expect(names.first == "UI(ours)" && names.contains("CTXGDT(stock)") && names.contains("WD(stock)"))
        // The negotiated list is the recorded WD module's (HT and credential v2 included).
        #expect(wd.negotiated.map(\.id) == [0x05, 0x10, 0x12, 0x21])
    }

    @Test func oursReplacesListedModulesAndWDCapsKeepsTheRecordedFixedPart() throws {
        let (wd, _) = try Self.driver { $0.stockOurs = ["CTXGDT", "WDCAPS"] }
        var sent: [[UInt8]] = []
        wd.transmit = { sent.append($0) }
        var names: [String] = []
        wd.onEvent = { if case .initResponseSent(let n, _) = $0 { names = n } }
        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        #expect(names.contains("CTXGDT(ours)") && names.contains("WD(stock, our caps)"))
        let gdt = try #require(sent.first { $0.count > 42 && $0[6] == 3 && $0[39] == 29 })
        #expect(Array(gdt[9..<12]) == [0, 0, 0])   // our module: no name; the recorded one is "Rec29"
        let wdModule = try #require(sent.first { $0[6] == WDModuleClass.wd.rawValue })
        let layout = try WDModuleLayout(Array(wdModule.dropFirst(3)))
        #expect(layout.reducerPower == 16 && layout.productID == 82)
        #expect(!layout.capabilities.contains { $0.id == 0x10 })   // ours: HT not offered by default
        #expect(!wd.negotiated.contains { $0.id == 0x10 })
    }

    @Test func compressionPatchDropsPowersAndHT() throws {
        let (wd, _) = try Self.driver { $0.stockPowers = (0, 0); $0.stockDropCaps = [0x10] }
        var sent: [[UInt8]] = []
        wd.transmit = { sent.append($0) }
        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        let layout = try WDModuleLayout(Array(try #require(sent.first { $0[6] == WDModuleClass.wd.rawValue }).dropFirst(3)))
        #expect(layout.reducerPower == 0 && layout.expanderPower == 0)
        #expect(layout.capabilities.map(\.id) == [0x05, 0x12, 0x21])
        #expect(wd.configuration.stockWDDescription.contains("powers patched to 0/0"))
    }

    /// Server side of the connect: INIT_CONNECT PD + WD (reducer v3, powers 16/19), then the encryption init.
    static func connect(_ wd: WinstationDriver) {
        var pd = [UInt8](repeating: 0, count: 12)
        pd[2] = 1; pd[3] = 4; pd[8] = 0x0B
        var c = [UInt8](repeating: 0, count: 40)
        c[3] = 2; c[26] = 16; c[27] = 19; c[30] = 3
        c[32] = 4; c[34] = 36; c[38] = 4
        wd.receive(Data([0x02, 12, 0] + pd + [0x02, 40, 0] + c + WDFraming.frame([0x02])))
    }

    @Test func compressedServerFramesAreDecodedAndClientFramesStayUncompressed() throws {
        let (wd, engines) = try Self.driver()
        var sent: [[UInt8]] = []
        wd.transmit = { sent.append($0) }
        var failures: [String] = []
        wd.onEvent = { if case .failure(let t) = $0 { failures.append(t) } }
        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        Self.connect(wd)
        #expect(wd.v3 && wd.highThroughput)
        #expect(failures.isEmpty)
        // A compressed GDT write (expander power 19, model 0) inside HT (flags 0) and encryption.
        var peer = try WDV3Coder(power: 19)
        let syn = hex("01 02 00 00 00 1d 00 07 01 00 00 02 00 00")
        var f = V3FrameBuilder()
        f.segment(channel: 29, complete: true, compressed: true, value: syn.count, try peer.encode(model: 0, syn))
        var server = WDBasicCipher(key: 0x42)
        var body = [0x00] + f.frame
        server.encrypt(&body)
        wd.receive(Data(WDFraming.frame([0x01] + body)))
        #expect(failures.isEmpty)
        #expect(engines["CTXGDT\0"]?.received == [Data(syn)])
        // Our answer: HT header 0, one uncompressed V3 segment (decodable without a coder).
        sent = []
        engines["CTXGDT\0"]?.output?(.channel(Data([0x02, 0x01])))
        #expect(sent.count == 1)
        var out = Array(sent[0].dropFirst(3))
        #expect(sent[0][2] == 0x01)
        server.decrypt(&out)
        #expect(out.first == 0x00)
        var plain = WDV3Expander()
        #expect(try plain.expand(Array(out.dropFirst())) == WDBuild.virtualWrite(channel: 29, [0x02, 0x01]))
    }

    @Test func withoutDecompressionTheDefaultStillReportsTheExpanderPower() throws {
        let (wd, _) = try Self.driver { $0.v3Decompression = false }
        var failures: [String] = []
        wd.onEvent = { if case .failure(let t) = $0 { failures.append(t) } }
        wd.receive(Data(bytes(hex: liveInitRequestHex)))
        Self.connect(wd)
        #expect(failures.contains { $0.contains("expander power 19") })
    }

    @Test func credentialRequestVersion2IsAnsweredOnlyWhenEnabled() throws {
        let reply = WDBuild.credentialsV2(username: "", domain: "\\D", password: "pw", ticketType: "T1", ticket: "abc")
        // 44 len16, 04 00, offsets from the byte after 04 00: user 0, 0, domain 16, 0, password 22, 0, type 28, ticket 34.
        #expect(Array(reply.prefix(5)) == [0x44, UInt8(reply.count - 3), 0x00, 0x04, 0x00])
        #expect(Array(reply[5..<21]) == hex("00 00 00 00 10 00 00 00 16 00 00 00 1c 00 22 00"))
        #expect(Array(reply[21...]) == Array("\\D\0pw\0T1\0abc\0".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        for enabled in [true, false] {
            let (wd, _) = try Self.driver { $0.credentialsV2 = enabled; $0.v3Decompression = true }
            var sent: [[UInt8]] = []
            wd.transmit = { sent.append($0) }
            wd.receive(Data(bytes(hex: liveInitRequestHex)))
            Self.connect(wd)
            sent = []
            var server = WDBasicCipher(key: 0x42)
            var f = V3FrameBuilder()
            f.segment(channel: 0x3F, complete: true, compressed: false, value: 5 << 1, [0x44, 0x02, 0x00, 0x03, 0x01])
            var body = [0x00] + f.frame
            server.encrypt(&body)
            wd.receive(Data(WDFraming.frame([0x01] + body)))
            #expect(sent.count == (enabled ? 1 : 0))
        }
    }

    @Test func stockFormUIModuleLayout() throws {
        var logon = WDLogon()
        logon.initialProgram = "#App"
        logon.clientName = "Name"
        logon.productName = "WI"
        logon.clientVersion = "1.2"
        logon.clientBuild = 25
        logon.launchReference = "ref"
        let m = try WDModules.uiStockForm(logon: logon, seed: 0x33, date: date)
        func u16(_ at: Int) -> Int { Int(m[at]) | Int(m[at + 1]) << 8 }
        #expect(m[3] == 0 && m[4] == 1 && m[5] == 8 && Array(m[6..<9]) == Array("ui\0".utf8))
        #expect(Array(m[36..<40]) == hex("34 00 00 00") && m[44] == 1 && m[45] == 0x33)
        #expect(Array(m[46..<56]) == [UInt8](repeating: 0, count: 10))
        #expect(u16(70) == 106 && u16(72) == m.count - 106 && u16(66) == 25 && u16(76) == 1)
        #expect(m[83] == 0 && m[92] == 0x1F && u16(95) == 100 && Array(m[100..<106]) == hex("06 00 01 00 02 00"))
        var pool = Array(m[106...])
        WDObfuscation.deobfuscate(&pool, seed: 0x33)
        let full = Array(m[..<106]) + pool
        func string(_ at: Int) -> String {
            var units: [UInt16] = []
            var i = at
            while full[i] != 0 || full[i + 1] != 0 { units.append(UInt16(full[i]) | UInt16(full[i + 1]) << 8); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        #expect(u16(56) == 106 + 66 && Array(pool[0..<66]) == [UInt8](repeating: 0, count: 66))
        #expect(string(u16(56)) == "#App" && string(u16(68)) == "Name" && string(u16(88)) == "WI" && string(u16(90)) == "1.2" && string(u16(93)) == "ref")
    }

    @Test func driverUsesTheStockFormUIWhenAsked() throws {
        var c = WinstationDriver.Configuration()
        c.logon.initialProgram = "#Files App"
        c.stockFormUI = true
        let wd = WinstationDriver(configuration: c)
        wd.register(ThinwireEngine())
        let (modules, names) = try wd.buildModules()
        let ui = try #require(names.firstIndex(of: "UI").map { modules[$0] })
        #expect(Array(ui[36..<40]) == hex("34 00 00 00") && (Int(ui[70]) | Int(ui[71]) << 8) == 106)
    }

    @Test func stubAnswersTheFirstHostWriteOnlyWhenGivenAReply() {
        let stub = StubChannelEngine(name: "CTXTUI\0")
        var out: [Data] = []
        stub.output = { if case .channel(let d) = $0 { out.append(d) } }
        stub.receive(Data([4, 0, 0, 0]))
        #expect(out.isEmpty)
        let answering = StubChannelEngine(name: "CTXTUI\0")
        answering.firstReply = [4, 0, 0x80, 0]
        answering.output = { if case .channel(let d) = $0 { out.append(d) } }
        answering.receive(Data([4, 0, 0, 0]))
        answering.receive(Data([4, 0, 0, 0]))
        #expect(out == [Data([4, 0, 0x80, 0])])
    }
}
