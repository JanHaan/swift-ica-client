import Foundation

/// Policy for relaunching a resource whose session ended before it was established.
///
/// Live: the gateway sometimes drops the link ~0.9 s after the bind, twice in a row. Such early drops
/// (the session layer reports them as "early drop", docs/20 §3.12.2) get up to three relaunches with
/// growing pauses; any other failure that never reached the seamless channel keeps a single relaunch.
public struct LaunchRetry: Equatable, Sendable {
    /// Pauses before relaunch 1, 2, 3 after an early drop.
    public static let earlyDropDelays: [TimeInterval] = [1, 3, 6]
    public static let otherDelay: TimeInterval = 0

    public private(set) var earlyDrops = 0
    public private(set) var otherRetries = 0

    public init() {}

    public enum Decision: Equatable, Sendable {
        case relaunch(attempt: Int, of: Int, delay: TimeInterval)
        case giveUp
    }

    /// True if `endReason` came from the session layer's early-drop path.
    public static func isEarlyDrop(_ endReason: String) -> Bool { endReason.contains("early drop") }

    /// Decides what to do after a session ended and records a relaunch if one is chosen.
    /// `reachedSeamless`: the session got as far as the seamless channel (it was established).
    public mutating func next(reachedSeamless: Bool, endReason: String, terminating: Bool) -> Decision {
        if reachedSeamless {
            self = LaunchRetry()   // established: start counting afresh
            return .giveUp
        }
        guard !terminating else { return .giveUp }
        if Self.isEarlyDrop(endReason) {
            guard earlyDrops < Self.earlyDropDelays.count else { return .giveUp }
            defer { earlyDrops += 1 }
            return .relaunch(attempt: earlyDrops + 1, of: Self.earlyDropDelays.count, delay: Self.earlyDropDelays[earlyDrops])
        }
        guard otherRetries < 1 else { return .giveUp }
        otherRetries += 1
        return .relaunch(attempt: 1, of: 1, delay: Self.otherDelay)
    }
}
