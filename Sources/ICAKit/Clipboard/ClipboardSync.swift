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
    /// The pasteboard's change count when the host's latest format list arrived (`hostListed`): a Mac change the
    /// poll had not seen by then is older than the host's copy.
    public private(set) var countAtHostList: Int?

    public init(pasteboard: ClipboardPasteboard) { self.pasteboard = pasteboard }

    /// The channel is READY (also after a host re-init): announce what the Mac holds now.
    public func channelReady() {
        isReady = true
        lastSeen = nil
        check("channel ready")
    }

    public func channelClosed() { isReady = false }

    /// The host announced a new clipboard (its FORMAT_LIST arrived). Call before that list's data is written. The poll
    /// runs only every 500 ms and only while the viewer is frontmost, so a Mac copy it has not seen yet may well
    /// predate the remote copy; the change count now tells the two apart at write time.
    public func hostListed() { countAtHostList = pasteboard.changeCount }

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

    /// Host data for the pasteboard. Not written when the Mac changed after the host's list arrived (that change is
    /// announced instead: the newer Mac copy wins), or when it is an echo of our own announce (the pasteboard already
    /// holds it). A Mac change from before the host's list loses to the host copy. Returns true if written.
    @discardableResult
    public func hostContent(_ content: ClipboardContent, echo: Bool = false) -> Bool {
        hostWrite(summary: content.summary, echo: echo) { pasteboard.writeContent(content) }
    }

    /// Any host data for the pasteboard (e.g. the host's files as promised file URLs): the same rules as
    /// `hostContent`; `write` replaces the contents and returns the change count after it. Returns true if written.
    @discardableResult
    public func hostWrite(summary: String, echo: Bool = false, _ write: () -> Int) -> Bool {
        let count = pasteboard.changeCount
        if isReady, count != lastSeen, count != ownWrite {
            if let listed = countAtHostList, count == listed {
                // Unseen, but already there when the host's list arrived: the remote copy is the newer one.
                log("Mac pasteboard change \(count) predates the host's copy: the host copy wins")
            } else {
                log("Mac pasteboard changed during the host fetch: keeping the Mac copy")
                check("change during host fetch")
                return false
            }
        }
        if echo {
            log("host list echoes our own announce: pasteboard left as it is")
            return false
        }
        let after = write()
        ownWrite = after
        lastSeen = after
        log("host clipboard written to the Mac pasteboard (change \(after)): \(summary)")
        return true
    }
}
