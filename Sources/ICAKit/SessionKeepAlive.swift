import Foundation

/// Keeps the sign-in alive while a remote session is connected (docs/10 D.6.9, D191).
///
/// The gateway ends a web sign-in after about 90 minutes without a request (D190). Someone working in a connected
/// session sends no store request, so the sign-in would end under them and the next launch would renew it. While at
/// least one session is connected this sends one background `Sessions/List` every `interval` (30 min). It never
/// renews an expired sign-in: the next request the user makes does, as before (D184). No sessions, no requests.
public final class SessionKeepAlive: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case alive
        /// The sign-in had expired (not renewed here).
        case expired
        case failed(String)
    }

    /// The interval between requests: 30 min. `override` (seconds) is for tests and development builds only.
    public static func interval(override: String?, development: Bool) -> TimeInterval {
        if development, let override, let seconds = TimeInterval(override), seconds >= 1 { return seconds }
        return 30 * 60
    }

    /// One background `Sessions/List`: never starts a sign-in renewal (`StoreClient.background`).
    public static func ping(_ store: StoreClient) async -> Outcome {
        var store = store
        store.background = true
        do {
            _ = try await store.sessions.list()
            return .alive
        } catch is SignInRenewal.Failure {
            return .expired
        } catch {
            return .failed("\(error)")
        }
    }

    public let interval: TimeInterval
    private let request: @Sendable () async -> Outcome
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var suspended = false
    private var pingCount = 0
    private var lastLogged: Outcome?
    private var lastLoggedAt: Date?
    /// One line per start, stop, change of outcome, and hour.
    public var log: @Sendable (String) -> Void = { _ in }

    /// Requests sent so far (tests).
    public var pings: Int { lock.withLock { pingCount } }
    public var isRunning: Bool { lock.withLock { task != nil } }

    public init(interval: TimeInterval = 30 * 60, request: @escaping @Sendable () async -> Outcome) {
        self.interval = interval
        self.request = request
    }

    /// The number of connected sessions changed (running, not disconnected or still connecting). Starts the timer at
    /// the first one, stops it when the last one ends. Ignored after `signedOut()` until `signedIn()`.
    public func update(connected: Int) {
        let started: Bool? = lock.withLock {
            if connected > 0, task == nil, !suspended {
                task = Task { [weak self] in await self?.run() }
                return true
            }
            if connected == 0, let running = task {
                running.cancel()
                task = nil
                return false
            }
            return nil
        }
        if started == true { log("keep-alive: started (a request every \(Int(interval)) s while a session is connected)") }
        if started == false { log("keep-alive: stopped (no connected session)") }
    }

    /// Sign-out: stop, and send nothing until the next sign-in.
    public func signedOut() {
        lock.withLock { suspended = true }
        stop(reason: "signed out")
    }

    public func signedIn() { lock.withLock { suspended = false } }

    /// The app quits.
    public func stop(reason: String = "quit") {
        let was: Bool = lock.withLock {
            defer { task?.cancel(); task = nil }
            return task != nil
        }
        if was { log("keep-alive: stopped (\(reason))") }
    }

    private func run() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            let outcome = await request()
            if Task.isCancelled { return }
            let (count, shouldLog): (Int, Bool) = lock.withLock {
                pingCount += 1
                let due = lastLogged != outcome || lastLoggedAt.map { Date().timeIntervalSince($0) >= 3600 } != false
                if due { lastLogged = outcome; lastLoggedAt = Date() }
                return (pingCount, due)
            }
            if shouldLog {
                switch outcome {
                case .alive: log("keep-alive: request \(count) answered")
                case .expired: log("keep-alive: request \(count) found the sign-in expired; not renewed (the next user action renews it)")
                case .failed(let why): log("keep-alive: request \(count) failed: \(why)")
                }
            }
        }
    }
}
