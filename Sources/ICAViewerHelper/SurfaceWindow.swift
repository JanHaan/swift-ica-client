import AppHostKit
import AppKit
import QuartzCore

/// A window of this helper whose content is a crop of the host's IOSurface: an app window (`SurfaceWindow`)
/// or, phase 2, a popup, menu or tooltip of the app (`SurfacePanel`).
protocol SurfaceShowing: NSWindow {
    var spec: HelperWindowSpec { get }
    var surfaceView: SurfaceView { get }
    func apply(_ new: HelperWindowSpec, surface: IOSurfaceRef?)
}

/// One remote window, owned by this helper process, whose content is a crop of the host's IOSurface,
/// like `SessionView` in ICAViewer. Two looks:
/// - spike (`spec.seamless` nil): a standard titled window the helper places itself;
/// - seamless (ICAViewer, docs/99 §12): as ICAViewer's `SeamlessWindow` (D14): hidden title bar, invisible
///   but enabled traffic lights (still AXStandardWindow with close and minimize), placed where the host
///   says, every mouse event to the remote window, except a caption drag or an edge resize, which run here
///   (phase 2, D20): nothing goes to the host during the gesture, one `gestureEnded` at its end.
/// Input goes to the host as view and screen points; the host maps them to session pixels.
final class SurfaceWindow: NSWindow, SurfaceShowing {
    private(set) var spec: HelperWindowSpec
    let surfaceView: SurfaceView
    private let send: (HelperMessage) -> Void
    /// Set while a host change is applied, so the delegate does not echo it back.
    private(set) var applyingHost = false
    var expectMiniaturize = false
    var expectDeminiaturize = false
    /// The user restored the window here; until the host reports it restored (or 2 s pass), a spec that
    /// still says minimised is the host's old state, not a new minimise (no restore bounce).
    var localRestoreSince: Date?
    /// A local gesture started (true) or its content is live again (false): the helper hides its popups
    /// meanwhile, as the main process does (they would stay behind).
    var onGesture: ((SurfaceWindow, Bool) -> Void)?

    // Local move/resize (D20): the content stays frozen at the crop where the gesture started (a snapshot
    // once the size differs) until the host has confirmed the one move/resize (`gestureDone`).
    /// Caption press waiting to become a drag (moved ≥ 3 pt) or a click (released in place).
    private var pendingCaption: NSEvent?
    /// Caption drag in progress: pointer and frame origin (screen coordinates) at its start.
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    /// A drag or live resize runs: the host hears nothing until it ends.
    private(set) var inGesture = false
    private var gestureFallback: DispatchWorkItem?
    /// The host's answer to `gestureEnded` normally comes after its 500 ms timeout at the latest.
    static let gestureDoneTimeout: TimeInterval = 2

    var isSeamless: Bool { spec.seamless == true }

    /// `defaultScale`: session pixels per point when the spec has none (spike).
    init(spec: HelperWindowSpec, defaultScale: CGFloat, send: @escaping (HelperMessage) -> Void) {
        self.spec = spec
        self.send = send
        let scale = spec.scale.map { CGFloat($0) } ?? defaultScale
        let content = spec.frame?.cgRect
            ?? NSRect(x: 0, y: 0, width: CGFloat(spec.rect.width) / scale, height: CGFloat(spec.rect.height) / scale)
        surfaceView = SurfaceView(frame: NSRect(origin: .zero, size: content.size), scale: scale, send: send)
        var style: NSWindow.StyleMask = spec.seamless == true
            ? [.titled, .closable, .miniaturizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable]
        if spec.seamless == true, spec.resizable == true { style.insert(.resizable) }
        super.init(contentRect: content, styleMask: style, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        acceptsMouseMovedEvents = true
        title = spec.title
        contentView = surfaceView
        initialFirstResponder = surfaceView
        makeFirstResponder(surfaceView)     // keys reach the remote window after Cmd-Tab too, not only after a click
        surfaceView.windowId = spec.id
        if isSeamless {
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            titlebarSeparatorStyle = .none
            collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
            // Invisible but enabled (alpha 0 would disable them, D14): switchers need a working minimize.
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(type)?.alphaValue = 0.01
            }
            // Zoom is the Window menu's (TWI maximise), never AppKit's local zoom.
            standardWindowButton(.zoomButton)?.isEnabled = false
            if spec.topmost == true { level = .floating }
            placeFromHost(content)
        } else if let visible = NSScreen.main?.visibleFrame {
            // Spike: the "session" starts at the visible frame's top-left.
            setFrameTopLeftPoint(NSPoint(x: visible.minX + CGFloat(spec.rect.x) / scale, y: visible.maxY - CGFloat(spec.rect.y) / scale))
        }
        surfaceView.dim(spec.dim)
    }

    /// The host's 1:1 position, even where AppKit would push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        isSeamless ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A new spec from the host: geometry, crop, title, level, controls, minimised and dim state.
    func apply(_ new: HelperWindowSpec, surface: IOSurfaceRef?) {
        let old = spec
        spec = new
        if new.title != old.title { title = new.title }
        if let scale = new.scale { surfaceView.scale = CGFloat(scale) }
        if isSeamless {
            if new.topmost != old.topmost { level = new.topmost == true ? .floating : .normal }
            if new.resizable != old.resizable {
                if new.resizable == true { styleMask.insert(.resizable) } else { styleMask.remove(.resizable) }
                standardWindowButton(.zoomButton)?.isEnabled = false
            }
            // A gesture runs or awaits the host's answer: the local frame wins until `gestureDone`, which
            // applies the host's (confirmed or adjusted) frame; no snap back to the pre-drag frame meanwhile.
            if !inGesture, !isFrozen, let frame = new.frame?.cgRect, frame != contentRect(forFrameRect: self.frame), !isMiniaturized {
                placeFromHost(frame)
            }
            if new.minimized != true { localRestoreSince = nil }
            let restorePending = localRestoreSince.map { Date().timeIntervalSince($0) < 2 } ?? false
            if new.minimized == true, !isMiniaturized, !restorePending {
                expectMiniaturize = true
                miniaturize(nil)
            } else if new.minimized != true, isMiniaturized, old.minimized == true {
                expectDeminiaturize = true
                deminiaturize(nil)
            }
        }
        if new.dim != old.dim { surfaceView.dim(new.dim) }
        surfaceView.refresh(surface, crop: new.rect)
    }

    private func placeFromHost(_ content: CGRect) {
        applyingHost = true
        setFrame(frameRect(forContentRect: content), display: true)
        applyingHost = false
    }

    // MARK: Mouse

    /// Seamless: every mouse event goes to the remote window (never to the invisible buttons or the
    /// title-bar view), as `SeamlessWindow.sendEvent`; a caption press that becomes a drag moves the window
    /// here, a press on the sizing border of a resizable window resizes it here (AppKit live resize).
    override func sendEvent(_ event: NSEvent) {
        guard isSeamless else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDown:
            let p = surfaceView.convert(event.locationInWindow, from: nil)     // flipped: remote window-relative points
            let bands = localGestures ? spec.bands : nil
            if let bands, styleMask.contains(.resizable), bands.isResizeEdge(p, size: surfaceView.bounds.size), !hitsStandardButton(event) {
                return super.sendEvent(event)       // windowWillStartLiveResize → beginGesture
            }
            activateForClick()
            if event.clickCount == 1, let bands, bands.isCaption(p, size: surfaceView.bounds.size) {
                pendingCaption = event
                return
            }
            surfaceView.mouseDown(with: event)
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
                    beginGesture()
                    let downScreen = convertPoint(toScreen: down.locationInWindow)
                    let start = frame.origin
                    drag = (downScreen, start)
                    let m = screenPoint(event)
                    setFrameOrigin(NSPoint(x: start.x + m.x - downScreen.x, y: start.y + m.y - downScreen.y))
                }
                return
            }
            surfaceView.mouseDragged(with: event)
        case .leftMouseUp:
            if drag != nil {
                drag = nil
                endGesture()
                return
            }
            if let down = pendingCaption {
                // A click on the caption (no drag): give it to the remote window.
                pendingCaption = nil
                surfaceView.mouseDown(with: down)
            }
            surfaceView.mouseUp(with: event)
        case .rightMouseDown:
            activateForClick()
            surfaceView.rightMouseDown(with: event)
        case .rightMouseUp: surfaceView.rightMouseUp(with: event)
        case .rightMouseDragged: surfaceView.rightMouseDragged(with: event)
        case .otherMouseDown:
            activateForClick()
            surfaceView.otherMouseDown(with: event)
        case .otherMouseUp: surfaceView.otherMouseUp(with: event)
        case .otherMouseDragged: surfaceView.otherMouseDragged(with: event)
        case .mouseMoved: surfaceView.mouseMoved(with: event)
        case .scrollWheel: surfaceView.scrollWheel(with: event)
        default: super.sendEvent(event)
        }
    }

    /// Not while the session is suspended (dimmed: the host drops input) or minimised.
    private var localGestures: Bool { spec.dim == nil && !isMiniaturized }

    /// Event location in screen coordinates (the window may have moved since the event was made).
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window === self ? convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation
    }

    /// We bypass NSWindow's click handling, so do its activation part.
    private func activateForClick() {
        if !NSApp.isActive { NSApp.activate() }
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        if firstResponder !== surfaceView { makeFirstResponder(surfaceView) }
    }

    private func hitsStandardButton(_ event: NSEvent) -> Bool {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { type in
            guard let b = standardWindowButton(type), let sv = b.superview else { return false }
            return sv.convert(b.frame, to: nil).insetBy(dx: -4, dy: -4).contains(event.locationInWindow)
        }
    }

    // MARK: Local gestures (D20)

    /// The content is frozen: a gesture runs, or its move/resize is not yet confirmed by the host.
    var isFrozen: Bool { surfaceView.frozenCrop != nil }

    private func beginGesture() {
        gestureFallback?.cancel()
        gestureFallback = nil
        inGesture = true
        if !isFrozen { surfaceView.freeze(spec.rect) }
        onGesture?(self, true)
    }

    private func endGesture() {
        inGesture = false
        send(.gestureEnded(windowId: spec.id, frame: WirePointRect(contentRect(forFrameRect: frame))))
        let fallback = DispatchWorkItem { [weak self] in self?.gestureDone(surface: nil) }
        gestureFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gestureDoneTimeout, execute: fallback)
    }

    /// The host settled the move/resize (or it did not answer in time): live content again.
    /// `surface` nil = the one shown last.
    func gestureDone(surface: IOSurfaceRef?) {
        guard !inGesture else { return }        // a new gesture already runs; it keeps the freeze
        gestureFallback?.cancel()
        gestureFallback = nil
        guard isFrozen else { return }
        surfaceView.unfreeze()
        if let frame = spec.frame?.cgRect, frame != contentRect(forFrameRect: self.frame), !isMiniaturized { placeFromHost(frame) }
        surfaceView.refresh(surface ?? surfaceView.shownSurface, crop: spec.rect)
        onGesture?(self, false)
    }

    /// Also while suspended: an AppKit live resize cannot be refused, and the host must hear its end (the
    /// main process commits it too).
    func liveResizeStarted() {
        guard isSeamless else { return }
        beginGesture()
    }

    func liveResizeEnded() {
        if inGesture { endGesture() }
    }

    /// During a live resize: once the size differs from the frozen crop, the content is a snapshot of it.
    func resized() {
        if inGesture { surfaceView.snapshotIfResized() }
    }
}

/// A popup, menu, tooltip or tool window of the app (phase 2): borderless and non-activating, at the pop-up
/// menu level for menus and floating otherwise, as `SeamlessPanel` in the main process. Placed where the
/// host says (its monitor map and k, D29); clicks go to the remote window without activating this app.
final class SurfacePanel: NSPanel, SurfaceShowing {
    private(set) var spec: HelperWindowSpec
    let surfaceView: SurfaceView

    init(spec: HelperWindowSpec, defaultScale: CGFloat, send: @escaping (HelperMessage) -> Void) {
        self.spec = spec
        let scale = spec.scale.map { CGFloat($0) } ?? defaultScale
        let content = spec.frame?.cgRect
            ?? NSRect(x: 0, y: 0, width: CGFloat(spec.rect.width) / scale, height: CGFloat(spec.rect.height) / scale)
        surfaceView = SurfaceView(frame: NSRect(origin: .zero, size: content.size), scale: scale, send: send)
        super.init(contentRect: content, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = spec.menu == true ? .popUpMenu : .floating
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        isExcludedFromWindowsMenu = true
        contentView = surfaceView
        surfaceView.windowId = spec.id
        setFrame(frameRect(forContentRect: content), display: false)
        surfaceView.dim(spec.dim)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(_ new: HelperWindowSpec, surface: IOSurfaceRef?) {
        let old = spec
        spec = new
        if let scale = new.scale { surfaceView.scale = CGFloat(scale) }
        if new.menu != old.menu { level = new.menu == true ? .popUpMenu : .floating }
        if let frame = new.frame?.cgRect, frame != contentRect(forFrameRect: self.frame) {
            setFrame(frameRect(forContentRect: frame), display: true)
        }
        if new.dim != old.dim { surfaceView.dim(new.dim) }
        surfaceView.refresh(surface, crop: new.rect)
    }
}

final class SurfaceView: NSView {
    var windowId: UInt32 = 0
    /// Session pixels per point.
    var scale: CGFloat
    /// The remote pointer shape at this view's k (phase 2); nil = the arrow (no shape known yet).
    var cursorProvider: ((CGFloat) -> NSCursor?)?
    private let send: (HelperMessage) -> Void
    private let surfaceLayer = CALayer()
    private let dimLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    /// What `refresh` last showed, to redo it when the window moves to a screen with another backing scale.
    private var shown: (surface: IOSurfaceRef?, crop: WireRect)?
    /// Local gesture (D20): the crop where it started, and its snapshot once the size differs.
    private(set) var frozenCrop: WireRect?
    private var snapshot: CGImage?

    var shownSurface: IOSurfaceRef? { shown?.surface }

    init(frame: NSRect, scale: CGFloat, send: @escaping (HelperMessage) -> Void) {
        self.scale = scale
        self.send = send
        super.init(frame: frame)
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.magnificationFilter = .nearest
        surfaceLayer.minificationFilter = .nearest
        surfaceLayer.isOpaque = true
        surfaceLayer.backgroundColor = NSColor.black.cgColor
        layer = surfaceLayer          // layer-hosting, as SessionView
        wantsLayer = true
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.isHidden = true
        dimLayer.zPosition = 1
        surfaceLayer.addSublayer(dimLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Re-reads the surface (pixels changed, or a new surface) and sets the crop, as SessionView.refresh.
    /// One session pixel per device pixel when k equals the backing scale (nearest, pixel-exact); a 2x
    /// window on a 1x screen minifies linearly (docs/80 §4.2). Frozen (D20): the crop where the gesture
    /// started, or its snapshot.
    func refresh(_ surface: IOSurfaceRef?, crop r: WireRect) {
        shown = (surface, r)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = nil
        let backing = window?.backingScaleFactor ?? scale
        surfaceLayer.contentsScale = backing
        surfaceLayer.minificationFilter = scale > backing ? .linear : .nearest
        if let snapshot {
            surfaceLayer.contents = snapshot
            updateSnapshotRect(snapshot)
        } else {
            surfaceLayer.contents = surface
            if let surface {
                let w = CGFloat(IOSurfaceGetWidth(surface)), h = CGFloat(IOSurfaceGetHeight(surface))
                if w > 0, h > 0 {
                    let c = (frozenCrop ?? r).cgRect
                    surfaceLayer.contentsRect = CGRect(x: c.minX / w, y: c.minY / h, width: c.width / w, height: c.height / h)
                }
            }
        }
        dimLayer.frame = bounds
        CATransaction.commit()
    }

    /// Anchored top-left, 1:1; beyond the image Core Animation extends the edge pixels.
    private func updateSnapshotRect(_ image: CGImage) {
        surfaceLayer.contentsRect = SharedSurface.snapshotContentsRect(
            viewPixels: CGSize(width: bounds.width * scale, height: bounds.height * scale), imageSize: CGSize(width: image.width, height: image.height))
    }

    func freeze(_ crop: WireRect) {
        frozenCrop = crop
        snapshot = nil
    }

    func unfreeze() {
        frozenCrop = nil
        snapshot = nil
    }

    /// The view no longer has the frozen crop's size: show a copy of that crop from the shared surface.
    func snapshotIfResized() {
        guard let crop = frozenCrop, snapshot == nil, let surface = shown?.surface else { return }
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w != crop.width || h != crop.height else { return }
        snapshot = SharedSurface.image(surface, rect: crop)
        if let shown { refresh(shown.surface, crop: shown.crop) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let shown { refresh(shown.surface, crop: shown.crop) }
    }

    /// Overlay alpha, or nil for none.
    func dim(_ alpha: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        dimLayer.opacity = Float(alpha ?? 0)
        dimLayer.isHidden = alpha == nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let snapshot { updateSnapshotRect(snapshot) }
        dimLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: Cursor (phase 2: the remote pointer shape)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // Hover reaches the host also while the app is inactive, as in ICAViewer's SessionView.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        if let cursor = cursorProvider?(scale) { addCursorRect(bounds, cursor: cursor) }
    }

    override func cursorUpdate(with event: NSEvent) {
        (cursorProvider?(scale) ?? .arrow).set()
    }

    // MARK: Input → host (view and screen points)

    private func points(_ event: NSEvent) -> (view: CGPoint, screen: CGPoint) {
        let p = convert(event.locationInWindow, from: nil)
        let s = window.map { event.window === $0 ? $0.convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation }
            ?? NSEvent.mouseLocation
        return (p, s)
    }

    private func mouse(_ event: NSEvent, _ kind: MouseKind, button: Int) {
        let (p, s) = points(event)
        let clicks = kind == .down || kind == .up ? event.clickCount : 0
        // Moves may be dropped when the host is busy; buttons may not.
        let message = HelperMessage.mouse(windowId: windowId, kind: kind, button: button, x: Double(p.x), y: Double(p.y),
                                          screenX: Double(s.x), screenY: Double(s.y), clickCount: clicks,
                                          modifiers: event.modifierFlags.rawValue, sentNs: uptimeNanoseconds())
        send(message)
    }

    override func mouseDown(with event: NSEvent) { mouse(event, .down, button: 0) }
    override func mouseUp(with event: NSEvent) { mouse(event, .up, button: 0) }
    override func mouseDragged(with event: NSEvent) { mouse(event, .dragged, button: 0) }
    override func rightMouseDown(with event: NSEvent) { mouse(event, .down, button: 1) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, .up, button: 1) }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, .dragged, button: 1) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { mouse(event, .down, button: 2) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { mouse(event, .up, button: 2) } }
    override func otherMouseDragged(with event: NSEvent) { mouse(event, .dragged, button: 2) }
    override func mouseMoved(with event: NSEvent) { mouse(event, .moved, button: -1) }

    override func scrollWheel(with event: NSEvent) {
        let (p, s) = points(event)
        send(.scroll(windowId: windowId, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                     precise: event.hasPreciseScrollingDeltas, x: Double(p.x), y: Double(p.y),
                     screenX: Double(s.x), screenY: Double(s.y), sentNs: uptimeNanoseconds()))
    }

    // MARK: Keyboard → host (the host's translator makes scancodes, docs/99 §4)

    /// Cmd shortcuts the Edit menu has; in a remote window they go to the server as Ctrl+key, as in
    /// ICAViewer's SessionView (the menu items, chosen by mouse, send the same).
    static let remoteShortcuts: Set<String> = Set(EditCommand.allCases.map(\.letter))

    /// This helper's own menu (`HelperMenu`), to tell its key equivalents from those AppKit adds by itself.
    var ownMenu: [HelperMenuSection] = []

    /// Key equivalents reach the key window's views before the menu bar. The Edit letters and every Cmd or
    /// Ctrl key-down that is not one of our own items (⌘Q/H/W/M, ⌥⌘H, ⌃⌥⌘L) go to the server here, so
    /// AppKit's automatic items (macOS 15 tiling ⌃fn-arrows = Ctrl+Home/End…, Help search ⇧⌘/) never take
    /// them; ⌘` (cycle windows) stays with AppKit.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command), Self.remoteShortcuts.contains(key) {
            self.key(event, .down)
            return true
        }
        guard flags.contains(.command) || flags.contains(.control), !(flags.contains(.command) && key == "`") else {
            return super.performKeyEquivalent(with: event)
        }
        var modifiers: HelperShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if HelperMenu.isOwnShortcut(key: key, modifiers: modifiers, in: ownMenu) { return super.performKeyEquivalent(with: event) }
        self.key(event, .down)
        return true
    }

    override func keyDown(with event: NSEvent) { key(event, .down) }
    override func keyUp(with event: NSEvent) { key(event, .up) }
    override func flagsChanged(with event: NSEvent) { key(event, .flags) }

    private func key(_ event: NSEvent, _ phase: KeyPhase) {
        // `characters` raises for flagsChanged events.
        let text = phase == .flags ? "" : event.characters ?? ""
        let plain = phase == .flags ? "" : event.charactersIgnoringModifiers ?? ""
        send(.key(windowId: windowId, phase: phase, keyCode: event.keyCode, characters: text, charactersIgnoringModifiers: plain,
                  modifiers: event.modifierFlags.rawValue, isRepeat: phase == .down && event.isARepeat, sentNs: uptimeNanoseconds()))
    }
}
