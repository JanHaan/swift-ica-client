import Foundation

/// Ends the signed-in state at the servers, then locally (security review L-04; the web client's sequence, docs/90
/// §6.5 steps 2–3, docs/10 D.1): `POST Authentication/Logoff` at the store, then `GET /cgi/logout` at the gateway
/// when the account goes through one, each step even if the previous one failed, then the cookie jar (memory and
/// file). ICA sessions are not touched: they log off or disconnect on their own (Connection Center).
public enum AccountSignOut {
    public typealias Transport = (_ method: String, _ url: URL, _ headers: [String: String], _ form: [(String, String)]?)
        async throws -> HTTPClient.Response

    public struct Step: Equatable, Sendable, CustomStringConvertible {
        public var name: String
        /// HTTP status, or nil when the request failed.
        public var status: Int?
        public var error: String?
        public var description: String { "\(name) " + (status.map { "HTTP \($0)" } ?? "failed (\(error ?? "?"))") }
    }

    /// `storeBase`: the store's Receiver for Web base (`StoreClient.base`; through a gateway that is
    /// `https://gateway/welcome/`). `gateway`: the gateway root for a gateway account, nil for a direct store.
    /// `cookieFile`: the persisted jar to delete with the cookies.
    public static func run(http: HTTPClient, storeBase: URL?, gateway: URL?, cookieFile: String?,
                           transport: Transport? = nil) async -> [Step] {
        let send: Transport = transport ?? { method, url, headers, form in
            try await http.send(method, url, headers: headers, form: form)
        }
        var steps: [Step] = []
        func attempt(_ name: String, _ method: String, _ url: URL, _ headers: [String: String]) async {
            do {
                let response = try await send(method, url, headers, nil)
                steps.append(Step(name: name, status: response.status))
            } catch {
                steps.append(Step(name: name, status: nil, error: String(describing: error)))
            }
        }
        if let storeBase, let url = URL(string: "Authentication/Logoff", relativeTo: storeBase)?.absoluteURL {
            var headers = ["X-Citrix-IsUsingHTTPS": storeBase.scheme?.lowercased() == "https" ? "Yes" : "No",
                           "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
            if let csrf = http.cookie("CsrfToken", for: storeBase) { headers["Csrf-Token"] = csrf }
            await attempt("store Authentication/Logoff", "POST", url, headers)
        }
        if let gateway, let url = URL(string: "/cgi/logout", relativeTo: gateway)?.absoluteURL {
            await attempt("gateway /cgi/logout", "GET", url, [:])
        }
        if let cookieFile { http.clearCookies(deletingFile: cookieFile) } else { http.clearCookies() }
        return steps
    }
}
