import Carbon.HIToolbox
import Foundation
import ICAKit

// MARK: - Shortcut key probe (D167)

/// `ICA_KBDTEST_KEYS=1 icactl kbdtest <klid hex> [resource]` (lab, default "Command Prompt"): one fresh logon announcing
/// that layout. PowerShell in the session reads keys with `[Console]::ReadKey` (the virtual key Windows made of them)
/// until Enter; we send shortcut chords as a German Mac types them, through the app's `KeyTranslator` in text mode (the
/// Mac layout differs from the session's). PowerShell then puts the keys it read on the session clipboard, followed by
/// the layout facts behind the rule: for each KLID of `KeyboardLayoutSync.klids`, the scancodes `MapVirtualKeyEx` gives
/// for VK_OEM_PLUS, VK_OEM_MINUS, VK_OEM_COMMA, VK_OEM_PERIOD, A–Z and 0–9. Logoff discards the session.
func runKeyProbe(ica: ICAFile, app: TestApp, klid: UInt32) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
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
    var window: UInt32?
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
            if w.kind == .appWindow, window == nil { window = w.id; say("app window \(w.id) \"\(w.title)\"") }
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.onEvent = { event in
        if case .closed(let reason) = event { say("session closed: \(reason)") }
    }

    let probe = KeyProbe.strokes
    try await session.start()
    let found = await waitFor(session, 150) { logon.isFresh && ready && window != nil }
    let fresh = await onSession(session) { logon.isFresh }
    var got = ""
    if found, fresh, let target = await onSession(session, { window }) {
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let command = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "
            + AudioProbeScript.encoded(KeyProbe.script(klids: Set(KeyboardLayoutSync.klids.values).sorted()))
        let units = Array(command.utf16)
        for start in stride(from: 0, to: units.count, by: 200) {   // in chunks, as audioprobe (a burst lost characters)
            let chunk = units[start..<min(units.count, start + 200)]
            session.sendInput { wd in for unit in chunk { wd.keyUnicode(unit, flags: []); wd.keyUnicode(unit, flags: .up) } }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        session.sendInput { wd in wd.keyScancode(0x1C, up: false); wd.keyScancode(0x1C, up: true) }
        // PowerShell starts and waits in ReadKey (8 s was once too short: the keys reached cmd before it).
        try await Task.sleep(nanoseconds: 14_000_000_000)
        let translator = KeyTranslator()
        translator.textForPrintables = true
        translator.sessionLayout = klid
        try await typeStrokes(probe.map(\.stroke) + [.key(UInt16(kVK_Return), "\r")], translator, session)
        _ = await waitFor(session, 60) { !texts.isEmpty }
        got = await onSession(session) { texts.last ?? "" }
    } else {
        say("no fresh logon with a window within 150 s (fresh \(fresh)): no input sent")
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
    let lines = got.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
    let keys = lines.first?.split(separator: " ").map(String.init) ?? []
    for line in lines.dropFirst() { say("layout " + line) }
    var pass = keys.count == probe.count
    for (i, p) in probe.enumerated() {
        let read = i < keys.count ? keys[i] : "-"
        let want = p.expected(klid)
        if read != want { pass = false }
        say("\(p.name): read \(read), expected \(want)\(read == want ? "" : "  <-- differs")")
    }
    say(String(format: "RESULT: %@ kbdtest %08x keys: %d of %d keys as expected; end: %@", pass ? "PASS" : "FAIL", klid,
               zip(keys, probe).filter { $0 == $1.expected(klid) }.count, probe.count, ending))
}

enum KeyProbe {
    struct Probe {
        var name: String
        var stroke: Stroke
        /// ConsoleKey and modifiers as the script prints them, per session KLID (default: `other`).
        var expected: (UInt32) -> String
    }

    /// Shortcut chords on a German Mac (ISO key codes).
    static let strokes: [Probe] = [
        Probe(name: "Ctrl + (German + key)", stroke: .chord(.control, UInt16(kVK_ANSI_RightBracket), "\u{1D}", "+", levels: ["+", "*"]),
              expected: { _ in "OemPlus:Control" }),
        Probe(name: "Ctrl - (German - key)", stroke: .chord(.control, UInt16(kVK_ANSI_Slash), "\u{1F}", "-", levels: ["-", "_"]),
              expected: { _ in "OemMinus:Control" }),
        Probe(name: "Ctrl ,", stroke: .chord(.control, UInt16(kVK_ANSI_Comma), ",", ",", levels: [",", ";"]),
              expected: { _ in "OemComma:Control" }),
        Probe(name: "Ctrl .", stroke: .chord(.control, UInt16(kVK_ANSI_Period), ".", ".", levels: [".", ":"]),
              expected: { _ in "OemPeriod:Control" }),
        Probe(name: "Ctrl Shift 7 (German /)", stroke: .chord([.control, .shift], UInt16(kVK_ANSI_7), "/", "/", levels: ["7", "/"]),
              expected: { _ in "D7:Shift+Control" }),
        Probe(name: "Ctrl 1", stroke: .chord(.control, UInt16(kVK_ANSI_1), "1", "1", levels: ["1", "!"]),
              expected: { _ in "D1:Control" }),
        // Positional: the key right of Ä (ISO) is VK_OEM_2 in German, VK_OEM_5 (\) in US layouts.
        Probe(name: "Ctrl # (German # key)", stroke: .chord(.control, UInt16(kVK_ANSI_Backslash), "\u{1C}", "#", levels: ["#", "'"]),
              expected: { [0x0000_0407, 0x0000_0807].contains($0) ? "Oem2:Control" : "Oem5:Control" }),
        Probe(name: "Ctrl Z (German Z key)", stroke: .chord(.control, UInt16(kVK_ANSI_Y), "\u{1A}", "z", levels: ["z", "Z"]),
              expected: { _ in "Z:Control" }),
    ]

    /// Reads keys until Enter, then the layout table, all onto the clipboard (first line: the keys).
    static func script(klids: [UInt32]) -> String {
        let ids = klids.map { String(format: "'%08X'", $0) }.joined(separator: ",")
        return """
        [Console]::TreatControlCAsInput = $true
        Write-Host 'keyprobe: press keys, Enter ends'
        $r = @()
        while ($true) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Enter') { break }; $r += ('{0}:{1}' -f $k.Key, ($k.Modifiers -replace ', ', '+')) }
        Add-Type -Name K -Namespace W -MemberDefinition @'
        [DllImport("user32.dll")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
        [DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
        [DllImport("user32.dll")] public static extern uint MapVirtualKeyEx(uint code, uint type, IntPtr hkl);
        [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n, IntPtr[] list);
        '@
        $n = [W.K]::GetKeyboardLayoutList(0, $null); $loaded = New-Object IntPtr[] $n; [void][W.K]::GetKeyboardLayoutList($n, $loaded)
        $t = @()
        foreach ($id in @(\(ids))) {
            $h = [W.K]::LoadKeyboardLayout($id, 0x80)
            $v = @(0xBB, 0xBD, 0xBC, 0xBE) + (0x41..0x5A) + (0x30..0x39) | ForEach-Object { '{0:X2}' -f [W.K]::MapVirtualKeyEx($_, 0, $h) }
            $t += ($id + ' +-,.=' + ($v[0..3] -join ',') + ' A-Z=' + ($v[4..29] -join ',') + ' 0-9=' + ($v[30..39] -join ','))
            if ($loaded -notcontains $h) { [void][W.K]::UnloadKeyboardLayout($h) }
        }
        Set-Clipboard -Value (($r -join ' ') + "`n" + ($t -join "`n"))
        """
    }
}
