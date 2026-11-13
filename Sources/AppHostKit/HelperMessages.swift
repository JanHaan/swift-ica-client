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

/// One window a helper owns: an id, a title and its crop of the shared surface.
public struct HelperWindowSpec: Codable, Equatable, Sendable {
    public var id: UInt32
    public var title: String
    public var rect: WireRect

    public init(id: UInt32, title: String, rect: WireRect) {
        self.id = id; self.title = title; self.rect = rect
    }
}

/// Main process (host) → helper (docs/99 §4 control channel). `surface` travels with the IOSurface's
/// Mach port as the message's port descriptor.
public enum HostMessage: Codable, Equatable, Sendable {
    case hello(appName: String)
    case surface(width: Int, height: Int)
    case windowAdded(HelperWindowSpec)
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

/// Helper → host. `checkIn` carries a send right to the helper's own receive port.
public enum HelperMessage: Codable, Equatable, Sendable {
    case checkIn(token: String, pid: Int32)
    case key(windowId: UInt32, keyCode: UInt16, characters: String, modifiers: UInt, down: Bool, sentNs: UInt64)
    /// `x`/`y` in session pixels.
    case mouse(windowId: UInt32, kind: MouseKind, button: Int, x: Double, y: Double, clickCount: Int, sentNs: UInt64)
    case scroll(windowId: UInt32, dx: Double, dy: Double, sentNs: UInt64)
    /// A window became key in the helper (user click, Cmd-Tab, Mission Control).
    case focus(windowId: UInt32)
    case appActive(Bool)
    /// The user clicked the close button; the host decides (TWI close) and answers with windowRemoved.
    case close(windowId: UInt32)
    /// Host-to-helper frame latency over the last `count` frames, in microseconds.
    case frameStats(count: Int, meanUs: Double, maxUs: Double)
    case probeResult(pixel: UInt32, seed: UInt32, sentNs: UInt64)
    /// `yieldActivation` done: the host now sends `activate` to the target (Mach gives no ordering
    /// between two different receivers, so the activate must not race the yield).
    case yielded(toPid: Int32, wasActive: Bool)
    /// Outcome of an `activate` request, for the host's log.
    case activation(String)
    /// The user quit the helper (Cmd-Q).
    case appQuit
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
