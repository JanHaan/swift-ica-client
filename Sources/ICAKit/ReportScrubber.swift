import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Privacy scrubber for "Report a Problem" (Help menu). Everything a report shares (the user's text,
/// the environment and settings summary, the log) passes through `scrub` before the preview shows
/// it, so the preview is exactly what leaves the Mac. Pure (no I/O): the viewer supplies the context
/// (gateway host, user names, resource names, secret values from `.env`); nothing is read here.
///
/// Rules, in the order applied. Placeholders are kept as private-use characters until the end, so a
/// later rule never matches inside an earlier replacement (a user named "user" leaves `<user>` alone).
///
///  1. Known secret values (the context's `secretValues`, e.g. password and TOTP secret from `.env`;
///     4 characters or more, also percent-encoded) anywhere → `<redacted>`.
///  2. Secret fields: the value of every field whose name contains password, passwd, pwd, passcode,
///     passphrase, secret, token, ticket, csrf, xsrf, apikey, authorization, otp/totp,
///     launchreference, nonce, signature, samlresponse, sessionid, authid, deviceid, fingerprint or
///     thumbprint, or starts with `NSC_` (gateway cookies), written `name=value`, `name: value`,
///     `"name": "value"` or `<name>value</name>` → `<redacted>`. Descriptive values (yes/no, on/off,
///     stored, unchanged, present, password, passcode, …) stay, so `password present: yes` and form
///     summaries like `passwd:password` remain readable.
///  3. Cookies: in `Cookie:` / `Set-Cookie:` lines each `name=value` keeps its name, the value becomes
///     `<redacted>` (a plain list of cookie names stays); `cookie=value` → `cookie=<redacted>`.
///     Authorization schemes (`Bearer`, `Basic`, `Negotiate`, `NTLM`) followed by a credential that
///     contains a digit or `+/=` → `<scheme> <redacted>`.
///  4. STA tickets (`STA<hex>;<ticket>`) → `<sta-ticket>`.
///     4a. Store resource ids (`/Resources/<Verb>/<id>`, `resources/v2/<id>`; base64 of
///     "<prefix>.<name>") → `<resource-id>(App n)` if the decoded name is known, else `<resource-id>`.
///  5. Camera names (`camera "…"`, `opening "…"`), which often carry the owner's name → `"<camera>"`;
///     quoted window titles in `TWI window …` lines of older logs → `"<title>"`.
///  6. E-mail addresses → `<email>`.
///  7. URL query values (`?a=1&b=2`) → `a=…&b=…` (as HTTPClient's own trace does).
///  8. Home paths `/Users/<name>` and `/home/<name>` (also as `file://` URLs) → `~` (`/Users/Shared`
///     stays); `/Volumes/<name>` → `/Volumes/<volume>`.
///  9. Windows profile paths `C:\Users\<name>` / `C:\Documents and Settings\<name>` (either slash)
///     → `C:\Users\<user>`; UNC servers `\\server` → `\\<server>`. Drive mapping (defence in depth;
///     the viewer logs only `path[<n> chars #keyed hash]` and "default/custom folder"): the path after a CDM operation (`cdm: OPEN …`,
///     both sides of RENAME) and the folder in `drive mapping: M: = …` → `<path>`.
/// 10. The gateway and store hosts (context `hosts`) → `<gateway>`; any other host in the same
///     domain (e.g. `storefront.<their domain>`) → `<gateway-domain>`.
/// 11. Other host names → `<host>`: the host of `scheme://host`, of HTTP trace lines (`→ GET host/…`,
///     `↪ 302 → host/…`), in `connected to X:port`, `host X:port`, `server X:port`, and after
///     connect to/CTXSRVR/host/server/address when the name has a digit, a hyphen or a dot (`vda07`,
///     `srv-02`), and any value of `CTXSRVR=`, `server =`, `host=`, `address=`;
///     dotted names ending in a common TLD (com, net, org, de, local, corp, internal, …); lower-case
///     names with three or more labels that do not end in a file extension. Kept: example.com/.org/
///     .net, github.com, apple.com, swift.org, localhost, reverse-DNS ids (`com.apple.x`) and
///     CamelCase type paths (`ICAKit.Gateway.Error`).
/// 12. Network addresses: colon-hex fingerprints of 8+ bytes → `<fingerprint>`; MAC addresses →
///     `<mac>`; IPv6 (validated with inet_pton; `::` and `::1` stay) → `<ipv6>`; IPv4 (0.0.0.0,
///     127.x and 255.255.255.255 stay) → `<ipv4>`.
/// 13. Identifiers and tickets: GUIDs and hex runs of 24+ characters → `<id>`; base64/base64url runs
///     of 24+ characters with mixed case and digits → `<token>` (runs with `/` must also look random,
///     so ordinary paths stay; single-case runs need 6+ digits and no separators); base32 runs of 16+ characters with a digit (TOTP secrets) →
///     `<redacted>`.
/// 14. One-time codes: 6–8 digits after passcode, OTP, TOTP, "one-time code", "verification code",
///     "security code" or "code" → `<code>`.
/// 15. People and machines: user names from the context (also each part of `DOMAIN\user` and of the
///     full name, 3+ characters) → `<user>`; logon domains → `<domain>`; computer names → `<computer>`;
///     any other `domain\user` (any case) → `<domain>\<user>`.
/// 16. Resource and app names (the context's names, which the viewer keeps across runs, plus every
///     name the texts announce: `«name»`, resource ids and older plain log forms, see `learnedNames`)
///     → `App 1`, `App 2`, … numbered in sorted order, unless the user includes them; included names
///     still lose a trailing environment tag ("Calculator ABC" → "Calculator"). With names hidden,
///     any `«…»` left over → `«<name>»`.
/// 17. Private censor words (the context's `censorWords`, e.g. `.shotcheck-censor`) → their replacement.
/// 18. Final pass: rules 1–4 run again on the finished text, so no secret survives an earlier rewrite.
public struct ReportScrubber: Sendable {
    public struct Replacement: Sendable, Equatable {
        public var word: String
        public var with: String
        public init(word: String, with: String) {
            self.word = word
            self.with = with
        }
    }

    public struct Context: Sendable, Equatable {
        /// Gateway and store host names (or addresses).
        public var hosts: [String] = []
        /// Login names, the macOS account name and full name.
        public var userNames: [String] = []
        /// Windows logon domains.
        public var domains: [String] = []
        /// The Mac's computer and local host names.
        public var computerNames: [String] = []
        /// Published resource and app names.
        public var resourceNames: [String] = []
        /// Literal secrets that must never appear (from `.env`; the Keychain is never read for this).
        public var secretValues: [String] = []
        /// Private organisation words and their replacement.
        public var censorWords: [Replacement] = []
        /// True: resource names stay (without their environment tag); false: `App 1`, `App 2`, ….
        public var includeResourceNames = false
        public init() {}
    }

    public let context: Context
    /// Resource names in pseudonym order (index 0 is "App 1").
    public let names: [String]

    /// `learningFrom`: texts (the raw log) whose announced app names join the context's names, so
    /// every part of one report uses the same numbering.
    public init(_ context: Context, learningFrom texts: [String] = []) {
        self.context = context
        var seen = Set<String>()
        var list: [String] = []
        for name in context.resourceNames + texts.flatMap(Self.learnedNames(in:)) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, seen.insert(trimmed.lowercased()).inserted else { continue }
            list.append(trimmed)
        }
        names = list.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Scrubbing

    public func scrub(_ input: String) -> String {
        var text = Mark.encodeLiterals(String(String.UnicodeScalarView(input.unicodeScalars.filter { !Mark.isMark($0) })))
        text = secretPass(text)
        text = resourceIDPass(text)
        text = Self.camera.replace(text) { g in g[1]! + "\"" + Mark.camera.token + "\"" }
        text = Self.windowTitle.replace(text) { g in g[1]! + "\"" + Mark.title.token + "\"" }
        text = Self.email.replace(text) { _ in Mark.email.token }
        text = Self.query.replace(text) { g in g[1]! + "…" }
        text = Self.homePath.replace(text) { g in g[1]!.caseInsensitiveCompare("Shared") == .orderedSame ? nil : "~" }
        text = Self.volume.replace(text) { g in "/Volumes/" + Mark.volume.token }
        text = Self.windowsProfile.replace(text) { g in g[1]! + Mark.user.token }
        text = Self.unc.replace(text) { g in "\\\\" + Mark.server.token + g[2]! }
        text = Self.uncBare.replace(text) { _ in "\\\\" + Mark.server.token }
        text = Self.cdmPath.replace(text) { g in g[1]! + Mark.path.token }
        text = Self.cdmRenameTarget.replace(text) { g in g[1]! + Mark.path.token }
        text = Self.driveFolder.replace(text) { g in g[1]! + Mark.path.token }
        text = hostPass(text)
        text = addressPass(text)
        text = Self.urlPath.replace(text) { g in
            let segments = g[2]!.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
                let segment = String(segment)
                return Self.looksLikePathID(segment) ? resourceLabel(segment, fallback: .id) : segment
            }
            return g[1]! + segments.joined(separator: "/")
        }
        text = identifierPass(text)
        text = Self.oneTimeCode.replace(text) { g in g[1]! + g[2]! + Mark.code.token }
        text = peoplePass(text)
        text = namePass(text)
        for r in context.censorWords where !r.word.isEmpty {
            text = text.replacingOccurrences(of: r.word, with: r.with, options: .caseInsensitive)
        }
        return Mark.decode(secretPass(Mark.decode(text)))
    }

    /// `scrub` for a long text such as the log, in chunks of whole lines on all cores (every rule
    /// works within a line, so the result equals `scrub(text)`).
    public func scrubLines(_ text: String, chunkLines: Int = 400) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > chunkLines else { return scrub(text) }
        let chunks = stride(from: 0, to: lines.count, by: chunkLines).map {
            lines[$0..<min($0 + chunkLines, lines.count)].joined(separator: "\n")
        }
        let results = ResultBox(count: chunks.count)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { i in results.set(i, scrub(chunks[i])) }
        return results.values.joined(separator: "\n")
    }

    /// Rules 1–4.
    private func secretPass(_ input: String) -> String {
        var text = input
        for value in Self.secretVariants(context.secretValues) {
            text = text.replacingOccurrences(of: value, with: Mark.redacted.token)
        }
        text = Self.cookieHeader.replace(text) { g in
            let value = g[3]!
            guard value.contains("=") else { return nil }
            return g[1]! + g[2]! + Self.cookiePair.replace(value) { p in p[1]! + "=" + Mark.redacted.token }
        }
        text = Self.cookieAssignment.replace(text) { g in g[1]! + Mark.redacted.token }
        text = Self.authScheme.replace(text) { g in g[1]! + " " + Mark.redacted.token }
        text = Self.staTicket.replace(text) { _ in Mark.staTicket.token }
        text = Self.xmlSecret.replace(text) { g in "<\(g[1]!)>" + Mark.redacted.token + "</\(g[1]!)>" }
        text = Self.secretField.replaceFields(text) { name, value in
            guard Self.isSecretName(name) else { return nil }
            var inner = value
            let quote = value.first.map { $0 == "\"" || $0 == "'" ? String($0) : "" } ?? ""
            if !quote.isEmpty { inner = String(inner.dropFirst().dropLast()) }
            if Self.descriptiveValues.contains(inner.lowercased()) { return nil }
            return quote + Mark.redacted.token + quote
        }
        return text
    }

    private static func secretVariants(_ values: [String]) -> [String] {
        var out = Set<String>()
        for value in values where value.count >= 4 {
            out.insert(value)
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != value { out.insert(encoded) }
            let compact = value.replacingOccurrences(of: " ", with: "")
            if compact.count >= 4 { out.insert(compact); out.insert(compact.uppercased()) }
        }
        return out.sorted { $0.count > $1.count }
    }

    /// Rule 4a: resource ids in store URLs (`/Resources/LaunchIca/<id>`, `resources/v2/<id>`) are
    /// base64 of "<prefix>.<resource name>": always replaced, by the name's pseudonym if it is known.
    private func resourceIDPass(_ input: String) -> String {
        Self.resourceID.replace(input) { g in g[1]! + resourceLabel(g[2]!, fallback: .resourceID) }
    }

    /// `<resource-id>(App 3)` for an id whose decoded name is known, else the fallback placeholder;
    /// an extension (`.ica`) stays.
    private func resourceLabel(_ segment: String, fallback: Mark) -> String {
        let ext = segment.firstIndex(of: ".").map { String(segment[$0...]) } ?? ""
        guard let decoded = Self.decodedResourceName(segment) else { return fallback.token + ext }
        let lower = decoded.map { $0.lowercased() }
        guard let index = names.firstIndex(where: { lower.contains($0.lowercased()) }) else { return fallback.token + ext }
        let label = context.includeResourceNames ? DisplayName.censored(names[index]) : Mark.app(index + 1)
        return Mark.resourceID.token + "(" + label + ")" + ext
    }

    /// The name inside a base64/base64url resource id: the decoded text and, for "CVAD.Name", "Name".
    static func decodedResourceName(_ segment: String) -> [String]? {
        var text = (segment.removingPercentEncoding ?? segment)
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // base64url ids may pad with "-" (read as "+" above): try without trailing padding first.
        var found: [[String]] = []
        for var candidate in [String(text.reversed().drop(while: { $0 == "+" || $0 == "=" }).reversed()), text] {
            while candidate.hasSuffix("=") { candidate.removeLast() }
            guard candidate.count >= 4 else { continue }
            candidate += String(repeating: "=", count: (4 - candidate.count % 4) % 4)
            guard let data = Data(base64Encoded: candidate), let decoded = String(data: data, encoding: .utf8),
                  !decoded.isEmpty, decoded.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { continue }
            if let dot = decoded.firstIndex(of: "."), decoded[..<dot].allSatisfy(\.isLetter), decoded.index(after: dot) < decoded.endIndex {
                return [String(decoded[decoded.index(after: dot)...]), decoded]   // "CVAD.Name"
            }
            found.append([decoded])
        }
        return found.first
        return nil
    }

    /// A URL path segment that is an id: 12+ base64url characters (extension aside) with a digit,
    /// `=` or `--` padding, not only letters.
    static func looksLikePathID(_ segment: String) -> Bool {
        let body = segment.firstIndex(of: ".").map { String(segment[..<$0]) } ?? segment
        guard body.count >= 12, body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=+%".contains($0)) }) else { return false }
        return body.contains(where: \.isNumber) || body.hasSuffix("=") || body.hasSuffix("--")
    }

    /// Rules 10–11.
    private func hostPass(_ input: String) -> String {
        var text = input
        let hosts = Set(context.hosts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[] ")) }.filter { !$0.isEmpty })
        if let exact = Self.literalAlternation(Array(hosts), before: #"[A-Za-z0-9.\-]"#, after: #"[A-Za-z0-9\-]|\.[A-Za-z0-9]"#) {
            text = exact.replace(text) { _ in Mark.gateway.token }
        }
        let bases = Set(hosts.compactMap(Self.baseDomain))
        for base in bases {
            let re = ScrubPattern(#"(?i)(?<![A-Za-z0-9.\-])(?:[A-Za-z0-9\-]+\.)*"# + NSRegularExpression.escapedPattern(for: base)
                        + #"(?![A-Za-z0-9\-]|\.[A-Za-z0-9])"#)
            text = re.replace(text) { _ in Mark.gatewayDomain.token }
        }
        text = Self.urlHost.replace(text) { g in Self.isKeptHost(g[2]!) ? nil : g[1]! + Mark.host.token }
        text = Self.requestHost.replace(text) { g in Self.isKeptHost(g[2]!) ? nil : g[1]! + Mark.host.token }
        text = Self.hostWithPort.replace(text) { g in Self.isAddressLiteral(g[2]!) ? nil : g[1]! + Mark.host.token }
        text = Self.hostAssignment.replace(text) { g in Self.isKeptHost(g[3]!) ? nil : g[1]! + g[2]! + Mark.host.token }
        text = Self.nearHost.replace(text) { g in
            let name = g[3]!
            if Self.isKeptHost(name) { return nil }
            if name.contains("."), let tld = name.split(separator: ".").last, Self.fileExtensions.contains(tld.lowercased()) { return nil }
            return g[1]! + g[2]! + Mark.host.token
        }
        text = Self.dottedName.replace(text) { g in Self.looksLikeHost(g[0]!) ? Mark.host.token : nil }
        return text
    }

    /// Rule 12.
    private func addressPass(_ input: String) -> String {
        var text = Self.fingerprint.replace(input) { _ in Mark.fingerprint.token }
        text = Self.mac.replace(text) { _ in Mark.mac.token }
        text = Self.ipv6Candidate.replace(text) { g in
            let candidate = g[1]!
            guard candidate.filter({ $0 == ":" }).count >= 2, candidate != "::", candidate != "::1",
                  Self.isIPv6(candidate) else { return nil }
            return Mark.ipv6.token
        }
        text = Self.ipv4.replace(text) { g in
            let octets = (1...4).compactMap { Int(g[$0]!) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
            if octets == [0, 0, 0, 0] || octets[0] == 127 || octets == [255, 255, 255, 255] { return nil }
            return Mark.ipv4.token
        }
        return text
    }

    /// Rule 13.
    private func identifierPass(_ input: String) -> String {
        var text = Self.guid.replace(input) { _ in Mark.id.token }
        text = Self.longHex.replace(text) { _ in Mark.id.token }
        text = Self.base64.replace(text) { g in Self.looksRandom(g[0]!) ? Mark.token.token : nil }
        text = Self.base32.replace(text) { g in
            let run = g[0]!
            return run.contains(where: \.isNumber) && run.filter(\.isLetter).count >= 8 ? Mark.redacted.token : nil
        }
        return text
    }

    /// Rule 15.
    private func peoplePass(_ input: String) -> String {
        var text = input
        var users: [String] = []
        var domains = context.domains
        for name in context.userNames {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            users.append(trimmed)
            var user = Substring(trimmed)
            if let slash = user.firstIndex(of: "\\") {
                domains.append(String(user[..<slash]))
                user = user[user.index(after: slash)...]
            }
            if let at = user.firstIndex(of: "@") { user = user[..<at] }
            users.append(String(user))
            let parts = user.split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
            if parts.count > 1 { users += parts.filter { $0.count >= 3 } }
        }
        let computers = context.computerNames.flatMap { name -> [String] in
            // "Erika’s MacBook Pro" also appears as the host name "Erikas-MacBook-Pro".
            let dashed = name.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: " ", with: "-")
            return [name, dashed]
        }
        for (list, mark) in [(computers, Mark.computer), (users, Mark.user), (domains, Mark.domain)] {
            if let re = Self.literalAlternation(list.filter { $0.count >= 2 }, boundary: #"[\p{L}\p{N}_]"#) {
                text = re.replace(text) { _ in mark.token }
            }
        }
        // Anyone else's logon name.
        return Self.domainUser.replace(text) { _ in Mark.domain.token + "\\" + Mark.user.token }
    }

    /// Rule 16.
    private func namePass(_ input: String) -> String {
        var replacement: [String: String] = [:]
        var aliases: [String] = []
        for (index, name) in names.enumerated() {
            let shown = context.includeResourceNames ? DisplayName.censored(name) : Mark.app(index + 1)
            if context.includeResourceNames && shown == name { continue }
            for alias in [name, DisplayName.censored(name)] where alias.count >= 2 && replacement[alias.lowercased()] == nil {
                // The tag-less alias ("Calculator") is hidden too, but only when names are hidden.
                if alias != name && context.includeResourceNames { continue }
                replacement[alias.lowercased()] = shown
                aliases.append(alias)
            }
        }
        var text = input
        if let re = Self.literalAlternation(aliases, boundary: #"[\p{L}\p{N}_]"#) {
            text = re.replace(text) { g in replacement[g[0]!.lowercased()] }
        }
        guard !context.includeResourceNames else { return text }
        // A «name» the scrubber did not learn (it was not in the texts it learned from).
        return Self.quotedName.replace(text) { g in
            g[1]!.unicodeScalars.contains(where: Mark.isMark) ? nil : "«" + Mark.name.token + "»"
        }
    }

    // MARK: - Learning names from the log

    /// App and resource names the log announces itself (`TWI app added: app:Name "Name"`, quoted
    /// launches), so a name the store list did not supply is still hidden.
    ///
    /// Sources: every `«name»` (the viewer logs resource and app names so), names inside store
    /// resource ids, and the plain forms of logs written before names were quoted (`session X closed:`,
    /// `launch: X:`, `reconnect via resource X`, `session sharing: X: …`, …).
    public static func learnedNames(in text: String) -> [String] {
        var out: [String] = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("«") else { return }
            out.append(trimmed.hasPrefix("app:") ? String(trimmed.dropFirst(4)) : trimmed)   // «app:X» → X's number
        }
        for g in quotedName.matches(text) { add(g[1]!) }
        for g in appAdded.matches(text) {
            if let quoted = g[2] { add(quoted) }
            if let key = g[1] { add(key) }
        }
        for pattern in legacyNamePatterns {
            for g in pattern.matches(text) {
                for i in 1..<g.count { if let name = g[i] { name.components(separatedBy: ", ").forEach(add) } }
            }
        }
        for g in resourceID.matches(text) {
            if let decoded = decodedResourceName(g[2]!), decoded.count == 2 { add(decoded[0]) }   // "CVAD.Name" only
        }
        return out
    }

    // MARK: - Helpers

    /// `example.com` for `gw.example.com`; `example.co.uk` for `gw.example.co.uk`; the host itself
    /// for a two-label host; nil for an address.
    static func baseDomain(_ host: String) -> String? {
        guard !isAddressLiteral(host) else { return nil }
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let second = labels[labels.count - 2]
        if labels.count >= 3, labels.last!.count == 2, second.count <= 3,
           ["co", "com", "net", "org", "ac", "gov", "edu", "or", "ne", "gv"].contains(second) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Addresses (the IP rules handle them), placeholders and the public hosts that stay.
    static func isKeptHost(_ name: String) -> Bool {
        let lower = name.lowercased()
        return isAddressLiteral(name) || lower == "localhost" || keptDomains.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }

    static func isAddressLiteral(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: Mark.isMark) { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    static func isIPv6(_ text: String) -> Bool {
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v6 = in6_addr()
        return inet_pton(AF_INET6, address, &v6) == 1
    }

    private static let commonTLDs: Set<String> = [
        "com", "net", "org", "de", "at", "ch", "eu", "uk", "io", "info", "biz", "local", "lan", "corp",
        "internal", "intranet", "intra", "home", "cloud", "gov", "edu", "fr", "nl", "it", "es", "be", "pl",
        "cz", "us", "ca", "au", "dk", "se", "no", "fi", "lu", "li",
    ]
    private static let fileExtensions: Set<String> = [
        "swift", "plist", "log", "txt", "md", "json", "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "pdf",
        "zip", "gz", "tgz", "bz2", "xz", "ica", "app", "dylib", "framework", "bundle", "exe", "dll", "sys",
        "docx", "xlsx", "pptx", "doc", "xls", "ppt", "csv", "html", "htm", "xml", "yml", "yaml", "sh", "py",
        "c", "h", "m", "mm", "mov", "mp4", "bin", "dat", "tmp", "bak", "lnk", "ini", "cfg", "conf", "msi",
        "raw", "wav", "caf", "aac", "opus", "h264", "rtf", "key", "pages", "numbers", "dmg", "pkg", "cer",
    ]
    private static let keptDomains = ["example.com", "example.org", "example.net", "github.com",
                                      "githubusercontent.com", "apple.com", "swift.org"]

    static func looksLikeHost(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "localhost" || keptDomains.contains(where: { lower == $0 || lower.hasSuffix("." + $0) }) { return false }
        let labels = lower.split(separator: ".").map(String.init)
        guard labels.count >= 2, let tld = labels.last, tld.allSatisfy(\.isLetter) else { return false }
        if labels.count >= 3, ["com", "org", "net", "io", "edu", "gov"].contains(labels[0]) { return false }   // reverse DNS
        if commonTLDs.contains(tld) { return true }
        return labels.count >= 3 && name == lower && !fileExtensions.contains(tld)
    }

    /// True for a base64 run that looks like random data rather than a word, path or identifier.
    static func looksRandom(_ run: String) -> Bool {
        let digits = run.filter(\.isNumber).count
        let upper = run.filter(\.isUppercase).count
        let lower = run.filter(\.isLowercase).count
        // Paths and words change character class rarely (a word per segment); random data often.
        func kind(_ c: Character) -> Int { c.isUppercase ? 0 : c.isLowercase ? 1 : c.isNumber ? 2 : 3 }
        let chars = Array(run)
        let changeRate = Double(zip(chars, chars.dropFirst()).filter { kind($0) != kind($1) }.count) / Double(max(1, chars.count - 1))
        if upper == 0 || lower == 0 {
            // Single-case tickets (upper-case letters and digits): many digits, no separators.
            return !run.contains(where: { "/-_".contains($0) }) && digits >= 6 && upper + lower >= 6 && changeRate >= 0.3
        }
        guard digits >= 1 else { return false }
        if run.contains("+") || run.hasSuffix("=") { return true }   // base64 alphabet or padding
        guard run.contains("/") else { return digits >= 2 && upper >= 2 && lower >= 2 }
        return changeRate >= 0.45
    }

    /// One case-insensitive regex for a list of literals, longest first, not inside a longer word.
    private static func literalAlternation(_ words: [String], boundary: String) -> ScrubPattern? {
        literalAlternation(words, before: boundary, after: boundary)
    }

    private static func literalAlternation(_ words: [String], before: String, after: String) -> ScrubPattern? {
        let unique = Array(Set(words.filter { !$0.isEmpty })).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        guard !unique.isEmpty else { return nil }
        let body = unique.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return ScrubPattern("(?i)(?<!" + before + ")(?:" + body + ")(?!" + after + ")")
    }

    private static let descriptiveValues: Set<String> = [
        "yes", "no", "none", "true", "false", "on", "off", "set", "unset", "stored", "unchanged", "present",
        "absent", "missing", "required", "optional", "empty", "hidden", "prompt", "password", "passcode",
        "text", "totp", "nil", "null", "…", "...", "redacted", "ok", "bearer", "basic", "negotiate", "ntlm",
    ]

    // MARK: - Patterns

    /// Any `name=` / `name:` / `"name":` with its value in a lookahead, so the next search starts at
    /// the value and finds a field nested there (`settings: password: x`); `isSecretName` decides.
    private static let secretField = ScrubPattern(
        #"(?<![A-Za-z0-9_.\-])(["']?)([A-Za-z0-9_.\-]+)\1(\s*[:=]\s*)(?=("(?:[^"\\\n]|\\.)*"|'[^'\n]*'|[^\s,;&)\]}"'<>]+))"#)
    private static let secretName = ScrubPattern(
        #"(?i)pass(?:word|wd|code|phrase)|pwd|secret|token|ticket|csrf|xsrf|api[_\-]?key|authorization|launch[_\-]?reference|nonce|signature|saml[_\-]?response|sess(?:ion)?[_\-]?id|auth[_\-]?id|device[_\-]?id|fingerprint|thumbprint|(?<![a-z])otp|totp|^NSC_"#)

    static func isSecretName(_ name: String) -> Bool { !secretName.matches(name).isEmpty }

    private static let xmlSecret = ScrubPattern(
        #"(?i)<([A-Za-z0-9_:\-]*(?:password|secret|token|ticket|passcode|cookie)[A-Za-z0-9_\-]*)>[^<]*</\1>"#)
    private static let cookieHeader = ScrubPattern(#"(?im)\b((?:set-)?cookie2?)(\s*:\s*)([^\n]*)"#)
    private static let cookiePair = ScrubPattern(#"([^=;,\s"]+)=("[^"]*"|[^;,\s"]*)"#)
    private static let cookieAssignment = ScrubPattern(#"(?i)\b(cookies?\s*=\s*)[^\s;,&]+"#)
    private static let authScheme = ScrubPattern(#"(?i)\b(bearer|basic|negotiate|ntlm)\s+(?=[A-Za-z0-9._~+/\-]*[0-9+/=])[A-Za-z0-9._~+/=\-]{8,}"#)
    private static let staTicket = ScrubPattern(#"(?i)\bSTA[0-9A-F]{4,};[A-Za-z0-9+/=_\-]+"#)
    private static let camera = ScrubPattern(#"(?i)\b((?:camera|opening)\s+)"[^"\n]*""#)
    private static let email = ScrubPattern(#"(?i)(?<![A-Z0-9._%+\-])[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#)
    private static let query = ScrubPattern(#"([?&][A-Za-z0-9_.\-%\[\]]+=)[^&\s#"'<>]+"#)
    private static let homePath = ScrubPattern(#"(?:file://)?/(?:Users|home)/([^/\s"':]+)"#)
    private static let volume = ScrubPattern(#"/Volumes/(?:[^/\n"':]+(?=/)|[^/\s"':]+)"#)
    private static let windowsProfile = ScrubPattern(#"(?i)\b([A-Z]:[\\/]+(?:Users|Documents and Settings)[\\/]+)[^\\/\s"':]+"#)
    private static let unc = ScrubPattern(#"(?<![\\\w])\\\\([A-Za-z0-9._\-]+)(\\)"#)
    private static let uncBare = ScrubPattern(#"(?<![\\\w])\\\\[A-Za-z0-9._\-]+(?![\\\w.\-])"#)
    private static let domainUser = ScrubPattern(#"(?<![\\\w:.\-])[A-Za-z][A-Za-z0-9_\-]{1,14}\\[A-Za-z][A-Za-z0-9._\-]{0,63}(?![\\\w])"#)
    /// The path after a CDM operation (`cdm: OPEN <path> access …`), unless it is already a label.
    private static let cdmPath = ScrubPattern(
        #"(\bcdm: (?!CONNECT)[A-Z][A-Z_]+(?: ctx \d+)? )(?!path\[|/ |/$|→|refused|ctx |mode |\()(.+?)(?= → |: | access \d| mode \d| mode 0x| at \d| \d+ B at |$)"#,
        options: [.anchorsMatchLines])
    private static let cdmRenameTarget = ScrubPattern(#"(\bcdm: RENAME .+? → )(?!path\[|\p{Co})([^:\n]+?)(?=: |$)"#, options: [.anchorsMatchLines])
    private static let driveFolder = ScrubPattern(#"(drive mapping: [A-Z]: = )(?!path\[|default folder|custom folder)(.+?)(?= \(read-only\)|$)"#, options: [.anchorsMatchLines])
    private static let resourceID = ScrubPattern(#"(?i)(/Resources/[A-Za-z]+/|\bresources/v2/)([^/\s?#"'<>]+)"#)
    /// A path after a host placeholder or `scheme://host` (rule 12 ran, so addresses are placeholders).
    private static let urlPath = ScrubPattern(#"((?:https?|wss?)://[^/\s"'<>]+|[\x{E001}-\x{E003}\x{E005}\x{E006}])(/[^\s"'<>?#]*)"#)
    private static let urlHost = ScrubPattern(#"(?i)\b((?:https?|wss?)://)([^/\s:?#"'<>@\p{Co}]+)"#)
    /// `CTXSRVR=x`, `server = x`, `host=x`, `address=x`: any value is a server name.
    private static let hostAssignment = ScrubPattern(#"(?i)\b(ctxsrvr|server|host|address)(\s*=\s*)([^\s,;&)\]"'<>\p{Co}]+)"#)
    /// Titles in TWI window lines of older logs (now only their length is logged).
    private static let windowTitle = ScrubPattern(#"(TWI window [0-9A-Fa-f]+ [^\n"]*?)"[^"\n]*""#)
    /// HTTP trace lines: `→ GET host/path`, `↪ 302 → host/path`.
    private static let requestHost = ScrubPattern(#"((?:→ (?:GET|POST|PUT|DELETE|HEAD|PATCH|OPTIONS) |↪ \d{3} → ))(?!(?:https?|wss?)://)([^/\s?#"'<>\p{Co}]+)"#)
    /// Server names without a port near host words: with a digit or hyphen, or dotted.
    private static let nearHost = ScrubPattern(
        #"(?i)\b(connect(?:ed|ing)? to|ctxsrvr|host|server|address)(\s*[=:]?\s*)([A-Za-z][A-Za-z0-9]*[0-9\-][A-Za-z0-9\-]*(?:\.[A-Za-z0-9\-]+)*|[A-Za-z][A-Za-z0-9\-]*(?:\.[A-Za-z0-9\-]+)+)(?![A-Za-z0-9\-]|\.[A-Za-z0-9])"#)
    private static let hostWithPort = ScrubPattern(#"(?i)(\b(?:connect(?:ed|ing)? to|host|server|address)\s*[=:]?\s*)([A-Za-z0-9][A-Za-z0-9.\-]*)(?=:\d{1,5}\b)"#)
    private static let dottedName = ScrubPattern(#"(?<![A-Za-z0-9.@\-])(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,62})\.)+[A-Za-z]{2,24}(?![A-Za-z0-9\-]|\.[A-Za-z0-9])"#)
    private static let fingerprint = ScrubPattern(#"(?i)(?<![0-9a-f:])[0-9a-f]{2}(?::[0-9a-f]{2}){7,}(?![0-9a-f:])"#)
    private static let mac = ScrubPattern(#"(?i)(?<![0-9a-f:\-])[0-9a-f]{2}(?:([:\-])[0-9a-f]{2})(?:\1[0-9a-f]{2}){4}(?![0-9a-f:\-])"#)
    private static let ipv6Candidate = ScrubPattern(#"(?<![0-9A-Za-z:.])([0-9A-Fa-f:]*:[0-9A-Fa-f:]*(?:\d{1,3}(?:\.\d{1,3}){3})?(?:%[A-Za-z0-9]+)?)(?![0-9A-Za-z:]|\.\d)"#)
    private static let ipv4 = ScrubPattern(#"(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w]|\.\d)"#)
    private static let guid = ScrubPattern(#"(?i)(?<![0-9a-z])\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?(?![0-9a-z])"#)
    private static let longHex = ScrubPattern(#"(?i)(?<![0-9a-z])(?:0x)?[0-9a-f]{24,}(?![0-9a-z])"#)
    private static let base64 = ScrubPattern(#"(?<![A-Za-z0-9+/=_\-])[A-Za-z0-9+/_\-]{24,}={0,2}(?![A-Za-z0-9+/=_\-])"#)
    private static let base32 = ScrubPattern(#"(?<![A-Za-z0-9])[A-Z2-7]{16,}={0,6}(?![A-Za-z0-9])"#)
    private static let oneTimeCode = ScrubPattern(#"(?i)\b(passcode|one[\- ]time (?:code|password)|otp|totp|verification code|security code|code)(\W{1,3}|\s+is\s+)\d{6,8}(?!\d)"#)
    private static let appAdded = ScrubPattern(#"TWI app added: (.*?) "([^"\n]*)""#)
    private static let quotedName = ScrubPattern(#"«([^»\n]*)»"#)
    /// Plain-name log formats of earlier versions (names now come as «name»).
    private static let legacyNamePatterns: [ScrubPattern] = [
        #"launch of "([^"\n]+)""#,
        #"\bsession (?!sharing:)([^«\n:]+?)(?:: \d+ screen| closed: | suspended \(| resumed: input)"#,
        #"\blaunch: ([^«\n]+?)(?:: | dropped;)"#,
        #"\blauncher: ([^«\n]+?) not launched; ([^«\n]+?) is still starting"#,
        #"\blauncher: log off ([^«\n]+)$"#,
        #"\bconnection center: (?:disconnect|log off) our connection ([^«\n]+)$"#,
        #"\bconnection center: reconnect via resource ([^«\n]+)$"#,
        #"\bsession sharing: starting ([^«\n]+?) in the session of ([^«\n]+?) over CTXCTL"#,
        #"\bsession sharing: TWI app [^«\n]+? is ([^«\n]+)$"#,
        #"\bsession sharing: (?!TWI app |starting |no window)([^«\n:]+?)(?:: | could not be started)"#,
        #"\bdisconnect ([^«\n]+?) \(CGP FINISH\)"#,
        #"\bscaling: reconnecting ([^«\n]+?) to apply"#,
        #"\bscaling: relaunching ([^«\n]+?) with the new settings"#,
        #"\bafter give-up: relaunching ([^«\n]+)$"#,
        #"\bno resource named ([^«\n]+)$"#,
        #"\brelaunch of ([^«\n]+?) \(the previous"#,
        #"\brunning session ([^«\n]+?), but"#,
        #"\bequals that of ([^«\n]+?): not an early drop"#,
        #"\brunning session of ([^«\n]+?): starting it there"#,
    ].map { ScrubPattern($0, options: [.anchorsMatchLines]) }
}

/// Placeholders, kept as private-use characters while scrubbing (see ReportScrubber).
private enum Mark: Int, CaseIterable {
    case redacted, gateway, gatewayDomain, host, email, ipv4, ipv6, mac, id, token, fingerprint, code, user,
         domain, computer, server, volume, camera, staTicket, path, resourceID, name, title

    static let base: UInt32 = 0xE000
    static let appBase: UInt32 = 0xF000

    var token: String { String(Character(UnicodeScalar(Self.base + UInt32(rawValue))!)) }
    static func app(_ n: Int) -> String { String(Character(UnicodeScalar(appBase + UInt32(min(n, 0x8FF)))!)) }

    var text: String {
        switch self {
        case .redacted: "<redacted>"
        case .gateway: "<gateway>"
        case .gatewayDomain: "<gateway-domain>"
        case .host: "<host>"
        case .email: "<email>"
        case .ipv4: "<ipv4>"
        case .ipv6: "<ipv6>"
        case .mac: "<mac>"
        case .id: "<id>"
        case .token: "<token>"
        case .fingerprint: "<fingerprint>"
        case .code: "<code>"
        case .user: "<user>"
        case .domain: "<domain>"
        case .computer: "<computer>"
        case .server: "<server>"
        case .volume: "<volume>"
        case .camera: "<camera>"
        case .staTicket: "<sta-ticket>"
        case .path: "<path>"
        case .resourceID: "<resource-id>"
        case .name: "<name>"
        case .title: "<title>"
        }
    }

    static func isMark(_ s: UnicodeScalar) -> Bool {
        (base..<(base + UInt32(allCases.count))).contains(s.value) || (appBase...(appBase + 0x8FF)).contains(s.value)
    }

    /// Placeholders already in the input (a pasted report) are protected like new ones.
    static func encodeLiterals(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = text
        for mark in allCases where out.contains(mark.text) { out = out.replacingOccurrences(of: mark.text, with: mark.token) }
        return out
    }

    static func decode(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isMark) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar.value >= appBase && scalar.value <= appBase + 0x8FF {
                out += "App \(scalar.value - appBase)"
            } else if scalar.value >= base, let mark = Mark(rawValue: Int(scalar.value - base)) {
                out += mark.text
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String]
    init(count: Int) { items = Array(repeating: "", count: count) }
    func set(_ i: Int, _ value: String) { lock.lock(); items[i] = value; lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A compiled regex with a closure-based replace (`nil` from the closure keeps the match).
private struct ScrubPattern: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(_ text: String) -> [[String?]] {
        let ns = Self.native(text)
        return re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { Self.groups($0, ns) }
    }

    /// A UTF-16 backed copy: NSRegularExpression on a bridged Swift string is several times slower.
    static func native(_ text: String) -> NSString {
        let units = Array(text.utf16)
        return NSString(characters: units, length: units.count)
    }

    func replace(_ text: String, _ transform: ([String?]) -> String?) -> String {
        let ns = Self.native(text)
        let found = re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else { return text }
        var out = ""
        var last = 0
        for m in found {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = Self.groups(m, ns)
            out += transform(groups) ?? groups[0]!
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// For `secretField`: group 2 is the name, group 4 (a lookahead) the value. `transform` returns
    /// the value's replacement or nil; a replaced value is skipped by the search.
    func replaceFields(_ text: String, _ transform: (_ name: String, _ value: String) -> String?) -> String {
        let ns = Self.native(text)
        var out = ""
        var last = 0
        for m in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) where m.range.location >= last {
            let value = m.range(at: 4)
            guard value.location != NSNotFound,
                  let replacement = transform(ns.substring(with: m.range(at: 2)), ns.substring(with: value)) else { continue }
            out += ns.substring(with: NSRange(location: last, length: value.location - last)) + replacement
            last = value.location + value.length
        }
        return last == 0 ? text : out + ns.substring(from: last)
    }

    private static func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

// MARK: - Private files

/// Files next to the logs that must never be readable by others (resource names, the label key).
public enum PrivateFile {
    /// Creates `directory`, or resets an existing one, to 0700; false if that fails.
    @discardableResult
    public static func ensureDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    /// Writes `data` atomically with mode 0600 from the first byte: a temp file created 0600 in the
    /// same folder (O_EXCL), renamed over the target.
    public static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }
}

// MARK: - Report

/// A problem report from already scrubbed parts: the Markdown file and the GitHub "new issue" link.
/// The viewer scrubs every part with one `ReportScrubber` first, so the preview, the file and the
/// link carry the same text.
public struct ProblemReport: Sendable, Equatable {
    public var created: Date
    public var description: String
    /// Environment lines (app, macOS, Mac model, displays); empty if not included.
    public var environment: [String]
    /// Settings summary lines; empty if not included.
    public var settings: [String]
    /// Log lines; nil if not included.
    public var log: [String]?
    public var logMinutes: Int
    public var appNamesIncluded: Bool

    public init(created: Date, description: String, environment: [String] = [], settings: [String] = [],
                log: [String]? = nil, logMinutes: Int = 30, appNamesIncluded: Bool = false) {
        self.created = created
        self.description = description
        self.environment = environment
        self.settings = settings
        self.log = log
        self.logMinutes = logMinutes
        self.appNamesIncluded = appNamesIncluded
    }

    /// `ICAViewer-report-2026-11-06-101503.md` (UTC).
    public var fileName: String { "ICAViewer-report-\(Self.stamp(created, "yyyy-MM-dd-HHmmss")).md" }

    /// The issue title: the first non-empty line of the description, at most 80 characters.
    public var title: String {
        let first = description.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard first.count > 80 else { return first }
        let cut = first.prefix(79)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(word.count >= 40 ? word : cut) + "…"
    }

    public var markdown: String {
        var out = "# ICAViewer problem report\n\nCreated: \(Self.stamp(created, "yyyy-MM-dd HH:mm")) UTC\n\n"
        out += "## Description\n\n\(description.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if !environment.isEmpty { out += "## Environment\n\n" + environment.map { "- \($0)\n" }.joined() + "\n" }
        if !settings.isEmpty { out += "## Settings (no secrets)\n\n" + settings.map { "- \($0)\n" }.joined() + "\n" }
        if let log {
            let names = appNamesIncluded ? "app names included" : "app names replaced by App 1, App 2, …"
            out += "## Log (last \(logMinutes) minutes, \(log.count) lines; \(names))\n\n"
            let body = log.joined(separator: "\n")
            let fence = Self.fence(for: body)
            out += fence + "text\n" + body + (body.isEmpty ? "" : "\n") + fence + "\n\n"
        }
        out += "---\nScrubbed by ICAViewer before saving: host names, user and computer names, addresses, home paths, "
            + "identifiers, tickets and secrets are replaced by placeholders such as `<gateway>`, `<user>`, `<ipv4>`, "
            + "`<id>` and `<redacted>`.\n"
        return out
    }

    /// A backtick fence longer than any backtick run in `body`.
    static func fence(for body: String) -> String {
        var longest = 0, run = 0
        for c in body { run = c == "`" ? run + 1 : 0; longest = max(longest, run) }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: date)
    }

    // MARK: GitHub

    public static let newIssueURL = "https://github.com/JanHaan/swift-ica-client/issues/new"
    public static let issueTemplate = "bug_report.yml"
    /// Browsers and GitHub accept longer URLs, but proxies and the issue form are safe below this.
    public static let urlLimit = 6_000
    static let truncationNote = "\n\n[… shortened; the full text is in the attached report file]"

    /// The "new issue" link: template, title, description, environment and an attachment hint as
    /// issue-form query parameters, percent-encoded, at most `limit` characters. The description is
    /// shortened first, then the environment; the log is never part of the link (it is in the file).
    public func issueURL(limit: Int = ProblemReport.urlLimit) -> URL {
        let title = self.title.isEmpty ? "Problem report" : self.title
        var environmentText = (environment + settings).map { "- \($0)" }.joined(separator: "\n")
        let hint = "<!-- Drag \(fileName) from Finder into this field. -->"
        func link(_ description: String, _ environment: String) -> String {
            var query = [("template", Self.issueTemplate), ("title", title), ("description", description)]
            if !environment.isEmpty { query.append(("environment", environment)) }
            query.append(("report", hint))
            return Self.newIssueURL + "?" + query.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Environment: whole lines while the link with an empty description stays below 2/3 of the limit.
        var lines = environmentText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while !lines.isEmpty, link(Self.truncationNote, environmentText).count > limit * 2 / 3 {
            lines.removeLast()
            environmentText = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n- …"
        }
        if link(text, environmentText).count <= limit { return URL(string: link(text, environmentText))! }
        // Longest prefix (in characters) that fits with the note.
        let chars = Array(text)
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            if link(String(chars[..<mid]) + Self.truncationNote, environmentText).count <= limit { low = mid } else { high = mid - 1 }
        }
        return URL(string: link(String(chars[..<low]).trimmingCharacters(in: .whitespaces) + Self.truncationNote, environmentText))!
    }

    /// Percent-encoding with only RFC 3986 unreserved characters left as they are (`+` and `&` encoded).
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
