import Carbon.HIToolbox
import Foundation
import ICAKit

// MARK: - Keyboard layout test (backlog 2.3, D141)

/// `icactl kbdtest <klid hex> [resource]` (lab, default "Notepad"): one fresh logon announcing that keyboard layout in
/// the UI module, then fixed scancode sequences in Notepad, Ctrl+A, Ctrl+C, and the session's text compared with what
/// the layout must produce. The same scancodes give different characters under German and US, so a pass shows the
/// VDA applied the announced layout. Logoff discards the text.
///   A = 2C 15 28 0C (German "yzäß"), B = 15 2C ⇧03 1A (US "yz@["), C = AltGr+10 AltGr+09 AltGr+12 (German "@[€", only
///   sent for 0x407: under US, Right Alt would reach Notepad's menu).
/// `text` mode: the app's own path after a mid-session switch to a German Mac layout (S17, D160): `KeyTranslator` in
/// text mode turns German-Mac key strokes for "yz@[äß€𝄞" (@ [ € with their own Option press each; 𝄞 outside the
/// BMP as a surrogate pair) and then Ctrl-A, Ctrl-C into session input. It must arrive unchanged under any layout.
func runKbdTest(ica: ICAFile, app: TestApp, klid: UInt32, text textMode: Bool = false) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let unicodeString = "yz@[äß€𝄞"
    let expected: [UInt32: String] = textMode ? [0x0000_0407: unicodeString, 0x0000_0409: unicodeString, 0x0000_040C: unicodeString]
        : [0x0000_0407: "yzäß zy\"ü @[€", 0x0000_0409: "zy'- yz@["]
    guard let want = expected[klid] else { fail(String(format: "kbdtest knows 00000407 and 00000409, not %08x", klid)) }
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.logon.keyboardLayout = klid
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipTestConfig())
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless
    say(String(format: "keyboard layout announced in the UI module: %08x", klid))

    var logon = newLogonDetector()
    var appWindows: [(UInt32, String)] = []
    var ready = false
    var texts: [String] = []
    clip.onEvent = { event in
        switch event {
        case .ready: ready = true
        case .hostClipboard(let content, _, _): if let t = content.text { texts.append(t) }
        default: break
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            if w.kind == .appWindow { appWindows.append((w.id, w.title)); say("app window \(w.id) \"\(w.title)\"") }
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.onEvent = { event in
        if case .closed(let reason) = event { say("session closed: \(reason)") }
    }

    /// One key with modifiers (scancodes; 0x38 with `extended` = Right Alt / AltGr).
    struct Key { var code: UInt8; var shift = false; var altGr = false; var ctrl = false }
    func press(_ keys: [Key]) async throws {
        for k in keys {
            session.sendInput { wd in
                if k.ctrl { wd.keyScancode(0x1D, up: false) }
                if k.shift { wd.keyScancode(0x2A, up: false) }
                if k.altGr { wd.keyScancodes([0xE0, 0x38], up: false) }
                wd.keyScancode(k.code, up: false)
                wd.keyScancode(k.code, up: true)
                if k.altGr { wd.keyScancodes([0xE0, 0x38], up: true) }
                if k.shift { wd.keyScancode(0x2A, up: true) }
                if k.ctrl { wd.keyScancode(0x1D, up: true) }
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }
    /// Strokes as AppKit reports them: a plain key, or a modifier pressed and released around one key.
    func type(_ strokes: [Stroke], _ t: KeyTranslator) async throws {
        for stroke in strokes {
            var out: [KeyOutput] = []
            switch stroke {
            case .key(let code, let chars):
                let k = KeyStroke(keyCode: code, characters: chars, charactersIgnoringModifiers: chars)
                out = t.keyDown(k) + t.keyUp(k)
            case .chord(let mod, let code, let chars, let plain):
                let modKey = UInt16(mod == .option ? kVK_Option : kVK_Control)
                let k = KeyStroke(keyCode: code, modifiers: mod, characters: chars, charactersIgnoringModifiers: plain)
                out = t.flagsChanged(KeyStroke(keyCode: modKey, modifiers: mod)) + t.keyDown(k) + t.keyUp(k)
                    + t.flagsChanged(KeyStroke(keyCode: modKey))
            }
            session.sendInput { wd in wd.send(out) }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }
    let space = Key(code: 0x39)
    let a = [0x2C, 0x15, 0x28, 0x0C].map { Key(code: UInt8($0)) }
    let b = [Key(code: 0x15), Key(code: 0x2C), Key(code: 0x03, shift: true), Key(code: 0x1A)]
    let c = [Key(code: 0x10, altGr: true), Key(code: 0x09, altGr: true), Key(code: 0x12, altGr: true)]

    try await session.start()
    let found = await waitFor(session, 150) { logon.isFresh && ready && appWindows.contains { $0.1.lowercased().contains(app.titleWord ?? "notepad") } }
    let fresh = await onSession(session) { logon.isFresh }
    var got = ""
    if found {
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let translator = KeyTranslator()
        translator.textForPrintables = true
        translator.sessionLayout = klid
        if textMode {
            try await type(germanMacStrokes(), translator)
        } else {
            try await press(a + [space] + b + (klid == 0x0000_0407 ? [space] + c : []))
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let before = await onSession(session) { texts.count }
        if textMode {
            // Through the translator: Ctrl+letter goes where the session layout has the letter (A is 0x10 on AZERTY).
            try await type([.chord(.control, UInt16(kVK_ANSI_A), "\u{1}", "a"), .chord(.control, UInt16(kVK_ANSI_C), "\u{3}", "c")], translator)
        } else {
            // Ctrl+A, Ctrl+C by position: A is 0x10 on AZERTY (French, Belgian), else 0x1E; C is 0x2E everywhere here.
            let azerty = [0x040C, 0x080C].contains(klid & 0xFFFF)
            try await press([Key(code: azerty ? 0x10 : 0x1E, ctrl: true), Key(code: 0x2E, ctrl: true)])
        }
        _ = await waitFor(session, 10) { texts.count > before }
        got = await onSession(session) { texts.last ?? "" }
        // Notepad's scratch content is discarded by the logoff.
    } else {
        say("no app window within 150 s (fresh \(fresh))")
    }
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
    let text = got.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    say(String(format: "RESULT: %@ kbdtest %08x%@: expected \"%@\", got \"%@\"; end: %@", text == want ? "PASS" : "FAIL", klid, textMode ? " text" : "", want, text, ending))
}

/// A scripted Mac key stroke for `kbdtest` text mode.
enum Stroke {
    case key(UInt16, String)
    case chord(KeyStroke.Modifiers, UInt16, String, String)   // modifier, key code, characters, without modifiers
}

/// "yz@[äß€𝄞" on the German Mac layout (key codes are ANSI positions: y is at Z, z at Y, ä at Quote, ß at Minus).
/// 𝄞 stands for any character outside the BMP a key can give (a custom layout or the Unicode Hex Input source).
func germanMacStrokes() -> [Stroke] {
    [.key(UInt16(kVK_ANSI_Z), "y"), .key(UInt16(kVK_ANSI_Y), "z"),
     .chord(.option, UInt16(kVK_ANSI_L), "@", "l"), .chord(.option, UInt16(kVK_ANSI_5), "[", "5"),
     .key(UInt16(kVK_ANSI_Quote), "ä"), .key(UInt16(kVK_ANSI_Minus), "ß"),
     .chord(.option, UInt16(kVK_ANSI_E), "€", "e"), .key(UInt16(kVK_ANSI_Grave), "𝄞")]
}
