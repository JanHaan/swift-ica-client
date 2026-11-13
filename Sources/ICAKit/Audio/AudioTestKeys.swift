import Foundation

/// The key sequence of `icactl audiotest` for the sound test apps (`ICA_AUDIOTEST_KEYS`), e.g.
/// `ctrl+tab,tab,alt+t,esc`: comma-separated steps, each `[ctrl+][alt+][shift+]<key>`. Keys: a–z, 0–9, f1–f12,
/// tab, esc, enter, space, backspace, delete, up, down, left, right, home, end, pgup, pgdn. Enter and Space are sent only when they
/// are written in the sequence. Letters are mapped to the key that types them on the session layout (QWERTZ
/// swaps y and z). Anything unknown makes the whole sequence invalid, so nothing is sent.
public struct AudioTestKeyStep: Equatable, Sendable, CustomStringConvertible {
    public var ctrl = false
    public var alt = false
    public var shift = false
    /// Set-1 scancode of the key.
    public var scancode: UInt8
    /// Arrow/navigation keys: sent with the 0xE0 prefix.
    public var extended = false
    /// The step as written (lowercased), for logs.
    public var text: String

    public var description: String {
        text + String(format: " (%@%02X)", extended ? "E0 " : "", scancode)
    }

    /// Scancodes of the modifiers held around the key: left Ctrl, left Alt, left Shift.
    public var modifiers: [UInt8] { (ctrl ? [0x1D] : []) + (alt ? [0x38] : []) + (shift ? [0x2A] : []) }
}

public enum AudioTestKeys {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case empty
        case tooLong(Int)
        case unknownKey(String)
        case badStep(String)
        public var description: String {
            switch self {
            case .empty: return "empty key sequence"
            case .tooLong(let n): return "\(n) steps; at most \(AudioTestKeys.maxSteps)"
            case .unknownKey(let k): return "unknown key \"\(k)\""
            case .badStep(let s): return "bad step \"\(s)\""
            }
        }
    }

    public static let maxSteps = 30

    /// US positions (set 1); `qwertz` swaps y and z.
    static func scancode(_ key: String, qwertz: Bool) -> (UInt8, Bool)? {
        let letters: [Character: UInt8] = [
            "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14, "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19,
            "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22, "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26,
            "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F, "b": 0x30, "n": 0x31, "m": 0x32,
        ]
        if key.count == 1, let c = key.first {
            if var l = c.isLetter ? c : nil {
                if qwertz, l == "y" { l = "z" } else if qwertz, l == "z" { l = "y" }
                return letters[l].map { ($0, false) }
            }
            if let d = c.wholeNumberValue, c.isASCII { return (d == 0 ? 0x0B : UInt8(1 + d), false) }
        }
        if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) {
            return (n <= 10 ? UInt8(0x3A + n) : UInt8(0x57 + n - 11), false)
        }
        let named: [String: (UInt8, Bool)] = [
            "tab": (0x0F, false), "esc": (0x01, false), "enter": (0x1C, false), "space": (0x39, false),
            "backspace": (0x0E, false), "delete": (0x53, true),
            "up": (0x48, true), "down": (0x50, true), "left": (0x4B, true), "right": (0x4D, true),
            "home": (0x47, true), "end": (0x4F, true), "pgup": (0x49, true), "pgdn": (0x51, true),
        ]
        return named[key]
    }

    /// Parses the sequence; `keyboardLayout` is the session's (0x0407 German, 0x0807 Swiss German, … are QWERTZ).
    public static func parse(_ text: String, keyboardLayout: UInt32) throws -> [AudioTestKeyStep] {
        let qwertz = [0x0407, 0x0807, 0x0C07, 0x1007, 0x1407, 0x0405, 0x041B, 0x040E, 0x0415, 0x0424, 0x041A]
            .contains(Int(keyboardLayout & 0xFFFF))
        let raw = text.lowercased().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !(raw.count == 1 && raw[0].isEmpty) else { throw Failure.empty }
        guard raw.count <= maxSteps else { throw Failure.tooLong(raw.count) }
        return try raw.map { stepText in
            let parts = stepText.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard let key = parts.last, !key.isEmpty, !parts.dropLast().contains(where: \.isEmpty) else { throw Failure.badStep(stepText) }
            var step = AudioTestKeyStep(scancode: 0, text: stepText)
            for m in parts.dropLast() {
                switch m {
                case "ctrl": step.ctrl = true
                case "alt": step.alt = true
                case "shift": step.shift = true
                default: throw Failure.badStep(stepText)
                }
            }
            guard let (code, extended) = scancode(key, qwertz: qwertz) else { throw Failure.unknownKey(key) }
            step.scancode = code
            step.extended = extended
            return step
        }
    }
}
