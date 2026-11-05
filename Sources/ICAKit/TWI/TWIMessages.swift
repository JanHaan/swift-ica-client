import Foundation

// Seamless windows channel (CTXTWI): wire types and parsers. Spec: docs/50-twi.md.
// All integers are little-endian; strings are NUL-terminated (UTF-8 if negotiated, else Latin-1).

/// Rectangle as sent on the wire: left, top, right, bottom (right/bottom exclusive), session pixels.
public struct TWIRect: Equatable, Hashable, Sendable {
    public var left: Int32, top: Int32, right: Int32, bottom: Int32
    public init(left: Int32, top: Int32, right: Int32, bottom: Int32) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.init(left: x, top: y, right: x + width, bottom: y + height)
    }
    public static let zero = TWIRect(left: 0, top: 0, right: 0, bottom: 0)
    public var width: Int32 { right - left }
    public var height: Int32 { bottom - top }
}

/// Win32 style bits the seamless layer evaluates (docs/50 §2.7).
public enum TWIStyle {
    public static let popup: UInt32 = 0x8000_0000
    public static let child: UInt32 = 0x4000_0000
    public static let visible: UInt32 = 0x1000_0000
    public static let minimize: UInt32 = 0x2000_0000
    public static let maximize: UInt32 = 0x0100_0000
    public static let disabled: UInt32 = 0x0800_0000
    public static let border: UInt32 = 0x0080_0000
    public static let dlgFrame: UInt32 = 0x0040_0000
    public static let caption: UInt32 = 0x00C0_0000
    public static let sysMenu: UInt32 = 0x0008_0000
    public static let thickFrame: UInt32 = 0x0004_0000
    public static let minimizeBox: UInt32 = 0x0002_0000
    public static let maximizeBox: UInt32 = 0x0001_0000

    public static let exToolWindow: UInt32 = 0x0000_0080
    public static let exNoActivate: UInt32 = 0x0800_0000
    public static let exAppWindow: UInt32 = 0x0004_0000
    public static let exTopmost: UInt32 = 0x0000_0008
}

/// Host feature flags (u32 at offset 13 of host init).
public struct TWIHostFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let noRefreshWithUTF8 = TWIHostFlags(rawValue: 0x0000_0008)
    public static let monitorLayout = TWIHostFlags(rawValue: 0x0000_0010)
    public static let closeAlt = TWIHostFlags(rawValue: 0x0000_0200)
    public static let noUnsolicitedMetrics = TWIHostFlags(rawValue: 0x0000_0400)
    public static let extendedInfo = TWIHostFlags(rawValue: 0x0000_0800)
    public static let iconChunks = TWIHostFlags(rawValue: 0x0000_1000)
    public static let bitmaps = TWIHostFlags(rawValue: 0x0000_8000)
    public static let utf8 = TWIHostFlags(rawValue: 0x0001_0000)
    public static let flag20000 = TWIHostFlags(rawValue: 0x0002_0000)
}

/// Client capability flags (u32 in the client init).
public struct TWIClientFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let bit4 = TWIClientFlags(rawValue: 0x0004)
    public static let bit8 = TWIClientFlags(rawValue: 0x0008)
    public static let monitorLayout = TWIClientFlags(rawValue: 0x0010)
    public static let extendedInfo = TWIClientFlags(rawValue: 0x0080)
    public static let iconChunks = TWIClientFlags(rawValue: 0x0100)
    public static let bitmaps = TWIClientFlags(rawValue: 0x0800)
    public static let utf8 = TWIClientFlags(rawValue: 0x1000)
    public static let flag2000 = TWIClientFlags(rawValue: 0x2000)
}

/// Host init (H2C 0x01), docs/50 §1.4.
public struct TWIHostInit: Equatable, Sendable {
    public var captionGeneration: UInt8   // byte 0
    public var hostVersion: UInt8         // byte 4 (>= 3: re-send metrics after ack)
    public var desktopWidth: Int16        // offset 8
    public var desktopHeight: Int16       // offset 10
    public var flags: TWIHostFlags        // offset 13
    public var rawHeader: Data            // first 17 bytes, for diagnostics
}

public struct TWICreate: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case v1, menu, v2 }
    public var source: Source
    public var id: UInt32
    public var flags: UInt16
    public var style: UInt32
    public var exStyle: UInt32
    public var windowRect: TWIRect
    public var clientRect: TWIRect
    public var ownerId: UInt32
    /// Only in v2 creates.
    public var processId: UInt32?
    /// Second string of v2 creates (grouping key, probably an AppUserModelID).
    public var appId: String?
    public var title: String?
}

public struct TWIChangeMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let title = TWIChangeMask(rawValue: 0x01)
    public static let style = TWIChangeMask(rawValue: 0x02)
    public static let exStyle = TWIChangeMask(rawValue: 0x04)
    public static let windowRect = TWIChangeMask(rawValue: 0x08)
    public static let clientRect = TWIChangeMask(rawValue: 0x10)
    public static let owner = TWIChangeMask(rawValue: 0x20)
    public static let above = TWIChangeMask(rawValue: 0x40)
    /// Mask that describes a complete window (implicit create for an unknown id).
    public static let full = TWIChangeMask(rawValue: 0x3f)
}

public struct TWIChange: Equatable, Sendable {
    public var id: UInt32
    public var mask: TWIChangeMask
    public var flags: UInt16
    public var style: UInt32?
    public var exStyle: UInt32?
    public var windowRect: TWIRect?
    public var clientRect: TWIRect?
    public var ownerId: UInt32?
    public var windowAbove: UInt32?
    public var title: String?
}

public struct TWISystemMetrics: Equatable, Sendable {
    public var firstWord: UInt32
    /// 22 signed 16-bit metrics.
    public var metrics: [Int16]
    public var strings: [String]
    public var frameThickness: (x: Int16, y: Int16) { (metrics[0], metrics[1]) }
    public var dialogFrameThickness: (x: Int16, y: Int16) { (metrics[2], metrics[3]) }
    public var cornerGrip: (x: Int16, y: Int16) { (metrics[8], metrics[9]) }
    public var captionHeight: Int16 { metrics[16] }
    public var captionButtonWidth: Int16 { metrics[18] }

    public static func == (a: TWISystemMetrics, b: TWISystemMetrics) -> Bool {
        a.firstWord == b.firstWord && a.metrics == b.metrics && a.strings == b.strings
    }
}

public struct TWIProcessInfo: Equatable, Sendable {
    public var processId: UInt32
    /// "Second id"; parent process id by inference.
    public var parentId: UInt32
    public var flags: UInt16
    public var stringA: String
    /// Executable path (the engine calls it moduleFilePath).
    public var executablePath: String
    /// The engine calls it appName; carries `...#Name` for published apps.
    public var appName: String
}

/// One chunk of WINDOW_ICON_EX (0x3e).
public struct TWIIconChunk: Equatable, Sendable {
    public var windowId: UInt32
    public var processId: UInt32
    public var iconType: UInt32
    public var flags: UInt16
    /// Present only on the first chunk of a multi-chunk icon.
    public var totalSize: UInt32?
    public var data: Data
    public var isFirst: Bool { flags & 0x40 != 0 }
    public var hasMore: Bool { flags & 0x80 != 0 }
}

/// One chunk of WINDOW_BITMAP (0x42).
public struct TWIBitmapChunk: Equatable, Sendable {
    public var windowId: UInt32
    public var flags: UInt16
    public var totalSize: UInt32?
    public var data: Data
    public var isFirst: Bool { flags & 0x40 != 0 }
    public var hasMore: Bool { flags & 0x80 != 0 }
}

public enum TWIHostMessage: Equatable, Sendable {
    case hostInit(TWIHostInit)
    case open
    case close
    case create(TWICreate)
    case destroy(windowId: UInt32)
    case change(TWIChange)
    case systemMetrics(TWISystemMetrics)
    case windowIcon(windowId: UInt32, iconType: UInt32, blob: Data)
    case foreground(windowId: UInt32)
    case windowRect(windowId: UInt32, rect: TWIRect)               // 0x19, discarded by the reference engine
    case rectList(windowId: UInt32, rects: [TWIRect])              // 0x33, probably the window region
    case metricsAck                                                 // 0x3a
    case iconChunk(TWIIconChunk)
    case processCreated(TWIProcessInfo)
    case processEnded(processId: UInt32, flags: UInt16)
    case bitmapChunk(TWIBitmapChunk)
    /// Type not handled (undefined, or defined but not dispatched by the reference engine).
    case unknown(type: UInt8, length: Int)
}

public enum TWIParseError: Error, Equatable {
    case malformed(type: UInt8)
}

/// Host message type ids.
public enum TWIHostType {
    public static let hostInit: UInt8 = 0x01, open: UInt8 = 0x02, close: UInt8 = 0x03
    public static let createV1: UInt8 = 0x0a, destroy: UInt8 = 0x0b, change: UInt8 = 0x0c
    public static let systemMetrics: UInt8 = 0x0d, windowIcon: UInt8 = 0x0e
    public static let foreground: UInt8 = 0x14, createMenu: UInt8 = 0x17, windowRect: UInt8 = 0x19
    public static let rectList: UInt8 = 0x33, metricsAck: UInt8 = 0x3a
    public static let iconChunk: UInt8 = 0x3e, createV2: UInt8 = 0x3f
    public static let processCreated: UInt8 = 0x40, processEnded: UInt8 = 0x41, bitmapChunk: UInt8 = 0x42
}

// MARK: - Payload access

struct TWIPayload {
    let bytes: [UInt8]
    init(_ data: Data) { bytes = [UInt8](data) }
    var count: Int { bytes.count }

    func u8(_ o: Int) throws -> UInt8 {
        guard o >= 0, o < bytes.count else { throw ByteError.truncated }
        return bytes[o]
    }
    func u16(_ o: Int) throws -> UInt16 { UInt16(try u8(o)) | UInt16(try u8(o + 1)) << 8 }
    func u32(_ o: Int) throws -> UInt32 { UInt32(try u16(o)) | UInt32(try u16(o + 2)) << 16 }
    func i16(_ o: Int) throws -> Int16 { Int16(bitPattern: try u16(o)) }
    func i32(_ o: Int) throws -> Int32 { Int32(bitPattern: try u32(o)) }
    func rect(_ o: Int) throws -> TWIRect {
        TWIRect(left: try i32(o), top: try i32(o + 4), right: try i32(o + 8), bottom: try i32(o + 12))
    }
    func data(_ o: Int, _ n: Int) throws -> Data {
        guard o >= 0, n >= 0, o + n <= bytes.count else { throw ByteError.truncated }
        return Data(bytes[o..<o + n])
    }
    /// NUL-terminated string starting at `o`; empty when `o` is outside the payload.
    func cString(at o: Int, utf8: Bool) -> String {
        guard o >= 0, o < bytes.count else { return "" }
        let end = bytes[o...].firstIndex(of: 0) ?? bytes.count
        return TWIText.decode(bytes[o..<end], utf8: utf8)
    }
}

enum TWIText {
    static func decode(_ b: ArraySlice<UInt8>, utf8: Bool) -> String {
        if utf8 { return String(decoding: b, as: UTF8.self) }
        var s = String.UnicodeScalarView()
        for c in b { s.append(UnicodeScalar(c)) }
        return String(s)
    }
}

// MARK: - Stream framing

/// Reassembles the 1-byte type + 2-byte length framing from arbitrary payload splits.
public struct TWIStreamFramer {
    public struct Frame: Equatable, Sendable {
        public var type: UInt8
        public var payload: Data
    }
    private var buffer: [UInt8] = []
    public init() {}
    public var pendingBytes: Int { buffer.count }

    public mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        var pos = 0
        while buffer.count - pos >= 3 {
            let len = Int(buffer[pos + 1]) | Int(buffer[pos + 2]) << 8
            guard buffer.count - pos - 3 >= len else { break }
            frames.append(Frame(type: buffer[pos], payload: Data(buffer[pos + 3..<pos + 3 + len])))
            pos += 3 + len
        }
        if pos > 0 { buffer.removeFirst(pos) }
        return frames
    }

    public mutating func reset() { buffer.removeAll() }
}

// MARK: - Message parsing

public enum TWIMessageParser {
    public static func parse(_ frame: TWIStreamFramer.Frame, utf8: Bool) throws -> TWIHostMessage {
        try parse(type: frame.type, payload: frame.payload, utf8: utf8)
    }

    public static func parse(type: UInt8, payload data: Data, utf8: Bool) throws -> TWIHostMessage {
        let p = TWIPayload(data)
        do {
            switch type {
            case TWIHostType.hostInit: return .hostInit(try hostInit(p))
            case TWIHostType.open: return .open
            case TWIHostType.close: return .close
            case TWIHostType.createV1: return .create(try createV1(p, source: .v1, utf8: utf8))
            case TWIHostType.createMenu: return .create(try createV1(p, source: .menu, utf8: utf8))
            case TWIHostType.createV2: return .create(try createV2(p, utf8: utf8))
            case TWIHostType.destroy: return .destroy(windowId: try p.u32(0))
            case TWIHostType.change: return .change(try change(p, utf8: utf8))
            case TWIHostType.systemMetrics: return .systemMetrics(try systemMetrics(p, utf8: utf8))
            case TWIHostType.windowIcon:
                return .windowIcon(windowId: try p.u32(0), iconType: try p.u32(4), blob: try p.data(8, p.count - 8))
            case TWIHostType.foreground: return .foreground(windowId: try p.u32(0))
            case TWIHostType.windowRect: return .windowRect(windowId: try p.u32(0), rect: try p.rect(4))
            case TWIHostType.rectList: return try rectList(p)
            case TWIHostType.metricsAck: return .metricsAck
            case TWIHostType.iconChunk: return .iconChunk(try iconChunk(p))
            case TWIHostType.processCreated: return .processCreated(try processCreated(p, utf8: utf8))
            case TWIHostType.processEnded: return .processEnded(processId: try p.u32(0), flags: try p.u16(4))
            case TWIHostType.bitmapChunk: return .bitmapChunk(try bitmapChunk(p))
            default: return .unknown(type: type, length: p.count)
            }
        } catch {
            throw TWIParseError.malformed(type: type)
        }
    }

    static func hostInit(_ p: TWIPayload) throws -> TWIHostInit {
        guard p.count >= 17 else { throw ByteError.truncated }
        return TWIHostInit(
            captionGeneration: try p.u8(0), hostVersion: try p.u8(4),
            desktopWidth: try p.i16(8), desktopHeight: try p.i16(10),
            flags: TWIHostFlags(rawValue: try p.u32(13)), rawHeader: try p.data(0, 17))
    }

    static func createV1(_ p: TWIPayload, source: TWICreate.Source, utf8: Bool) throws -> TWICreate {
        guard p.count >= 50 else { throw ByteError.truncated }
        return TWICreate(
            source: source, id: try p.u32(0), flags: try p.u16(4), style: try p.u32(6), exStyle: try p.u32(10),
            windowRect: try p.rect(14), clientRect: try p.rect(30), ownerId: try p.u32(46),
            processId: nil, appId: nil, title: p.count > 50 ? p.cString(at: 50, utf8: utf8) : nil)
    }

    static func createV2(_ p: TWIPayload, utf8: Bool) throws -> TWICreate {
        guard p.count >= 58 else { throw ByteError.truncated }
        let titleOff = Int(try p.u16(54)), idOff = Int(try p.u16(56))
        return TWICreate(
            source: .v2, id: try p.u32(0), flags: try p.u16(52), style: try p.u32(4), exStyle: try p.u32(8),
            windowRect: try p.rect(12), clientRect: try p.rect(28), ownerId: try p.u32(44),
            processId: try p.u32(48),
            appId: idOff >= 58 && idOff < p.count ? p.cString(at: idOff, utf8: utf8) : nil,
            title: titleOff >= 58 && titleOff < p.count ? p.cString(at: titleOff, utf8: utf8) : nil)
    }

    /// Optional fields follow the 10-byte header in the order style, exStyle, window rect,
    /// client rect, owner, window-above, title (bit 0x01 last).
    static func change(_ p: TWIPayload, utf8: Bool) throws -> TWIChange {
        var c = TWIChange(id: try p.u32(0), mask: TWIChangeMask(rawValue: try p.u32(4)), flags: try p.u16(8))
        var o = 10
        if c.mask.contains(.style) { c.style = try p.u32(o); o += 4 }
        if c.mask.contains(.exStyle) { c.exStyle = try p.u32(o); o += 4 }
        if c.mask.contains(.windowRect) { c.windowRect = try p.rect(o); o += 16 }
        if c.mask.contains(.clientRect) { c.clientRect = try p.rect(o); o += 16 }
        if c.mask.contains(.owner) { c.ownerId = try p.u32(o); o += 4 }
        if c.mask.contains(.above) { c.windowAbove = try p.u32(o); o += 4 }
        if c.mask.contains(.title), o < p.count { c.title = p.cString(at: o, utf8: utf8) }
        else if c.mask.contains(.title) { c.title = "" }
        return c
    }

    static func systemMetrics(_ p: TWIPayload, utf8: Bool) throws -> TWISystemMetrics {
        guard p.count >= 54 else { throw ByteError.truncated }
        var metrics: [Int16] = []
        for i in 0..<22 { metrics.append(try p.i16(4 + 2 * i)) }
        var strings: [String] = []
        for i in 0..<3 { strings.append(p.cString(at: 54 + Int(try p.u16(48 + 2 * i)), utf8: utf8)) }
        return TWISystemMetrics(firstWord: try p.u32(0), metrics: metrics, strings: strings)
    }

    static func rectList(_ p: TWIPayload) throws -> TWIHostMessage {
        // u16 ?, u32 id, u32 count, u32 ?, count x rect
        let id = try p.u32(2), n = Int(try p.u32(6))
        guard n >= 0, 14 + n * 16 <= p.count else { throw ByteError.truncated }
        return .rectList(windowId: id, rects: try (0..<n).map { try p.rect(14 + $0 * 16) })
    }

    static func iconChunk(_ p: TWIPayload) throws -> TWIIconChunk {
        guard p.count >= 18 else { throw ByteError.truncated }
        let flags = try p.u16(12)
        let dataOff = Int(try p.u16(14)), chunkLen = Int(try p.u16(16))
        var total: UInt32?
        if flags & 0xC0 == 0xC0 { total = try p.u32(18) }
        let start = min(dataOff, p.count)
        // Continuation chunks carry exactly chunkLen bytes; the final one is clamped to the payload.
        let n = min(chunkLen, p.count - start)
        return TWIIconChunk(windowId: try p.u32(0), processId: try p.u32(4), iconType: try p.u32(8), flags: flags,
                            totalSize: total, data: try p.data(start, n))
    }

    static func bitmapChunk(_ p: TWIPayload) throws -> TWIBitmapChunk {
        guard p.count >= 10 else { throw ByteError.truncated }
        let flags = try p.u16(4)
        let dataOff = Int(try p.u16(6)), chunkLen = Int(try p.u16(8))
        var total: UInt32?
        if flags & 0xC0 == 0xC0 { total = try p.u32(10) }
        let start = min(dataOff, p.count)
        return TWIBitmapChunk(windowId: try p.u32(0), flags: flags, totalSize: total,
                              data: try p.data(start, min(chunkLen, p.count - start)))
    }

    /// String offsets are from the payload start; the area begins at 16.
    static func processCreated(_ p: TWIPayload, utf8: Bool) throws -> TWIProcessInfo {
        guard p.count >= 16 else { throw ByteError.truncated }
        func s(_ at: Int) throws -> String {
            let off = Int(try p.u16(at))
            return off >= 16 ? p.cString(at: off, utf8: utf8) : ""
        }
        return TWIProcessInfo(
            processId: try p.u32(6), parentId: try p.u32(10), flags: try p.u16(14),
            stringA: try s(0), executablePath: try s(2), appName: try s(4))
    }
}

/// Reassembles chunked icons (0x3e) and bitmaps (0x42).
struct TWIChunkAssembler {
    private struct Key: Hashable { var window: UInt32, process: UInt32, type: UInt32 }
    private var icons: [Key: Data] = [:]
    private var bitmaps: [UInt32: Data] = [:]

    mutating func reset() { icons.removeAll(); bitmaps.removeAll() }
    var pendingCount: Int { icons.count + bitmaps.count }

    /// Returns the complete icon blob once the last chunk has arrived.
    mutating func add(_ c: TWIIconChunk) -> (windowId: UInt32, iconType: UInt32, blob: Data)? {
        let key = Key(window: c.windowId, process: c.processId, type: c.iconType)
        if c.isFirst && c.hasMore {
            icons[key] = c.data
            return nil
        }
        if c.hasMore {
            icons[key, default: Data()].append(c.data)   // continuation without a start also accumulates
            return nil
        }
        var blob = c.data
        if var pending = icons.removeValue(forKey: key) { pending.append(c.data); blob = pending }
        return (c.windowId, c.iconType, blob)
    }

    mutating func add(_ c: TWIBitmapChunk) -> (windowId: UInt32, data: Data)? {
        if c.isFirst && c.hasMore { bitmaps[c.windowId] = c.data; return nil }
        if c.hasMore { bitmaps[c.windowId, default: Data()].append(c.data); return nil }
        var blob = c.data
        if var pending = bitmaps.removeValue(forKey: c.windowId) { pending.append(c.data); blob = pending }
        return (c.windowId, blob)
    }
}
