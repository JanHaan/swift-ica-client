import Foundation

/// StoreFront "Receiver for Web" API behind the gateway (docs/10-launch.md B.3, D.2–D.3), or reached directly with
/// explicit authentication (`direct`, docs/16-direct-mode.md §2).
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

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case http(String, Int)
        case launch(String)
        /// Direct store: the store wants a logon and no logon handler is set.
        case needsLogon
        /// A store request through the gateway was answered by the gateway's logon page (docs/10 D.6), and no
        /// renewal is attached (`renewal`) or it is the renewal's own store sign-in.
        case signedOut(String)
        /// `Sessions/GetLaunchStatus` answered 404 for a session entry: that session has ended or moved to another
        /// device (docs/90 §3.3). Not an expired sign-in: nothing signs in again.
        case sessionGone
        /// An answer that is not the expected document (e.g. HTML where launch status JSON belongs).
        case unexpected(String)

        public var description: String {
            switch self {
            case .http(let what, let status): "\(what) failed with HTTP \(status)"
            case .launch(let text): "launch failed: \(text)"
            case .needsLogon: "the store asks for a logon"
            case .signedOut(let what): "\(what): answered by the gateway's logon page (gateway sign-in expired)"
            case .sessionGone: "the session is no longer listed (GetLaunchStatus HTTP 404): it ended or moved"
            case .unexpected(let text): "unexpected store answer: \(text)"
            }
        }
    }

    public let http: HTTPClient
    /// Store web base URL, e.g. https://gateway.example.com/welcome/
    public let base: URL
    /// Where the requests go: `http`, or a scripted store in the tests.
    var transport: StoreTransport
    /// Renews an expired sign-in for every request of this account, one renewal at a time (docs/10 D.6). Shared by
    /// all `StoreClient` values of the account. nil: an expired sign-in is an error (`signedOut`, the challenge).
    public var renewal: SignInRenewal?
    /// Requests nobody waits for (Connection Center polls, keep-alive): they never start a renewal (D.6.4).
    public var background = false

    /// Direct store (no gateway, docs/16 §2): the store session comes from an explicit logon, not CitrixAGBasic.
    public var direct = false
    /// Direct store: runs the explicit logon again when the store asks (e.g. `StoreFrontLogon.logon` with the
    /// remembered credentials, or the login window). nil: `signIn` throws `needsLogon`.
    public var explicitLogon: (() async throws -> Void)?

    public init(http: HTTPClient, base: URL) {
        self.http = http
        self.base = base
        transport = http
    }

    /// A store reached through `transport` (tests).
    init(transport: StoreTransport, http: HTTPClient = HTTPClient(), base: URL, direct: Bool = false) {
        self.http = http
        self.base = direct ? StoreFrontLogon.normalisedBase(base) : base
        self.transport = transport
        self.direct = direct
    }

    /// A direct store at its Receiver for Web base URL (docs/16 §2).
    public init(http: HTTPClient, directBase: URL, explicitLogon: (() async throws -> Void)? = nil) {
        self.http = http
        base = StoreFrontLogon.normalisedBase(directBase)
        transport = http
        direct = true
        self.explicitLogon = explicitLogon
    }

    /// `Yes` unless the store is reached over plain HTTP (docs/16 §2.1).
    var usingHTTPS: String { StoreFrontLogon.usingHTTPS(base) }

    /// Where the store's device id cookie persists between runs (docs/90 §8.6); set once at start by
    /// the app (its settings) or icactl (`.session/`). nil: not persisted.
    nonisolated(unsafe) public static var deviceIdentity: DeviceIdentityStore?

    /// Restores the saved device id into an empty jar, or saves a new one the store set.
    func syncDeviceId() {
        guard let store = Self.deviceIdentity else { return }
        DeviceIdentity.restore(into: http, from: store, base: base)
        DeviceIdentity.remember(from: http, into: store, base: base)
    }

    func post(_ path: String, form: [(String, String)]? = nil) async throws -> HTTPClient.Response {
        let url = URL(string: path, relativeTo: base)!
        let body = form.map { Data(HTTPClient.formEncode($0).utf8) } ?? Data()
        let type = form == nil ? nil : "application/x-www-form-urlencoded"
        return try await exchange(url) { [self] in
            // Built per attempt: after a renewal the store's CSRF token is a new one.
            var headers = ["X-Citrix-IsUsingHTTPS": usingHTTPS, "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
            // The store's own token: a jar may hold another host's CsrfToken too (D107).
            if let csrf = transport.cookie("CsrfToken", for: base) { headers["Csrf-Token"] = csrf }
            syncDeviceId()
            defer { syncDeviceId() }
            return try await transport.send("POST", url, headers: headers, body: body, contentType: type)
        }
    }

    /// One store request, through the renewal when there is one (docs/10 D.6).
    func exchange(_ url: URL, _ request: () async throws -> HTTPClient.Response) async throws -> HTTPClient.Response {
        guard let renewal else { return try await request() }
        return try await renewal.send(url, background: background, request)
    }

    /// The gateway's logon page instead of a store answer, with no renewal to fix it.
    func expired(_ response: HTTPClient.Response, _ url: URL) -> Bool {
        !direct && SignInExpiry.detect(response, requested: url) == .gateway
    }

    /// Session list and actions (docs/90), with the paths from the last `Home/Configuration`. With a renewal its
    /// requests renew an expired sign-in like every other store request; without one, a challenge runs `signIn`.
    public var sessions: StoreSessions {
        if let renewal {
            return StoreSessions(transport: RenewingTransport(base: transport, store: base, renewal: renewal, background: background),
                                 base: base, endpoints: SessionEndpoints.remembered(for: base), reauthenticate: nil,
                                 around: { syncDeviceId() })
        }
        return StoreSessions(transport: transport, base: base, endpoints: SessionEndpoints.remembered(for: base),
                             reauthenticate: { try await signIn() }, around: { syncDeviceId() })
    }

    /// Gets a CSRF token and signs in to the store with the gateway session (CitrixAGBasic). Direct store: the
    /// explicit logon handler instead.
    public func signIn() async throws {
        if direct {
            guard let explicitLogon else { throw Failure.needsLogon }
            return try await explicitLogon()
        }
        let config = try await post("Home/Configuration")
        // The gateway's logon page here means the gateway session itself has expired (docs/10 D.6.2).
        if expired(config, URL(string: "Home/Configuration", relativeTo: base)!) { throw Failure.signedOut("Home/Configuration") }
        guard config.status == 200 else { throw Failure.http("Home/Configuration", config.status) }
        SessionEndpoints.remember(SessionEndpoints(configuration: config.text), for: base)
        // GatewayAuth/Login answers "fail / fatalerror" unless the auth methods were queried first.
        _ = try await post("Authentication/GetAuthMethods")
        let login = try await post("GatewayAuth/Login")
        guard login.status == 200, login.text.contains("<Result>success</Result>") else {
            throw Failure.http("GatewayAuth/Login", login.status)
        }
    }

    /// Right after a gateway logon: `Resources/List` for the store's challenge, then the store sign-in (CitrixAGBasic),
    /// the sequence of docs/10 D.2 steps 9–11. Its requests are exempt from the renewal (they are part of a sign-in).
    public func signInAfterGatewayLogon() async throws {
        try await SignInRenewal.exempt {
            let target = URL(string: "Resources/List", relativeTo: base)!
            let list = try await post("Resources/List", form: [("format", "json"), ("resourceDetails", "Default")])
            if expired(list, target) { throw Failure.signedOut("Resources/List") }
            if SignInExpiry.detect(list, requested: target) == .store { try await signIn() }
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
        if expired(response, URL(string: "Resources/List", relativeTo: base)!) { throw Failure.signedOut("Resources/List") }
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
        let statusTarget = URL(string: statusURL, relativeTo: base)!
        for _ in 0..<30 {
            let response = try await post(statusURL, form: form)
            if expired(response, statusTarget) { throw Failure.signedOut("GetLaunchStatus") }
            // A session entry that is gone (ended, or reconnected elsewhere): refresh the list, never sign in (D.6.5).
            if response.status == 404, resource.isSession { throw Failure.sessionGone }
            guard response.status == 200 else { throw Failure.http("GetLaunchStatus", response.status) }
            guard let status = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
                throw Failure.unexpected("GetLaunchStatus: \(Self.shape(response))")
            }
            switch status["status"] as? String {
            case "success":
                let launchTarget = URL(string: launchURL, relativeTo: base)!
                let ica = try await exchange(launchTarget) { [self] in
                    // Built per attempt: after a renewal the CSRF token is a new one.
                    var components = URLComponents(url: launchTarget, resolvingAgainstBaseURL: true)!
                    components.queryItems = [
                        URLQueryItem(name: "CsrfToken", value: transport.cookie("CsrfToken", for: base) ?? ""),
                        URLQueryItem(name: "IsUsingHttps", value: usingHTTPS),
                    ]
                    return try await transport.send("GET", components.url!, headers: [:], body: nil, contentType: nil)
                }
                if expired(ica, launchTarget) { throw Failure.signedOut("LaunchIca") }
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

    /// Status, content type and size of an answer for the log (never the body).
    static func shape(_ response: HTTPClient.Response) -> String {
        "HTTP \(response.status), \(response.header("Content-Type") ?? "no content type"), \(response.body.count) B"
    }
}

/// A store transport whose requests go through the account's renewal (docs/10 D.6): `StoreSessions` calls.
/// A request sent again after a renewal carries the store's new CSRF token.
final class RenewingTransport: StoreTransport {
    let base: StoreTransport
    let store: URL
    let renewal: SignInRenewal
    let background: Bool

    init(base: StoreTransport, store: URL, renewal: SignInRenewal, background: Bool) {
        self.base = base
        self.store = store
        self.renewal = renewal
        self.background = background
    }

    func send(_ method: String, _ url: URL, headers: [String: String], body: Data?, contentType: String?) async throws
        -> HTTPClient.Response {
        var first = true
        return try await renewal.send(url, background: background) { [self] in
            var h = headers
            if !first, let csrf = base.cookie("CsrfToken", for: store) {
                h["Csrf-Token"] = csrf
                if h["CsrfToken"] != nil { h["CsrfToken"] = csrf }
            }
            first = false
            return try await base.send(method, url, headers: h, body: body, contentType: contentType)
        }
    }

    func cookie(_ name: String) -> String? { base.cookie(name) }
    func cookie(_ name: String, for url: URL) -> String? { base.cookie(name, for: url) }
}
