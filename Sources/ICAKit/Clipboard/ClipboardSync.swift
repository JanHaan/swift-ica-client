import Foundation

/// The local pasteboard as the sync sees it (NSPasteboard in the app, a fake in tests).
/// Called on one thread only (main in the app).
public protocol ClipboardPasteboard: AnyObject {
    /// Increases on every change (NSPasteboard.changeCount).
    var changeCount: Int { get }
    /// Current contents in the kinds we carry; nil when there is nothing usable, or when the item is
    /// marked concealed/transient (password managers, §5.4 [P]).
    func readContent() -> ClipboardContent?
    /// Replaces the contents; returns the change count after the write.
    func writeContent(_ content: ClipboardContent) -> Int
}

/// Mac side of the clipboard sync (docs/70 §5.4, §5.6): polls `changeCount` at the trigger points,
/// announces changes that are not our own writes, and writes host data. Never blocks on the host: the
/// snapshot goes to the engine through `announce` (the session queue) and host data comes back as a
/// call to `hostContent`. Main thread only.
public final class ClipboardSync {
    public let pasteboard: ClipboardPasteboard
    /// Hands a snapshot to the engine (e.g. `session.clipboardAnnounce`).
    public var announce: (ClipboardSnapshot) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }
    public var now: () -> UInt64 = ClipboardClock.now
    /// False when Mac → host is off: changes are still tracked, but the pasteboard is never read.
    public var readsContent = true

    /// Last change count looked at (announced, skipped, or written by us).
    public private(set) var lastSeen: Int?
    /// The change count our own write produced; never announced (loop prevention).
    public private(set) var ownWrite: Int?
    public private(set) var isReady = false

    public init(pasteboard: ClipboardPasteboard) { self.pasteboard = pasteboard }

    /// The channel is READY (also after a host re-init): announce what the Mac holds now.
    public func channelReady() {
        isReady = true
        lastSeen = nil
        check("channel ready")
    }

    public func channelClosed() { isReady = false }

    /// Trigger point (app active, window key, poll, paste key). Returns true if a snapshot was sent.
    @discardableResult
    public func check(_ reason: String) -> Bool {
        guard isReady else { return false }
        let count = pasteboard.changeCount
        guard count != lastSeen else { return false }
        lastSeen = count
        guard count != ownWrite else { return false }
        let content = readsContent ? pasteboard.readContent() : nil
        let snapshot = ClipboardSnapshot(content: content, takenAt: now())
        log("Mac pasteboard change \(count) (\(reason)): \(content?.summary ?? "nothing to offer")")
        announce(snapshot)
        return true
    }

    /// Host data for the pasteboard. Not written when the Mac changed since our last look (that
    /// change is announced instead: the newer Mac copy wins), or when it is an echo of our own
    /// announce (the pasteboard already holds it). Returns true if written.
    @discardableResult
    public func hostContent(_ content: ClipboardContent, echo: Bool = false) -> Bool {
        let count = pasteboard.changeCount
        if isReady, count != lastSeen, count != ownWrite {
            log("Mac pasteboard changed during the host fetch: keeping the Mac copy")
            check("change during host fetch")
            return false
        }
        if echo {
            log("host list echoes our own announce: pasteboard left as it is")
            return false
        }
        let after = pasteboard.writeContent(content)
        ownWrite = after
        lastSeen = after
        log("host clipboard written to the Mac pasteboard (change \(after)): \(content.summary)")
        return true
    }
}
