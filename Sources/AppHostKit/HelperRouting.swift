import Foundation

/// Pure decisions of the helper integration (docs/99 §12): which windows a helper hosts, the handles it
/// knows them by, which dirty rects it needs, and how activation moves between processes.
public enum HelperRouting {
    /// TWI app keys that never get a helper: windows without a real app (logon console, orphans) stay in
    /// the main process (docs/99 §3). Mirrors `WindowModel.sessionAppKey` and `noGroup` (ICAKit).
    public static let unroutedKeys: Set<String> = ["", "session", "_NONE_"]

    /// The helper key of an app window, or nil when the main process keeps it; the first app window of a key
    /// starts its helper. Popups and menus: `popupHelperKey`.
    public static func helperKey(appKey: String, isAppWindow: Bool) -> String? {
        guard isAppWindow, !unroutedKeys.contains(appKey) else { return nil }
        return appKey
    }

    /// Phase 2: the helper a popup, menu or tooltip goes to, or nil when the main process keeps it. Only an
    /// app with a running helper takes its popups; a popup never starts a helper (it is transient, and a
    /// helper takes up to seconds to check in).
    public static func popupHelperKey(appKey: String, helperRunning: Bool) -> String? {
        guard helperRunning, !unroutedKeys.contains(appKey) else { return nil }
        return appKey
    }

    /// A helper lives as long as its app has app windows; its own windowless rule counts only those too
    /// (docs/99 §12.22). nil = keep it; else it quits and these popups (left over after the last app window)
    /// go back to the main process first.
    public static func popupsToHandBack<ID>(_ windows: [(id: ID, isApp: Bool)]) -> [ID]? {
        windows.contains(where: \.isApp) ? nil : windows.map(\.id)
    }

    /// A content rect a helper reported, made safe for the integer session maths: nil when not finite or
    /// empty; else its size capped to `limit` (the screens' union) and its origin kept within `limit`
    /// widened by its size (a window may hang off an edge, not be anywhere).
    public static func validFrame(_ r: WirePointRect, limit: CGRect) -> CGRect? {
        guard [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite), r.width > 0, r.height > 0,
              !limit.isEmpty, limit.minX.isFinite, limit.maxY.isFinite else { return nil }
        let w = min(CGFloat(r.width), limit.width), h = min(CGFloat(r.height), limit.height)
        let x = min(max(CGFloat(r.x), limit.minX - w), limit.maxX), y = min(max(CGFloat(r.y), limit.minY - h), limit.maxY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A pointer position from a helper: nil when not finite; else clamped to `limit` widened by its size
    /// on every side (drags may leave the screens, but never by astronomical amounts).
    public static func validPoint(x: Double, y: Double, limit: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, !limit.isEmpty else { return nil }
        let wide = limit.insetBy(dx: -limit.width, dy: -limit.height)
        return CGPoint(x: min(max(CGFloat(x), wide.minX), wide.maxX), y: min(max(CGFloat(y), wide.minY), wide.maxY))
    }

    /// The dirty rects a helper needs: those that touch one of its windows' crops. Order kept.
    public static func dirtyRects(_ dirty: [WireRect], crops: [WireRect]) -> [WireRect] {
        dirty.filter { d in crops.contains { $0.intersects(d) } }
    }

    /// A rect in session pixels (fractional view sizes × k) as the wire's integer rect: edges rounded.
    public static func wireRect(_ r: CGRect) -> WireRect {
        let left = Int(r.minX.rounded()), top = Int(r.minY.rounded())
        return WireRect(x: left, y: top, width: Int(r.maxX.rounded()) - left, height: Int(r.maxY.rounded()) - top)
    }
}

/// Handles for windows inside helpers: small, unique per manager, never reused while the manager lives,
/// so a late message about a removed window can never hit a new one. `Owner` identifies a window on the
/// main side (session + TWI id, or an object identity).
public struct HelperHandles<Owner: Hashable> {
    private var next: UInt32 = 1
    private var byOwner: [Owner: UInt32] = [:]
    private var byHandle: [UInt32: Owner] = [:]

    public init() {}

    /// The handle of `owner`, allocated on first use.
    public mutating func handle(for owner: Owner) -> UInt32 {
        if let h = byOwner[owner] { return h }
        let h = next
        next = next == .max ? 1 : next + 1
        byOwner[owner] = h
        byHandle[h] = owner
        return h
    }

    public func existing(for owner: Owner) -> UInt32? { byOwner[owner] }
    public func owner(of handle: UInt32) -> Owner? { byHandle[handle] }

    @discardableResult
    public mutating func remove(_ owner: Owner) -> UInt32? {
        guard let h = byOwner.removeValue(forKey: owner) else { return nil }
        byHandle[h] = nil
        return h
    }

    public var count: Int { byOwner.count }
}

/// Activation between the main process and its helpers under macOS 14 cooperative activation (docs/99 §4):
/// the app in front yields to the target, then the target activates. Never takes activation from an app
/// that is not ours: the remote focus follows the user, not the other way round.
public enum ActivationHandover {
    public enum Step: Equatable, Sendable {
        /// The main process yields in-process (`NSApp.yieldActivation(to:)`).
        case hostYields(toPid: Int32)
        /// A helper yields; the next step waits for its `yielded` (300 ms fallback).
        case helperYields(fromPid: Int32, toPid: Int32)
        /// The target activates (a helper: `activate(windowId:)`; the host: `NSApp.activate()`).
        case activate(pid: Int32)
    }

    /// Steps to make `target` (the host or one of its helpers) the active app; nil when another app is in
    /// front (or nothing is known to be): then nothing changes.
    public static func plan(frontmost: Int32?, host: Int32, helpers: Set<Int32>, target: Int32) -> [Step]? {
        guard let frontmost, frontmost == host || helpers.contains(frontmost) else { return nil }
        if frontmost == target { return [.activate(pid: target)] }
        if frontmost == host { return [.hostYields(toPid: target), .activate(pid: target)] }
        return [.helperYields(fromPid: frontmost, toPid: target), .activate(pid: target)]
    }
}
