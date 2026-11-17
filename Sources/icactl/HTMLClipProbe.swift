import Foundation
import ICAKit

// MARK: - HTML clipboard probe (D130): does "HTML Format" cross CTXCLIP at all?

/// `icactl htmlprobe [resource]` (lab, default "Command Prompt"): one fresh logon. Windows PowerShell 5.1 is the HTML
/// source and sink, so no app's format preference is involved:
/// 1. host → Mac: `Set-Clipboard -AsHtml` puts "HTML Format" (and text) on the session clipboard; the host's FORMAT_LIST
///    and our fetch show whether the HTML id reaches us;
/// 2. Mac → host: we announce text + HTML, then `Get-Clipboard -TextFormatType Html | Set-Clipboard` reads the HTML
///    in the session (the host must fetch our HTML id) and puts it back as plain text, which we fetch and check for the
///    marker. Input only into this run's own Command Prompt window; logoff at the end.
func runHTMLClipProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let marker = "h\(String(UUID().uuidString.prefix(6)).lowercased())"
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let layout = config.logon.keyboardLayout
    var clipConfig = clipTestConfig()
    // Discovery switches (D130): ICA_CLIP_VERSION=4 (in clipTestConfig), ICA_CLIP_ECHO_NAMES=1 / 0.
    if let echo = env["ICA_CLIP_ECHO_NAMES"] { clipConfig.echoFormatNames = echo == "1" }
    say("clipboard: max version \(clipConfig.maxVersion), FORMAT_NAMES_REPLY with names \(clipConfig.echoFormatNames)")
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipConfig)
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless

    // Session-queue state.
    var logon = newLogonDetector()
    var appWindows: [UInt32] = []
    var ready = false
    var hostLists: [[UInt16]] = []
    var hostContents: [ClipboardContent] = []
    var hostRequests: [(UInt16, Bool, Int)] = []
    var announced: [[UInt16]] = []
    var terminateReason: UInt8?

    clip.onEvent = { event in
        switch event {
        case .trace: return
        case .ready: ready = true
        case .hostFormats(let ids): hostLists.append(ids)
        case .hostClipboard(let content, _, _): hostContents.append(content)
        case .hostRequest(let format, let served, let bytes): hostRequests.append((format, served, bytes))
        case .announced(let ids): announced.append(ids)
        default: break
        }
        say("clip: \(event)")
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\"")
        case .windowRemoved(let w): appWindows.removeAll { $0 == w.id }
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
        case .wd(.terminate(let reason)): terminateReason = reason
        default: break
        }
    }

    func keys(_ sequence: String, wait: Double = 1) async throws {
        for step in try AudioTestKeys.parse(sequence, keyboardLayout: layout) {
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
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    }
    func line(_ text: String, wait: Double) async throws {
        say("type: \(text)")
        session.sendInput { wd in
            for unit in text.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        try await keys("enter", wait: wait)
    }
    func label(_ ids: [UInt16]) async -> String { await onSession(session) { ids.map { clip.label($0) }.joined(separator: ", ") } }

    try await session.start()
    let found = await waitFor(session, 150) { logon.isFresh && ready && !appWindows.isEmpty }
    let fresh = await onSession(session) { logon.isFresh }
    var verdicts: [String] = []
    if found {
        let htmlId = await onSession(session) { clip.registeredId(ClipboardFormat.htmlName) }
        say("host registered \"HTML Format\" as \(htmlId.map { String(format: "0x%04x", $0) } ?? "nothing")")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await line("powershell -noprofile", wait: 6)

        /// The text the session put on its clipboard after `command` (the host lists text, we fetch it).
        func textAfter(_ command: String) async throws -> String {
            let n = await onSession(session) { hostContents.count }
            try await line(command, wait: 6)
            return await onSession(session) { Array(hostContents.dropFirst(n)).compactMap(\.text).last ?? "" }
        }
        // 0. control: plain text from the session reaches us.
        let control0 = try await textAfter("Set-Clipboard -Value '\(marker)-plain'")
        verdicts.append("control: session plain text reached the Mac \(control0.contains("\(marker)-plain"))")

        // 1. host → Mac
        let before1 = await onSession(session) { hostLists.count }
        try await line("Set-Clipboard -AsHtml -Value '<b>\(marker)-h2m</b> plain'", wait: 6)
        let (lists1, contents1) = await onSession(session) { (Array(hostLists.dropFirst(before1)), hostContents) }
        for l in lists1 { say("host list after Set-Clipboard -AsHtml: \(await label(l))") }
        let htmlListed = lists1.contains { l in htmlId.map { l.contains($0) } ?? false }
        let htmlGot = contents1.last?.html?.contains("\(marker)-h2m") == true
        verdicts.append("host→Mac: HTML id in host list \(htmlListed), HTML fetched with the marker \(htmlGot)")
        // 1b. control: the HTML really is on the session clipboard (read locally in the session, sent back as text).
        let local = try await textAfter("Get-Clipboard -TextFormatType Html | Set-Clipboard")
        say("session's own HTML read back as text (\(local.utf8.count) B): \(local.prefix(300))")
        verdicts.append("control: Set-Clipboard -AsHtml left HTML on the session clipboard \(local.contains("\(marker)-h2m"))")

        // 2. Mac → host
        let before2 = await onSession(session) { (hostRequests.count, hostContents.count) }
        session.clipboardAnnounce(ClipboardSnapshot(content: ClipboardContent(text: "\(marker)-m2h text",
                                                                              html: "<p><b>\(marker)-m2h</b> html</p>")))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let ours = await onSession(session) { announced.last ?? [] }
        say("our announce: \(await label(ours))")
        try await line("Get-Clipboard -TextFormatType Html | Set-Clipboard", wait: 6)
        let (requests, contents2) = await onSession(session) {
            (Array(hostRequests.dropFirst(before2.0)), Array(hostContents.dropFirst(before2.1)))
        }
        for r in requests { say(String(format: "host requested 0x%04x (%@): served %@, %d B", r.0, await label([r.0]), r.1 ? "yes" : "no", r.2)) }
        let htmlRequested = requests.contains { r in htmlId == r.0 }
        let back = contents2.compactMap(\.text).last ?? ""
        say("text back from the session (\(back.utf8.count) B): \(back.prefix(300))")
        verdicts.append("Mac→host: host requested our HTML id \(htmlRequested), the session read our HTML back "
                        + "\(back.contains("\(marker)-m2h</b>"))")
        // 2b. control: our text reached the session.
        session.clipboardAnnounce(ClipboardSnapshot(content: ClipboardContent(text: "\(marker)-m2h text2",
                                                                              html: "<p><b>\(marker)-m2h</b> html</p>")))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let text2 = try await textAfter("Get-Clipboard | Set-Clipboard")
        verdicts.append("control: our announced text reached the session \(text2.contains("\(marker)-m2h text2"))")
        try await line("exit", wait: 2)
    } else {
        say("no app window within 150 s (fresh \(fresh))")
    }

    var ending = "?"
    if session.isClosed {
        ending = "ended by the server"
    } else if !fresh {
        await session.close()
        ending = "disconnected (not a fresh logon)"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed { ending = "logged off" } else { await session.close(); ending = "logoff timed out; disconnected" }
    }
    let reason = await onSession(session) { terminateReason }
    say("\n=== htmlprobe summary (\(app.resource), marker \(marker)) ===")
    for v in verdicts { say("  \(v)") }
    say("end: \(ending)\(reason.map { " (TERMINATE reason \($0))" } ?? "")")
}
