import CoreGraphics
import Testing
@testable import ICAKit

/// The caption and sizing-border bands (docs/50 §3.1, D20) that RemoteWindow and the helper apps use.
@Suite struct TWIHitBandsTests {
    /// WS_OVERLAPPEDWINDOW | WS_VISIBLE (Notepad-like).
    let notepad: UInt32 = 0x10cf_0000
    /// Calculator, live: caption, sysmenu, minimize box; no sizing border.
    let calc: UInt32 = 0x14ca_0000

    @Test func fallbacksWithoutMetrics() {
        let b = TWIHitBands(style: notepad, flags: 0, metrics: nil, hostScale: 1, minimumScale: 1)
        #expect(b.resizeEdge == 4)
        #expect(b.caption == .init(top: 4, bottom: 33, left: 27, right: 142))
        let c = TWIHitBands(style: calc, flags: 0, metrics: nil, hostScale: 1, minimumScale: 1)
        #expect(c.resizeEdge == nil)
        #expect(c.caption == .init(top: 3, bottom: 32, left: 26, right: 141))
        // 200 %: the 100 % minimums scale.
        let k2 = TWIHitBands(style: notepad, flags: 0, metrics: nil, hostScale: 2, minimumScale: 2)
        #expect(k2.resizeEdge == 8 && k2.caption == .init(top: 8, bottom: 66, left: 54, right: 284))
    }

    @Test func hostMetricsScaleByMonitor() {
        var values = [Int16](repeating: 0, count: 22)
        values[0] = 8; values[1] = 8; values[2] = 6; values[3] = 6
        values[16] = 30; values[18] = 50
        let m = TWISystemMetrics(firstWord: 0, metrics: values, strings: [])
        let b = TWIHitBands(style: notepad, flags: 0, metrics: m, hostScale: 1, minimumScale: 1)
        #expect(b.resizeEdge == 8)
        #expect(b.caption == .init(top: 8, bottom: 44, left: 38, right: 158))
        let half = TWIHitBands(style: notepad, flags: 0, metrics: m, hostScale: 0.5, minimumScale: 1)
        #expect(half.resizeEdge == 4)                    // never below the 4 px minimum
        #expect(half.caption == .init(top: 4, bottom: 33, left: 27, right: 142))
    }

    @Test func noBandsWhenMaximisedOrSuppressed() {
        let maximized = TWIHitBands(style: notepad | TWIStyle.maximize, flags: 0, metrics: nil, hostScale: 1, minimumScale: 1)
        #expect(maximized.resizeEdge == nil && maximized.caption == nil)
        let suppressed = TWIHitBands(style: notepad, flags: 0x0008, metrics: nil, hostScale: 1, minimumScale: 1)
        #expect(suppressed.caption == nil && suppressed.resizeEdge == 4)
        // A custom caption (flag 0x0004) without WS_CAPTION still drags.
        let custom = TWIHitBands(style: TWIStyle.visible | TWIStyle.popup, flags: 0x0004, metrics: nil, hostScale: 1, minimumScale: 1)
        #expect(custom.caption == .init(top: 3, bottom: 32, left: 3, right: 49))
        let none = TWIHitBands(style: TWIStyle.visible | TWIStyle.popup, flags: 0, metrics: nil, hostScale: 1, minimumScale: 1)
        #expect(none.caption == nil && none.resizeEdge == nil)
    }

    @Test func pointTests() {
        let b = TWIHitBands(style: notepad, flags: 0, metrics: nil, hostScale: 1, minimumScale: 1)
        let size = CGSize(width: 800, height: 600)
        #expect(b.isResizeEdge(CGPoint(x: 3, y: 300), size: size) && b.isResizeEdge(CGPoint(x: 400, y: 597), size: size))
        #expect(!b.isResizeEdge(CGPoint(x: 400, y: 300), size: size))
        #expect(b.isCaption(CGPoint(x: 27, y: 4), size: size) && b.isCaption(CGPoint(x: 657, y: 32), size: size))
        #expect(!b.isCaption(CGPoint(x: 658, y: 10), size: size) && !b.isCaption(CGPoint(x: 26, y: 10), size: size))
        #expect(!b.isCaption(CGPoint(x: 300, y: 33), size: size))
    }
}
