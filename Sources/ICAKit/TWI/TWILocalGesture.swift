import CoreGraphics
import Foundation

/// Which window controls the local window may offer, from the remote style (docs/50 §2.7).
public struct TWIWindowControls: Equatable, Sendable {
    /// Local resize only for a sizing border (WS_THICKFRAME / WS_SIZEBOX 0x00040000).
    public var resizable: Bool
    /// Zoom/maximise only with WS_MAXIMIZEBOX (0x00010000).
    public var zoomable: Bool
    /// Minimise is always offered for app windows (switchers need a working minimize button).
    public var minimizable: Bool

    public init(style: UInt32) {
        resizable = style & TWIStyle.thickFrame != 0
        zoomable = style & TWIStyle.maximizeBox != 0
        minimizable = true
    }
}

/// State machine for a local move/resize of a seamless window (docs/50 §3.1): no TWI traffic during the
/// gesture, the window keeps showing the remote rect where it started (a snapshot once the size
/// differs), exactly one MOVE_RESIZE at the end, live content again once the host reported the window
/// at its new rect and a Thinwire frame covering it was presented, or after a timeout.
public struct TWILocalGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case live
        /// Gesture in progress, started at this remote rect.
        case local(start: TWIRect)
        /// One request sent; waiting for the host (hostSeen) and then a frame.
        case awaiting(start: TWIRect, requested: TWIRect, hostSeen: Bool)
    }

    public private(set) var phase: Phase = .live
    public init() {}

    public var isFrozen: Bool { phase != .live }
    public var startRect: TWIRect? {
        switch phase {
        case .live: return nil
        case .local(let s), .awaiting(let s, _, _): return s
        }
    }

    /// Starts a gesture (no-op if already frozen).
    public mutating func begin(at remote: TWIRect) {
        if case .live = phase { phase = .local(start: remote) }
    }

    /// True when the content should come from a snapshot of the start rect (the size differs).
    public func needsSnapshot(viewWidth: Int32, viewHeight: Int32) -> Bool {
        guard let s = startRect else { return false }
        return s.width != viewWidth || s.height != viewHeight
    }

    /// Gesture ended at `local`. Returns the one request to send, or nil if nothing changed (then live).
    public mutating func commit(local: TWIRect) -> TWIRect? {
        guard case .local(let start) = phase else { return nil }
        if local == start { phase = .live; return nil }
        phase = .awaiting(start: start, requested: local, hostSeen: false)
        return local
    }

    /// The host reported a window rect while awaiting (confirmation, possibly adjusted).
    public mutating func hostReported() {
        if case .awaiting(let s, let r, _) = phase { phase = .awaiting(start: s, requested: r, hostSeen: true) }
    }

    /// A frame was presented; returns true (and goes live) when it covers `current` after the host's report.
    public mutating func framePresented(_ rects: [CGRect], current: TWIRect) -> Bool {
        guard case .awaiting(_, _, true) = phase else { return false }
        let wr = CGRect(x: CGFloat(current.left), y: CGFloat(current.top), width: CGFloat(current.width), height: CGFloat(current.height))
        guard rects.contains(where: { $0.intersects(wr) }) else { return false }
        phase = .live
        return true
    }

    public mutating func timeout() { phase = .live }

    /// Remote origin for input: the requested rect once committed, else the start rect, else nil (live).
    public var inputOverride: TWIRect? {
        switch phase {
        case .live: return nil
        case .local(let s): return s
        case .awaiting(_, let r, _): return r
        }
    }

    /// contentsRect for a snapshot of `imageSize` shown 1:1 anchored top-left in a view of `viewSize`
    /// (unit coordinates; > 1 makes Core Animation extend the edge pixels into newly exposed areas).
    public static func snapshotContentsRect(viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: 0, y: 0, width: viewSize.width / imageSize.width, height: viewSize.height / imageSize.height)
    }
}
