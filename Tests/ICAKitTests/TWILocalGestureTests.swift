import CoreGraphics
import Testing
@testable import ICAKit

@Test func windowControlsFollowRemoteStyle() {
    // Calculator, live: 0x14ca0000 (visible, clipsiblings, caption, sysmenu, minimizebox; no sizing border).
    let calc = TWIWindowControls(style: 0x14ca_0000)
    #expect(!calc.resizable && !calc.zoomable && calc.minimizable)
    // Notepad-like WS_OVERLAPPEDWINDOW | WS_VISIBLE: sizing border and maximize box.
    let notepad = TWIWindowControls(style: 0x10cf_0000)
    #expect(notepad.resizable && notepad.zoomable)
    // Sizing border without maximize box, and the reverse.
    #expect(TWIWindowControls(style: TWIStyle.visible | TWIStyle.thickFrame).resizable)
    #expect(!TWIWindowControls(style: TWIStyle.visible | TWIStyle.thickFrame).zoomable)
    #expect(TWIWindowControls(style: TWIStyle.visible | TWIStyle.maximizeBox).zoomable)
    #expect(!TWIWindowControls(style: TWIStyle.visible | TWIStyle.maximizeBox).resizable)
}

@Test func moveGestureSendsOneRequestAndWaitsForHostAndFrame() {
    var g = TWILocalGesture()
    let start = TWIRect(x: 100, y: 100, width: 300, height: 200)
    g.begin(at: start)
    #expect(g.isFrozen && g.startRect == start && g.inputOverride == start)
    g.begin(at: TWIRect(x: 5, y: 5, width: 1, height: 1))          // second begin keeps the start
    #expect(g.startRect == start)
    #expect(!g.needsSnapshot(viewWidth: 300, viewHeight: 200))       // a move keeps the live crop
    let target = TWIRect(x: 250, y: 140, width: 300, height: 200)
    let first = g.commit(local: target), second = g.commit(local: target)
    #expect(first == target)
    #expect(second == nil)                                           // only one request per gesture
    #expect(g.inputOverride == target)
    let frame = [CGRect(x: 250, y: 140, width: 300, height: 200)]
    let early = g.framePresented(frame, current: target)             // host has not reported yet
    #expect(!early)
    g.hostReported()
    let elsewhere = g.framePresented([CGRect(x: 0, y: 0, width: 10, height: 10)], current: target)
    #expect(!elsewhere)
    let covering = g.framePresented(frame, current: target)
    #expect(covering)
    #expect(!g.isFrozen && g.inputOverride == nil)
}

@Test func gestureWithoutChangeGoesLiveAndTimeoutUnfreezes() {
    var g = TWILocalGesture()
    let r = TWIRect(x: 0, y: 0, width: 10, height: 10)
    g.begin(at: r)
    let none = g.commit(local: r)
    #expect(none == nil && !g.isFrozen)
    g.begin(at: r)
    _ = g.commit(local: TWIRect(x: 1, y: 0, width: 10, height: 10))
    g.timeout()
    #expect(!g.isFrozen)
}

@Test func resizeUsesTopLeftAnchoredSnapshot() {
    var g = TWILocalGesture()
    g.begin(at: TWIRect(x: 50, y: 60, width: 400, height: 300))
    #expect(g.needsSnapshot(viewWidth: 520, viewHeight: 380))
    // Larger view: unit rect beyond 1 (edge pixels extended into the new area), origin stays top-left.
    let grow = TWILocalGesture.snapshotContentsRect(viewSize: CGSize(width: 520, height: 380), imageSize: CGSize(width: 400, height: 300))
    #expect(grow.origin == .zero && abs(grow.width - 1.3) < 1e-9 && abs(grow.height - 380.0 / 300.0) < 1e-9)
    // Smaller view: the top-left part only (clipped), 1:1.
    let shrink = TWILocalGesture.snapshotContentsRect(viewSize: CGSize(width: 200, height: 150), imageSize: CGSize(width: 400, height: 300))
    #expect(shrink == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    let request = TWIRect(x: 50, y: 60, width: 520, height: 380)
    let sent = g.commit(local: request)
    #expect(sent == request)
}
