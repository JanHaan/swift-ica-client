import Foundation

/// Why a store request needs a new sign-in (docs/10 D.6).
public enum SignInExpiry: String, Sendable, Equatable {
    /// The request through the gateway ended at the gateway's logon page: the gateway session expired.
    case gateway
    /// The store answered with its challenge (`CitrixWebReceiver-Authenticate`, or HTTP 401): the store session
    /// expired. Through a gateway the store sign-in (CitrixAGBasic) renews it; a direct store needs the explicit logon.
    case store

    /// The logon pages of a NetScaler Gateway: `/vpn/index.html` (where an expired session is sent first) and
    /// `/logon/LogonPoint/…` (docs/10 D.1 step 1; the account probe's marks, docs/16 §3).
    static func isGatewayLogonPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasPrefix("/logon/logonpoint/") || p.hasPrefix("/vpn/")
    }

    /// The expiry an answer to a store request shows, if any (docs/10 D.6.1). `requested`: the URL asked for.
    ///
    /// The signal is where the request ended, not the body: the gateway redirects an expired session's store
    /// request (`302 /vpn/index.html`, `302 /logon/LogonPoint/tmindex.html`) to its logon page, which answers
    /// `200` with HTML. HTML alone is no signal (the store's own error pages are HTML, e.g. its 404), and the
    /// `NSC_*` cookies are not either (the redirects neither delete nor replace them).
    public static func detect(_ response: HTTPClient.Response, requested: URL) -> SignInExpiry? {
        if !isGatewayLogonPath(requested.path) {
            if isGatewayLogonPath(response.url.path) { return .gateway }
            // A redirect that was not followed (HTTPClient refuses HTTPS → HTTP) still names the logon page.
            if (300..<400).contains(response.status), let location = response.header("Location"),
               let target = URL(string: location, relativeTo: requested), isGatewayLogonPath(target.path) {
                return .gateway
            }
        }
        if response.header("CitrixWebReceiver-Authenticate") != nil || response.status == 401 { return .store }
        return nil
    }
}

/// One sign-in renewal at a time for every store request of an account (docs/10 D.6).
///
/// A request that finds the sign-in expired starts the renewal, or joins the one already running; requests sent
/// while it runs wait for it first, so the gateway sees no store request during a logon. After the renewal the
/// request is sent once more. A background request (a Connection Center poll, a keep-alive) never starts one:
/// it fails with `Failure.expired` unless a renewal is already running. A request that was sent before a renewal
/// finished and comes back expired does not start a second one: it is only sent again.
public final class SignInRenewal: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A background request found the sign-in expired and did not start a renewal.
        case expired(SignInExpiry)
        /// Signed in again, yet the store still answered as signed out.
        case stillExpired(String)

        public var description: String {
            switch self {
            case .expired(let kind): "\(kind == .gateway ? "gateway" : "store") sign-in expired (not renewed by a background request)"
            case .stillExpired(let what): "\(what): still signed out after a new sign-in"
            }
        }
    }

    /// Signs in again for this kind of expiry (`StoreService.renew` in the app, the `.env` logon in icactl).
    public typealias Renew = @Sendable (SignInExpiry) async throws -> Void

    /// True inside a renewal: its own store requests (e.g. the store sign-in) are neither held nor renewed.
    @TaskLocal static var inside = false

    private let renew: Renew
    private let lock = NSLock()
    private var running: Task<Void, Error>?
    /// Counts finished sign-ins: a request compares it before and after its round trip.
    private var generation = 0
    /// The generation whose expiry was logged already (one line per expiry, not per poll).
    private var reported: Int?
    private var signedInAt: Date?
    private var lastAnswer: Date?
    /// Renewals started (tests, icactl's report).
    public private(set) var renewals = 0
    /// The first expired answer since the last sign-in: when, and which kind (icactl's timeout report).
    public var lastExpiry: (at: Date, kind: SignInExpiry)? { lock.withLock { expiry } }
    private var expiry: (at: Date, kind: SignInExpiry)?
    /// One line per expiry and per renewal outcome; no secrets (paths and times only).
    public var log: @Sendable (String) -> Void = { _ in }
    var clock: @Sendable () -> Date = { Date() }

    public init(renew: @escaping Renew) {
        self.renew = renew
    }

    /// Runs `body` with its store requests neither held nor renewed (a sign-in's own store requests).
    public static func exempt<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $inside.withValue(true) { try await body() }
    }

    /// A sign-in done outside a renewal (the first one, File > Sign In, `icactl login`).
    public func noteSignedIn() {
        let now = clock()
        lock.withLock {
            generation += 1
            signedInAt = now
            lastAnswer = now
        }
    }

    /// When this process last signed in (nil: before it started, from a saved cookie jar).
    public var lastSignIn: Date? { lock.withLock { signedInAt } }

    /// Sends a store request; on an expired sign-in renews it (or joins the running renewal) and sends it once more.
    public func send(_ url: URL, background: Bool = false,
                     _ request: () async throws -> HTTPClient.Response) async throws -> HTTPClient.Response {
        if Self.inside { return try await request() }
        let seen = try await settled()
        let first = try await request()
        guard let expiry = SignInExpiry.detect(first, requested: url) else {
            if first.status == 403, try await renewedSince(seen) {
                // Sent with the old session's CSRF token while another request renewed it (the lab's store answers
                // those 403, not its challenge): the store did not act, so sending it again is safe.
                return try await request()
            }
            if first.status < 400 { answered() }
            return first
        }
        try await renewal(after: seen, expiry, what: Self.what(url), background: background)
        let second = try await request()
        if SignInExpiry.detect(second, requested: url) != nil {
            log("sign-in: \(Self.what(url)) still signed out after the new sign-in")
            throw Failure.stillExpired(Self.what(url))
        }
        answered()
        return second
    }

    /// Waits for a running renewal and returns the generation to compare against (its error is rethrown: the
    /// request would only find the sign-in expired again).
    private func settled() async throws -> Int {
        let (task, current) = lock.withLock { (running, generation) }
        guard let task else { return current }
        try await task.value
        return lock.withLock { generation }
    }

    /// Whether a renewal finished since generation `seen`, or is running (then after waiting for it).
    private func renewedSince(_ seen: Int) async throws -> Bool {
        let (task, current) = lock.withLock { (running, generation) }
        if let task {
            try await task.value
            return true
        }
        return current != seen
    }

    private func answered() {
        let now = clock()
        lock.withLock { lastAnswer = now }
    }

    private func renewal(after seen: Int, _ expiry: SignInExpiry, what: String, background: Bool) async throws {
        enum Next { case resend, join(Task<Void, Error>), refuse(log: Bool), start(Task<Void, Error>) }
        let now = clock()
        let next: Next = lock.withLock {
            if generation != seen { return .resend }          // signed in again since this request was sent
            if reported != generation { self.expiry = (now, expiry) }
            if let running { return .join(running) }
            if background {
                let first = reported != generation
                reported = generation
                return .refuse(log: first)
            }
            reported = generation
            renewals += 1
            // Logged under the lock, so it always precedes the renewal's own result line.
            log("sign-in: \(Self.describe(expiry)) on \(what) (\(Self.age(signedInAt, lastAnswer, now))); renewing")
            let task = Task { [self] in
                do {
                    try await Self.$inside.withValue(true) { try await renew(expiry) }
                    let end = clock()
                    lock.withLock {
                        generation += 1
                        signedInAt = end
                        lastAnswer = end
                        running = nil
                    }
                    log(String(format: "sign-in: renewed after %.1f s", end.timeIntervalSince(now)))
                } catch {
                    lock.withLock { running = nil }
                    log("sign-in: not renewed (\(error))")
                    throw error
                }
            }
            running = task
            return .start(task)
        }
        switch next {
        case .resend: return
        case .join(let task), .start(let task): try await task.value
        case .refuse(let first):
            if first { log("sign-in: \(Self.describe(expiry)) on \(what) (\(Self.age(signedInAt, lastAnswer, now))); a background request does not renew it") }
            throw Failure.expired(expiry)
        }
    }

    static func describe(_ expiry: SignInExpiry) -> String {
        expiry == .gateway ? "gateway sign-in expired (answered by the gateway's logon page)" : "store sign-in expired (store challenge)"
    }

    /// "signed in 91 min ago, last answer 86 min ago": what tells the gateway's timeout.
    static func age(_ signedIn: Date?, _ answer: Date?, _ now: Date) -> String {
        func minutes(_ d: Date) -> String { String(format: "%.1f min ago", now.timeIntervalSince(d) / 60) }
        return "signed in " + (signedIn.map(minutes) ?? "before this start") + ", last store answer " + (answer.map(minutes) ?? "none")
    }

    /// The request for the log: the store path without ids (`Resources/GetLaunchStatus`, `Sessions/List`).
    static func what(_ url: URL) -> String {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { ["Resources", "Sessions", "Home", "Authentication", "GatewayAuth"].contains($0) }) else {
            return parts.last ?? url.path
        }
        return parts[i...].prefix(2).joined(separator: "/")
    }
}
