import Foundation

/// Connection Center placeholders for connections the user just disconnected (docs/90 §9.3): shown as "Disconnected"
/// until the store lists the session as disconnected, so the row does not flicker away. A placeholder must not
/// outlive what it bridges (mac-C's nightly: a "Disconnected — Notepad" row without buttons stayed after a logoff
/// while the server listed 0 sessions).
public struct RecentDisconnects: Sendable {
    public struct Entry: Equatable, Sendable {
        public var apps: [String]
        public var at: Date
    }

    /// The longest a placeholder lives.
    public static let maxAge: TimeInterval = 30
    /// A store list requested this long after the disconnect reflects it: the placeholder has done its job.
    public static let settle: TimeInterval = 5

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func disconnected(_ apps: [String], at time: Date) { entries.append(Entry(apps: apps, at: time)) }

    /// The user logged these apps off (any session with one of them): nothing to bridge.
    public mutating func loggedOff(_ apps: [String]) { entries.removeAll { !Set($0.apps).isDisjoint(with: apps) } }

    /// A successful store list requested at `requested`: entries it already reflects go.
    public mutating func listed(requestedAt requested: Date) {
        entries.removeAll { requested.timeIntervalSince($0.at) >= Self.settle }
    }

    /// The placeholders to show at `now`, without apps that have a connection here again (reconnected).
    public mutating func visible(at now: Date, connectedApps: [String]) -> [Entry] {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.maxAge || !Set($0.apps).isDisjoint(with: connectedApps) }
        return entries
    }
}
