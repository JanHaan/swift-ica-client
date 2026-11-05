import Foundation

/// A validated path below the drive root (docs/95 §A.2, §A.7): real name components, never empty, ".",
/// "..", a device name or anything with `\ / : * ? " < > |`, NUL or control characters. NFC.
public struct CDMPath: Hashable, Sendable, CustomStringConvertible {
    public private(set) var components: [String]

    public init(_ components: [String] = []) { self.components = components }

    public static let root = CDMPath()
    public var isRoot: Bool { components.isEmpty }
    public var name: String? { components.last }
    public var parent: CDMPath { CDMPath(Array(components.dropLast())) }
    public func appending(_ name: String) -> CDMPath { CDMPath(components + [name]) }

    /// For logs: relative to the shared folder, `/`-separated; the root is "/".
    public var description: String { isRoot ? "/" : components.joined(separator: "/") }

    /// Case-folded form, as a key for per-directory tables (Windows lookups are case-insensitive).
    public var key: String { components.map(CDMNames.fold).joined(separator: "/") }
}

/// Wire strings, path parsing, name rules, wildcards and 8.3 names.
public enum CDMNames {
    /// Paths longer than this are refused (§A.7 item 5).
    public static let maxPathBytes = 32 * 1024
    /// One name: APFS's limit in UTF-8 bytes.
    public static let maxNameBytes = 255

    static let reserved: Set<Unicode.Scalar> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
    static let wildcards: Set<Unicode.Scalar> = ["*", "?", "<", ">", "\""]
    static let devices: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$"]
        for i in 0...9 { s.insert("COM\(i)"); s.insert("LPT\(i)") }
        for sup in ["¹", "²", "³"] { s.insert("COM" + sup); s.insert("LPT" + sup) }
        return s
    }()

    /// Case folding for lookups: NFC, then each character upper-cased only where that gives exactly one
    /// character (Windows' simple upper-casing): "ß" stays "ß" (not "SS"), "ﬁ" stays "ﬁ" (not "FI"), so
    /// STRASSE.TXT never names straße.txt.
    public static func fold(_ name: String) -> String {
        if name.utf8.allSatisfy({ $0 < 0x80 }) { return name.uppercased() }  // ASCII: always one-to-one
        var out = ""
        for c in name.precomposedStringWithCanonicalMapping {
            let upper = String(c).uppercased()
            if upper.count == 1, upper.unicodeScalars.count == String(c).unicodeScalars.count { out += upper } else { out.append(c) }
        }
        return out
    }

    /// A wire string: UTF-8 when CONNECT negotiated it ("V2"), else one byte per code point ("V1",
    /// docs/95 §A.2). Nil for invalid UTF-8.
    public static func decode(_ bytes: Data, utf8: Bool) -> String? {
        if utf8 { return String(data: bytes, encoding: .utf8) }
        return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    /// A name for the wire: UTF-8, or (V1) ASCII with `?` for everything else (§A.8 step 3).
    public static func encode(_ text: String, utf8: Bool) -> Data {
        if utf8 { return Data(text.precomposedStringWithCanonicalMapping.utf8) }
        return Data(text.precomposedStringWithCanonicalMapping.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : 0x3F })
    }

    /// Whether `name` is a name the session may use (and that we list): see `CDMPath`. With `pattern`,
    /// the wildcards `* ? < > "` are allowed.
    public static func isValidName(_ name: String, pattern: Bool = false) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxNameBytes else { return false }
        for s in name.unicodeScalars {
            if s.value < 0x20 || s.value == 0x7F { return false }
            if reserved.contains(s), !(pattern && wildcards.contains(s)) { return false }
        }
        // Dots only ("..", "..."), also after dropping invisible format characters (U+200B, U+FEFF, …) or
        // compatibility forms (U+FF0E fullwidth full stop): never a name, whatever a later layer does with it.
        let skeleton = name.utf8.allSatisfy({ $0 < 0x80 }) ? name : String(String.UnicodeScalarView(
            name.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        if skeleton.allSatisfy({ $0 == "." || $0 == " " }) { return false }
        // DOS device names, with or without an extension (CON, nul.txt, COM1 .log).
        let base = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        if devices.contains(base.trimmingCharacters(in: .whitespaces).uppercased()) { return false }
        return true
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooLong(Int)
        case encoding
        /// Not `X:` / `X:\…`, or another letter than ours.
        case drive
        case dotDot
        case badName
        public var description: String {
            switch self {
            case .tooLong(let n): return "path of \(n) B"
            case .encoding: return "not valid UTF-8"
            case .drive: return "not a path on our drive"
            case .dotDot: return "'..' in path"
            case .badName: return "invalid name"
            }
        }
    }

    /// Parses a DOS path `M:\dir\file.txt` (`/` is a separator too; `M:` and `M:\` are the root).
    /// A NUL cuts the string, as in the reference (§A.2). Empty and "." components are dropped; ".."
    /// anywhere is refused (we never climb, §A.7). With `pattern`, the last component may carry wildcards
    /// (FIND_FIRST).
    public static func parse(_ wire: Data, utf8: Bool, letter: Character, pattern: Bool = false) -> Result<CDMPath, ParseError> {
        guard wire.count <= maxPathBytes else { return .failure(.tooLong(wire.count)) }
        let bytes = wire.prefix { $0 != 0 }
        guard let raw = decode(bytes, utf8: utf8) else { return .failure(.encoding) }
        let text = raw.precomposedStringWithCanonicalMapping
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2, scalars[1] == ":",
              String(scalars[0]).uppercased() == String(letter).uppercased() else { return .failure(.drive) }
        let rest = scalars.dropFirst(2)
        if let first = rest.first, first != "\\", first != "/" { return .failure(.drive) }  // "M:foo" (drive-relative)
        let parts = String(String.UnicodeScalarView(rest)).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        var components: [String] = []
        for (index, part) in parts.enumerated() {
            if part == "." { continue }
            if part == ".." { return .failure(.dotDot) }
            guard isValidName(part, pattern: pattern && index == parts.count - 1) else { return .failure(.badName) }
            components.append(part)
        }
        return .success(CDMPath(components))
    }

    /// True if `name` contains a wildcard (then a FIND_FIRST pattern filters; else it names one entry).
    public static func hasWildcard(_ name: String) -> Bool { name.unicodeScalars.contains { wildcards.contains($0) } }

    /// Whether the session may create an entry with this name: Windows never creates names ending in a dot
    /// or a space (it strips them), so such a name on the Mac could not be opened again from the session.
    public static func isCreatableName(_ name: String) -> Bool { !name.hasSuffix(".") && !name.hasSuffix(" ") }

    /// DOS wildcard match, case-insensitive: `*` any run, `?` one character; `*.*` matches every name
    /// (also names without a dot), as on Windows. The NT forms `<` `>` `"` count as `*` `?` `.`.
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(fold(pattern).map { c -> Character in
            switch c { case "<": return "*"; case ">": return "?"; case "\"": return "."; default: return c }
        })
        if p == ["*"] || p == ["*", ".", "*"] { return true }
        let n = Array(fold(name))
        if glob(p, n) { return true }
        // "x*.*" also matches names without an extension.
        return p.count >= 2 && p[p.count - 2] == "." && p[p.count - 1] == "*" && !n.contains(".") && glob(p, n + ["."])
    }

    /// Non-backtracking: the pattern splits at `*` into segments; the first must match at the start, the
    /// last at the end, and each middle one at its leftmost position after the previous (leftmost is always
    /// right for `*`), so the cost is bounded by name length × pattern length.
    private static func glob(_ p: [Character], _ n: [Character]) -> Bool {
        let segments = p.split(separator: "*", omittingEmptySubsequences: false).map(Array.init)
        func at(_ seg: [Character], _ i: Int) -> Bool {
            guard i >= 0, i + seg.count <= n.count else { return false }
            for k in seg.indices where seg[k] != "?" && seg[k] != n[i + k] { return false }
            return true
        }
        if segments.count == 1 { return segments[0].count == n.count && at(segments[0], 0) }
        let first = segments[0], last = segments[segments.count - 1]
        guard first.count + last.count <= n.count, at(first, 0), at(last, n.count - last.count) else { return false }
        var position = first.count
        let end = n.count - last.count
        for seg in segments[1..<(segments.count - 1)] where !seg.isEmpty {
            var i = position
            while i + seg.count <= end, !at(seg, i) { i += 1 }
            guard i + seg.count <= end else { return false }
            position = i + seg.count
        }
        return true
    }

    /// Characters a DOS 8.3 name may hold besides A–Z and 0–9.
    static let shortExtra = Set("!#$%&'()-@^_`{}~")

    /// Whether `name` is a valid 8.3 name as it stands (then it is sent as the short name with an empty long
    /// name, §A.5): base 1…8 and extension 0…3 bytes in the wire encoding, at most one dot, no leading dot,
    /// no spaces or `+ , ; = [ ]`; V1 additionally ASCII only.
    public static func fits83(_ name: String, utf8: Bool) -> Bool {
        if !utf8, !name.unicodeScalars.allSatisfy(\.isASCII) { return false }
        guard !name.hasPrefix("."), name.filter({ $0 == "." }).count <= 1 else { return false }
        if name.contains(where: { " +,;=[]".contains($0) }) { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let base = encode(String(parts[0]), utf8: utf8).count
        let ext = parts.count > 1 ? encode(String(parts[1]), utf8: utf8).count : 0
        return (1...8).contains(base) && ext <= 3
    }

    /// The parts a generated short name starts from: upper-cased base (leading dots dropped, at most 6
    /// characters) and extension (at most 3), keeping only 8.3-safe ASCII. Never empty.
    static func shortStem(_ name: String) -> (base: String, ext: String) {
        var trimmed = Substring(name)
        while trimmed.hasPrefix(".") { trimmed = trimmed.dropFirst() }
        let dot = trimmed.lastIndex(of: ".")
        let base = dot.map { trimmed[..<$0] } ?? trimmed
        let ext = dot.map { trimmed[trimmed.index(after: $0)...] } ?? ""
        func clean(_ s: Substring, _ limit: Int) -> String {
            String(s.uppercased().filter { c in c.isASCII && (c.isLetter || c.isNumber || shortExtra.contains(c)) }.prefix(limit))
        }
        let b = clean(base, 6)
        return (b.isEmpty ? "_" : b, clean(ext, 3))
    }
}
