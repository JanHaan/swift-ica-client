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

    public init(id: UInt32, title: String, rect: WireRect, frame: WirePointRect? = nil, scale: Double? = nil,
                seamless: Bool? = nil, minimized: Bool? = nil, topmost: Bool? = nil, dim: Double? = nil) {
        self.id = id; self.title = title; self.rect = rect; self.frame = frame; self.scale = scale
        self.seamless = seamless; self.minimized = minimized; self.topmost = topmost; self.dim = dim
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
