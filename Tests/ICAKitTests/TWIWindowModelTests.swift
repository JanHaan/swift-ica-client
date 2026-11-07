import Testing
import Foundation
@testable import ICAKit

private typealias F = TWIFixture

private func setup(config: SeamlessEngine.Config = .init()) -> (SeamlessEngine, Box<[SeamlessEvent]>, Box<[Data]>) {
    let engine = SeamlessEngine(config: config)
    let events = Box<[SeamlessEvent]>([]), sent = Box<[Data]>([])
    engine.onEvent = { events.value.append($0) }
    engine.output = { if case .channel(let d) = $0 { sent.value.append(d) } }
    engine.receive(F.hostInit(flags: 0x0001_1810))
    engine.receive(F.open)
    events.value.removeAll(); sent.value.removeAll()
    return (engine, events, sent)
}

private func names(_ events: [SeamlessEvent]) -> [String] {
    events.map {
        switch $0 {
        case .channelReady: "ready"
        case .seamlessStateChanged(let a): "state:\(a)"
        case .systemMetricsChanged: "metrics"
        case .appAdded(let a): "appAdded:\(a.name)"
        case .appChanged(let a): "appChanged:\(a.name)"
        case .appRemoved(let a): "appRemoved:\(a.name)"
        case .windowAdded(let w): "added:\(w.id)"
        case .windowChanged(let w, _): "changed:\(w.id)"
        case .windowRemoved(let w): "removed:\(w.id)"
        case .windowActivated(let id): "activated:\(id.map(String.init) ?? "none")"
        case .iconChanged(let id, _): "icon:\(id)"
        case .processCreated(let p): "proc+\(p.processId)"
        case .processEnded(let p): "proc-\(p)"
        case .windowsReset: "reset"
        }
    }
}

private let vis = F.visible

@Test func classification() {
    func k(_ style: UInt32, _ ex: UInt32 = 0, owner: UInt32 = 0, menu: Bool = false) -> TWIWindowKind {
        WindowModel.classify(style: style, exStyle: ex, ownerId: owner, isMenu: menu).kind
    }
    func t(_ style: UInt32, _ ex: UInt32 = 0, owner: UInt32 = 0, menu: Bool = false) -> Bool {
        WindowModel.classify(style: style, exStyle: ex, ownerId: owner, isMenu: menu).taskbar
    }
    #expect(k(0) == .hidden)
    #expect(k(vis | F.caption) == .appWindow && t(vis | F.caption))
    #expect(k(vis, 0, menu: true) == .popup)
    #expect(k(vis, TWIStyle.exToolWindow) == .popup && !t(vis, TWIStyle.exToolWindow))
    #expect(k(vis, TWIStyle.exNoActivate) == .popup)
    #expect(k(vis, TWIStyle.exNoActivate | TWIStyle.exAppWindow) == .appWindow)            // rule 3 passes, owner 0
    #expect(k(vis | TWIStyle.popup, 0, owner: 5) == .popup)                                  // owned, no caption: popup
    #expect(k(vis | F.caption, 0, owner: 5) == .appWindow && !t(vis | F.caption, 0, owner: 5)) // dialog, no taskbar entry
    #expect(k(vis | F.caption, TWIStyle.exAppWindow, owner: 5) == .appWindow && t(vis | F.caption, TWIStyle.exAppWindow, owner: 5))
    #expect(k(vis | F.caption, TWIStyle.exToolWindow, owner: 5) == .popup)
}

@Test func createLateTitleOwnerPopupDestroy() {
    let (engine, events, _) = setup()
    // Top-level window without title, then the title arrives late.
    engine.receive(F.createV1(id: 10, style: vis | F.caption))
    #expect(engine.model.windows[10]?.title == "")
    #expect(names(events.value) == ["appAdded:Remote Application", "added:10"])
    events.value.removeAll()
    engine.receive(F.change(id: 10, mask: 0x01, title: "Untitled - Notepad"))
    #expect(engine.model.windows[10]?.title == "Untitled - Notepad")
    #expect(names(events.value) == ["changed:10"])
    if case .windowChanged(_, let ch) = events.value[0] { #expect(ch == .title) }
    events.value.removeAll()

    // Owned popup (tool-tip like) and an owned dialog.
    engine.receive(F.createV1(id: 11, style: vis | TWIStyle.popup, ex: TWIStyle.exNoActivate, owner: 10, title: "tip"))
    engine.receive(F.createV1(id: 12, style: vis | F.caption, owner: 10, title: "Save As"))
    engine.receive(F.createV1(type: 0x17, id: 13, style: vis | TWIStyle.popup, owner: 10))
    #expect(engine.model.windows[11]?.kind == .popup)
    #expect(engine.model.windows[12]?.kind == .appWindow && engine.model.windows[12]?.hasTaskbarEntry == false)
    #expect(engine.model.windows[13]?.kind == .popup && engine.model.windows[13]?.isMenu == true)
    #expect(engine.model.apps.values.first?.windowIds == [10, 12])
    events.value.removeAll()

    engine.receive(F.destroy(10)); engine.receive(F.destroy(11)); engine.receive(F.destroy(12)); engine.receive(F.destroy(13))
    #expect(names(events.value) == ["removed:10", "removed:11", "removed:12", "appRemoved:Remote Application", "removed:13"])
    #expect(engine.model.windows.isEmpty && engine.model.apps.isEmpty)
}

@Test func visibilityChangeReclassifiesAndUpdatesApps() {
    let (engine, events, _) = setup()
    engine.receive(F.createV1(id: 1, style: F.caption, title: "hidden at first"))
    #expect(engine.model.windows[1]?.kind == .hidden && engine.model.apps.isEmpty)
    events.value.removeAll()
    engine.receive(F.change(id: 1, mask: 0x02, style: vis | F.caption))
    #expect(engine.model.windows[1]?.kind == .appWindow)
    #expect(names(events.value) == ["appAdded:Remote Application", "changed:1"])
    guard case .windowChanged(_, let ch) = events.value[1] else { Issue.record(); return }
    #expect(ch.contains(.style) && ch.contains(.kind))
}

@Test func changeAppliesFieldsAndIgnoresUnknownWindows() {
    let (engine, events, sent) = setup()
    engine.receive(F.createV1(id: 1, style: vis | F.caption, title: "a"))
    events.value.removeAll()
    engine.receive(F.change(id: 1, mask: 0x08 | 0x10 | 0x40, window: F.rect(5, 6, 105, 206), client: F.rect(6, 7, 104, 205), above: 3))
    let w = engine.model.windows[1]!
    #expect(w.windowRect == TWIRect(left: 5, top: 6, right: 105, bottom: 206) && w.clientRect.left == 6 && w.windowAbove == 3)
    // Same data again: no event.
    events.value.removeAll()
    engine.receive(F.change(id: 1, mask: 0x08, window: F.rect(5, 6, 105, 206)))
    #expect(events.value.isEmpty)
    // Minimise via style.
    engine.receive(F.change(id: 1, mask: 0x02, style: vis | F.caption | TWIStyle.minimize))
    #expect(engine.model.windows[1]?.isMinimized == true)
    // Partial change for unknown id -> resend request, and no window.
    sent.value.removeAll()
    engine.receive(F.change(id: 77, mask: 0x01, title: "x"))
    #expect(sent.value == [TWIRequest.resendWindow(windowId: 77)])
    #expect(engine.model.windows[77] == nil)
    // Change for id 0 is ignored.
    sent.value.removeAll()
    engine.receive(F.change(id: 0, mask: 0x01, title: "x"))
    #expect(sent.value.isEmpty)
}

@Test func fullMaskChangeForUnknownIdIsImplicitCreate() {
    let (engine, events, sent) = setup()
    engine.receive(F.change(id: 42, mask: 0x3f, flags: 4, style: vis | F.caption, ex: 0, window: F.rect(0, 0, 50, 50),
                            client: F.rect(1, 1, 49, 49), owner: 0, title: "Implicit"))
    #expect(sent.value.isEmpty)
    #expect(engine.model.windows[42]?.title == "Implicit" && engine.model.windows[42]?.flags == 4)
    #expect(names(events.value).contains("added:42"))
    // Create for an existing id is ignored.
    engine.receive(F.createV1(id: 42, style: vis, title: "dup"))
    #expect(engine.model.windows[42]?.title == "Implicit")
    // Window 0 is never created.
    engine.receive(F.createV1(id: 0, style: vis))
    #expect(engine.model.windows[0] == nil)
}

@Test func minimizedTaskbarWindowTriggersRestore() {
    let (engine, _, sent) = setup()
    engine.receive(F.createV1(id: 5, style: vis | F.caption | TWIStyle.minimize))
    #expect(sent.value == [TWIRequest.restore(windowId: 5)])
    var cfg = SeamlessEngine.Config(); cfg.restoreMinimizedOnCreate = false
    let (e2, _, s2) = setup(config: cfg)
    e2.receive(F.createV1(id: 5, style: vis | F.caption | TWIStyle.minimize))
    #expect(s2.value.isEmpty)
}

@Test func foregroundTracking() {
    let (engine, events, _) = setup()
    engine.receive(F.foreground(4))
    engine.receive(F.foreground(4))
    engine.receive(F.foreground(0))
    #expect(names(events.value) == ["activated:4", "activated:none"])
    #expect(engine.model.foregroundWindow == nil && engine.model.lastForegroundWindow == 4)
}

@Test func processGrouping() {
    let (engine, events, _) = setup()
    // Root process of a published app, a child process, and an unrelated process.
    engine.receive(F.processCreated(pid: 100, parent: 1, exe: "C:\\Program Files\\Office\\winword.exe", app: "WINWORD#Word"))
    engine.receive(F.processCreated(pid: 101, parent: 100, exe: "C:\\Windows\\splwow.exe", app: ""))
    engine.receive(F.processCreated(pid: 200, parent: 1, exe: "C:\\Windows\\System32\\notepad.exe", app: ""))
    engine.receive(F.createV2(id: 1, style: vis | F.caption, pid: 100, title: "Doc1", appId: "Microsoft.Office.WINWORD"))
    engine.receive(F.createV2(id: 2, style: vis | F.caption, pid: 101, title: "Child", appId: ""))
    engine.receive(F.createV2(id: 3, style: vis | F.caption, pid: 200, title: "Untitled", appId: "_NONE_"))
    engine.receive(F.createV2(id: 4, style: vis | F.caption, pid: 999, title: "Mystery", appId: "Some.AUMID"))
    engine.receive(F.createV2(id: 5, style: vis | F.caption, pid: 998, title: "Nothing", appId: ""))
    let m = engine.model
    #expect(m.windows[1]?.appKey == "app:Word" && m.windows[2]?.appKey == "app:Word")
    #expect(m.windows[3]?.appKey == "exe:c:\\windows\\system32\\notepad.exe")
    #expect(m.windows[4]?.appKey == "aumid:Some.AUMID")
    #expect(m.windows[5]?.appKey == WindowModel.sessionAppKey)
    #expect(m.apps["app:Word"]?.windowIds == [1, 2] && m.apps["app:Word"]?.name == "Word")
    #expect(m.apps["exe:c:\\windows\\system32\\notepad.exe"]?.name == "notepad")
    #expect(m.apps.count == 4)
    #expect(names(events.value).filter { $0.hasPrefix("appAdded") }.count == 4)
    // Closing both Word windows removes the app.
    events.value.removeAll()
    engine.receive(F.destroy(1)); engine.receive(F.destroy(2))
    #expect(names(events.value).contains("appRemoved:Word") && m.apps["app:Word"] == nil)
}

@Test func lateProcessMessageRegroupsWindows() {
    let (engine, events, _) = setup()
    engine.receive(F.createV2(id: 1, style: vis | F.caption, pid: 50, title: "T", appId: ""))
    #expect(engine.model.windows[1]?.appKey == WindowModel.sessionAppKey)
    events.value.removeAll()
    engine.receive(F.processCreated(pid: 50, parent: 0, exe: "C:\\x\\calc.exe", app: ""))
    #expect(engine.model.windows[1]?.appKey == "exe:c:\\x\\calc.exe")
    let n = names(events.value)
    #expect(n.contains("appAdded:calc") && n.contains("appRemoved:Remote Application") && n.contains("changed:1"))
    // A process that ends keeps its windows grouped.
    engine.receive(F.frame(0x41, F.u32(50) + F.u16(0)))
    #expect(engine.model.windows[1]?.appKey == "exe:c:\\x\\calc.exe")
}

@Test func ownerInheritsProcessAndAppId() {
    let (engine, _, _) = setup()
    engine.receive(F.processCreated(pid: 7, parent: 0, exe: "C:\\a\\app.exe", app: ""))
    engine.receive(F.createV2(id: 1, style: vis | F.caption, pid: 7, title: "Main", appId: "My.App"))
    // v1 dialog (no pid) and a v2 popup with pid 0, both owned by 1; grandchild owned by the dialog.
    engine.receive(F.createV1(id: 2, style: vis | F.caption, owner: 1, title: "Dlg"))
    engine.receive(F.createV1(id: 3, style: vis | F.caption, owner: 2, title: "Sub"))
    for id: UInt32 in [2, 3] {
        #expect(engine.model.windows[id]?.processId == 7)
        #expect(engine.model.windows[id]?.appIdString == "My.App")
        #expect(engine.model.windows[id]?.appKey == "aumid:My.App")
    }
}

@Test func ownedWindowCreatedBeforeOwnerResolvesLater() {
    let (engine, _, _) = setup()
    engine.receive(F.createV1(id: 2, style: vis | F.caption, owner: 1, title: "early dialog"))
    #expect(engine.model.windows[2]?.processId == nil)
    engine.receive(F.createV2(id: 1, style: vis | F.caption, pid: 9, title: "Owner", appId: "Late.Owner"))
    #expect(engine.model.windows[2]?.appIdString == "Late.Owner")
    #expect(engine.model.windows[2]?.appKey == "aumid:Late.Owner")
}

@Test func publishedNameParsing() {
    func p(_ s: String) -> TWIProcessInfo { TWIProcessInfo(processId: 1, parentId: 0, flags: 0, stringA: "", executablePath: "", appName: s) }
    #expect(WindowModel.publishedName(p("x#Name")) == "Name")
    #expect(WindowModel.publishedName(p("#Name")) == "Name")
    #expect(WindowModel.publishedName(p("x#")) == nil)
    #expect(WindowModel.publishedName(p("#")) == nil)
    #expect(WindowModel.publishedName(p("plain")) == nil)
    #expect(WindowModel.executableName("C:\\Windows\\NOTEPAD.EXE") == "NOTEPAD")
}

@Test func openResetsWindowsAndEmitsRemovals() {
    let (engine, events, _) = setup()
    engine.receive(F.createV1(id: 1, style: vis | F.caption, title: "a"))
    engine.receive(F.foreground(1))
    events.value.removeAll()
    engine.receive(F.open)
    let n = names(events.value)
    #expect(n.contains("removed:1") && n.contains("activated:none") && n.contains("appRemoved:Remote Application"))
    #expect(engine.model.windows.isEmpty)
}

@Test func displayLayoutChangeSendsPauseResumeAndClearsWindows() {
    let (engine, _, sent) = setup()
    engine.setMonitors([TWIMonitor(bounds: TWIRect(left: 0, top: 0, right: 800, bottom: 600), workArea: TWIRect(left: 0, top: 0, right: 800, bottom: 580))])
    sent.value.removeAll()
    engine.receive(F.createV1(id: 1, style: vis | F.caption))
    engine.displayLayoutChanged()
    #expect(engine.model.windows.isEmpty)
    #expect(sent.value.map { $0[0] } == [0x05, 0x06, 0x3b])
}

@Test func iconsSingleChunkedAndBeforeCreate() {
    let (engine, events, _) = setup()
    // Build a 2x2, 32 bpp icon blob.
    func blob(alpha: Bool) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 12)
        let maskOff = 24 + 40 + 16, bmiOff = 24, bitsOff = 24 + 40
        b += F.u32(UInt32(maskOff)) + F.u32(UInt32(bmiOff)) + F.u32(UInt32(bitsOff))
        b += F.u32(40) + F.i32(2) + F.i32(2) + F.u16(1) + F.u16(32) + [UInt8](repeating: 0, count: 24)
        // Bottom row first: (B,G,R,A) pixels. Bottom-left red, bottom-right green; top-left blue, top-right white.
        let a: UInt8 = alpha ? 255 : 0
        b += [0, 0, 255, a, 0, 255, 0, a]
        b += [255, 0, 0, a, 255, 255, 255, a]
        b += [0x40, 0, 0, 0, 0x00, 0, 0, 0]   // AND mask: row0 (bottom) pixel1 transparent... only used when alpha is absent
        return b
    }
    // Icon arrives before the window exists: kept until create.
    engine.receive(F.frame(0x0e, F.u32(1) + F.u32(1) + blob(alpha: true)))
    #expect(engine.model.droppedIconCount == 1)
    engine.receive(F.createV1(id: 1, style: vis | F.caption, title: "i"))
    let icon = engine.model.windows[1]?.icon
    #expect(icon?.type == 1 && icon?.width == 2 && icon?.height == 2)
    if let img = icon?.image {
        #expect(TWIIconDecoder.pixel(img, x: 0, y: 1)! == (255, 0, 0, 255))     // bottom-left red
        #expect(TWIIconDecoder.pixel(img, x: 1, y: 1)! == (0, 255, 0, 255))
        #expect(TWIIconDecoder.pixel(img, x: 0, y: 0)! == (0, 0, 255, 255))
        #expect(TWIIconDecoder.pixel(img, x: 1, y: 0)! == (255, 255, 255, 255))
    } else { Issue.record("icon did not decode") }

    // Chunked delivery of a second icon (type 0), split in three.
    events.value.removeAll()
    let full = blob(alpha: false)
    func chunk(_ flags: UInt16, total: UInt32?, _ data: ArraySlice<UInt8>) -> Data {
        let hdr: UInt16 = total == nil ? 18 : 22
        var p = F.u32(1) + F.u32(55) + F.u32(0) + F.u16(flags) + F.u16(hdr) + F.u16(UInt16(data.count))
        if let t = total { p += F.u32(t) }
        return F.frame(0x3e, p + data)
    }
    let c1 = chunk(0xC0, total: UInt32(full.count), full[0..<30])
    let c2 = chunk(0x80, total: nil, full[30..<60])
    let c3 = chunk(0x00, total: nil, full[60...])
    engine.receive(c1); engine.receive(c2)
    #expect(events.value.isEmpty)
    engine.receive(c3)
    #expect(names(events.value) == ["changed:1", "icon:1"])
    let small = engine.model.windows[1]?.icons[0]
    #expect(small?.blob == Data(full) && small?.image != nil)
    // Mask applies when the alpha channel is all zero: pixel (x=1,y=1) is bottom-right, mask bit 0x40 -> x=1 transparent.
    if let img = small?.image { #expect(TWIIconDecoder.pixel(img, x: 1, y: 1)?.3 == 0); #expect(TWIIconDecoder.pixel(img, x: 0, y: 1)?.3 == 255) }
    // Primary icon stays the first one received.
    #expect(engine.model.windows[1]?.primaryIconType == 1)
}

@Test func systemMetricsStored() {
    let (engine, events, _) = setup()
    var p = F.u32(1)
    for i in 0..<22 { p += F.u16(UInt16(i)) }
    p += F.u16(0) + F.u16(0) + F.u16(0) + [0]
    engine.receive(F.frame(0x0d, p))
    #expect(engine.systemMetrics?.captionHeight == 16)
    #expect(names(events.value) == ["metrics"])
}

@Test func splitDeliveryAcrossReceiveCallsProducesSameModel() {
    let (engine, _, _) = setup()
    let stream = F.processCreated(pid: 3, parent: 0, exe: "C:\\z\\z.exe", app: "") + F.createV2(id: 8, style: vis | F.caption, pid: 3, title: "Split", appId: "")
        + F.change(id: 8, mask: 0x01, title: "Split 2")
    var i = 0
    while i < stream.count {   // irregular chunk sizes
        let n = min(1 + i % 7, stream.count - i)
        engine.receive(stream.subdata(in: i..<i + n))
        i += n
    }
    #expect(engine.model.windows[8]?.title == "Split 2")
    #expect(engine.model.windows[8]?.appKey == "exe:c:\\z\\z.exe")
}

/// Replays real channel-12 captures from .session/replay/ch12-*.bin (raw concatenated channel payloads,
/// written by `ICA_CAPTURE_REPLAY=1 icactl session`). Skips when none exist. Prints message type counts only (no titles other than the test app's).
@Test func replayRealCapturesIfPresent() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent(".session/replay")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("ch12-") && $0.hasSuffix(".bin") }.sorted()
    guard !files.isEmpty else { return }
    let engine = SeamlessEngine()
    let sent = Box<[UInt8]>([])
    engine.output = { if case .channel(let d) = $0, let t = d.first { sent.value.append(t) } }
    let added = Box<[TWIWindow]>([]), apps = Box<[TWIApp]>([]), removed = Box<[UInt32]>([])
    let icons = Box<[(UInt32, Int)]>([])
    engine.onEvent = {
        switch $0 {
        case .windowAdded(let w): added.value.append(w)
        case .windowRemoved(let w): removed.value.append(w.id)
        case .appAdded(let a): apps.value.append(a)
        case .iconChanged(_, let icon): icons.value.append((icon.type, icon.width))
        default: break
        }
    }
    for name in files {
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        var i = 0
        while i < data.count { let n = min(1024, data.count - i); engine.receive(data.subdata(in: i..<i + n)); i += n }
    }
    let counts = engine.messageCounts.sorted { $0.key < $1.key }.map { String(format: "0x%02x=%d", $0.key, $0.value) }
    let host = engine.hostInit.map { String(format: "host flags 0x%08x version %d desktop %dx%d", $0.flags.rawValue, $0.hostVersion, $0.desktopWidth, $0.desktopHeight) } ?? "no host init"
    print("TWI replay: files=\(files.count) types: \(counts.joined(separator: " ")) unknown=\(engine.unknownTypeCounts) malformed=\(engine.malformedCount) \(host)")
    print("TWI replay: sent types \(sent.value.map { String(format: "%02x", $0) }.joined(separator: ",")) icons \(icons.value.map { "type\($0.0):\($0.1)px" })")
    for w in added.value {
        let title = "(\(w.title.count) chars)"
        print("TWI replay: window \(String(w.id, radix: 16)) \(w.kind) \(title) rect \(w.windowRect) style \(String(w.style, radix: 16)) app \(w.appKey)")
    }
    for a in apps.value { print("TWI replay: app \(a.key) name \(a.name)") }
    #expect(engine.malformedCount == 0)
    // The lifecycle checks need a complete fresh-logon capture of the calculator resource: the logon UI, then one
    // calculator window that is removed again (logoff). A reconnect or a cut-off capture only replays.
    let sawLogonUI = added.value.contains { $0.appKey.lowercased().hasSuffix("\\logonui.exe") }
    if sawLogonUI, let w = added.value.first(where: { $0.kind == .appWindow && !$0.appKey.lowercased().hasSuffix("\\logonui.exe") }), removed.value.contains(w.id) {
        #expect(added.value.filter { $0.kind == .appWindow && !$0.appKey.lowercased().hasSuffix("\\logonui.exe") }.count == 1)
        #expect(w.kind == .appWindow && w.hasTaskbarEntry)
        #expect(w.windowRect.width > 100 && w.windowRect.height > 100)
        #expect(apps.value.contains { $0.windowIds == [w.id] && !$0.name.isEmpty && $0.key != WindowModel.sessionAppKey })
        #expect(removed.value.contains(w.id))
        #expect(icons.value.allSatisfy { $0.1 > 0 })
    }
}

/// Live reconnect sequence (docs/50 §7.1): host init, OPEN, metrics; after the second Thinwire INIT the
/// client sends PAUSE + RESUME (reference behaviour); the host then (re)announces its windows.
@Test func pauseResumeAfterThinwireInitOnReconnect() {
    let engine = SeamlessEngine()
    let sent = Box<[UInt8]>([])
    let events = Box<[SeamlessEvent]>([])
    engine.onEvent = { events.value.append($0) }
    engine.output = { if case .channel(let d) = $0, let t = d.first { sent.value.append(t) } }
    #expect(!engine.pauseResume())                       // before the host init: nothing can be sent
    #expect(sent.value.isEmpty)
    // Multi-monitor host flags seen live (no 0x10: no monitor layout from us).
    engine.receive(F.hostInit(flags: 0x015f_ff89))
    engine.receive(F.open)
    engine.receive(F.createV2(id: 7, style: vis | F.caption, pid: 1, title: "Calculator", appId: ""))
    #expect(engine.model.windows.count == 1)
    sent.value.removeAll()
    #expect(engine.pauseResume())                        // second Thinwire INIT
    #expect(sent.value == [0x05, 0x06])
    #expect(engine.model.windows.isEmpty)                // RESUME resets the list; the host replays
    #expect(names(events.value).contains("removed:7"))
    engine.receive(F.hostInit(flags: 0x015f_ff89))
    engine.receive(F.open)
    engine.receive(F.createV2(id: 7, style: vis | F.caption, pid: 1, title: "Calculator", appId: ""))
    #expect(engine.model.windows[7]?.kind == .appWindow)
}

@Test func pauseResumeResendsMonitorLayoutWhenHostWantsIt() {
    let engine = SeamlessEngine()
    let sent = Box<[UInt8]>([])
    engine.output = { if case .channel(let d) = $0, let t = d.first { sent.value.append(t) } }
    let r = TWIRect(x: 0, y: 0, width: 1800, height: 1168)
    engine.setMonitors([TWIMonitor(bounds: r, workArea: r)])
    engine.receive(F.hostInit(flags: 0x015f_ff99))       // single monitor: host has 0x10
    sent.value.removeAll()
    #expect(engine.pauseResume())
    #expect(sent.value == [0x05, 0x06, 0x3b])
    var config = SeamlessEngine.Config()
    config.seamless = false
    let windowed = SeamlessEngine(config: config)
    windowed.output = { _ in }
    windowed.receive(F.hostInit(flags: 0x015f_ff99))
    #expect(!windowed.pauseResume())                     // only in seamless mode
}

/// A window the stock client left minimised arrives visible with WS_MINIMIZE (ARW_HIDE parks it
/// off-screen): it is still an app window, and the model asks for a restore only via the config flag.
@Test func minimisedWindowOnReconnectIsAnAppWindow() {
    let (engine, _, sent) = setup()
    engine.receive(F.createV2(id: 9, style: vis | F.caption | TWIStyle.minimize, pid: 1, title: "Mail", appId: ""))
    #expect(engine.model.windows[9]?.kind == .appWindow)
    #expect(engine.model.windows[9]?.isMinimized == true)
    #expect(sent.value.count == 1)                       // RESTORE (restoreMinimizedOnCreate default)
}


/// A list reset (OPEN/RESUME) announces itself before the removals, so a UI can keep its windows.
@Test func resetIsAnnouncedBeforeRemovals() {
    let (engine, events, _) = setup()
    engine.receive(F.createV2(id: 4, style: vis | F.caption, pid: 1, title: "A", appId: ""))
    events.value.removeAll()
    engine.receive(F.open)
    let n = names(events.value)
    #expect(n.firstIndex(of: "reset")! < n.firstIndex(of: "removed:4")!)
    events.value.removeAll()
    engine.receive(F.open)                       // empty list: no reset event
    #expect(!names(events.value).contains("reset"))
}
