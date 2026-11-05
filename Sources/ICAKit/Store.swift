import Foundation

/// StoreFront "Receiver for Web" API behind the gateway (docs/10-launch.md B.3, D.2–D.3).
public struct StoreClient {
    public struct Resource: Decodable {
        public let id: String
        public let name: String
        public let path: String?
        public let launchurl: String?
        public let launchstatusurl: String?
        public let clienttypes: [String]?
        public let disabled: Bool?
    }

    public enum Failure: Error, CustomStringConvertible {
        case http(String, Int)
        case launch(String)

        public var description: String {
            switch self {
            case .http(let what, let status): "\(what) failed with HTTP \(status)"
            case .launch(let text): "launch failed: \(text)"
            }
        }
    }

    public let http: HTTPClient
    /// Store web base URL, e.g. https://gateway.example.com/welcome/
    public let base: URL

    public init(http: HTTPClient, base: URL) {
        self.http = http
        self.base = base
    }

    func post(_ path: String, form: [(String, String)]? = nil) async throws -> HTTPClient.Response {
        var headers = ["X-Citrix-IsUsingHTTPS": "Yes", "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
        if let csrf = http.cookie("CsrfToken") { headers["Csrf-Token"] = csrf }
        return try await http.send("POST", URL(string: path, relativeTo: base)!, headers: headers, form: form)
    }

    /// Gets a CSRF token and signs in to the store with the gateway session (CitrixAGBasic).
    public func signIn() async throws {
        let config = try await post("Home/Configuration")
        guard config.status == 200 else { throw Failure.http("Home/Configuration", config.status) }
        // GatewayAuth/Login answers "fail / fatalerror" unless the auth methods were queried first.
        _ = try await post("Authentication/GetAuthMethods")
        let login = try await post("GatewayAuth/Login")
        guard login.status == 200, login.text.contains("<Result>success</Result>") else {
            throw Failure.http("GatewayAuth/Login", login.status)
        }
    }

    public func resources() async throws -> [Resource] {
        var response = try await post("Resources/List", form: [("format", "json"), ("resourceDetails", "Default")])
        if response.header("CitrixWebReceiver-Authenticate") != nil {
            try await signIn()
            response = try await post("Resources/List", form: [("format", "json"), ("resourceDetails", "Default")])
        }
        guard response.status == 200 else { throw Failure.http("Resources/List", response.status) }
        struct List: Decodable { let resources: [Resource] }
        return try JSONDecoder().decode(List.self, from: response.body).resources
    }

    /// Waits for the broker to prepare the resource, then downloads its ICA file.
    public func launchICA(_ resource: Resource) async throws -> String {
        guard let statusURL = resource.launchstatusurl, let launchURL = resource.launchurl else {
            throw Failure.launch("\(resource.name) has no launch URL")
        }
        for _ in 0..<30 {
            let response = try await post(
                statusURL, form: [("displayNameDesktopTitle", resource.name), ("createFileFetchTicket", "false")])
            guard response.status == 200 else { throw Failure.http("GetLaunchStatus", response.status) }
            let status = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
            switch status["status"] as? String {
            case "success":
                var components = URLComponents(url: URL(string: launchURL, relativeTo: base)!,
                                               resolvingAgainstBaseURL: true)!
                components.queryItems = [
                    URLQueryItem(name: "CsrfToken", value: http.cookie("CsrfToken") ?? ""),
                    URLQueryItem(name: "IsUsingHttps", value: "Yes"),
                ]
                let ica = try await http.send("GET", components.url!)
                guard ica.status == 200, ica.text.hasPrefix("[") else { throw Failure.http("LaunchIca", ica.status) }
                return ica.text
            case "retry":
                let wait = (status["pollTimeout"] as? Double) ?? 3
                try await Task.sleep(for: .seconds(wait))
            default:
                throw Failure.launch("status \(status["status"] ?? "?") errorId \(status["errorId"] ?? "?")")
            }
        }
        throw Failure.launch("\(resource.name) not ready after 30 polls")
    }
}
