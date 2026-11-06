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
        /// Relative to the store base (docs/10 §D); used for the Dock icon (docs/99 Phase 0).
        public let iconurl: String?

        /// A `Sessions/ListAvailable` entry as a launchable resource (docs/90 §4.2).
        init(session: AvailableSession) {
            id = session.launchurl
            name = session.initialapp ?? "session"
            path = nil
            launchurl = session.launchurl
            launchstatusurl = session.launchstatusurl
            clienttypes = nil
            disabled = nil
            iconurl = nil
        }

        /// True for a session entry (reconnect): its launch status request carries no desktop title.
        public var isSession: Bool { launchurl?.hasPrefix("Sessions/") == true }
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

    /// Where the store's device id cookie persists between runs (docs/90 §8.6); set once at start by
    /// the app (its settings) or icactl (`.session/`). nil: not persisted.
    nonisolated(unsafe) public static var deviceIdentity: DeviceIdentityStore?

    /// Restores the saved device id into an empty jar, or saves a new one the store set.
    func syncDeviceId() {
        guard let store = Self.deviceIdentity else { return }
        DeviceIdentity.restore(into: http, from: store, base: base)
        DeviceIdentity.remember(from: http, into: store)
    }

    func post(_ path: String, form: [(String, String)]? = nil) async throws -> HTTPClient.Response {
        var headers = ["X-Citrix-IsUsingHTTPS": "Yes", "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
        if let csrf = http.cookie("CsrfToken") { headers["Csrf-Token"] = csrf }
        syncDeviceId()
        defer { syncDeviceId() }
        return try await http.send("POST", URL(string: path, relativeTo: base)!, headers: headers, form: form)
    }

    /// Session list and actions (docs/90), with the paths from the last `Home/Configuration`.
    public var sessions: StoreSessions {
        StoreSessions(transport: http, base: base, endpoints: SessionEndpoints.remembered(for: base),
                      reauthenticate: { try await signIn() }, around: { syncDeviceId() })
    }

    /// Gets a CSRF token and signs in to the store with the gateway session (CitrixAGBasic).
    public func signIn() async throws {
        let config = try await post("Home/Configuration")
        guard config.status == 200 else { throw Failure.http("Home/Configuration", config.status) }
        SessionEndpoints.remember(SessionEndpoints(configuration: config.text), for: base)
        // GatewayAuth/Login answers "fail / fatalerror" unless the auth methods were queried first.
        _ = try await post("Authentication/GetAuthMethods")
        let login = try await post("GatewayAuth/Login")
        guard login.status == 200, login.text.contains("<Result>success</Result>") else {
            throw Failure.http("GatewayAuth/Login", login.status)
        }
    }

    /// `Home/KeepAlive` (docs/10 D.3 step 17), while the Connection Center is open (docs/90 §8.2).
    public func keepAlive() async {
        _ = try? await post("Home/KeepAlive")
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
        // A session entry has no desktop title (docs/90 §4.2 step 1).
        let form = resource.isSession ? [("createFileFetchTicket", "false")]
            : [("displayNameDesktopTitle", resource.name), ("createFileFetchTicket", "false")]
        for _ in 0..<30 {
            let response = try await post(statusURL, form: form)
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
                if ica.status == 200, ica.text.hasPrefix("[") { return ica.text }
                // A session launch may answer with launch status JSON instead (docs/90 §4.2 step 3).
                let json = ica.status == 200 ? (try? JSONSerialization.jsonObject(with: ica.body)) as? [String: Any] : nil
                guard let json, let state = json["status"] as? String else { throw Failure.http("LaunchIca", ica.status) }
                guard state == "retry" else {
                    throw Failure.launch("status \(state) errorId \(json["errorId"] ?? "?")")
                }
                try await Task.sleep(for: .seconds((json["pollTimeout"] as? Double) ?? 3))
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
