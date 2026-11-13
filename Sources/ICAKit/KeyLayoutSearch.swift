import Foundation

/// The key that types a character in a keyboard layout (docs/99 §12 phase 2: an Edit menu item is sent as
/// its shortcut, and scancodes are positional, so Paste on Dvorak is the key that types "v" there, not the
/// ANSI V position). `translate` gives the unmodified character of a macOS virtual key code in the current
/// layout (UCKeyTranslate in ICAViewer), nil when unknown.
public enum KeyLayoutSearch {
    /// Every virtual key code of a Mac keyboard.
    public static let keyCodes: Range<UInt16> = 0..<0x80

    /// ANSI positions of the letters (kVK_ANSI_*), used when the layout cannot be read.
    public static let ansiLetters: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
    ]

    public static func keyCode(typing character: String, translate: ((UInt16) -> String?)?) -> UInt16? {
        let wanted = character.lowercased()
        if let translate, let found = keyCodes.first(where: { translate($0)?.lowercased() == wanted }) { return found }
        return ansiLetters[wanted]
    }
}
