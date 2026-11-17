import CryptoKit
import Foundation
import ICAKit

// MARK: - Client drive mapping with File Explorer (backlog 1.1, D112; docs/95 "To verify live" items 2, 7, §A.7)

/// `icactl cdmtest-explorer [resource]`: a fresh temp folder is mapped as drive M; the session's File Explorer lists it,
/// copies a file inside it (Explorer reads the source and creates the copy over CDM), makes a folder, deletes both, and
/// tries to leave the folder: a symlink to a folder outside it, one to a file outside it, and `..` in the address bar.
/// Checked on the Mac: the copy's bytes, `com.apple.quarantine` on what the session created, everything gone after the
/// deletes, and the outside folder untouched. Input only in a fresh logon of this run; destructive keys only while the
/// window title still shows the mapped drive (this run's temp folder). Nothing on the VDA's disks is touched.
func runCDMExplorerTest(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let runID = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    let probeName = "cdmtest-probe.txt"
    let probeText = Data("CTXCDM Explorer test \(runID) äöü\r\n".utf8)
    let secretText = Data("outside the shared folder \(runID)\r\n".utf8)
    let fm = FileManager.default

    // Mac side: base/share is the mapped root; base/outside must stay unreachable.
    let base = URL(fileURLWithPath: "/tmp/ica-cdmx-\(runID)", isDirectory: true)
    let share = base.appendingPathComponent("share", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: share, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: base) }
    try probeText.write(to: share.appendingPathComponent(probeName))
    try secretText.write(to: outside.appendingPathComponent("secret.txt"))
    try fm.createSymbolicLink(atPath: share.appendingPathComponent("escape-dir").path, withDestinationPath: "../outside")
    try fm.createSymbolicLink(atPath: share.appendingPathComponent("escape-file.txt").path, withDestinationPath: "../outside/secret.txt")
    try fm.createSymbolicLink(atPath: share.appendingPathComponent("inside-link.txt").path, withDestinationPath: probeName)
    func outsideState() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: outside.path)) ?? []).sorted().map { name in
            let url = outside.appendingPathComponent(name)
            let data = (try? Data(contentsOf: url)) ?? Data()
            let xattr = getxattr(url.path, CDMPOSIXFileSystem.quarantineName, nil, 0, 0, XATTR_NOFOLLOW) > 0
            return "\(name) \(data.count) B \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))\(xattr ? " quarantined" : "")"
        }
    }
    let outsideBefore = outsideState()
    say("run \(runID): mapped folder \(share.path) as M: (probe, escape-dir → ../outside, escape-file.txt → ../outside/secret.txt, "
        + "inside-link.txt → probe); outside: \(outsideBefore.joined(separator: ", "))")

    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: ProcessInfo.processInfo.environment)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let layout = config.logon.keyboardLayout
    let fs = try CDMPOSIXFileSystem(root: share, readOnly: false)
    fs.quarantineAgent = "icactl"
    // Names and paths are read back through the clipboard; version 4 as in cliptest-files (Explorer's copy of the
    // address bar text came as an empty list at version 3 and nothing after it, live 2026-11-17).
    var clipConfig = clipTestConfig(files: ProcessInfo.processInfo.environment["ICA_CDMX_CLIP_FILES"] != "0")
    if ProcessInfo.processInfo.environment["ICA_CLIP_VERSION"] == nil { clipConfig.maxVersion = 4 }
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipConfig,
                                 cdm: CDMEngine.Config(fileSystem: fs, letter: "M", label: "cdmtest"))
    guard let cdm = session.cdm, let clip = session.clipboard else { fail("no CDM or clipboard engine") }
    let seamless = session.seamless
    let shots = sessionDir.appendingPathComponent("cdm")
    try fm.createDirectory(at: shots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    // Session-queue state.
    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var operations: [String] = []
    var protocolError: String?
    var clipReady = false
    var terminateReason: UInt8?

    cdm.onEvent = { event in
        say("cdm: \(event)")
        switch event {
        case .operation(let line): operations.append(line)
        case .protocolError(let text): protocolError = text
        case .stopped: break
        }
    }
    clip.onEvent = { event in
        if case .trace = event { return }
        say("clip: \(event)")   // test strings only (paths and names of this run)
        switch event {
        case .ready: clipReady = true
        default: break
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, let changes):
            windowsSeen.note(w)
            if changes.contains(.title) { say("TWI window \(w.id) title \"\(w.title)\"") }
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
            say("TWI window \(w.id) removed")
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        case .wd(.failure(let text)): say("WD failure: \(text)")
        case .wd(.packet(let p)) where p.channel == CDMWire.channelNumber && [0x03, 0x04, 0x11, 0x15, 0x08].contains(p.payload.first ?? 0xFF):
            // WRITE requests carry only this run's probe bytes: hex for the wire layout (docs/95 §A.3).
            say("cdm wire: host packet \(p.payload.count) B: " + p.payload.prefix(96).map { String(format: "%02x", $0) }.joined(separator: " "))
        default: break
        }
    }

    try await session.start()
    let start = Date()
    let connected = await waitFor(session, 90) { operations.contains { $0.hasPrefix("CONNECT") } }
    say(connected ? "CDM CONNECT received" : "no CDM CONNECT within 90 s (drive mapping off by policy, or the module refused)")
    let explorer: () -> UInt32? = {
        appWindows.first { app.matches(executable: windowsSeen.single($0, seamless.model), appKey: windowsSeen.appKey($0)) }
    }
    _ = await waitFor(session, max(5, 120 - Date().timeIntervalSince(start))) { logon.isFresh && explorer() != nil && clipReady }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { explorer() }
    say("clipboard channel ready: \(await onSession(session) { clipReady })")

    var shot = 0
    var steps: [String] = []
    func note(_ line: String) { steps.append(line); say(line) }
    func title() async -> String { await onSession(session) { target.flatMap { seamless.model.windows[$0]?.title } ?? "" } }
    func appWindowIDs() async -> Set<UInt32> { await onSession(session) { Set(seamless.model.windows.filter { $0.value.kind == .appWindow }.keys) } }
    func newWindows(since before: Set<UInt32>) async -> [(UInt32, String)] {
        await onSession(session) {
            seamless.model.windows.values.filter { $0.kind == .appWindow && !before.contains($0.id) }.map { ($0.id, $0.title) }
        }
    }
    func screenshot(_ label: String) async {
        guard let target else { return }
        shot += 1
        say("[\(label)] " + (await audioTestScreenshot(session, target: target, index: shot, file: "cdmtest-explorer-\(runID)", dir: shots)))
    }
    func keys(_ sequence: String, wait: Double = 1.5) async throws {
        let parsed = try AudioTestKeys.parse(sequence, keyboardLayout: layout)
        say("keys: \(sequence)")
        for step in parsed {
            session.sendInput { wd in
                for m in step.modifiers { wd.keyScancode(m, up: false) }
                if step.extended {
                    wd.keyScancodes([0xE0, step.scancode], up: false)
                    wd.keyScancodes([0xE0, step.scancode], up: true)
                } else {
                    wd.keyScancode(step.scancode, up: false)
                    wd.keyScancode(step.scancode, up: true)
                }
                for m in step.modifiers.reversed() { wd.keyScancode(m, up: true) }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    }
    func type(_ text: String) async throws {
        say("type: \(text)")
        session.sendInput { wd in
            for unit in text.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    /// Ctrl+L, the path, Enter; the window title afterwards. (Not read back through the clipboard: with the drive
    /// mapped, Explorer's copy of the address bar came as an empty host list, live 2026-11-17.)
    func go(_ path: String) async throws -> String {
        try await keys("ctrl+l", wait: 1)
        try await keys("ctrl+a", wait: 0.5)
        try await type(path)
        try await keys("enter", wait: 3)
        return await title()
    }
    func abort(_ why: String) async throws {
        note("STOP: \(why); Esc, no further input")
        try await keys("esc", wait: 1)
    }
    func quarantined(_ url: URL) -> Bool { getxattr(url.path, CDMPOSIXFileSystem.quarantineName, nil, 0, 0, XATTR_NOFOLLOW) > 0 }

    var listed = false, copied = false, madeDir = false, deleted = false, confined = false
    let root = "\\\\Client\\M$"
    func listing() -> [String] { ((try? fm.contentsOfDirectory(atPath: share.path)) ?? []).sorted() }
    if !fresh {
        note("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !connected || target == nil {
        note("no CDM CONNECT or no Explorer window: no input is sent")
    } else if let target {
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await screenshot("start, title \"\(await title())\"")
        // 1. The mapped drive: the title changes and the host lists the root (FIND on "/").
        let opsBefore = await onSession(session) { operations.count }
        let driveTitle = try await go(root)
        await screenshot("mapped drive, title \"\(driveTitle)\"")
        let rootOps = await onSession(session) { Array(operations.dropFirst(opsBefore)) }
        let finds = rootOps.filter { $0.hasPrefix("FIND") }
        listed = !finds.isEmpty && driveTitle != "This PC" && !driveTitle.isEmpty
        note("mapped drive: title \"\(driveTitle)\"; \(finds.count) FIND operations (\(finds.prefix(3).joined(separator: " | ")))")
        // Destructive keys only while the title still shows the mapped drive: the drive is this run's temp folder.
        func inDrive() async -> Bool { await title() == driveTitle }
        if listed {
            // 2. Copy inside the drive: Explorer reads the probe and creates "cdmtest-probe - Copy.txt".
            try await keys("f5", wait: 2)
            try await type("cdmtest-probe")
            await screenshot("probe selected")
            if await inDrive() {
                try await keys("ctrl+c", wait: 1)
                try await keys("ctrl+v", wait: 5)
                await screenshot("after Ctrl+C, Ctrl+V")
            }
            var copies = listing().filter { $0.hasPrefix("cdmtest-probe") && $0 != probeName }
            // The copy may still be closing: give it up to 10 s to hold the probe's bytes.
            for _ in 0..<10 where copies.count == 1 {
                if (try? Data(contentsOf: share.appendingPathComponent(copies[0]))) == probeText { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                copies = listing().filter { $0.hasPrefix("cdmtest-probe") && $0 != probeName }
            }
            if copies.count == 1 {
                let url = share.appendingPathComponent(copies[0])
                let data = (try? Data(contentsOf: url)) ?? Data()
                if data != probeText {
                    let first = zip(data, probeText).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(data.count, probeText.count)
                    note("copy differs from byte \(first): got \(data.dropFirst(first).prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")), "
                         + "expected \(probeText.dropFirst(first).prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
                }
                copied = data == probeText && quarantined(url)
                note("copy: \"\(copies[0])\" on the Mac, \(data.count) B, \(data == probeText ? "EQUALS" : "does NOT equal") the probe, "
                     + "quarantine \(quarantined(url) ? "set" : "MISSING")")
            } else {
                note("copy: \(copies.count) copies on the Mac (\(copies.joined(separator: ", ")))")
            }
            // 3. A new folder.
            if await inDrive() {
                try await keys("ctrl+shift+n", wait: 2)
                try await type("cdmtest-dir")
                try await keys("enter", wait: 2)
            }
            let dir = share.appendingPathComponent("cdmtest-dir")
            var isDir: ObjCBool = false
            let dirExists = fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
            madeDir = dirExists && quarantined(dir)
            note("mkdir: cdmtest-dir \(dirExists ? "exists" : "MISSING") on the Mac, quarantine \(quarantined(dir) ? "set" : "missing")")
            // 4. Delete both: type-ahead selection, Shift+Delete, one confirmation each.
            var gone = 0
            for prefix in ["cdmtest-probe - ", "cdmtest-dir"] {
                guard await inDrive() else { try await abort("the title is no longer \"\(driveTitle)\""); break }
                try await keys("f5", wait: 2)
                try await type(prefix)
                let before = await appWindowIDs()
                try await keys("shift+delete", wait: 2)
                let dialogs = await newWindows(since: before)
                await screenshot("delete \(prefix)")
                guard dialogs.count == 1, ["delet", "lösch"].contains(where: { dialogs[0].1.lowercased().contains($0) }) else {
                    try await abort("expected one delete confirmation for \"\(prefix)\", got \(dialogs.map { "\"\($0.1)\"" })")
                    break
                }
                note("confirmation \"\(dialogs[0].1)\" for \"\(prefix)…\": Enter")
                try await keys("enter", wait: 3)
                gone += 1
            }
            let left = listing()
            deleted = gone == 2 && !left.contains("cdmtest-dir") && !left.contains { $0.hasPrefix("cdmtest-probe - ") } && left.contains(probeName)
            note("delete: \(gone) confirmed; the Mac folder now holds \(left.joined(separator: ", "))")
            // 5. Confinement: the links that lead outside, then `..` in the address bar.
            var escapes: [String] = []
            let opsConfine = await onSession(session) { operations.count }
            for name in ["escape-dir", "escape-file.txt", "inside-link.txt"] {
                _ = try await go(root)
                let before = await appWindowIDs()
                let t = try await go(root + "\\" + name)
                let dialogs = await newWindows(since: before)
                await screenshot("open \(name)")
                note("confinement \(name): title \"\(t)\", new windows \(dialogs.map { "\"\($0.1)\"" })")
                if name.hasPrefix("escape"), t.lowercased().hasPrefix("escape") || t.lowercased() == "outside" || dialogs.contains(where: { $0.1.lowercased().contains("secret") }) {
                    escapes.append(name)
                }
                for _ in dialogs { try await keys("esc", wait: 1.5) }
                let still = await newWindows(since: before)
                if !still.isEmpty {
                    // A file that opened in an app: close it without saving (Alt+F4, then Esc for any prompt).
                    note("confinement \(name): windows still open \(still.map { "\"\($0.1)\"" }); Alt+F4")
                    for (id, _) in still {
                        session.send { _, twi in twi.activate(windowId: id) }
                        try await Task.sleep(nanoseconds: 800_000_000)
                        try await keys("alt+f4", wait: 1.5)
                    }
                    session.send { _, twi in twi.activate(windowId: target) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            _ = try await go(root)
            let up = try await go(root + "\\..\\..")
            await screenshot("dot-dot")
            note("confinement ..: title after \(root)\\..\\.. is \"\(up)\"")
            let ops = await onSession(session) { Array(operations.dropFirst(opsConfine)) }
            let refused = ops.filter { $0.contains("refused") || $0.contains("ACCESS_DENIED") || $0.contains("escapes") || $0.contains("NOT_FOUND") }
            note("CDM during the confinement steps: \(ops.count) operations, \(refused.count) refused or not found: "
                 + refused.prefix(8).joined(separator: " | "))
            let outsideAfter = outsideState()
            confined = escapes.isEmpty && outsideAfter == outsideBefore
            note("outside folder \(outsideAfter == outsideBefore ? "unchanged" : "CHANGED: \(outsideAfter.joined(separator: ", "))"); "
                 + "opened through a link: \(escapes.isEmpty ? "none" : escapes.joined(separator: ", "))")
        }
    }

    // End: log off only this run's fresh session; otherwise disconnect.
    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            await session.close()
            ending = "logoff did not end the session in 30 s; disconnected"
        }
    }
    say("\n=== cdmtest-explorer summary (run \(runID)) ===")
    say("CDM connected: \(connected), fresh logon: \(fresh), protocol error: \(protocolError ?? "none")")
    for step in steps { say("  " + step) }
    say("end: \(ending)")
    let pass = fresh && connected && listed && copied && madeDir && deleted && confined && protocolError == nil && ending.hasPrefix("logged off")
    say("RESULT: \(pass ? "PASS" : "FAIL") cdmtest-explorer run \(runID): fresh \(fresh), CDM \(connected), listed \(listed), copy \(copied), "
        + "mkdir \(madeDir), deleted \(deleted), confined \(confined), end: \(ending)")
}
