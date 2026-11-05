import Foundation

/// A fixed part with u16 "offset" placeholders whose data is appended after the fixed part,
/// in the order the placeholders were written (docs/30-winstation.md §5.7). Offsets count from
/// the start of this writer's buffer.
struct WDOffsetWriter {
    private(set) var fixed: [UInt8] = []
    private var pending: [(at: Int, data: [UInt8])] = []

    var count: Int { fixed.count }

    mutating func u8(_ v: UInt8) { fixed.append(v) }
    mutating func u16(_ v: UInt16) { fixed += [UInt8(v & 0xff), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { fixed.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func raw(_ bytes: [UInt8]) { fixed += bytes }
    mutating func zeros(_ n: Int) { fixed += [UInt8](repeating: 0, count: n) }

    /// ASCII text in exactly `width` bytes, zero padded (truncated if longer).
    mutating func fixedText(_ text: String, width: Int) {
        var bytes = Array(text.utf8.prefix(width))
        bytes += [UInt8](repeating: 0, count: width - bytes.count)
        fixed += bytes
    }

    /// u16 placeholder referencing `data`; empty data leaves 0 and appends nothing.
    mutating func reference(_ data: [UInt8]) {
        if !data.isEmpty { pending.append((fixed.count, data)) }
        u16(0)
    }

    func bytes() -> [UInt8] {
        var out = fixed
        var position = fixed.count
        for item in pending {
            out[item.at] = UInt8(position & 0xff)
            out[item.at + 1] = UInt8((position >> 8) & 0xff)
            out += item.data
            position += item.data.count
        }
        return out
    }
}

/// Module classes and the 36-byte module header (docs/30-winstation.md §5.2).
public enum WDModuleClass: UInt8, Sendable {
    case ui = 0, wd = 2, vd = 3, pd = 4, td = 5
}

public struct WDModuleIdentity: Sendable {
    public var moduleClass: WDModuleClass
    public var versionLow: UInt8
    public var versionHigh: UInt8
    public var name: String
    public var hostName: String

    public static let wd = WDModuleIdentity(moduleClass: .wd, versionLow: 1, versionHigh: 9, name: "", hostName: "WDICA")
    public static let td = WDModuleIdentity(moduleClass: .td, versionLow: 1, versionHigh: 2, name: "", hostName: "")
    public static let framing = WDModuleIdentity(moduleClass: .pd, versionLow: 1, versionHigh: 2, name: "", hostName: "PDRFRAME")
    public static let encryption = WDModuleIdentity(moduleClass: .pd, versionLow: 1, versionHigh: 1, name: "", hostName: "PDCRYPT1")
    public static let thinwire = WDModuleIdentity(moduleClass: .vd, versionLow: 1, versionHigh: 5, name: "", hostName: "VDTW30")
    public static let twi = WDModuleIdentity(moduleClass: .vd, versionLow: 1, versionHigh: 1, name: "", hostName: "ICA")
    /// CTXCLIP: min 1 / max 0, as the reference really sends it (docs/70 §1.1, §1.2).
    public static let clipboard = WDModuleIdentity(moduleClass: .vd, versionLow: 1, versionHigh: 0, name: "", hostName: "ICA")
    public static let ui = WDModuleIdentity(moduleClass: .ui, versionLow: 1, versionHigh: 8, name: "UIModule.class", hostName: "")
}

/// Logon and client identity carried by the UI module (docs/30-winstation.md §5.6, docs/10-launch.md A.4).
/// Values from the ICA file are ticket fragments: never log them.
public struct WDLogon: Sendable {
    public var domain = ""
    public var username = ""
    public var password = ""
    public var initialProgram = ""
    public var launchReference = ""
    public var clientName = "MAC-ICA"
    public var clientVersion = "26.7.0.124"
    public var productName = "ReceiverWeb"
    public var clientBuild: UInt16 = 1
    public var keyboardLayout: UInt32 = 0x0000_0407
    public var seamless = true
    /// Font smoothing type in the UI v8 struct: 0 none, 1 standard, 2 ClearType.
    public var fontSmoothing: UInt16 = 2

    public init() {}

    /// Fields as the reference engine reads them from the launch file.
    public init(ica: ICAFile) {
        domain = ica["Domain"] ?? ""
        username = ica["Username"] ?? ""
        password = ica["ClearPassword"] ?? ""
        initialProgram = ica["InitialProgram"] ?? ""
        launchReference = ica["LaunchReference"] ?? ""
        if let name = ica["ClientName"], !name.isEmpty { clientName = name }
        if let layout = ica["KeyboardLayout"].flatMap({ UInt32($0, radix: 16) }) { keyboardLayout = layout }
        seamless = ica["TWIMode"]?.lowercased() == "on"
    }
}

public struct WDDisplay: Sendable {
    public var width: Int = 1920
    public var height: Int = 1080
    /// 8 = 24 bpp, 4 = 16 bpp (Block A fColorCaps).
    public var colorCaps: UInt16 = 8
    public var scalePercent: UInt16 = 100

    /// Monitors in session coordinates (origin = top-left of the union of all monitors), primary first.
    /// With more than one monitor the Thinwire caps carry the layout (cap 0x11, docs/40 §2.3).
    public var monitors: [WDMonitor] = []
    /// Advertise the H.264 capability group (0x0D, 0x16, 0x17, 0x18, 0x1A, 0x1C). Off = only the
    /// "compatible mode" group, as a client without an H.264 decoder would send.
    public var advertiseH264 = true

    public init(width: Int = 1920, height: Int = 1080) {
        self.width = width
        self.height = height
    }
}

/// One monitor for the Thinwire layout (cap 0x11 / C2H 0x1D): bounds and work area, exclusive right/bottom.
public struct WDMonitor: Equatable, Sendable {
    public var left: Int, top: Int, right: Int, bottom: Int
    public var workLeft: Int, workTop: Int, workRight: Int, workBottom: Int
    public var scalePercent: UInt16
    public init(left: Int, top: Int, right: Int, bottom: Int, workLeft: Int, workTop: Int, workRight: Int, workBottom: Int,
                scalePercent: UInt16 = 100) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
        self.workLeft = workLeft; self.workTop = workTop; self.workRight = workRight; self.workBottom = workBottom
        self.scalePercent = scalePercent
    }
}

/// Builds the INIT_RESPONSE module list.
public enum WDModules {
    public enum Failure: Error { case missingInitialProgram, stringTooLong(String) }

    /// Fixed channel numbers (docs/30-winstation.md §10).
    public static let fixedChannels: [String: UInt8] = [
        "CTXSCRN": 0, "CTXLPT1": 1, "CTXLPT2": 2, "CTXCPM ": 4, "CTXCOM1": 5, "CTXCOM2": 6,
        "CTXINT ": 7, "CTXCCM ": 8, "CTXTW  ": 9, "CTXCDM ": 10, "CTXSHDW": 11, "CTXTWI\0": 12,
        "CTXOEM ": 14, "CTXOEM2": 16, "CTXCLIP": 17, "CTXMM  ": 18, "CTXCAM ": 19,
    ]

    static func header(_ id: WDModuleIdentity, date: Date) -> WDOffsetWriter {
        var w = WDOffsetWriter()
        w.u16(0)  // byte count, patched by `finish`
        w.u8(0)   // modules remaining, patched by `finish`
        w.u8(id.moduleClass.rawValue)
        w.u8(id.versionLow)
        w.u8(id.versionHigh)
        w.fixedText(id.name, width: 12)
        w.u8(0)
        w.fixedText(id.hostName, width: 8)
        w.u8(0)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dosDate = (c.day! & 0x1f) | (c.month! << 5 & 0x1e0) | ((c.year! - 1980) << 9 & 0xfe00)
        let dosTime = (c.second! / 2 & 0x1f) | (c.minute! << 5 & 0x7e0) | (c.hour! << 11 & 0xf800)
        w.u16(UInt16(dosDate))
        w.u16(UInt16(dosTime))
        w.u32(0)
        return w
    }

    /// WD module (§5.3). `channels` is the VC bind table (name, number).
    public static func wd(capabilities: [WDCapability], channels: [(String, UInt8)], serial: UInt32 = 0x149A_97F5,
                          maxVirtualWrite: UInt16 = 5000, reducerVersion: UInt16 = 0, date: Date = Date()) -> [UInt8] {
        var w = header(.wd, date: date)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        w.u32(serial)
        w.u8(UInt8(c.day!))
        w.u8(UInt8(c.month!))
        w.u16(UInt16(c.year!))
        w.u8(UInt8(c.hour!))
        w.u8(UInt8(c.minute!))
        w.u8(UInt8(c.second!))
        w.u8(UInt8(min(99, c.nanosecond! / 10_000_000)))
        w.u32(0x0F)            // flags
        w.u16(0)               // count of 12-byte entries
        w.reference([])        // their offset
        w.u16(maxVirtualWrite)
        w.u16(100)             // out-buffer count host
        w.u16(100)             // out-buffer count client
        w.u16(0xFFFF)
        w.u16(0xFFFF)
        w.u16(0x0101)
        w.u32(0)
        w.u16(UInt16(channels.count))
        var table: [UInt8] = []
        for (name, number) in channels {
            var bytes = Array(name.utf8.prefix(7))
            bytes += [UInt8](repeating: 0x20, count: 7 - bytes.count)
            table += bytes + [0x00, number, 0x00]
        }
        w.reference(table)
        w.u8(0)                // reducer power (client → server)
        w.u8(0)                // expander power (server → client)
        w.u16(0)
        w.u16(reducerVersion)  // max reducer version
        let block = WDCapabilityBlock.serialize(capabilities)
        w.u16(UInt16(block.count))
        w.reference(block)
        return w.bytes()
    }

    /// TD module (§5.4). The address field is `port BE` plus IPv4 octets.
    public static func td(outBufLength: UInt16 = 1460, port: UInt16 = 443, ipv4: [UInt8] = [0, 0, 0, 0], date: Date = Date()) -> [UInt8] {
        var w = header(.td, date: date)
        w.u16(outBufLength)
        w.u16(2)
        var address: [UInt8] = [UInt8(port >> 8), UInt8(port & 0xff)] + ipv4.prefix(4)
        address += [UInt8](repeating: 0, count: 19 - address.count)
        w.raw(address)
        w.u8(0)
        return w.bytes()
    }

    public static func framing(date: Date = Date()) -> [UInt8] {
        var w = header(.framing, date: date)
        w.raw([0x09, 0, 0, 0])
        return w.bytes()
    }

    public static func encryption(date: Date = Date()) -> [UInt8] {
        var w = header(.encryption, date: date)
        w.raw([0x0B, 0, 0, 0, 0x01])
        return w.bytes()
    }

    /// Identities of VDs on fixed channels whose header differs from the generic VD (1/1, "ICA").
    /// The driver builds generic VD modules by channel; a generic identity on one of these channels
    /// is replaced here, so the module goes out as the spec says.
    static let fixedVDIdentities: [UInt8: WDModuleIdentity] = [ClipboardWire.channelNumber: .clipboard]

    /// Common VD part (§5.5): channel number (cap 0x21 negotiated), no quota, no flow control.
    static func vdHeader(_ id: WDModuleIdentity, channel: UInt8, date: Date) -> WDOffsetWriter {
        let generic = id.moduleClass == .vd && id.versionLow == 1 && id.versionHigh == 1 && id.name.isEmpty && id.hostName == "ICA"
        let identity = generic ? fixedVDIdentities[channel] ?? id : id
        var w = header(identity, date: date)
        w.u32(UInt32(channel))
        w.u8(0)
        w.u8(0)
        w.zeros(6)
        return w
    }

    public static func twi(channel: UInt8 = 12, date: Date = Date()) -> [UInt8] {
        vdHeader(.twi, channel: channel, date: date).bytes()
    }

    /// CTXCLIP module, 48 bytes, no VD-specific data (docs/70 §1.2). The bind entry
    /// `CTXCLIP\0 11 00` comes from the WD module's bind table once the engine is registered.
    public static func clipboard(channel: UInt8 = ClipboardWire.channelNumber, date: Date = Date()) -> [UInt8] {
        vdHeader(.clipboard, channel: channel, date: date).bytes()
    }

    /// Thinwire `LargeCacheSize(w,h)` (docs/40-thinwire.md §2.2).
    public static func largeCacheSize(width: Int, height: Int) -> UInt32 {
        let px = Double(width * height)
        let size: Double
        if px <= 0x1E000 { size = max(2.5 * px + 0.5, 0x19000) }
        else if px <= 0x3E800 { size = max(2 * px, 0x4B000) }
        else if px <= 0x7D000 { size = max(1.5 * px + 0.5, 0x7D000) }
        else { size = max(px, 0xBB800) }
        return UInt32(size) & ~0x7FF
    }

    static func displayBlock(width: Int, height: Int, colorCaps: UInt16) -> [UInt8] {
        var w = WDOffsetWriter()
        w.u8(2)
        w.u8(0)
        w.u16(0x8000)
        w.u32(largeCacheSize(width: width, height: height))
        w.u32(0x0000_1909)
        w.u16(colorCaps)
        w.u8(0)
        w.u8(0)
        var res = WDOffsetWriter()
        res.u16(UInt16(min(width, 0x8000)))
        res.u16(UInt16(min(height, 0x8000)))
        w.reference(res.bytes())
        w.u16(1)
        return w.bytes()
    }

    /// The H.264 phase-1 capability blob (docs/40-thinwire.md §7), with the u16 first-entry
    /// offset the reference writer puts after the count (see "Live findings" in docs/30).
    public static func thinwireCapabilities(scalePercent: UInt16 = 100) -> [UInt8] {
        thinwireCapabilities(scalePercent: scalePercent, monitors: [], h264: true)
    }

    /// Monitor layout data as in cap 0x11 (docs/40 §2.3): u32 total, u8 n, u8 primary index, 2 zero
    /// bytes, then per monitor bounds and work area as 8 × u16. The primary is index 0.
    public static func monitorLayoutData(_ monitors: [WDMonitor]) -> [UInt8] {
        var w = ByteWriter()
        w.u32(UInt32(8 + 16 * monitors.count))
        w.u8(UInt8(monitors.count)); w.u8(0); w.u8(0); w.u8(0)
        for m in monitors {
            for v in [m.left, m.top, m.right, m.bottom, m.workLeft, m.workTop, m.workRight, m.workBottom] {
                w.u16(UInt16(truncatingIfNeeded: v))
            }
        }
        return [UInt8](w.data)
    }

    /// Thinwire C2H 0x1D (monitor layout update): `3A len 1D u16 n data`, data = cap-0x11 data with its
    /// first byte set to 8 (as the reference does).
    public static func thinwireMonitorUpdate(_ monitors: [WDMonitor]) -> [UInt8] {
        var data = monitorLayoutData(monitors)
        data[0] = 8
        return WDBuild.thinwire(sub: 0x1D, [UInt8(data.count & 0xff), UInt8(data.count >> 8)] + data)
    }

    public static func thinwireCapabilities(scalePercent: UInt16, monitors: [WDMonitor], h264: Bool) -> [UInt8] {
        let scales = monitors.count > 1 ? monitors.map(\.scalePercent) : [scalePercent]
        var dpi: [UInt8] = [0x02, 0x00, UInt8(scales.count), 0x00]
        for sc in scales { dpi += [UInt8(sc & 0xff), UInt8(sc >> 8)] }
        func entry(_ id: UInt8, _ data: [UInt8] = []) -> [UInt8] {
            let n = 4 + data.count
            return [UInt8(n & 0xff), UInt8(n >> 8), id, 0x00] + data
        }
        var entries: [[UInt8]] = [entry(0x20, dpi)]
        if monitors.count > 1 { entries.append(entry(0x11, monitorLayoutData(monitors))) }
        entries += [
            [0x04, 0x00, 0x04, 0x00],
            [0x04, 0x00, 0x03, 0x00],
            [0x04, 0x00, 0x08, 0x00],
            [0x04, 0x00, 0x0E, 0x00],
            [0x04, 0x00, 0x19, 0x00],
            [0x06, 0x00, 0x10, 0x00, 0x0F, 0x00],
            [0x04, 0x00, 0x15, 0x00],
            [0x04, 0x00, 0x22, 0x00],
        ]
        if h264 { entries += [
            [0x08, 0x00, 0x0D, 0x00, 0x04, 0x00, 0x00, 0x00],
            [0x04, 0x00, 0x16, 0x00],
            [0x08, 0x00, 0x18, 0x00, 0x01, 0x00, 0x01, 0x00],
            [0x04, 0x00, 0x1C, 0x00],
            [0x08, 0x00, 0x17, 0x00, 0x02, 0x00, 0x00, 0x00],
            [0x05, 0x00, 0x1A, 0x00, 0x00],
        ] }
        return [0x00, UInt8(entries.count), 0x04, 0x00] + entries.flatMap { $0 }
    }

    /// CTXTW module: VD header, Block A (requested mode), Block B (max mode), Block C, caps blob.
    public static func thinwire(display: WDDisplay, channel: UInt8 = 9, date: Date = Date()) -> [UInt8] {
        var w = vdHeader(.thinwire, channel: channel, date: date)
        let current = largeCacheSize(width: display.width, height: display.height)
        w.raw(displayBlock(width: display.width, height: display.height, colorCaps: display.colorCaps))
        w.raw(displayBlock(width: 0x1400, height: 0x1000, colorCaps: 0x0C))
        // Block C
        w.zeros(36)
        w.u32(0x8000)
        w.u32(largeCacheSize(width: 0x1400, height: 0x1000))
        w.zeros(20)
        w.u32(8)
        var m = Int(current / 4)
        m *= display.colorCaps == 4 ? 2 : 3
        var bits = 1
        if m > 1 { var v = m; while v > 0 { bits += 1; v >>= 1 } } else { bits = 31 }
        w.u8(UInt8(bits))
        w.u8(0)
        w.u8(0x0E)
        w.u8(0)
        w.u32(UInt32((1 << bits) / 12))
        w.u32(0)
        let caps = thinwireCapabilities(scalePercent: display.scalePercent, monitors: display.monitors, h264: display.advertiseH264)
        w.u16(UInt16(caps.count))
        w.reference(caps)
        return w.bytes()
    }

    static func utf16z(_ text: String, limit: Int) throws -> [UInt8] {
        let units = Array(text.utf16)
        guard units.count <= limit else { throw Failure.stringTooLong("\(units.count) > \(limit)") }
        return units.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [0, 0]
    }

    /// UI module (§5.6). With `credentialsInModule` false the user/domain/password strings are
    /// empty and the server asks for them with 0x44 (cap 0x12 negotiated).
    public static func ui(logon: WDLogon, credentialsInModule: Bool, longCredentials: Bool, seed: UInt8,
                          date: Date = Date()) throws -> [UInt8] {
        guard !logon.initialProgram.isEmpty, logon.initialProgram != "#" else { throw Failure.missingInitialProgram }
        let credLimit = longCredentials ? 256 : 0
        var w = header(.ui, date: date)
        let fixedStart = w.count  // 36
        var flags: UInt32 = 0x01 | 0x04
        if logon.seamless { flags |= 0x10 }
        w.u32(flags)
        w.u32(logon.keyboardLayout)
        w.u8(1)     // pool obfuscated
        w.u8(seed)

        // String pool, in the order the placeholders are written; offsets are computed here because
        // the pool is obfuscated as a whole before it is attached.
        let pieces: [[UInt8]] = [
            try utf16z(credentialsInModule ? logon.domain : "", limit: max(credLimit, 17)),
            try utf16z(credentialsInModule ? logon.username : "", limit: max(credLimit, 20)),
            try utf16z(credentialsInModule ? logon.password : "", limit: max(credLimit, 14)),
            try utf16z("none", limit: 256),
            try utf16z("", limit: 256),
            try utf16z(logon.initialProgram, limit: 256),
            try utf16z(logon.clientName, limit: 20),
            try utf16z("", limit: 20),
            try utf16z(logon.productName, limit: 256),
            try utf16z(logon.clientVersion, limit: 256),
            try utf16z(logon.launchReference, limit: 256),
            [6, 0, 1, 0, UInt8(logon.fontSmoothing & 0xff), UInt8(logon.fontSmoothing >> 8)],
        ]
        let fixedEnd = fixedStart + 61  // 97: header + fixed UI fields incl. the font-struct pointer
        var offsets: [UInt16] = []
        var position = fixedEnd
        for piece in pieces {
            offsets.append(UInt16(position))
            position += piece.count
        }
        var pool = pieces.flatMap { $0 }
        WDObfuscation.obfuscate(&pool, seed: seed)

        w.u16(offsets[0])   // @46 domain
        w.u16(offsets[1])   // @48 user
        w.u16(offsets[2])   // @50 password
        w.u16(offsets[3])   // @52 "none"
        w.u16(offsets[4])   // @54 ""
        w.u16(offsets[5])   // @56 initial program
        w.zeros(6)          // @58
        w.u16(0)            // @64 no string
        w.u16(logon.clientBuild)  // @66
        w.u16(offsets[6])   // @68 client name
        w.u16(UInt16(fixedEnd))   // @70
        w.u16(UInt16(pool.count)) // @72
        w.u16(offsets[7])   // @74 ""
        w.u16(1)            // @76 encoding unicode
        w.u16(0)            // @78
        w.u16(0x0000)       // @80 low half of 0x000C0000
        w.u8(0x00)          // @82
        w.u8(0x0C)          // @83
        w.u16(0)            // @84
        w.u16(0)            // @86
        w.u16(offsets[8])   // @88 product
        w.u16(offsets[9])   // @90 version
        w.u8(0x10)          // @92
        w.u16(offsets[10])  // @93 launch reference
        w.u16(offsets[11])  // @95 font smoothing struct
        precondition(w.count == fixedEnd)
        w.raw(pool)
        return w.bytes()
    }

    /// Patches byte count and "modules remaining" into each module and wraps it as `01 <u16 len> module`.
    public static func initResponsePackets(_ modules: [[UInt8]]) -> [[UInt8]] {
        modules.enumerated().map { index, module in
            var m = module
            m[0] = UInt8(m.count & 0xff)
            m[1] = UInt8(m.count >> 8)
            m[2] = UInt8(modules.count - 1 - index)
            return [0x01, UInt8(m.count & 0xff), UInt8(m.count >> 8)] + m
        }
    }
}
