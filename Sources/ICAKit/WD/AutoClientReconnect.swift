import Foundation

/// What an ACR reconnect needs from the previous connection (docs/30 §15.6 point 3): the latest CGP reconnect ticket
/// and the host's ACR cookie, plus the host's cap 0x0A values. Both secrets stay in memory; the description shows
/// lengths only. The ICA file itself is kept by the caller (the same file is used again).
public struct ACRReconnect: Sendable, CustomStringConvertible {
    public let ticket: CGPReconnectTicket
    let cookie: [UInt8]
    public let parameters: WDACRParameters

    init(ticket: CGPReconnectTicket, cookie: [UInt8], parameters: WDACRParameters) {
        self.ticket = ticket
        self.cookie = cookie
        self.parameters = parameters
    }

    public var cookieLength: Int { cookie.count }
    public var acrTimeout: TimeInterval { TimeInterval(parameters.acrTimeout) }

    /// The same data with the ticket's type byte replaced (see `CGPReconnectTicket.withType`).
    public func withTicketType(_ type: UInt8) -> ACRReconnect {
        ACRReconnect(ticket: ticket.withType(type), cookie: cookie, parameters: parameters)
    }

    public var description: String { "\(ticket); cookie \(cookie.count) B; acrTimeout \(parameters.acrTimeout) s" }
}

/// Why a session cannot be reconnected with ACR.
public enum ACRUnavailable: Error, Equatable, Sendable, CustomStringConvertible {
    /// No cap 0x0A in the final capability list (not advertised, or the host did not offer it).
    case notNegotiated
    /// acrTimeout 0.
    case disabledByHost
    /// The handshake never completed on this connection.
    case noICAData
    /// The host never sent a cookie (0x41 sub 1).
    case noCookie
    /// The gateway sent no CGP reconnect ticket (cap 6).
    case noTicket

    public var description: String {
        switch self {
        case .notNegotiated: "ACR not negotiated (no cap 0x0A)"
        case .disabledByHost: "ACR disabled by the host (acrTimeout 0)"
        case .noICAData: "no ICA data received on this connection"
        case .noCookie: "no ACR cookie from the host"
        case .noTicket: "no CGP reconnect ticket from the gateway"
        }
    }
}

/// Milestones of one ACR connect attempt and the verdict (docs/30 §15.6 point 4): the gateway takes the reconnect
/// ticket (BIND_RESPONSE), the WD handshake completes, the host asks for the cookie, and the session's display and
/// windows come back without a new logon. Pure state; feed it from the session queue.
public struct ACRAttemptMonitor: Sendable {
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        /// The same session is back: Thinwire INIT and an app window, no fresh logon.
        case reconnected
        /// The host started a new logon instead of reconnecting (logon UI, then the desktop much later).
        case newLogon
        /// The host took the cookie and reconnected the session (new cookie, Thinwire INIT), but Windows showed its logon
        /// screen and asked for no credentials over ICA; the host ended the connection after about 30 s (live, D84).
        case logonRequired(String)
        /// The gateway did not accept the reconnect ticket (no BIND_RESPONSE, or a FINISH before it).
        case gatewayRejected(String)
        /// The host ended the connection after the handshake (cookie refused, TERMINATE, close).
        case hostRefused(String)
        /// No connection, or it broke before the gateway answered (worth another attempt).
        case failed(String)

        /// Only a transport failure is retried: the same ticket and cookie would be refused again.
        public var isRetryable: Bool { if case .failed = self { true } else { false } }

        public var description: String {
            switch self {
            case .reconnected: "reconnected to the same session"
            case .newLogon: "new logon instead of a reconnect"
            case .logonRequired(let why): "session reconnected, but Windows asks for a logon: \(why)"
            case .gatewayRejected(let why): "gateway rejected the reconnect ticket: \(why)"
            case .hostRefused(let why): "host refused the reconnect: \(why)"
            case .failed(let why): "attempt failed: \(why)"
            }
        }
    }

    public private(set) var transportConnected = false
    public private(set) var bound = false
    public private(set) var wdConnected = false
    /// Length of the cookie we answered the host's 0x41 query with (nil: the host never asked).
    public private(set) var cookieAnswered: Int?
    /// A new cookie from the host on this connection (length).
    public private(set) var newCookie: Int?
    public private(set) var credentialRequested = false
    public private(set) var thinwireInits = 0
    public private(set) var appWindows = 0
    public private(set) var terminateReason: UInt8?
    public private(set) var finishReason: UInt8?
    public private(set) var logon = FreshLogonDetector()

    public init() {}

    public mutating func tlsConnected() { transportConnected = true }

    /// Session events (ICASession.onEvent).
    public mutating func note(_ event: ICASession.Event) {
        switch event {
        case .cgpBound: bound = true
        case .wd(.connected): wdConnected = true
        case .wd(.acrQuery(let length)): cookieAnswered = length
        case .wd(.acrCookie(let length)): newCookie = length
        case .wd(.credentialRequest): credentialRequested = true
        case .wd(.terminate(let reason)): terminateReason = reason
        default: break
        }
    }

    /// A server FINISH_REQUEST reason (CGPTransport.Status.serverFinishReason).
    public mutating func serverFinished(reason: UInt8) { finishReason = reason }

    public mutating func thinwireInit(at now: Date = Date()) {
        thinwireInits += 1
        _ = logon.thinwireInit(at: now)
    }

    public mutating func hostInit(at now: Date = Date()) { _ = logon.hostInit(at: now) }

    /// A TWI window appeared. Logon UI windows feed the fresh-logon detector; other app windows count as the session's.
    public mutating func windowAdded(kind: TWIWindowKind, appKey: String, at now: Date = Date()) {
        logon.windowAdded(appKey: appKey, at: now)
        if kind == .appWindow, !appKey.lowercased().hasSuffix("\\logonui.exe") { appWindows += 1 }
    }

    /// The verdict while the connection is up: nil until the session is back (or a fresh logon is evident).
    public var success: Outcome? {
        if logon.isFresh { return .newLogon }
        guard thinwireInits > 0, appWindows > 0 else { return nil }
        return .reconnected
    }

    /// The verdict after the connection closed (`reason`: the session's close text).
    public func verdict(closed reason: String) -> Outcome {
        if let success { return success }
        if !transportConnected { return .failed("no connection: \(reason)") }
        if !bound {
            if let r = finishReason {
                let kind = (0x11...0x14).contains(r) ? "ticket invalid or unknown" : "FINISH before the bind response"
                return .gatewayRejected(String(format: "%@ (reason 0x%02x)", kind, r))
            }
            return .gatewayRejected("closed without a bind response (\(reason))")
        }
        let reconnected = newCookie != nil || thinwireInits > 0
        if reconnected, logon.sawLogonUI, appWindows == 0 {
            return .logonRequired(terminateReason.map { "TERMINATE reason \($0) at the logon screen" } ?? reason)
        }
        if let t = terminateReason {
            return .hostRefused((cookieAnswered.map { "cookie (\($0) B) refused: " } ?? "") + "TERMINATE reason \(t)")
        }
        if !wdConnected { return .failed("closed during the ICA handshake (\(reason))") }
        if logon.sawLogonUI { return .newLogon }
        return .hostRefused((cookieAnswered == nil ? "no cookie query; " : "after the cookie; ") + reason)
    }
}
