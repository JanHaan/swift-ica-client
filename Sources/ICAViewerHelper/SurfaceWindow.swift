import AppHostKit
import AppKit
import QuartzCore

/// One remote window, owned by this helper process, whose content is a crop of the host's IOSurface,
/// like `SessionView` in ICAViewer. Two looks:
/// - spike (`spec.seamless` nil): a standard titled window the helper places itself;
/// - seamless (ICAViewer, docs/99 §12): as ICAViewer's `SeamlessWindow` (D14): hidden title bar, invisible
///   but enabled traffic lights (still AXStandardWindow with close and minimize), placed where the host
///   says, every mouse event to the remote window.
/// Input goes to the host as view and screen points; the host maps them to session pixels.
final class SurfaceWindow: NSWindow {
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

    var isSeamless: Bool { spec.seamless == true }

    /// `defaultScale`: session pixels per point when the spec has none (spike).
    init(spec: HelperWindowSpec, defaultScale: CGFloat, send: @escaping (HelperMessage) -> Void) {
        self.spec = spec
        self.send = send
        let scale = spec.scale.map { CGFloat($0) } ?? defaultScale
        let content = spec.frame?.cgRect
            ?? NSRect(x: 0, y: 0, width: CGFloat(spec.rect.width) / scale, height: CGFloat(spec.rect.height) / scale)
        surfaceView = SurfaceView(frame: NSRect(origin: .zero, size: content.size), scale: scale, send: send)
        let style: NSWindow.StyleMask = spec.seamless == true
            ? [.titled, .closable, .miniaturizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable]
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

    /// A new spec from the host: geometry, crop, title, level, minimised and dim state.
    func apply(_ new: HelperWindowSpec, surface: IOSurfaceRef?) {
        let old = spec
        spec = new
        if new.title != old.title { title = new.title }
        if let scale = new.scale { surfaceView.scale = CGFloat(scale) }
        if isSeamless {
            if new.topmost != old.topmost { level = new.topmost == true ? .floating : .normal }
            if let frame = new.frame?.cgRect, frame != contentRect(forFrameRect: self.frame), !isMiniaturized { placeFromHost(frame) }
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

    /// Seamless: every mouse event goes to the remote window (never to the invisible buttons or the
    /// title-bar view), as `SeamlessWindow.sendEvent`. Phase 1 has no local caption drag or edge resize
    /// (D20 moves into the helper in phase 2): the host moves and sizes the window itself.
    override func sendEvent(_ event: NSEvent) {
        guard isSeamless else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDown:
            activateForClick()
            surfaceView.mouseDown(with: event)
        case .leftMouseDragged: surfaceView.mouseDragged(with: event)
        case .leftMouseUp: surfaceView.mouseUp(with: event)
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

    /// We bypass NSWindow's click handling, so do its activation part.
    private func activateForClick() {
        if !NSApp.isActive { NSApp.activate() }
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        if firstResponder !== surfaceView { makeFirstResponder(surfaceView) }
    }
}

final class SurfaceView: NSView {
    var windowId: UInt32 = 0
    /// Session pixels per point.
    var scale: CGFloat
    private let send: (HelperMessage) -> Void
    private let surfaceLayer = CALayer()
    private let dimLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    /// What `refresh` last showed, to redo it when the window moves to a screen with another backing scale.
    private var shown: (surface: IOSurfaceRef?, crop: WireRect)?

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
    /// window on a 1x screen minifies linearly (docs/80 §4.2).
    func refresh(_ surface: IOSurfaceRef?, crop r: WireRect) {
        shown = (surface, r)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = nil
        surfaceLayer.contents = surface
        let backing = window?.backingScaleFactor ?? scale
        surfaceLayer.contentsScale = backing
        surfaceLayer.minificationFilter = scale > backing ? .linear : .nearest
        if let surface {
            let w = CGFloat(IOSurfaceGetWidth(surface)), h = CGFloat(IOSurfaceGetHeight(surface))
            if w > 0, h > 0 {
                let c = r.cgRect
                surfaceLayer.contentsRect = CGRect(x: c.minX / w, y: c.minY / h, width: c.width / w, height: c.height / h)
            }
        }
        dimLayer.frame = bounds
        CATransaction.commit()
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
        dimLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // Hover reaches the host also while the app is inactive, as in ICAViewer's SessionView.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
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

    /// Cmd shortcuts an Edit menu would take; in a remote window they go to the server as Ctrl+key, as in
    /// ICAViewer's SessionView. Cmd-Q, Cmd-H, Cmd-M and Cmd-W stay with this app's menu.
    static let remoteShortcuts: Set<String> = ["z", "x", "c", "v", "a"]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.isKeyWindow == true, event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(), Self.remoteShortcuts.contains(key) {
            self.key(event, .down)
            return true
        }
        return super.performKeyEquivalent(with: event)
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
