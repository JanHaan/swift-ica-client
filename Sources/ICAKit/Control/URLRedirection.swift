import Foundation
import Network

/// Host-to-client URL redirection (docs/56-url-redirection.md): a link opened in the session arrives as CTXCTL 0x09
/// and opens on the Mac. The host and every program in the session are semi-trusted (docs/security/asvs-review.md §1),
/// so the URL passes `URLRedirectFilter` and `URLRedirectLimiter` before anything is opened, and the viewer opens it
/// with NSWorkspace only.

/// CTXCTL messages of host-to-client URL redirection (docs/56 §3), from the lab VDA's traffic to the stock client.
public enum URLRedirectWire {
    /// Longest URL we read from a 0x0E payload, in bytes; the u16 length field allows 65,531. Longer → not opened.
    public static let maxPayload = 16_384

    /// The URL of a 0x0E payload: `u32 offset` (4 in every capture) and the URL's bytes from there up to a NUL (or the
    /// end). nil if the offset is outside the payload or the bytes are not UTF-8 (every capture was ASCII).
    public static func url(fromPayload p: [UInt8]) -> String? {
        guard p.count >= 4, p.count <= maxPayload + 4 else { return nil }
        let offset = Int(ControlWire.u32(p, 0))
        guard offset >= 4, offset <= p.count else { return nil }
        let bytes = Data(p[offset...].prefix { $0 != 0 })
        return String(data: bytes, encoding: .utf8)
    }

    /// The whole 0x0A reply: `opened` true → 0 (the client opened it), false → 1 (the host opens it in the session).
    public static func reply(opened: Bool) -> [UInt8] {
        ControlWire.message(ControlWire.Command.openURLReply, ControlWire.le32(opened ? 0 : 1))
    }
}

/// The security rule of docs/56 §5: which URLs may open on the Mac.
public enum URLRedirectFilter {
    /// The only schemes that open (docs/56 §5.1): what the stock client opens. Everything else, `mailto:`, `file:`,
    /// `javascript:`, custom schemes and local paths included, is refused, and the session opens it.
    public static let allowedSchemes: Set<String> = ["http", "https"]
    /// Longest URL accepted, in UTF-16 units (docs/56 §5.2).
    public static let maxLength = 8192

    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case empty
        case tooLong(Int)
        case controlCharacter
        case notAURL
        case scheme(String)
        case noHost
        /// localhost, loopback, unspecified or link-local: in a link from the session it names the server's side.
        case localHost

        public var description: String {
            switch self {
            case .empty: return "empty"
            case .tooLong(let n): return "\(n) characters, more than \(URLRedirectFilter.maxLength)"
            case .controlCharacter: return "control or invisible formatting character"
            case .notAURL: return "not a URL"
            case .scheme(let s): return "scheme \(s.isEmpty ? "(none)" : "\"\(s)\"") not allowed"
            case .noHost: return "no host"
            case .localHost: return "a local address (it names the server's side)"
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case open(URL)
        case refused(Refusal)
    }

    /// Checks one URL string as the host sent it (its terminating NUL already removed).
    public static func check(_ raw: String) -> Verdict {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .refused(.empty) }
        let length = text.utf16.count
        guard length <= maxLength else { return .refused(.tooLong(length)) }
        guard !text.unicodeScalars.contains(where: isForbidden) else { return .refused(.controlCharacter) }
        let scheme = schemePrefix(text)
        guard let scheme else { return .refused(.scheme("")) }   // a local path (C:\…, \\server\…, /…) or garbage
        guard allowedSchemes.contains(scheme) else { return .refused(.scheme(scheme)) }
        // No percent-encoding by Foundation: a URL that is not already valid is refused, not repaired.
        guard let url = URL(string: text, encodingInvalidCharacters: false), url.scheme?.lowercased() == scheme else {
            return .refused(.notAURL)
        }
        guard let host = url.host(percentEncoded: true), !host.isEmpty else { return .refused(.noHost) }
        // A browser decodes `%` in a host and maps it through IDNA (`%6c%6fcalhost`, full-width letters): such hosts
        // are refused rather than decoded here.
        guard !host.contains("%") else { return .refused(.notAURL) }
        // A host whose last label is a number is an IPv4 address to a browser (WHATWG); one that does not parse as
        // such is no valid host.
        if !host.contains(":"), endsInNumber(host), whatwgIPv4(host) == nil { return .refused(.notAURL) }
        guard !isLocal(host: host) else { return .refused(.localHost) }
        return .open(url)
    }

    /// `localhost` (and `*.localhost`, RFC 6761), loopback 127/8, "this network" 0/8 (0.0.0.0 reaches the Mac's own
    /// services), link-local 169.254/16 and fe80::/10, all of ::/96 (::1, ::, and the deprecated IPv4-compatible
    /// `::127.0.0.1`), and IPv4-mapped forms of the IPv4 ones (L-21). Private ranges (10/8, 192.168/16, …) stay allowed:
    /// intranet hosts.
    static func isLocal(host raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if let v4 = whatwgIPv4(host) { return isLocal(v4: v4) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            if b[0..<12].allSatisfy({ $0 == 0 }) { return true }   // ::/96: ::, ::1, IPv4-compatible
            if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return isLocal(v4: Array(b[12...])) }
            return false
        }
        return false
    }

    /// The WHATWG URL Standard's IPv4 parser: 1–4 parts, each decimal, octal (leading 0) or hex (0x), the last part
    /// filling the remaining bytes (`127.1`, `2130706433`, `0x7f.1` are all 127.0.0.1). nil unless the host is one.
    static func whatwgIPv4(_ host: String) -> [UInt8]? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        guard (1...4).contains(parts.count), endsInNumber(host) else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard !part.isEmpty else { return nil }
            var digits = Substring(part), radix = 10
            if digits.lowercased().hasPrefix("0x") { digits = digits.dropFirst(2); radix = 16 }
            else if digits.count > 1, digits.hasPrefix("0") { digits = digits.dropFirst(); radix = 8 }
            if digits.isEmpty { numbers.append(0); continue }
            guard digits.count <= 20, let n = UInt64(digits, radix: radix) else { return nil }
            numbers.append(n)
        }
        let last = numbers.removeLast()
        guard numbers.allSatisfy({ $0 <= 255 }), last < (UInt64(1) << (8 * (4 - numbers.count))) else { return nil }
        let value = numbers.enumerated().reduce(last) { $0 + ($1.element << (8 * (3 - UInt64($1.offset)))) }
        return (0..<4).map { UInt8((value >> (8 * (3 - UInt64($0)))) & 0xFF) }
    }

    /// The WHATWG "ends in a number" check: the last non-empty label is all digits, or `0x` and hex digits.
    static func endsInNumber(_ host: String) -> Bool {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last == "" { labels.removeLast() }
        guard let last = labels.last, !last.isEmpty else { return false }
        if last.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        let l = last.lowercased()
        return l.hasPrefix("0x") && l.dropFirst(2).allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    static func isLocal(v4 b: [UInt8]) -> Bool {
        b[0] == 127 || b[0] == 0 || (b[0] == 169 && b[1] == 254)
    }

    /// The scheme before the first `:`, lowercased, if it is a valid RFC 3986 scheme of at least two characters (a
    /// one-letter "scheme" is a drive letter: `C:\…`).
    static func schemePrefix(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon]
        guard name.count >= 2, let first = name.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return nil }
        return name.lowercased()
    }

    /// C0 and C1 controls, DEL, and the invisible bidi and format characters that can disguise a URL (U+200B–200F,
    /// U+202A–202E, U+2060–2069, U+FEFF).
    static func isForbidden(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    /// What the log may show of a URL: scheme and host only (path and query can hold tokens), plus the length.
    public static func logSummary(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "?"
        return "\(scheme)://\(url.host(percentEncoded: true) ?? "") (\(url.absoluteString.utf16.count) characters)"
    }

    /// For a refused string: the scheme as far as it can be read, and the length; never the text itself.
    public static func logSummary(raw: String) -> String {
        let scheme = schemePrefix(raw.trimmingCharacters(in: .whitespaces)).map { "\($0):" } ?? "no scheme"
        return "\(scheme.prefix(40)) (\(raw.utf16.count) characters)"
    }
}

/// At most `limit` opens in any `window` seconds, for the whole app (docs/56 §5.3); more are refused and only counted.
/// Not thread-safe; the owner serialises access. Times are seconds on any monotonic clock.
public struct URLRedirectLimiter: Sendable {
    public static let defaultLimit = 5
    public static let defaultWindow: Double = 30

    public let limit: Int
    public let window: Double
    private var opened: [Double] = []
    /// Refused since the last open, for one summary line.
    public private(set) var dropped = 0

    public init(limit: Int = URLRedirectLimiter.defaultLimit, window: Double = URLRedirectLimiter.defaultWindow) {
        self.limit = limit
        self.window = window
    }

    /// True if an open at `now` is within the limit (and counts it); false if it must be dropped.
    public mutating func allow(at now: Double) -> Bool {
        opened.removeAll { now - $0 >= window }
        guard opened.count < limit else {
            dropped += 1
            return false
        }
        opened.append(now)
        return true
    }

    /// The drops counted since the last call, and resets the count.
    public mutating func takeDropped() -> Int {
        defer { dropped = 0 }
        return dropped
    }
}

/// The reachability check before a link opens on the Mac (docs/56 §4): a TCP connection to the URL's host and port,
/// closed at once. Nothing is sent: no HTTP request, no cookie, no credential, no TLS. A link this Mac cannot reach (an
/// intranet name from home) is left to the session, which opens it in the server's browser, as the stock client does
/// after its own check.
public enum URLRedirectProbe {
    public static let defaultTimeout: TimeInterval = 3

    /// The host and port to connect to: the URL's, or 80/443 by scheme. nil without a host or for another scheme.
    public static func endpoint(_ url: URL) -> (host: String, port: UInt16)? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if let port = url.port { return (0...65535).contains(port) ? (bare, UInt16(port)) : nil }
        switch url.scheme?.lowercased() {
        case "http": return (bare, 80)
        case "https": return (bare, 443)
        default: return nil
        }
    }

    /// Calls `completion` once on `queue`: true when a TCP connection to `url`'s endpoint is up within `timeout`.
    public static func check(_ url: URL, timeout: TimeInterval = defaultTimeout, queue: DispatchQueue,
                             completion: @escaping (Bool) -> Void) {
        guard let (host, port) = endpoint(url), let nwPort = NWEndpoint.Port(rawValue: port) else {
            return queue.async { completion(false) }
        }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.loopback]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        var done = false
        func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(ok)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            case .waiting: finish(false)   // no route, refused or DNS failure: NWConnection would retry forever
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}
