import Carbon.HIToolbox

/// macOS virtual key codes (kVK_*) → PC scancode set 1. Scancodes are positional, so the
/// session's keyboard layout (announced at logon, D141) decides the character. Extended keys carry 0xE0.
public enum KeyMap {
    public struct Code: Equatable, Hashable {
        public var extended: Bool
        public var code: UInt8
        public init(_ code: UInt8, extended: Bool = false) { self.code = code; self.extended = extended }
    }

    /// ISO keyboards (German Mac keyboards) swap the two keys around the left shift/1 key
    /// compared with ANSI: kVK_ISO_Section is the key left of 1 (PC 0x29), kVK_ANSI_Grave
    /// is the key right of the left shift (PC 0x56).
    public static var isISO: Bool = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO

    public static func scancode(_ keyCode: UInt16) -> Code? {
        switch Int(keyCode) {
        case kVK_ISO_Section: return Code(isISO ? 0x29 : 0x56)
        case kVK_ANSI_Grave: return Code(isISO ? 0x56 : 0x29)
        default: return table[Int(keyCode)]
        }
    }

    /// Keys that type a character in some layout (letters, digits, punctuation, the ISO key): a dead key among them gives
    /// no characters on its own (D141). Not space, return, tab, escape, delete, keypad or function keys.
    public static func isCharacterKey(_ keyCode: UInt16) -> Bool { characterKeys.contains(Int(keyCode)) }

    static let characterKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
        kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
        kVK_ANSI_9, kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
        kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
        kVK_ISO_Section,
    ]

    static let table: [Int: Code] = {
        var t: [Int: Code] = [
            kVK_ANSI_A: Code(0x1E), kVK_ANSI_S: Code(0x1F), kVK_ANSI_D: Code(0x20), kVK_ANSI_F: Code(0x21),
            kVK_ANSI_H: Code(0x23), kVK_ANSI_G: Code(0x22), kVK_ANSI_Z: Code(0x2C), kVK_ANSI_X: Code(0x2D),
            kVK_ANSI_C: Code(0x2E), kVK_ANSI_V: Code(0x2F), kVK_ANSI_B: Code(0x30), kVK_ANSI_Q: Code(0x10),
            kVK_ANSI_W: Code(0x11), kVK_ANSI_E: Code(0x12), kVK_ANSI_R: Code(0x13), kVK_ANSI_Y: Code(0x15),
            kVK_ANSI_T: Code(0x14), kVK_ANSI_1: Code(0x02), kVK_ANSI_2: Code(0x03), kVK_ANSI_3: Code(0x04),
            kVK_ANSI_4: Code(0x05), kVK_ANSI_6: Code(0x07), kVK_ANSI_5: Code(0x06), kVK_ANSI_Equal: Code(0x0D),
            kVK_ANSI_9: Code(0x0A), kVK_ANSI_7: Code(0x08), kVK_ANSI_Minus: Code(0x0C), kVK_ANSI_8: Code(0x09),
            kVK_ANSI_0: Code(0x0B), kVK_ANSI_RightBracket: Code(0x1B), kVK_ANSI_O: Code(0x18), kVK_ANSI_U: Code(0x16),
            kVK_ANSI_LeftBracket: Code(0x1A), kVK_ANSI_I: Code(0x17), kVK_ANSI_P: Code(0x19), kVK_Return: Code(0x1C),
            kVK_ANSI_L: Code(0x26), kVK_ANSI_J: Code(0x24), kVK_ANSI_Quote: Code(0x28), kVK_ANSI_K: Code(0x25),
            kVK_ANSI_Semicolon: Code(0x27), kVK_ANSI_Backslash: Code(0x2B), kVK_ANSI_Comma: Code(0x33),
            kVK_ANSI_Slash: Code(0x35), kVK_ANSI_N: Code(0x31), kVK_ANSI_M: Code(0x32), kVK_ANSI_Period: Code(0x34),
            kVK_Tab: Code(0x0F), kVK_Space: Code(0x39), kVK_Delete: Code(0x0E), kVK_Escape: Code(0x01),
            // Modifiers (flagsChanged). Right Option = AltGr.
            kVK_Shift: Code(0x2A), kVK_RightShift: Code(0x36), kVK_CapsLock: Code(0x3A),
            kVK_Option: Code(0x38), kVK_RightOption: Code(0x38, extended: true),
            kVK_Control: Code(0x1D), kVK_RightControl: Code(0x1D, extended: true),
            // Keypad.
            kVK_ANSI_KeypadDecimal: Code(0x53), kVK_ANSI_KeypadMultiply: Code(0x37), kVK_ANSI_KeypadPlus: Code(0x4E),
            kVK_ANSI_KeypadClear: Code(0x45), kVK_ANSI_KeypadDivide: Code(0x35, extended: true),
            kVK_ANSI_KeypadEnter: Code(0x1C, extended: true), kVK_ANSI_KeypadMinus: Code(0x4A),
            kVK_ANSI_Keypad0: Code(0x52), kVK_ANSI_Keypad1: Code(0x4F), kVK_ANSI_Keypad2: Code(0x50),
            kVK_ANSI_Keypad3: Code(0x51), kVK_ANSI_Keypad4: Code(0x4B), kVK_ANSI_Keypad5: Code(0x4C),
            kVK_ANSI_Keypad6: Code(0x4D), kVK_ANSI_Keypad7: Code(0x47), kVK_ANSI_Keypad8: Code(0x48),
            kVK_ANSI_Keypad9: Code(0x49),
            // Function keys.
            kVK_F1: Code(0x3B), kVK_F2: Code(0x3C), kVK_F3: Code(0x3D), kVK_F4: Code(0x3E), kVK_F5: Code(0x3F),
            kVK_F6: Code(0x40), kVK_F7: Code(0x41), kVK_F8: Code(0x42), kVK_F9: Code(0x43), kVK_F10: Code(0x44),
            kVK_F11: Code(0x57), kVK_F12: Code(0x58), kVK_F13: Code(0x64), kVK_F14: Code(0x65), kVK_F15: Code(0x66),
            // Navigation (extended).
            kVK_Help: Code(0x52, extended: true), kVK_Home: Code(0x47, extended: true),
            kVK_PageUp: Code(0x49, extended: true), kVK_ForwardDelete: Code(0x53, extended: true),
            kVK_End: Code(0x4F, extended: true), kVK_PageDown: Code(0x51, extended: true),
            kVK_LeftArrow: Code(0x4B, extended: true), kVK_RightArrow: Code(0x4D, extended: true),
            kVK_DownArrow: Code(0x50, extended: true), kVK_UpArrow: Code(0x48, extended: true),
        ]
        t[kVK_ANSI_KeypadEquals] = Code(0x0D)
        return t
    }()

    /// The key that types `character` (a letter) in the current keyboard layout, for a menu command sent
    /// as its shortcut (scancodes are positional: on a German layout Z is kVK_ANSI_Y, on Dvorak V is
    /// kVK_ANSI_Period). Every key code is searched; the ANSI position when the layout has no Unicode data.
    public static func keyCode(typing character: String) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return KeyLayoutSearch.keyCode(typing: character, translate: nil)
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt16? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return KeyLayoutSearch.keyCode(typing: character, translate: nil)
            }
            return KeyLayoutSearch.keyCode(typing: character) { code in
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                return status == noErr ? String(utf16CodeUnits: chars, count: length) : nil
            }
        }
    }

    /// The characters a key types on its base and Shift levels in the current keyboard layout (no dead-key state; a
    /// dead key gives its accent), for shortcuts on punctuation keys in text mode (D167). Empty without layout data.
    public static func characters(keyCode: UInt16) -> [String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> [String] in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return [] }
            return [UInt32(0), UInt32(shiftKey >> 8)].compactMap { modifiers in
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
            }
        }
    }

    public static let leftControl = Code(0x1D)
    public static let leftAlt = Code(0x38)
}

/// Dead-key composition the way the Mac's text system does it (D167): AppKit gives a view that does not route key
/// events through an input context the dead key with no characters and the next key **uncomposed** (S17 VM run:
/// ^ e arrived as "e"). This keeps the layout's dead-key state across key downs and returns the composed characters
/// (UCKeyTranslate, the current keyboard layout or a given one).
public struct DeadKeyComposer {
    private var state: UInt32 = 0
    private var layoutID: String?
    private let fixedSource: String?

    /// `inputSource`: a layout id (`com.apple.keylayout.German`) for tests; nil = the current keyboard layout.
    public init(inputSource: String? = nil) { fixedSource = inputSource }

    /// A dead key is waiting for the next key (UCKeyTranslate keeps other bits in the state's upper half after a
    /// composition: 0x10000 after ^ e).
    public var isComposing: Bool { state & 0xFFFF != 0 }

    public mutating func reset() { state = 0 }

    /// The characters of a key down with Shift, Option and Caps Lock as given, under the layout's dead-key state: ""
    /// for a dead key (the state now waits), the composition for the key after it. nil without layout data.
    public mutating func characters(keyCode: UInt16, shift: Bool, option: Bool, capsLock: Bool) -> String? {
        guard let (id, data) = layout() else { state = 0; return nil }
        if id != layoutID { state = 0; layoutID = id }   // another input source: a pending dead key is void
        var modifiers: UInt32 = 0
        if shift { modifiers |= UInt32(shiftKey >> 8) }
        if capsLock { modifiers |= UInt32(alphaLock >> 8) }
        if option { modifiers |= UInt32(optionKey >> 8) }
        var dead = state
        let result: String? = data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), 0,
                                        &dead, chars.count, &length, &chars)
            return status == noErr ? String(utf16CodeUnits: chars, count: length) : nil
        }
        state = result == nil ? 0 : dead
        return result
    }

    private func layout() -> (String, Data)? {
        let source: TISInputSource?
        if let fixedSource {
            let filter = [kTISPropertyInputSourceID as String: fixedSource] as CFDictionary
            source = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        } else {
            source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        return (id, Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data)
    }
}
