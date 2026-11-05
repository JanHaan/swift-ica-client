import Foundation

/// Did this run log the session on itself, or did it reconnect to an existing (possibly the user's
/// own) session? Evidence for a fresh logon: the logon UI (logonui.exe) appeared, and a later
/// post-logon Thinwire INIT or TWI host init came at least `threshold` after it (live fresh logons:
/// 10–16 s; a reconnect after the logon UI: 1.7 s; a plain reconnect shows no logon UI at all,
/// D18/D20). Anything else counts as a reconnect: only a fresh logon may be logged off.
public struct FreshLogonDetector: Sendable {
    public static let threshold: TimeInterval = 5

    public private(set) var logonUIAt: Date?
    public private(set) var isFresh = false
    private var thinwireInits = 0
    private var hostInits = 0

    public init() {}

    public var sawLogonUI: Bool { logonUIAt != nil }

    /// A TWI window appeared (its app key, e.g. `C:\Windows\System32\LogonUI.exe`).
    public mutating func windowAdded(appKey: String, at now: Date = Date()) {
        if appKey.lowercased().hasSuffix("\\logonui.exe"), logonUIAt == nil { logonUIAt = now }
    }

    /// A Thinwire INIT. Returns the gap to the logon UI when this INIT decided (second INIT on).
    public mutating func thinwireInit(at now: Date = Date()) -> TimeInterval? {
        thinwireInits += 1
        return judge(count: thinwireInits, now)
    }

    /// A TWI host init. Returns the gap to the logon UI when this init decided (second init on).
    public mutating func hostInit(at now: Date = Date()) -> TimeInterval? {
        hostInits += 1
        return judge(count: hostInits, now)
    }

    private mutating func judge(count: Int, _ now: Date) -> TimeInterval? {
        guard count >= 2, !isFresh, let t = logonUIAt else { return nil }
        let gap = now.timeIntervalSince(t)
        isFresh = gap >= Self.threshold
        return gap
    }
}

/// `ICA_LOGOFF_IF_ONLY=<exe>[,<exe>…]`: may a session that is *not* a fresh logon be logged off anyway?
/// Only when every TWI window seen belongs to a listed executable (or to logonui.exe; cmd.exe only if
/// listed: it can be anything the user runs), and at least one window belongs to a listed one other than
/// logonui.exe. An unknown executable, any other window, or no window at
/// all refuses: such a session may be the user's own.
public enum GuardedLogoff {
    public static let alwaysAllowed: Set<String> = ["logonui.exe"]
    public static let unknown = "(unknown)"

    public enum Decision: Equatable, Sendable {
        /// Sorted distinct executable basenames of the windows seen.
        case allowed(seen: [String])
        case refused(seen: [String])
    }

    /// Comma-separated basenames, case-insensitive (`win32calc.exe, Notepad.exe`).
    public static func parseList(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").map { basename($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
    }

    /// Last path component (Windows or POSIX separators), lowercased.
    public static func basename(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "").lowercased()
    }

    /// `windowExecutables`: the executable path of every TWI window seen, nil when unknown.
    public static func decide(allowList: Set<String>, windowExecutables: [String?]) -> Decision {
        let names = windowExecutables.map { $0.map(basename).flatMap { $0.isEmpty ? nil : $0 } ?? unknown }
        let seen = Array(Set(names)).sorted()
        let listed = allowList.map { $0.lowercased() }
        guard !listed.isEmpty, !names.isEmpty else { return .refused(seen: seen) }
        let allKnown = names.allSatisfy { listed.contains($0) || alwaysAllowed.contains($0) }
        let anyListed = names.contains { listed.contains($0) && !alwaysAllowed.contains($0) }
        return allKnown && anyListed ? .allowed(seen: seen) : .refused(seen: seen)
    }
}
