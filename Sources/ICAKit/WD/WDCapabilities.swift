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
    public func negotiate(server: [WDCapability]) -> [WDCapability] {
        var out: [WDCapability] = []
        var seen: Set<UInt16> = []
        for cap in server where !seen.contains(cap.id) {
            var result: WDCapability?
            switch cap.id {
            case WDCapability.reducer:
                let flags = (cap.u16(at: 0) ?? 0) & reducerFlags
                result = WDCapability(id: cap.id, body: [UInt8(flags & 0xff), UInt8(flags >> 8)])
            case WDCapability.longCredentials:
                result = WDCapability(id: cap.id)
            case WDCapability.credentialRequest where credentialRequest:
                result = WDCapability(id: cap.id, body: [min(cap.body.first ?? 0, 0)])
            case WDCapability.unicodeKeyboard where unicodeKeyboard:
                // Client offers version 1, mode 1; the reference reads single bytes at body 0 and 2.
                let version = min(cap.body.first ?? 1, 1)
                result = WDCapability(id: cap.id, body: [version, 0, 1, 0])
            case WDCapability.highThroughput where highThroughput:
                result = WDCapability(id: cap.id, body: [0, 0, 0, 0, 0xB4, 0x05, 0, 0])
            case WDCapability.vcCount:
                let n = min(cap.u16(at: 0) ?? maxChannels, maxChannels)
                result = WDCapability(id: cap.id, body: [UInt8(n & 0xff), UInt8(n >> 8)])
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
