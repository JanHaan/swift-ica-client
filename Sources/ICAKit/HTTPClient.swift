import Foundation

/// URLSession wrapper with its own cookie jar, request tracing and cookie persistence.
/// Traces show methods, paths, status codes and cookie names, never cookie values or bodies.
public final class HTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public struct Response {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
        public let url: URL

        public var text: String { String(decoding: body, as: UTF8.self) }

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    public var trace: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// User-Agent for every request of this client (gateway and store), unless a request sets its own.
    /// nil: the system default. Defaults to `ICA_GATEWAY_UA` (docs/15 §1.1: NetScaler picks the session
    /// policy by User-Agent, e.g. `CONTAINS("CitrixReceiver")` for native clients).
    public var userAgent: String? = HTTPClient.environmentUserAgent
    /// `ICA_GATEWAY_UA` if set and non-empty.
    public static var environmentUserAgent: String? {
        ProcessInfo.processInfo.environment["ICA_GATEWAY_UA"].flatMap { $0.isEmpty ? nil : $0 }
    }
    private var session: URLSession!
    private let jar: HTTPCookieStorage
    /// Hosts this client has reached over HTTPS. They are never contacted over plain HTTP afterwards, neither by a
    /// request nor by a redirect (HSTS-like): their cookies without the Secure attribute (and a URL's query) would
    /// cross the network in clear (security review F-04).
    private var secureHosts: Set<String> = []
    private let secureLock = NSLock()
    /// "host version, suite" already logged (`didFinishCollecting`); under `secureLock`.
    private var loggedTLS: Set<String> = []

    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A plain HTTP request to a host this client reached over HTTPS before.
        case downgrade(String)
        public var description: String {
            switch self {
            case .downgrade(let host): "refused plain HTTP to \(host), which this client reached over HTTPS"
            }
        }
    }

    public override init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        jar = config.httpCookieStorage!
        super.init()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// The first cookie of this name in the whole jar, whatever its domain. Prefer `cookie(_:for:)`: a jar loaded from
    /// disk may hold cookies of several hosts (a gateway and a lab store, D107).
    public func cookie(_ name: String) -> String? {
        jar.cookies?.first { $0.name == name }?.value
    }

    /// The cookie of this name that a request to `url` would carry (domain, path and Secure rules of the jar).
    public func cookie(_ name: String, for url: URL) -> String? {
        cookieRecord(name, for: url)?.value
    }

    /// Every cookie of this name in the jar (all hosts).
    public func cookieRecords(_ name: String) -> [HTTPCookie] { (jar.cookies ?? []).filter { $0.name == name } }

    public func cookieRecord(_ name: String, for url: URL) -> HTTPCookie? {
        jar.cookies(for: url.absoluteURL)?.first { $0.name == name }
    }

    public var cookieNames: [String] { (jar.cookies ?? []).map(\.name).sorted() }

    /// The first cookie with this name (value, domain, path), e.g. to persist the store's device id.
    public func cookieRecord(_ name: String) -> HTTPCookie? {
        jar.cookies?.first { $0.name == name }
    }

    public func setCookie(_ cookie: HTTPCookie) { jar.setCookie(cookie) }

    public func clearCookies() {
        for cookie in jar.cookies ?? [] { jar.deleteCookie(cookie) }
    }

    /// Empties the jar and deletes its saved copy (`saveCookies`): after "forget my login" the gateway and store
    /// session cookies must not sign the next start in (security review L-03).
    public func clearCookies(deletingFile path: String) {
        clearCookies()
        try? FileManager.default.removeItem(atPath: path)
    }

    public func send(
        _ method: String, _ url: URL, headers: [String: String] = [:], form: [(String, String)]? = nil
    ) async throws -> Response {
        if let form {
            return try await send(method, url, headers: headers, body: Data(Self.formEncode(form).utf8),
                                  contentType: "application/x-www-form-urlencoded")
        }
        return try await send(method, url, headers: headers, body: method == "POST" ? Data() : nil, contentType: nil)
    }

    /// Request with a raw body (e.g. JSON for the store's session control calls, docs/90 §5.2).
    public func send(
        _ method: String, _ url: URL, headers: [String: String] = [:], body: Data?, contentType: String?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        if let host = downgradedHost(url) {
            trace("✗ \(method) \(Self.display(url)): plain HTTP to a host reached over HTTPS before; refused")
            throw Failure.downgrade(host)
        }
        trace("→ \(method) \(Self.display(url))")
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        noteSecure(url)
        if let final = http.url { noteSecure(final) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: http.url ?? url).map(\.name)
        trace("← \(http.statusCode) \(data.count)B"
            + (setCookies.isEmpty ? "" : " set-cookie: \(setCookies.joined(separator: ","))"))
        return Response(status: http.statusCode, headers: headers, body: data, url: http.url ?? url)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard Self.redirectAllowed(from: response.url ?? task.currentRequest?.url, to: request.url),
              request.url.flatMap(downgradedHost) == nil else {
            // nil: the task completes with this 3xx response, which every caller treats as unexpected.
            trace("↪ \(response.statusCode) → \(request.url.map(Self.display) ?? "?"): HTTPS to plain HTTP; refused")
            return nil
        }
        trace("↪ \(response.statusCode) → \(request.url.map(Self.display) ?? "?")")
        return request
    }

    /// `ICA_EXTRA_CA_FILE` (D144): a server certificate from the lab's own CA is accepted in addition to the system
    /// trust store; the host name and chain are still checked. Without the variable, the system's default handling.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              !ExtraTrust.anchors.isEmpty, let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard ExtraTrust.evaluate(trust) else {
            trace("TLS: \(challenge.protectionSpace.host) not trusted (system store + ICA_EXTRA_CA_FILE)")
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// The negotiated TLS version and cipher suite of each new connection (task metrics), once per host and
    /// parameters: a later connection with the same result is not logged again. Host names only, no secrets.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for t in metrics.transactionMetrics where !t.isReusedConnection && t.resourceFetchType == .networkLoad {
            guard let version = t.negotiatedTLSProtocolVersion, let suite = t.negotiatedTLSCipherSuite,
                  let host = t.request.url?.host?.lowercased() else { continue }
            let info = TLSInfo(version: version, cipherSuite: suite)
            secureLock.lock()
            let fresh = loggedTLS.insert("\(host) \(info)").inserted
            secureLock.unlock()
            if fresh { trace("TLS: \(host) \(info)") }
        }
    }

    // MARK: Transport security (security review F-04)

    /// A redirect may not leave HTTPS for plain HTTP (any host).
    public static func redirectAllowed(from: URL?, to: URL?) -> Bool {
        guard let to else { return false }
        if from?.scheme?.lowercased() == "https" { return to.scheme?.lowercased() == "https" }
        return true
    }

    /// Same scheme, host and port (the default port of the scheme when absent).
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ u: URL) -> (String, String, Int)? {
            let u = u.absoluteURL
            guard let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return nil }
            return (scheme, host, u.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1))
        }
        guard let x = origin(a), let y = origin(b) else { return false }
        return x == y
    }

    func noteSecure(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return }
        secureLock.lock()
        secureHosts.insert(host)
        secureLock.unlock()
    }

    /// The host if `url` is plain HTTP to a host reached over HTTPS before.
    func downgradedHost(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return nil }
        secureLock.lock()
        defer { secureLock.unlock() }
        return secureHosts.contains(host) ? host : nil
    }

    // MARK: Cookie persistence

    public func saveCookies(to path: String) throws {
        let list = (jar.cookies ?? []).map { cookie in
            Dictionary(uniqueKeysWithValues: (cookie.properties ?? [:]).map { ($0.key.rawValue, $0.value) })
        }
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    public func loadCookies(from path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] ?? []
        for entry in list {
            let properties = Dictionary(uniqueKeysWithValues: entry.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: properties) { jar.setCookie(cookie) }
        }
    }

    // MARK: Helpers

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// URL for traces: path only, query values replaced.
    static func display(_ url: URL) -> String {
        var text = (url.host ?? "") + url.path
        if let query = url.query, !query.isEmpty {
            text += "?" + query.split(separator: "&").map { $0.split(separator: "=").first.map(String.init) ?? "" }
                .map { "\($0)=…" }.joined(separator: "&")
        }
        return text
    }
}
