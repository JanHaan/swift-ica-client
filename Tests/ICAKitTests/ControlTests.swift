import Testing
import Foundation
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { UInt8($0, radix: 16)! } }
private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

/// docs/55 §5.4: the host's capability request (caps 1, 2, 3 limit 0x0800, 5 = 0, 6 = 1, 0x0A) and our response.
let controlCapabilityRequest = hex("""
    34 00 00 00
    04 00 06 00
    01 00 08 00  01 00 00 00
    02 00 0C 00  02 00 00 00 00 00 00 00
    03 00 08 00  00 08 00 00
    05 00 08 00  00 00 00 00
    06 00 08 00  01 00 00 00
    0A 00 04 00
    """)
let controlCapabilityResponse = hex("""
    34 00 01 00
    04 00 06 00
    01 00 08 00  01 00 00 00
    02 00 0C 00  02 00 00 00 00 00 00 00
    03 00 08 00  00 08 00 00
    05 00 08 00  00 00 00 00
    06 00 08 00  01 00 00 00
    0A 00 04 00
    """)
/// The same layout as the commit (cmd 0x02).
let controlCapabilityCommit = [UInt8](controlCapabilityRequest.prefix(2)) + [0x02] + controlCapabilityRequest.dropFirst(3)
/// Layout of docs/55 §6.5 (worked example there: an Explorer resource with a longer name, 66 bytes), for
/// "Explorer Demo", no command line, 54 bytes.
let controlExplorerLaunch = hex("""
    32 00 03 00
    0C 00 30 00 00 00 00 00 00 00 00 00
    23 00 22 00 45 00 78 00 70 00 6C 00 6F 00 72 00
    65 00 72 00 20 00 44 00 65 00 6D 00 6F 00 22 00
    22 00 00 00
    00 00
    """)
private let success = hex("04 00 04 00 00 00 00 00")
private func status(_ s: UInt8) -> [UInt8] { hex("04 00 04 00") + [s, 0, 0, 0] }

/// An engine with captured output and hand-driven timers.
private final class Harness {
    let engine: ControlEngine
    var sent: [[UInt8]] = []
    var timers: [(delay: TimeInterval, block: () -> Void)] = []
    var results: [Int: ControlEngine.LaunchResult] = [:]
    var events: [String] = []

    init(_ config: ControlEngine.Config = ControlEngine.Config()) {
        engine = ControlEngine(config: config)
        engine.output = { [unowned self] out in if case .channel(let d) = out { sent.append([UInt8](d)) } }
        engine.scheduleAfter = { [unowned self] delay, block in timers.append((delay, block)) }
        engine.onEvent = { [unowned self] in events.append("\($0)") }
    }

    func feed(_ bytes: [UInt8]) { engine.receive(Data(bytes)) }

    private var count = 0

    /// Returns the harness's own index (a completion may run before `launch` returns).
    @discardableResult
    func launch(_ program: String, _ commandLine: String = "") -> Int {
        count += 1
        let index = count
        engine.launch(ControlLaunch(initialProgram: program, commandLine: commandLine)) { [unowned self] r in results[index] = r }
        return index
    }

    func ready() {
        feed(controlCapabilityRequest)
        feed(controlCapabilityCommit)
        sent.removeAll()
    }

    /// Fires every pending timer with this delay.
    func fire(_ delay: TimeInterval) {
        let due = timers.filter { $0.delay == delay }
        timers.removeAll { $0.delay == delay }
        due.forEach { $0.block() }
    }
}

@Suite struct ControlModuleTests {
    static let exampleDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!

    @Test func module48BytesVersions1To2HostICAChannel20() {
        let m = WDModules.control(channel: 20, date: Self.exampleDate)
        let expected = hex("30 00 00 03 01 02") + zeros(13) + hex("49 43 41") + zeros(6)
            + hex("66 5D 00 60 00 00 00 00 14 00 00 00 00 00 00 00 00 00 00 00")
        #expect(expected.count == 48)
        #expect(m.count == 48)
        // Byte count and "modules remaining" are patched into the packet.
        let packet = WDModules.initResponsePackets([m])[0]
        #expect(Array(packet.prefix(3)) == hex("01 30 00"))
        #expect(Array(packet.dropFirst(3)) == expected)
        #expect(ControlEngine().module(channel: 20, date: Self.exampleDate) == m)
    }

    @Test func registeredAfterCTXCAMOnChannel20WithBindEntry() throws {
        let wd = WinstationDriver(configuration: {
            var c = WinstationDriver.Configuration()
            c.logon.initialProgram = "#Notepad Demo"
            return c
        }())
        wd.register(ThinwireEngine())
        wd.register(SeamlessEngine(config: SeamlessEngine.Config()))
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        wd.register(AudioEngine(config: AudioEngine.Config()))
        let engine = ControlEngine()
        #expect(wd.register(engine) == 20)
        let (modules, names) = try wd.buildModules()
        let index = try #require(names.firstIndex(of: "CTXCTL "))
        #expect(index == names.firstIndex(of: "CTXCAM ")! + 1)
        #expect(modules[index].count == 48)
        #expect(modules[index][3] == 3 && modules[index][4] == 1 && modules[index][5] == 2)
        #expect(Array(modules[index][36...39]) == hex("14 00 00 00"))
        #expect(engine.diagnostics.moduleBytes == modules[index])
        let bind = hex("43 54 58 43 54 4C 20 00 14 00")
        #expect(modules[0].indices.contains { i in i + bind.count <= modules[0].count && Array(modules[0][i..<i + bind.count]) == bind })
    }
}

@Suite struct ControlCapabilityTests {
    @Test func specExampleParsesAndAnswersByteExact() {
        var parser = ControlStreamParser()
        let messages = parser.feed(controlCapabilityRequest)
        #expect(messages.count == 1 && messages[0].command == 0)
        let caps = ControlCapability.parseList(messages[0].payload)
        #expect(caps.map(\.id) == [1, 2, 3, 5, 6, 0x0A])
        #expect(ControlCapability.commandLineLimit(caps) == 0x800)
        let (payload, answered) = ControlCapability.response(to: caps, hasLaunchData: false)
        #expect(answered.count == 6)
        let reply = ControlWire.message(ControlWire.Command.capabilityResponse, payload)
        #expect(reply.count == 56)
        #expect(reply == controlCapabilityResponse)
    }

    @Test func answerRules() {
        // Cap 3 with len 10 gets one more u16; an odd limit loses bit 0; cap 7 and unknown ids are not echoed;
        // cap 6 with 0 answers 0; cap 5 reports our own launch data.
        let host = hex("""
            04 00 05 00
            03 00 0A 00 01 04 00 00 00 00
            07 00 08 00 04 00 00 00
            06 00 08 00 00 00 00 00
            05 00 08 00 00 00 00 00
            63 00 04 00
            """)
        let caps = ControlCapability.parseList(host)
        #expect(caps.map(\.id) == [3, 7, 6, 5, 0x63])
        let (payload, answered) = ControlCapability.response(to: caps, hasLaunchData: true)
        #expect(answered.map(\.id) == [3, 6, 5])
        #expect(payload == hex("04 00 03 00  03 00 0A 00 00 04 00 00 00 00  06 00 08 00 00 00 00 00  05 00 08 00 01 00 00 00"))
        // Limit 0: no answer for cap 3.
        let zero = ControlCapability.parseList(hex("04 00 01 00 03 00 08 00 00 00 00 00"))
        #expect(ControlCapability.response(to: zero, hasLaunchData: false).answered.isEmpty)
    }

    @Test func malformedListsStopInsteadOfOverrunning() {
        #expect(ControlCapability.parseList([]).isEmpty)
        // len 2 (< header) and a len past the end.
        #expect(ControlCapability.parseList(hex("04 00 02 00 01 00 02 00")).isEmpty)
        #expect(ControlCapability.parseList(hex("04 00 02 00 01 00 08 00 01 00 00 00 02 00 20 00")).map(\.id) == [1])
        // Count larger than present.
        #expect(ControlCapability.parseList(hex("04 00 09 00 0A 00 04 00")).map(\.id) == [0x0A])
    }
}

@Suite struct ControlLaunchTests {
    @Test func explorerExample54BytesExactly() throws {
        let bytes = try #require(ControlLaunch(initialProgram: "#Explorer Demo").request(commandLineLimit: 0x800))
        #expect(bytes.count == 54)
        #expect(bytes == controlExplorerLaunch)
    }

    @Test func calculatorHeaderValues() throws {
        let bytes = try #require(ControlLaunch(initialProgram: "#Calculator Demo").request(commandLineLimit: 0x800))
        // `#"Calculator Demo""` + NUL = 20 units → A = 52 (12 + 40), L = 54, command line at 52.
        #expect(Array(bytes.prefix(8)) == hex("36 00 03 00 0C 00 34 00"))
        #expect(bytes.count == 58)
        #expect(Array(bytes.suffix(2)) == [0, 0])
    }

    @Test func applicationStringTransform() {
        #expect(ControlLaunch(initialProgram: "#App").applicationString == "#\"App\"\"")
        #expect(ControlLaunch(initialProgram: "#\"App\"").applicationString == "#\"App\"\"")
        #expect(ControlLaunch(initialProgram: "#\"App").applicationString == "#\"App\"\"")
        #expect(ControlLaunch(initialProgram: "App").applicationString == nil)
        #expect(ControlLaunch(initialProgram: "").request(commandLineLimit: 0x800) == nil)
    }

    @Test func commandLineJoinFromICAFile() throws {
        let long = try #require(ICAFile(text: """
            [Application]
            InitialProgram=#Notepad Demo
            LongCommandLine="C:\\a b"
            LongCommandLine000=\\c.txt
            LongCommandLine001=""
            LongCommandLine003=never
            cmdLine=ignored
            """))
        // Only pieces longer than 2 characters lose their quotes; the run stops at the missing 002.
        #expect(ControlLaunch.commandLine(long) == "C:\\a b\\c.txt\"\"")
        let short = try #require(ICAFile(text: "[A]\nInitialProgram=#X\ncmdLine=/s\n"))
        #expect(ControlLaunch(ica: short) == ControlLaunch(initialProgram: "#X", commandLine: "/s"))
        let none = try #require(ICAFile(text: "[A]\nInitialProgram=#X\n"))
        #expect(ControlLaunch(ica: none).commandLine.isEmpty)
    }

    @Test func commandLineLimit() throws {
        let l = ControlLaunch(initialProgram: "#X", commandLine: "abcdef")
        #expect(l.limitedCommandLine(limit: 0x800) == "abcdef")
        #expect(l.limitedCommandLine(limit: 14) == "abcdef")       // 2·6 + 2 = 14 fits
        #expect(l.limitedCommandLine(limit: 10) == "abcd")         // (10 − 2) / 2
        #expect(l.limitedCommandLine(limit: 0).isEmpty)            // no cap 3
        let bytes = try #require(l.request(commandLineLimit: 10))
        // `#"X""` + NUL = 6 units → A = 12; "abcd" + NUL → C = 10; L = 34, command line at 24.
        #expect(Array(bytes.prefix(8)) == hex("22 00 03 00 0C 00 18 00"))
        #expect(Array(bytes.suffix(10)) == hex("61 00 62 00 63 00 64 00 00 00"))
    }
}

@Suite struct ControlEngineTests {
    @Test func handshakeQueuesUntilCommitThenLaunchesAndMatchesStatus() {
        let h = Harness()
        let id = h.launch("#Explorer Demo")
        #expect(h.sent.isEmpty && h.engine.state == .waiting && h.engine.pendingLaunches == 1)
        h.feed(controlCapabilityRequest)
        #expect(h.sent == [controlCapabilityResponse])
        #expect(h.engine.state == .waiting)   // nothing before the commit (§3.4)
        h.feed(controlCapabilityCommit)
        #expect(h.engine.state == .ready && h.engine.commandLineLimit == 0x800)
        #expect(h.sent.count == 2 && h.sent[1] == controlExplorerLaunch)
        #expect(h.results[id] == nil)
        h.feed(success)
        #expect(h.results[id] == .started)
        #expect(h.engine.pendingLaunches == 0)
        #expect(h.engine.diagnostics.capabilityResponse == controlCapabilityResponse)
    }

    @Test func fifoMatchingAndIgnoredStatus5() {
        let h = Harness()
        h.ready()
        let a = h.launch("#Calculator Demo"), b = h.launch("#Explorer Demo"), c = h.launch("#Notepad Demo")
        #expect(h.sent.count == 3)
        h.feed(status(5))                     // unnamed: dequeues nothing
        #expect(h.results.isEmpty)
        h.feed(success + status(6))           // merged in one write
        #expect(h.results[a] == .started && h.results[b] == .failed(status: 6))
        h.feed(hex("08 00 04 00 02 00 00 00 FF FF FF FF"))   // a longer payload: only the u32 counts
        #expect(h.results[c] == .failed(status: 2))
        h.feed(success)                       // nothing pending: logged only
        #expect(h.results.count == 3)
    }

    @Test func splitWritesAndUnknownCommandsSkippedByLength() {
        let h = Harness()
        let id = h.launch("#Calculator Demo")
        let stream = controlCapabilityRequest + hex("06 00 09 00 01 02 03 04 05 06") + controlCapabilityCommit
            + hex("02 00 0C 00 AA BB") + success
        for byte in stream { h.feed([byte]) }
        #expect(h.engine.state == .ready)
        #expect(h.results[id] == .started)
        #expect(h.engine.diagnostics.skippedCommands == [0x09: 1, 0x0C: 1])
    }

    @Test func notHashProgramIsDroppedWithoutSending() {
        let h = Harness()
        h.ready()
        let id = h.launch("Calculator Demo")
        #expect(h.sent.isEmpty)
        if case .notSent = h.results[id] {} else { Issue.record("expected notSent, got \(String(describing: h.results[id]))") }
    }

    @Test func responseTimeoutKeepsAPlaceholderSoLateResponsesDoNotShift() {
        let h = Harness()
        h.ready()
        let a = h.launch("#Calculator Demo")
        h.fire(20)
        #expect(h.results[a] == .timedOut)
        let b = h.launch("#Notepad Demo")
        h.feed(success)                       // late answer for a
        #expect(h.results[b] == nil)
        h.feed(status(4))
        #expect(h.results[b] == .failed(status: 4))
        #expect(h.results[a] == .timedOut)
    }

    @Test func readyTimeoutAndShutdown() {
        let h = Harness()
        let a = h.launch("#Calculator Demo")
        h.fire(90)
        if case .notSent = h.results[a] {} else { Issue.record("expected notSent") }
        let b = h.launch("#Calculator Demo")
        h.ready()
        let c = h.launch("#Notepad Demo")
        h.engine.shutdown()
        #expect(h.results[b] == .sessionEnded && h.results[c] == .sessionEnded)
        let d = h.launch("#Notepad Demo")
        if case .notSent = h.results[d] {} else { Issue.record("expected notSent after shutdown") }
        #expect(h.engine.state == .ended)
    }

    @Test func commitWithCap5SendsOwnAppFirstAndSharedLaunchesWait() throws {
        var config = ControlEngine.Config()
        config.own = ControlLaunch(initialProgram: "#Notepad Demo")
        let h = Harness(config)
        h.feed(controlCapabilityRequest)
        // Our own app has no command line: cap 5 answered 0.
        #expect(h.sent.last == controlCapabilityResponse)
        let commit = hex("""
            14 00 02 00  04 00 02 00
            03 00 08 00 00 08 00 00
            05 00 08 00 01 00 00 00
            """)
        h.feed(commit)
        let own = try #require(ControlLaunch(initialProgram: "#Notepad Demo").request(commandLineLimit: 0x800))
        #expect(h.sent.last == own && h.engine.diagnostics.ownLaunchSent)
        let shared = h.launch("#Calculator Demo")
        #expect(h.sent.count == 2)           // waits for the own launch's response
        h.feed(success)                       // the own launch's answer
        #expect(h.results[shared] == nil && h.sent.count == 3)
        h.feed(success)
        #expect(h.results[shared] == .started)
    }

    @Test func ownLaunchWithoutResponseReleasesTheQueue() {
        var config = ControlEngine.Config()
        config.own = ControlLaunch(initialProgram: "#Notepad Demo")
        let h = Harness(config)
        h.feed(controlCapabilityRequest)
        h.feed(hex("0C 00 02 00 04 00 01 00 05 00 08 00 01 00 00 00"))
        let shared = h.launch("#Calculator Demo")
        #expect(h.sent.count == 2)
        h.fire(5)
        #expect(h.sent.count == 3)
        h.feed(success)
        #expect(h.results[shared] == .started)
    }

    @Test func noOwnLaunchWithoutCap5OrWithoutOwnApp() {
        let h = Harness()
        h.feed(controlCapabilityRequest)
        h.feed(hex("0C 00 02 00 04 00 01 00 05 00 08 00 01 00 00 00"))
        #expect(h.engine.state == .ready && !h.engine.diagnostics.ownLaunchSent && h.sent.count == 1)
    }

    @Test func sessionEventsAreParsed() {
        let h = Harness()
        h.feed(hex("10 00 0F 00  00 00 00 00 00 00 00 00 01 00 00 00 02 00 00 00"))
        #expect(h.events.contains { $0.contains("DISCONNECT") })
        h.feed(hex("1C 00 0F 00  00 00 00 00 00 00 00 00 02 00 00 00") + hex("33 22 11 00 55 44 77 66 88 99 AA BB CC DD EE FF"))
        #expect(h.engine.diagnostics.sessionGuid == "00112233-4455-6677-8899-AABBCCDDEEFF")
    }
}

@Suite struct SessionSharingTests {
    private static func ica(_ lines: String) -> ICAFile { ICAFile(text: "[Application]\n" + lines)! }
    private static let base = """
        SSLEnable=On
        SSLProxyHost=gw.example.test:443
        TWIMode=On
        SessionsharingKey=K1
        """

    @Test func gatewayEndpointNotTheTicket() {
        let a = SessionShareKey(ica: Self.ica(Self.base + "\nAddress=TICKET-A\nInitialProgram=#Mouse Demo"))
        let b = SessionShareKey(ica: Self.ica(Self.base + "\nAddress=TICKET-B\nInitialProgram=#Explorer Demo"))
        #expect(a.connectHost == "gw.example.test" && a.connectPort == 443 && a.sslEnabled)
        #expect(b.shares(with: a))
    }

    @Test func endpointRules() {
        let plain = SessionShareKey(ica: Self.ica("Address=10.0.0.5\nTWIMode=On\nSessionsharingKey=K"))
        #expect(!plain.sslEnabled && plain.connectHost == "10.0.0.5" && plain.connectPort == 1494)
        let proxy = SessionShareKey(ica: Self.ica("Address=10.0.0.5\nProxyHost=proxy.test:8080\nTWIMode=On\nSessionsharingKey=K"))
        #expect(proxy.connectHost == "proxy.test" && proxy.connectPort == 8080)
        let noPort = SessionShareKey(ica: Self.ica("SSLEnable=On\nSSLProxyHost=GW.Example.Test\nTWIMode=On"))
        #expect(noPort.connectHost == "gw.example.test" && noPort.connectPort == 443)
    }

    @Test func matchRules() {
        let a = SessionShareKey(ica: Self.ica(Self.base))
        func with(_ change: (inout SessionShareKey) -> Void) -> SessionShareKey { var k = a; change(&k); return k }
        #expect(with { $0.connectPort = 8443 }.shares(with: a) == false)
        #expect(with { $0.connectHost = "other.test" }.shares(with: a) == false)
        #expect(with { $0.sslEnabled = false }.shares(with: a) == false)
        #expect(with { $0.sharingKey = "K2" }.shares(with: a) == false)
        // String compare: "on" ≠ "On", even though both are seamless.
        #expect(with { $0.twiMode = "on" }.shares(with: a) == false)
        // Desktops never share, and an absent or empty key never matches (unlike the reference).
        #expect(with { $0.twiMode = "Off" }.shares(with: with { $0.twiMode = "Off" }) == false)
        let noKey = SessionShareKey(ica: Self.ica(Self.base.replacingOccurrences(of: "SessionsharingKey=K1", with: "SessionsharingKey=")))
        #expect(noKey.sharingKey == nil && !noKey.shares(with: noKey))
        #expect(a.differences(to: with { $0.twiMode = "on"; $0.connectPort = 1 }) == ["connect port", "TWIMode"])
    }

    @Test func decision() {
        let a = SessionShareKey(ica: Self.ica(Self.base))
        var desktop = a
        desktop.twiMode = "Off"
        var other = a
        other.sharingKey = "K9"
        // Newest matching session first; one without CTXCTL is refused, not connected.
        let d1 = SessionSharingDecision.decide(a, among: [(1, a, true), (2, a, true), (3, other, true)])
        if case .share(let s) = d1 { #expect(s == 2) } else { Issue.record("expected share, got \(d1)") }
        let d2 = SessionSharingDecision.decide(a, among: [(1, a, false)])
        if case .refuse(let s, _) = d2 { #expect(s == 1) } else { Issue.record("expected refuse, got \(d2)") }
        // Same key, different TWIMode: still no second connection.
        let d3 = SessionSharingDecision.decide(desktop, among: [(1, a, true)])
        if case .refuse = d3 {} else { Issue.record("expected refuse, got \(d3)") }
        if case .connect = SessionSharingDecision.decide(a, among: [(3, other, true)]) {} else { Issue.record("expected connect") }
        if case .connect = SessionSharingDecision<Int>.decide(a, among: []) {} else { Issue.record("expected connect") }
    }
}

@Suite struct ControlEngineLinkTests {
    @Test func timeoutsWaitWhileTheLinkIsDown() {
        let h = Harness()
        h.ready()
        let a = h.launch("#Calculator Demo")
        h.engine.suspend()
        h.fire(20)
        #expect(h.results[a] == nil)          // re-armed, not failed
        h.engine.resume()
        h.feed(success)
        #expect(h.results[a] == .started)
        let b = h.launch("#Notepad Demo")
        h.fire(20)
        #expect(h.results[b] == .timedOut)
    }
}
