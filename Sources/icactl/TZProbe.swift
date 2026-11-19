import Foundation
import ICAKit

// MARK: - Client time zone probe (docs/30 §4.4)

/// `icactl tzprobe [resource]` (lab, default "Command Prompt"): one fresh logon that sends this process's time zone
/// (`TimeZone.current`, so `TZ=Asia/Kolkata icactl tzprobe` tries another zone) in caps 0x08/0x26. In the session
/// `C:\Users\Public\tz-show.ps1 -Clip` (scripts/vda/) puts the session's zone on the clipboard; the probe compares its Id
/// and current UTC offset with ours. `ICA_TZPROBE_EXPECT=client` (default) or `server` (the session keeps the VDA's zone,
/// as with the policy "Use server time zone" or `ICA_TZPROBE_SEND=0`, which leaves the caps out). Input only into this
/// run's own Command Prompt window; logoff at the end.
func runTZProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let zone = TimeZone.current
    let ours = WDTimeZone(zone)
    let send = env["ICA_TZPROBE_SEND"] != "0"
    let expectClient = (env["ICA_TZPROBE_EXPECT"] ?? (send ? "client" : "server")) == "client"
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    config.policy.timeZone = send ? zone : nil
    let offsetNow = zone.secondsFromGMT() / 60
    say("our zone: \(ours); UTC offset now \(offsetNow) min; caps 0x08/0x26 \(send ? "sent when offered" : "left out")")
    let layout = config.logon.keyboardLayout
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipTestConfig())
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless

    var logon = newLogonDetector()
    var appWindows: [UInt32] = []
    var ready = false
    var hostTexts: [String] = []
    var terminateReason: UInt8?
    var negotiatedZone: [String] = []

    clip.onEvent = { event in
        switch event {
        case .trace: return
        case .ready: ready = true
        case .hostClipboard(let content, _, _): if let t = content.text { hostTexts.append(t) }
        default: break
        }
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
        case .wd(.initResponseSent(_, let negotiated)):
            negotiatedZone = negotiated.filter { $0.id == WDCapability.timeZone || $0.id == WDTimeZone.extendedCapability }
                .map { String(format: "0x%02x", $0.id) + " (\($0.body.count + 4) B)" }
            say("→ time zone caps: \(negotiatedZone.isEmpty ? "none" : negotiatedZone.joined(separator: ", "))")
        case .wd(.terminate(let reason)): terminateReason = reason
        default: break
        }
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
        for step in try AudioTestKeys.parse("enter", keyboardLayout: layout) {
            session.sendInput { wd in
                wd.keyScancode(step.scancode, up: false)
                wd.keyScancode(step.scancode, up: true)
            }
        }
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    }

    try await session.start()
    // The clipboard may be off for the user (policy): then the window alone, and the result only in the VDA file.
    var windowSeen: Date?
    let found = await waitFor(session, 150) {
        if !appWindows.isEmpty, windowSeen == nil { windowSeen = Date() }
        return logon.isFresh && !appWindows.isEmpty && (ready || Date().timeIntervalSince(windowSeen ?? Date()) > 15)
    }
    let fresh = await onSession(session) { logon.isFresh }
    var verdicts: [String] = []
    var pass = false
    if found {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await line(#"powershell -nop -ep bypass -file C:\Users\Public\tz-show.ps1 -Clip"#, wait: 10)
        let shown = await onSession(session) { hostTexts.last { $0.hasPrefix("TZSHOW") } }
        if let shown {
            say("session: \(shown)")
            let fields = Dictionary(shown.dropFirst(7).components(separatedBy: " | ").compactMap { part -> (String, String)? in
                guard let eq = part.firstIndex(of: "=") else { return nil }
                return (String(part[..<eq]), String(part[part.index(after: eq)...]))
            }, uniquingKeysWith: { a, _ in a })
            let id = fields["id"] ?? "?"
            let offset = Double(fields["offset"] ?? "").map { Int($0.rounded()) }
            let idMatches = id == ours.standardName
            let offsetMatches = offset == offsetNow
            verdicts.append("session zone \(id) (ours \(ours.standardName)): \(idMatches ? "same" : "different")")
            verdicts.append("session UTC offset now \(offset.map(String.init) ?? "?") min (ours \(offsetNow)): \(offsetMatches ? "same" : "different")")
            pass = expectClient ? (idMatches && offsetMatches) : !(idMatches && offsetMatches)
        } else {
            verdicts.append("no TZSHOW line came back over the clipboard (clipboard \(await onSession(session) { ready } ? "ready" : "not open"));"
                            + " the session wrote it to C:\\Users\\Public\\tz-<user>.txt on the VDA")
        }
        try await line("exit", wait: 1)
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
    say("\n=== tzprobe summary (\(app.resource), \(zone.identifier), expect \(expectClient ? "client" : "server") zone) ===")
    say("  time zone caps sent: \(negotiatedZone.isEmpty ? "none" : negotiatedZone.joined(separator: ", "))")
    for v in verdicts { say("  \(v)") }
    say("  \(pass ? "PASS" : "FAIL")")
    say("end: \(ending)\(reason.map { " (TERMINATE reason \($0))" } ?? "")")
    if !pass { exit(1) }
}
