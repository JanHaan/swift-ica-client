import Foundation

/// The redirections a server policy can refuse (D115, D118): the client announces the channel, the host never uses it.
public enum RedirectionFeature: String, CaseIterable, Sendable, Hashable {
    case clipboard, fileCopy, drives, printing, audio

    /// The virtual channel our client binds the feature to; host data on it means the server allows it.
    public var channel: UInt8 {
        switch self {
        case .clipboard: ClipboardWire.channelNumber
        case .fileCopy: GDTWire.channelNumber
        case .drives: CDMWire.channelNumber
        case .printing: PrinterWire.channelNumber
        case .audio: AudioWire.channelNumber
        }
    }

    public static func forChannel(_ channel: UInt8) -> RedirectionFeature? { allCases.first { $0.channel == channel } }
}

/// Which announced redirections the server refused, from host traffic alone (the rule of `icactl policyprobe`, D115):
/// with the policy on, the host opens each announced channel within seconds of the logon (CLIP_INIT, CDM CONNECT,
/// CTXCPM commands, CTXCAM init, the CTXGDT opening write); with it off, it sends **0 bytes** on that channel. So a
/// feature counts as refused once `settleSeconds` have passed since the session's first app window without any host
/// byte on its channel. Before that it is `.waiting`; host data at any time makes it `.inUse` (late data wins).
///
/// File copy rides on the clipboard (D90): the host opens CTXGDT even for a user without clipboard (labuser2: 58 B, the
/// opening exchange), so its traffic proves nothing; file copy counts as refused whenever the clipboard is. A policy
/// with the clipboard on but file copy off is not told apart by this rule [I].
///
/// Not thread-safe; the owner serialises access. Times are seconds on any monotonic clock.
public struct RedirectionStatus: Sendable {
    public enum State: Equatable, Sendable {
        /// Our client did not announce it (off in Settings): nothing to report.
        case notRequested
        /// Announced; the host has not used it yet and the settle time has not passed.
        case waiting
        /// The host sent data on its channel.
        case inUse
        /// Announced, but no host data `settleSeconds` after the first app window: blocked by server policy.
        case refused
    }

    /// Lab (D118, labuser4): the host's first bytes on every allowed channel came between 1.5 s before and 0.4 s after
    /// the first app window; 20 s leaves a wide margin and still tells the user early.
    public static let defaultSettleSeconds: Double = 20

    public let requested: Set<RedirectionFeature>
    public var settleSeconds: Double
    public private(set) var used: Set<RedirectionFeature> = []
    public private(set) var appWindowAt: Double?
    private var noticed: Set<RedirectionFeature> = []

    public init(requested: Set<RedirectionFeature>, settleSeconds: Double = RedirectionStatus.defaultSettleSeconds) {
        self.requested = requested
        self.settleSeconds = settleSeconds
    }

    /// Host data on `channel`. Returns the feature that just became in use (once per feature), else nil.
    @discardableResult
    public mutating func hostData(channel: UInt8) -> RedirectionFeature? {
        guard let f = RedirectionFeature.forChannel(channel), requested.contains(f), !used.contains(f) else { return nil }
        used.insert(f)
        return f
    }

    /// The first app window of the session starts the settle clock; later calls change nothing.
    public mutating func appWindowShown(at time: Double) {
        if appWindowAt == nil { appWindowAt = time }
    }

    public func state(_ f: RedirectionFeature, at time: Double) -> State {
        guard requested.contains(f) else { return .notRequested }
        if f == .fileCopy, requested.contains(.clipboard), state(.clipboard, at: time) == .refused { return .refused }
        if used.contains(f) { return .inUse }
        guard let start = appWindowAt, time - start >= settleSeconds else { return .waiting }
        return .refused
    }

    /// Refused features in `allCases` order.
    public func refused(at time: Double) -> [RedirectionFeature] {
        RedirectionFeature.allCases.filter { state($0, at: time) == .refused }
    }

    /// When the settle time ends (nil before the first app window): the moment to look again.
    public var settlesAt: Double? { appWindowAt.map { $0 + settleSeconds } }

    /// The user tried a refused action. True the first time per feature (show the notice), false afterwards, and
    /// false while the feature is not refused.
    public mutating func attempt(_ f: RedirectionFeature, at time: Double) -> Bool {
        guard state(f, at: time) == .refused, !noticed.contains(f) else { return false }
        noticed.insert(f)
        return true
    }
}
