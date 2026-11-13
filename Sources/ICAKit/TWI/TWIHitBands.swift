import CoreGraphics
import Foundation

/// Where a press on a seamless window starts a local gesture (docs/50 §3.1, D20): the remote sizing border
/// (local resize) and the remote caption without its icon and caption buttons (local move). In
/// window-relative session pixels. Used by `RemoteWindow` for its own windows and, converted to points, sent
/// to helper apps (docs/99 §12 phase 2), so both decide by the same numbers.
public struct TWIHitBands: Equatable, Sendable {
    /// Width of the sizing border; nil = no local resize (no WS_THICKFRAME, or maximised).
    public var resizeEdge: CGFloat?
    /// Caption drag area: rows `top..<bottom`, columns `left..<(width - right)`; nil = no local move.
    public var caption: Caption?

    public struct Caption: Equatable, Sendable {
        public var top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat
        public init(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
            self.top = top; self.bottom = bottom; self.left = left; self.right = right
        }
    }

    public init(resizeEdge: CGFloat?, caption: Caption?) {
        self.resizeEdge = resizeEdge; self.caption = caption
    }

    /// `hostScale`: host metrics (SYSTEM_METRICS) are taken to be at the primary monitor's Windows scaling [I],
    /// so they scale by W(this monitor) / W(primary); `minimumScale`: our fallback minimums are 100 % values
    /// and scale by W / 100 (docs/80 §2.3, §4.2).
    public init(style: UInt32, flags: UInt16, metrics m: TWISystemMetrics?, hostScale: CGFloat, minimumScale: CGFloat) {
        let maximized = style & TWIStyle.maximize != 0
        let thick = style & TWIStyle.thickFrame != 0
        if TWIWindowControls(style: style).resizable, !maximized {
            resizeEdge = max(4 * minimumScale, m.map { CGFloat($0.frameThickness.x) * hostScale } ?? 0)
        } else {
            resizeEdge = nil
        }
        let hasCaption = style & TWIStyle.caption == TWIStyle.caption || flags & 0x0004 != 0
        guard hasCaption, flags & 0x0008 == 0, !maximized else {
            caption = nil
            return
        }
        func metric(_ v: Int16?, _ fallback: CGFloat) -> CGFloat { v.map { CGFloat($0) * hostScale } ?? fallback * minimumScale }
        let fx = metric(thick ? m?.frameThickness.x : m?.dialogFrameThickness.x, thick ? 4 : 3)
        let fy = metric(thick ? m?.frameThickness.y : m?.dialogFrameThickness.y, thick ? 4 : 3)
        let captionHeight = max(metric(m?.captionHeight, 23), 23 * minimumScale)
        // Visible caption buttons are wider than the classic metric on current Windows; be generous:
        // anything excluded here still works, the host then moves the window itself.
        let buttonWidth = max(metric(m?.captionButtonWidth, 46), 46 * minimumScale)
        let boxes = style & (TWIStyle.minimizeBox | TWIStyle.maximizeBox) != 0
        let buttons = (boxes ? 3 : 1) * buttonWidth
        let icon = style & TWIStyle.sysMenu != 0 ? captionHeight : 0
        caption = Caption(top: fy, bottom: fy + captionHeight + 6 * minimumScale, left: fx + icon, right: fx + buttons)
    }

    public func isResizeEdge(_ p: CGPoint, size: CGSize) -> Bool {
        guard let band = resizeEdge else { return false }
        return p.x < band || p.y < band || p.x > size.width - band || p.y > size.height - band
    }

    public func isCaption(_ p: CGPoint, size: CGSize) -> Bool {
        guard let c = caption else { return false }
        return p.y >= c.top && p.y < c.bottom && p.x >= c.left && p.x < size.width - c.right
    }
}
