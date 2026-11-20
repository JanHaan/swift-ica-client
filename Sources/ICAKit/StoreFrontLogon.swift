import Foundation

/// Explicit (user name and password) logon at a StoreFront store's Receiver for Web site, without a gateway
/// (docs/16-direct-mode.md §2): `Home/Configuration` → `Authentication/GetAuthMethods` → the `ExplicitForms` URL
/// (`ExplicitAuth/Login`) → Common Forms conversation (`ExplicitAuth/LoginAttempt`, …) until `Result=success`, which
/// sets the `CtxsAuthId` cookie. Afterwards `StoreClient` lists and launches as through the gateway.
///
/// Same conversation model as the gateway's nFactor (`GatewayLogon`, `LogonForm`): the forms are the Common Forms
/// language [P]. Never logs credentials, `StateContext` or cookie values.
public struct StoreFrontLogon: FormLogonFlow {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `Home/Configuration` did not answer with a `clientSettings` document: not a Receiver for Web site.
        case notAStore(Int)
        /// The store offers no `ExplicitForms` method (e.g. only domain pass-through, smart card or a gateway).
        case noExplicitForms([String])
        case http(String, Int)

        public var description: String {
            switch self {
            case .notAStore(let status): "not a StoreFront Receiver for Web site (Home/Configuration answered HTTP \(status))"
            case .noExplicitForms(let names):
                "the store offers no user name and password logon (methods: \(names.isEmpty ? "none" : names.joined(separator: ", ")))"
            case .http(let what, let status): "\(what) failed with HTTP \(status)"
            }
        }
    }

    public struct AuthMethod: Equatable, Sendable {
        public var name: String
        public var url: String
    }

    public let http: HTTPClient
    /// The store's Receiver for Web base, e.g. `https://storefront.example/Citrix/StoreWeb/` (trailing slash).
    public let base: URL
    public let languages: [String]

    typealias Transport = GatewayLogon.Transport
    /// HTTP requests (tests replace it).
    var transport: Transport

    public init(http: HTTPClient, base: URL, languages: [String] = Locale.preferredLanguages) {
        self.http = http
        self.base = Self.normalisedBase(base)
        self.languages = languages
        transport = { method, url, headers, form in try await http.send(method, url, headers: headers, form: form) }
    }

    /// A trailing slash, so relative endpoint paths resolve inside the site.
    static func normalisedBase(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        if !c.path.hasSuffix("/") { c.path += "/" }
        c.query = nil
        c.fragment = nil
        return c.url ?? url
    }

    /// `X-Citrix-IsUsingHTTPS`: `No` on a plain-HTTP site, else StoreFront marks its cookies Secure and they would
    /// not come back over HTTP [P web API "Getting started"].
    static func usingHTTPS(_ url: URL) -> String { url.scheme?.lowercased() == "https" ? "Yes" : "No" }

    func headers(conversation: Bool) -> [String: String] {
        var h = ["X-Citrix-IsUsingHTTPS": Self.usingHTTPS(base), "X-Requested-With": "XMLHttpRequest",
                 "Accept": "application/xml, text/xml, application/vnd.citrix.authenticateresponse-1+xml, */*"]
        if let csrf = http.cookie("CsrfToken", for: base) { h["Csrf-Token"] = csrf }
        if conversation {
            h["X-Citrix-AM-CredentialTypes"] = "none, username, domain, password, newpassword, passcode, savecredentials, textcredential"
            h["X-Citrix-AM-LabelTypes"] = "none, plain, heading, information, warning, error, confirmation"
            // The server localises the form texts by Accept-Language (Common Forms API [P]).
            h["Accept-Language"] = languages.prefix(4).enumerated()
                .map { $0.offset == 0 ? $0.element : "\($0.element);q=\(String(format: "%.1f", 1 - 0.2 * Double($0.offset)))" }
                .joined(separator: ", ")
        }
        return h
    }

    func send(_ path: String, conversation: Bool = false, form: [(String, String)]? = nil) async throws -> HTTPClient.Response {
        let store = StoreClient(http: http, base: base)
        store.syncDeviceId()
        defer { store.syncDeviceId() }
        // Paths include the server's PostBack: credentials go to the store's own origin only (security review F-04).
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, HTTPClient.sameOrigin(url, base) else {
            throw GatewayLogon.Failure.unexpectedResponse("a form target outside the store's origin")
        }
        return try await transport("POST", url, headers(conversation: conversation), form)
    }

    // MARK: Conversation

    /// The site page, `Home/Configuration` (CSRF token, session cookie), an unauthenticated `Resources/List` (the
    /// challenge, as the web UI does [P WEBAPI "Getting started"]), the auth methods, then the first form. This is
    /// the sequence of the lab's working logon (D107).
    public func begin() async throws -> LogonForm {
        let store = StoreClient(http: http, base: base)
        store.syncDeviceId()
        _ = try? await transport("GET", base, ["X-Citrix-IsUsingHTTPS": Self.usingHTTPS(base)], nil)
        let config = try await send("Home/Configuration")
        guard config.status == 200, config.text.contains("clientSettings") else { throw Failure.notAStore(config.status) }
        SessionEndpoints.remember(SessionEndpoints(configuration: config.text), for: base)
        let list = try await send("Resources/List", form: [("format", "json"), ("resourceDetails", "Default")])
        http.trace("  store Resources/List before logon: \(list.status)"
                   + (list.header("CitrixWebReceiver-Authenticate") != nil ? ", challenge" : ""))
        let response = try await send("Authentication/GetAuthMethods")
        guard response.status == 200 else { throw Failure.http("Authentication/GetAuthMethods", response.status) }
        let methods = Self.parseAuthMethods(response.body)
        http.trace("  store auth methods: \(methods.map(\.name).joined(separator: ","))")
        guard let explicit = methods.first(where: { $0.name == "ExplicitForms" }) else {
            throw Failure.noExplicitForms(methods.map(\.name))
        }
        let first = try await send(explicit.url, conversation: true)
        switch try step(first, postedIDs: []) {
        case .form(let form): return form
        case .success: throw GatewayLogon.Failure.unexpectedResponse("logon succeeded without credentials")
        case .failed(let message): throw GatewayLogon.Failure.rejected([message])
        }
    }

    public func submit(_ form: LogonForm, values: [String: String], button: String? = nil) async throws -> LogonStep {
        let body = Self.encode(form, values: values, button: button)
        http.trace("  store form post fields=\(body.map(\.0).joined(separator: ","))")
        let response = try await send(form.postBack, conversation: true, form: body)
        let posted = form.postedIDs.union(form.fields.filter(\.isCredential).map(\.id))
        return try step(response, postedIDs: posted)
    }

    /// Non-interactive logon; like `GatewayLogon.logon`, never re-posts a rejected password.
    public func logon(_ credentials: GatewayLogon.Credentials) async throws {
        var form = try await begin()
        for _ in 0..<5 {
            http.trace("  store form fields=\(form.summary)")
            if form.isRePrompt { throw GatewayLogon.Failure.rejected(form.errors) }
            switch try await submit(form, values: GatewayLogon.values(for: form, credentials)) {
            case .success: return
            case .failed(let message): throw GatewayLogon.Failure.rejected([message])
            case .form(let next): form = next
            }
        }
        throw GatewayLogon.Failure.unexpectedResponse("too many logon forms")
    }

    /// The gateway's form post, plus `StateContext=` when the form had an empty `StateContext` element (StoreFront
    /// expects the field; D107).
    static func encode(_ form: LogonForm, values: [String: String], button: String?) -> [(String, String)] {
        var body = GatewayLogon.encode(form, values: values, button: button)
        if form.stateContext == nil, form.hasStateContext { body.append(("StateContext", "")) }
        return body
    }

    func step(_ response: HTTPClient.Response, postedIDs: Set<String>) throws -> LogonStep {
        guard response.status == 200 else { throw Failure.http(response.url.lastPathComponent, response.status) }
        let document = try FormResponse(response)
        let strings = LogonStrings(language: LogonStrings.pick(languages))
        let form = LogonForm(document, strings: strings, postedIDs: postedIDs)
        http.trace("  store result=\(document.result) fields=\(form.summary)\(form.isRePrompt ? " (re-prompt)" : "")")
        switch document.result {
        case "success":
            return .success
        case "more-info", "update-credentials":
            guard !form.postBack.isEmpty else { throw GatewayLogon.Failure.unexpectedResponse("no PostBack") }
            return .form(form)
        default:
            let texts = form.errors.isEmpty ? form.fields.filter { $0.kind == .label }.map(\.label) : form.errors
            return .failed(texts.isEmpty ? "Result \(document.result.isEmpty ? "?" : document.result)" : texts.joined(separator: " "))
        }
    }

    /// `<authMethods><method name="ExplicitForms" url="ExplicitAuth/Login"/>…</authMethods>` [P].
    static func parseAuthMethods(_ data: Data) -> [AuthMethod] {
        guard let doc = SafeXML.document(data),
              let nodes = try? doc.nodes(forXPath: "//*[local-name()='method']") else { return [] }
        return nodes.compactMap { node in
            guard let e = node as? XMLElement, let name = e.attribute(forName: "name")?.stringValue,
                  let url = e.attribute(forName: "url")?.stringValue else { return nil }
            return AuthMethod(name: name, url: url)
        }
    }
}

// MARK: - Account kind

/// What an address the user typed points at (docs/16 §3): a NetScaler Gateway (nFactor logon, store behind it) or a
/// StoreFront Receiver for Web site reached directly.
public enum AccountKind: String, Sendable, Equatable {
    case gateway
    case storeFront = "storefront"
}

public struct AccountProbe {
    public struct Result: Equatable, Sendable {
        public var kind: AccountKind
        /// Gateway: its root (`https://host/`). StoreFront: the Receiver for Web base (`…/Citrix/StoreWeb/`).
        public var url: URL
    }

    public enum Failure: Error, CustomStringConvertible {
        case notRecognised(URL)
        public var description: String {
            switch self {
            case .notRecognised(let url):
                "\(url.host ?? "the address") is neither a NetScaler Gateway nor a StoreFront store; enter the store "
                    + "URL, e.g. https://storefront.example/Citrix/StoreWeb/"
            }
        }
    }

    typealias Transport = GatewayLogon.Transport
    let http: HTTPClient
    var transport: Transport

    public init(http: HTTPClient) {
        self.http = http
        transport = { method, url, headers, form in try await http.send(method, url, headers: headers, form: form) }
    }

    /// Classifies the answer to a GET of the typed address (redirects followed) [I]: a gateway redirects to its logon
    /// point (`/logon/LogonPoint/`, `/vpn/`, `/nf/`) or sets `NSC_*` cookies; a StoreFront server's IIS root redirects
    /// to `/Citrix/<Store>Web/` (a store path in the final URL or in the page). nil: not recognised.
    public static func classify(requested: URL, response: HTTPClient.Response) -> Result? {
        let path = response.url.path.lowercased()
        let cookies = response.header("Set-Cookie") ?? ""
        if ["/logon/logonpoint", "/vpn/", "/nf/", "/cgi/", "/logon/"].contains(where: { path.hasPrefix($0) })
            || cookies.contains("NSC_") {
            return LoginSettings.gatewayURL(from: requested.absoluteString).map { Result(kind: .gateway, url: $0) }
                ?? Result(kind: .gateway, url: root(of: requested))
        }
        if let site = storeSite(in: response.url.path) {
            return Result(kind: .storeFront, url: root(of: response.url).appendingPathComponent(site, isDirectory: true))
        }
        if let site = storeSite(in: requested.path) {
            return Result(kind: .storeFront, url: root(of: requested).appendingPathComponent(site, isDirectory: true))
        }
        // A page that only links to the store (an HTML or script redirect).
        let text = response.text
        if let range = text.range(of: #"/Citrix/[A-Za-z0-9_.-]+"#, options: .regularExpression),
           let site = storeSite(in: String(text[range]) + "/") {
            return Result(kind: .storeFront, url: root(of: response.url).appendingPathComponent(site, isDirectory: true))
        }
        return nil
    }

    /// `Citrix/<site>` from a path such as `/Citrix/StoreWeb/receiver.html`, keeping the original case.
    static func storeSite(in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0.lowercased() == "citrix" }), i + 1 < parts.count else { return nil }
        let site = parts[i + 1]
        guard !site.isEmpty, !site.contains("."), !site.hasPrefix("?") else { return nil }
        return "Citrix/" + site
    }

    public static func root(of url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: true) ?? URLComponents()
        c.path = "/"
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.url ?? url
    }

    /// GET the address, classify it, and for a StoreFront candidate confirm `Home/Configuration`. A Store Services
    /// path (`/Citrix/Store/`) is tried as its Receiver for Web site `/Citrix/StoreWeb/` (the default naming) [I].
    public func probe(_ url: URL) async throws -> Result {
        let response = try await transport("GET", url, [:], nil)
        guard let found = Self.classify(requested: url, response: response) else { throw Failure.notRecognised(url) }
        guard found.kind == .storeFront else { return found }
        var candidates = [found.url]
        let last = found.url.lastPathComponent
        if !last.lowercased().hasSuffix("web") {
            candidates.append(found.url.deletingLastPathComponent().appendingPathComponent(last + "Web", isDirectory: true))
        }
        for candidate in candidates {
            let headers = ["X-Citrix-IsUsingHTTPS": StoreFrontLogon.usingHTTPS(candidate), "X-Requested-With": "XMLHttpRequest"]
            if let config = try? await transport("POST", URL(string: "Home/Configuration", relativeTo: candidate)!.absoluteURL, headers, nil),
               config.status == 200, config.text.contains("clientSettings") {
                return Result(kind: .storeFront, url: candidate)
            }
        }
        throw Failure.notRecognised(url)
    }
}
