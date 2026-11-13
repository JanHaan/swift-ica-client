import Foundation

// Early drops (notes/early-drop-analysis.md): pattern A, the peer closes 20–70 ms after our
// INIT_CONNECT_RESPONSE with no WD TERMINATE and no CGP FINISH; pattern B, WD TERMINATE before the
// first Thinwire INIT (the host refused a second or held session for this user). Plus the NumLock
// SET_LED gate (H1: never a framed packet before the host's first framed packet) and a small packet
// ring for the diagnostics, with a redaction policy: no credentials, logon strings, keys or channel data.

// MARK: - SET_LED gate

/// NumLock on (SET_LED 0x20) only after the host spoke first in framed mode, or on the first key event,
/// never right behind INIT_CONNECT_RESPONSE as the old viewer did (the reference sends it from
/// keyboard handling only). Session queue.
public struct LEDGate: Equatable, Sendable {
    public enum Trigger: Equatable, Sendable {
        case hostPacket(UInt8)
        case keyEvent

        public var description: String {
            switch self {
            case .hostPacket(let type): String(format: "the host's first framed packet (WD 0x%02x)", type)
            case .keyEvent: "the first key event"
            }
        }
    }

    private var connected = false
    public private(set) var sentAfter: Trigger?

    public init() {}

    /// INIT_CONNECT_RESPONSE went out: framed mode starts, nothing is sent yet.
    public mutating func connectResponseSent() { connected = true }

    /// A host packet; true once, when the LED is due now.
    public mutating func hostPacket(type: UInt8) -> Bool { fire(.hostPacket(type)) }

    /// A key event; true once, when the LED is due now.
    public mutating func keyEvent() -> Bool { fire(.keyEvent) }

    private mutating func fire(_ trigger: Trigger) -> Bool {
        guard connected, sentAfter == nil else { return false }
        sentAfter = trigger
        return true
    }
}

// MARK: - Drop classification

public struct EarlyDrop: Equatable, Sendable {
    public enum Pattern: String, Sendable {
        /// Closed after INIT_CONNECT_RESPONSE, before any framed host packet, no TERMINATE.
        case a = "A"
        /// WD TERMINATE before the first Thinwire INIT.
        case b = "B"
        /// Closed after the host's first framed packets, without TERMINATE, before Thinwire INIT.
        case afterHostPackets = "A-late"
        /// Closed before INIT_CONNECT_RESPONSE (bind, TLS, handshake).
        case beforeConnect = "before-connect"
    }

    public var pattern: Pattern
    /// From INIT_CONNECT_RESPONSE to the close (A) or to the TERMINATE (B).
    public var milliseconds: Int?
    public var terminateReason: UInt8?

    public var summary: String {
        "early drop pattern \(pattern.rawValue)"
            + (milliseconds.map { pattern == .b ? ", TERMINATE \($0) ms after INIT_CONNECT_RESPONSE" : ", closed \($0) ms after INIT_CONNECT_RESPONSE" } ?? "")
            + (terminateReason.map { ", reason \($0)" } ?? "")
    }
}

/// Records the handshake milestones of one connection (session queue) and classifies its end.
public struct EarlyDropMonitor: Equatable, Sendable {
    public private(set) var connectResponseAt: Date?
    public private(set) var firstHostFramedAt: Date?
    public private(set) var terminateAt: Date?
    public private(set) var terminateReason: UInt8?
    public private(set) var thinwireInitAt: Date?

    public init() {}

    public mutating func connectResponseSent(at now: Date = Date()) { if connectResponseAt == nil { connectResponseAt = now } }

    /// A host packet; framed if INIT_CONNECT_RESPONSE went out before it.
    public mutating func hostPacket(at now: Date = Date()) {
        if connectResponseAt != nil, firstHostFramedAt == nil { firstHostFramedAt = now }
    }

    public mutating func terminate(_ reason: UInt8, at now: Date = Date()) {
        if terminateAt == nil, thinwireInitAt == nil { terminateAt = now; terminateReason = reason }
    }

    public mutating func thinwireInit(at now: Date = Date()) { if thinwireInitAt == nil { thinwireInitAt = now } }

    /// nil once the session was established (a Thinwire INIT arrived): not an early drop.
    public func classify(closedAt: Date = Date()) -> EarlyDrop? {
        guard thinwireInitAt == nil else { return nil }
        func ms(_ from: Date?, _ to: Date) -> Int? { from.map { Int((to.timeIntervalSince($0) * 1000).rounded()) } }
        if let terminateAt {
            return EarlyDrop(pattern: .b, milliseconds: ms(connectResponseAt, terminateAt), terminateReason: terminateReason)
        }
        guard connectResponseAt != nil else { return EarlyDrop(pattern: .beforeConnect) }
        return EarlyDrop(pattern: firstHostFramedAt == nil ? .a : .afterHostPackets, milliseconds: ms(connectResponseAt, closedAt))
    }
}

// MARK: - Packet ring (diagnostics)

/// The last packets in each direction, as redacted one-line descriptions. Session queue.
public struct PacketRing: Sendable {
    public let capacity: Int
    public private(set) var inbound: [String] = []
    public private(set) var outbound: [String] = []
    private let start = Date()

    public init(capacity: Int = 8) { self.capacity = capacity }

    public mutating func received(_ packet: WDPacket, at now: Date = Date()) {
        let line = stamp(now) + PacketDump.inbound(packet)
        push(&inbound, line)
    }

    /// One complete outbound WD packet (type byte first).
    public mutating func sent(_ packet: [UInt8], at now: Date = Date()) {
        let line = stamp(now) + PacketDump.outbound(packet)
        push(&outbound, line)
    }

    /// A handshake write (unframed WD packet): its type and length only, INIT_CONNECT_RESPONSE in full.
    public mutating func sentHandshake(_ bytes: [UInt8], at now: Date = Date()) {
        let line = stamp(now) + PacketDump.handshake(bytes)
        push(&outbound, line)
    }

    public var lines: [String] {
        ["last \(outbound.count) sent:"] + outbound.map { "  → " + $0 } + ["last \(inbound.count) received:"] + inbound.map { "  ← " + $0 }
    }

    private func stamp(_ now: Date) -> String { String(format: "%8.3f ", now.timeIntervalSince(start)) }

    private func push(_ list: inout [String], _ line: String) {
        list.append(line)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
    }
}

/// What may be shown of a packet. Bytes (≤ 64) only for control packets that carry no user data;
/// channel data shows the channel, the length and the first two bytes (the message type).
public enum PacketDump {
    public static let maxBytes = 64

    /// Host → client types whose payload is shown.
    static let inboundShown: Set<UInt8> = [
        WDPacketType.initRequest, WDPacketType.terminate, WDPacketType.setLED, WDPacketType.command,
        WDPacketType.channelMonitor, WDPacketType.setMousePosition, WDPacketType.nop, WDPacketType.redraw,
    ]
    /// Client → host types whose payload is shown (no keys, credentials, INIT_RESPONSE or channel data).
    static let outboundShown: Set<UInt8> = [
        WDPacketType.initConnectResponse, WDPacketType.terminate, WDPacketType.setLED, WDPacketType.channelMonitor,
        WDPacketType.nop, WDPacketType.virtualAck, WDPacketType.redraw,
    ]

    static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ") + (bytes.count > maxBytes ? " …" : "")
    }

    public static func inbound(_ p: WDPacket) -> String {
        if let channel = p.channel {
            return String(format: "VC ch%d %d B [%@]", channel, p.payload.count, hex(p.payload.prefix(2)))
        }
        let head = String(format: "WD 0x%02x %d B", p.type, p.payload.count)
        return inboundShown.contains(p.type) ? head + " [\(hex(p.payload))]" : head
    }

    public static func outbound(_ packet: [UInt8]) -> String {
        guard let type = packet.first else { return "empty" }
        if WDPacketType.isVirtualWrite(type) {
            let header = type == WDPacketType.virtualWrite1 ? 1 : (type == WDPacketType.virtualWrite8 ? 2 : 3)
            guard packet.count > header else { return String(format: "VC write 0x%02x %d B", type, packet.count) }
            let data = packet.dropFirst(header + 1)
            return String(format: "VC ch%d %d B [%@]", packet[header], data.count, hex(data.prefix(2)))
        }
        let head = String(format: "WD 0x%02x %d B", type, packet.count)
        return outboundShown.contains(type) ? head + " [\(hex(packet))]" : head
    }

    public static func handshake(_ bytes: [UInt8]) -> String {
        guard let type = bytes.first else { return "empty" }
        let head = String(format: "handshake WD 0x%02x %d B", type, bytes.count)
        return type == WDPacketType.initConnectResponse && bytes.count <= 8 ? head + " [\(hex(bytes))]" : head
    }
}
