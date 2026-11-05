import Foundation

/// WD packet types (docs/30-winstation.md §9.2). Names are ours.
public enum WDPacketType {
    public static let initRequest: UInt8 = 0x00
    public static let initResponse: UInt8 = 0x01
    public static let initConnect: UInt8 = 0x02
    public static let initConnectResponse: UInt8 = 0x04
    public static let terminate: UInt8 = 0x05
    public static let redraw: UInt8 = 0x06
    public static let keyboardScancode: UInt8 = 0x0A
    public static let keyboardMultiScancode: UInt8 = 0x0B
    public static let mouseSingle: UInt8 = 0x0D
    public static let mouse8: UInt8 = 0x0E
    public static let mouse16: UInt8 = 0x0F
    public static let setMousePosition: UInt8 = 0x1C
    public static let virtualWrite1: UInt8 = 0x2F
    public static let virtualWrite8: UInt8 = 0x30
    public static let virtualWrite16: UInt8 = 0x31
    public static let virtualAck: UInt8 = 0x32
    public static let nop: UInt8 = 0x35
    public static let setLED: UInt8 = 0x37
    public static let thinwireReply: UInt8 = 0x3A
    public static let sessionInfo: UInt8 = 0x3B
    public static let unicodeKey: UInt8 = 0x3C
    public static let extendedMouse8: UInt8 = 0x3D
    public static let extendedMouse16: UInt8 = 0x3E
    public static let channelMonitor: UInt8 = 0x3F
    public static let acrCookie: UInt8 = 0x41
    public static let resumeVirtualWrite: UInt8 = 0x43
    public static let command: UInt8 = 0x44

    public static func isVirtualWrite(_ type: UInt8) -> Bool {
        type == virtualWrite1 || type == virtualWrite8 || type == virtualWrite16 || type == resumeVirtualWrite
    }

    /// Receive-side length encoding per type (reference table, docs/30 §9.1-9.2).
    public enum Encoding: Equatable { case l16, l8, fixed(Int), bad }

    private static let table: [Int] = {
        let L16 = -2, L8 = -3, B = -1
        return [
            L16, B, L16, B, B, L8, B, B, 0, B, B, B, B, B, B, B,        // 0x00-0x0F
            1, B, 3, B, 1, L8, L16, L8, L16, 5, 6, 4, 4, 1, 2, 1,       // 0x10-0x1F
            1, 1, 1, 7, 7, 7, 7, 0, 0, 0, 0, 1, 1, 1, 1, 1,             // 0x20-0x2F
            L8, L16, B, L8, L8, L8, 3, 1, 2, B, L16, L16, B, B, B, L8,  // 0x30-0x3F
            B, L16, B, L16, L16,                                        // 0x40-0x44
        ]
    }()

    public static func encoding(_ type: UInt8) -> Encoding {
        guard Int(type) < table.count else { return .bad }
        switch table[Int(type)] {
        case -2: return .l16
        case -3: return .l8
        case -1: return .bad
        case let n: return .fixed(n)
        }
    }

    public static func name(_ type: UInt8) -> String {
        switch type {
        case 0x00: "INIT_REQUEST"
        case 0x02: "INIT_CONNECT"
        case 0x05: "TERMINATE"
        case 0x1C: "SET_MOUSE_POS"
        case 0x2F, 0x30, 0x31: "VIRTUAL_WRITE"
        case 0x35: "NOP"
        case 0x37: "SET_LED"
        case 0x3B: "SESSION_INFO"
        case 0x3F: "CHANNEL_MONITOR"
        case 0x41: "ACR_COOKIE"
        case 0x43: "RESUME_VIRTUAL_WRITE"
        case 0x44: "COMMAND"
        default: String(format: "0x%02X", type)
        }
    }
}

/// A complete server packet. For virtual writes `channel` is set and `payload` is the channel data.
public struct WDPacket: Equatable, Sendable {
    public var type: UInt8
    public var channel: UInt8?
    public var payload: [UInt8]
}

/// Streaming parser for the WD command stream. Packets may span input chunks (frames).
/// An unknown type discards the rest of the current chunk, like the reference.
public struct WDStreamParser {
    private enum State { case type, len8, len16lo, len16hi(UInt8), payload }
    private var state = State.type
    private var type: UInt8 = 0
    private var size = 0
    private var buffer: [UInt8] = []
    private var skipNext = false
    public private(set) var badTypes = 0

    public init() {}

    public mutating func reset() {
        state = .type
        buffer = []
        skipNext = false
    }

    /// Parses `bytes`; `stop` is consulted after each packet and, when it returns true, parsing stops
    /// and the unconsumed tail is returned (used when the stream switches to framed mode).
    public mutating func feed(_ bytes: [UInt8], stop: (WDPacket) -> Bool = { _ in false }) -> (packets: [WDPacket], rest: [UInt8]) {
        var packets: [WDPacket] = []
        var i = 0
        while i < bytes.count {
            if skipNext { skipNext = false; i += 1; continue }
            switch state {
            case .type:
                type = bytes[i]
                i += 1
                if type == WDPacketType.nop { skipNext = true; continue }
                switch WDPacketType.encoding(type) {
                case .bad:
                    badTypes += 1
                    return (packets, [])
                case .l8: state = .len8
                case .l16: state = .len16lo
                case .fixed(let n):
                    // Virtual write 0x2F: channel byte plus `n` data bytes.
                    size = n + (type == WDPacketType.virtualWrite1 ? 1 : 0)
                    buffer = []
                    state = .payload
                }
            case .len8:
                size = Int(bytes[i]); i += 1
                buffer = []
                state = .payload
            case .len16lo:
                state = .len16hi(bytes[i]); i += 1
            case .len16hi(let lo):
                size = Int(lo) | Int(bytes[i]) << 8; i += 1
                buffer = []
                state = .payload
            case .payload:
                let take = min(size - buffer.count, bytes.count - i)
                buffer += bytes[i..<(i + take)]
                i += take
            }
            if case .payload = state, buffer.count == size {
                let packet = Self.makePacket(type: type, body: buffer)
                packets.append(packet)
                state = .type
                buffer = []
                if stop(packet) { return (packets, Array(bytes[i...])) }
            }
        }
        // A packet with an empty payload that completes exactly at the end of input.
        if case .payload = state, buffer.count == size {
            packets.append(Self.makePacket(type: type, body: buffer))
            state = .type
            buffer = []
        }
        return (packets, [])
    }

    private static func makePacket(type: UInt8, body: [UInt8]) -> WDPacket {
        if WDPacketType.isVirtualWrite(type), let channel = body.first {
            return WDPacket(type: type, channel: channel, payload: Array(body.dropFirst()))
        }
        return WDPacket(type: type, channel: nil, payload: body)
    }
}

/// Client → server packet builders (docs/30-winstation.md §9-§15).
public enum WDBuild {
    static func l16(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count & 0xff), UInt8(body.count >> 8)] + body
    }

    public static let initConnectResponse: [UInt8] = [0x04, 0x00, 0x00]
    public static let terminateAck: [UInt8] = [0x05, 0x01, 0x02]
    public static let pingResponse: [UInt8] = [0x3F, 0x01, 0x02]

    /// VC write with the smallest header: `2F ch b`, `30 n ch data`, `31 n16 ch data` (n counts ch).
    public static func virtualWrite(channel: UInt8, _ data: [UInt8]) -> [UInt8] {
        if data.count == 1 { return [0x2F, channel, data[0]] }
        if data.count + 1 <= 0xFF { return [0x30, UInt8(data.count + 1), channel] + data }
        precondition(data.count + 1 <= 0xFFFF)
        return [0x31, UInt8((data.count + 1) & 0xff), UInt8((data.count + 1) >> 8), channel] + data
    }

    /// VC flow-control ACK `32 ch u16`.
    public static func virtualAck(channel: UInt8, value: UInt16) -> [UInt8] {
        [0x32, channel, UInt8(value & 0xff), UInt8(value >> 8)]
    }

    public static func scancode(_ code: UInt8, up: Bool) -> [UInt8] { [0x0A, up ? code | 0x80 : code] }

    /// Multi-byte scancode, e.g. `[0xE0, 0x4B]`. Key up sets 0x80 on packet bytes 3 (and 4).
    public static func multiScancode(_ codes: [UInt8], up: Bool) -> [UInt8] {
        precondition(codes.count == 2 || codes.count == 3)
        var p: [UInt8] = [0x0B, UInt8(codes.count)] + codes
        if up {
            p[3] |= 0x80
            if codes.count == 3 { p[4] |= 0x80 }
        }
        return p
    }

    public struct UnicodeFlags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let up = UnicodeFlags(rawValue: 1)
        public static let special = UnicodeFlags(rawValue: 2)
        public static let insert = UnicodeFlags(rawValue: 4)
    }

    /// `3C 03 00 flags u16` — one UTF-16 unit.
    public static func unicodeKey(_ unit: UInt16, flags: UnicodeFlags) -> [UInt8] {
        [0x3C, 0x03, 0x00, flags.rawValue, UInt8(unit & 0xff), UInt8(unit >> 8)]
    }

    public static func setLED(_ mask: UInt8) -> [UInt8] { [0x37, mask] }

    public struct MouseState: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let moved = MouseState(rawValue: 0x01)
        public static let leftDown = MouseState(rawValue: 0x02)
        public static let leftUp = MouseState(rawValue: 0x04)
        public static let rightDown = MouseState(rawValue: 0x08)
        public static let rightUp = MouseState(rawValue: 0x10)
        public static let middleDown = MouseState(rawValue: 0x20)
        public static let middleUp = MouseState(rawValue: 0x40)
    }

    public struct MouseRecord: Sendable {
        public var x: UInt16, y: UInt16, state: MouseState
        public init(x: UInt16, y: UInt16, state: MouseState) { self.x = x; self.y = y; self.state = state }
    }

    /// Absolute pixel position → the 0..65536 normalised coordinate (docs/30 §14.2).
    public static func normalise(x: Int, y: Int, width: Int, height: Int) -> (UInt16, UInt16) {
        var px = x
        if px <= 1 { px = 0 } else if px >= width - 2 { px = width - 1 }
        let py = min(max(y, 0), height - 1)
        let nx = min(65535, 65536 * px / max(width, 1) + 1)
        let ny = min(65535, 65536 * py / max(height, 1) + 1)
        return (UInt16(nx), UInt16(ny))
    }

    public static func mouse(_ records: [MouseRecord]) -> [UInt8] {
        let body = records.flatMap { [UInt8($0.x & 0xff), UInt8($0.x >> 8), UInt8($0.y & 0xff), UInt8($0.y >> 8), $0.state.rawValue] }
        if records.count == 1 { return [0x0D] + body }
        if body.count <= 0xFF { return [0x0E, UInt8(body.count)] + body }
        return [0x0F, UInt8(body.count & 0xff), UInt8(body.count >> 8)] + body
    }

    /// Vertical wheel (state 0x20, amount = delta); requires server cap 0x04 bit 0.
    public static func wheel(x: UInt16, y: UInt16, delta: Int16) -> [UInt8] {
        let amount = UInt16(bitPattern: delta)
        let record: [UInt8] = [8, UInt8(x & 0xff), UInt8(x >> 8), UInt8(y & 0xff), UInt8(y >> 8), 0x20,
                               UInt8(amount & 0xff), UInt8(amount >> 8)]
        return [0x3D, UInt8(record.count)] + record
    }

    /// Redraw request: four 12-bit values packed into 6 bytes (right/bottom exclusive).
    public static func redraw(left: Int, top: Int, right: Int, bottom: Int) -> [UInt8] {
        func pack(_ a: Int, _ b: Int) -> [UInt8] {
            [UInt8(a & 0xff), UInt8((a >> 8) & 0x0f) | UInt8((b & 0x0f) << 4), UInt8((b >> 4) & 0xff)]
        }
        return [0x06, 0x06, 0x00] + pack(left, top) + pack(right, bottom)
    }

    /// Credential reply `44 len 02 01` + three 4-byte offsets (user, domain, password) + UTF-16 strings.
    public static func credentials(username: String, domain: String, password: String, limit: Int = 256) -> [UInt8] {
        func z(_ s: String) -> [UInt8] { Array(s.utf16.prefix(limit)).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [0, 0] }
        let strings = [z(username), z(domain), z(password)]
        var block: [UInt8] = []
        var offset = 12
        for s in strings {
            block += [UInt8(offset & 0xff), 0, UInt8((offset >> 8) & 0xff), 0]
            offset += s.count
        }
        block += strings.flatMap { $0 }
        return l16(0x44, [0x02, 0x01] + block)
    }

    /// Thinwire C2H packet `3A len16 sub data` (docs/40-thinwire.md §4.1).
    public static func thinwire(sub: UInt8, _ data: [UInt8]) -> [UInt8] { l16(0x3A, [sub] + data) }
}
