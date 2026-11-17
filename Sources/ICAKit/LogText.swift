import Foundation

/// One log line (security review L-15, ASVS 16.4.1). Store and host names (apps, window titles, resources, errors from
/// a server) reach the log verbatim; a line break in one of them would start a forged line, with its own timestamp,
/// in the log file and in a problem report. Line breaks and other control characters become visible escapes.
public enum LogText {
    public static func oneLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsEscape) else { return text }
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s {
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case _ where needsEscape(s): out.append(contentsOf: String(format: "\\u{%X}", s.value).unicodeScalars)
            default: out.append(s)
            }
        }
        return String(out)
    }

    /// C0 controls except tab, DEL, C1 controls (NEL U+0085 included), and the Unicode line and paragraph separators.
    static func needsEscape(_ s: Unicode.Scalar) -> Bool {
        (s.value < 0x20 && s != "\t") || (0x7F...0x9F).contains(s.value) || s.value == 0x2028 || s.value == 0x2029
    }
}
