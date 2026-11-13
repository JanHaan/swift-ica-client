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

    public override init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        jar = config.httpCookieStorage!
        super.init()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func cookie(_ name: String) -> String? {
        jar.cookies?.first { $0.name == name }?.value
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
        trace("→ \(method) \(Self.display(url))")
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
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
        trace("↪ \(response.statusCode) → \(request.url.map(Self.display) ?? "?")")
        return request
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
