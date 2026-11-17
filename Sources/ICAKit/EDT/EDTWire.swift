import Foundation

// EDT (HDX over UDP) wire layer, skeleton (docs/80-edt.md, D130). Built from our own captures of the stock client
// (§3–§6 there, tags [B]) and the public UDT draft (draft-gg-udt-03, [P]). Parts never seen on the wire are marked
// [I] and kept minimal. Everything is big-endian. Off by default (`EDTFeature`); no transport uses it yet.

/// `ICA_EDT=1` turns EDT experiments on; default off (D130).
public enum EDTFeature {
    public static func enabled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool { env["ICA_EDT"] == "1" }
}

public enum EDTWireError: Error, Equatable, CustomStringConvertible {
    case tooShort(Int)
    case badHandshake(Int)
    public var description: String {
        switch self {
        case .tooShort(let n): return "EDT datagram too short (\(n) B)"
        case .badHandshake(let n): return "EDT handshake body of \(n) B"
        }
    }
}

/// Control packet types. 0, 1, 5 and 0x20 were seen [B]; the others are the UDT draft's [P], unobserved [I].
public enum EDTControlType: UInt16, Sendable {
    case handshake = 0, keepAlive = 1, ack = 2, nak = 3, congestionWarning = 4, shutdown = 5, ack2 = 6, dropRequest = 7
    /// Not in the UDT draft: MTU probes right after a switch-over (docs/80 §6) [B].
    case mtuProbe = 0x20
    /// The VDA's answer to a probe: the same size, the probe's counter and length echoed (docs/80 §6) [L].
    case mtuProbeReply = 0x21
}

/// The 48-byte handshake body (+ the 8-byte EDT extension in the second round) (docs/80 §4.1) [B].
public struct EDTHandshake: Equatable, Sendable {
    /// 4 in the first request, 7 afterwards [B].
    public var version: UInt32
    /// 1 = stream [B][P].
    public var socketType: UInt32 = 1
    public var initialSequence: UInt32
    public var maxPacketSize: UInt32 = 1500
    public var flowWindow: UInt32 = 16384
    /// 1 = request; −1 in the second round [B].
    public var connectionType: Int32
    public var socketID: UInt32
    public var cookie: UInt32
    /// IPv4 address bytes in wire order (little-endian: 10.77.0.12 is `0c 00 4d 0a`) [B].
    public var peerAddress: [UInt8]
    /// Second round only: (socket id, initial sequence) of the sender [B].
    public var ext: (socketID: UInt32, sequence: UInt32)?

    public init(version: UInt32, initialSequence: UInt32, connectionType: Int32, socketID: UInt32, cookie: UInt32,
                peerIPv4: [UInt8], ext: (socketID: UInt32, sequence: UInt32)? = nil) {
        self.version = version
        self.initialSequence = initialSequence
        self.connectionType = connectionType
        self.socketID = socketID
        self.cookie = cookie
        self.peerAddress = Self.wireAddress(ipv4: peerIPv4)
        self.ext = ext
    }

    /// Dotted-order IPv4 bytes (10, 77, 0, 12) → the 16-byte wire field (reversed, zero-padded) [B].
    public static func wireAddress(ipv4: [UInt8]) -> [UInt8] {
        Array(ipv4.prefix(4).reversed()) + [UInt8](repeating: 0, count: 16 - min(4, ipv4.count))
    }

    /// The IPv4 address in dotted order, from the wire field.
    public var peerIPv4: [UInt8] { Array(peerAddress.prefix(4).reversed()) }

    public static func == (a: EDTHandshake, b: EDTHandshake) -> Bool {
        a.version == b.version && a.socketType == b.socketType && a.initialSequence == b.initialSequence
            && a.maxPacketSize == b.maxPacketSize && a.flowWindow == b.flowWindow && a.connectionType == b.connectionType
            && a.socketID == b.socketID && a.cookie == b.cookie && a.peerAddress == b.peerAddress
            && a.ext?.socketID == b.ext?.socketID && a.ext?.sequence == b.ext?.sequence
    }
}

/// One EDT datagram.
public enum EDTPacket: Equatable, Sendable {
    /// Control packet. `reserved`: the low 16 bits of word 0 (`0007` in the stock client's handshakes, 0 from the
    /// VDA [B], meaning unknown [I]); `info`: word 1 (the ACK number for ACK/ACK2 in UDT [P][I]).
    case control(type: UInt16, reserved: UInt16, info: UInt32, timestamp: UInt32, destination: UInt32, body: [UInt8])
    /// Data packet: 31-bit sequence; word 1 = position (2 bits, `11` = a whole message), in-order flag (1 bit),
    /// 29-bit message number [B][P]; timestamp in µs since the connection start [B].
    case data(sequence: UInt32, position: UInt8, inOrder: Bool, message: UInt32, timestamp: UInt32, destination: UInt32,
              payload: [UInt8])

    public static let headerSize = 16

    public static func parse(_ bytes: [UInt8]) throws -> EDTPacket {
        guard bytes.count >= headerSize else { throw EDTWireError.tooShort(bytes.count) }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]) }
        let w0 = u32(0), w1 = u32(4), ts = u32(8), dst = u32(12)
        let rest = Array(bytes[headerSize...])
        if w0 & 0x8000_0000 != 0 {
            return .control(type: UInt16((w0 >> 16) & 0x7FFF), reserved: UInt16(w0 & 0xFFFF), info: w1, timestamp: ts,
                            destination: dst, body: rest)
        }
        return .data(sequence: w0, position: UInt8(w1 >> 30), inOrder: w1 & 0x2000_0000 != 0, message: w1 & 0x1FFF_FFFF,
                     timestamp: ts, destination: dst, payload: rest)
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = []
        func u32(_ v: UInt32) { out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        switch self {
        case .control(let type, let reserved, let info, let ts, let dst, let body):
            u32(0x8000_0000 | UInt32(type & 0x7FFF) << 16 | UInt32(reserved)); u32(info); u32(ts); u32(dst)
            out += body
        case .data(let seq, let pos, let inOrder, let msg, let ts, let dst, let payload):
            u32(seq & 0x7FFF_FFFF); u32(UInt32(pos & 3) << 30 | (inOrder ? 0x2000_0000 : 0) | msg & 0x1FFF_FFFF); u32(ts); u32(dst)
            out += payload
        }
        return out
    }

    // MARK: Builders for the observed control packets

    public static func handshake(_ h: EDTHandshake, destination: UInt32, reserved: UInt16) -> EDTPacket {
        var body: [UInt8] = []
        func u32(_ v: UInt32) { body += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        u32(h.version); u32(h.socketType); u32(h.initialSequence); u32(h.maxPacketSize); u32(h.flowWindow)
        u32(UInt32(bitPattern: h.connectionType)); u32(h.socketID); u32(h.cookie)
        body += h.peerAddress
        if let e = h.ext { u32(e.socketID); u32(e.sequence) }
        return .control(type: EDTControlType.handshake.rawValue, reserved: reserved, info: 0, timestamp: 0, destination: destination, body: body)
    }

    /// Keep-alive and shutdown: 16-byte header + 4 zero bytes, timestamp 0 [B].
    public static func keepAlive(destination: UInt32) -> EDTPacket {
        .control(type: EDTControlType.keepAlive.rawValue, reserved: 0, info: 0, timestamp: 0, destination: destination, body: [0, 0, 0, 0])
    }

    public static func shutdown(destination: UInt32) -> EDTPacket {
        .control(type: EDTControlType.shutdown.rawValue, reserved: 0, info: 0, timestamp: 0, destination: destination, body: [0, 0, 0, 0])
    }

    /// MTU probe [B]: body word 0 = 0, word 1 = a counter, word 2 = the datagram length − 28, zero padding to `size`.
    /// The probe also carried two short ASCII tags further in, not reproduced (meaning unknown) [I].
    public static func mtuProbe(destination: UInt32, counter: UInt32, size: Int) -> EDTPacket {
        var body = [UInt8](repeating: 0, count: max(12, size - headerSize))
        let rest = UInt32(max(0, size - 28))
        for (i, v) in [counter, rest].enumerated() {
            for b in 0..<4 { body[4 + i * 4 + b] = UInt8(v >> UInt32(24 - 8 * b) & 0xFF) }
        }
        return .control(type: EDTControlType.mtuProbe.rawValue, reserved: 0, info: 0, timestamp: 0, destination: destination, body: body)
    }

    /// The handshake body of a control packet of type 0.
    public var handshake: EDTHandshake? {
        guard case .control(let type, _, _, _, _, let body) = self, type == EDTControlType.handshake.rawValue,
              body.count == 48 || body.count == 56 else { return nil }
        func u32(_ i: Int) -> UInt32 { UInt32(body[i]) << 24 | UInt32(body[i + 1]) << 16 | UInt32(body[i + 2]) << 8 | UInt32(body[i + 3]) }
        var h = EDTHandshake(version: u32(0), initialSequence: u32(8), connectionType: Int32(bitPattern: u32(20)),
                             socketID: u32(24), cookie: u32(28), peerIPv4: [])
        h.socketType = u32(4)
        h.maxPacketSize = u32(12)
        h.flowWindow = u32(16)
        h.peerAddress = Array(body[32..<48])
        if body.count == 56 { h.ext = (u32(48), u32(52)) }
        return h
    }

    /// The reply to a probe (ours to the VDA's, or a test VDA's): type 0x21, the probe's body unchanged [L].
    public func mtuProbeReply(destination: UInt32) -> EDTPacket? {
        guard case .control(let type, _, let info, _, _, let body) = self, type == EDTControlType.mtuProbe.rawValue else { return nil }
        return .control(type: EDTControlType.mtuProbeReply.rawValue, reserved: 0, info: info, timestamp: 0, destination: destination, body: body)
    }

    /// (counter, declared rest length) of an MTU probe or probe reply.
    public var mtuProbeFields: (counter: UInt32, rest: UInt32)? {
        guard case .control(let type, _, _, _, _, let body) = self,
              type == EDTControlType.mtuProbe.rawValue || type == EDTControlType.mtuProbeReply.rawValue, body.count >= 12 else { return nil }
        func u32(_ i: Int) -> UInt32 { UInt32(body[i]) << 24 | UInt32(body[i + 1]) << 16 | UInt32(body[i + 2]) << 8 | UInt32(body[i + 3]) }
        return (u32(4), u32(8))
    }

    public var controlType: EDTControlType? {
        if case .control(let type, _, _, _, _, _) = self { return EDTControlType(rawValue: type) }
        return nil
    }

    public var destination: UInt32 {
        switch self {
        case .control(_, _, _, _, let d, _), .data(_, _, _, _, _, let d, _): return d
        }
    }
}

/// UDT-draft ACK body [P], never seen from EDT yet [I]: last acknowledged sequence + RTT, RTT variance, available
/// buffer, receive rate, link capacity (µs / packets / packets per second). Built and parsed only for tests until a
/// working EDT session shows the real layout.
public struct EDTAck: Equatable, Sendable {
    public var ackNumber: UInt32
    public var lastSequence: UInt32
    public var rtt: UInt32 = 0, rttVariance: UInt32 = 0, availableBuffer: UInt32 = 0, receiveRate: UInt32 = 0, linkCapacity: UInt32 = 0

    public init(ackNumber: UInt32, lastSequence: UInt32) {
        self.ackNumber = ackNumber
        self.lastSequence = lastSequence
    }

    public func packet(destination: UInt32, timestamp: UInt32) -> EDTPacket {
        var body: [UInt8] = []
        for v in [lastSequence, rtt, rttVariance, availableBuffer, receiveRate, linkCapacity] {
            body += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        return .control(type: EDTControlType.ack.rawValue, reserved: 0, info: ackNumber, timestamp: timestamp, destination: destination, body: body)
    }

    public init?(_ packet: EDTPacket) {
        guard case .control(let type, _, let info, _, _, let body) = packet, type == EDTControlType.ack.rawValue, body.count >= 4 else { return nil }
        func u32(_ i: Int) -> UInt32 { i + 4 <= body.count ? UInt32(body[i]) << 24 | UInt32(body[i + 1]) << 16 | UInt32(body[i + 2]) << 8 | UInt32(body[i + 3]) : 0 }
        ackNumber = info
        lastSequence = u32(0)
        rtt = u32(4); rttVariance = u32(8); availableBuffer = u32(12); receiveRate = u32(16); linkCapacity = u32(20)
    }
}
