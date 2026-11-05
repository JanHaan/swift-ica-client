import Testing
import Foundation
@testable import ICAKit

// MARK: Host-side message builders (test only)

private enum Host {
    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    static func initRequest(version: UInt16, flags: UInt16 = 0) -> Data { Data(u16(1) + u16(flags) + u16(version)) }
    static func names(_ entries: [(UInt16, String)]) -> Data {
        var b = u16(8) + u16(0)
        for (id, name) in entries { b += u16(id) + u32(UInt32(name.utf8.count + 1)) + Array(name.utf8) + [0] }
        return Data(b + [0, 0, 0, 0, 0, 0])
    }
    static func list(_ ids: [UInt16]) -> Data {
        if ids.count == 1 { return Data(u16(3) + u16(1) + u16(ids[0]) + u32(0)) }
        return Data(u16(3) + u16(3) + ids.flatMap { u16($0) + u32(7) } + u16(0))
    }
    static let emptyList = Data([0x03, 0x00, 0x0C, 0x00])
    static func request(_ format: UInt16) -> Data { Data(u16(4) + u16(0) + u16(format) + u16(0)) }
    static func response(_ format: UInt16, _ data: Data) -> Data { Data(u16(5) + u16(0) + u16(format) + u32(UInt32(data.count))) + data }
    static let failure = Data([0x05, 0x00, 0x04, 0x00])
}

private func hex(_ s: String) -> Data { Data(bytes(hex: s.replacingOccurrences(of: " ", with: ""))) }

/// Engine with a manual clock and scheduler; output collected per VC write.
private final class Harness {
    let engine: ClipboardEngine
    var writes: [Data] = []
    var events: [ClipboardEngine.Event] = []
    var timers: [(delay: TimeInterval, block: () -> Void)] = []
    var clock: UInt64 = 1_000

    init(_ config: ClipboardEngine.Config = .init()) {
        engine = ClipboardEngine(config: config)
        engine.output = { [unowned self] out in if case .channel(let d) = out { writes.append(d) } }
        engine.onEvent = { [unowned self] in events.append($0) }
        engine.scheduleAfter = { [unowned self] delay, block in timers.append((delay, block)) }
        engine.now = { [unowned self] in clock }
    }

    /// Everything written since the last call, as one stream.
    func take() -> Data {
        defer { writes = [] }
        return writes.reduce(Data(), +)
    }

    func feed(_ d: Data) { engine.receive(d) }

    func fireTimers() {
        let t = timers
        timers = []
        t.forEach { $0.block() }
    }

    func ready(version: UInt16 = 3, names: [(UInt16, String)] = [(0xC00D, "HTML Format"), (0xC010, "Rich Text Format")]) {
        feed(Host.initRequest(version: version))
        if version >= 2 { feed(Host.names(names)) }
        _ = take()
        events = []
    }

    var hostClipboard: (ClipboardContent, Bool)? {
        for e in events.reversed() { if case .hostClipboard(let c, _, let echo) = e { return (c, echo) } }
        return nil
    }
}

// MARK: Module and binding (§1)

@Test func clipboardModuleIsByteExact() {
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 5, hour: 14, minute: 30, second: 10).date!
    let module = WDModules.initResponsePackets([WDModules.clipboard(date: date)])[0]
    #expect(Array(module.prefix(3)) == [0x01, 0x30, 0x00])
    let m = Array(module.dropFirst(3))
    let dosDate: UInt16 = 5 | 11 << 5 | (2026 - 1980) << 9
    let dosTime: UInt16 = 5 | 30 << 5 | 14 << 11
    let expected: [UInt8] = [0x30, 0x00, 0x00, 0x03, 0x01, 0x00] + [UInt8](repeating: 0, count: 13)
        + [0x49, 0x43, 0x41] + [UInt8](repeating: 0, count: 6)
        + [UInt8(dosDate & 0xFF), UInt8(dosDate >> 8), UInt8(dosTime & 0xFF), UInt8(dosTime >> 8)]
        + [0, 0, 0, 0] + [0x11, 0, 0, 0] + [0, 0] + [UInt8](repeating: 0, count: 6)
    #expect(m.count == 48)
    #expect(m == expected)
}

@Test func sessionAnnouncesClipboardModuleAndBindEntry() throws {
    let text = "[ApplicationServers]\nX=\n[X]\nSSLProxyHost=gw.example:443\nAddress=ticket\nCGPSecurityTicket=On\nTWIMode=On\nInitialProgram=#Test\n"
    let ica = try #require(ICAFile(text: text))
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    let plain = try ICASession(ica: ica, configuration: config)
    #expect(plain.clipboard == nil && plain.wd.channelNumber("CTXCLIP") == nil)

    let session = try ICASession(ica: ica, configuration: config, clipboard: .init())
    #expect(session.wd.channelNumber("CTXCLIP") == 17)
    let (modules, names) = try session.wd.buildModules()
    #expect(names == ["WD", "TD", "PDRFRAME", "PDCRYPT1", "CTXTW  ", "CTXTWI", "CTXCLIP", "UI"])
    let clip = modules[6]
    #expect(clip.count == 48)
    #expect(Array(clip[3...5]) == [0x03, 0x01, 0x00])      // class 3, min 1, max 0
    #expect(Array(clip[19...27]) == [0x49, 0x43, 0x41, 0, 0, 0, 0, 0, 0])
    #expect(Array(clip[32...47]) == [0, 0, 0, 0, 0x11, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
    #expect(Array(modules[5][3...5]) == [0x03, 0x01, 0x01])  // CTXTWI unchanged
    let wd = modules[0]
    let entry: [UInt8] = [0x43, 0x54, 0x58, 0x43, 0x4C, 0x49, 0x50, 0x00, 0x11, 0x00]
    let tableOffset = Int(wd[74]) | Int(wd[75]) << 8
    #expect(Int(wd[72]) == 3)
    #expect(Array(wd[(tableOffset + 20)..<(tableOffset + 30)]) == entry)
}

// MARK: Builders vs the byte examples (§3.2)

@Test func clipboardBuildersMatchSpecExamples() {
    #expect(ClipboardWire.initReply(version: 3) == hex("02 00 00 00 03 00 00 00 00 00 00 00"))
    #expect(ClipboardWire.formatList([13]) == hex("03 00 01 00 0D 00 00 00 00 00"))
    #expect(ClipboardWire.formatList([13, 0xC005]) == hex("03 00 03 00 0D 00 00 00 00 00 05 C0 00 00 00 00 00 00"))
    #expect(ClipboardWire.formatList([]) == hex("03 00 0C 00"))
    #expect(ClipboardWire.dataRequest(format: 13) == hex("04 00 00 00 0D 00 00 00"))
    #expect(ClipboardWire.dataFailure == hex("05 00 04 00"))
    #expect(ClipboardWire.dataResponse(format: 13, data: Data([0x41, 0, 0, 0])) == hex("05 00 00 00 0D 00 04 00 00 00 41 00 00 00"))
    #expect(ClipboardWire.formatNamesReply(ids: [0xC00D, 0xC010]).count == 10 + 12)
    #expect(ClipboardWire.formatNamesReply(ids: [0xC00D]) == hex("09 00 00 00 0D C0 00 00 00 00 00 00 00 00 00 00"))
}

@Test func clipboardWritesSplitAt1020() {
    #expect(ClipboardWire.split(Data(count: 3000)).map(\.count) == [1020, 1020, 960])
    #expect(ClipboardWire.split(Data(count: 1020)).map(\.count) == [1020])
    let h = Harness()
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: String(repeating: "x", count: 1500)), takenAt: 2_000))
    _ = h.take()
    h.feed(Host.request(13))
    // 10-byte header + 3002 bytes of UTF-16 text with the NUL.
    #expect(h.writes.map(\.count) == [1020, 1020, 972])
    let stream = h.take()
    #expect(stream.prefix(10) == hex("05 00 00 00 0D 00 BA 0B 00 00"))
}

// MARK: Parser (§2.1)

@Test func clipboardParserHandlesEveryCommand() {
    var p = ClipboardStreamParser()
    let stream = Host.initRequest(version: 3, flags: 0x10) + Host.names([(0xC00D, "HTML Format")]) + Host.list([13, 0xC00D])
        + Host.list([13]) + Host.emptyList + Host.request(13) + Host.response(13, Data([0x41, 0, 0, 0])) + Host.failure
    let messages = p.feed(stream)
    #expect(messages == [
        .initRequest(flags: 0x10, version: 3),
        .formatNames(flags: 0, entries: [ClipboardFormatName(id: 0xC00D, name: "HTML Format")]),
        .formatList(flags: 3, formats: [13, 0xC00D]),
        .formatList(flags: 1, formats: [13]),
        .formatList(flags: 0x0C, formats: []),
        .dataRequest(flags: 0, format: 13),
        .dataResponse(format: 13, length: 4, data: Data([0x41, 0, 0, 0])),
        .dataFailure(flags: 4),
    ])
    #expect(p.bufferedCount == 0 && !p.inPayload)

    // Byte by byte gives the same messages: the parser waits and never loses sync.
    var q = ClipboardStreamParser()
    var oneByOne: [ClipboardHostMessage] = []
    for b in stream { oneByOne += q.feed(Data([b])) }
    #expect(oneByOne == messages)

    // Arbitrary splits.
    var r = ClipboardStreamParser()
    var chunks: [ClipboardHostMessage] = []
    var i = stream.startIndex
    var size = 1
    while i < stream.endIndex {
        let end = min(stream.endIndex, i + size)
        chunks += r.feed(stream.subdata(in: i..<end))
        i = end
        size = size % 7 + 2
    }
    #expect(chunks == messages)
}

@Test func clipboardParserNameTerminatorAndNames() {
    var p = ClipboardStreamParser()
    // Terminator with a non-zero length: its bytes are consumed too (§3.2.3).
    let b: [UInt8] = [8, 0, 0, 0] + [0x05, 0xC0, 3, 0, 0, 0, 0x50, 0x4E, 0x47] + [0, 0, 2, 0, 0, 0, 0xAA, 0xBB] + [4, 0, 0, 0, 0xD, 0, 0, 0]
    let m = p.feed(Data(b))
    #expect(m == [.formatNames(flags: 0, entries: [ClipboardFormatName(id: 0xC005, raw: Data("PNG".utf8))]), .dataRequest(flags: 0, format: 13)])
    #expect(ClipboardFormatName(id: 1, raw: Data([0x48, 0x54, 0, 0])).name == "HT")
    #expect(ClipboardFormatName(id: 1, raw: Data([0xC4])).name == "\u{C4}")
}

@Test func clipboardParserDropsUnknownAndOverCap() {
    var p = ClipboardStreamParser(dataCap: 4)
    // Over the cap: consumed in pieces, not kept, and the next message still parses.
    let big = Host.response(13, Data(repeating: 0x41, count: 10))
    var out = p.feed(big.prefix(12))
    #expect(out.isEmpty && p.inPayload)
    out = p.feed(big.dropFirst(12) + Host.request(13))
    #expect(out == [.dataResponse(format: 13, length: 10, data: nil), .dataRequest(flags: 0, format: 13)])
    // Unknown command: everything buffered after it is dropped.
    out = p.feed(Data([0x07, 0x00, 0x00, 0x00]) + Host.request(13))
    #expect(out == [.unknown(command: 7, flags: 0, head: hex("07 00 00 00 04 00 00 00 0D 00 00 00"), previous: Host.request(13))])
    #expect(p.bufferedCount == 0)
    #expect(p.feed(Host.request(2)) == [.dataRequest(flags: 0, format: 2)])
    // Absurd name length.
    var q = ClipboardStreamParser()
    let absurd = Data([8, 0, 0, 0, 1, 0xC0, 0xFF, 0xFF, 0xFF, 0x7F])
    #expect(q.feed(absurd) == [.malformed(command: 8, flags: 0, reason: "name length 2147483647", head: absurd, previous: Data())])
    // Zero-length data response.
    #expect(q.feed(Host.response(13, Data())) == [.dataResponse(format: 13, length: 0, data: Data())])
}

// MARK: Handshake and state machine (§5)

@Test func clipboardHandshakeWithFakeHost() {
    let h = Harness()
    h.feed(Host.initRequest(version: 3))
    #expect(h.take() == hex("02 00 00 00 03 00 00 00 00 00 00 00"))
    #expect(h.engine.phase == .awaitingNames)
    h.feed(Host.names([(0xC00D, "HTML Format"), (0xC00E, "Rich Text Format")]))
    #expect(h.take() == hex("09 00 00 00 0D C0 00 00 00 00 0E C0 00 00 00 00 00 00 00 00 00 00") + hex("03 00 0C 00"))
    #expect(h.engine.phase == .ready)
    #expect(h.engine.registeredId("HTML Format") == 0xC00D)
    // The empty list is sent once only.
    h.engine.announceLocal(ClipboardSnapshot(content: nil, takenAt: 2_000))
    #expect(h.take().isEmpty)

    // Version 1: no names, ready at once.
    let v1 = Harness()
    v1.feed(Host.initRequest(version: 1))
    #expect(v1.take() == hex("02 00 00 00 01 00 00 00 00 00 00 00 03 00 0C 00"))
    #expect(v1.engine.phase == .ready && v1.engine.version == 1)
    // Host version above 3 is capped.
    let v9 = Harness()
    v9.feed(Host.initRequest(version: 9))
    #expect(v9.engine.version == 3)
}

@Test func clipboardEagerFetchHostToMac() {
    let h = Harness()
    h.ready()
    h.clock = 5_000
    // Host copies text + HTML + RTF + a private format + a bitmap.
    h.feed(Host.list([0x0200, 2, 13, 0xC00D, 0xC010]))
    #expect(h.engine.hostFormats == [2, 13, 0xC00D, 0xC010])
    #expect(h.take() == ClipboardWire.dataRequest(format: 13))
    h.feed(Host.response(13, ClipboardText.encodeForHost("Hallo\nWelt")))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC00D))
    h.feed(Host.response(0xC00D, ClipboardHTML.build("<b>Hallo</b>")))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC010))
    h.feed(Host.failure)
    #expect(h.take().isEmpty)  // no bitmap: text is offered
    let (content, echo) = try! #require(h.hostClipboard)
    #expect(content.text == "Hallo\nWelt" && !echo)
    #expect(content.html == ClipboardHTML.macDocument(fragment: "<b>Hallo</b>"))
    #expect(content.rtf == nil && content.image == nil)

    // Bitmap only: fetched.
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 128])
    h.feed(Host.list([2]))
    #expect(h.take() == ClipboardWire.dataRequest(format: 2))
    h.feed(Host.response(2, ClipboardDIB.encode(width: 2, height: 1, rgba: pixels)!))
    #expect(h.hostClipboard?.0.image?.rgba() == pixels)

    // Host clipboard empty.
    h.feed(Host.emptyList)
    #expect(h.engine.hostFormats.isEmpty)
}

@Test func clipboardHostToMacOffMakesNoRequests() {
    var config = ClipboardEngine.Config()
    config.hostToMac = false
    let h = Harness(config)
    h.ready()
    h.feed(Host.list([13]))
    #expect(h.take().isEmpty)
    #expect(h.engine.hostFormats == [13])
}

@Test func clipboardRequestTimeoutMovesOn() {
    let h = Harness()
    h.ready()
    h.feed(Host.list([13, 0xC00D]))
    #expect(h.take() == ClipboardWire.dataRequest(format: 13))
    #expect(h.timers.count == 1 && h.timers[0].delay == 5)
    h.fireTimers()
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC00D))
    // The late text response is discarded; the HTML request keeps waiting.
    h.feed(Host.response(13, ClipboardText.encodeForHost("late")))
    #expect(h.engine.pendingRequest == 0xC00D)
    h.feed(Host.response(0xC00D, ClipboardHTML.build("x")))
    #expect(h.hostClipboard?.0.text == nil && h.hostClipboard?.0.html != nil)
    #expect(!h.engine.isFetching)
    // A stale timer of an answered request does nothing.
    h.fireTimers()
    #expect(h.take().isEmpty)
    #expect(h.events.contains { if case .fetchFailed(13, _) = $0 { return true }; return false })
}

@Test func clipboardNewHostListCancelsFetch() {
    let h = Harness()
    h.ready()
    h.feed(Host.list([13]))
    _ = h.take()
    h.feed(Host.list([13, 0xC00D]))
    #expect(h.take() == ClipboardWire.dataRequest(format: 13))
    // The host answers in order: the first answer belongs to the cancelled request.
    h.feed(Host.response(13, ClipboardText.encodeForHost("old")))
    #expect(h.take().isEmpty && h.engine.pendingRequest == 13)
    h.feed(Host.response(13, ClipboardText.encodeForHost("new")))
    _ = h.take()
    h.feed(Host.response(0xC00D, ClipboardHTML.build("<i>new</i>")))
    #expect(h.hostClipboard?.0.text == "new")
}

@Test func clipboardMacToHostServesSnapshot() {
    let h = Harness()
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "a\nb", html: "<p>a</p>"), takenAt: 2_000))
    #expect(h.take() == ClipboardWire.formatList([13, 0xC00D]))
    h.feed(Host.request(13))
    #expect(h.take() == ClipboardWire.dataResponse(format: 13, data: hex("61 00 0D 00 0A 00 62 00 00 00")))
    h.feed(Host.request(0xC00D))
    #expect(h.take() == ClipboardWire.dataResponse(format: 0xC00D, data: ClipboardHTML.build("<p>a</p>")))
    h.feed(Host.request(1))
    #expect(h.take() == ClipboardWire.dataFailure)
    // Unsolicited host response while we own the clipboard: discarded, our list re-asserted.
    h.feed(Host.response(13, ClipboardText.encodeForHost("x")))
    #expect(h.take() == ClipboardWire.formatList([13, 0xC00D]))
    // Image announced as CF_BITMAP and converted on request.
    var rendered = 0
    let image = ClipboardImage(width: 1, height: 1) { rendered += 1; return Data([1, 2, 3, 4]) }
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(image: image), takenAt: 3_000))
    #expect(h.take() == ClipboardWire.formatList([2]) && rendered == 0)
    h.feed(Host.request(2))
    h.feed(Host.request(2))
    #expect(rendered == 1)
    let dib = ClipboardDIB.encode(width: 1, height: 1, rgba: Data([1, 2, 3, 4]))!
    #expect(h.take() == ClipboardWire.dataResponse(format: 2, data: dib) + ClipboardWire.dataResponse(format: 2, data: dib))
    // Nothing usable → the empty form; and a registered format the host did not name is left out.
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "", rtf: Data()), takenAt: 4_000))
    #expect(h.take() == hex("03 00 0C 00"))
    h.feed(Host.request(13))
    #expect(h.take() == ClipboardWire.dataFailure)
}

@Test func clipboardMacToHostOffAnnouncesEmpty() {
    var config = ClipboardEngine.Config()
    config.macToHost = false
    let h = Harness(config)
    h.feed(Host.initRequest(version: 1))
    _ = h.take()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "secret"), takenAt: 2_000))
    #expect(h.take().isEmpty)  // empty list already sent at READY
    h.feed(Host.request(13))
    #expect(h.take() == ClipboardWire.dataFailure)
}

@Test func clipboardOrderingRules() {
    let h = Harness()
    // Before READY: kept and sent after the empty list.
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "early"), takenAt: 500))
    h.feed(Host.initRequest(version: 1))
    #expect(h.take() == ClipboardWire.initReply(version: 1) + hex("03 00 0C 00") + ClipboardWire.formatList([13]))

    // Snapshot older than the latest host list: dropped (host wins).
    h.clock = 10_000
    h.feed(Host.list([13]))
    _ = h.take()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "old"), takenAt: 9_000))
    #expect(h.take().isEmpty)
    // Newer snapshot during the fetch: deferred; then it wins and the host data is not delivered.
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "new"), takenAt: 11_000))
    #expect(h.take().isEmpty)
    h.events = []
    h.feed(Host.response(13, ClipboardText.encodeForHost("host")))
    #expect(h.hostClipboard == nil)
    #expect(h.take() == ClipboardWire.formatList([13]))
}

@Test func clipboardEchoIsFlagged() {
    let h = Harness()
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "same"), takenAt: 2_000))
    _ = h.take()
    h.clock = 3_000
    h.feed(Host.list([13]))
    h.feed(Host.response(13, ClipboardText.encodeForHost("same")))
    #expect(h.hostClipboard?.1 == true)
    h.feed(Host.list([13]))
    h.feed(Host.response(13, ClipboardText.encodeForHost("same")))
    #expect(h.hostClipboard?.1 == false)  // our announce was no longer current
}

@Test func clipboardUnknownCommandClearsHostList() {
    let h = Harness()
    h.ready()
    h.feed(Host.list([13]))
    _ = h.take()
    h.feed(Data([0x06, 0x00, 0x00, 0x00, 0x01, 0x02]))
    #expect(h.engine.hostFormats.isEmpty && !h.engine.isFetching)
    #expect(h.events.contains { if case .protocolError = $0 { return true }; return false })
    // A late response afterwards is just unsolicited.
    h.feed(Host.response(13, ClipboardText.encodeForHost("x")))
    #expect(h.hostClipboard == nil)
}

@Test func clipboardOutputIsPacedByBacklog() {
    var config = ClipboardEngine.Config()
    config.backlogLimit = 100
    let h = Harness(config)
    var backlog = 0
    h.engine.backlog = { backlog }
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: String(repeating: "y", count: 2000)), takenAt: 2_000))
    _ = h.take()
    backlog = 1_000
    h.feed(Host.request(13))
    h.feed(Host.request(1))   // its failure must stay behind the big response
    #expect(h.writes.count == 0)
    backlog = 0
    h.fireTimers()
    let stream = h.take()
    #expect(stream == ClipboardWire.dataResponse(format: 13, data: ClipboardText.encodeForHost(String(repeating: "y", count: 2000))) + ClipboardWire.dataFailure)
}

// MARK: Text (§4.3)

@Test func clipboardTextConversions() {
    #expect(ClipboardText.encodeForHost("") == Data([0, 0]))
    #expect(ClipboardText.decodeHost(Data([0, 0])) == "")
    #expect(ClipboardText.decodeHost(Data()) == "")
    #expect(ClipboardText.encodeForHost("a\nb\r\nc\rd") == hex("61 00 0D 00 0A 00 62 00 0D 00 0A 00 63 00 0D 00 0A 00 64 00 00 00"))
    #expect(ClipboardText.encodeForHost("\n\n") == hex("0D 00 0A 00 0D 00 0A 00 00 00"))
    #expect(ClipboardText.decodeHost(hex("61 00 0D 00 0A 00 62 00 0D 00 63 00")) == "a\nb\rc")
    // Cut at the first NUL; the engine's double NUL and garbage after it are ignored; an odd byte too.
    #expect(ClipboardText.decodeHost(hex("41 00 00 00 00 00 42 00")) == "A")
    #expect(ClipboardText.decodeHost(hex("41 00 42")) == "A")
    // Non-BMP: surrogate pairs pass through both ways.
    let emoji = "x😀ä"
    #expect(ClipboardText.encodeForHost(emoji) == hex("78 00 3D D8 00 DE E4 00 00 00"))
    #expect(ClipboardText.decodeHost(ClipboardText.encodeForHost(emoji)) == emoji)
    // A lone surrogate becomes U+FFFD.
    #expect(ClipboardText.decodeHost(hex("3D D8 41 00")) == "\u{FFFD}A")
    let round = "Zeile 1\nZeile 2\n\nÄÖÜ €"
    #expect(ClipboardText.decodeHost(ClipboardText.encodeForHost(round)) == round)
}

// MARK: HTML (§4.4)

@Test func clipboardHTMLHeaderOffsets() throws {
    let data = ClipboardHTML.build("Grüße <b>€</b>")
    let bytes = [UInt8](data)
    let header = String(decoding: bytes.prefix(100), as: UTF8.self)
    #expect(header == "Version:0.9\nStartHTML:0000000100\nEndHTML:\(String(format: "%010d", bytes.count))\n"
        + "StartFragment:0000000132\nEndFragment:\(String(format: "%010d", bytes.count - 32))\n")
    let fields = ClipboardHTML.parseHeader(bytes)
    let s = try #require(fields["StartFragment"]), e = try #require(fields["EndFragment"])
    #expect(String(decoding: bytes[s..<e], as: UTF8.self) == "Grüße <b>€</b>")
    #expect(String(decoding: bytes[(e)..<(e + 18)], as: UTF8.self) == "<!--EndFragment-->")
    #expect(String(decoding: bytes[100..<106], as: UTF8.self) == "<html>")
    #expect(bytes.last != 0)
    #expect(ClipboardHTML.fragment(data) == "Grüße <b>€</b>")

    // Non-ASCII before the fragment: true byte offsets.
    let doc = "<html><head><title>Ä</title></head><body class=\"x\"><!--StartFragment-->ö<!--EndFragment--></body></html>"
    let built = ClipboardHTML.build(doc)
    #expect(ClipboardHTML.fragment(built) == "ö")
    // Full document without markers: inserted after <body…> and before </body>.
    #expect(ClipboardHTML.fragment(ClipboardHTML.build("<HTML><Body bgcolor=x>ü</BODY></HTML>")) == "ü")
}

@Test func clipboardHTMLParsingFallbacks() {
    // Word-style CRLF header with a trailing NUL.
    let body = "<html><body><!--StartFragment--><p>Hi</p><!--EndFragment--></body></html>"
    let headerTemplate = "Version:0.9\r\nStartHTML:%08d\r\nEndHTML:%08d\r\nStartFragment:%08d\r\nEndFragment:%08d\r\n"
    let headerLength = String(format: headerTemplate, 0, 0, 0, 0).utf8.count
    let start = headerLength + body.utf8.count - "<p>Hi</p><!--EndFragment--></body></html>".utf8.count
    let header = String(format: headerTemplate, headerLength, headerLength + body.utf8.count, start, start + 9)
    #expect(ClipboardHTML.fragment(Data((header + body).utf8) + Data([0])) == "<p>Hi</p>")
    // Bad offsets: the markers decide.
    #expect(ClipboardHTML.fragment(Data(("Version:0.9\nStartFragment:9999\nEndFragment:5\n" + body).utf8)) == "<p>Hi</p>")
    // No header, no markers: the document.
    #expect(ClipboardHTML.fragment(Data("<b>x</b>".utf8)) == "<b>x</b>")
    #expect(ClipboardHTML.fragment(Data([0, 0])) == nil)
}

// MARK: RTF and DIB (§4.5)

@Test func clipboardRTFNul() {
    #expect(ClipboardRTF.encodeForHost(Data("{\\rtf1}".utf8)) == Data("{\\rtf1}".utf8) + Data([0]))
    #expect(ClipboardRTF.decodeHost(Data("{\\rtf1}".utf8) + Data([0, 0])) == Data("{\\rtf1}".utf8))
}

@Test func clipboardDIBRoundTripAndVariants() throws {
    // 2×2 RGBA, top-down: red, green / blue, half-transparent white.
    let rgba = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128])
    let dib = try #require(ClipboardDIB.encode(width: 2, height: 2, rgba: rgba))
    #expect(dib.count == 52 + 16)
    #expect(dib.prefix(20) == hex("28 00 00 00 02 00 00 00 02 00 00 00 01 00 20 00 03 00 00 00"))
    #expect(dib.subdata(in: 40..<52) == hex("00 00 FF 00 00 FF 00 00 FF 00 00 00"))
    // Bottom-up B G R A: the first stored row is the last image row (blue, white).
    #expect(dib.subdata(in: 52..<60) == hex("FF 00 00 FF FF FF FF 80"))
    let back = try ClipboardDIB.decode(dib)
    #expect(back.width == 2 && back.height == 2 && back.rgba() == rgba)

    // 24 bpp BI_RGB, width 1 → rows padded to 4 bytes.
    var w = ByteWriter()
    w.u32(40); w.u32(1); w.u32(2); w.u16(1); w.u16(24); w.u32(0); w.raw([UInt8](repeating: 0, count: 20))
    w.raw([0x01, 0x02, 0x03, 0x00, 0x0A, 0x0B, 0x0C, 0x00])
    let rgb = try ClipboardDIB.decode(w.data)
    #expect(rgb.rgba() == Data([0x0C, 0x0B, 0x0A, 0xFF, 0x03, 0x02, 0x01, 0xFF]))

    // 32 bpp BI_RGB with every alpha 0: opaque.
    var z = ByteWriter()
    z.u32(40); z.u32(1); z.u32(1); z.u16(1); z.u16(32); z.u32(0); z.raw([UInt8](repeating: 0, count: 20))
    z.raw([0x10, 0x20, 0x30, 0x00])
    #expect(try ClipboardDIB.decode(z.data).rgba() == Data([0x30, 0x20, 0x10, 0xFF]))

    // Top-down (negative height) accepted.
    var t = ByteWriter()
    t.u32(40); t.u32(1); t.u32(UInt32(bitPattern: -2)); t.u16(1); t.u16(32); t.u32(0); t.raw([UInt8](repeating: 0, count: 20))
    t.raw([1, 2, 3, 255, 4, 5, 6, 255])
    #expect(try ClipboardDIB.decode(t.data).rgba() == Data([3, 2, 1, 255, 6, 5, 4, 255]))

    // Rejected: palette images, RLE, wrong header size, truncation.
    var pal = ByteWriter()
    pal.u32(40); pal.u32(1); pal.u32(1); pal.u16(1); pal.u16(8); pal.u32(0); pal.raw([UInt8](repeating: 0, count: 24))
    #expect(throws: ClipboardDIB.Failure.bitCount(8)) { try ClipboardDIB.decode(pal.data) }
    #expect(throws: ClipboardDIB.Failure.header(12)) { try ClipboardDIB.decode(Data([12] + [UInt8](repeating: 0, count: 39))) }
    #expect(throws: ClipboardDIB.Failure.truncated) { try ClipboardDIB.decode(dib.prefix(60)) }
}

// MARK: Pasteboard sync and loop prevention (§5.4, §5.6)

private final class FakePasteboard: ClipboardPasteboard {
    var changeCount = 1
    var content: ClipboardContent?
    var reads = 0
    func readContent() -> ClipboardContent? { reads += 1; return content }
    func writeContent(_ content: ClipboardContent) -> Int {
        self.content = content
        changeCount += 1
        return changeCount
    }
    func userCopies(_ text: String) {
        content = ClipboardContent(text: text)
        changeCount += 1
    }
}

@Test func clipboardSyncLoopPrevention() {
    let board = FakePasteboard()
    board.content = ClipboardContent(text: "at start")
    let sync = ClipboardSync(pasteboard: board)
    var sent: [String?] = []
    sync.announce = { sent.append($0.content?.text) }

    #expect(!sync.check("before ready"))
    sync.channelReady()
    #expect(sent == ["at start"])
    #expect(!sync.check("poll"))                   // unchanged
    board.userCopies("mac copy")
    #expect(sync.check("paste key"))
    #expect(sent == ["at start", "mac copy"])

    // Host data written: our own change count is never announced.
    #expect(sync.hostContent(ClipboardContent(text: "from host")))
    #expect(board.content?.text == "from host")
    #expect(!sync.check("poll"))
    #expect(sent.count == 2 && board.reads == 2)

    // The Mac changed before host data arrived: the Mac copy is kept and announced.
    board.userCopies("newer mac copy")
    #expect(!sync.hostContent(ClipboardContent(text: "host again")))
    #expect(board.content?.text == "newer mac copy")
    #expect(sent.last == "newer mac copy")

    // Echo: left alone.
    #expect(!sync.hostContent(ClipboardContent(text: "newer mac copy"), echo: true))
    // Concealed items read as nil and go out as an empty snapshot.
    board.content = nil
    board.changeCount += 1
    #expect(sync.check("poll"))
    #expect(sent.last == .some(nil))
}

@Test func clipboardSyncAndEngineEndToEnd() {
    let h = Harness()
    let board = FakePasteboard()
    let sync = ClipboardSync(pasteboard: board)
    sync.now = { h.clock }
    sync.announce = { h.engine.announceLocal($0) }
    h.ready()
    sync.channelReady()
    #expect(h.take().isEmpty)                       // empty pasteboard: the empty list was already sent
    board.userCopies("x")
    h.clock = 2_000
    sync.check("poll")
    #expect(h.take() == ClipboardWire.formatList([13]))
    // Host copy → fetched → written → not announced back.
    h.clock = 3_000
    h.feed(Host.list([13]))
    h.feed(Host.response(13, ClipboardText.encodeForHost("host text")))
    let (content, echo) = try! #require(h.hostClipboard)
    _ = h.take()
    #expect(sync.hostContent(content, echo: echo))
    #expect(!sync.check("poll"))
    #expect(h.take().isEmpty)
}

@Test func clipboardEventDescriptionsCarryNoContents() {
    let secret = "geheim-123"
    let h = Harness()
    h.feed(Host.initRequest(version: 3))
    h.feed(Host.names([(0xC00D, "HTML Format")]))
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: secret, html: "<b>\(secret)</b>"), takenAt: 2_000))
    h.feed(Host.request(13))
    h.feed(Host.request(0xC00D))
    h.clock = 3_000
    h.feed(Host.list([13, 0xC00D]))
    h.feed(Host.response(13, ClipboardText.encodeForHost(secret)))
    h.feed(Host.response(0xC00D, ClipboardHTML.build(secret)))
    let text = h.events.map(\.description).joined(separator: "\n")
    #expect(text.contains("0xC00D \"HTML Format\" (12 B)"))
    #expect(text.contains("host clipboard ready"))
    #expect(!text.contains(secret))
}

// MARK: Round 2: live findings and review fixes

/// Live (host version 4): right after a host DATA_REQUEST the parser met command 0x0000. Read as a request
/// longer than 8 bytes with zero padding (12 bytes here): the zeros are skipped and reported, nothing desyncs.
@Test func clipboardLongDataRequestIsTolerated() {
    var p = ClipboardStreamParser()
    let request12 = hex("04 00 00 00 0D 00 00 00 00 00 00 00")
    let out = p.feed(request12 + Host.list([13]))
    #expect(out == [.dataRequest(flags: 0, format: 13), .padding(bytes: 4, previous: request12.prefix(8)), .formatList(flags: 1, formats: [13])])
    // Padding split over VC writes.
    var q = ClipboardStreamParser()
    #expect(q.feed(request12.prefix(10)) == [.dataRequest(flags: 0, format: 13), .padding(bytes: 2, previous: request12.prefix(8))])
    #expect(q.feed(request12.suffix(2) + Host.request(2)) == [.padding(bytes: 2, previous: request12.prefix(8)), .dataRequest(flags: 0, format: 2)])

    // Engine: served, then the next message is handled; the skip is logged with the header it followed.
    let h = Harness()
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "x"), takenAt: 2_000))
    _ = h.take()
    h.feed(request12)
    h.feed(Host.list([13]))
    #expect(!h.events.contains { if case .protocolError = $0 { return true }; return false })
    #expect(h.events.map(\.description).contains("skipped 4 zero bytes after [04 00 00 00 0d 00 00 00]"))
    #expect(h.engine.hostFormats == [13])
}

@Test func clipboardProtocolErrorShowsHeaderBytes() {
    let h = Harness()
    h.ready()
    h.feed(Host.request(13) + hex("07 00 34 12 AA BB"))
    let text = h.events.map(\.description).joined(separator: "\n")
    #expect(text.contains("unknown command 0x0007, flags 0x1234, bytes [07 00 34 12 aa bb], after [04 00 00 00 0d 00 00 00]"))
    // After a DATA_RESPONSE only its 10 header bytes are shown, never payload.
    let k = Harness()
    k.ready()
    k.feed(Host.list([13]))
    k.feed(Host.response(13, Data("SECRET".utf16.flatMap { [UInt8($0), 0] } + [0, 0])) + hex("09 00 00 00"))
    let shown = k.events.map(\.description).joined(separator: "\n")
    #expect(shown.contains("after [05 00 00 00 0d 00 0e 00 00 00]"))
    #expect(!shown.contains("53 00"))
}

@Test func clipboardLargePayloadIsLinear() {
    var p = ClipboardStreamParser()
    let size = 8 << 20
    let chunk = Data(repeating: 0x5A, count: 1000)
    let start = DispatchTime.now().uptimeNanoseconds
    var out = p.feed(Host.response(13, Data()).prefix(6) + Host.u32(UInt32(size)).withUnsafeBufferPointer { Data($0) })
    var sent = 0
    while sent < size {
        let n = min(1000, size - sent)
        out += p.feed(n == 1000 ? chunk : chunk.prefix(n))
        sent += n
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    #expect(out.count == 1)
    if case .dataResponse(_, let length, let data) = out.first { #expect(length == size && data?.count == size) }
    #expect(seconds < 0.5, "8 MiB in 1000-B pieces took \(seconds) s")
}

@Test func clipboardTimeoutWaitsWhileBytesFlow() {
    let h = Harness()
    h.ready()
    h.feed(Host.list([13, 0xC00D]))
    #expect(h.take() == ClipboardWire.dataRequest(format: 13))
    let body = ClipboardText.encodeForHost(String(repeating: "z", count: 100))
    let message = Host.response(13, body)
    h.clock += 1_000_000_000
    h.feed(message.prefix(50))
    h.fireTimers()                     // bytes arrived since the timer was armed: re-armed
    #expect(h.take().isEmpty && h.engine.pendingRequest == 13 && h.timers.count == 1)
    h.clock += 1_000_000_000
    h.feed(message.dropFirst(50))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC00D))
    #expect(h.hostClipboard == nil)
    // Nothing more arrives: the HTML request times out.
    h.clock += 6_000_000_000
    h.timers.removeFirst()             // the text request's (stale) timer
    h.fireTimers()
    #expect(h.hostClipboard?.0.text == String(repeating: "z", count: 100))
}

@Test func clipboardLateFailureAfterNewListIsDiscarded() {
    let h = Harness()
    h.ready()
    h.feed(Host.list([13]))
    #expect(h.take() == ClipboardWire.dataRequest(format: 13))
    h.feed(Host.list([13, 0xC00D]))   // cancels the first fetch; a second request for 13 goes out
    #expect(h.take() == ClipboardWire.dataRequest(format: 13))
    h.feed(Host.failure)              // answers the first request
    #expect(h.engine.pendingRequest == 13)
    #expect(h.events.contains { if case .lateResponse(nil, _, 13) = $0 { return true }; return false })
    h.feed(Host.response(13, ClipboardText.encodeForHost("second")))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC00D))
    h.feed(Host.response(0xC00D, ClipboardHTML.build("<i>2</i>")))
    #expect(h.hostClipboard?.0.text == "second" && h.hostClipboard?.0.html != nil)

    // A late success for a timed-out request of another format: discarded, the pending one waits.
    h.feed(Host.list([13, 0xC00D]))
    _ = h.take()
    h.fireTimers()                    // 13 times out → HTML requested
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC00D))
    h.feed(Host.response(13, ClipboardText.encodeForHost("late")))
    #expect(h.engine.pendingRequest == 0xC00D)
    // Stale entries are forgotten after three timeouts: a much later failure is unsolicited... or for the
    // pending request when that is the only one left.
    h.clock += 20_000_000_000
    h.feed(Host.failure)
    #expect(h.engine.pendingRequest == nil && !h.engine.isFetching)
}

@Test func clipboardControlGoesAheadOfPacedData() {
    var config = ClipboardEngine.Config()
    config.backlogLimit = 100
    let h = Harness(config)
    var backlog = 0
    h.engine.backlog = { backlog }
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: String(repeating: "y", count: 2000)), takenAt: 2_000))
    _ = h.take()
    h.feed(Host.request(13))
    #expect(h.writes.count == 4)                 // started while the backlog was low
    _ = h.take()
    backlog = 1_000
    h.feed(Host.request(13))                     // second response: waits
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "new"), takenAt: 3_000))
    #expect(h.take() == ClipboardWire.formatList([13]))   // the list goes first
    backlog = 0
    h.fireTimers()
    // The held response carries the snapshot that was current when the host asked.
    #expect(h.take() == ClipboardWire.dataResponse(format: 13, data: ClipboardText.encodeForHost(String(repeating: "y", count: 2000))))
}

@Test func clipboardReinitClearsHostStateAndKeepsRegisteredNames() {
    let h = Harness()
    h.feed(Host.initRequest(version: 3))
    h.feed(Host.names([(0x0005, "Odd"), (0xC00D, "HTML Format")]))
    #expect(h.engine.formatNames.map(\.id) == [0xC00D])
    #expect(h.take().suffix(22 + 4) == ClipboardWire.formatNamesReply(ids: [0x0005, 0xC00D]) + ClipboardWire.emptyFormatList)
    h.feed(Host.list([13]))
    #expect(h.engine.hostFormats == [13])
    h.feed(Host.initRequest(version: 3))
    #expect(h.engine.formatNames.isEmpty && h.engine.hostFormats.isEmpty && h.engine.phase == .awaitingNames)
}

@Test func clipboardSyncSkipsReadsWhenMacToHostOff() {
    let board = FakePasteboard()
    board.content = ClipboardContent(text: "private")
    let sync = ClipboardSync(pasteboard: board)
    sync.readsContent = false
    var sent: [ClipboardSnapshot] = []
    sync.announce = { sent.append($0) }
    sync.channelReady()
    #expect(board.reads == 0 && sent.count == 1 && sent[0].content == nil)
}
