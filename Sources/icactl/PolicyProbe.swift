import Foundation
import ICAKit

// MARK: - Policy probe (backlog 1.9, D115): which redirections the host opens for this user

/// `icactl policyprobe [resource]`: one fresh logon with the clipboard, client drive (an empty read-only temp folder),
/// printer (PDF) and audio (playback only, no capture device) engines announced. No input at all. It waits for the app
/// window, then `ICA_POLICYPROBE_SECONDS` (default 40) more, and logs off. Reports per channel whether the host used it
/// (CLIP_INIT, CDM CONNECT, CTXCPM commands, CTXCAM commands, host bytes per channel) and whether the session stayed
/// healthy (app window, no protocol error, clean logoff). `ICA_POLICYPROBE_EXPECT=on|off`: PASS only if every
/// redirection matches (on = the "everything on" policy, off = the restricted one).
func runPolicyProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let expect = env["ICA_POLICYPROBE_EXPECT"]?.lowercased()
    if let expect, !["on", "off"].contains(expect) { fail("ICA_POLICYPROBE_EXPECT must be on or off") }
    let hold = Double(env["ICA_POLICYPROBE_SECONDS"] ?? "") ?? 40
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("ica-policyprobe-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: folder) }

    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    var audioConfig = AudioEngine.Config()
    audioConfig.capabilities = AudioWire.Caps.playback
    audioConfig.microphone = false   // never a capture device
    // File copy (CTXGDT) is announced as ICA Viewer does with clipboard files on (D90), so its refusal shows too.
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipTestConfig(files: true),
                                 cdm: CDMEngine.Config(fileSystem: try CDMPOSIXFileSystem(root: folder, readOnly: true), letter: "M", label: "probe"),
                                 printing: PrinterEngine.Config(), audio: audioConfig, gdt: GDTEngine.Config())
    let seamless = session.seamless

    // Session-queue state.
    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var clipReady = false
    var cdmConnect = false
    var cdmProtocolError: String?
    var printCommands = 0
    var audioCommands = 0
    var hostBytes: [UInt8: Int] = [:]
    // The app's refusal rule (ICAKit RedirectionStatus, D118) on the same traffic, and when each channel spoke first.
    var redirections = RedirectionStatus(requested: Set(RedirectionFeature.allCases))
    let started = Date()
    var firstHostData: [RedirectionFeature: Double] = [:]
    var failures: [String] = []
    var terminateReason: UInt8?

    session.clipboard?.onEvent = { event in
        if case .trace = event { return }
        if case .ready = event { clipReady = true; say("clip: ready") }
        if case .protocolError = event { failures.append("clipboard: \(event)") }
    }
    session.cdm?.onEvent = { event in
        switch event {
        case .operation(let line):
            if line.hasPrefix("CONNECT") { cdmConnect = true; say("cdm: \(line)") }
        case .protocolError(let text): cdmProtocolError = text
        case .stopped: break
        }
    }
    session.printer?.onEvent = { event in
        if case .command(let line) = event {
            printCommands += 1
            if printCommands <= 3 { say("cpm: \(line)") }
        }
    }
    session.audio?.onEvent = { event in
        if case .command(let line) = event {
            audioCommands += 1
            if audioCommands <= 3 { say("audio: \(line)") }
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow {
                appWindows.append(w.id)
                redirections.appWindowShown(at: Date().timeIntervalSince(started))
            }
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
        case .wd(.initResponseSent(let modules, _)): say("→ INIT_RESPONSE modules \(modules.joined(separator: ", "))")
        case .wd(.packet(let p)):
            if let ch = p.channel {
                hostBytes[ch, default: 0] += p.payload.count
                if let f = redirections.hostData(channel: ch) { firstHostData[f] = Date().timeIntervalSince(started) }
            }
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        case .wd(.failure(let text)):
            failures.append("WD: \(text)")
            say("WD failure: \(text)")
        default: break
        }
    }

    try await session.start()
    let appWindow: () -> UInt32? = {
        appWindows.first { app.matches(executable: windowsSeen.single($0, seamless.model), appKey: windowsSeen.appKey($0)) }
    }
    let found = await waitFor(session, 150) { logon.isFresh && appWindow() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    if found {
        say("app window up; observing \(Int(hold)) s without input")
        let deadline = Date().addingTimeInterval(hold)
        while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 500_000_000) }
    } else {
        say("no \(app.resource) window within 150 s (fresh \(fresh))")
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

    let (clip, cdm, cpm, cam, bytes, errors, cdmError) = await onSession(session) {
        (clipReady, cdmConnect, printCommands, audioCommands, hostBytes, failures, cdmProtocolError)
    }
    let (tracker, firsts) = await onSession(session) { (redirections, firstHostData) }
    let used: [(String, Bool, String)] = [
        ("clipboard", clip, "CLIP_INIT \(clip ? "yes" : "no"), ch \(ClipboardWire.channelNumber) \(bytes[ClipboardWire.channelNumber] ?? 0) B"),
        ("drives", cdm, "CDM CONNECT \(cdm ? "yes" : "no"), ch \(CDMWire.channelNumber) \(bytes[CDMWire.channelNumber] ?? 0) B"),
        ("printers", cpm > 0 && (bytes[PrinterWire.channelNumber] ?? 0) > 0, "CTXCPM commands \(cpm), ch \(PrinterWire.channelNumber) \(bytes[PrinterWire.channelNumber] ?? 0) B"),
        // Host bytes, not command events: the engine also reports local steps (the microphone switched off at logoff).
        ("audio", (bytes[AudioWire.channelNumber] ?? 0) > 0, "CTXCAM events \(cam), ch \(AudioWire.channelNumber) \(bytes[AudioWire.channelNumber] ?? 0) B"),
    ]
    say("\n=== policyprobe summary (\(app.resource)) ===")
    say("fresh logon: \(fresh), app window: \(found), errors: \(errors.isEmpty && cdmError == nil ? "none" : (errors + [cdmError].compactMap { $0 }).joined(separator: "; "))")
    for (name, on, detail) in used { say("  \(name): \(on ? "ON" : "off") (\(detail))") }
    let now = Date().timeIntervalSince(started)
    let window = tracker.appWindowAt
    say("  app rule (RedirectionStatus, settle \(Int(tracker.settleSeconds)) s): refused ["
        + tracker.refused(at: now).map(\.rawValue).joined(separator: ", ") + "]; first host data after the app window: "
        + RedirectionFeature.allCases.map { f in
            "\(f.rawValue) " + (firsts[f].map { t in window.map { String(format: "%+.1f s", t - $0) } ?? String(format: "%.1f s", t) } ?? "none")
        }.joined(separator: ", "))
    say("  host bytes by channel: " + bytes.sorted { $0.key < $1.key }.map { "ch \($0.key) \($0.value) B" }.joined(separator: ", "))
    say("end: \(ending)")
    let healthy = fresh && found && errors.isEmpty && cdmError == nil && ending.hasPrefix("logged off")
    let matches = expect.map { e in used.allSatisfy { $0.1 == (e == "on") } } ?? true
    let matrix = used.map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: ", ")
    say("RESULT: \(healthy && matches ? "PASS" : "FAIL") policyprobe \(app.resource): \(matrix); expected \(expect ?? "(not set)"), "
        + "healthy \(healthy), end: \(ending)")
}
