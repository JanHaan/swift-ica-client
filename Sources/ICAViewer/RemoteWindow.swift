import AppKit
import ICAKit
import QuartzCore

/// Shows a crop of the shared session framebuffer: a layer whose `contents` is the framebuffer's
/// IOSurface and whose `contentsRect` is the remote window rect (docs/50 §3, D8). Forwards input.
final class SessionView: NSView {
    weak var remote: RemoteWindow?
    private let surfaceLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.magnificationFilter = .nearest
        surfaceLayer.minificationFilter = .nearest
        surfaceLayer.isOpaque = true
        surfaceLayer.backgroundColor = NSColor.black.cgColor
        layer = surfaceLayer          // layer-hosting: we own the layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Re-reads the IOSurface (its pixels changed, or the surface was replaced) and the crop.
    func refresh() {
        guard let remote, let controller = remote.controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = nil
        surfaceLayer.contents = controller.surface
        updateContentsRect()
        CATransaction.commit()
    }

    /// Crop = remote window origin + the view's current size (so a local live resize does not stretch).
    func updateContentsRect() {
        guard let remote, let controller = remote.controller else { return }
        let fb = controller.surfaceSize
        guard fb.width > 0, fb.height > 0 else { return }
        let r = remote.info.windowRect
        surfaceLayer.contentsRect = CGRect(x: CGFloat(r.left) / fb.width, y: CGFloat(r.top) / fb.height,
                                           width: bounds.width / fb.width, height: bounds.height / fb.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateContentsRect()
        CATransaction.commit()
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        if let cursor = remote?.controller?.cursor { addCursorRect(bounds, cursor: cursor) }
    }

    override func cursorUpdate(with event: NSEvent) {
        remote?.controller?.cursor.set()
    }

    // MARK: Mouse

    /// Absolute session position for an event.
    private func sessionPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let r = remote?.info.windowRect ?? .zero
        return (Int(r.left) + Int(p.x.rounded(.down)), Int(r.top) + Int(p.y.rounded(.down)))
    }

    private func mouse(_ event: NSEvent, _ state: WDBuild.MouseState) {
        let (x, y) = sessionPoint(event)
        remote?.controller?.mouse(x: x, y: y, state: state)
    }

    override func mouseMoved(with event: NSEvent) { mouse(event, .moved) }
    override func mouseDragged(with event: NSEvent) { mouse(event, .moved) }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, .moved) }
    override func otherMouseDragged(with event: NSEvent) { mouse(event, .moved) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        mouse(event, .leftDown)
    }
    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseUp(with: event) }
        mouse(event, .leftUp)
    }
    override func rightMouseDown(with event: NSEvent) { mouse(event, .rightDown) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, .rightUp) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { mouse(event, .middleDown) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { mouse(event, .middleUp) } }

    override func scrollWheel(with event: NSEvent) {
        // Windows: 120 per notch, positive = away from the user. macOS deltaY already follows the
        // user's scroll direction setting, so the sign carries over.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 4 : event.scrollingDeltaY * 120
        scrollAccumulator += delta
        guard abs(scrollAccumulator) >= 1 else { return }
        let amount = Int16(clamping: Int(scrollAccumulator))
        scrollAccumulator -= CGFloat(amount)
        let (x, y) = sessionPoint(event)
        remote?.controller?.wheel(x: x, y: y, delta: amount)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { remote?.controller?.keyboard.keyDown(event) }
    override func keyUp(with event: NSEvent) { remote?.controller?.keyboard.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { remote?.controller?.keyboard.flagsChanged(event) }
}

/// Titled window for an `.appWindow`: a real NSWindow so switchers see an AXStandardWindow.
final class SeamlessWindow: NSWindow {
    /// Keep the 1:1 position even where AppKit would push the title bar below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless, non-activating panel for menus, tooltips and tool windows.
final class SeamlessPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One remote window and its local NSWindow/NSPanel, kept in sync in both directions.
final class RemoteWindow: NSObject, NSWindowDelegate {
    private(set) var info: TWIWindow
    weak var controller: SessionController?
    let window: NSWindow
    let view: SessionView
    var isApp: Bool { info.kind == .appWindow }

    /// Set while we apply a host change, so the delegate callbacks don't echo it back.
    private var applyingRemote = false
    private var closingFromRemote = false
    private var expectMiniaturize = false
    private var expectDeminiaturize = false
    private var moveDebounce: DispatchWorkItem?
    private var verifyWork: DispatchWorkItem?

    init(info: TWIWindow, controller: SessionController) {
        self.info = info
        self.controller = controller
        let frame = controller.mapping.screenRect(info.windowRect)
        view = SessionView(frame: NSRect(origin: .zero, size: frame.size))
        if info.kind == .appWindow {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if info.isResizable { style.insert(.resizable) }
            let w = SeamlessWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            w.title = info.title
            w.tabbingMode = .disallowed
            w.collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
            window = w
        } else {
            let p = SeamlessPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = info.isMenu ? .popUpMenu : .floating
            p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            window = p
        }
        super.init()
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = view
        window.delegate = self
        view.remote = self
        if info.isTopmost, info.kind == .appWindow { window.level = .floating }
        view.refresh()
    }

    func show(activate: Bool) {
        applyingRemote = true
        defer { applyingRemote = false }
        if info.isMinimized, isApp {
            window.orderFront(nil)
            expectMiniaturize = true
            window.miniaturize(nil)
        } else if activate, isApp {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// Host changed this window.
    func update(_ new: TWIWindow, _ changes: TWIWindowChange) {
        let old = info
        info = new
        applyingRemote = true
        defer { applyingRemote = false }
        if changes.contains(.title), isApp { window.title = new.title }
        if changes.contains(.style) {
            if new.isMinimized, !old.isMinimized, isApp, !window.isMiniaturized {
                expectMiniaturize = true
                window.miniaturize(nil)
            } else if !new.isMinimized, old.isMinimized, window.isMiniaturized {
                expectDeminiaturize = true
                window.deminiaturize(nil)
            }
        }
        // Minimised windows are parked by the host (ARW_HIDE); don't follow their rect.
        if changes.contains(.windowRect), !new.isMinimized { applyRemoteFrame() }
        view.refresh()
    }

    private func applyRemoteFrame() {
        guard let controller else { return }
        let content = controller.mapping.screenRect(info.windowRect)
        let frame = window.frameRect(forContentRect: content)
        if window.frame != frame {
            let wasApplying = applyingRemote
            applyingRemote = true
            window.setFrame(frame, display: true)
            applyingRemote = wasApplying
        }
    }

    /// Remote rect of the local content area.
    var localRemoteRect: TWIRect {
        controller?.mapping.remoteRect(window.contentRect(forFrameRect: window.frame)) ?? info.windowRect
    }

    func closeFromRemote() {
        closingFromRemote = true
        moveDebounce?.cancel()
        verifyWork?.cancel()
        window.orderOut(nil)
        window.close()
        window.delegate = nil
        view.remote = nil
    }

    // MARK: NSWindowDelegate (local → remote)

    func windowDidMove(_ notification: Notification) { localGeometryChanged() }
    func windowDidResize(_ notification: Notification) {
        if !window.inLiveResize { localGeometryChanged() }
    }
    func windowDidEndLiveResize(_ notification: Notification) { localGeometryChanged() }

    private func localGeometryChanged() {
        guard !applyingRemote, !closingFromRemote, !window.isMiniaturized else { return }
        // Moves arrive continuously while dragging; send the final rect.
        moveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendGeometry() }
        moveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func sendGeometry() {
        guard let controller, !closingFromRemote else { return }
        let rect = localRemoteRect
        guard rect != info.windowRect else { return }
        vlog("local move/resize of \(String(info.id, radix: 16)) → \(rect.left),\(rect.top) \(rect.width)x\(rect.height)")
        // Show the new spot immediately; the host confirms with a CHANGE_WINDOW rect.
        info.windowRect = TWIRect(x: rect.left, y: rect.top, width: info.windowRect.width, height: info.windowRect.height)
        view.refresh()
        controller.moveResize(id: info.id, rect: rect)
        // If the host refuses (e.g. fixed-size window), snap back to what it reports.
        verifyWork?.cancel()
        let verify = DispatchWorkItem { [weak self] in
            guard let self, let current = self.controller?.currentInfo(self.info.id) else { return }
            self.info = current
            self.applyRemoteFrame()
            self.view.refresh()
        }
        verifyWork = verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: verify)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller?.windowBecameKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        controller?.keyboard.releaseAll()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingFromRemote { return true }
        controller?.requestClose(id: info.id)
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if expectMiniaturize { expectMiniaturize = false; return }
        controller?.minimize(id: info.id)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if expectDeminiaturize { expectDeminiaturize = false; return }
        controller?.restore(id: info.id)
    }
}
