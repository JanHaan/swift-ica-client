import Foundation
import ICAKit

// MARK: - fetch-file: one named file from the session to the Mac over CTXGDT (docs/76 §7.17, D88)

/// `icactl fetch-file "Explorer Citrix ABC" 'H:\file.ext' [destDir] [--max-mb N] [--stall S] [--select-all]`
/// (`--select-all`: Ctrl+A in the folder instead of typing the name; the folder must hold only that file.)
///
/// Fresh logon only (refused while any ABC session exists). Input in the session is limited to: Ctrl+L, typing the
/// folder path, Enter, typing the file name (Explorer type-ahead selects it), Ctrl+C. The host's file group must be
/// exactly that one file, else nothing is fetched. The file streams to `<destDir>/.<name>.part-<run>` and is renamed
/// to a name that does not exist yet; size and SHA-256 are printed. No quarantine attribute (a CLI fetch), nothing is
/// opened or unpacked. Then logoff and a check that the session is gone.
func fetchFileCommand(_ args: [String], store: StoreClient) async {
    let usage = "usage: icactl fetch-file \"Explorer Citrix ABC\" 'H:\\path\\file' [destDir] [--max-mb N] [--stall S] [--select-all]"
    var positional: [String] = []
    var maxMB: UInt64 = 16 << 10   // 16 GiB
    var stall: TimeInterval = 60
    var selectAll = false
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--max-mb": guard let v = it.next().flatMap(UInt64.init), v > 0 else { fail(usage) }; maxMB = v
        case "--select-all": selectAll = true
        case "--stall": guard let v = it.next().flatMap(Double.init), v >= 5 else { fail("--stall needs seconds ≥ 5") }; stall = v
        default: positional.append(a)
        }
    }
    guard (2...3).contains(positional.count) else { fail(usage) }
    let resourceName = positional[0]
    // Lab (D132): "File Explorer" with ICA_ALLOW_ANY_RESOURCE=1, gated on the lab user having no session at all.
    let lab = resourceName == "File Explorer" && ProcessInfo.processInfo.environment["ICA_ALLOW_ANY_RESOURCE"] == "1"
    guard resourceName == "Explorer Citrix ABC" || lab else {
        fail("fetch-file is limited to \"Explorer Citrix ABC\" (lab: \"File Explorer\" with ICA_ALLOW_ANY_RESOURCE=1)")
    }
    guard let (folder, name) = HostFileFetch.split(positional[1]) else { fail("not an absolute Windows file path: \(positional[1])") }
    let destDir = positional.count == 3
        ? URL(fileURLWithPath: (positional[2] as NSString).expandingTildeInPath, isDirectory: true)
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/citrix-lab", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch { fail("cannot create \(destDir.path): \(error.localizedDescription)") }

    do {
        // Gate: no session of the ABC group may exist (fresh logon only). Others (e.g. the user's XYZ session) stay.
        let resources = try await store.resources()
        let list = try await store.sessions.list()
        let abc = lab ? list.sessions : list.sessions.filter {
            HostFileFetch.isTestGroup(appNames: TestSessionGate.resolvedNames($0, resources: resources) + $0.appNames)
        }
        say("sessions before: \(list.sessions.count), in the ABC group: \(abc.count)")
        guard abc.isEmpty else {
            fail("refused: ABC session(s) exist (\(abc.map(\.shortId).joined(separator: ", "))); fetch-file needs a fresh logon")
        }
        guard let resource = resources.first(where: { $0.name == resourceName }) else { fail("no resource named \(resourceName)") }
        guard let ica = ICAFile(text: try await testLaunchICA(store, resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        let ok = try await runFetchFile(ica: ica, folder: folder, name: name, destDir: destDir, cap: maxMB << 20, stall: stall, selectAll: selectAll)
        // The session must be gone from the store's list.
        var gone = false
        for _ in 0..<6 {
            let after = try await store.sessions.list()
            let left = lab ? after.sessions : after.sessions.filter { HostFileFetch.isTestGroup(appNames: TestSessionGate.resolvedNames($0, resources: resources) + $0.appNames) }
            if left.isEmpty { gone = true; break }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        try http.saveCookies(to: cookiePath)
        say(gone ? "store: no ABC session left" : "store: an ABC session is STILL listed (check icactl sessions list)")
        if !ok || !gone { exit(1) }
    } catch {
        fail("\(error)")
    }
}

/// The session part of `fetch-file`; true if the file was stored and the session logged off.
func runFetchFile(ica: ICAFile, folder: String, name: String, destDir: URL, cap: UInt64, stall: TimeInterval, selectAll: Bool = false) async throws -> Bool {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let runID = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    say("run \(runID): fetch \"\(name)\" from \(folder)\(selectAll ? " (select all)" : "") → \(destDir.path) (cap \(cap >> 20) MiB, stall \(Int(stall)) s)")

    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    // As the app with "Copy files through the clipboard" on (D90): CTXCLIP v4 with file formats, CTXGDT files, no
    // GDT history (it would hold file contents), no wire traces.
    var clipConfig = ClipboardEngine.Config()
    clipConfig.files = true
    clipConfig.maxVersion = ClipboardWire.filesVersion
    var gdtConfig = GDTEngine.Config()
    gdtConfig.historyLimit = 0
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipConfig, gdt: gdtConfig)
    guard let clip = session.clipboard, let gdt = session.gdt else { fail("no clipboard or CTXGDT engine") }

    gdt.files.stallTimeout = stall
    gdt.files.maxFileSize = Int(clamping: cap)
    gdt.files.maxFiles = 1
    gdt.files.quarantineAgent = nil
    gdt.files.filePermissions = 0o600
    if let text = env["ICA_GDT_READSIZE"] {
        guard let n = Int(text), n > 0, n <= 16 << 20 else { fail("ICA_GDT_READSIZE must be 1…16777216") }
        gdt.files.readSize = n
    }
    if let text = env["ICA_GDT_READAHEAD"] {
        guard let n = Int(text), (1...8).contains(n) else { fail("ICA_GDT_READAHEAD must be 1…8") }
        gdt.files.readAhead = n
    }

    // Session-queue state.
    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var ready = false
    var listed: UInt16?          // the host list carries FileGroupDescriptorW (its registered id)
    var hostTextArrived = false  // Ctrl+C gave text instead of files (focus was not in the file list)
    var terminateReason: UInt8?
    clip.filesOverGDT = true
    clip.fetchFileContents = false
    clip.onEvent = { event in
        switch event {
        case .ready: ready = true
        case .hostFileGroupListed(let id): listed = id
        case .hostClipboard: hostTextArrived = true   // contents are not logged
        default: break
        }
    }
    gdt.onEvent = { event in
        if case .log(let text) = event { say("gdt: \(text)") }
    }
    let seamless = session.seamless
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
        case .windowChanged(let w, _): windowsSeen.note(w)
        case .windowRemoved(let w): appWindows.removeAll { $0 == w.id }
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.onEvent = { event in
        switch event {
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)): terminateReason = reason; say("← TERMINATE reason \(reason)")
        case .wd(.failure(let text)): say("WD failure: \(text)")
        default: break
        }
    }

    try await session.start()
    let start = Date()
    let gotReady = await waitFor(session, 90) { ready }
    say(gotReady ? "clipboard channel ready" : "clipboard channel NOT ready after 90 s")
    let explorer: () -> UInt32? = {
        appWindows.first { id in
            if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == "explorer.exe" }
            return windowsSeen.appKey(id)?.lowercased() == "app:explorer citrix abc"
        }
    }
    _ = await waitFor(session, max(5, 120 - Date().timeIntervalSince(start))) { logon.isFresh && explorer() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { explorer() }

    let layout = config.logon.keyboardLayout
    func keys(_ sequence: String, wait: Double) async throws {
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
    func type(_ text: String, wait: Double) async throws {
        say("type: \(text)")
        session.sendInput { wd in
            for unit in text.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
        }
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    }

    var stored: URL?
    var outcome = "not started"
    if !fresh {
        outcome = "not a fresh logon by this run: no input sent"
    } else if !gotReady || target == nil {
        outcome = "no Explorer window or no clipboard channel: no input sent"
    } else if let target {
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        // The only input: Ctrl+L, the folder, Enter, the file name (type-ahead selects), Ctrl+C.
        try await keys("ctrl+l", wait: 1)
        try await type(folder, wait: 1)
        try await keys("enter", wait: 3)
        if selectAll {
            // --select-all: the folder holds only this file; Ctrl+A selects everything in it (the file group check
            // below still requires exactly one entry with the name).
            try await keys("ctrl+a", wait: 1.5)
        } else {
            try await type(name, wait: 1.5)
        }
        await onSession(session) { listed = nil; hostTextArrived = false }
        try await keys("ctrl+c", wait: 0.5)
        _ = await waitFor(session, 20) { listed != nil || hostTextArrived }
        let id = await onSession(session) { listed }
        if let id {
            stored = try await fetchListed(session: session, gdt: gdt, format: id, name: name, destDir: destDir, cap: cap,
                                           stall: stall, runID: runID, outcome: &outcome)
        } else {
            outcome = await onSession(session) { hostTextArrived }
                ? "Ctrl+C copied text, not a file (the selection is not in the file list): nothing fetched"
                : "no file group on the host clipboard within 20 s: nothing fetched"
        }
    }

    // End: log off this run's fresh session; otherwise only disconnect.
    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            say("→ TWI LOGOFF")
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            await session.close()
            ending = sent ? "logoff sent but the session did not end; disconnected" : "TWI not ready; disconnected"
        }
    }
    say("\n=== fetch-file summary (run \(runID)) ===")
    say("fresh logon: \(fresh); \(outcome)")
    say("end: \(ending)")
    return stored != nil && ending.hasPrefix("logged off")
}

/// Descriptor first (nothing fetched unless it is exactly the one file), then the file with that descriptor
/// expected, streamed to a part file; progress every 4 MiB, the stall watchdog in `GDTFileTransfer`.
private func fetchListed(session: ICASession, gdt: GDTEngine, format: UInt16, name: String, destDir: URL, cap: UInt64,
                         stall: TimeInterval, runID: String, outcome: inout String) async throws -> URL? {
    // 1. The descriptor only.
    var group: [ClipboardFileEntry]?
    var ended: String?
    await onSession(session) {
        gdt.files.fetch(.descriptor, systemFormat: UInt32(format)) { update in
            switch update {
            case .group(let e): group = e
            case .done: ended = "done"
            case .failed(let why): ended = "failed: \(why)"
            default: break
            }
        }
    }
    _ = await waitFor(session, stall + 5) { ended != nil }
    let (entries, end) = await onSession(session) { (group, ended) }
    guard let entries, end == "done" else {
        await onSession(session) { gdt.files.cancelFetch("no descriptor") }
        outcome = "the host's file list did not arrive (\(end ?? "timeout")): nothing fetched"
        return nil
    }
    let entry: ClipboardFileEntry
    switch HostFileFetch.check(entries, name: name, cap: cap) {
    case .failure(let problem):
        outcome = "\(problem): nothing fetched"
        return nil
    case .success(let e): entry = e
    }
    say("host file list: exactly \"\(entry.name)\", \(entry.size) B")
    if let free = try? destDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
       free > 0, UInt64(free) < entry.size + entry.size / 10 {
        outcome = "not enough free space in \(destDir.path) (\(free) B free, \(entry.size) B + 10 % needed): nothing fetched"
        return nil
    }

    // 2. The file, into a part file next to the destination.
    let part = destDir.appendingPathComponent(".\(HostFileFetch.isValidName(name) ? name : "file").part-\(runID)")
    var progress = HostFileFetch.Progress(total: entry.size)
    let started = Date()
    var written: UInt64 = 0
    var lastData = Date()
    var result: String?
    await onSession(session) {
        gdt.files.fetch(.files(targets: [0: part], expect: entries), systemFormat: UInt32(format)) { update in
            switch update {
            case .progress(_, let bytes):
                written = UInt64(bytes)
                lastData = Date()
                if let line = progress.update(written, elapsed: Date().timeIntervalSince(started)) { say("progress: " + line) }
            case .file(_, _, let bytes): written = UInt64(bytes)
            case .fileFailed(_, let why): result = "failed: \(why)"
            case .done(let n): if result == nil { result = n == 1 ? "done" : "failed: \(n) files stored" }
            case .failed(let why): result = "failed: \(why)"
            case .group: break
            }
        }
    }
    // The transfer watchdog lives in GDTFileTransfer (no host answer for `stall` s); this is the outer bound in case
    // answers keep coming without data.
    while await onSession(session, { result == nil }) {
        if session.isClosed { break }
        let idle = await onSession(session) { Date().timeIntervalSince(lastData) }
        if idle > stall {
            await onSession(session) { gdt.files.cancelFetch("no data for \(Int(stall)) s") }
            _ = await waitFor(session, 5) { result != nil }
            break
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    let final = await onSession(session) { result }
    let duration = Date().timeIntervalSince(started)
    guard final == "done" else {
        await onSession(session) { gdt.files.cancelFetch("ended") }
        try? FileManager.default.removeItem(at: part)
        outcome = "transfer \(final ?? (session.isClosed ? "ended with the session" : "stalled")) after \(written) B: partial file removed"
        return nil
    }
    let target = HostFileFetch.destination(in: destDir, name: HostFileFetch.isValidName(name) ? name : "file")
    try FileManager.default.moveItem(at: part, to: target)
    let (sha, bytes) = try HostFileFetch.sha256(fileAt: target)
    guard bytes == entry.size else {
        outcome = "stored \(bytes) B but the host announced \(entry.size) B: \(target.path) kept for inspection"
        return nil
    }
    outcome = String(format: "stored %@: %llu B, SHA-256 %@, %.1f s (%.2f MiB/s)", target.path, bytes, sha, duration,
                     duration > 0 ? Double(bytes) / 1_048_576 / duration : 0)
    say(outcome)
    return target
}
