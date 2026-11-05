import Foundation

/// A monitor as reported to the host: bounds and work area in session pixels.
public struct TWIMonitor: Equatable, Sendable {
    public var bounds: TWIRect
    public var workArea: TWIRect
    public init(bounds: TWIRect, workArea: TWIRect) { self.bounds = bounds; self.workArea = workArea }
}

/// Builders for client -> host messages (docs/50 §2.2). Each returns a complete framed message:
/// `u8 type, u16 length, payload`. Send the result as `ChannelOutput.channel`.
public enum TWIRequest {
    public enum ClientType {
        public static let clientInit: UInt8 = 0x01, pause: UInt8 = 0x05, resume: UInt8 = 0x06
        public static let moveResize: UInt8 = 0x0a, activate: UInt8 = 0x0b, restore: UInt8 = 0x0c
        public static let close: UInt8 = 0x0e, resendWindow: UInt8 = 0x14, logoff: UInt8 = 0x33
        public static let clientMetrics: UInt8 = 0x35, sysCommand: UInt8 = 0x36
        public static let monitorLayout: UInt8 = 0x3b, closeAlt: UInt8 = 0x3c
    }

    public static let wmSysCommand: UInt32 = 0x112
    public static let scMinimize: UInt32 = 0xF020
    public static let scMaximize: UInt32 = 0xF030
    public static let clientMetricsSize = 456

    public static func frame(_ type: UInt8, _ payload: Data = Data()) -> Data {
        precondition(payload.count <= 0xffff, "TWI payload too long")
        var w = ByteWriter()
        w.u8(type); w.u16(UInt16(payload.count)); w.raw(payload)
        return w.data
    }

    /// Client init: `u8 0, u8 major, u8 minor, u8 action, u32 flags`. Action 0 = seamless wanted, 1 = not.
    public static func clientInit(seamless: Bool = true, flags: TWIClientFlags, major: UInt8 = 3, minor: UInt8 = 2) -> Data {
        var w = ByteWriter()
        w.u8(0); w.u8(major); w.u8(minor); w.u8(seamless ? 0 : 1); w.u32(flags.rawValue)
        return frame(ClientType.clientInit, w.data)
    }

    public static func pause() -> Data { frame(ClientType.pause) }
    public static func resume() -> Data { frame(ClientType.resume) }
    public static func logoff() -> Data { frame(ClientType.logoff) }

    public static func moveResize(windowId: UInt32, rect: TWIRect) -> Data {
        var w = ByteWriter()
        w.u32(windowId); put(&w, rect)
        return frame(ClientType.moveResize, w.data)
    }

    /// `windowId` 0 means "no remote window has focus".
    public static func activate(windowId: UInt32) -> Data { idOnly(ClientType.activate, windowId) }
    public static func restore(windowId: UInt32) -> Data { idOnly(ClientType.restore, windowId) }
    public static func close(windowId: UInt32) -> Data { idOnly(ClientType.close, windowId) }
    /// Close for hosts that set flag 0x200.
    public static func closeAlt(windowId: UInt32) -> Data { idOnly(ClientType.closeAlt, windowId) }
    public static func resendWindow(windowId: UInt32) -> Data { idOnly(ClientType.resendWindow, windowId) }

    public static func sysCommand(windowId: UInt32, message: UInt32 = wmSysCommand, wParam: UInt32,
                                  lParam: UInt32 = 0, extra: UInt32 = 0) -> Data {
        var w = ByteWriter()
        w.u32(windowId); w.u32(message); w.u32(wParam); w.u32(lParam); w.u32(extra)
        return frame(ClientType.sysCommand, w.data)
    }
    public static func minimize(windowId: UInt32) -> Data { sysCommand(windowId: windowId, wParam: scMinimize) }
    public static func maximize(windowId: UInt32) -> Data { sysCommand(windowId: windowId, wParam: scMaximize) }

    /// Work area rect for the 0x35 message: one monitor -> its work area; none -> 0,0,session size;
    /// several -> all zero (the per-monitor areas go in the monitor layout).
    public static func workArea(monitors: [TWIMonitor], sessionWidth: Int32, sessionHeight: Int32) -> TWIRect {
        switch monitors.count {
        case 0: return TWIRect(left: 0, top: 0, right: sessionWidth, bottom: sessionHeight)
        case 1: return monitors[0].workArea
        default: return .zero
        }
    }

    /// 456 bytes: work area, `1`, 340 zero bytes (NONCLIENTMETRICS), minimised metrics
    /// `20,154,0,0,8`, 76 zero bytes (ICONMETRICS).
    public static func clientMetrics(workArea: TWIRect) -> Data {
        var w = ByteWriter()
        put(&w, workArea)
        w.u32(1)
        w.raw([UInt8](repeating: 0, count: 340))
        for v: UInt32 in [20, 154, 0, 0, 8] { w.u32(v) }
        w.raw([UInt8](repeating: 0, count: 76))
        assert(w.data.count == clientMetricsSize)
        return frame(ClientType.clientMetrics, w.data)
    }

    public static func monitorLayout(_ monitors: [TWIMonitor]) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(monitors.count))
        for m in monitors { put(&w, m.bounds); put(&w, m.workArea) }
        return frame(ClientType.monitorLayout, w.data)
    }

    private static func idOnly(_ type: UInt8, _ id: UInt32) -> Data {
        var w = ByteWriter()
        w.u32(id)
        return frame(type, w.data)
    }

    private static func put(_ w: inout ByteWriter, _ r: TWIRect) {
        w.u32(UInt32(bitPattern: r.left)); w.u32(UInt32(bitPattern: r.top))
        w.u32(UInt32(bitPattern: r.right)); w.u32(UInt32(bitPattern: r.bottom))
    }
}
