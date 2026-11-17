import Foundation
import ICAKit

// MARK: - Typing latency probe (backlog 1.7, D122)

/// `icactl typeprobe [resource]` (lab): in a fresh Notepad scratch tab, types `ICA_TYPEPROBE_KEYS` (default 20) single
/// characters 1.5 s apart and measures, per key, the time until the first screen update inside the Notepad window that
/// is not caret-sized (a rect at least 4 px wide and 8 px high): the echo of the key as the user would see it. Prints
/// median, p90 and max, and the CGP resumes of the run. Then clears the text and logs off. Run it under the lab's
/// `icalab.sh net set --rtt … --loss …` profiles.
func runTypeProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let count = max(1, min(100, Int(env["ICA_TYPEPROBE_KEYS"] ?? "") ?? 20))
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config)
    let seamless = session.seamless

    // Session-queue state.
    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var watch: (rect: CGRect, since: Date)?
    var echo: TimeInterval?
    var echoRect: CGRect?
    var resumes = 0
    var terminateReason: UInt8?

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
    session.thinwire.onUpdate = { rects in
        guard let w = watch, echo == nil else { return }
        if let hit = rects.first(where: { $0.width >= 4 && $0.height >= 8 && $0.intersects(w.rect) }) {
            echo = Date().timeIntervalSince(w.since)
            echoRect = hit
        }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .suspended(let info): say("CGP suspended: \(info.reason)")
        case .resumed:
            resumes += 1
            say("CGP resumed")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        default: break
        }
    }

    try await session.start()
    let notepad: () -> UInt32? = {
        appWindows.first { app.matches(executable: windowsSeen.single($0, seamless.model), appKey: windowsSeen.appKey($0)) }
    }
    let found = await waitFor(session, 150) { logon.isFresh && notepad() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { notepad() }
    var latencies: [TimeInterval] = []
    var misses = 0
    if !fresh {
        say("not a fresh logon by this run: no input is sent")
    } else if !found || target == nil {
        say("no \(app.resource) window: no input is sent")
    } else if let target {
        let scratch = NotepadScratch(session: session, target: target)
        if try await scratch.open() {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let rect = await onSession(session) { () -> CGRect in
                guard let w = seamless.model.windows[target] else { return .zero }
                let r = w.windowRect
                return CGRect(x: Int(r.left), y: Int(r.top), width: Int(r.right - r.left), height: Int(r.bottom - r.top))
            }
            say("typing \(count) keys 1.5 s apart into window \(target) \(rect)")
            for i in 0..<count {
                await onSession(session) { echo = nil; echoRect = nil; watch = (rect, Date()) }
                session.sendInput { wd in
                    wd.keyUnicode(UInt16(UInt8(ascii: "W")), flags: [])
                    wd.keyUnicode(UInt16(UInt8(ascii: "W")), flags: .up)
                }
                scratch.markTyped()
                _ = await waitFor(session, 5) { echo != nil }
                let (e, r) = await onSession(session) { (echo, echoRect) }
                await onSession(session) { watch = nil }
                if let e {
                    latencies.append(e)
                    say(String(format: "key %d: echo after %.0f ms (rect %@)", i + 1, e * 1000, "\(r ?? .zero)"))
                } else {
                    misses += 1
                    say("key \(i + 1): no echo within 5 s")
                }
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
            say(try await scratch.clear())
        } else {
            say("Ctrl+N: an unexpected window appeared; Esc, no further input")
        }
    }

    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            await session.close()
            ending = "logoff did not end the session in 40 s; disconnected"
        }
    }
    let sorted = latencies.sorted()
    func ms(_ q: Double) -> String {
        guard !sorted.isEmpty else { return "-" }
        return String(format: "%.0f", sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))] * 1000)
    }
    let res = await onSession(session) { resumes }
    say("\n=== typeprobe summary ===")
    say("keys \(count), echoes \(latencies.count), misses \(misses); latency ms: min \(ms(0)), median \(ms(0.5)), p90 \(ms(0.9)), max \(ms(1)); CGP resumes \(res)")
    say("end: \(ending)")
    let pass = fresh && !latencies.isEmpty && ending.hasPrefix("logged off")
    say("RESULT: \(pass ? "PASS" : "FAIL") typeprobe: median \(ms(0.5)) ms, p90 \(ms(0.9)) ms, max \(ms(1)) ms, misses \(misses), resumes \(res), end: \(ending)")
}
