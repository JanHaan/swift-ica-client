import Carbon
import Foundation

/// Keyboard layout sync (backlog 2.3, D141): the Mac's current keyboard input source as a Windows keyboard layout id
/// (KLID), for the UI module's layout field at logon (docs/30 §5.6 @40; the stock client sends 0x407 from a German Mac
/// [L]) and for a layout change during the session. Scancodes are positional, so the session must use the layout the
/// Mac uses; Option-composed characters go as Unicode and do not depend on it.
public enum KeyboardLayoutSync {
    /// Mac input source id (`com.apple.keylayout.*`) → Windows KLID. Variants of one national layout share the KLID.
    public static let klids: [String: UInt32] = [
        "German": 0x0000_0407, "German-DIN-2137": 0x0000_0407, "Austrian": 0x0000_0407,
        "US": 0x0000_0409, "ABC": 0x0000_0409, "USExtended": 0x0000_0409, "ABC-Extended": 0x0000_0409,
        "USInternational-PC": 0x0002_0409,
        "British": 0x0000_0809, "British-PC": 0x0000_0809, "Irish": 0x0000_1809,
        "French": 0x0000_040C, "French-PC": 0x0000_040C, "French-numerical": 0x0000_040C,
        "Belgian": 0x0000_080C, "Canadian-CSA": 0x0001_1009, "SwissFrench": 0x0000_100C,
        "SwissGerman": 0x0000_0807,
        "Dutch": 0x0000_0413,
        "Spanish": 0x0000_040A, "Spanish-ISO": 0x0000_040A,
        "Italian": 0x0000_0410, "Italian-Pro": 0x0000_0410,
        "Dvorak": 0x0001_0409, "DVORAK-QWERTYCMD": 0x0001_0409,
        "Danish": 0x0000_0406, "Swedish": 0x0000_041D, "Swedish-Pro": 0x0000_041D, "Norwegian": 0x0000_0414,
        "Finnish": 0x0000_040B, "Portuguese": 0x0000_0816, "Brazilian": 0x0000_0416, "Brazilian-ABNT2": 0x0000_0416,
        "Polish": 0x0001_0415, "PolishPro": 0x0000_0415, "Czech": 0x0000_0405, "Czech-QWERTY": 0x0001_0405,
    ]

    /// The KLID for a Mac input source id, or nil for a layout we do not map (the caller keeps its default).
    public static func klid(forInputSource id: String) -> UInt32? {
        let prefix = "com.apple.keylayout."
        guard id.hasPrefix(prefix) else { return nil }
        return klids[String(id.dropFirst(prefix.count))]
    }

    /// The id of the current keyboard layout (an input method such as Pinyin reports its underlying layout).
    public static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The layout to announce: `ICA_KBD_LAYOUT` (hex KLID) if set, else the current input source's KLID, else 0x407.
    public static func sessionLayout(environment: [String: String] = ProcessInfo.processInfo.environment) -> (klid: UInt32, source: String) {
        if let text = environment["ICA_KBD_LAYOUT"], let v = UInt32(text, radix: 16) { return (v, "ICA_KBD_LAYOUT") }
        if let id = currentInputSourceID() {
            if let v = klid(forInputSource: id) { return (v, id) }
            return (0x0000_0407, "\(id) (not mapped, German)")
        }
        return (0x0000_0407, "no input source (German)")
    }

    /// Characters a key event may send as Unicode text instead of its scancode while the Mac's layout differs from the
    /// session's (D141): printable only (no control characters, no AppKit function-key range F700–F8FF).
    public static func isPrintable(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    /// The scancode of a letter (a–z) in a Windows layout, for shortcuts while the Mac's layout differs from the
    /// session's: Windows matches Ctrl shortcuts by the layout's letter, not by position. QWERTY unless the KLID is a
    /// QWERTZ, AZERTY or Dvorak layout we announce (all match `MapVirtualKeyEx` on the lab VDA, D167); nil for anything
    /// but one ASCII letter.
    public static func letterScancode(_ letter: String, klid: UInt32) -> UInt8? {
        guard letter.count == 1, let c = letter.unicodeScalars.first, ("a"..."z").contains(c) else { return nil }
        let qwertz: Set<UInt32> = [0x0000_0407, 0x0000_0807, 0x0000_100C, 0x0000_0405, 0x0001_0415]
        let rows: [(UInt8, String)]
        if klid == 0x0001_0409 { rows = [(0x13, "pyfgcrl"), (0x1E, "aoeuidhtns"), (0x2D, "qjkxbmwvz")] }   // Dvorak
        else if qwertz.contains(klid) { rows = [(0x10, "qwertzuiop"), (0x1E, "asdfghjkl"), (0x2C, "yxcvbnm")] }
        else if [0x040C, 0x080C].contains(klid & 0xFFFF) { rows = [(0x10, "azertyuiop"), (0x1E, "qsdfghjklm"), (0x2C, "wxcvbn")] }
        else { rows = [(0x10, "qwertyuiop"), (0x1E, "asdfghjkl"), (0x2C, "zxcvbnm")] }
        for (start, row) in rows {
            if let i = Array(row.unicodeScalars).firstIndex(of: c) { return start + UInt8(i) }
        }
        return nil
    }

    /// The scancode of the key Windows names by `character` (VK_OEM_PLUS, VK_OEM_MINUS, VK_OEM_COMMA, VK_OEM_PERIOD for
    /// + - , .) in a session layout, for shortcuts while the Mac's layout differs (D167); nil if that layout has no such
    /// key or we do not know the layout.
    public static func punctuationScancode(_ character: String, klid: UInt32) -> UInt8? {
        guard let i = "+-,.".firstIndex(of: Character(character.count == 1 ? character : " ")),
              let codes = oemScancodes[klid] else { return nil }
        let code = codes["+-,.".distance(from: "+-,.".startIndex, to: i)]
        return code == 0 ? nil : code
    }

    /// VK_OEM_PLUS, VK_OEM_MINUS, VK_OEM_COMMA, VK_OEM_PERIOD → scancode (0 = none) for every KLID we announce, as
    /// `MapVirtualKeyEx` gave them on the lab VDA (Windows Server 2022, `kbdtest` key probe, 2026-11-18) [L].
    static let oemScancodes: [UInt32: [UInt8]] = [
        0x0000_0405: [0x0C, 0x35, 0x33, 0x34], 0x0000_0406: [0x0C, 0x35, 0x33, 0x34], 0x0000_0407: [0x1B, 0x35, 0x33, 0x34],
        0x0000_0409: [0x0D, 0x0C, 0x33, 0x34], 0x0000_040A: [0x1B, 0x35, 0x33, 0x34], 0x0000_040B: [0x0C, 0x35, 0x33, 0x34],
        0x0000_040C: [0x0D, 0x00, 0x32, 0x33], 0x0000_0410: [0x1B, 0x35, 0x33, 0x34], 0x0000_0413: [0x27, 0x35, 0x33, 0x34],
        0x0000_0414: [0x0C, 0x35, 0x33, 0x34], 0x0000_0415: [0x0D, 0x0C, 0x33, 0x34], 0x0000_0416: [0x0D, 0x0C, 0x33, 0x34],
        0x0000_041D: [0x0C, 0x35, 0x33, 0x34], 0x0000_0807: [0x00, 0x35, 0x33, 0x34], 0x0000_0809: [0x0D, 0x0C, 0x33, 0x34],
        0x0000_080C: [0x35, 0x0D, 0x32, 0x33], 0x0000_0816: [0x1A, 0x35, 0x33, 0x34], 0x0000_100C: [0x00, 0x35, 0x33, 0x34],
        0x0000_1809: [0x0D, 0x0C, 0x33, 0x34], 0x0001_0405: [0x0D, 0x0C, 0x33, 0x34], 0x0001_0409: [0x1B, 0x28, 0x11, 0x12],
        0x0001_0415: [0x0C, 0x35, 0x33, 0x34], 0x0001_1009: [0x0D, 0x0C, 0x33, 0x34], 0x0002_0409: [0x0D, 0x0C, 0x33, 0x34],
    ]

    /// Posted (distributed) when the user picks another input source.
    public static let changedNotification = Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")
}
