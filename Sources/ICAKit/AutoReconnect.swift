import Foundation

/// Automatic reconnect after session reliability gave up (docs/90 §9.6, D86).
///
/// Reference-style ACR does not work on this site (D84), so the client does what the manual Reconnect panel does:
/// relaunch the same resource through the store, which reconnects to the now-disconnected session (D18,
/// docs/20 §3.12.11). This file holds only the decisions (whether to start, when to try, when to stop); the app
/// drives them with the clock and the network path and does the launching.
public enum AutoReconnect {
    /// The setting "After a connection drop": reconnect automatically (default) or show the Reconnect panel.
    public enum Mode: String, Sendable, CaseIterable {
        case automatic, ask
        public static let defaultMode = Mode.automatic
    }

    /// Why a give-up does not start an automatic reconnect.
    public enum Skip: String, Equatable, Sendable {
        /// The setting is "ask": the manual panel as before.
        case settingAsk
        /// Headless or test run (`ICAVIEWER_LAUNCH`, self-test, hold, autofill, …).
        case automatedRun
        /// The user disconnected or logged off this session, or quit the app.
        case userEnded
        /// The server ended the session normally (FINISH reason 0x00): nothing to reconnect.
        case sessionEnded
        /// FINISH reason 0x03: an administrator disconnected the session; a relaunch is offered, not done (§3.12.8).
        case adminDisconnected
        /// FINISH reason 0x02: the server is shutting down; a relaunch would start a new session elsewhere.
        case serverShutdown
    }

    /// nil: start an automatic reconnect. Otherwise the reason the manual panel (or the plain end) applies.
    /// `userEnded`: a Disconnect, Log Off or Quit was asked for this connection before the give-up arrived.
    public static func skipReason(_ giveUp: CGPTransport.GiveUp, mode: Mode, automated: Bool, userEnded: Bool) -> Skip? {
        if userEnded { return .userEnded }
        if !giveUp.offerRelaunch { return .sessionEnded }
        if case .serverFinish(let reason) = giveUp.cause {
            switch reason {
            case 0x00: return .sessionEnded
            case 0x02: return .serverShutdown
            case 0x03: return .adminDisconnected
            default: break
            }
        }
        if automated { return .automatedRun }
        if mode == .ask { return .settingAsk }
        return nil
    }

    /// One pending reconnect per session: the SessionsharingKey when the ICA file has one (all apps of a shared
    /// session, docs/55), else the connection itself. Keys are compared, never logged.
    public static func sessionKey(sharingKey: String?, connection: String) -> String {
        if let sharingKey, !sharingKey.isEmpty { return "share:" + sharingKey }
        return "conn:" + connection
    }

    /// The sessions with a pending automatic reconnect. `claim` fails for a session that already has one, so a
    /// session is never relaunched twice.
    public struct Registry: Sendable {
        private var keys: Set<String> = []
        public init() {}
        public var isEmpty: Bool { keys.isEmpty }
        public var count: Int { keys.count }
        public func contains(_ key: String) -> Bool { keys.contains(key) }
        public mutating func claim(_ key: String) -> Bool { keys.insert(key).inserted }
        public mutating func release(_ key: String) { keys.remove(key) }
    }

    /// The schedule of one automatic reconnect: wait out the server's SR hold if the give-up was our own decision,
    /// wait for the network while offline, then up to `maxAttempts` relaunches with growing pauses, all within
    /// `budget` from the give-up. After that the manual panel takes over.
    public struct Plan: Equatable, Sendable {
        /// Everything (offline wait, holds, attempts) must start within this time after the give-up.
        public static let budget: TimeInterval = 600
        /// Pause before attempt 1, 2, … (index = attempts already made). The first goes at once.
        public static let delays: [TimeInterval] = [0, 10, 30, 60, 120]
        public static var maxAttempts: Int { delays.count }
        /// After the network comes back: Wi-Fi association, DHCP and DNS need a moment.
        public static let settle: TimeInterval = 3

        public enum Waiting: String, Equatable, Sendable {
            /// Until the VDA's SR hold ends (relaunchNotBefore, §3.12.11): a relaunch before it would not reconnect.
            case serverHold
            /// Pause after a failed attempt.
            case backoff
            /// The network just came back.
            case networkSettle
        }

        public enum Exhausted: Equatable, Sendable {
            /// The budget ran out; `offline` if the network was still down then.
            case budget(offline: Bool)
            /// Every attempt failed.
            case attempts
        }

        public enum Step: Equatable, Sendable {
            case wait(until: Date, Waiting)
            case waitForNetwork(until: Date)
            /// Relaunch now; the app reports the result with `attemptFailed` (success ends the plan).
            case attempt(Int, of: Int)
            /// An attempt is running; nothing to do.
            case inProgress(Int)
            /// Another connection of ours holds this session again (e.g. the user opened one of its apps meanwhile):
            /// its windows come back there, no relaunch.
            case alreadyOpen
            case giveUp(Exhausted)
        }

        public let started: Date
        public let notBefore: Date?
        public private(set) var attempts = 0
        public private(set) var inProgress = false
        private var nextAt: Date
        private var lastOnline: Bool?
        private var onlineSince: Date?

        public init(start: Date, notBefore: Date?) {
            started = start
            self.notBefore = notBefore
            nextAt = start
        }

        public var deadline: Date { started.addingTimeInterval(Self.budget) }

        /// What to do now. Call it on every timer and network change; `.attempt` counts the attempt.
        public mutating func step(now: Date, online: Bool, alreadyOpen: Bool) -> Step {
            defer { lastOnline = online }
            if online, lastOnline == false { onlineSince = now }
            if !online { onlineSince = nil }
            if inProgress { return .inProgress(attempts) }
            if alreadyOpen { return .alreadyOpen }
            if attempts >= Self.maxAttempts { return .giveUp(.attempts) }
            if now >= deadline { return .giveUp(.budget(offline: !online)) }
            if !online { return .waitForNetwork(until: deadline) }
            if let since = onlineSince, now < since.addingTimeInterval(Self.settle) {
                return .wait(until: min(since.addingTimeInterval(Self.settle), deadline), .networkSettle)
            }
            let hold = notBefore ?? .distantPast
            let target = max(nextAt, hold)
            if now < target {
                // A target past the deadline still waits until the deadline, which then gives up.
                return .wait(until: min(target, deadline), hold > nextAt ? .serverHold : .backoff)
            }
            attempts += 1
            inProgress = true
            return .attempt(attempts, of: Self.maxAttempts)
        }

        /// The running attempt failed. One that failed while offline is not counted: the network wait takes over.
        public mutating func attemptFailed(now: Date, online: Bool) {
            guard inProgress else { return }
            inProgress = false
            if !online {
                attempts -= 1
                nextAt = now
                return
            }
            nextAt = now.addingTimeInterval(Self.delays[min(attempts, Self.delays.count - 1)])
        }

        /// "Reconnect now" in the panel: skip the current pause (never the server's SR hold).
        public mutating func skipPause(now: Date) {
            guard !inProgress else { return }
            nextAt = now
            onlineSince = nil
        }
    }
}
