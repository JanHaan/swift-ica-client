import Foundation

/// The only way ICAKit parses XML from a server (gateway nFactor, StoreFront, the native store API). Security review
/// F-07: `XMLDocument(data:)` with default options expands external entities (`<!ENTITY e SYSTEM "file:///…">`), so a
/// gateway or store could read any file the user can read into a logon form, whose read-only fields the client posts
/// back; internal entity chains ("billion laughs") cost tens of seconds of CPU. None of these APIs uses a DTD, so a
/// document with one is refused before parsing, and external entities are never loaded.
public enum SafeXML {
    /// The parsed document, or nil: unparsable, a DTD (`<!DOCTYPE`, `<!ENTITY`), or not UTF-8 (a UTF-16/32 byte
    /// order mark or NUL bytes would hide the markup from the byte check).
    public static func document(_ data: Data) -> XMLDocument? {
        guard isPlainUTF8Markup(data) else { return nil }
        return try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    static func isPlainUTF8Markup(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.contains(0) { return false }
        return !containsCaseInsensitive(bytes, "<!DOCTYPE") && !containsCaseInsensitive(bytes, "<!ENTITY")
    }

    static func containsCaseInsensitive(_ bytes: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.uppercased().utf8)
        guard bytes.count >= n.count else { return false }
        func upper(_ b: UInt8) -> UInt8 { (0x61...0x7A).contains(b) ? b - 0x20 : b }
        var i = 0
        while i <= bytes.count - n.count {
            if bytes[i] == n[0] {
                var j = 1
                while j < n.count, upper(bytes[i + j]) == n[j] { j += 1 }
                if j == n.count { return true }
            }
            i += 1
        }
        return false
    }
}
