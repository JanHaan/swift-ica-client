import Foundation

/// Display-name censoring for screenshots (ICAVIEWER_SCREENSHOT=1): a resource name such as
/// "Calculator ABC" is shown without its trailing environment tag, and organisation words are
/// replaced. Pure, so it is unit-tested; the viewer applies it to every name it shows.
public enum DisplayName {
    /// Drops a trailing all-caps token of 2 to 4 letters after a space ("Word ABC" -> "Word"; the
    /// name is kept if nothing else is left), after replacing each `replacing` word (case-insensitive).
    public static func censored(_ name: String, replacing: [(word: String, with: String)] = []) -> String {
        var text = name
        for r in replacing where !r.word.isEmpty {
            text = text.replacingOccurrences(of: r.word, with: r.with, options: .caseInsensitive)
        }
        if let range = text.range(of: #" [A-Z]{2,4}$"#, options: .regularExpression),
           !text[..<range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Parses replacement rules, one `word=replacement` per line or separated by `;` (blank lines and
    /// `#` comments ignored). The rules live outside the source, in a private file or the environment.
    public static func parseReplacements(_ text: String) -> [(word: String, with: String)] {
        text.split(whereSeparator: { $0 == "\n" || $0 == ";" }).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let word = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            return word.isEmpty ? nil : (word, String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
    }
}
