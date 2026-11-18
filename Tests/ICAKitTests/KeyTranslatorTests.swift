import Carbon.HIToolbox
import Testing
@testable import ICAKit

// Key translation (docs/30 §14.1a, D141, D160): shortcuts stay keys in text mode, Option that composed a character
// is not an Alt tap, shortcut letters follow the session layout after a switch.

private func code(_ c: UInt8, _ extended: Bool = false) -> ICAKit.KeyMap.Code { ICAKit.KeyMap.Code(c, extended: extended) }
private let leftAlt = code(0x38), leftCtrl = code(0x1D)

/// The German Mac layout typing into a session announced as US, as after S17's switch.
private func germanAfterSwitch() -> KeyTranslator {
    let t = KeyTranslator()
    t.sessionLayout = 0x0000_0409
    t.textForPrintables = true
    return t
}

/// Option held around one key that composes `char` (Option+L = @, Option+E = € on the German Mac layout).
private func optionChord(_ t: KeyTranslator, keyCode: Int, plain: String, char: String) -> [KeyOutput] {
    let key = KeyStroke(keyCode: UInt16(keyCode), modifiers: .option, characters: char, charactersIgnoringModifiers: plain)
    return t.flagsChanged(KeyStroke(keyCode: UInt16(kVK_Option), modifiers: .option))
        + t.keyDown(key) + t.keyUp(key)
        + t.flagsChanged(KeyStroke(keyCode: UInt16(kVK_Option)))
}

/// Ctrl held around one key (as a person or axrunner types it: the Control key's own events around the chord).
private func ctrlChord(_ t: KeyTranslator, keyCode: Int, plain: String) -> [KeyOutput] {
    let ctrl = Character(UnicodeScalar(UInt8(plain.unicodeScalars.first!.value - 0x60)))
    let key = KeyStroke(keyCode: UInt16(keyCode), modifiers: .control, characters: String(ctrl), charactersIgnoringModifiers: plain)
    return t.flagsChanged(KeyStroke(keyCode: UInt16(kVK_Control), modifiers: .control))
        + t.keyDown(key) + t.keyUp(key)
        + t.flagsChanged(KeyStroke(keyCode: UInt16(kVK_Control)))
}

@Test func optionComposedCharactersSendNoAlt() {
    for textMode in [false, true] {
        let t = KeyTranslator()
        t.textForPrintables = textMode
        #expect(optionChord(t, keyCode: kVK_ANSI_L, plain: "l", char: "@") == [.text("@")])
        #expect(optionChord(t, keyCode: kVK_ANSI_E, plain: "e", char: "€") == [.text("€")])
        #expect(t.down.isEmpty)
    }
}

@Test func loneOptionIsAnAltTapAndOptionWithAKeyIsAlt() {
    let t = KeyTranslator()
    let option = KeyStroke(keyCode: UInt16(kVK_Option), modifiers: .option)
    let release = KeyStroke(keyCode: UInt16(kVK_Option))
    #expect(t.flagsChanged(option).isEmpty)
    #expect(t.flagsChanged(release) == [.key(leftAlt, up: false), .key(leftAlt, up: true)])
    // Option+Left (no character): Alt+Left, Alt released with Option.
    let left = KeyStroke(keyCode: UInt16(kVK_LeftArrow), modifiers: .option, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}")
    #expect(t.flagsChanged(option).isEmpty)
    #expect(t.keyDown(left) == [.key(leftAlt, up: false), .key(code(0x4B, true), up: false)])
    #expect(t.keyUp(left) == [.key(code(0x4B, true), up: true)])
    #expect(t.flagsChanged(release) == [.key(leftAlt, up: true)])
}

@Test func ctrlShortcutsStayKeysInTextMode() {
    let t = germanAfterSwitch()
    let a = ctrlChord(t, keyCode: kVK_ANSI_A, plain: "a")
    #expect(a == [.key(leftCtrl, up: false), .key(code(0x1E), up: false), .key(code(0x1E), up: true), .key(leftCtrl, up: true)])
    let c = ctrlChord(t, keyCode: kVK_ANSI_C, plain: "c")
    #expect(c == [.key(leftCtrl, up: false), .key(code(0x2E), up: false), .key(code(0x2E), up: true), .key(leftCtrl, up: true)])
}

/// S17's failing sequence: "@€" typed with Option, then Ctrl-A, Ctrl-C. Before D160 each Option release was an Alt
/// tap, which put Notepad's menu bar in focus: € and the shortcuts went to the menu.
@Test func s17SequenceHasNoAltTap() {
    let t = germanAfterSwitch()
    var out = optionChord(t, keyCode: kVK_ANSI_L, plain: "l", char: "@")
    out += optionChord(t, keyCode: kVK_ANSI_E, plain: "e", char: "€")
    out += ctrlChord(t, keyCode: kVK_ANSI_A, plain: "a")
    out += ctrlChord(t, keyCode: kVK_ANSI_C, plain: "c")
    #expect(!out.contains(.key(leftAlt, up: false)))
    #expect(out.filter { if case .text = $0 { true } else { false } } == [.text("@"), .text("€")])
    #expect(t.down.isEmpty)
}

@Test func shortcutLettersFollowTheSessionLayoutInTextMode() {
    // German Mac: the key at the US Y position types z. Cmd-Z must stay undo in a US session (Ctrl + 0x2C).
    let cmdZ = KeyStroke(keyCode: UInt16(kVK_ANSI_Y), modifiers: .command, characters: "z", charactersIgnoringModifiers: "z")
    let t = germanAfterSwitch()
    #expect(t.keyDown(cmdZ) == [.key(leftCtrl, up: false), .key(code(0x2C), up: false), .key(code(0x2C), up: true), .key(leftCtrl, up: true)])
    // Layouts match (German session, scancode mode): positional, which is the same letter.
    let same = KeyTranslator()
    #expect(same.keyDown(cmdZ) == [.key(leftCtrl, up: false), .key(code(0x15), up: false), .key(code(0x15), up: true), .key(leftCtrl, up: true)])
    // Ctrl-Z in text mode: the mapped key goes down, and its key up releases the same scancode.
    let ctrlZ = KeyStroke(keyCode: UInt16(kVK_ANSI_Y), modifiers: .control, characters: "\u{1A}", charactersIgnoringModifiers: "z")
    #expect(t.keyDown(ctrlZ) == [.key(code(0x2C), up: false)])
    #expect(t.keyUp(KeyStroke(keyCode: UInt16(kVK_ANSI_Y))) == [.key(code(0x2C), up: true)])
    // Released on focus loss too.
    #expect(t.keyDown(ctrlZ) == [.key(code(0x2C), up: false)])
    #expect(t.releaseAll() == [.key(code(0x2C), up: true)])
    #expect(t.keyUp(KeyStroke(keyCode: UInt16(kVK_ANSI_Y))).isEmpty)
}

@Test func printableKeysAreTextOnlyInTextMode() {
    let y = KeyStroke(keyCode: UInt16(kVK_ANSI_Z), characters: "y", charactersIgnoringModifiers: "y")
    #expect(germanAfterSwitch().keyDown(y) == [.text("y")])
    #expect(KeyTranslator().keyDown(y) == [.key(code(0x2C), up: false)])
    // A dead key (no characters yet) is swallowed in text mode; return stays a key.
    #expect(germanAfterSwitch().keyDown(KeyStroke(keyCode: UInt16(kVK_ANSI_Equal), characters: "")).isEmpty)
    #expect(germanAfterSwitch().keyDown(KeyStroke(keyCode: UInt16(kVK_Return), characters: "\r")) == [.key(code(0x1C), up: false)])
}

@Test func letterScancodesPerSessionLayout() {
    #expect(KeyboardLayoutSync.letterScancode("a", klid: 0x0000_0409) == 0x1E)
    #expect(KeyboardLayoutSync.letterScancode("z", klid: 0x0000_0409) == 0x2C)
    #expect(KeyboardLayoutSync.letterScancode("z", klid: 0x0000_0407) == 0x15)
    #expect(KeyboardLayoutSync.letterScancode("y", klid: 0x0000_0407) == 0x2C)
    #expect(KeyboardLayoutSync.letterScancode("a", klid: 0x0000_040C) == 0x10)
    #expect(KeyboardLayoutSync.letterScancode("q", klid: 0x0000_080C) == 0x1E)
    #expect(KeyboardLayoutSync.letterScancode("w", klid: 0x0000_040C) == 0x2C)
    #expect(KeyboardLayoutSync.letterScancode("m", klid: 0x0000_040C) == 0x27)
    #expect(KeyboardLayoutSync.letterScancode("z", klid: 0x0001_0409) == 0x35)   // Dvorak
    #expect(KeyboardLayoutSync.letterScancode("c", klid: 0x0001_0409) == 0x17)
    #expect(KeyboardLayoutSync.letterScancode("a", klid: 0x0001_0409) == 0x1E)
    #expect(KeyboardLayoutSync.letterScancode("y", klid: 0x0002_0409) == 0x15)   // US International: QWERTY
    #expect(KeyboardLayoutSync.letterScancode("ä", klid: 0x0000_0407) == nil)
    #expect(KeyboardLayoutSync.letterScancode("1", klid: 0x0000_0409) == nil)
    #expect(KeyboardLayoutSync.letterScancode("ab", klid: 0x0000_0409) == nil)
}

// D167: dead keys compose on the Mac in both modes; shortcuts on + - , . follow the session layout in text mode; text
// from the macOS text input system goes as Unicode.

private func plain(_ t: KeyTranslator, _ keyCode: Int, _ chars: String, _ modifiers: KeyStroke.Modifiers = [],
                   composed: Bool = false) -> [KeyOutput] {
    let k = KeyStroke(keyCode: UInt16(keyCode), modifiers: modifiers, characters: chars, charactersIgnoringModifiers: chars,
                      composed: composed)
    return t.keyDown(k) + t.keyUp(k)
}

@Test func deadKeysComposeOnTheMacInBothModes() {
    for textMode in [false, true] {
        let t = KeyTranslator()
        t.textForPrintables = textMode
        // ^ e → ê, ´ e → é, ^ space → ^; ^ ^ → ^ with ^ still pending (the Mac layout's rule), then x → ^x.
        #expect(plain(t, kVK_ISO_Section, "") == [])
        #expect(plain(t, kVK_ANSI_E, "ê", composed: true) == [.text("ê")])
        #expect(plain(t, kVK_ANSI_Equal, "") == [])
        #expect(plain(t, kVK_ANSI_E, "é", composed: true) == [.text("é")])
        #expect(plain(t, kVK_ISO_Section, "") == [])
        #expect(plain(t, kVK_Space, "^", composed: true) == [.text("^")])
        #expect(plain(t, kVK_ISO_Section, "") == [])
        #expect(plain(t, kVK_ISO_Section, "^", composed: true) == [.text("^")])
        #expect(plain(t, kVK_ANSI_X, "^x", composed: true) == [.text("^x")])
        // After the composition, keys are as before: a scancode in scancode mode.
        #expect(plain(t, kVK_ANSI_X, "x") == (textMode ? [.text("x")] : [.key(code(0x2D), up: false), .key(code(0x2D), up: true)]))
        #expect(t.down.isEmpty)
    }
}

@Test func optionDeadKeyIsNoAlt() {
    // Option-N on a German Mac starts ~; n then gives ñ. Neither Alt+N nor an Alt tap may reach the session.
    let t = KeyTranslator()
    var out = t.flagsChanged(KeyStroke(keyCode: UInt16(kVK_Option), modifiers: .option))
    out += plain(t, kVK_ANSI_N, "", .option)
    out += t.flagsChanged(KeyStroke(keyCode: UInt16(kVK_Option)))
    out += plain(t, kVK_ANSI_N, "ñ", composed: true)
    #expect(out == [.text("ñ")])
}

@Test func controlCharacterAfterADeadKeyIsItsKey() {
    // ^ then Return: the layout gives "^\r": the accent as text, then Return as its key.
    let t = KeyTranslator()
    _ = plain(t, kVK_ISO_Section, "")
    let ret = KeyStroke(keyCode: UInt16(kVK_Return), characters: "^\r", composed: true)
    #expect(t.keyDown(ret) == [.text("^"), .key(code(0x1C), up: false)])
    #expect(t.keyUp(ret) == [.key(code(0x1C), up: true)])
}

@Test func punctuationShortcutsFollowTheSessionLayoutInTextMode() {
    func ctrl(_ t: KeyTranslator, _ keyCode: Int, _ plain: String, _ levels: [String], shift: Bool = false) -> KeyOutput? {
        let k = KeyStroke(keyCode: UInt16(keyCode), modifiers: shift ? [.control, .shift] : .control, characters: plain,
                          charactersIgnoringModifiers: plain, keyCharacters: levels)
        let out = t.keyDown(k)
        _ = t.keyUp(k)
        return out.first
    }
    let t = germanAfterSwitch()   // German Mac, US session
    #expect(ctrl(t, kVK_ANSI_RightBracket, "+", ["+", "*"]) == .key(code(0x0D), up: false))   // VK_OEM_PLUS
    #expect(ctrl(t, kVK_ANSI_Slash, "-", ["-", "_"]) == .key(code(0x0C), up: false))          // VK_OEM_MINUS
    #expect(ctrl(t, kVK_ANSI_Comma, ",", [",", ";"]) == .key(code(0x33), up: false))
    #expect(ctrl(t, kVK_ANSI_7, "/", ["7", "/"], shift: true) == .key(code(0x08), up: false)) // digits: positional
    #expect(ctrl(t, kVK_ANSI_Backslash, "#", ["#", "'"]) == .key(code(0x2B), up: false))      // other keys: positional
    #expect(t.down.isEmpty)
    // A US Mac in a German session: the =/+ key is the plus key there (0x1B).
    let us = KeyTranslator()
    us.textForPrintables = true
    #expect(ctrl(us, kVK_ANSI_Equal, "=", ["=", "+"]) == .key(code(0x1B), up: false))
    // Swiss German has no VK_OEM_PLUS: positional.
    us.sessionLayout = 0x0000_0807
    #expect(ctrl(us, kVK_ANSI_Equal, "=", ["=", "+"]) == .key(code(0x0D), up: false))
    // Layouts match (scancode mode): always positional.
    let same = KeyTranslator()
    #expect(ctrl(same, kVK_ANSI_RightBracket, "+", ["+", "*"]) == .key(code(0x1B), up: false))
}

@Test func punctuationScancodesPerSessionLayout() {
    #expect(KeyboardLayoutSync.punctuationScancode("+", klid: 0x0000_0409) == 0x0D)
    #expect(KeyboardLayoutSync.punctuationScancode("-", klid: 0x0000_0407) == 0x35)
    #expect(KeyboardLayoutSync.punctuationScancode("-", klid: 0x0000_040C) == nil)    // French: no VK_OEM_MINUS
    #expect(KeyboardLayoutSync.punctuationScancode(".", klid: 0x0001_0409) == 0x12)   // Dvorak
    #expect(KeyboardLayoutSync.punctuationScancode("+", klid: 0x0000_0807) == nil)
    #expect(KeyboardLayoutSync.punctuationScancode("#", klid: 0x0000_0407) == nil)
    #expect(KeyboardLayoutSync.punctuationScancode("+", klid: 0x0000_0C07) == nil)    // not a KLID we announce
    #expect(Set(KeyboardLayoutSync.klids.values).allSatisfy { KeyboardLayoutSync.oemScancodes[$0] != nil })
}

@Test func insertedTextGoesAsUnicode() {
    let t = KeyTranslator()
    #expect(t.insertText("🚀") == [.text("🚀")])
    #expect(t.insertText("é") == [.text("é")])
    #expect(t.insertText("\n").isEmpty)
}

/// The German Mac layout's own compositions (read from the layout, not the current input source).
@Test func deadKeyComposerFollowsTheMacLayout() {
    var c = DeadKeyComposer(inputSource: "com.apple.keylayout.German")
    func key(_ code: Int, shift: Bool = false, option: Bool = false) -> String? {
        c.characters(keyCode: UInt16(code), shift: shift, option: option, capsLock: false)
    }
    #expect(key(kVK_ISO_Section) == "")
    #expect(c.isComposing)
    #expect(key(kVK_ANSI_E) == "ê")
    #expect(!c.isComposing)
    #expect(key(kVK_ANSI_Equal) == "")
    #expect(key(kVK_ANSI_E) == "é")
    #expect(key(kVK_ANSI_Equal, shift: true) == "")
    #expect(key(kVK_ANSI_E) == "è")
    #expect(key(kVK_ISO_Section) == "")
    #expect(key(kVK_Space) == "^")
    #expect(key(kVK_ISO_Section) == "")
    #expect(key(kVK_ISO_Section) == "^")                 // ^ ^ → one ^, and ^ is still pending
    #expect(c.isComposing)
    #expect(key(kVK_ANSI_X) == "^x")
    #expect(key(kVK_ANSI_N, option: true) == "")
    #expect(key(kVK_ANSI_N) == "ñ")
    #expect(key(kVK_ISO_Section) == "")
    #expect(key(kVK_Return) == "^\r")
    #expect(key(kVK_ANSI_X) == "x")
}
