import Foundation

// MARK: - Form model

/// One page of an nFactor logon (an `AuthenticationRequirements` document), in display order.
public struct LogonForm: Sendable {
    public struct Field: Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case username, password, passcode, newPassword, checkbox, text, label, heading, error, button
            /// Credential type `domain` or `realm` (Common Forms language [P], docs/16 §2.3): a text field, or a list
            /// when `choices` is not empty.
            case domain
        }

        /// One entry of a `ComboBox` (Common Forms language [P]): shown text and posted value.
        public struct Choice: Sendable, Equatable {
            public var display: String
            public var value: String
            public init(display: String, value: String) {
                self.display = display
                self.value = value
            }
        }

        /// Credential ID (the post field name), or `#<index>` for a label without one.
        public var id: String
        public var kind: Kind
        /// Human text (resolved from the gateway's string key).
        public var label: String
        /// The raw label text from the XML, usually a NetScaler string key such as `dualauth_user_name`.
        public var labelKey: String
        /// nFactor credential type (`username`, `password`, `savecredentials`, `none`, ...).
        public var credentialType: String
        public var secret: Bool
        /// Regular expression the whole value must match (e.g. `.+`).
        public var constraint: String?
        public var initialValue: String?
        public var readOnly: Bool
        /// For buttons: the value posted with the button's ID (e.g. `dualauth_submit`).
        public var buttonValue: String?
        /// For a `ComboBox` input: the entries; `initialValue` is the initial selection. Empty for text inputs.
        public var choices: [Choice] = []

        /// True for the gateway's "remember my credentials" checkbox; we always post `false` for it
        /// (the app offers its own Keychain option instead).
        public var isSaveCredentials: Bool { credentialType == "savecredentials" }
        /// True if the field's value is posted.
        public var isInput: Bool {
            switch kind {
            case .username, .password, .passcode, .newPassword, .checkbox, .text, .domain: true
            default: false
            }
        }
        /// Username, password, passcode or new password: the fields the rejection guard watches.
        public var isCredential: Bool { [.username, .password, .passcode, .newPassword].contains(kind) }

        /// True if `value` satisfies the field's constraint (no constraint: anything).
        public func accepts(_ value: String) -> Bool {
            if !choices.isEmpty { return choices.contains { $0.value == value } }
            guard let constraint, !constraint.isEmpty,
                  let regex = try? NSRegularExpression(pattern: "^(?:" + constraint + ")$", options: [.dotMatchesLineSeparators])
            else { return true }
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }

    public var fields: [Field]
    public var postBack: String
    public var cancelPostBack: String?
    /// True if this form asks again for a credential field that was already posted in this logon,
    /// i.e. the gateway rejected the previous attempt (or the TOTP code was reused).
    public var isRePrompt: Bool
    /// Resolved texts of the error labels.
    public var errors: [String] { fields.filter { $0.kind == .error }.map(\.label) }
    /// Field ids and kinds for logs (never values).
    public var summary: String { fields.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ",") }

    var stateContext: String?
    /// The document had a `StateContext` element (perhaps empty). StoreFront wants it posted back even when empty
    /// (`StateContext=`, Common Forms wire example [P]; live: the lab store, D107). The gateway post is unchanged.
    var hasStateContext = false
    /// Credential IDs posted so far in this logon (all factors).
    var postedIDs: Set<String>
    let strings: LogonStrings
}

/// Result of posting one logon form.
public enum LogonStep: Sendable {
    /// Another factor, or the same form again (`isRePrompt`, usually with error labels).
    case form(LogonForm)
    case success
    case failed(String)
}

// MARK: - Logon

/// A forms logon conversation (Common Forms protocol): NetScaler nFactor at the gateway (`GatewayLogon`) or explicit
/// authentication at a StoreFront store (`StoreFrontLogon`, docs/16 §2). The login window drives either.
public protocol FormLogonFlow {
    /// The client the logon runs on: for a sign-in beside a running session its own (`HTTPClient.signInClient`),
    /// whose cookies the session takes over on success (docs/10 D.6.3).
    var http: HTTPClient { get }
    func begin() async throws -> LogonForm
    func submit(_ form: LogonForm, values: [String: String], button: String?) async throws -> LogonStep
}

/// Logon at a NetScaler Gateway with nFactor ("ExplicitForms" / Common Forms protocol).
/// Interactive use: `begin()`, then `submit` each form until `.success`. Non-interactive use: `logon(_:)`.
public struct GatewayLogon: FormLogonFlow {
    public struct Credentials {
        public var username: String
        public var password: String
        /// Called once per factor that asks for a passcode, so a TOTP is fresh when posted.
        public var passcode: () -> String?
        /// For a form with a separate domain field (StoreFront, docs/16 §2.3). Without one the domain belongs in
        /// `username` (`DOMAIN\user` or a UPN).
        public var domain: String?

        public init(username: String, password: String, domain: String? = nil, passcode: @escaping () -> String? = { nil }) {
            self.username = username
            self.password = password
            self.domain = domain
            self.passcode = passcode
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unexpectedResponse(String)
        case rejected([String])
        /// The non-interactive logon cannot fill a field (e.g. a new password or a passcode without a TOTP secret).
        case needsInput(String)

        public var description: String {
            switch self {
            case .unexpectedResponse(let text): "unexpected gateway response: \(text)"
            case .rejected(let labels): "logon rejected: \(labels.joined(separator: " / "))"
            case .needsInput(let what): "the gateway asks for input that cannot be filled automatically: \(what)"
            }
        }
    }

    static let credentialTypes = "none, username, domain, password, newpassword, passcode, savecredentials, "
        + "textcredential, webview, negotiate, nsg_push, nsg_push_otp, nf_sspr_rem, nfactor_otp"
    static let labelTypes = "none, plain, heading, information, warning, error, confirmation, image, nsg-epa, "
        + "nsg-epa-failure, nsg-login-label, tlogin-failure-msg, nsg-tlogin-heading, nsg-tlogin-single-res, "
        + "nsg-tlogin-multi-res, nsg-tlogin, nsg-login-heading, nsg-fullvpn, nsg-l20n, nsg-l20n-error, "
        + "certauth-failure-msg, dialogue-label, nsg-change-pass-assistive-text, nsg_confirmation"
    static let headers = [
        "X-Citrix-AM-CredentialTypes": credentialTypes,
        "X-Citrix-AM-LabelTypes": labelTypes,
        "X-Citrix-IsUsingHTTPS": "Yes",
    ]

    public let http: HTTPClient
    public let base: URL
    /// Preferred UI languages, best first (BCP 47, e.g. `de-DE`).
    public let languages: [String]
    /// After a successful logon, select the Workspace/ICA web client mode (`/cgi/setclient?wica`), which the
    /// Receiver-for-Web store under /welcome/ needs (D11). Native clients don't call it (docs/15 §1.1).
    /// Default: on, unless `ICA_SKIP_SETCLIENT=1`.
    public var selectWebClient = ProcessInfo.processInfo.environment["ICA_SKIP_SETCLIENT"] != "1"

    typealias Transport = (_ method: String, _ url: URL, _ headers: [String: String], _ form: [(String, String)]?)
        async throws -> HTTPClient.Response
    /// HTTP requests (tests replace it).
    var transport: Transport

    public init(http: HTTPClient, base: URL, languages: [String] = Locale.preferredLanguages) {
        self.http = http
        self.base = base
        self.languages = languages
        transport = { method, url, headers, form in try await http.send(method, url, headers: headers, form: form) }
    }

    func send(_ method: String, _ path: String, headers: [String: String] = [:], form: [(String, String)]? = nil)
        async throws -> HTTPClient.Response {
        // Paths include the server's PostBack: credentials go to the gateway's own origin only (security review F-04).
        guard let url = URL(string: path, relativeTo: base), HTTPClient.sameOrigin(url, base) else {
            throw Failure.unexpectedResponse("a form target outside the gateway's origin")
        }
        return try await transport(method, url, headers, form)
    }

    /// Starts a logon: fresh cookie jar, logon page, label strings, first form.
    public func begin() async throws -> LogonForm {
        // An expired NSC_AAAC makes the gateway drop the connection, so start with an empty jar.
        http.clearCookies()
        let page = try await transport("GET", base, [:], nil)
        let strings = await LogonStrings.load(transport: transport, base: base, logonPage: page.url, languages: languages)
        http.trace("  logon strings: \(strings.language), \(strings.gateway.count) from the gateway")
        let response = try await send("POST", "nf/auth/getAuthenticationRequirements.do", headers: Self.headers)
        switch try step(response, strings: strings, postedIDs: []) {
        case .form(let form): return form
        case .success: throw Failure.unexpectedResponse("logon succeeded without credentials")
        case .failed(let message): throw Failure.rejected([message])
        }
    }

    /// Posts a form. `values` are keyed by field id; fields without a value post their initial value.
    /// `button` is the id of the pressed button (default: the first button).
    public func submit(_ form: LogonForm, values: [String: String], button: String? = nil) async throws -> LogonStep {
        let body = Self.encode(form, values: values, button: button)
        http.trace("  nFactor post fields=\(body.map(\.0).joined(separator: ","))")
        let response = try await send("POST", form.postBack, headers: Self.headers, form: body)
        let posted = form.postedIDs.union(form.fields.filter(\.isCredential).map(\.id))
        let next = try step(response, strings: form.strings, postedIDs: posted)
        if case .success = next, selectWebClient {
            // Select the Workspace/ICA client mode; without it the store under /welcome/ answers 404.
            _ = try await send("GET", "cgi/setclient?wica")
        }
        return next
    }

    /// Non-interactive logon. Never re-posts a password: if the gateway asks again for a credential
    /// field that was already posted, the logon stops with `.rejected` (repeated attempts can lock
    /// the directory account, and a reused TOTP code is refused the same way).
    public func logon(_ credentials: Credentials) async throws {
        var form = try await begin()
        for _ in 0..<5 {
            http.trace("  nFactor form fields=\(form.summary)")
            if form.isRePrompt { throw Failure.rejected(form.errors) }
            switch try await submit(form, values: Self.values(for: form, credentials)) {
            case .success: return
            case .failed(let message): throw Failure.rejected([message])
            case .form(let next): form = next
            }
        }
        throw Failure.unexpectedResponse("too many logon factors")
    }

    /// Values for the non-interactive logon. Calls `passcode()` once per passcode field.
    static func values(for form: LogonForm, _ credentials: Credentials) throws -> [String: String] {
        var values: [String: String] = [:]
        // `DOMAIN\user` goes into two fields when the form has its own domain field.
        let hasDomain = form.fields.contains { $0.kind == .domain && !$0.readOnly }
        var username = credentials.username
        var domain = credentials.domain
        if hasDomain, let slash = username.firstIndex(of: "\\") {
            if domain == nil { domain = String(username[..<slash]) }
            username = String(username[username.index(after: slash)...])
        } else if !hasDomain, let d = domain, !d.isEmpty, !username.contains("\\"), !username.contains("@") {
            // No domain field (e.g. a StoreFront form with only username/password): the domain goes in as a
            // `DOMAIN\user` prefix, which is what the `.env` key CITRIX_DOMAIN means (live: the lab store, D107).
            username = d + "\\" + username
        }
        for field in form.fields where field.isInput && !field.readOnly {
            switch field.kind {
            case .username: values[field.id] = username
            case .domain:
                let wanted = domain ?? field.initialValue ?? ""
                if field.choices.isEmpty {
                    guard field.accepts(wanted) else { throw Failure.needsInput("domain") }
                    values[field.id] = wanted
                } else {
                    // Match the value or the shown name, case-insensitively.
                    guard let choice = field.choices.first(where: { $0.value.caseInsensitiveCompare(wanted) == .orderedSame })
                        ?? field.choices.first(where: { $0.display.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                        throw Failure.needsInput("domain (not in the list)")
                    }
                    values[field.id] = choice.value
                }
            case .password: values[field.id] = credentials.password
            case .passcode:
                guard let code = credentials.passcode(), !code.isEmpty else { throw Failure.needsInput("passcode") }
                values[field.id] = code
            case .newPassword: throw Failure.needsInput("new password")
            case .text:
                let value = field.initialValue ?? field.choices.first?.value ?? ""
                if !field.accepts(value) { throw Failure.needsInput(field.labelKey.isEmpty ? field.id : field.labelKey) }
                if !field.choices.isEmpty { values[field.id] = value }
            default: break
            }
        }
        return values
    }

    /// The form post body: input fields in form order, the pressed button, then `StateContext`.
    static func encode(_ form: LogonForm, values: [String: String], button: String?) -> [(String, String)] {
        var body: [(String, String)] = []
        let pressed = button ?? form.fields.first { $0.kind == .button }?.id
        for field in form.fields {
            switch field.kind {
            case .checkbox:
                let value = field.isSaveCredentials ? "false" : (values[field.id] ?? field.initialValue ?? "false")
                body.append((field.id, value))
            case .button:
                if field.id == pressed { body.append((field.id, field.buttonValue ?? "")) }
            default:
                guard field.isInput else { continue }
                let value = field.readOnly ? (field.initialValue ?? "") : (values[field.id] ?? field.initialValue ?? "")
                body.append((field.id, value))
            }
        }
        if let state = form.stateContext { body.append(("StateContext", state)) }
        return body
    }

    func step(_ response: HTTPClient.Response, strings: LogonStrings, postedIDs: Set<String>) throws -> LogonStep {
        let document = try FormResponse(response)
        let form = LogonForm(document, strings: strings, postedIDs: postedIDs)
        http.trace("  nFactor result=\(document.result) fields=\(form.summary)\(form.isRePrompt ? " (re-prompt)" : "")")
        switch document.result {
        case "success":
            return .success
        case "more-info":
            guard !form.postBack.isEmpty else { throw Failure.unexpectedResponse("no PostBack") }
            return .form(form)
        default:
            let texts = form.errors.isEmpty ? form.fields.filter { $0.kind == .label }.map(\.label) : form.errors
            return .failed(texts.isEmpty ? "Result \(document.result.isEmpty ? "?" : document.result)" : texts.joined(separator: " "))
        }
    }
}

// MARK: - Kind inference

extension LogonForm {
    static let headingLabelTypes: Set<String> = ["heading", "nsg-login-heading", "nsg-tlogin-heading"]
    static let errorLabelTypes: Set<String> = [
        "error", "warning", "nsg-l20n-error", "tlogin-failure-msg", "certauth-failure-msg", "nsg-epa-failure",
    ]

    init(_ document: FormResponse, strings: LogonStrings, postedIDs: Set<String>) {
        var fields: [Field] = []
        var sawInput = false
        var sawPassword = false
        for (index, r) in document.requirements.enumerated() {
            let type = r.type.lowercased()
            let kind: Field.Kind
            if r.button != nil {
                kind = .button
            } else if r.checkBox != nil || type == "savecredentials" {
                kind = .checkbox
            } else if r.id != nil, type == "domain" || type == "realm", r.hasTextInput || r.comboBox != nil {
                kind = .domain
            } else if r.id != nil, r.comboBox != nil {
                kind = .text
            } else if r.id != nil, r.hasTextInput || ["username", "password", "passcode", "newpassword"].contains(type) {
                switch type {
                case "username": kind = .username
                case "passcode", "nfactor_otp", "nsg_push_otp": kind = .passcode
                case "newpassword": kind = .newPassword
                case "password":
                    kind = sawPassword || Self.looksLikePasscode(r.label, resolved: strings.text(for: r.label)) ? .passcode : .password
                default: kind = .text
                }
            } else if Self.errorLabelTypes.contains(r.labelType.lowercased()) {
                kind = .error
            } else if Self.headingLabelTypes.contains(r.labelType.lowercased()) {
                kind = .heading
            } else {
                // A text-only requirement above all inputs (e.g. `dualauth_please_log_on`) is the form's title.
                kind = sawInput ? .label : .heading
            }
            if kind == .password { sawPassword = true }
            if kind != .label && kind != .heading && kind != .error { sawInput = true }
            // Label-only requirements without text carry nothing to show.
            if [.label, .heading, .error].contains(kind), r.label.isEmpty { continue }
            let labelKey = kind == .button ? (r.button ?? "") : r.label
            fields.append(Field(
                id: r.id ?? "#\(index)", kind: kind, label: strings.text(for: labelKey), labelKey: labelKey,
                credentialType: type, secret: r.secret, constraint: r.constraint,
                initialValue: kind == .checkbox ? r.checkBox ?? r.initialValue : r.comboBox?.initial ?? r.initialValue,
                readOnly: r.readOnly, buttonValue: r.button,
                choices: (r.comboBox?.choices ?? []).map { Field.Choice(display: $0.display, value: $0.value) }))
        }
        self.fields = fields
        postBack = document.postBack ?? ""
        cancelPostBack = document.cancelPostBack
        stateContext = document.stateContext
        hasStateContext = document.hasStateContext
        self.postedIDs = postedIDs
        self.strings = strings
        isRePrompt = fields.contains { $0.isCredential && postedIDs.contains($0.id) }
    }

    /// Label key or text that names a one-time code. For keys the schema prefix (`dualauthorotp_…`)
    /// is ignored, since schema names may contain "otp".
    static func looksLikePasscode(_ key: String, resolved: String) -> Bool {
        let words = ["passcode", "otp", "token"]
        var subject = key.lowercased()
        if LogonStrings.isKey(key), let underscore = subject.firstIndex(of: "_") {
            subject = String(subject[subject.index(after: underscore)...])
        }
        return words.contains { subject.contains($0) || resolved.lowercased().contains($0) }
    }
}

// MARK: - Label strings

/// NetScaler UI string keys (`dualauth_user_name`, `errorMessageLabel4001`, ...) → text in the user's language.
/// Source order: the gateway's own RfWebUI string bundle and its custom strings, then a small built-in
/// table (German and English), then a humanised key.
public struct LogonStrings: Sendable {
    public let language: String
    /// Strings served by the gateway (empty if it serves none).
    public let gateway: [String: String]

    public init(language: String, gateway: [String: String] = [:]) {
        self.language = language
        self.gateway = gateway
    }

    public func text(for key: String) -> String {
        guard !key.isEmpty else { return "" }
        if let text = gateway[key], !text.isEmpty { return text }
        let table = Self.builtIn[language] ?? Self.builtIn["en"]!
        if let text = table[key] ?? Self.builtIn["en"]![key] { return text }
        guard Self.isKey(key) else { return key }
        // Schema prefixes vary (`dualauth_`, `dualauthdeviceid_`, ...); the rest of the key is generic.
        if let underscore = key.firstIndex(of: "_") {
            let suffix = "_" + key[key.index(after: underscore)...]
            if let text = table[suffix] ?? Self.builtIn["en"]![suffix] { return text }
        }
        return Self.humanise(key)
    }

    /// True if `text` looks like a string key rather than literal text.
    static func isKey(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `dualauth_user_name` → `User name`.
    static func humanise(_ key: String) -> String {
        var parts = key.split(separator: "_").map(String.init)
        if parts.count > 1 { parts.removeFirst() }
        let text = parts.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Gateway languages with an RfWebUI string bundle.
    static let gatewayLanguages = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "zh-CN", "zh-TW"]

    /// The first preferred language the gateway has strings for, else English.
    static func pick(_ languages: [String]) -> String {
        for raw in languages {
            let parts = raw.split(separator: "-").map(String.init)
            guard let code = parts.first?.lowercased() else { continue }
            if code == "zh" {
                return parts.contains { ["Hant", "TW", "HK", "MO"].contains($0) } ? "zh-TW" : "zh-CN"
            }
            if gatewayLanguages.contains(code) { return code }
        }
        return "en"
    }

    /// Loads the gateway's string bundle for the preferred language (best effort; never throws).
    static func load(transport: GatewayLogon.Transport, base: URL, logonPage: URL, languages: [String]) async -> LogonStrings {
        let language = pick(languages)
        // The logon page's directory, e.g. /logon/LogonPoint/ (RfWebUI default).
        let point: URL = logonPage.path.hasPrefix("/logon/")
            ? logonPage.deletingLastPathComponent()
            : URL(string: "logon/LogonPoint/", relativeTo: base)!
        func get(_ path: String) async -> String? {
            guard let url = URL(string: path, relativeTo: point),
                  let response = try? await transport("GET", url, [:], nil), response.status == 200 else { return nil }
            return response.text
        }
        func bundle(_ lang: String) async -> [String: String] {
            let path = lang == "en" ? "receiver/js/localization/en/ctxs.strings.js"
                : "receiver/js/localization/\(lang)/ctxs.strings.\(lang).js"
            guard let text = await get(path), text.contains("addStringBundle") else { return [:] }
            return parseBundle(text)
        }
        var table = await bundle(language)
        if table.isEmpty, language != "en" { table = await bundle("en") }
        // Administrator overrides (`{}` when none).
        if let text = await get("custom/strings.\(language).json"),
           let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            for (key, value) in json { if let value = value as? String { table[key] = value } }
        }
        return LogonStrings(language: language, gateway: table)
    }

    /// Extracts `key: "text"` pairs from a JavaScript string bundle (`addStringBundle("de", {...})`).
    /// Keys may be identifiers or quoted strings. This reads data; it never evaluates the script.
    static func parseBundle(_ source: String) -> [String: String] {
        enum Token { case string(String), word(String), colon, other }
        let s = Array(source.unicodeScalars)
        var i = 0
        var tokens: [Token] = []
        var table: [String: String] = [:]
        func hex(_ count: Int) -> UInt32? {
            guard i + count <= s.count else { return nil }
            let digits = String(String.UnicodeScalarView(s[i..<i + count]))
            i += count
            return UInt32(digits, radix: 16)
        }
        while i < s.count {
            let c = s[i]
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "\"" || c == "'" {
                i += 1
                var text = String.UnicodeScalarView()
                while i < s.count, s[i] != c {
                    if s[i] == "\\", i + 1 < s.count {
                        i += 1
                        let e = s[i]
                        i += 1
                        switch e {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        case "r": text.append("\r")
                        case "u":
                            if var v = hex(4) {
                                // UTF-16 surrogate pair
                                if (0xD800..<0xDC00).contains(v), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                                    i += 2
                                    if let low = hex(4) { v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00) }
                                }
                                if let scalar = Unicode.Scalar(v) { text.append(scalar) }
                            }
                        case "x":
                            if let v = hex(2), let scalar = Unicode.Scalar(v) { text.append(scalar) }
                        default: text.append(e)
                        }
                    } else {
                        text.append(s[i])
                        i += 1
                    }
                }
                i += 1
                tokens.append(.string(String(text)))
            } else if c.properties.isAlphabetic || c == "_" || c == "$" {
                var word = String.UnicodeScalarView()
                while i < s.count, s[i].properties.isAlphabetic || s[i].properties.numericType != nil || s[i] == "_" || s[i] == "$" {
                    word.append(s[i])
                    i += 1
                }
                tokens.append(.word(String(word)))
            } else {
                if c == ":" { tokens.append(.colon) } else if !c.properties.isWhitespace { tokens.append(.other) }
                i += 1
            }
            // key ':' "value"
            if tokens.count >= 3, case .string(let value) = tokens[tokens.count - 1], case .colon = tokens[tokens.count - 2] {
                switch tokens[tokens.count - 3] {
                case .string(let key), .word(let key): table[key] = value
                default: break
                }
            }
            if tokens.count > 8 { tokens.removeFirst(tokens.count - 3) }
        }
        return table
    }

    /// Fallback texts for the common keys, used when the gateway serves no strings. Keys starting with
    /// `_` match any schema prefix (`dualauth_user_name`, `dualauthdeviceid_user_name`, ...).
    static let builtIn: [String: [String: String]] = [
        "en": [
            "_please_log_on": "Please sign in",
            "_user_name": "User name:",
            "_password": "Password:",
            "_passcode": "Passcode:",
            "_remember_my_credentials": "Remember my credentials",
            "_submit": "Sign In",
            "_log_on": "Sign In",
            "errorMessageLabel4001": "Incorrect user name or password.",
            "errorMessageLabel4444": "Incorrect user name or password.",
            "errorMessageLabel4006": "Incorrect user name.",
            "errorMessageLabel4007": "Incorrect password.",
            "errorMessageLabel4011": "Your account is disabled.",
            "errorMessageLabel4012": "Your password has expired.",
            "errorMessageLabel4015": "Your account is temporarily locked.",
            "Invalid Credentials": "Invalid credentials",
            "Incorrect credentials. Try again.": "Incorrect credentials. Try again.",
            "Account Locked": "Account locked",
            "Password Expired": "Password expired",
        ],
        "de": [
            "_please_log_on": "Bitte anmelden",
            "_user_name": "Benutzername:",
            "_password": "Kennwort:",
            "_passcode": "Passcode:",
            "_remember_my_credentials": "Anmeldedaten merken",
            "_submit": "Anmelden",
            "_log_on": "Anmelden",
            "errorMessageLabel4001": "Benutzername oder Kennwort ist falsch.",
            "errorMessageLabel4444": "Benutzername oder Kennwort ist falsch.",
            "errorMessageLabel4006": "Der Benutzername ist falsch.",
            "errorMessageLabel4007": "Das Kennwort ist falsch.",
            "errorMessageLabel4011": "Ihr Konto ist deaktiviert.",
            "errorMessageLabel4012": "Ihr Kennwort ist abgelaufen.",
            "errorMessageLabel4015": "Ihr Konto ist vorübergehend gesperrt.",
            "Invalid Credentials": "Ungültige Anmeldedaten",
            "Incorrect credentials. Try again.": "Anmeldedaten falsch. Bitte erneut versuchen.",
            "Account Locked": "Konto gesperrt",
            "Password Expired": "Kennwort abgelaufen",
        ],
    ]
}

// MARK: - XML

/// Parsed `AuthenticateResponse` document.
struct FormResponse {
    struct Requirement {
        var id: String?
        var type: String
        var label: String
        var labelType: String
        var button: String?
        var hasTextInput: Bool
        var secret: Bool
        var readOnly: Bool
        var initialValue: String?
        var constraint: String?
        /// Initial value of a checkbox input (`nil` if the requirement has no checkbox).
        var checkBox: String?
        /// A `ComboBox` input: entries and initial selection (Common Forms language [P]).
        var comboBox: (choices: [(display: String, value: String)], initial: String?)?
    }

    var result: String
    var stateContext: String?
    var hasStateContext = false
    var postBack: String?
    var cancelPostBack: String?
    var requirements: [Requirement]

    init(_ response: HTTPClient.Response) throws {
        guard let document = SafeXML.document(response.body) else {
            throw GatewayLogon.Failure.unexpectedResponse(
                "HTTP \(response.status) \(response.header("Content-Type") ?? "") from \(response.url.path)")
        }
        func nodes(_ path: String, in node: XMLNode?) -> [XMLNode] {
            // `a/b` → ./*[local-name()='a']/*[local-name()='b'] (the document has a default namespace)
            let xpath = (node == nil ? "/" : ".") + path.split(separator: "/").map { "/*[local-name()='\($0)']" }.joined()
            return (try? (node ?? document).nodes(forXPath: xpath)) ?? []
        }
        func string(_ path: String, in node: XMLNode? = nil) -> String? {
            nodes(path, in: node).first?.stringValue
        }
        func any(_ name: String) -> String? {
            ((try? document.nodes(forXPath: "//*[local-name()='\(name)']")) ?? []).first?.stringValue
        }
        result = any("Result") ?? ""
        stateContext = any("StateContext").flatMap { $0.isEmpty ? nil : $0 }
        hasStateContext = any("StateContext") != nil
        postBack = any("PostBack")
        cancelPostBack = any("CancelPostBack").flatMap { $0.isEmpty ? nil : $0 }
        let list = (try? document.nodes(forXPath: "//*[local-name()='Requirement']")) ?? []
        requirements = list.map { node in
            let text = nodes("Input/Text", in: node).first
            let check = nodes("Input/CheckBox", in: node).first
            let combo = nodes("Input/ComboBox", in: node).first.map { box in
                (choices: nodes("DisplayValues/DisplayValue", in: box).map { entry in
                    let value = string("Value", in: entry) ?? ""
                    return (display: string("Display", in: entry) ?? value, value: value)
                }, initial: string("InitialSelection", in: box).flatMap { $0.isEmpty ? nil : $0 })
            }
            return Requirement(
                id: string("Credential/ID", in: node).flatMap { $0.isEmpty ? nil : $0 },
                type: string("Credential/Type", in: node) ?? "",
                label: string("Label/Text", in: node) ?? "",
                labelType: string("Label/Type", in: node) ?? "",
                button: string("Input/Button", in: node),
                hasTextInput: text != nil,
                secret: text.flatMap { string("Secret", in: $0) } == "true",
                readOnly: text.flatMap { string("ReadOnly", in: $0) } == "true",
                initialValue: text.flatMap { string("InitialValue", in: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                constraint: text.flatMap { string("Constraint", in: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                checkBox: check.map { string("InitialValue", in: $0) ?? "false" },
                comboBox: combo)
        }
    }
}
