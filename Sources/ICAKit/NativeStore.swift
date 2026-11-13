import Foundation

/// The StoreFront Store Services API ("native" store, as used by the Workspace app), reached through the
/// NetScaler Gateway session (docs/15-native-store-launch.md). The web `StoreClient` stays unchanged.
///
/// Every request goes to the gateway origin with the path of the StoreFront URL (docs/15 §0, §2), carries
/// the gateway session cookie (from the jar), `X-Citrix-Gateway` and a `Citrix-TransactionId`, and a
/// `CitrixAuth` token obtained on demand (§1.2). Tokens live in memory only and are never traced.
public final class NativeStoreClient: @unchecked Sendable {
    // MARK: Types

    public struct Resource: Sendable {
        public let id: String
        public let title: String
        public let path: String?
        public let enabled: Bool
        public let launchURL: URL?
        public let iconURL: URL?
        public let clientTypes: [String]
    }

    public enum LaunchResult: Equatable, Sendable {
        case success(ica: String, logonTicket: String?)
        case retry(url: URL, after: Double, reason: String?)
        case failure(id: String, text: String?)
    }

    public enum Failure: Error, CustomStringConvertible {
        case http(String, Int, String?)
        case unexpected(String)
        case noGatewayProtocol([String])
        case launch(String)

        public var description: String {
            switch self {
            case .http(let what, let status, let reason):
                "\(what) failed with HTTP \(status)" + (reason.map { " (\($0))" } ?? "")
            case .unexpected(let text): "unexpected store response: \(text)"
            case .noGatewayProtocol(let offered):
                "the store offers no gateway pass-through protocol (offered: \(offered.joined(separator: ", ")))"
            case .launch(let text): "launch failed: \(text)"
            }
        }
    }

    /// Default native User-Agent (docs/15 §1.1). It contains "CitrixReceiver" so that the gateway's
    /// documented native-client session policy expression matches; it names this client too.
    public static let defaultUserAgent = "CitrixReceiver/26.09.0.25 MacOSX/26.0 ICAKit/1.0"

    /// Protocols that use the gateway session instead of our own credentials, in preference order.
    static let gatewayProtocols = ["CitrixAGBasic", "CitrixAGBasicNoPassword"]

    static let tokenAccept = "application/vnd.citrix.requesttokenresponse+xml, application/vnd.citrix.requesttokenchoices+xml"
    static let protocolAccept = "application/vnd.citrix.requesttokenresponse+xml, text/xml, application/vnd.citrix.authenticateresponse-1+xml"

    typealias Transport = (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?, _ contentType: String?)
        async throws -> HTTPClient.Response

    // MARK: State

    public let http: HTTPClient
    /// Gateway origin, e.g. https://gateway.example/
    public let gateway: URL
    public let clientName: String
    public let deviceId: String
    /// Optional `launcher` launch parameter (docs/15 §4.1, §7.4 T4 bisection); nil: not sent (as the stock client).
    public var launcher: String?
    /// Store base path through the gateway, e.g. `/Citrix/Store/` (from `setStorePath` or `discoverStore`).
    public private(set) var storePath: String?
    /// The auth protocol chosen in the last token flow (for logs).
    public private(set) var lastProtocol: String?
    /// The protocols the store offered in the last choices response (for logs).
    public private(set) var offeredProtocols: [String] = []

    var transport: Transport
    /// Tokens by realm (service id). Never logged.
    private var tokens: [String: String] = [:]
    /// Protection spaces: path prefix → realm, longest prefix wins.
    private var spaces: [(prefix: String, realm: String)] = []
    /// Endpoint id → URL (already rewritten to the gateway).
    public private(set) var endpoints: [String: URL] = [:]
    var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    public init(http: HTTPClient, gateway: URL, clientName: String, deviceId: String, storePath: String? = nil) {
        self.http = http
        self.gateway = gateway
        self.clientName = clientName
        self.deviceId = deviceId
        self.storePath = storePath.map(Self.normalisedStorePath)
        transport = { method, url, headers, body, contentType in
            try await http.send(method, url, headers: headers, body: body, contentType: contentType)
        }
    }

    static func normalisedStorePath(_ path: String) -> String {
        var p = path.hasPrefix("/") ? path : "/" + path
        if !p.hasSuffix("/") { p += "/" }
        return p
    }

    // MARK: URLs

    /// The same path (and query) on the gateway origin: StoreFront documents return intranet URLs
    /// (docs/15 §0, black-box "Translate url for proxy mode=0").
    public func throughGateway(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let g = URLComponents(url: gateway, resolvingAgainstBaseURL: true) else { return url }
        components.scheme = g.scheme
        components.host = g.host
        components.port = g.port
        return components.url ?? url
    }

    func storeURL(_ relative: String) throws -> URL {
        guard let storePath else { throw Failure.unexpected("store path unknown (set ICA_NATIVE_STORE or discover it)") }
        return URL(string: storePath + relative, relativeTo: gateway)!.absoluteURL
    }

    // MARK: Requests

    var baseHeaders: [String: String] {
        ["X-Citrix-Gateway": gateway.host ?? "", "Citrix-TransactionId": UUID().uuidString.lowercased()]
    }

    /// One request; on a CitrixAuth challenge obtains a token (§1.2) and resends, at most twice.
    func send(_ method: String, _ url: URL, accept: String, body: Data? = nil, contentType: String? = nil)
        async throws -> HTTPClient.Response {
        let target = throughGateway(url)
        var response: HTTPClient.Response!
        for _ in 0..<3 {
            var headers = baseHeaders
            headers["Accept"] = accept
            if let token = token(for: target) { headers["Authorization"] = "CitrixAuth \(token)" }
            response = try await transport(method, target, headers, body ?? (method == "POST" ? Data() : nil), contentType)
            guard response.status == 401,
                  let challenge = CitrixAuthChallenge(header: response.header("WWW-Authenticate")) else { return response }
            try await authorize(challenge, serviceURL: target, depth: 0)
        }
        return response
    }

    /// The token of the protection space `url` belongs to (longest matching path prefix).
    func token(for url: URL) -> String? {
        let path = url.path
        let match = spaces.filter { path.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
        return match.flatMap { tokens[$0.realm] }
    }

    func remember(_ challenge: CitrixAuthChallenge, serviceURL: URL) {
        let hintPath = challenge.serviceRootHint.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = hintPath ?? serviceURL.deletingLastPathComponent().path
        spaces.removeAll { $0.prefix == prefix }
        spaces.append((prefix, challenge.realm))
    }

    /// Obtains a token for `challenge.realm` (docs/15 §1.2, AUTH `security-token-services-api.md`).
    func authorize(_ challenge: CitrixAuthChallenge, serviceURL: URL, depth: Int) async throws {
        guard depth < 4 else { throw Failure.unexpected("CitrixAuth challenge loop") }
        remember(challenge, serviceURL: serviceURL)
        if tokens[challenge.realm] != nil {
            // A known realm on a new path: reuse the token; otherwise it was rejected (expired, …).
            if challenge.reason == "notoken" { return }
            tokens[challenge.realm] = nil
        }
        guard let location = challenge.locations.first.flatMap({ URL(string: $0) }).map(throughGateway) else {
            throw Failure.unexpected("challenge without locations")
        }
        let body = Self.requestToken(forService: challenge.realm, serviceURL: serviceURL)
        var response = try await postToken(location, body: body, accept: Self.tokenAccept)
        if response.status == 401, let next = CitrixAuthChallenge(header: response.header("WWW-Authenticate")) {
            // The token service itself wants a (primary) token first.
            try await authorize(next, serviceURL: location, depth: depth + 1)
            response = try await postToken(location, body: body, accept: Self.tokenAccept)
        }
        if response.status == 300 {
            let choices = Self.parseChoices(response.body)
            offeredProtocols = choices.map(\.protocol)
            guard let choice = Self.gatewayProtocols.lazy.compactMap({ name in choices.first { $0.protocol == name } }).first,
                  let choiceURL = URL(string: choice.location) else {
                throw Failure.noGatewayProtocol(offeredProtocols)
            }
            lastProtocol = choice.protocol
            response = try await postToken(throughGateway(choiceURL), body: body, accept: Self.protocolAccept)
        }
        guard response.status == 200, let token = Self.parseTokenResponse(response.body) else {
            throw Failure.http("token request to \(location.path)", response.status, response.header("Content-Type"))
        }
        tokens[challenge.realm] = token
    }

    func postToken(_ url: URL, body: Data, accept: String) async throws -> HTTPClient.Response {
        var headers = baseHeaders
        headers["Accept"] = accept
        if let token = token(for: url) { headers["Authorization"] = "CitrixAuth \(token)" }
        return try await transport("POST", url, headers, body, "application/vnd.citrix.requesttoken+xml")
    }

    // MARK: Discovery (docs/15 §2)

    /// Finds the store through the account service (`/Citrix/Roaming/Accounts`) unless a path is set.
    /// Returns the discovery URL path.
    @discardableResult
    public func discoverStore() async throws -> String {
        if let storePath { return storePath + "discovery" }
        let url = URL(string: "/Citrix/Roaming/Accounts", relativeTo: gateway)!.absoluteURL
        let response = try await send("GET", url, accept: "application/vnd.citrix.roamingaccounts+xml")
        guard response.status == 200 else { throw Failure.http("Roaming/Accounts", response.status, nil) }
        guard let address = Self.parseAccountStores(response.body).first,
              let path = URL(string: address)?.path, path.hasSuffix("/discovery") else {
            throw Failure.unexpected("no store in the account service answer")
        }
        storePath = Self.normalisedStorePath(String(path.dropLast("discovery".count)))
        return path
    }

    /// Discovery document (no auth) and the store's endpoints list. Returns the discovery document's URLs.
    @discardableResult
    public func discover() async throws -> [URL] {
        try await discoverStore()
        let discovery = try await send("GET", try storeURL("discovery"), accept: "application/vnd.citrix.discovery+xml")
        guard discovery.status == 200 else { throw Failure.http("discovery", discovery.status, nil) }
        let urls = Self.urls(in: discovery.body)
        let found = urls.first { $0.path.hasSuffix("/endpoints/v1") && !$0.path.contains("Auth/") }.map(throughGateway)
        let endpointsURL = try found ?? storeURL("endpoints/v1")
        let list = try await send("GET", endpointsURL, accept: "application/vnd.citrix.endpoints+xml")
        guard list.status == 200 else { throw Failure.http("endpoints", list.status, nil) }
        endpoints = Self.parseEndpoints(list.body).mapValues(throughGateway)
        return urls
    }

    // MARK: Resources (docs/15 §3)

    public func resources() async throws -> [Resource] {
        if endpoints.isEmpty { try await discover() }
        let listed = endpoints["ListResourcesWithAutoProvision"] ?? endpoints["ListResources"]
        let base = try listed ?? storeURL("resources/v2")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: true)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "clientName", value: clientName)]
        let response = try await send("GET", components.url!, accept: "application/vnd.citrix.resources+xml")
        guard response.status == 200 else { throw Failure.http("resources/v2", response.status, nil) }
        return Self.parseResources(response.body).map {
            Resource(id: $0.id, title: $0.title, path: $0.path, enabled: $0.enabled,
                     launchURL: $0.launchURL.map(throughGateway), iconURL: $0.iconURL.map(throughGateway),
                     clientTypes: $0.clientTypes)
        }
    }

    // MARK: Launch (docs/15 §4)

    /// Launches over `launch/ica` and returns the ICA file text; follows `retry` answers (at most 30).
    public func launchICA(_ resource: Resource, now: Date = Date()) async throws -> String {
        guard resource.enabled, var url = resource.launchURL else { throw Failure.launch("\(resource.title) cannot be launched") }
        let body = Self.launchParams(deviceId: deviceId, clientName: clientName, launcher: launcher, start: now)
        for _ in 0..<30 {
            let response = try await send("POST", url, accept: "application/vnd.citrix.launchdata+xml", body: body,
                                          contentType: "application/vnd.citrix.launchparams+xml")
            guard response.status == 200 else {
                throw Failure.http("launch/ica", response.status, response.header("X-Citrix-Error-Reason"))
            }
            guard let result = Self.parseLaunch(response.body) else {
                throw Failure.unexpected("launch answer is not launchdata (\(response.header("Content-Type") ?? "?"))")
            }
            switch result {
            case .success(let ica, _): return ica
            case .retry(let next, let after, _):
                url = throughGateway(next)
                try await sleep(min(max(after, 1), 30))
            case .failure(let id, _): throw Failure.launch("error \(id)")
            }
        }
        throw Failure.launch("\(resource.title) not ready after 30 retries")
    }

    // MARK: Messages

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func requestToken(forService realm: String, serviceURL: URL) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <requesttoken xmlns="http://citrix.com/delivery-services/1-0/auth/requesttoken">\
        <for-service>\(xmlEscape(realm))</for-service>\
        <for-service-url>\(xmlEscape(serviceURL.absoluteString))</for-service-url>\
        <reqtokentemplate/></requesttoken>
        """.utf8)
    }

    /// Launch parameters as the stock client sends them (docs/15 §4.1), minus `clientAddress` (the gateway
    /// supplies the client identity) and without any App Protection claim.
    static func launchParams(deviceId: String, clientName: String, launcher: String?, start: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <launchparams xmlns="http://citrix.com/delivery-services/1-0/launchparams">\
        <deviceId>\(xmlEscape(deviceId))</deviceId>\
        <clientName>\(xmlEscape(clientName))</clientName>\
        <display>seamless</display>\
        <showDesktopViewer>true</showDesktopViewer>
        """
        if let launcher { xml += "<launcher>\(xmlEscape(launcher))</launcher>" }
        xml += "<LaunchSource>WorkspaceApp</LaunchSource>"
            + "<ResourceLaunchStartTime>\(formatter.string(from: start))</ResourceLaunchStartTime>"
            + "<shouldRetryAppLaunchOnReconnect>0</shouldRetryAppLaunchOnReconnect>"
            + "<launchCancellationToken>\(UUID().uuidString.lowercased())</launchCancellationToken>"
            + "</launchparams>"
        return Data(xml.utf8)
    }

    // MARK: Parsing

    static func document(_ data: Data) -> XMLDocument? { try? XMLDocument(data: data) }

    /// Elements anywhere with this local name.
    static func all(_ name: String, in node: XMLNode) -> [XMLNode] {
        (try? node.nodes(forXPath: ".//*[local-name()='\(name)']")) ?? []
    }

    /// The text of the first child path (`a/b`) by local names.
    static func string(_ path: String, in node: XMLNode) -> String? {
        let xpath = "." + path.split(separator: "/").map { "/*[local-name()='\($0)']" }.joined()
        return ((try? node.nodes(forXPath: xpath)) ?? []).first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTokenResponse(_ data: Data) -> String? {
        guard let doc = document(data), let root = doc.rootElement(), root.localName == "requesttokenresponse",
              let token = string("token", in: root), !token.isEmpty else { return nil }
        return token
    }

    static func parseChoices(_ data: Data) -> [(protocol: String, location: String)] {
        guard let doc = document(data) else { return [] }
        return all("choice", in: doc).compactMap { node in
            guard let name = string("protocol", in: node), let location = string("location", in: node) else { return nil }
            return (name, location)
        }
    }

    static func parseAccountStores(_ data: Data) -> [String] {
        guard let doc = document(data) else { return [] }
        return all("Service", in: doc).compactMap { node in
            guard (node as? XMLElement)?.attribute(forName: "type")?.stringValue == "Store" else { return nil }
            return string("Address", in: node)
        }
    }

    static func parseEndpoints(_ data: Data) -> [String: URL] {
        guard let doc = document(data) else { return [:] }
        var out: [String: URL] = [:]
        for node in all("endpoint", in: doc) {
            guard let id = (node as? XMLElement)?.attribute(forName: "id")?.stringValue,
                  let url = string("url", in: node).flatMap(URL.init(string:)) else { continue }
            out[id] = url
        }
        return out
    }

    /// Every absolute http(s) URL in element texts or attributes (the discovery schema is not public).
    static func urls(in data: Data) -> [URL] {
        guard let doc = document(data) else { return [] }
        var out: [URL] = []
        func visit(_ node: XMLNode) {
            if let element = node as? XMLElement {
                for attribute in element.attributes ?? [] { add(attribute.stringValue) }
                if element.children?.allSatisfy({ $0.kind == .text }) ?? false { add(element.stringValue) }
            }
            node.children?.forEach(visit)
        }
        func add(_ text: String?) {
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), t.hasPrefix("http"),
                  let url = URL(string: t), url.host != nil, !out.contains(url) else { return }
            out.append(url)
        }
        visit(doc)
        return out
    }

    static func parseResources(_ data: Data) -> [Resource] {
        guard let doc = document(data) else { return [] }
        return all("resource", in: doc).compactMap { node in
            guard let id = string("id", in: node) else { return nil }
            let enabled = string("enabled", in: node).map { $0 == "true" || $0 == "1" } ?? true
            return Resource(
                id: id, title: string("title", in: node) ?? id, path: string("path", in: node), enabled: enabled,
                launchURL: string("launchica/url", in: node).flatMap(URL.init(string:)),
                iconURL: string("icon/url", in: node).flatMap(URL.init(string:)),
                clientTypes: all("clienttype", in: node).compactMap { $0.stringValue })
        }
    }

    static func parseLaunch(_ data: Data) -> LaunchResult? {
        guard let doc = document(data), let root = doc.rootElement(), root.localName == "launch" else { return nil }
        let status = root.attribute(forName: "status")?.stringValue ?? ""
        switch status {
        case "success":
            // The ICA text keeps its own line breaks; only the XML around it is trimmed.
            guard let ica = (all("ica", in: root).first?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ica.hasPrefix("[") else { return nil }
            return .success(ica: ica, logonTicket: string("result/logonTicket", in: root))
        case "retry":
            guard let url = string("result/retry/url", in: root).flatMap(URL.init(string:)) else { return nil }
            return .retry(url: url, after: string("result/retry/after", in: root).flatMap(Double.init) ?? 3,
                          reason: string("result/retry/reason", in: root))
        default:
            return .failure(id: string("result/error/id", in: root) ?? status, text: string("result/error/text", in: root))
        }
    }
}

// MARK: - CitrixAuth challenge

/// `WWW-Authenticate: CitrixAuth realm="…", reqtokentemplate="", reason="…", locations="a|b", serviceroot-hint="…"`
/// (AUTH `citrixauth-authentication-scheme.md`).
public struct CitrixAuthChallenge: Equatable, Sendable {
    public var realm: String
    public var reason: String?
    public var locations: [String]
    public var serviceRootHint: String?
    public var template: String?

    public init?(header: String?) {
        guard let header, let range = header.range(of: "CitrixAuth", options: [.caseInsensitive]) else { return nil }
        let params = Self.parameters(String(header[range.upperBound...]))
        guard let realm = params["realm"] else { return nil }
        self.realm = realm
        reason = params["reason"]
        locations = (params["locations"] ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        serviceRootHint = params["serviceroot-hint"].flatMap { $0.isEmpty ? nil : $0 }
        template = params["reqtokentemplate"]
    }

    /// `name="value"` or `name=value` pairs; straight or typographic quotes; keys lowercased.
    static func parameters(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:["“”]([^"“”]*)["“”]|([^,\s]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let quoted = match.range(at: 2)
            let value = quoted.location != NSNotFound ? ns.substring(with: quoted) : ns.substring(with: match.range(at: 3))
            if out[key] == nil { out[key] = value }
        }
        return out
    }
}

// MARK: - Device id

/// Our own stable device id for the native store (docs/15 §7.5: never the stock client's), kept 0600.
public enum NativeDeviceId {
    public static func loadOrCreate(path: String) -> String {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        let id = UUID().uuidString.lowercased()
        FileManager.default.createFile(atPath: path, contents: Data((id + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return id
    }
}

// MARK: - ICA key diff

/// Key-name comparison of two ICA files (docs/15 §4.3). Values only for keys known to be non-secret.
public enum ICAKeyDiff {
    public static let shownValues: Set<String> = [
        "Launcher", "ClientType", "LaunchSource", "TWIMode", "SSLEnable", "CGPSecurityTicket", "HDXoverUDP",
        "TransportDriver", "WinStationDriver", "BrowserProtocol", "SFRAllowed", "RemoveICAFile", "ProxyType",
        "ProxyTimeout", "Version", "WebSocketPort", "DesiredColor", "LogonTicketType", "SecureChannelProtocol",
        "DesktopViewer", "ConnectionBar", "TransparentKeyPassthrough", "VirtualCOMPortEmulation",
    ]

    public static func lines(web: ICAFile, native: ICAFile) -> [String] {
        let w = Set(web.keys), n = Set(native.keys)
        func shown(_ key: String, _ file: ICAFile) -> String {
            shownValues.contains(key) ? "\(key)=\(file[key] ?? "")" : key
        }
        var out = ["only in web (\(w.subtracting(n).count)):"]
        out += web.keys.filter { !n.contains($0) }.map { "  " + shown($0, web) }
        out.append("only in native (\(n.subtracting(w).count)):")
        out += native.keys.filter { !w.contains($0) }.map { "  " + shown($0, native) }
        let common = native.keys.filter { w.contains($0) }
        out.append("in both (\(common.count)):")
        for key in common {
            if shownValues.contains(key), web[key] != native[key] {
                out.append("  \(key): web=\(web[key] ?? "") native=\(native[key] ?? "")")
            } else {
                out.append("  \(key)" + (web[key] == native[key] ? "" : " (value differs)"))
            }
        }
        return out
    }
}
