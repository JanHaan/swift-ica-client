import AppHostKit
import AppKit
import QuartzCore

/// One remote window, owned by this helper process: a standard titled window (AXStandardWindow with
/// close and minimize buttons, D14) whose content is a crop of the host's IOSurface, like
/// `SessionView` in ICAViewer. Input goes to the host in session pixels.
final class SurfaceWindow: NSWindow {
    let spec: HelperWindowSpec
    let surfaceView: SurfaceView

    /// `scale`: session pixels per point.
    init(spec: HelperWindowSpec, scale: CGFloat, send: @escaping (HelperMessage) -> Void) {
        self.spec = spec
        let size = NSSize(width: CGFloat(spec.rect.width) / scale, height: CGFloat(spec.rect.height) / scale)
        surfaceView = SurfaceView(frame: NSRect(origin: .zero, size: size), spec: spec, scale: scale, send: send)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        title = spec.title
        contentView = surfaceView
        // Session top-left → screen: the spike's "session" starts at the visible frame's top-left.
        if let visible = NSScreen.main?.visibleFrame {
            let topLeft = NSPoint(x: visible.minX + CGFloat(spec.rect.x) / scale, y: visible.maxY - CGFloat(spec.rect.y) / scale)
            setFrameTopLeftPoint(topLeft)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SurfaceView: NSView {
    private let spec: HelperWindowSpec
    private let scale: CGFloat
    private let send: (HelperMessage) -> Void
    private let surfaceLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, spec: HelperWindowSpec, scale: CGFloat, send: @escaping (HelperMessage) -> Void) {
        self.spec = spec
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Re-reads the surface (pixels changed, or a new surface) and sets the crop, as SessionView.refresh.
    func refresh(_ surface: IOSurfaceRef?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = nil
        surfaceLayer.contents = surface
        surfaceLayer.contentsScale = window?.backingScaleFactor ?? scale
        if let surface {
            let w = CGFloat(IOSurfaceGetWidth(surface)), h = CGFloat(IOSurfaceGetHeight(surface))
            let r = spec.rect.cgRect
            surfaceLayer.contentsRect = CGRect(x: r.minX / w, y: r.minY / h, width: r.width / w, height: r.height / h)
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Input → host (session pixels)

    private func sessionPoint(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        return (Double(CGFloat(spec.rect.x) + p.x * scale), Double(CGFloat(spec.rect.y) + p.y * scale))
    }

    private func mouse(_ event: NSEvent, _ kind: MouseKind, button: Int) {
        let (x, y) = sessionPoint(event)
        send(.mouse(windowId: spec.id, kind: kind, button: button, x: x, y: y,
                    clickCount: kind == .down || kind == .up ? event.clickCount : 0, sentNs: uptimeNanoseconds()))
    }

    override func mouseDown(with event: NSEvent) { mouse(event, .down, button: 0) }
    override func mouseUp(with event: NSEvent) { mouse(event, .up, button: 0) }
    override func mouseDragged(with event: NSEvent) { mouse(event, .dragged, button: 0) }
    override func rightMouseDown(with event: NSEvent) { mouse(event, .down, button: 1) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, .up, button: 1) }
    override func mouseMoved(with event: NSEvent) { mouse(event, .moved, button: -1) }

    override func scrollWheel(with event: NSEvent) {
        send(.scroll(windowId: spec.id, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), sentNs: uptimeNanoseconds()))
    }

    override func keyDown(with event: NSEvent) { key(event, down: true) }
    override func keyUp(with event: NSEvent) { key(event, down: false) }

    private func key(_ event: NSEvent, down: Bool) {
        send(.key(windowId: spec.id, keyCode: event.keyCode, characters: event.characters ?? "",
                  modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, down: down,
                  sentNs: uptimeNanoseconds()))
    }
}
