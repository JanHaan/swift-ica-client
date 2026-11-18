import Foundation
import ICAKit

// MARK: - Webcam probe (backlog 1.10)

/// `icactl camprobe [resource]` (lab, "Command Prompt"): HDX webcam redirection end to end with the synthetic test
/// pattern (`WebcamTestPattern`, never a camera; docs/98b §10.6). In the session the VDA checker
/// `C:\Users\Public\cam-grab.ps1` (scripts/vda/) opens "Citrix HDX Web Camera" with the lab's 32-bit VLC for 6 s and
/// reports frames, size and motion in the console and in `C:\Users\Public\camg-<user>.txt`. Here: every ch 18 command,
/// the §13 verdict, and the console as a picture. PASS when the host played the context and our samples went out.
/// Logs off at the end.
func runCamProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config, clipboard: nil, cdm: nil, printing: nil, audio: nil,
                                 webcam: WebcamEngine.Config())
    guard let webcam = session.webcam else { fail("no webcam engine") }
    webcam.source = WebcamTestPattern()
    let seamless = session.seamless

    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var terminateReason: UInt8?
    webcam.onEvent = { say("cam: \($0)") }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
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
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        default: break
        }
    }

    try await session.start()
    let window: () -> UInt32? = {
        appWindows.first { app.matches(executable: windowsSeen.single($0, seamless.model), appKey: windowsSeen.appKey($0)) }
    }
    let found = await waitFor(session, 150) { logon.isFresh && window() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { window() }
    var ran = false
    if !fresh {
        say("not a fresh logon by this run: no input is sent")
    } else if !found || target == nil {
        say("no \(app.resource) window: no input is sent")
    } else if let target {
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let command = #"powershell -nop -ep bypass -file C:\Users\Public\cam-grab.ps1 -Seconds 6 -Expect """#
        say("typing: \(command)")
        session.sendInput { wd in
            for unit in command.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
            wd.keyScancode(0x1C, up: false)
            wd.keyScancode(0x1C, up: true)
        }
        ran = true
        let wait = Double(env["ICA_CAMPROBE_WAIT"] ?? "") ?? 45
        say("watching \(Int(wait)) s")
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 500_000_000) }
        say(await audioTestScreenshot(session, target: target, index: 0, file: "camprobe-console"))
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
    let d = await onSession(session) { webcam.diagnostics }
    say("\n=== camprobe summary ===")
    say("commands: " + d.commandCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    say("controls: " + d.controls.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    say("device paths: \(d.recentDevicePaths); host format blocks: \(d.recentFormatBlocks)")
    say("samples \(d.samplesSent) (\(d.keyFramesSent) key, \(d.sampleBytesSent) B, \(d.fragmentsSent) fragments, largest \(d.largestSample) B); "
        + "skipped in flight \(d.framesSkippedInFlight), backlog \(d.framesSkippedBacklog); context errors \(d.contextErrors)")
    say("verdict: " + d.verdict(appOpenedCamera: ran))
    say("end: \(ending)")
    let pass = fresh && ran && (d.controls["PLAY"] ?? 0) > 0 && d.samplesSent > 0 && d.contextErrors == 0 && ending.hasPrefix("logged off")
    say("RESULT: \(pass ? "PASS" : "FAIL") camprobe: PLAY \(d.controls["PLAY"] ?? 0), samples \(d.samplesSent), end: \(ending)"
        + " (the VDA's frame count: C:\\Users\\Public\\camg-<user>.txt)")
}
