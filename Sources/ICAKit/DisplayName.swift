import Foundation

/// Display-name censoring for screenshots (ICAVIEWER_SCREENSHOT=1): a resource name such as
/// "Calculator ABC" is shown without its trailing environment tag, and the organisation name is
/// replaced. Pure, so it is unit-tested; the viewer applies it to every name it shows.
public enum DisplayName {
    /// Words replaced anywhere in the name (case-insensitive).
    static let replacements: [(String, String)] = [("example", "example")]

    /// Drops a trailing all-caps token of 2 to 4 letters after a space ("Word ABC" -> "Word"; the
    /// name is kept if nothing else is left), and replaces the organisation name.
    public static func censored(_ name: String) -> String {
        var text = name
        for (word, replacement) in replacements {
            text = text.replacingOccurrences(of: word, with: replacement, options: .caseInsensitive)
        }
        if let range = text.range(of: #" [A-Z]{2,4}$"#, options: .regularExpression),
           !text[..<range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
