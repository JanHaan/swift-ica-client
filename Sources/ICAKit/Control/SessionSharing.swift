import Foundation

/// What decides whether a new launch belongs into a running session (docs/55-session-sharing.md §2): the connect
/// endpoint (SSL flag, connect host, connect port), `TWIMode` and `SessionsharingKey`. Desktops never share, and
/// unlike the reference an absent or empty key never matches (§2.2 edge case, §10 step 4).
/// The key is opaque and must not be logged; compare with `==` or `differences`.
public struct SessionShareKey: Equatable, Sendable {
    public var sslEnabled: Bool
    /// The host the client connects to: with the gateway the `SSLProxyHost` host, never the STA ticket in `Address`.
    public var connectHost: String
    public var connectPort: UInt16
    /// `TWIMode` verbatim (the reference compares strings, so `On` ≠ `on`).
    public var twiMode: String
    /// `SessionsharingKey` verbatim; nil when absent or empty.
    public var sharingKey: String?

    public init(sslEnabled: Bool, connectHost: String, connectPort: UInt16, twiMode: String, sharingKey: String?) {
        self.sslEnabled = sslEnabled
        self.connectHost = connectHost
        self.connectPort = connectPort
        self.twiMode = twiMode
        self.sharingKey = sharingKey
    }

    /// §2.1: `SSLProxyHost` if `SSLEnable=On`, else `ProxyHost` if set, else `Address`; the port from the same value
    /// (default 443 with SSL, 1494 without).
    public init(ica: ICAFile) {
        sslEnabled = ica["SSLEnable"]?.lowercased() == "on"
        let proxy = ica["ProxyHost"].flatMap { $0.isEmpty ? nil : $0 }
        let endpoint = sslEnabled ? ica["SSLProxyHost"] ?? "" : proxy ?? ica["Address"] ?? ""
        (connectHost, connectPort) = Self.split(endpoint, defaultPort: sslEnabled ? 443 : 1494)
        twiMode = ica["TWIMode"] ?? ""
        sharingKey = (ica["SessionsharingKey"] ?? ica["SessionSharingKey"]).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func split(_ endpoint: String, defaultPort: UInt16) -> (String, UInt16) {
        // `[v6]:port`, `host:port` or a bare host; an unbracketed IPv6 literal has no port.
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            return (host.lowercased(), rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let colons = endpoint.filter { $0 == ":" }.count
        if colons == 1, let colon = endpoint.lastIndex(of: ":") {
            return (String(endpoint[..<colon]).lowercased(), UInt16(endpoint[endpoint.index(after: colon)...]) ?? defaultPort)
        }
        return (endpoint.lowercased(), defaultPort)
    }

    /// Seamless (`TWIMode` on) with a non-empty key: only such launches share, or take others in.
    public var canShare: Bool { twiMode.lowercased() == "on" && sharingKey != nil }

    /// §2.2: a new launch with key `self` goes into a running session with key `running`.
    public func shares(with running: SessionShareKey) -> Bool {
        canShare && running.canShare && self == running
    }

    /// Names of the fields that differ (values never shown), for logs.
    public func differences(to other: SessionShareKey) -> [String] {
        var out: [String] = []
        if sslEnabled != other.sslEnabled { out.append("SSL") }
        if connectHost != other.connectHost { out.append("connect host") }
        if connectPort != other.connectPort { out.append("connect port") }
        if twiMode != other.twiMode { out.append("TWIMode") }
        if sharingKey != other.sharingKey { out.append("SessionsharingKey") }
        return out
    }
}

/// What to do with a new launch, given the running sessions (docs/55 §10 steps 4–5). Pure, for the app and tests.
public enum SessionSharingDecision<Session>: CustomStringConvertible {
    /// No session matches: an ordinary new connection.
    case connect
    /// Start the app in this session over CTXCTL (queued there until the channel is ready).
    case share(Session)
    /// A session with the same `SessionsharingKey` exists but cannot take the app (no CTXCTL, e.g. started by an older
    /// build, or a different endpoint/TWIMode): no second connection (the host refuses it, §1), only a message.
    case refuse(Session, reason: String)

    public var description: String {
        switch self {
        case .connect: return "connect"
        case .share: return "share"
        case .refuse(_, let reason): return "refuse (\(reason))"
        }
    }

    /// Candidates are the running sessions, newest last (the reference searches newest first, §2.2).
    /// `hasControl`: the session announced CTXCTL (it may still be waiting for the capability commit).
    public static func decide(_ key: SessionShareKey, among sessions: [(session: Session, key: SessionShareKey, hasControl: Bool)])
        -> SessionSharingDecision {
        for candidate in sessions.reversed() where key.shares(with: candidate.key) {
            if candidate.hasControl { return .share(candidate.session) }
            return .refuse(candidate.session, reason: "the running session has no control channel")
        }
        // The same key with another endpoint or TWIMode: still the user's session on the host, which refuses a
        // second one (D51); never connect a second time into it.
        if let k = key.sharingKey, let other = sessions.last(where: { $0.key.sharingKey == k }) {
            return .refuse(other.session, reason: "same SessionsharingKey, but " + key.differences(to: other.key).joined(separator: ", ") + " differ")
        }
        return .connect
    }
}
