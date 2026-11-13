import AppKit
import ICAKit
import QuartzCore

/// Shows a crop of the shared session framebuffer: a layer whose `contents` is the framebuffer's
/// IOSurface and whose `contentsRect` is the remote window rect (docs/50 §3, D8). Forwards input.
/// The view is in points; the crop and all input are session pixels, k = `RemoteWindow.displayScale`
/// pixels per point (docs/80 §2.3, §4.2).
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
        // Shown by a helper app (docs/99 §12): this window stays hidden; the helper gets the new crop.
        if let presenter = remote.presenter { return presenter.update(remote) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = nil
        if let image = remote.resizeSnapshot { surfaceLayer.contents = image }
        else { surfaceLayer.contents = controller.surface }
        updateFilters()
        updateContentsRect()
        CATransaction.commit()
    }

    /// One session pixel per device pixel when k equals the screen's backing scale: nearest filtering,
    /// pixel-exact. A 2x window on a 1x screen (manual 2x, or a window straddling onto it) shows
    /// 2 px per device pixel: linear minification keeps thin strokes (docs/80 §4.2).
    private func updateFilters() {
        let backing = window?.backingScaleFactor ?? 1
        let k = remote?.displayScale ?? 1
        surfaceLayer.contentsScale = backing
        surfaceLayer.magnificationFilter = .nearest
        surfaceLayer.minificationFilter = k > backing ? .linear : .nearest
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// Crop = content origin + the view's current size. With a snapshot: anchored top-left, 1:1; a
    /// rect beyond the image makes Core Animation extend the edge pixels, which fills newly exposed
    /// areas with the window's edge colour.
    func updateContentsRect() {
        guard let remote, let controller = remote.controller else { return }
        let k = remote.displayScale
        if let image = remote.resizeSnapshot {
            surfaceLayer.contentsRect = TWILocalGesture.snapshotContentsRect(
                viewSize: CGSize(width: bounds.width * k, height: bounds.height * k), imageSize: CGSize(width: image.width, height: image.height))
            return
        }
        let fb = controller.surfaceSize
        guard fb.width > 0, fb.height > 0 else { return }
        let r = remote.contentPixelRect
        surfaceLayer.contentsRect = CGRect(x: r.minX / fb.width, y: r.minY / fb.height, width: r.width / fb.width, height: r.height / fb.height)
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

    /// Absolute session position for an event: origin + floor(p · k) on the window and its screen
    /// (docs/80 §2.3); a drag carried onto another screen maps through that screen.
    private func sessionPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        guard let remote, let window, let layout = remote.controller?.layout else {
            let s = ScalingLayout.sessionPoint(viewPoint: p, origin: remote?.inputOrigin ?? .zero, scale: remote?.displayScale ?? 1)
            return (s.x, s.y)
        }
        let s = layout.eventPoint(viewPoint: p, origin: remote.inputOrigin, scale: remote.displayScale,
                                  screenPoint: window.convertPoint(toScreen: event.locationInWindow),
                                  windowFrame: window.frame, windowMonitor: remote.monitorIndex)
        return (s.x, s.y)
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
        let p = view.convert(event.locationInWindow, from: nil)   // flipped: remote window-relative points
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

/// Shows a RemoteWindow somewhere else than in its own NSWindow: in a helper app (docs/99 §12 phases 1–2,
/// `HelperManager`). The RemoteWindow keeps all its logic (geometry, scaling maps, local gestures, TWI
/// requests) on a window that is never ordered in; the presenter mirrors its state.
protocol RemotePresenter: AnyObject {
    /// First show (`show(activate:)`).
    func present(_ w: RemoteWindow, activate: Bool)
    /// Geometry, crop, title, minimised or dim state may have changed.
    func update(_ w: RemoteWindow)
    /// The host removed the window.
    func dismiss(_ w: RemoteWindow)
    /// A local move/resize is settled (confirmed, refused or timed out): the window shows live content again.
    func gestureDone(_ w: RemoteWindow)
}

/// One remote window and its local NSWindow/NSPanel, kept in sync in both directions.
final class RemoteWindow: NSObject, NSWindowDelegate {
    private(set) var info: TWIWindow
    weak var controller: SessionController?
    let window: NSWindow
    let view: SessionView
    var isApp: Bool { info.kind == .appWindow }
    /// Set when a helper app shows this window (ICA_HELPER_APPS=1); nil = shown here, as always.
    weak var presenter: RemotePresenter?

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
    /// Session pixels per point for this window: the k of the monitor its remote rect was placed by.
    private(set) var displayScale: CGFloat = 1
    /// That monitor (index into the controller's layout).
    private(set) var monitorIndex = 0
    /// The local content rect we last placed from a remote rect, and that rect: an unchanged local
    /// frame maps back to exactly this rect (no rounding).
    private var applied: (content: CGRect, remote: TWIRect)?

    /// Framebuffer pixels the layer shows: the crop origin plus the view size in pixels.
    var contentPixelRect: CGRect {
        let r = contentOrigin
        return CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: view.bounds.width * displayScale, height: view.bounds.height * displayScale)
    }
    /// Remote origin for input: the rect we asked for once committed (the host is moving it there).
    var inputOrigin: TWIRect { gesture.inputOverride ?? info.windowRect }

    init(info: TWIWindow, controller: SessionController) {
        self.info = info
        self.controller = controller
        monitorIndex = controller.placementMonitor(for: info)
        displayScale = CGFloat(controller.layout.monitors[monitorIndex].scale)
        let frame = controller.layout.pointRect(info.windowRect, monitor: monitorIndex)
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
        applied = (window.contentRect(forFrameRect: window.frame), info.windowRect)
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
            vlog("window \(String(info.id, radix: 16)) windowNumber \(window.windowNumber): frame \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)), content \(Int(c.width))x\(Int(c.height)), remote \(info.windowRect.width)x\(info.windowRect.height) (monitor \(monitorIndex), \(Int(displayScale))x)")
        }
        view.refresh()
    }

    func show(activate: Bool) {
        if let presenter { return presenter.present(self, activate: activate) }
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
        defer { presenter?.update(self) }
        if changes.contains(.title), isApp { window.title = displayName(new.title) }
        if changes.contains(.style), presenter == nil {
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
        presenter?.gestureDone(self)
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

    /// Places the window at the host's rect, through the monitor holding most of it.
    private func applyRemoteFrame() {
        guard let controller else { return }
        let layout = controller.layout
        monitorIndex = controller.placementMonitor(for: info)
        let k = CGFloat(layout.monitors[monitorIndex].scale)
        if k != displayScale {
            vlog("window \(String(info.id, radix: 16)): now on monitor \(monitorIndex) at \(Int(k))x")
            displayScale = k
        }
        let content = layout.pointRect(info.windowRect, monitor: monitorIndex)
        let frame = window.frameRect(forContentRect: content)
        if window.frame != frame {
            let wasApplying = applyingRemote
            applyingRemote = true
            window.setFrame(frame, display: true)
            applyingRemote = wasApplying
        }
        applied = (window.contentRect(forFrameRect: window.frame), info.windowRect)
    }

    /// Host metrics (SYSTEM_METRICS) are taken to be at the primary monitor's Windows scaling [I], so
    /// they scale by W(this monitor) / W(primary); our fallback minimums are 100 % values and scale by
    /// W / 100 (docs/80 §2.3, §4.2).
    private var metricScale: (host: CGFloat, minimum: CGFloat) {
        guard let layout = controller?.layout, monitorIndex < layout.monitors.count else { return (1, 1) }
        let w = CGFloat(layout.monitors[monitorIndex].windowsPercent), primary = CGFloat(layout.monitors[0].windowsPercent)
        return (w / max(primary, 1), w / 100)
    }

    // MARK: Caption and border hit areas (docs/50 §3.1), compared in session pixels

    /// The caption and sizing-border bands of this window (`TWIHitBands`, window-relative session pixels);
    /// a helper gets them in points (docs/99 §12 phase 2).
    var hitBands: TWIHitBands {
        let s = metricScale
        var bands = TWIHitBands(style: info.style, flags: info.flags, metrics: controller?.systemMetrics, hostScale: s.host, minimumScale: s.minimum)
        if !window.styleMask.contains(.resizable) { bands.resizeEdge = nil }
        return bands
    }

    /// View point (points) → window-relative session pixels, and the view size in pixels.
    private func pixels(_ p: NSPoint) -> (p: NSPoint, size: CGSize) {
        let k = displayScale
        return (NSPoint(x: p.x * k, y: p.y * k), CGSize(width: view.bounds.width * k, height: view.bounds.height * k))
    }

    /// Remote resize border: local resize for resizable windows.
    func isResizeEdge(_ point: NSPoint) -> Bool {
        let (p, size) = pixels(point)
        return hitBands.isResizeEdge(p, size: size)
    }

    /// Remote caption without its icon and caption buttons: dragging there moves the window locally.
    func isCaptionDrag(_ point: NSPoint) -> Bool {
        let (p, size) = pixels(point)
        return hitBands.isCaption(p, size: size)
    }

    /// The screen layout changed: re-place the window for the new mapping.
    func mappingChanged() {
        applyRemoteFrame()
        view.refresh()
    }

    /// Remote rect of the local content area, through the screen holding most of it. A move (same size
    /// in points) keeps the pixel size: a window that changes screens to one with another scale is
    /// rescaled by Windows itself (DPI change), and we follow the rect the host reports.
    var localRemoteRect: TWIRect {
        guard let layout = controller?.layout else { return info.windowRect }
        let c = window.contentRect(forFrameRect: window.frame)
        guard let applied else { return layout.sessionRect(c) }
        if c == applied.content { return applied.remote }
        let r = layout.sessionRect(c)
        if abs(c.width - applied.content.width) < 0.25, abs(c.height - applied.content.height) < 0.25 {
            return TWIRect(x: r.left, y: r.top, width: applied.remote.width, height: applied.remote.height)
        }
        return r
    }

    /// Dark overlay while the session is suspended (nil = off).
    func setDimmed(_ alpha: CGFloat?) {
        view.setDim(alpha)
        presenter?.update(self)
    }

    func closeFromRemote() {
        presenter?.dismiss(self)
        presenter = nil
        closingFromRemote = true
        moveDebounce?.cancel()
        verifyWork?.cancel()
        unfreezeTimeout?.cancel()
        window.orderOut(nil)
        window.close()
        window.delegate = nil
        view.remote = nil
    }

    // MARK: Helper apps (docs/99 §12)

    /// The helper could not take the window (no check-in, crash): show it here after all.
    func adoptLocally(activate: Bool) {
        guard presenter != nil, !closingFromRemote else { return }
        presenter = nil
        window.isExcludedFromWindowsMenu = false
        show(activate: activate)
        view.refresh()
    }

    /// The helper moved or resized its window (AX, Mission Control): mirror the frame here and commit it
    /// like any other local move once it settles (D20).
    func helperMoved(content: CGRect) {
        guard presenter != nil, !closingFromRemote, !info.isMinimized else { return }
        let frame = window.frameRect(forContentRect: content)
        guard window.frame != frame else { return }
        applyingRemote = true
        window.setFrame(frame, display: false)
        applyingRemote = false
        localGeometryChanged()
    }

    /// A caption drag or edge resize the helper ran locally ended at `content` (docs/99 §12 phase 2, D20):
    /// the same commit as for a local gesture here — frozen at the remote rect where it started, exactly one
    /// TWI move/resize, live again once the host confirmed and a covering frame was presented (or 500 ms).
    /// The helper is told by `gestureDone` (also when nothing changed).
    func helperGestureEnded(content: CGRect) {
        guard presenter != nil, !closingFromRemote, !info.isMinimized else { presenter?.gestureDone(self); return }
        beginLocalGeometry()
        let frame = window.frameRect(forContentRect: content)
        if window.frame != frame {
            applyingRemote = true
            window.setFrame(frame, display: false)
            applyingRemote = false
        }
        endLocalGeometry()
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
        let local = localRemoteRect
        if gesture.needsSnapshot(viewWidth: local.width, viewHeight: local.height) {
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
        if !controller.layout.isOnScreen(rect) {
            rect = controller.layout.onMainScreen(rect)
            vlog("local move of \(String(info.id, radix: 16)) left every screen; clamped")
            let content = controller.layout.pointRect(rect)
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
        DockIcon.shared.scheduleRefresh()
    }

    func windowDidResignKey(_ notification: Notification) {
        controller?.keyboard.releaseAll()
        DockIcon.shared.scheduleRefresh()
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
