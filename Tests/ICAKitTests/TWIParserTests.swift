import Testing
import Foundation
@testable import ICAKit

// Helpers that build host -> client messages byte by byte (independent of the parser).
enum TWIFixture {
    static func frame(_ type: UInt8, _ payload: [UInt8]) -> Data {
        Data([type, UInt8(payload.count & 0xff), UInt8(payload.count >> 8)] + payload)
    }
    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> UInt32(8 * $0)) & 0xff) } }
    static func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
    static func rect(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) -> [UInt8] { i32(l) + i32(t) + i32(r) + i32(b) }
    static func str(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

    static func hostInit(version: UInt8 = 3, w: Int16 = 1920, h: Int16 = 1080, flags: UInt32) -> Data {
        var p = [UInt8](repeating: 0, count: 17)
        p[0] = 2; p[4] = version
        p[8] = UInt8(w & 0xff); p[9] = UInt8(w >> 8); p[10] = UInt8(h & 0xff); p[11] = UInt8(h >> 8)
        p.replaceSubrange(13..<17, with: u32(flags))
        return frame(0x01, p)
    }
    static let open = frame(0x02, [])
    static let close = frame(0x03, [])

    static func createV1(type: UInt8 = 0x0a, id: UInt32, flags: UInt16 = 0, style: UInt32, ex: UInt32 = 0,
                         rect r: [UInt8] = rect(10, 20, 410, 320), owner: UInt32 = 0, title: String? = nil) -> Data {
        var p = u32(id) + u16(flags) + u32(style) + u32(ex) + r + rect(11, 21, 409, 319) + u32(owner)
        if let t = title { p += str(t) }
        return frame(type, p)
    }

    static func createV2(id: UInt32, style: UInt32, ex: UInt32 = 0, owner: UInt32 = 0, pid: UInt32,
                         flags: UInt16 = 0, title: String, appId: String) -> Data {
        let titleOff = 58, idOff = 58 + title.utf8.count + 1
        var p = u32(id) + u32(style) + u32(ex) + rect(0, 0, 100, 50) + rect(1, 1, 99, 49) + u32(owner) + u32(pid)
        p += u16(flags) + u16(UInt16(titleOff)) + u16(UInt16(idOff)) + str(title) + str(appId)
        return frame(0x3f, p)
    }

    static func change(id: UInt32, mask: UInt32, flags: UInt16 = 0, style: UInt32? = nil, ex: UInt32? = nil,
                       window: [UInt8]? = nil, client: [UInt8]? = nil, owner: UInt32? = nil, above: UInt32? = nil,
                       title: String? = nil) -> Data {
        var p = u32(id) + u32(mask) + u16(flags)
        if let s = style { p += u32(s) }
        if let e = ex { p += u32(e) }
        if let w = window { p += w }
        if let c = client { p += c }
        if let o = owner { p += u32(o) }
        if let a = above { p += u32(a) }
        if let t = title { p += str(t) }
        return frame(0x0c, p)
    }

    static func destroy(_ id: UInt32) -> Data { frame(0x0b, u32(id)) }
    static func foreground(_ id: UInt32) -> Data { frame(0x14, u32(id)) }

    static func processCreated(pid: UInt32, parent: UInt32, a: String = "", exe: String, app: String) -> Data {
        let offA = 16, offB = offA + a.utf8.count + 1, offC = offB + exe.utf8.count + 1
        let p = u16(UInt16(offA)) + u16(UInt16(offB)) + u16(UInt16(offC)) + u32(pid) + u32(parent) + u16(0)
            + str(a) + str(exe) + str(app)
        return frame(0x40, p)
    }

    static let visible: UInt32 = 0x1000_0000
    static let caption: UInt32 = 0x00C0_0000
}

private func collect(_ engine: SeamlessEngine) -> (events: Box<[SeamlessEvent]>, sent: Box<[Data]>) {
    let events = Box<[SeamlessEvent]>([]), sent = Box<[Data]>([])
    engine.onEvent = { events.value.append($0) }
    engine.output = { if case .channel(let d) = $0 { sent.value.append(d) } }
    return (events, sent)
}

final class Box<T> { var value: T; init(_ v: T) { value = v } }

private func openEngine(hostFlags: UInt32 = 0x0001_0810, config: SeamlessEngine.Config = .init()) -> (SeamlessEngine, Box<[SeamlessEvent]>, Box<[Data]>) {
    let engine = SeamlessEngine(config: config)
    let (e, s) = collect(engine)
    engine.receive(TWIFixture.hostInit(flags: hostFlags))
    engine.receive(TWIFixture.open)
    return (engine, e, s)
}

// MARK: - Framing and parsers

@Test func channelNameAndNumber() {
    #expect(SeamlessEngine().channelName == "CTXTWI\0")
    #expect(SeamlessEngine.channelNumber == 12)
}

@Test func framerHandlesSplitAndCoalescedMessages() {
    var framer = TWIStreamFramer()
    let a = TWIFixture.frame(0x14, TWIFixture.u32(7))
    let b = TWIFixture.frame(0x02, [])
    let c = TWIFixture.frame(0x0b, TWIFixture.u32(9))
    let stream = a + b + c
    var out: [TWIStreamFramer.Frame] = []
    for byte in stream { out += framer.feed(Data([byte])) }
    #expect(out.map(\.type) == [0x14, 0x02, 0x0b])
    #expect(out[0].payload == Data(TWIFixture.u32(7)))
    #expect(framer.pendingBytes == 0)
    // Header split inside the length, then all remaining at once.
    var f2 = TWIStreamFramer()
    #expect(f2.feed(stream.prefix(2)).isEmpty)
    #expect(f2.feed(stream.dropFirst(2)).count == 3)
}

@Test func parseHostInit() throws {
    let f = TWIFixture.hostInit(version: 3, w: 2560, h: 1440, flags: 0x0001_0810)
    var framer = TWIStreamFramer()
    let msg = try TWIMessageParser.parse(framer.feed(f)[0], utf8: false)
    guard case .hostInit(let h) = msg else { Issue.record("not host init"); return }
    #expect(h.hostVersion == 3 && h.captionGeneration == 2)
    #expect(h.desktopWidth == 2560 && h.desktopHeight == 1440)
    #expect(h.flags == [.utf8, .monitorLayout, .extendedInfo])
}

@Test func parseCreateV1WithAndWithoutTitle() throws {
    let with = TWIFixture.createV1(id: 0x1234, flags: 4, style: 0x1ccf_0000, ex: 0x100, owner: 5, title: "Notepad")
    var framer = TWIStreamFramer()
    guard case .create(let c) = try TWIMessageParser.parse(framer.feed(with)[0], utf8: false) else { Issue.record(); return }
    #expect(c.id == 0x1234 && c.flags == 4 && c.style == 0x1ccf_0000 && c.exStyle == 0x100 && c.ownerId == 5)
    #expect(c.windowRect == TWIRect(left: 10, top: 20, right: 410, bottom: 320))
    #expect(c.clientRect == TWIRect(left: 11, top: 21, right: 409, bottom: 319))
    #expect(c.title == "Notepad" && c.source == .v1 && c.processId == nil)

    let without = TWIFixture.createV1(type: 0x17, id: 2, style: 0x9000_0000)
    guard case .create(let m) = try TWIMessageParser.parse(framer.feed(without)[0], utf8: false) else { Issue.record(); return }
    #expect(m.source == .menu && m.title == nil)
}

@Test func parseCreateV2() throws {
    let f = TWIFixture.createV2(id: 9, style: TWIFixture.visible, ex: 0x40, owner: 3, pid: 4242, flags: 8, title: "Doc1", appId: "Microsoft.Word")
    var framer = TWIStreamFramer()
    guard case .create(let c) = try TWIMessageParser.parse(framer.feed(f)[0], utf8: true) else { Issue.record(); return }
    #expect(c.source == .v2 && c.id == 9 && c.processId == 4242 && c.ownerId == 3 && c.flags == 8)
    #expect(c.title == "Doc1" && c.appId == "Microsoft.Word")
    #expect(c.windowRect == TWIRect(left: 0, top: 0, right: 100, bottom: 50))
    #expect(c.clientRect.width == 98)
}

@Test func parseChangeFieldOrder() throws {
    let f = TWIFixture.change(id: 5, mask: 0x7f, flags: 3, style: 0x11, ex: 0x22, window: TWIFixture.rect(1, 2, 3, 4),
                              client: TWIFixture.rect(5, 6, 7, 8), owner: 99, above: 77, title: "T")
    var framer = TWIStreamFramer()
    guard case .change(let c) = try TWIMessageParser.parse(framer.feed(f)[0], utf8: false) else { Issue.record(); return }
    #expect(c.id == 5 && c.flags == 3 && c.style == 0x11 && c.exStyle == 0x22)
    #expect(c.windowRect == TWIRect(left: 1, top: 2, right: 3, bottom: 4))
    #expect(c.clientRect == TWIRect(left: 5, top: 6, right: 7, bottom: 8))
    #expect(c.ownerId == 99 && c.windowAbove == 77 && c.title == "T")
    // Title only.
    let t = TWIFixture.change(id: 5, mask: 0x01, title: "Späť")
    guard case .change(let c2) = try TWIMessageParser.parse(framer.feed(t)[0], utf8: true) else { Issue.record(); return }
    #expect(c2.title == "Späť" && c2.style == nil && c2.windowRect == nil)
}

@Test func latin1StringsWithoutUTF8() throws {
    let f = TWIFixture.change(id: 1, mask: 0x01, title: "x")
    var raw = [UInt8](f); raw.removeLast(2); raw += [0xe4, 0]   // "ä" in Latin-1
    raw[1] = UInt8(raw.count - 3)
    var framer = TWIStreamFramer()
    guard case .change(let c) = try TWIMessageParser.parse(framer.feed(Data(raw))[0], utf8: false) else { Issue.record(); return }
    #expect(c.title == "ä")
}

@Test func parseSimpleMessages() throws {
    func parse(_ d: Data) throws -> TWIHostMessage {
        var f = TWIStreamFramer(); return try TWIMessageParser.parse(f.feed(d)[0], utf8: false)
    }
    #expect(try parse(TWIFixture.destroy(0xdead)) == .destroy(windowId: 0xdead))
    #expect(try parse(TWIFixture.foreground(0)) == .foreground(windowId: 0))
    #expect(try parse(TWIFixture.open) == .open)
    #expect(try parse(TWIFixture.close) == .close)
    #expect(try parse(TWIFixture.frame(0x3a, [])) == .metricsAck)
    #expect(try parse(TWIFixture.frame(0x41, TWIFixture.u32(77) + TWIFixture.u16(2))) == .processEnded(processId: 77, flags: 2))
    #expect(try parse(TWIFixture.frame(0x19, TWIFixture.u32(3) + TWIFixture.rect(1, 2, 3, 4)))
            == .windowRect(windowId: 3, rect: TWIRect(left: 1, top: 2, right: 3, bottom: 4)))
    #expect(try parse(TWIFixture.frame(0x0e, TWIFixture.u32(3) + TWIFixture.u32(1) + [9, 8, 7]))
            == .windowIcon(windowId: 3, iconType: 1, blob: Data([9, 8, 7])))
    let rl = TWIFixture.frame(0x33, TWIFixture.u16(0) + TWIFixture.u32(6) + TWIFixture.u32(2) + TWIFixture.u32(0)
                              + TWIFixture.rect(0, 0, 1, 1) + TWIFixture.rect(2, 2, 3, 3))
    #expect(try parse(rl) == .rectList(windowId: 6, rects: [TWIRect(left: 0, top: 0, right: 1, bottom: 1), TWIRect(left: 2, top: 2, right: 3, bottom: 3)]))
    #expect(try parse(TWIFixture.frame(0x99, [1, 2, 3])) == .unknown(type: 0x99, length: 3))
    #expect(throws: TWIParseError.malformed(type: 0x0b)) { try parse(TWIFixture.frame(0x0b, [1, 2])) }
}

@Test func parseSystemMetrics() throws {
    var p = TWIFixture.u32(0xAABB)
    for i in 0..<22 { p += TWIFixture.u16(UInt16(bitPattern: Int16(i == 16 ? 23 : i == 18 ? -5 : i))) }
    // Offsets are relative to the string area at 54. Area = "\0u\0zz\0".
    p += TWIFixture.u16(0) + TWIFixture.u16(1) + TWIFixture.u16(3)
    p += TWIFixture.str("") + TWIFixture.str("u") + TWIFixture.str("zz")
    var framer = TWIStreamFramer()
    guard case .systemMetrics(let m) = try TWIMessageParser.parse(framer.feed(TWIFixture.frame(0x0d, p))[0], utf8: false) else { Issue.record(); return }
    #expect(m.firstWord == 0xAABB && m.metrics.count == 22)
    #expect(m.captionHeight == 23 && m.captionButtonWidth == -5)
    #expect(m.strings == ["", "u", "zz"])
}

@Test func iconChunkParsingAndReassembly() throws {
    func chunk(flags: UInt16, total: UInt32?, data: [UInt8], type: UInt32 = 1) -> TWIIconChunk {
        let hdr = total == nil ? 18 : 22
        var p = TWIFixture.u32(5) + TWIFixture.u32(6) + TWIFixture.u32(type) + TWIFixture.u16(flags)
            + TWIFixture.u16(UInt16(hdr)) + TWIFixture.u16(UInt16(data.count))
        if let t = total { p += TWIFixture.u32(t) }
        p += data
        var f = TWIStreamFramer()
        guard case .iconChunk(let c) = try! TWIMessageParser.parse(f.feed(TWIFixture.frame(0x3e, p))[0], utf8: false) else { fatalError() }
        return c
    }
    let first = chunk(flags: 0xC0, total: 6, data: [1, 2])
    #expect(first.isFirst && first.hasMore && first.totalSize == 6 && first.data == Data([1, 2]))
    let mid = chunk(flags: 0x80, total: nil, data: [3, 4])
    let last = chunk(flags: 0x00, total: nil, data: [5, 6])
    var asm = TWIChunkAssembler()
    #expect(asm.add(first) == nil)
    #expect(asm.add(mid) == nil)
    let done = asm.add(last)
    #expect(done?.blob == Data([1, 2, 3, 4, 5, 6]) && done?.windowId == 5 && done?.iconType == 1)
    #expect(asm.pendingCount == 0)
    // Single-message icon.
    #expect(asm.add(chunk(flags: 0, total: nil, data: [9]))?.blob == Data([9]))
}

@Test func parseProcessCreated() throws {
    var f = TWIStreamFramer()
    let d = TWIFixture.processCreated(pid: 100, parent: 4, a: "cmd", exe: "C:\\Windows\\notepad.exe", app: "x#Notepad")
    guard case .processCreated(let p) = try TWIMessageParser.parse(f.feed(d)[0], utf8: false) else { Issue.record(); return }
    #expect(p.processId == 100 && p.parentId == 4)
    #expect(p.stringA == "cmd" && p.executablePath == "C:\\Windows\\notepad.exe" && p.appName == "x#Notepad")
}

// MARK: - Builders

@Test func requestBuildersBytes() {
    #expect(TWIRequest.clientInit(flags: [.bit4, .bit8, .utf8]) == Data([0x01, 8, 0, 0, 3, 2, 0, 0x0c, 0x10, 0, 0]))
    #expect(TWIRequest.clientInit(seamless: false, flags: [.bit4]) == Data([0x01, 8, 0, 0, 3, 2, 1, 0x04, 0, 0, 0]))
    #expect(TWIRequest.pause() == Data([0x05, 0, 0]))
    #expect(TWIRequest.resume() == Data([0x06, 0, 0]))
    #expect(TWIRequest.logoff() == Data([0x33, 0, 0]))
    #expect(TWIRequest.activate(windowId: 0x01020304) == Data([0x0b, 4, 0, 4, 3, 2, 1]))
    #expect(TWIRequest.activate(windowId: 0) == Data([0x0b, 4, 0, 0, 0, 0, 0]))
    #expect(TWIRequest.restore(windowId: 1) == Data([0x0c, 4, 0, 1, 0, 0, 0]))
    #expect(TWIRequest.close(windowId: 1) == Data([0x0e, 4, 0, 1, 0, 0, 0]))
    #expect(TWIRequest.closeAlt(windowId: 1) == Data([0x3c, 4, 0, 1, 0, 0, 0]))
    #expect(TWIRequest.resendWindow(windowId: 2) == Data([0x14, 4, 0, 2, 0, 0, 0]))
    let mr = TWIRequest.moveResize(windowId: 7, rect: TWIRect(left: -1, top: 2, right: 3, bottom: 4))
    #expect(mr == Data([0x0a, 20, 0, 7, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0]))
    let min = TWIRequest.minimize(windowId: 9)
    #expect(min == Data([0x36, 20, 0, 9, 0, 0, 0, 0x12, 0x01, 0, 0, 0x20, 0xF0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    #expect(TWIRequest.maximize(windowId: 9)[11...14] == Data([0x30, 0xF0, 0, 0]))
}

@Test func clientMetricsLayout() {
    let m = TWIRequest.clientMetrics(workArea: TWIRect(left: 0, top: 25, right: 1920, bottom: 1080))
    #expect(m.count == 3 + 456)
    #expect(Array(m[0..<3]) == [0x35, 0xC8, 0x01])
    #expect(Array(m[3..<19]) == TWIFixture.rect(0, 25, 1920, 1080))
    #expect(Array(m[19..<23]) == [1, 0, 0, 0])
    #expect(m[23..<363].allSatisfy { $0 == 0 })
    #expect(Array(m[363..<383]) == TWIFixture.u32(20) + TWIFixture.u32(154) + TWIFixture.u32(0) + TWIFixture.u32(0) + TWIFixture.u32(8))
    #expect(m[383..<459].allSatisfy { $0 == 0 })
}

@Test func workAreaRules() {
    let a = TWIMonitor(bounds: TWIRect(left: 0, top: 0, right: 100, bottom: 100), workArea: TWIRect(left: 0, top: 10, right: 100, bottom: 100))
    #expect(TWIRequest.workArea(monitors: [], sessionWidth: 800, sessionHeight: 600) == TWIRect(left: 0, top: 0, right: 800, bottom: 600))
    #expect(TWIRequest.workArea(monitors: [a], sessionWidth: 800, sessionHeight: 600) == a.workArea)
    #expect(TWIRequest.workArea(monitors: [a, a], sessionWidth: 800, sessionHeight: 600) == .zero)
}

@Test func monitorLayoutBytes() {
    let m = TWIMonitor(bounds: TWIRect(left: 0, top: 0, right: 10, bottom: 20), workArea: TWIRect(left: 1, top: 2, right: 3, bottom: 4))
    let d = TWIRequest.monitorLayout([m, m])
    #expect(d.count == 3 + 4 + 64)
    #expect(Array(d[0..<7]) == [0x3b, 68, 0, 2, 0, 0, 0])
    #expect(Array(d[7..<23]) == TWIFixture.rect(0, 0, 10, 20))
    #expect(Array(d[23..<39]) == TWIFixture.rect(1, 2, 3, 4))
}

// MARK: - Engine handshake

@Test func hostInitProducesClientInitWithMirroredFlags() {
    let engine = SeamlessEngine()
    let (_, sent) = collect(engine)
    engine.receive(TWIFixture.hostInit(flags: 0x0001_9810))   // utf8 + bitmaps + iconChunks + extended + monitor layout
    // 0x10 | 0x800 | 0x1000 | 0x8000 | 0x10000 -> monitor 0x10, ext 0x80, chunks 0x100, utf8 0x1000; bitmaps off by default
    let flagsWord: UInt32 = 0x4 | 0x8 | 0x10 | 0x80 | 0x100 | 0x1000
    #expect(sent.value.count == 1)
    #expect(sent.value[0] == Data([0x01, 8, 0, 0, 3, 2, 0] + TWIFixture.u32(flagsWord)))
    #expect(engine.usesUTF8 && engine.hostInit?.hostVersion == 3)

    var cfg = SeamlessEngine.Config(); cfg.advertiseBitmaps = true; cfg.seamless = false
    let e2 = SeamlessEngine(config: cfg)
    let (_, s2) = collect(e2)
    e2.receive(TWIFixture.hostInit(flags: 0x0000_8800))
    #expect(s2.value[0] == Data([0x01, 8, 0, 0, 3, 2, 1] + TWIFixture.u32(0x4 | 0x8 | 0x80 | 0x800)))   // no 0x100: host lacks 0x1000
}

@Test func nothingSentBeforeHostInitAndMetricsAfterOpen() {
    let engine = SeamlessEngine()
    let (_, sent) = collect(engine)
    engine.activate(windowId: 1)
    engine.logoff()
    #expect(sent.value.isEmpty)
    engine.setMonitors([TWIMonitor(bounds: TWIRect(left: 0, top: 0, right: 2560, bottom: 1440), workArea: TWIRect(left: 0, top: 25, right: 2560, bottom: 1440))])
    engine.receive(TWIFixture.hostInit(flags: 0x10))
    #expect(sent.value.count == 1)
    engine.receive(TWIFixture.open)
    // client init, client metrics, monitor layout
    #expect(sent.value.count == 3)
    #expect(sent.value[1][0] == 0x35 && sent.value[1].count == 459)
    #expect(Array(sent.value[1][3..<19]) == TWIFixture.rect(0, 25, 2560, 1440))
    #expect(sent.value[2][0] == 0x3b)
    engine.activate(windowId: 5)
    #expect(sent.value.last == TWIRequest.activate(windowId: 5))
}

@Test func metricsFallBackToHostDesktopSizeAndAckResendsForNewHosts() {
    let engine = SeamlessEngine()
    let (_, sent) = collect(engine)
    engine.receive(TWIFixture.hostInit(version: 3, w: 1600, h: 900, flags: 0))
    engine.receive(TWIFixture.open)
    #expect(Array(sent.value[1][3..<19]) == TWIFixture.rect(0, 0, 1600, 900))
    #expect(sent.value.count == 2)   // no monitor layout without host flag / monitors
    engine.receive(TWIFixture.frame(0x3a, []))
    #expect(sent.value.count == 3 && sent.value[2][0] == 0x35)
    let old = SeamlessEngine()
    let (_, s2) = collect(old)
    old.receive(TWIFixture.hostInit(version: 2, flags: 0)); old.receive(TWIFixture.open)
    old.receive(TWIFixture.frame(0x3a, []))
    #expect(s2.value.count == 2)
}

@Test func closeUsesAltMessageWhenHostAsks() {
    let (engine, _, sent) = openEngine(hostFlags: 0x200)
    engine.requestClose(windowId: 3)
    #expect(sent.value.last == TWIRequest.closeAlt(windowId: 3))
    let (e2, _, s2) = openEngine(hostFlags: 0)
    e2.requestClose(windowId: 3)
    #expect(s2.value.last == TWIRequest.close(windowId: 3))
}

@Test func unknownTypesAreSkippedAndCounted() {
    let (engine, events, _) = openEngine()
    engine.receive(TWIFixture.frame(0x99, [1, 2, 3, 4]) + TWIFixture.frame(0x1a, [0]) + TWIFixture.frame(0x99, [])
                   + TWIFixture.createV1(id: 1, style: TWIFixture.visible, title: "A"))
    #expect(engine.unknownTypeCounts == [0x99: 2, 0x1a: 1])
    #expect(engine.unknownMessageCount == 3)
    #expect(engine.model.windows[1]?.title == "A")
    #expect(events.value.contains { if case .windowAdded = $0 { return true } else { return false } })
}

@Test func malformedMessagesAreCountedAndSkipped() {
    let (engine, _, _) = openEngine()
    engine.receive(TWIFixture.frame(0x0b, [1]) + TWIFixture.foreground(4))
    #expect(engine.malformedCount == 1)
    #expect(engine.model.foregroundWindow == 4)
}

@Test func windowMessagesDroppedUntilOpenAndAfterClose() {
    let engine = SeamlessEngine()
    _ = collect(engine)
    engine.receive(TWIFixture.hostInit(flags: 0))
    engine.receive(TWIFixture.createV1(id: 1, style: TWIFixture.visible))
    #expect(engine.model.windows.isEmpty && engine.droppedWhileInactive == 1)
    engine.receive(TWIFixture.open)
    engine.receive(TWIFixture.createV1(id: 1, style: TWIFixture.visible))
    #expect(engine.model.windows.count == 1)
    engine.receive(TWIFixture.close)
    #expect(engine.model.windows.isEmpty && !engine.isSeamlessActive)
}

/// Host message 0x47 (96 bytes, seen live three times on every reconnect) is not in the reference
/// dispatch: it must be skipped by length, not counted as malformed, and not disturb what follows.
@Test func unknownHostMessage47IsSkipped() {
    let engine = SeamlessEngine()
    engine.output = { _ in }
    var p47 = [UInt8](repeating: 0, count: 96)
    p47[0] = 8; p47[2] = 2; p47[4] = 1
    engine.receive(TWIFixture.hostInit(flags: 0x015f_ff89))
    engine.receive(TWIFixture.frame(0x47, p47) + TWIFixture.open)
    #expect(engine.unknownTypeCounts[0x47] == 1)
    #expect(engine.malformedCount == 0)
    #expect(engine.isSeamlessActive)
}

/// The host answers PAUSE/RESUME with CLOSE (0x03) then OPEN (0x02): seamless goes inactive and active
/// again, and the window list is rebuilt from what follows.
@Test func hostCloseThenOpenAfterResume() {
    let engine = SeamlessEngine()
    let states = Box<[Bool]>([])
    engine.onEvent = { if case .seamlessStateChanged(let a) = $0 { states.value.append(a) } }
    engine.output = { _ in }
    engine.receive(TWIFixture.hostInit(flags: 0x015f_ff89))
    engine.receive(TWIFixture.open)
    engine.receive(TWIFixture.createV2(id: 3, style: TWIFixture.visible | TWIFixture.caption, pid: 1, title: "A", appId: ""))
    #expect(engine.pauseResume())
    engine.receive(TWIFixture.frame(0x03, []) + TWIFixture.open)
    #expect(states.value == [true, false, true])
    #expect(engine.model.windows.isEmpty)
    engine.receive(TWIFixture.createV2(id: 3, style: TWIFixture.visible | TWIFixture.caption, pid: 1, title: "A", appId: ""))
    #expect(engine.model.windows.count == 1)
}
