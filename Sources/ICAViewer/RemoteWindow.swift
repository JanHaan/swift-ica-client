import AppKit
import ICAKit
import QuartzCore

/// Shows a crop of the shared session framebuffer: a layer whose `contents` is the framebuffer's
/// IOSurface and whose `contentsRect` is the remote window rect (docs/50 §3, D8). Forwards input.
final class SessionView: NSView {
    weak var remote: RemoteWindow?
    private let surfaceLayer = CALayer()
    /// Dark overlay while the session is suspended (docs/20 §3.12.9); a sublayer, so the window and
    /// its number stay the same.
    private let dimLayer = CALayer()
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
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.isHidden = true
        dimLayer.zPosition = 1
        surfaceLayer.addSublayer(dimLayer)
    }

    /// Overlay alpha, or nil for none.
    func setDim(_ alpha: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        dimLayer.opacity = Float(alpha ?? 0)
        dimLayer.isHidden = alpha == nil
        CATransaction.commit()
    }

    /// Input is dropped while the session is suspended.
    private var blocked: Bool { remote?.controller?.inputBlocked ?? false }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Re-reads the content (IOSurface pixels changed, or the surface was replaced) and the crop.
    /// During a local move/resize the window is frozen (see `RemoteWindow`): it keeps showing the
    /// remote rect where the gesture started, or a snapshot of it once the size differs.
    func refresh() {
        guard let remote, let controller = remote.controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = nil
        if let image = remote.resizeSnapshot { surfaceLayer.contents = image }
        else { surfaceLayer.contents = controller.surface }
        updateContentsRect()
        CATransaction.commit()
    }

    /// Crop = content origin + the view's current size. With a snapshot: anchored top-left, 1:1; a
    /// rect beyond the image makes Core Animation extend the edge pixels, which fills newly exposed
    /// areas with the window's edge colour.
    func updateContentsRect() {
        guard let remote, let controller = remote.controller else { return }
        if let image = remote.resizeSnapshot {
            surfaceLayer.contentsRect = TWILocalGesture.snapshotContentsRect(
                viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
            return
        }
        let fb = controller.surfaceSize
        guard fb.width > 0, fb.height > 0 else { return }
        let r = remote.contentOrigin
        surfaceLayer.contentsRect = CGRect(x: CGFloat(r.left) / fb.width, y: CGFloat(r.top) / fb.height,
                                           width: bounds.width / fb.width, height: bounds.height / fb.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateContentsRect()
        dimLayer.frame = bounds
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
        let r = remote?.inputOrigin ?? .zero
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

    /// Cmd shortcuts the Edit menu would take; in a remote window they go to the server as Ctrl+key.
    /// Cmd-Q, Cmd-H, Cmd-, and the other menu shortcuts stay with macOS (Cmd-Tab never reaches the app).
    static let remoteShortcuts: Set<String> = ["z", "x", "c", "v", "a"]

    /// Key equivalents reach the key window's views before the main menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.isKeyWindow == true, event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(), Self.remoteShortcuts.contains(key) {
            if blocked { return true }
            vlog("key: Cmd-\(key.uppercased()) → remote Ctrl-\(key.uppercased())")
            remote?.controller?.keyboard.keyDown(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) { if !blocked { remote?.controller?.keyboard.keyDown(event) } }
    override func keyUp(with event: NSEvent) { if !blocked { remote?.controller?.keyboard.keyUp(event) } }
    override func flagsChanged(with event: NSEvent) { if !blocked { remote?.controller?.keyboard.flagsChanged(event) } }
}

/// Titled window for an `.appWindow`: a real NSWindow so switchers see an AXStandardWindow with
/// working close and minimize buttons. The title bar is transparent, full-size content and the
/// traffic lights are invisible (alpha 0, still in AX), so the remote window's own caption is all
/// the user sees. Every mouse event goes to the remote window (never to the invisible buttons or
/// the title-bar view); a press on the remote caption that turns into a drag moves the window
/// locally (docs/50 §3.1), and a press on the edge band of a resizable window resizes locally.
final class SeamlessWindow: NSWindow {
    weak var remote: RemoteWindow?
    /// Caption press waiting to become a drag (moved ≥ 3 pt) or a click (released in place).
    private var pendingCaption: NSEvent?
    /// Local caption drag in progress: pointer and frame origin (screen coordinates) at its start.
    /// Done by hand from the dragged events we receive (performDrag(with:) did not move the window when
    /// started from a dragged event with real, slow input).
    private var drag: (mouse: NSPoint, origin: NSPoint)?

    /// Keep the 1:1 position even where AppKit would push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        guard let remote, let view = contentView as? SessionView else { return super.sendEvent(event) }
        if remote.controller?.inputBlocked == true {
            // Suspended (docs/20 §3.12.3): mouse input is dropped; a click only brings the window
            // forward locally. Keys go on to the view, which drops them too.
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: activateForClick()
            case .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                 .mouseMoved, .scrollWheel: break
            default: super.sendEvent(event)
            }
            pendingCaption = nil
            if drag != nil, event.type == .leftMouseUp {
                drag = nil
                remote.endLocalGeometry()
            }
            return
        }
        let p = view.convert(event.locationInWindow, from: nil)   // flipped: remote window-relative pixels
        switch event.type {
        case .leftMouseDown:
            if remote.isResizeEdge(p), !hitsStandardButton(event) {
                vlog("press at \(Int(p.x)),\(Int(p.y)): resize edge (AppKit)")
                return super.sendEvent(event)
            }
            activateForClick()
            remote.controller?.noteActivity()
            if event.clickCount == 1, remote.isCaptionDrag(p) {
                vlog("press at \(Int(p.x)),\(Int(p.y)): caption")
                pendingCaption = event
                return
            }
            vlog("press at \(Int(p.x)),\(Int(p.y)): content (click \(event.clickCount))")
            view.mouseDown(with: event)
        case .leftMouseDragged:
            if let d = drag {
                let m = screenPoint(event)
                setFrameOrigin(NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y))
                return
            }
            if let down = pendingCaption {
                let dist = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
                if dist >= 3 {
                    pendingCaption = nil
                    // Local move: no TWI traffic during the drag, one move request at the end.
                    remote.beginLocalGeometry()
                    let downScreen = convertPoint(toScreen: down.locationInWindow)
                    let start = frame.origin
                    drag = (downScreen, start)
                    let m = screenPoint(event)
                    vlog("local drag started")
                    setFrameOrigin(NSPoint(x: start.x + m.x - downScreen.x, y: start.y + m.y - downScreen.y))
                }
                return
            }
            view.mouseDragged(with: event)
        case .leftMouseUp:
            if drag != nil {
                drag = nil
                vlog("local drag ended")
                remote.endLocalGeometry()
                return
            }
            if let down = pendingCaption {
                // A click on the caption (no drag): give it to the remote window.
                pendingCaption = nil
                view.mouseDown(with: down)
            }
            view.mouseUp(with: event)
        case .rightMouseDown:
            activateForClick()
            view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .rightMouseDragged: view.rightMouseDragged(with: event)
        case .otherMouseDown:
            activateForClick()
            view.otherMouseDown(with: event)
        case .otherMouseUp: view.otherMouseUp(with: event)
        case .otherMouseDragged: view.otherMouseDragged(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        case .scrollWheel: view.scrollWheel(with: event)
        default: super.sendEvent(event)
        }
    }

    /// Event location in screen coordinates (the window may have moved since the event was made, so
    /// use the event's own window-relative location against the current frame only for this event).
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window === self ? convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation
    }

    /// We bypass NSWindow's click handling, so do its activation part.
    private func activateForClick() {
        if !NSApp.isActive { NSApp.activate() }
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        if firstResponder !== contentView { makeFirstResponder(contentView) }
    }

    private func hitsStandardButton(_ event: NSEvent) -> Bool {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { type in
            guard let b = standardWindowButton(type), let sv = b.superview else { return false }
            return sv.convert(b.frame, to: nil).insetBy(dx: -4, dy: -4).contains(event.locationInWindow)
        }
    }

    /// Hide the traffic lights visually but keep them in the AX tree and enabled, so switchers see a
    /// working minimize button. `isHidden` removes them from AX, and alpha 0 makes AppKit disable them
    /// (isEnabled and AXEnabled false; performMiniaturize/performClose then do nothing). Alpha 0.01
    /// is invisible and keeps them enabled.
    func hideStandardButtons() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.alphaValue = 0.01
        }
    }
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

    // Local move/resize (docs/50 §3.1): the remote window stays where it is until the gesture ends, so
    // the window keeps showing the remote rect where it started (live), or a snapshot of it once the
    // size differs; exactly one TWI move/resize is sent at the end; the live crop returns when the host
    // reports the window at the new rect and a Thinwire frame covering it was presented (or after 500 ms).
    private var gesture = TWILocalGesture()
    private(set) var resizeSnapshot: CGImage?
    private var gestureActive = false
    private var unfreezeTimeout: DispatchWorkItem?
    /// Remote rect when the gesture started; non-nil while frozen.
    var frozenRect: TWIRect? { gesture.startRect }

    /// Remote origin the layer crops from.
    var contentOrigin: TWIRect { gesture.startRect ?? info.windowRect }
    /// Remote origin for input: the rect we asked for once committed (the host is moving it there).
    var inputOrigin: TWIRect { gesture.inputOverride ?? info.windowRect }

    init(info: TWIWindow, controller: SessionController) {
        self.info = info
        self.controller = controller
        let frame = controller.mapping.screenRect(info.windowRect)
        view = SessionView(frame: NSRect(origin: .zero, size: frame.size))
        if info.kind == .appWindow {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            if TWIWindowControls(style: info.style).resizable { style.insert(.resizable) }
            let w = SeamlessWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            w.title = displayName(info.title)             // not shown, but AX and switchers read it
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.hideStandardButtons()
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
        // NSWindow(contentRect:) positions relative to the main screen and constrains; set the frame
        // explicitly so windows on another screen start where the host has them (live: 170,463
        // instead of 2410,… on the second screen).
        window.setFrame(window.frameRect(forContentRect: frame), display: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = view
        window.delegate = self
        view.remote = self
        (window as? SeamlessWindow)?.remote = self
        applyControls()
        if info.isTopmost, info.kind == .appWindow { window.level = .floating }
        if info.kind == .appWindow {
            let f = window.frame, c = window.contentRect(forFrameRect: f)
            vlog("window \(String(info.id, radix: 16)) windowNumber \(window.windowNumber): frame \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)), content \(Int(c.width))x\(Int(c.height)), remote \(info.windowRect.width)x\(info.windowRect.height)")
        }
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
        if changes.contains(.title), isApp { window.title = displayName(new.title) }
        if changes.contains(.style) {
            if new.isMinimized, !old.isMinimized, isApp, !window.isMiniaturized {
                expectMiniaturize = true
                window.miniaturize(nil)
            } else if !new.isMinimized, old.isMinimized, window.isMiniaturized {
                expectDeminiaturize = true
                window.deminiaturize(nil)
            }
        }
        if changes.contains(.style) { applyControls() }
        if gesture.isFrozen {
            // A local gesture owns the frame. After the commit, the host's rect is the confirmation; if it
            // differs from what we asked (host adjusted it), follow the host.
            if changes.contains(.windowRect), case .awaiting = gesture.phase {
                gesture.hostReported()
                if new.windowRect != localRemoteRect, !new.isMinimized { applyRemoteFrame() }
            }
            return
        }
        // Minimised windows are parked by the host (ARW_HIDE); don't follow their rect.
        if changes.contains(.windowRect), !new.isMinimized { applyRemoteFrame() }
        view.refresh()
    }

    /// A Thinwire frame was presented (framebuffer rects). Ends the freeze once the host has confirmed
    /// the new rect and the frame covers it.
    func framePresented(_ rects: [CGRect]) {
        if gesture.framePresented(rects, current: info.windowRect) { unfreeze("host confirmed, frame presented") }
    }

    /// Local window controls follow the remote style (sizing border, maximize box).
    func applyControls() {
        guard isApp else { return }
        let c = TWIWindowControls(style: info.style)
        if c.resizable { window.styleMask.insert(.resizable) } else { window.styleMask.remove(.resizable) }
        window.standardWindowButton(.zoomButton)?.isEnabled = c.zoomable
    }

    func beginLocalGeometry() {
        gestureActive = true
        guard !gesture.isFrozen else { return }
        unfreezeTimeout?.cancel()
        gesture.begin(at: info.windowRect)
        verifyWork?.cancel()
        controller?.localGestureStarted(self)
    }

    func endLocalGeometry() {
        gestureActive = false
        moveDebounce?.cancel()
        commitGeometry()
    }

    /// Snapshot of the remote rect at gesture start (for resizes), taken on the session queue.
    private func requestSnapshot() {
        guard resizeSnapshot == nil, let start = frozenRect, let controller else { return }
        controller.snapshot(start) { [weak self] image in
            guard let self, self.frozenRect != nil, let image else { return }
            self.resizeSnapshot = image
            self.view.refresh()
        }
    }

    private func unfreeze(_ why: String) {
        unfreezeTimeout?.cancel()
        if gesture.isFrozen { gesture.timeout() }
        resizeSnapshot = nil
        if let latest = controller?.currentInfo(info.id) { info = latest }
        vlog("window \(String(info.id, radix: 16)): live again (\(why))")
        view.refresh()
        controller?.localGestureEnded(self)
        // If the host refused the change (e.g. fixed size), snap to what it reports.
        verifyWork?.cancel()
        let verify = DispatchWorkItem { [weak self] in
            guard let self, self.frozenRect == nil, let current = self.controller?.currentInfo(self.info.id) else { return }
            self.info = current
            self.applyRemoteFrame()
            self.view.refresh()
        }
        verifyWork = verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: verify)
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

    // MARK: Caption and border hit areas (docs/50 §3.1), remote window-relative pixels

    /// Remote resize border: local resize for resizable windows.
    func isResizeEdge(_ p: NSPoint) -> Bool {
        guard window.styleMask.contains(.resizable), !info.isMaximized else { return false }
        let m = controller?.systemMetrics
        let band = CGFloat(max(4, Int(m?.frameThickness.x ?? 4)))
        let b = view.bounds
        return p.x < band || p.y < band || p.x > b.width - band || p.y > b.height - band
    }

    /// Remote caption without its icon and caption buttons: dragging there moves the window locally.
    func isCaptionDrag(_ p: NSPoint) -> Bool {
        let hasCaption = info.style & TWIStyle.caption == TWIStyle.caption || info.flags & 0x0004 != 0
        guard hasCaption, info.flags & 0x0008 == 0, !info.isMaximized else { return false }
        let m = controller?.systemMetrics
        let thick = info.isResizable
        let fx = CGFloat(thick ? (m?.frameThickness.x ?? 4) : (m?.dialogFrameThickness.x ?? 3))
        let fy = CGFloat(thick ? (m?.frameThickness.y ?? 4) : (m?.dialogFrameThickness.y ?? 3))
        let captionHeight = CGFloat(max(Int(m?.captionHeight ?? 23), 23))
        // Visible caption buttons are wider than the classic metric on current Windows; be generous:
        // anything excluded here still works, the host then moves the window itself.
        let buttonWidth = CGFloat(max(Int(m?.captionButtonWidth ?? 46), 46))
        let boxes = info.style & (TWIStyle.minimizeBox | TWIStyle.maximizeBox) != 0
        let buttons = (boxes ? 3 : 1) * buttonWidth
        let icon = info.style & TWIStyle.sysMenu != 0 ? captionHeight : 0
        let top = fy, bottom = fy + captionHeight + 6
        return p.y >= top && p.y < bottom && p.x >= fx + icon && p.x < view.bounds.width - fx - buttons
    }

    /// The screen layout changed: re-place the window for the new mapping.
    func mappingChanged() {
        applyRemoteFrame()
        view.refresh()
    }

    /// Remote rect of the local content area.
    var localRemoteRect: TWIRect {
        controller?.mapping.remoteRect(window.contentRect(forFrameRect: window.frame)) ?? info.windowRect
    }

    /// Dark overlay while the session is suspended (nil = off).
    func setDimmed(_ alpha: CGFloat?) { view.setDim(alpha) }

    func closeFromRemote() {
        closingFromRemote = true
        moveDebounce?.cancel()
        verifyWork?.cancel()
        unfreezeTimeout?.cancel()
        window.orderOut(nil)
        window.close()
        window.delegate = nil
        view.remote = nil
    }

    // MARK: NSWindowDelegate (local → remote)

    func windowDidMove(_ notification: Notification) { localGeometryChanged() }
    func windowDidResize(_ notification: Notification) { localGeometryChanged() }
    func windowWillStartLiveResize(_ notification: Notification) {
        guard !applyingRemote else { return }
        beginLocalGeometry()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard frozenRect != nil else { return }
        endLocalGeometry()
    }

    private func localGeometryChanged() {
        guard !applyingRemote, !closingFromRemote, !window.isMiniaturized else { return }
        if frozenRect == nil { beginLocalGeometry(); gestureActive = false }
        if gesture.needsSnapshot(viewWidth: Int32(view.bounds.width.rounded()), viewHeight: Int32(view.bounds.height.rounded())) {
            requestSnapshot()
        }
        view.refresh()
        // A drag or live resize commits at its end; other local moves (switchers, window managers via AX,
        // programmatic) commit once they have settled.
        guard !gestureActive, !window.inLiveResize else { return }
        moveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitGeometry() }
        moveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Sends exactly one TWI move/resize for the gesture, then waits for the host.
    private func commitGeometry() {
        guard let controller, !closingFromRemote, case .local = gesture.phase else { return }
        var rect = localRemoteRect
        // Never send the host a position outside every screen: Windows treats such a window as off the
        // desktop and the host removes it (live, Outlook dragged past the session desktop).
        if !controller.mapping.isOnScreen(rect) {
            rect = controller.mapping.onMainScreen(rect)
            vlog("local move of \(String(info.id, radix: 16)) left every screen; clamped")
            let content = controller.mapping.screenRect(rect)
            applyingRemote = true
            window.setFrame(window.frameRect(forContentRect: content), display: true)
            applyingRemote = false
        }
        guard let request = gesture.commit(local: rect) else { return unfreeze("no change") }
        vlog("local move/resize of \(String(info.id, radix: 16)) → \(request.left),\(request.top) \(request.width)x\(request.height) (one request)")
        controller.moveResize(id: info.id, rect: request)
        unfreezeTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.unfreeze("timeout 500 ms") }
        unfreezeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeout)
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
