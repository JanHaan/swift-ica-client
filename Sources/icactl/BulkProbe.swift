import Foundation
import ICAKit

// MARK: - Bulk throughput probe (D135): EDT vs TCP independent of GDT's pacing

/// `icactl bulkprobe [seconds]` (lab, "Command Prompt", labuser4): one fresh logon; PowerShell opens
/// C:\Users\Public\edt-noise.ps1, a 1024×640 window of random noise redrawn every 50 ms, for `seconds` (default 30).
/// Noise does not compress, so the host sends as much as the link carries. The transport's received bytes (CGP framing
/// included) are sampled every second while the noise window is up: mean and median rate. Then `exit`, logoff.
/// Run with and without ICA_EDT=1 under the same `icalab.sh net set` profile to compare.
func runBulkProbe(ica: ICAFile, seconds: Int) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let layout = config.logon.keyboardLayout
    let session = try ICASession(ica: ica, configuration: config)
    let seamless = session.seamless

    var logon = newLogonDetector()
    var appWindows: [UInt32] = []
    var consoleUp = false
    var noiseWindow: UInt32?
    var noiseGone = false
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            if w.kind == .appWindow {
                appWindows.append(w.id)
                say("app window \(w.id) \"\(w.title)\"")
            }
            if w.kind == .appWindow, w.title.lowercased().contains("cmd.exe") { consoleUp = true }
            if w.title == "edt-noise" { noiseWindow = w.id; say("noise window \(w.id) up") }
        case .windowChanged(let w, _):
            if noiseWindow == nil, w.title == "edt-noise" { noiseWindow = w.id; say("noise window \(w.id) up") }
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
            if w.id == noiseWindow { noiseGone = true }
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): if text.hasPrefix("EDT") || text.contains("connected to") || text.contains("resum") { say(text) }
        case .closed(let reason): say("session closed: \(reason)")
        default: break
        }
    }
    func keys(_ sequence: String) async throws {
        for step in try AudioTestKeys.parse(sequence, keyboardLayout: layout) {
            session.sendInput { wd in
                for m in step.modifiers { wd.keyScancode(m, up: false) }
                wd.keyScancode(step.scancode, up: false)
                wd.keyScancode(step.scancode, up: true)
                for m in step.modifiers.reversed() { wd.keyScancode(m, up: true) }
            }
        }
    }
    func line(_ text: String) async throws {
        say("type: \(text)")
        session.sendInput { wd in
            for unit in text.utf16 { wd.keyUnicode(unit, flags: []); wd.keyUnicode(unit, flags: .up) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await keys("enter")
    }

    let t0 = Date()
    try await session.start()
    let found = await waitFor(session, 150) { logon.isFresh && consoleUp }
    let fresh = await onSession(session) { logon.isFresh }
    let logonSeconds = Date().timeIntervalSince(t0)
    var samples: [Double] = []
    var total = 0
    var measured = 0.0
    if found {
        say(String(format: "app window after %.1f s over %@", logonSeconds, session.transport.transportKind))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await line("powershell -nop -ep bypass -file C:\\Users\\Public\\edt-noise.ps1 -Seconds \(seconds)")
        let up = await waitFor(session, 30) { noiseWindow != nil }
        if up {
            // Skip the first second (window creation), then sample once a second until the window goes.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var last = session.transport.status.bytesReceived
            let start = Date()
            var lastAt = start
            while Date().timeIntervalSince(start) < Double(seconds) - 1.5 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if await onSession(session, { noiseGone }) || session.isClosed { break }
                let now = Date(), bytes = session.transport.status.bytesReceived
                samples.append(Double(bytes - last) / now.timeIntervalSince(lastAt))
                total += bytes - last
                last = bytes
                lastAt = now
            }
            measured = lastAt.timeIntervalSince(start)
            _ = await waitFor(session, Double(seconds) + 10) { noiseGone }
        } else {
            say("no noise window within 30 s")
        }
        try await line("exit")
        try await Task.sleep(nanoseconds: 1_000_000_000)
    } else {
        say("no app window within 150 s (fresh \(fresh))")
    }
    let kind = session.transport.transportKind
    var ending = "?"
    if session.isClosed { ending = "ended by the server" }
    else if !fresh { await session.close(); ending = "disconnected (not a fresh logon)" }
    else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed { ending = "logged off" } else { await session.close(); ending = "logoff timed out; disconnected" }
    }
    let sorted = samples.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let mean = measured > 0 ? Double(total) / measured : 0
    say(String(format: "RESULT: %@ bulkprobe %@: %.1f s measured, %.2f MB, mean %.2f MB/s, median %.2f MB/s, min %.2f, max %.2f; logon %.1f s; end: %@",
               samples.count >= 5 ? "PASS" : "FAIL", kind, measured, Double(total) / 1e6, mean / 1e6, median / 1e6,
               (sorted.first ?? 0) / 1e6, (sorted.last ?? 0) / 1e6, logonSeconds, ending))
}
