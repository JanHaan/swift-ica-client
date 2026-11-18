import Carbon.HIToolbox

/// One Mac key event as the translator reads it: from an NSEvent of ICA Viewer, a helper app's forwarded event
/// (docs/99 §12), or a scripted test (`icactl kbdtest`). `characters` are nil for modifier changes.
public struct KeyStroke: Equatable {
    public struct Modifiers: OptionSet, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var characters: String?
    public var charactersIgnoringModifiers: String?
    public var isARepeat: Bool

    public init(keyCode: UInt16, modifiers: Modifiers = [], characters: String? = nil,
                charactersIgnoringModifiers: String? = nil, isARepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.isARepeat = isARepeat
    }
}

/// What a key event becomes in the session: a scancode make/break, or Unicode text (docs/30 §14.1).
public enum KeyOutput: Equatable {
    case key(KeyMap.Code, up: Bool)
    case text(String)
}

/// Mac key events → ICA keyboard input (docs/30 §14.1a, D141, D160). Scancodes for keys (the session's layout
/// applies); Unicode text for Option-composed characters and, while the Mac's input source differs from the session
/// layout (`textForPrintables`), for printable keys. Chords with Cmd or Ctrl are shortcuts and always go as modifier +
/// scancode; Cmd becomes Ctrl. Option alone is held back: it becomes Alt when a key needs it, an Alt tap when released
/// alone, and nothing when it only composed characters.
public final class KeyTranslator {
    /// The Mac's input source differs from the layout announced at logon (D141). Set by the session's owner.
    public var textForPrintables = false
    /// The KLID announced at logon: in text mode a shortcut's letter is placed where this layout has it.
    public var sessionLayout: UInt32 = 0x0000_0407
    /// Scancodes currently down on the server, to release on focus loss.
    public private(set) var down: Set<KeyMap.Code> = []
    /// Option is held but Alt has not been sent yet (it might compose a character, or be a lone tap).
    private var pendingAlt: KeyMap.Code?
    /// The held Option composed a character: its release is not an Alt tap.
    private var optionComposed = false
    /// Scancodes sent for a key code other than its position (text-mode shortcuts), for the matching key up.
    private var sentFor: [UInt16: KeyMap.Code] = [:]

    public init() {}

    private func press(_ code: KeyMap.Code, up: Bool, into out: inout [KeyOutput]) {
        if up { down.remove(code) } else { down.insert(code) }
        out.append(.key(code, up: up))
    }

    /// The scancode for a shortcut chord. Positional, unless the Mac's layout differs from the session's and the key
    /// types a letter: then the letter's key in the session layout (Cmd-Z after a switch QWERTY → QWERTZ stays undo).
    func shortcutCode(_ k: KeyStroke) -> KeyMap.Code? {
        let positional = KeyMap.scancode(k.keyCode)
        guard textForPrintables, positional != nil, let plain = k.charactersIgnoringModifiers?.lowercased(),
              let scancode = KeyboardLayoutSync.letterScancode(plain, klid: sessionLayout) else { return positional }
        return KeyMap.Code(scancode)
    }

    public func keyDown(_ k: KeyStroke) -> [KeyOutput] {
        var out: [KeyOutput] = []
        let m = k.modifiers
        if m.contains(.command) {
            // Cmd shortcuts not taken by our menu: Ctrl+key on the server (copy, paste, …).
            guard let code = shortcutCode(k) else { return [] }
            press(KeyMap.leftControl, up: false, into: &out)
            press(code, up: false, into: &out)
            press(code, up: true, into: &out)
            press(KeyMap.leftControl, up: true, into: &out)
            return out
        }
        if m.contains(.option), !m.contains(.control), let chars = k.characters, chars != k.charactersIgnoringModifiers,
           KeyboardLayoutSync.isPrintable(chars) {
            // Option-composed character (@ € | on a German Mac layout): text, and the Option was not an Alt.
            if pendingAlt != nil { optionComposed = true }
            return [.text(chars)]
        }
        if textForPrintables, !m.contains(.control), !m.contains(.option) {
            // Layout differs from the session's: the Mac's character, not the key position (D141). A dead key gives no
            // characters yet; it is swallowed and the composed character follows as text.
            if let chars = k.characters, KeyboardLayoutSync.isPrintable(chars) { return [.text(chars)] }
            if k.characters?.isEmpty ?? true, KeyMap.scancode(k.keyCode) != nil, KeyMap.isCharacterKey(k.keyCode) { return [] }
        }
        let code = m.contains(.control) ? shortcutCode(k) : KeyMap.scancode(k.keyCode)
        if let code {
            if let alt = pendingAlt { press(alt, up: false, into: &out); pendingAlt = nil }
            if code != KeyMap.scancode(k.keyCode) { sentFor[k.keyCode] = code }
            press(code, up: false, into: &out)    // repeats send another make code, as on a PC
        } else if let chars = k.characters, !chars.isEmpty {
            out.append(.text(chars))
        }
        return out
    }

    public func keyUp(_ k: KeyStroke) -> [KeyOutput] {
        if k.modifiers.contains(.command) { return [] }
        guard let code = sentFor.removeValue(forKey: k.keyCode) ?? KeyMap.scancode(k.keyCode), down.contains(code) else { return [] }
        var out: [KeyOutput] = []
        press(code, up: true, into: &out)
        return out
    }

    /// A modifier key changed; `k.modifiers` is the state after the change.
    public func flagsChanged(_ k: KeyStroke) -> [KeyOutput] {
        let keyCode = Int(k.keyCode)
        guard let code = KeyMap.scancode(k.keyCode) else { return [] }
        let m = k.modifiers
        var out: [KeyOutput] = []
        if keyCode == kVK_CapsLock {
            // One flagsChanged per toggle: tap Caps Lock on the server.
            press(code, up: false, into: &out)
            press(code, up: true, into: &out)
            return out
        }
        let isDown: Bool
        switch keyCode {
        case kVK_Shift, kVK_RightShift: isDown = m.contains(.shift) && !down.contains(code)
        case kVK_Control, kVK_RightControl: isDown = m.contains(.control) && !down.contains(code)
        case kVK_Option, kVK_RightOption: isDown = m.contains(.option) && !(down.contains(code) || pendingAlt == code)
        default: return []
        }
        if keyCode == kVK_Option || keyCode == kVK_RightOption {
            if isDown {
                pendingAlt = code
                optionComposed = false
            } else if pendingAlt == code {
                // Lone Option tap: an Alt tap on the server (menu activation). Not after it composed a character: that
                // tap would put the app's menu bar in focus and swallow the next keys (S17, D160).
                pendingAlt = nil
                if !optionComposed {
                    press(code, up: false, into: &out)
                    press(code, up: true, into: &out)
                }
                optionComposed = false
            } else if down.contains(code) {
                press(code, up: true, into: &out)
            }
            return out
        }
        if isDown { press(code, up: false, into: &out) } else if down.contains(code) { press(code, up: true, into: &out) }
        return out
    }

    /// Releases every key the server thinks is down (focus left our windows).
    public func releaseAll() -> [KeyOutput] {
        pendingAlt = nil
        optionComposed = false
        sentFor.removeAll()
        let out = down.map { KeyOutput.key($0, up: true) }
        down.removeAll()
        return out
    }
}

extension WinstationDriver {
    /// Sends translated key output: scancodes (E0-prefixed when extended) and text as Unicode key events, one per
    /// UTF-16 unit (a character outside the BMP as its surrogate pair), as inserts when cap 0x14 was negotiated.
    public func send(_ outputs: [KeyOutput]) {
        for output in outputs {
            switch output {
            case .key(let code, let up):
                if code.extended { keyScancodes([0xE0, code.code], up: up) } else { keyScancode(code.code, up: up) }
            case .text(let text):
                for unit in text.utf16 {
                    if unicodeInsertMode { keyUnicode(unit, flags: .insert) }
                    else { keyUnicode(unit, flags: []); keyUnicode(unit, flags: .up) }
                }
            }
        }
    }
}
