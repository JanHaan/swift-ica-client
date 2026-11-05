import Foundation

/// Common Gateway Protocol (session reliability), docs/20-transport.md §3 and §7.1.
/// Reconnect (resume bind, retransmit queue) is not implemented yet.
public final class CGPSession {
    public static let signature = Data([0x1a, 0x43, 0x47, 0x50, 0x2f, 0x30, 0x31])
    public static let icaDetect = Data([0x7f, 0x7f, 0x49, 0x43, 0x41, 0x00])

    public enum Command: UInt8 {
        case bindRequest = 0x01, bindResponse = 0x02, finishRequest = 0x03, finishResponse = 0x04
        case ack = 0x05, channelOpenRequest = 0x06, channelOpenResponse = 0x07, channelClose = 0x08
        case channelData = 0x09, data = 0x0a, dataWithAck = 0x0b
    }

    public struct Capability: CustomStringConvertible {
        public let serviceId: UInt16
        public let capId: UInt16
        public let body: Data

        public var description: String { "svc \(serviceId) cap \(capId) [\(body.count)B]" }
    }

    public enum Event {
        case signature
        case bindResponse([Capability])
        case channelOpenResponse(channelId: Int, status: UInt16, raw: Data)
        case data(Data)
        /// 0x05 from the peer; `raw` is the packet body (flags + reliability header).
        case keepalive(raw: Data)
        case finishRequest(closeType: UInt8, reason: UInt8)
        case finishResponse
        case other(command: UInt8, body: Data)
    }

    public enum Failure: Error { case badSignature(Data), badPacket(UInt8) }

    private var buffer = Data()
    private var sawSignature = false
    /// Received sequenced packets, and the count last reported to the peer.
    private var rxCount = 0
    private var lastAcked = 0
    public private(set) var tcpProxyServiceId: UInt16 = 1
    public private(set) var reconnectCookie = Data()
    /// Our packets the peer has acknowledged so far.
    public private(set) var peerAcked = 0
    /// Control packets whose body did not parse (kept for diagnostics).
    public private(set) var parseFailures = 0

    public init() {}

    // MARK: Outgoing

    static func packet(_ command: Command, _ body: Data) -> Data {
        var w = ByteWriter()
        w.varlen(body.count + 1)
        w.u8(command.rawValue)
        w.raw(body)
        return w.data
    }

    static func capability(_ capId: UInt16, _ body: Data) -> Data {
        var w = ByteWriter()
        w.varlen(6 + body.count)
        w.u16(0)
        w.u16(capId)
        w.u16(0)
        w.raw(body)
        return w.data
    }

    /// Signature plus BIND_REQUEST carrying the STA ticket (`Address` from the ICA file).
    public func bindRequest(ticket: String) -> Data {
        var sr = ByteWriter()  // cap 5 Session Reliability, initial connect
        sr.raw([0x01, 0x01, 0x01])
        sr.bytes(Data([0x05, 0x00]))
        sr.u8(0x01)
        sr.bytes(Data([0x05, 0x00]))
        sr.u32(0)        // nextSeq
        sr.u8(0)         // reconnect flag
        sr.u8(2)
        sr.bytes(Data()) // cookie
        sr.varlen(0)     // items

        var params = ByteWriter()  // cap 9 Reliability parameters
        params.u8(1); params.u16(180); params.u16(1); params.u16(25); params.u16(10)

        var keepalive = ByteWriter()  // cap 7
        keepalive.u32(3000); keepalive.u32(3000)

        var services = ByteWriter()  // cap 1
        let name = Data("Citrix.TcpProxyService".utf8)
        var entry = ByteWriter()
        entry.u16(1); entry.u8(1); entry.u16(0); entry.bytes(name)
        services.varlen(1)
        services.bytes(entry.data)

        var ticketCap = ByteWriter()  // cap 6
        ticketCap.u8(0)
        ticketCap.bytes(Data(ticket.utf8))

        var cap2 = ByteWriter()
        cap2.u8(3)
        cap2.bytes(Data())

        var body = ByteWriter()
        body.u8(0)
        body.u16(0)
        let caps = [
            Self.capability(5, sr.data), Self.capability(9, params.data), Self.capability(7, keepalive.data),
            Self.capability(1, services.data), Self.capability(6, ticketCap.data), Self.capability(2, cap2.data),
        ]
        body.varlen(caps.count)
        caps.forEach { body.raw($0) }
        return Self.signature + Self.packet(.bindRequest, body.data)
    }

    /// CHANNEL_OPEN_REQUEST for the TcpProxyService default channel (channel 0).
    public func channelOpenRequest() -> Data {
        var blob = ByteWriter()
        blob.u8(1)
        blob.bytes(Data("127.0.0.1:1494".utf8))
        blob.u16(3)
        var body = ByteWriter()
        body.u8(0x08)
        appendReliability(&body, sequenced: true)
        body.u16(tcpProxyServiceId)
        body.varlen(0)  // channel id
        body.u8(0)
        body.u8(2)
        body.u16(0)
        body.bytes(blob.data)
        return Self.packet(.channelOpenRequest, body.data)
    }

    /// ICA bytes on the default channel; piggybacks a pending ack.
    public func dataPacket(_ ica: Data, piggybackAck: Bool = true) -> Data {
        let delta = piggybackAck ? takeAckDelta() : 0
        if delta == 0 { return Self.packet(.data, ica) }
        var body = ByteWriter()
        body.varlen(delta)
        body.raw(ica)
        return Self.packet(.dataWithAck, body.data)
    }

    /// The client's ICA detect reply: a plain 0x0A packet without ack (§4).
    public func detectReply() -> Data { Self.packet(.data, Self.icaDetect) }

    /// Stand-alone ack, due when more than 5 received packets are unacknowledged.
    public func pendingAck(force: Bool = false) -> Data? {
        guard rxCount - lastAcked > (force ? 0 : 5) else { return nil }
        var body = ByteWriter()
        body.u8(0x08)
        appendReliability(&body, sequenced: false)
        return Self.packet(.ack, body.data)
    }

    /// 0x05 keepalive in the same form the server uses: flags 0x08 and a reliability header that
    /// carries the pending ack, if any.
    public func keepalive() -> Data {
        var body = ByteWriter()
        body.u8(0x08)
        appendReliability(&body, sequenced: false)
        return Self.packet(.ack, body.data)
    }

    /// Received sequenced packets so far.
    public var receivedSequenced: Int { rxCount }

    /// Received packets not yet acknowledged.
    public var unacknowledged: Int { rxCount - lastAcked }

    public func finishRequest(closeType: UInt8 = 0, reason: UInt8 = 0) -> Data {
        Self.packet(.finishRequest, Data([0x00, closeType, reason]))
    }

    public func finishResponse(closeType: UInt8 = 0) -> Data {
        Self.packet(.finishResponse, Data([0x00, closeType, 0x00]))
    }

    private func takeAckDelta() -> Int {
        defer { lastAcked = rxCount }
        return rxCount - lastAcked
    }

    /// Reliability header; sets the ack bit whenever an ack value is written (§3.3 note).
    private func appendReliability(_ w: inout ByteWriter, sequenced: Bool) {
        let delta = takeAckDelta()
        w.u8((sequenced ? 0x01 : 0) | (delta > 0 ? 0x02 : 0))
        if delta > 0 { w.varlen(delta) }
    }

    // MARK: Incoming

    public func feed(_ chunk: Data) throws -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []
        if !sawSignature {
            guard buffer.count >= Self.signature.count else { return events }
            let head = buffer.prefix(Self.signature.count)
            guard head == Self.signature else { throw Failure.badSignature(Data(head)) }
            buffer.removeFirst(Self.signature.count)
            sawSignature = true
            events.append(.signature)
        }
        while true {
            var reader = ByteReader(buffer)
            guard let length = try? reader.varlen(), reader.remaining >= length, length >= 1 else { break }
            let headerSize = reader.offset - buffer.startIndex
            let packet = try reader.raw(length)
            buffer.removeFirst(headerSize + length)
            buffer = Data(buffer)
            events.append(try parse(packet))
        }
        return events
    }

    private func parse(_ packet: Data) throws -> Event {
        var r = ByteReader(packet)
        let commandByte = try r.u8()
        guard let command = Command(rawValue: commandByte) else { return .other(command: commandByte, body: r.rest()) }
        switch command {
        case .data:
            rxCount += 1
            return .data(r.rest())
        case .dataWithAck:
            _ = try r.varlen()
            rxCount += 1
            return .data(r.rest())
        case .bindResponse:
            _ = try r.u8()
            _ = try r.u16()
            var caps: [Capability] = []
            for _ in 0..<(try r.varlen()) {
                var c = ByteReader(try r.bytes())
                let cap = Capability(serviceId: try c.u16(), capId: try c.u16(), body: { _ = try? c.u16(); return c.rest() }())
                caps.append(cap)
                if cap.serviceId == 0 && cap.capId == 1 { readServices(cap.body) }
                if cap.serviceId == 0 && cap.capId == 5 { readReliability(cap.body) }
            }
            return .bindResponse(caps)
        case .bindRequest:
            throw Failure.badPacket(commandByte)
        default:
            let raw = r.rest()
            r = ByteReader(raw)
            // Flagged commands with a short or empty body (seen live for 0x05) are reported, not fatal.
            do { try readFlags(&r) } catch {
                parseFailures += 1
                return command == .ack ? .keepalive(raw: raw) : .other(command: commandByte, body: raw)
            }
            switch command {
            case .ack:
                return .keepalive(raw: raw)
            case .finishRequest:
                return .finishRequest(closeType: (try? r.u8()) ?? 0, reason: (try? r.u8()) ?? 0)
            case .finishResponse:
                return .finishResponse
            case .channelOpenResponse:
                guard let channel = try? r.varlen(), let status = try? r.u16() else {
                    parseFailures += 1
                    return .other(command: commandByte, body: raw)
                }
                return .channelOpenResponse(channelId: channel, status: status, raw: raw)
            default:
                return .other(command: commandByte, body: r.rest())
            }
        }
    }

    /// Flags bitmask (7 bits per byte, bit 7 continues), then the optional headers it announces.
    private func readFlags(_ r: inout ByteReader) throws {
        var flags = 0
        var shift = 0
        while true {
            let byte = try r.u8()
            flags |= Int(byte & 0x7f) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        // With bit 0 the headers that follow are read from inside the length-prefixed extension
        // block; the main reader continues after it (seen live: `09 02 02 05` = ack of 5).
        var headers = r
        if flags & 0x01 != 0 { headers = ByteReader(try r.bytes()) }
        for bit in [0x02, 0x04, 0x08] where flags & bit != 0 {
            let rflags = try headers.u8()
            if rflags & 0x02 != 0 { peerAcked += try headers.varlen() }
            if rflags & 0x01 != 0 { rxCount += 1 }
        }
        if flags & 0x01 == 0 { r = headers }
    }

    private func readServices(_ body: Data) {
        var r = ByteReader(body)
        guard let count = try? r.varlen() else { return }
        for _ in 0..<count {
            guard let entry = try? r.bytes() else { return }
            var e = ByteReader(entry)
            guard let id = try? e.u16(), (try? e.u8()) != nil, (try? e.u16()) != nil, let name = try? e.bytes() else { continue }
            if String(decoding: name, as: UTF8.self) == "Citrix.TcpProxyService" { tcpProxyServiceId = id }
        }
    }

    private func readReliability(_ body: Data) {
        // a, b, c, bytes d, e, bytes f, nextSeq u32, reconnect u8, serverByte u8, cookie bytes
        var r = ByteReader(body)
        _ = try? r.raw(3)
        _ = try? r.bytes()
        _ = try? r.u8()
        _ = try? r.bytes()
        _ = try? r.u32()
        _ = try? r.u8()
        _ = try? r.u8()
        if let cookie = try? r.bytes() { reconnectCookie = cookie }
    }
}
