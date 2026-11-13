import Foundation

/// Rectangle in session pixels (top-left origin), as on the wire.
public struct WireRect: Codable, Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func intersects(_ other: WireRect) -> Bool {
        x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
    }
}

/// Rectangle in screen points: macOS global coordinates, bottom-left origin (an NSWindow content rect).
public struct WirePointRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ r: CGRect) {
        self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One window a helper owns: an id, a title and its crop of the shared surface.
///
/// The spike (dockspike) sends only id, title and rect; the helper then places a standard titled window
/// itself. ICAViewer (docs/99 §12 phase 1) sends the rest: the main process keeps the window model and the
/// scaling maps, so the helper only shows what it is told.
public struct HelperWindowSpec: Codable, Equatable, Sendable {
    /// The helper-side handle (unique per helper process; not the TWI window id).
    public var id: UInt32
    public var title: String
    /// Crop of the shared surface in session pixels: the layer's contentsRect.
    public var rect: WireRect
    /// Content rect on screen; nil = placed by the helper from `rect` (spike).
    public var frame: WirePointRect?
    /// Session pixels per point (the k of the window's monitor, docs/80 §2.3); nil = the screen's backing scale.
    public var scale: Double?
    /// A seamless app window: hidden title bar, invisible but enabled traffic lights (D14), every mouse event
    /// to the remote window. nil/false = a standard titled window (spike).
    public var seamless: Bool?
    public var minimized: Bool?
    public var topmost: Bool?
    /// Dark overlay alpha while the session is suspended (docs/20 §3.12.9); nil = none.
    public var dim: Double?
    /// Phase 2: a menu, tooltip or tool window of the app (borderless, non-activating panel); `menu` puts it
    /// at the pop-up menu level, else floating, as in the main process.
    public var popup: Bool?
    public var menu: Bool?
    /// Window controls from the remote style (D20): a sizing border allows a local resize, a maximise box Zoom.
    public var resizable: Bool?
    public var zoomable: Bool?
    /// Caption and sizing-border bands for local move/resize (D20), in view points; nil = no local gestures.
    public var bands: HelperHitBands?

    public init(id: UInt32, title: String, rect: WireRect, frame: WirePointRect? = nil, scale: Double? = nil,
                seamless: Bool? = nil, minimized: Bool? = nil, topmost: Bool? = nil, dim: Double? = nil,
                popup: Bool? = nil, menu: Bool? = nil, resizable: Bool? = nil, zoomable: Bool? = nil, bands: HelperHitBands? = nil) {
        self.id = id; self.title = title; self.rect = rect; self.frame = frame; self.scale = scale
        self.seamless = seamless; self.minimized = minimized; self.topmost = topmost; self.dim = dim
        self.popup = popup; self.menu = menu; self.resizable = resizable; self.zoomable = zoomable; self.bands = bands
    }
}

/// Where a press starts a local gesture (D20, docs/50 §3.1), in view points (top-left origin) of the window's
/// content: the main process computes it from the TWI style, flags and system metrics (`TWIHitBands`), so the
/// helper only compares numbers. A press elsewhere goes to the remote window.
public struct HelperHitBands: Codable, Equatable, Sendable {
    /// Width of the sizing border; nil = no local resize.
    public var resizeEdge: Double?
    /// Caption drag area: rows `captionTop..<captionBottom`, columns `captionLeft..<(width - captionRight)`
    /// (the icon and the caption buttons excluded); nil = no local move.
    public var caption: Caption?

    public struct Caption: Codable, Equatable, Sendable {
        public var top: Double, bottom: Double, left: Double, right: Double
        public init(top: Double, bottom: Double, left: Double, right: Double) {
            self.top = top; self.bottom = bottom; self.left = left; self.right = right
        }
    }

    public init(resizeEdge: Double? = nil, caption: Caption? = nil) {
        self.resizeEdge = resizeEdge; self.caption = caption
    }

    public var isEmpty: Bool { resizeEdge == nil && caption == nil }

    public func isResizeEdge(_ p: CGPoint, size: CGSize) -> Bool {
        guard let band = resizeEdge else { return false }
        let x = Double(p.x), y = Double(p.y)
        return x < band || y < band || x > Double(size.width) - band || y > Double(size.height) - band
    }

    public func isCaption(_ p: CGPoint, size: CGSize) -> Bool {
        guard let c = caption else { return false }
        let x = Double(p.x), y = Double(p.y)
        return y >= c.top && y < c.bottom && x >= c.left && x < Double(size.width) - c.right
    }
}

/// A remote pointer shape (Thinwire, session pixels) for the helpers' windows (phase 2): PNG plus hotspot in
/// image pixels; each window shows it at its own k, so it has the same size as in the main process.
public struct HelperCursor: Codable, Equatable, Sendable {
    /// nil = the host hid the pointer.
    public var png: Data?
    /// Size and hotspot of the host's shape in session pixels; the PNG may be downscaled to fit the channel
    /// (it is drawn at this size either way).
    public var pixelWidth: Int, pixelHeight: Int
    public var hotX: Double, hotY: Double
    /// true = the system arrow (the shape could not be sent).
    public var arrow: Bool?

    public init(png: Data?, pixelWidth: Int, pixelHeight: Int, hotX: Double, hotY: Double, arrow: Bool? = nil) {
        self.png = png; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.hotX = hotX; self.hotY = hotY
        self.arrow = arrow
    }

    public static let hidden = HelperCursor(png: nil, pixelWidth: 0, pixelHeight: 0, hotX: 0, hotY: 0)
    public static let systemArrow = HelperCursor(png: nil, pixelWidth: 0, pixelHeight: 0, hotX: 0, hotY: 0, arrow: true)

    /// Size and hotspot in points at k session pixels per point, as `ScalingLayout.cursor` in the main process
    /// (a 64 px host cursor at 200 % is a 32 pt Retina-sharp cursor).
    public func geometry(scale: Double) -> (size: CGSize, hotspot: CGPoint) {
        let k = CGFloat(max(1, scale.rounded()))
        return (CGSize(width: CGFloat(pixelWidth) / k, height: CGFloat(pixelHeight) / k), CGPoint(x: hotX / k, y: hotY / k))
    }
}

/// Main process (host) → helper (docs/99 §4 control channel). `surface` travels with the IOSurface's
/// Mach port as the message's port descriptor.
public enum HostMessage: Codable, Equatable, Sendable {
    case hello(appName: String)
    case surface(width: Int, height: Int)
    case windowAdded(HelperWindowSpec)
    /// Geometry, crop, title, minimised or dim state of a window changed (the whole spec again).
    case windowChanged(HelperWindowSpec)
    case windowRemoved(id: UInt32)
    /// The surface changed in `dirty`; `sentNs` is CLOCK_UPTIME_RAW at send (system-wide clock).
    case frame(seed: UInt32, dirty: [WireRect], sentNs: UInt64)
    /// Become the active app and make the window key (after the previously active helper yielded).
    case activate(windowId: UInt32)
    /// Yield activation to another helper (macOS 14 cooperative activation).
    case yieldActivation(toPid: Int32)
    /// Headless IPC check: read the pixel at (x, y) and reply with `probeResult`.
    case probe(x: Int, y: Int, sentNs: UInt64)
    case quit
    /// Phase 2: the remote pointer shape changed (shown over every window of the helper).
    case cursor(HelperCursor)
    /// Phase 2: the local move/resize the helper reported with `gestureEnded` is settled (the host confirmed
    /// it and presented a covering frame, refused it, or 500 ms passed): show the live crop again (D20).
    case gestureDone(windowId: UInt32)
}

public enum MouseKind: String, Codable, Sendable { case down, up, dragged, moved }

/// keyDown, keyUp or flagsChanged (modifier keys): the main process feeds them to its key translator.
public enum KeyPhase: String, Codable, Sendable { case down, up, flags }

/// Helper → host. `checkIn` carries a send right to the helper's own receive port.
///
/// Pointer positions are the view point (points, top-left origin, relative to the window's content) and
/// the same event in global screen points; the main process maps them to session pixels with its own
/// layout (docs/80 §2.3), exactly as for its own windows. `modifiers` is the raw NSEvent.ModifierFlags.
public enum HelperMessage: Codable, Equatable, Sendable {
    case checkIn(token: String, pid: Int32)
    case key(windowId: UInt32, phase: KeyPhase, keyCode: UInt16, characters: String, charactersIgnoringModifiers: String,
             modifiers: UInt, isRepeat: Bool, sentNs: UInt64)
    /// `button`: 0 left, 1 right, 2 middle, -1 none (moves).
    case mouse(windowId: UInt32, kind: MouseKind, button: Int, x: Double, y: Double, screenX: Double, screenY: Double,
               clickCount: Int, modifiers: UInt, sentNs: UInt64)
    case scroll(windowId: UInt32, dx: Double, dy: Double, precise: Bool, x: Double, y: Double, screenX: Double, screenY: Double,
                sentNs: UInt64)
    /// A window became key in the helper (user click, Cmd-Tab, Mission Control).
    case focus(windowId: UInt32)
    /// A window stopped being key: the host releases the keys it holds down.
    case resignedKey(windowId: UInt32)
    case appActive(Bool)
    /// The user clicked the close button; the host decides (TWI close) and answers with windowRemoved.
    case close(windowId: UInt32)
    /// The user minimised (true) or restored (false) a window: Cmd-M, the Dock, AX.
    case minimized(windowId: UInt32, Bool)
    /// The window was moved or resized in the helper (AX, Mission Control): its new content rect.
    case moved(windowId: UInt32, frame: WirePointRect)
    /// Host-to-helper frame latency over the last `count` frames, in microseconds (budget: docs/99 §12.18).
    case frameStats(count: Int, meanUs: Double, p95Us: Double, maxUs: Double)
    case probeResult(pixel: UInt32, seed: UInt32, sentNs: UInt64)
    /// `yieldActivation` done: the host now sends `activate` to the target (Mach gives no ordering
    /// between two different receivers, so the activate must not race the yield).
    case yielded(toPid: Int32, wasActive: Bool)
    /// Outcome of an `activate` request, for the host's log.
    case activation(String)
    /// The user quit the helper (Cmd-Q). The helper stays; the host closes the app's windows (docs/99 §12.12).
    case appQuit
    /// Phase 2: a local caption drag or edge resize ended with this content rect; the host sends exactly one
    /// TWI move/resize and answers with `gestureDone` (D20). Nothing is sent during the gesture.
    case gestureEnded(windowId: UInt32, frame: WirePointRect)
    /// Phase 2: an Edit menu item was chosen (by mouse): the host sends the same Ctrl+key as the shortcut,
    /// with the clipboard sync before a paste.
    case edit(windowId: UInt32, EditCommand)
    /// Phase 2: Window → Zoom: TWI maximise, or restore when maximised.
    case zoom(windowId: UInt32)
    /// Phase 2: an item of the helper's ICA menu; it runs in the main process (the helper has yielded
    /// activation to it first).
    case command(HelperCommand)
}

extension HelperMessage {
    /// Pointer moves and drags (absolute positions: the next one supersedes a lost one) and statistics go
    /// out with send timeout 0, so a busy host drops them instead of stalling the helper's main thread.
    public var mayDrop: Bool {
        switch self {
        case .mouse(_, let kind, _, _, _, _, _, _, _, _): kind == .moved || kind == .dragged
        case .frameStats: true
        default: false
        }
    }
}

/// JSON on the wire: small, debuggable, Codable-checked. Messages are bounded by `MachChannel.maxPayload`.
public enum WireCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// CLOCK_UPTIME_RAW in nanoseconds: the same clock in every process, for latency stamps.
public func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
