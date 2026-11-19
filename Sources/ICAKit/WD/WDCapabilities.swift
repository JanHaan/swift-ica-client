import Foundation

/// One WD capability: `u16 length (incl. 4-byte header) | u16 id | body` (docs/30-winstation.md §4.1).
public struct WDCapability: Equatable, Sendable, CustomStringConvertible {
    public var id: UInt16
    public var body: [UInt8]

    public init(id: UInt16, body: [UInt8] = []) {
        self.id = id
        self.body = body
    }

    public static let reducer: UInt16 = 0x02
    public static let twi: UInt16 = 0x03
    public static let input: UInt16 = 0x04
    public static let vcPriority: UInt16 = 0x05
    public static let channelMonitoring: UInt16 = 0x06
    public static let timeZone: UInt16 = 0x08
    public static let longCredentials: UInt16 = 0x09
    public static let acrCookie: UInt16 = 0x0A
    public static let hostOS: UInt16 = 0x0D
    public static let highThroughput: UInt16 = 0x10
    public static let credentialRequest: UInt16 = 0x12
    public static let unicodeKeyboard: UInt16 = 0x14
    public static let vcCount: UInt16 = 0x21
    public static let secureHDX: UInt16 = 0x31

    public var bytes: [UInt8] {
        let length = body.count + 4
        return [UInt8(length & 0xff), UInt8(length >> 8), UInt8(id & 0xff), UInt8(id >> 8)] + body
    }

    func u16(at offset: Int) -> UInt16? {
        guard body.count >= offset + 2 else { return nil }
        return UInt16(body[offset]) | UInt16(body[offset + 1]) << 8
    }

    public var description: String {
        let hex = body.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        return String(format: "0x%02x", id) + "[\(body.count)]" + (body.isEmpty ? "" : " " + hex + (body.count > 24 ? " …" : ""))
    }
}

public enum WDCapabilityBlock {
    public enum Failure: Error { case truncated, badEntry(Int) }

    /// Block: `u8 0, u8 count, u16 offset of first capability (from block start)`, then capabilities.
    public static func parse(_ bytes: [UInt8], from start: Int = 0) throws -> [WDCapability] {
        guard bytes.count >= start + 4 else { throw Failure.truncated }
        let count = Int(bytes[start + 1])
        var offset = start + Int(UInt16(bytes[start + 2]) | UInt16(bytes[start + 3]) << 8)
        var caps: [WDCapability] = []
        for index in 0..<count {
            guard bytes.count >= offset + 4 else { throw Failure.truncated }
            let length = Int(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            let id = UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8
            guard length >= 4, bytes.count >= offset + length else { throw Failure.badEntry(index) }
            caps.append(WDCapability(id: id, body: Array(bytes[(offset + 4)..<(offset + length)])))
            offset += length
        }
        return caps
    }

    public static func serialize(_ caps: [WDCapability]) -> [UInt8] {
        var out: [UInt8] = [0x00, UInt8(caps.count), 0x04, 0x00]
        for cap in caps { out += cap.bytes }
        return out
    }
}

/// What the client wants, and the rule that turns the server's INIT_REQUEST list into the
/// negotiated list we send back (docs/30-winstation.md §4.2-4.3, §16).
public struct WDCapabilityPolicy: Sendable {
    /// Reducer flags offered. 0x0C = V3, used with both powers 0 (no compressed segments).
    /// Flags 0 (version 0) made the VDA drop the connection right after INIT_RESPONSE (live, docs/30 "Live findings").
    public var reducerFlags: UInt16 = 0x0C
    /// Negotiate cap 0x12: logon strings travel in the 0x44 reply instead of the UI module.
    public var credentialRequest = true
    public var unicodeKeyboard = true
    public var maxChannels: UInt16 = 0x40
    /// Negotiate cap 0x10 (high throughput) when the server offers it: body u32 flags 0, u16 1460, u16 0 [I], which
    /// turns the HT frame header on (docs/30 §8.3). Off by default (docs/30 recommends not to); `ICA_WD_HT=1` in
    /// icactl is the docs/76 §7.1 V2 discovery variant.
    public var highThroughput = false
    /// Negotiate cap 0x0D (host OS info) with this client OS value (1 Windows, 2 Linux, 3 Mac) and two zero u16s
    /// instead of leaving it out (docs/30 §4.3; the reference sends three zeros). nil = left out (default); discovery
    /// only (docs/76 §7.8 V18, `ICA_WD_OSCAP`).
    public var hostOSReply: UInt16?
    /// Negotiate cap 0x21 (VC count). Off: every VD module carries the channel as the bit mask `1 << n` (docs/30
    /// §5.5) and only channels < 32 work. On by default; off only for docs/76 §7.9 V21 (`ICA_WD_VCMASK=1`).
    public var vcCountCapability = true
    /// Server capabilities we otherwise drop, echoed with the server's body (discovery only, docs/76 §7.9 V22). Empty
    /// by default.
    public var echoCapabilities: Set<UInt16> = []
    /// Negotiate cap 0x1E as docs/30 §4.3 describes the reference: the server's body with cap byte 4 (body byte 0) := 1
    /// and the u32 at cap offset 5 := 3. The stock client sends a 29-byte cap in the 0x1E slot [B]. Off by default
    /// (discovery only, docs/76 §7.12, icactl `ICA_WD_CAP1E=1`).
    public var capability1E = false
    /// Cap 0x12 as the stock client builds it: a 6-byte cap with this u16 version (stock: "set wd credential passing
    /// version 2", 6 B [B], docs/76 §7.13). nil (default) = the reference's u8 version 0 (5 B). Discovery only (icactl
    /// `ICA_WD_CREDVER`). [I] Version 2 may change how the host asks for credentials (the server offers 3 and logs no
    /// layout); a refused logon is the expected failure.
    public var credentialVersion: UInt16?
    /// Cap 0x14 body as u16 version, u16 mode (stock: "g_iEUKSversion 3", 8 B [B], docs/76 §7.13). nil (default) = the
    /// reference's version min(server, 1), mode 1. Discovery only (icactl `ICA_WD_EUKS=V[:M]`).
    public var unicodeKeyboardReply: (version: UInt16, mode: UInt16)?

    /// Advertise cap 0x0A (ACR cookie, docs/30 §4.3, §15.6) when the server offers it, with `acrReplyBody`. The host then
    /// hands out an ACR cookie (0x41 sub 1) and enables auto client reconnect (`WDACRParameters`).
    public var acr = false
    /// Cap 0x0A body we send. Default: the stock client's form `02 00 80 00` + 8 zero bytes (version 2, field a = 0x80,
    /// black-box D84). With the reference's 12 zero bytes the host negotiated acrTimeout 120 s but never sent a cookie
    /// (live, D84 run 1).
    public var acrReplyBody: [UInt8] = WDCapabilityPolicy.acrStockBody

    /// Caps 0x08 and 0x26 (docs/30 §4.4): when the server offers them, this zone goes back in the stock client's form
    /// (Windows key name, bias, transition rules; 0x26 adds the IANA name). The VDA uses it if its policy "Use local time
    /// of client" says so. Resolved at each INIT_REQUEST, so a later connection of the same session sends the zone of
    /// that moment. nil = left out (the session keeps the server's zone).
    public var timeZone: TimeZone? = .autoupdatingCurrent

    public static let acrStockBody: [UInt8] = [0x02, 0x00, 0x80, 0x00] + [UInt8](repeating: 0, count: 8)
    public static let acrReferenceBody = [UInt8](repeating: 0, count: 12)

    public static let cap1E: UInt16 = 0x1E

    /// The 0x1E reply body for a server body (nil if the body is shorter than 5 bytes).
    public static func reply1E(server body: [UInt8]) -> [UInt8]? {
        guard body.count >= 5 else { return nil }
        var out = body
        out[0] = 1
        out[1] = 3; out[2] = 0; out[3] = 0; out[4] = 0
        return out
    }

    public init() {}

    /// Reducer version implied by negotiated cap 0x02 flags: 0x10 → 4, 0x04/0x08 → 3, 0x02 → 2, else 0.
    public static func reducerVersion(_ caps: [WDCapability]) -> UInt16 {
        guard let flags = caps.first(where: { $0.id == WDCapability.reducer })?.u16(at: 0) else { return 0 }
        if flags & 0x10 != 0 { return 4 }
        if flags & 0x0C != 0 { return 3 }
        if flags & 0x02 != 0 { return 2 }
        return 0
    }

    /// For each server capability (in server order) that we also support, the negotiated value.
    /// Duplicates keep the first; cap 0x05 is appended at the end, as the reference client does.
    public func negotiate(server: [WDCapability], now: Date = Date()) -> [WDCapability] {
        var out: [WDCapability] = []
        var seen: Set<UInt16> = []
        let zone = timeZone.map { WDTimeZone($0, now: now) }
        for cap in server where !seen.contains(cap.id) {
            var result: WDCapability?
            switch cap.id {
            case WDCapability.timeZone where zone != nil:
                result = WDCapability(id: cap.id, body: zone!.capability08Body)
            case WDTimeZone.extendedCapability where zone != nil:
                result = WDCapability(id: cap.id, body: zone!.capability26Body)
            case WDCapability.reducer:
                let flags = (cap.u16(at: 0) ?? 0) & reducerFlags
                result = WDCapability(id: cap.id, body: [UInt8(flags & 0xff), UInt8(flags >> 8)])
            case WDCapability.longCredentials:
                result = WDCapability(id: cap.id)
            case WDCapability.credentialRequest where credentialRequest:
                if let v = credentialVersion {
                    result = WDCapability(id: cap.id, body: [UInt8(v & 0xff), UInt8(v >> 8)])
                } else {
                    result = WDCapability(id: cap.id, body: [min(cap.body.first ?? 0, 0)])
                }
            case WDCapability.unicodeKeyboard where unicodeKeyboard:
                if let r = unicodeKeyboardReply {
                    result = WDCapability(id: cap.id, body: [UInt8(r.version & 0xff), UInt8(r.version >> 8),
                                                            UInt8(r.mode & 0xff), UInt8(r.mode >> 8)])
                } else {
                    // Client offers version 1, mode 1; the reference reads single bytes at body 0 and 2.
                    let version = min(cap.body.first ?? 1, 1)
                    result = WDCapability(id: cap.id, body: [version, 0, 1, 0])
                }
            case WDCapability.acrCookie where acr:
                result = WDCapability(id: cap.id, body: acrReplyBody)
            case WDCapability.hostOS where hostOSReply != nil:
                let os = hostOSReply ?? 0
                result = WDCapability(id: cap.id, body: [UInt8(os & 0xff), UInt8(os >> 8), 0, 0, 0, 0])
            case WDCapability.highThroughput where highThroughput:
                result = WDCapability(id: cap.id, body: [0, 0, 0, 0, 0xB4, 0x05, 0, 0])
            case WDCapability.vcCount where vcCountCapability:
                let n = min(cap.u16(at: 0) ?? maxChannels, maxChannels)
                result = WDCapability(id: cap.id, body: [UInt8(n & 0xff), UInt8(n >> 8)])
            case Self.cap1E where capability1E:
                result = Self.reply1E(server: cap.body).map { WDCapability(id: cap.id, body: $0) }
            case let id where echoCapabilities.contains(id) && id != WDCapability.vcCount:
                result = WDCapability(id: cap.id, body: cap.body)
            default:
                result = nil
            }
            if let result {
                out.append(result)
                seen.insert(cap.id)
            }
        }
        out.append(WDCapability(id: WDCapability.vcPriority))
        return out
    }
}

/// Cap 0x0A body (docs/30 §15.6): `u8 version, u8 0, u16 a, u16 acrTimeout (s), u16 b, u16 c, u16 estimatedTcpTimeout (s)`.
/// The host's copy in the final capability list (INIT_CONNECT) carries the values; a, b, c are [I].
public struct WDACRParameters: Equatable, Sendable, CustomStringConvertible {
    public var version: UInt8
    public var a: UInt16
    public var acrTimeout: UInt16
    public var b: UInt16
    public var c: UInt16
    public var estimatedTcpTimeout: UInt16

    public init(version: UInt8, a: UInt16 = 0, acrTimeout: UInt16, b: UInt16 = 0, c: UInt16 = 0, estimatedTcpTimeout: UInt16 = 0) {
        self.version = version
        self.a = a
        self.acrTimeout = acrTimeout
        self.b = b
        self.c = c
        self.estimatedTcpTimeout = estimatedTcpTimeout
    }

    public init?(_ cap: WDCapability) {
        guard cap.id == WDCapability.acrCookie, cap.body.count >= 12, let a = cap.u16(at: 2), let t = cap.u16(at: 4),
              let b = cap.u16(at: 6), let c = cap.u16(at: 8), let tcp = cap.u16(at: 10) else { return nil }
        self.init(version: cap.body[0], a: a, acrTimeout: t, b: b, c: c, estimatedTcpTimeout: tcp)
    }

    /// From a capability list (the first cap 0x0A).
    public init?(_ caps: [WDCapability]) {
        guard let cap = caps.first(where: { $0.id == WDCapability.acrCookie }) else { return nil }
        self.init(cap)
    }

    /// ACR is on when the negotiated timeout is greater than 0 (docs/30 §15.6).
    public var enabled: Bool { acrTimeout > 0 }

    public var description: String {
        "version \(version), acrTimeout \(acrTimeout) s, estimatedTcpTimeout \(estimatedTcpTimeout) s, a \(a), b \(b), c \(c)"
    }
}

/// The parts of the server's INIT_REQUEST we act on.
public struct WDInitRequest: Sendable {
    public var level: UInt8
    public var capabilities: [WDCapability]

    public init(payload: [UInt8]) throws {
        guard let first = payload.first else { throw WDCapabilityBlock.Failure.truncated }
        level = first
        capabilities = payload.count > 1 ? try WDCapabilityBlock.parse(payload, from: 1) : []
    }

    public func capability(_ id: UInt16) -> WDCapability? { capabilities.first { $0.id == id } }

    /// Server cap 0x04 bit 0: extended (wheel) mouse records allowed.
    public var extendedMouse: Bool { (capability(WDCapability.input)?.u16(at: 0) ?? 0) & 0x01 != 0 }

    /// Server cap 0x0D: 1 Windows, 2 Linux, 3 Mac.
    public var hostOS: UInt16? { capability(WDCapability.hostOS)?.u16(at: 0) }
}

/// The high-throughput frame header (docs/30 §8.3): `flags u8 [bandwidth u16 if 0x10] [rtt u16 if 0x08] payload`,
/// inside encryption and outside compression.
public enum WDHighThroughput {
    public static let flagBandwidth: UInt8 = 0x10
    public static let flagRTT: UInt8 = 0x08
    /// The receiver answers with `3F 01 04`.
    public static let flagAnswer: UInt8 = 0x04
    public static let flagInterrupted: UInt8 = 0x80
    public static let answer: [UInt8] = [0x3F, 0x01, 0x04]

    /// Payload after the header, and the flags; nil if the frame is shorter than its header.
    public static func strip(_ frame: [UInt8]) -> ([UInt8], UInt8)? {
        guard let flags = frame.first else { return nil }
        var at = 1
        if flags & flagBandwidth != 0 { at += 2 }
        if flags & flagRTT != 0 { at += 2 }
        guard frame.count >= at else { return nil }
        return (Array(frame[at...]), flags)
    }
}
