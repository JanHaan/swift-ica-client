import Foundation

/// Common Gateway Protocol (session reliability), docs/20-transport.md §3 and §7.1, with resume
/// (§3.12): retransmit queue, resume bind, resume bind response.
///
/// Pure protocol state, no I/O. Sequenced packets (channel open, data) go through `output` and only
/// while CONNECTED or CLOSING; in any other state they are queued and written by the next resume
/// (§3.12.7). Other packets (bind, finish, keepalive, ack) are returned to the caller, which writes
/// them itself.
public final class CGPSession {
    public static let signature = Data([0x1a, 0x43, 0x47, 0x50, 0x2f, 0x30, 0x31])
    public static let icaDetect = Data([0x7f, 0x7f, 0x49, 0x43, 0x41, 0x00])
    /// Retransmit queue limit (§3.12.7 [I]).
    public static let defaultQueueLimit = 8 << 20

    public enum Command: UInt8 {
        case bindRequest = 0x01, bindResponse = 0x02, finishRequest = 0x03, finishResponse = 0x04
        case ack = 0x05, channelOpenRequest = 0x06, channelOpenResponse = 0x07, channelClose = 0x08
        case channelData = 0x09, data = 0x0a, dataWithAck = 0x0b
    }

    /// Core states, §3.11 (values as in the reference).
    public enum State: Int, Sendable {
        case notStarted = 0, binding = 2, connected = 4, suspended = 5, resuming = 6, failed = 7, closing = 8, closed = 9
    }

    public struct Capability: CustomStringConvertible {
        public let serviceId: UInt16
        public let capId: UInt16
        public let body: Data

        public var description: String { "svc \(serviceId) cap \(capId) [\(body.count)B]" }
    }

    /// Server cap 9 values (§3.5, §3.6).
    public struct ReliabilityParams: Equatable, Sendable {
        public var timeout: Int
        public var uiFlags: Int
        public var dimming: Int
        public var tcpTimeout: Int
    }

    /// Server SR cap (cap 5) read with the client's layout (§3.5). The cookie stays inside the session.
    public struct ServerReliability: Equatable, Sendable {
        public var nextSeq: UInt32
        public var reconnectFlag: UInt8
        public var serverByte: UInt8
        public var cookieLength: Int
        public var itemCount: Int
    }

    public struct ResumeResult: Sendable {
        /// nextSeq we sent (rxCount + 1) and the one the server sent (N).
        public var sentNextSeq: Int
        public var serverNextSeq: Int
        public var queueBefore: Int
        public var dropped: Int
        public var retransmitted: Int
    }

    public enum ResumeRefusal: Error, CustomStringConvertible, Sendable {
        /// SR nextSeq 0 (§3.12.6 step 4).
        case refused
        /// No SR cap in the resume response [I].
        case noReliabilityCap
        /// N < firstUnacked: the server wants packets it already acknowledged (deviation, §3.12.6 step 5).
        case alreadyAcknowledged(serverNextSeq: Int, firstUnacked: Int)
        /// N − firstUnacked larger than the queue (deviation, §3.12.6 step 5).
        case beyondQueue(serverNextSeq: Int, firstUnacked: Int, queued: Int)

        public var description: String {
            switch self {
            case .refused: "server refused the resume (nextSeq 0)"
            case .noReliabilityCap: "resume response without SR cap"
            case .alreadyAcknowledged(let n, let first): "server asks from packet \(n), but \(first - 1) were acknowledged"
            case .beyondQueue(let n, let first, let queued): "server expects packet \(n), queue holds \(first)…\(first + queued - 1)"
            }
        }
    }

    public enum Event {
        case signature
        case bindResponse([Capability])
        /// Resume bind response accepted: queue trimmed and retransmitted, state CONNECTED again.
        case resumed(ResumeResult)
        /// Resume bind response that ends SR; state FAILED.
        case resumeRefused(ResumeRefusal)
        case channelOpenResponse(channelId: Int, status: UInt16, raw: Data)
        case data(Data)
        /// 0x05 from the peer; `raw` is the packet body (flags + reliability header).
        case keepalive(raw: Data)
        case finishRequest(closeType: UInt8, reason: UInt8)
        case finishResponse
        case other(command: UInt8, body: Data)
    }

    public enum Failure: Error { case badSignature(Data), badPacket(UInt8), unexpectedBeforeResume(UInt8) }

    /// Writes a sequenced packet to the current connection (states 4 and 8 only).
    public var output: (Data) -> Void = { _ in }
    public private(set) var state = State.notStarted

    private var buffer = Data()
    private var sawSignature = false
    /// Received sequenced packets over the whole CGP session, and the count last reported to the peer.
    private var rxCount = 0
    private var lastAcked = 0
    public private(set) var tcpProxyServiceId: UInt16 = 1
    /// Our packets the peer has acknowledged so far (sum of all ack deltas; `txAcked` in §3.12).
    public private(set) var txAcked = 0
    /// Sequenced packets built so far (numbered from 1).
    public private(set) var txSent = 0
    /// Retransmit queue limit; tests lower it.
    var queueLimit = CGPSession.defaultQueueLimit
    /// The queue went over its limit while connected and was freed: no resume is possible any more,
    /// the session runs on without SR (see `abandonReliability`).
    public private(set) var reliabilityAbandoned = false
    /// Ack deltas that went beyond the queue (diagnostics; should stay 0).
    public private(set) var ackOverrun = 0
    /// Control packets whose body did not parse (kept for diagnostics).
    public private(set) var parseFailures = 0

    /// Retransmit queue: stored copies (ack zeroed) of packets `txAcked + 1 …`, oldest at `queueHead`.
    private var queue: [Data] = []
    private var queueHead = 0
    public private(set) var queueBytes = 0

    // Reconnect state from the server (secrets: memory only, never logged, §3.12.10).
    var serverByte: UInt8 = 2
    var reconnectCookie = Data()
    var serverTicket: (type: UInt8, ticket: Data)?
    private var staTicket = Data()
    public private(set) var serverReliability: ServerReliability?
    public private(set) var reliabilityParams: ReliabilityParams?
    /// Server cap 7 intervals in ms ([I] C2H, then H2C).
    public private(set) var keepaliveIntervals: (c2h: Int, h2c: Int)?
    /// The stored CHANNEL_OPEN_REQUEST, the item of every resume bind (§3.12.5).
    private(set) var channelOpenPacket: Data?
    /// Caps 9, 7, 1 and 2 of the first bind, reused byte for byte (§3.12.5).
    private var keptCaps: (params: Data, keepalive: Data, services: Data, cap2: Data)?

    public init() {}

    /// Our number of the oldest unacknowledged packet (§3.12).
    public var firstUnacked: Int { txAcked + 1 }
    public var queueCount: Int { queue.count - queueHead }
    /// Stored copies in the queue, oldest first (tests).
    var queuedPackets: [Data] { Array(queue[queueHead...]) }
    public var receivedSequenced: Int { rxCount }
    /// Received packets not yet acknowledged.
    public var unacknowledged: Int { rxCount - lastAcked }
    public var hasServerTicket: Bool { serverTicket != nil }
    /// Kept for older callers: same as `txAcked`.
    public var peerAcked: Int { txAcked }
    /// Packets go on the wire only in CONNECTED and CLOSING (§3.12.7).
    public var canWrite: Bool { state == .connected || state == .closing }

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

    /// Cap 5 body (§3.5): initial form, or the resume form with nextSeq, cookie and one item (§3.12.5).
    private func reliabilityCap(resume: Bool) -> Data {
        var sr = ByteWriter()
        sr.raw([0x01, 0x01, 0x01])
        sr.bytes(Data([0x05, 0x00]))
        sr.u8(0x01)
        sr.bytes(Data([0x05, 0x00]))
        sr.u32(resume ? UInt32(rxCount + 1) : 0)   // nextSeq
        sr.u8(resume ? 1 : 0)                      // reconnect flag
        sr.u8(resume ? serverByte : 2)
        sr.bytes(resume ? reconnectCookie : Data())
        if resume, let item = channelOpenPacket {
            sr.varlen(1)
            sr.raw(item)
        } else {
            sr.varlen(0)
        }
        return Self.capability(5, sr.data)
    }

    private func ticketCap(type: UInt8, _ ticket: Data) -> Data {
        var w = ByteWriter()
        w.u8(type)
        w.bytes(ticket)
        return Self.capability(6, w.data)
    }

    private func bindPacket(_ caps: [Data]) -> Data {
        var body = ByteWriter()
        body.u8(0)
        body.u16(0)
        body.varlen(caps.count)
        caps.forEach { body.raw($0) }
        return Self.signature + Self.packet(.bindRequest, body.data)
    }

    /// Signature plus BIND_REQUEST carrying the STA ticket (`Address` from the ICA file). State → 2.
    public func bindRequest(ticket: String) -> Data {
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

        var cap2 = ByteWriter()
        cap2.u8(3)
        cap2.bytes(Data())

        let kept = (params: Self.capability(9, params.data), keepalive: Self.capability(7, keepalive.data),
                    services: Self.capability(1, services.data), cap2: Self.capability(2, cap2.data))
        keptCaps = kept
        staTicket = Data(ticket.utf8)
        state = .binding
        return bindPacket([reliabilityCap(resume: false), kept.params, kept.keepalive, kept.services,
                           ticketCap(type: 0, staTicket), kept.cap2])
    }

    /// Signature plus the resume BIND_REQUEST (§3.12.5): same caps in the same order, cap 5 in the
    /// resume form, cap 6 with the latest server ticket. State → 6. The nextSeq field acknowledges
    /// everything received so far, so `lastAcked = rxCount` afterwards.
    public func resumeBindRequest() -> Data {
        guard let kept = keptCaps else { preconditionFailure("resume before the first bind") }
        let ticket = serverTicket ?? (type: 0, ticket: staTicket)
        let data = bindPacket([reliabilityCap(resume: true), kept.params, kept.keepalive, kept.services,
                               ticketCap(type: ticket.type, ticket.ticket), kept.cap2])
        lastAcked = rxCount
        state = .resuming
        return data
    }

    /// CHANNEL_OPEN_REQUEST for the TcpProxyService default channel (channel 0). Never carries an ack,
    /// so the stored copy is the sent packet (§3.12.5).
    public func channelOpenRequest() -> Data {
        var blob = ByteWriter()
        blob.u8(1)
        blob.bytes(Data("127.0.0.1:1494".utf8))
        blob.u16(3)
        var body = ByteWriter()
        body.u8(0x08)
        body.u8(0x01)   // rflags: sequenced, no ack
        body.u16(tcpProxyServiceId)
        body.varlen(0)  // channel id
        body.u8(0)
        body.u8(2)
        body.u16(0)
        body.bytes(blob.data)
        return Self.packet(.channelOpenRequest, body.data)
    }

    /// Opens the default channel once per CGP session: builds, stores and sends the open request.
    public func openChannel() {
        let packet = channelOpenRequest()
        channelOpenPacket = packet
        _ = sendSequenced(packet)
    }

    /// ICA bytes on the default channel; piggybacks a pending ack only while connected. Queued for
    /// retransmit; written only in states 4 and 8. False if the queue went over its limit.
    @discardableResult
    public func sendData(_ ica: Data, piggybackAck: Bool = true) -> Bool {
        sendSequenced(dataPacket(ica, piggybackAck: piggybackAck && canWrite))
    }

    /// The client's ICA detect reply: a plain 0x0A packet without ack (§4), counted and queued like
    /// any other 0x0A (§3.12.7).
    @discardableResult
    public func sendDetectReply() -> Bool { sendSequenced(detectReply()) }

    /// Builds a 0x0A/0x0B packet (no queueing; see `sendData`).
    func dataPacket(_ ica: Data, piggybackAck: Bool = true) -> Data {
        let delta = piggybackAck ? takeAckDelta() : 0
        if delta == 0 { return Self.packet(.data, ica) }
        var body = ByteWriter()
        body.varlen(delta)
        body.raw(ica)
        return Self.packet(.dataWithAck, body.data)
    }

    func detectReply() -> Data { Self.packet(.data, Self.icaDetect) }

    private func sendSequenced(_ packet: Data) -> Bool {
        txSent += 1
        if reliabilityAbandoned {
            if canWrite { output(packet) }
            return true
        }
        let stored = Self.zeroingAck(packet)
        queue.append(stored)
        queueBytes += stored.count
        if canWrite { output(packet) }
        return queueBytes <= queueLimit
    }

    /// Stops storing packets and frees the queue. A resume is impossible from now on; the caller
    /// gives up SR at once if the link dies later.
    public func abandonReliability() {
        reliabilityAbandoned = true
        queue = []
        queueHead = 0
        queueBytes = 0
    }

    /// Stand-alone ack, due when more than 5 received packets are unacknowledged. Never while not
    /// connected (§3.12.7).
    public func pendingAck(force: Bool = false) -> Data? {
        guard canWrite, rxCount - lastAcked > (force ? 0 : 5) else { return nil }
        return keepalive()
    }

    /// 0x05 keepalive (§3.12.7): `03 05 08 00`, or `04 05 08 02 <ackDelta>` with a pending ack. Never
    /// queued. The caller sends it only while connected.
    public func keepalive() -> Data {
        var body = ByteWriter()
        body.u8(0x08)
        appendReliability(&body, sequenced: false)
        return Self.packet(.ack, body.data)
    }

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

    /// Copy of a sent packet with its ack field zeroed and the length unchanged: a 1-byte varlen
    /// becomes `00`, a 2-byte one `80 00`; rflags stay (§3.8, §3.12.7). Handles the forms we build:
    /// 0x0B, and flagged packets with flags `08` and one reliability header.
    static func zeroingAck(_ packet: Data) -> Data {
        var bytes = [UInt8](packet)
        var r = ByteReader(Data(bytes))
        guard (try? r.varlen()) != nil, let command = try? r.u8() else { return packet }
        var ackAt: Int?
        switch command {
        case Command.dataWithAck.rawValue:
            ackAt = r.offset
        case Command.channelOpenRequest.rawValue, Command.channelClose.rawValue, Command.channelData.rawValue:
            guard let flags = try? r.u8(), flags == 0x08, let rflags = try? r.u8(), rflags & 0x02 != 0 else { return packet }
            ackAt = r.offset
        default:
            return packet
        }
        guard let i = ackAt, i < bytes.count else { return packet }
        if bytes[i] < 0x80 { bytes[i] = 0 } else if i + 1 < bytes.count { bytes[i] = 0x80; bytes[i + 1] = 0 }
        return Data(bytes)
    }

    /// The server acknowledged `delta` more of our packets: free that many oldest queue entries.
    private func peerAcknowledged(_ delta: Int) {
        guard delta > 0 else { return }
        txAcked += delta
        let drop = min(delta, queueCount)
        if drop < delta, !reliabilityAbandoned { ackOverrun += delta - drop }
        dropQueued(drop)
    }

    private func dropQueued(_ count: Int) {
        for i in queueHead..<(queueHead + count) { queueBytes -= queue[i].count }
        queueHead += count
        if queueHead > 1024, queueHead * 2 > queue.count {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
    }

    // MARK: State

    /// The link died (from 4) or a resume attempt failed (from 6): state 5, parser reset. Nothing goes
    /// on the wire (§3.12.3).
    public func suspend() {
        state = .suspended
        beginConnection()
    }

    /// Discards any partial packet; the next bytes must start with the signature (§3.12.3 step 4).
    public func beginConnection() {
        buffer = Data()
        sawSignature = false
    }

    public func markClosing() { state = .closing }
    public func markFailed() { state = .failed }
    public func markClosed() { if state != .failed { state = .closed } }

    // MARK: Incoming

    public func feed(_ chunk: Data) throws -> [Event] {
        let result = consume(chunk)
        if let error = result.error { throw error }
        return result.events
    }

    /// Like `feed`, but a failure does not lose the packets parsed before it in the same chunk
    /// (they are already counted in rxCount): they come back together with the error.
    public func consume(_ chunk: Data) -> (events: [Event], error: Error?) {
        var events: [Event] = []
        do { try parseChunk(chunk, into: &events) } catch { return (events, error) }
        return (events, nil)
    }

    private func parseChunk(_ chunk: Data, into events: inout [Event]) throws {
        buffer.append(chunk)
        if !sawSignature {
            guard buffer.count >= Self.signature.count else { return }
            let head = buffer.prefix(Self.signature.count)
            guard head == Self.signature else { throw Failure.badSignature(Data(head)) }
            buffer.removeFirst(Self.signature.count)
            buffer = Data(buffer)
            sawSignature = true
            events.append(.signature)
        }
        while state != .failed {
            var reader = ByteReader(buffer)
            guard let length = try? reader.varlen(), reader.remaining >= length, length >= 1 else { break }
            let headerSize = reader.offset - buffer.startIndex
            let packet = try reader.raw(length)
            buffer.removeFirst(headerSize + length)
            buffer = Data(buffer)
            if state == .resuming, let command = packet.first,
               command != Command.bindResponse.rawValue, command != Command.finishRequest.rawValue {
                // §3.12.4 step 3: only a bind response (or a refusing FINISH) may come first.
                throw Failure.unexpectedBeforeResume(command)
            }
            events.append(try parse(packet))
        }
    }

    private func parse(_ packet: Data) throws -> Event {
        var r = ByteReader(packet)
        let commandByte = try r.u8()
        guard let command = Command(rawValue: commandByte) else {
            // Unknown flagged command (e.g. a mid-session ticket update, §3.12.10): read its flags and
            // reliability headers best-effort, so a sequenced one still counts toward nextSeq.
            let raw = r.rest()
            if commandByte >= 0x03 {
                var flagged = ByteReader(raw)
                if (try? readFlags(&flagged)) == nil { parseFailures += 1 }
            }
            return .other(command: commandByte, body: raw)
        }
        switch command {
        case .data:
            rxCount += 1
            return .data(r.rest())
        case .dataWithAck:
            let delta = try r.varlen()
            rxCount += 1
            peerAcknowledged(delta)
            return .data(r.rest())
        case .bindResponse:
            _ = try r.u8()
            _ = try r.u16()
            var caps: [Capability] = []
            for _ in 0..<(try r.varlen()) {
                var c = ByteReader(try r.bytes())
                let cap = Capability(serviceId: try c.u16(), capId: try c.u16(), body: { _ = try? c.u16(); return c.rest() }())
                caps.append(cap)
            }
            return state == .resuming ? resumeResponse(caps) : firstBindResponse(caps)
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

    /// First BIND_RESPONSE (§3.6): service id, SR cap, ticket, keepalive intervals, cap 9. State → 4.
    private func firstBindResponse(_ caps: [Capability]) -> Event {
        for cap in caps where cap.serviceId == 0 {
            switch cap.capId {
            case 1: readServices(cap.body)
            case 5: readReliability(cap.body)
            case 6: readTicket(cap.body)
            case 7:
                var r = ByteReader(cap.body)
                if let c2h = try? r.u32(), let h2c = try? r.u32() { keepaliveIntervals = (Int(c2h), Int(h2c)) }
            case 9:
                var r = ByteReader(cap.body)
                if (try? r.u8()) != nil, let timeout = try? r.u16(), let ui = try? r.u16(), let dim = try? r.u16() {
                    reliabilityParams = ReliabilityParams(timeout: Int(timeout), uiFlags: Int(ui), dimming: Int(dim),
                                                          tcpTimeout: Int((try? r.u16()) ?? 0))
                }
            default: break
            }
        }
        if state == .binding || state == .notStarted { state = .connected }
        return .bindResponse(caps)
    }

    /// Resume BIND_RESPONSE (§3.12.6): only caps 5 and 6 count; trim the queue to N and retransmit the
    /// rest in order before any new packet. State → 4, or 7 on refusal.
    private func resumeResponse(_ caps: [Capability]) -> Event {
        var sr: ServerReliability?
        for cap in caps where cap.serviceId == 0 {
            if cap.capId == 6 { readTicket(cap.body) }
            if cap.capId == 5 { sr = readReliability(cap.body) }
        }
        func refuse(_ why: ResumeRefusal) -> Event {
            state = .failed
            return .resumeRefused(why)
        }
        guard let sr else { return refuse(.noReliabilityCap) }
        let n = Int(sr.nextSeq)
        if n == 0 { return refuse(.refused) }
        let first = firstUnacked
        if n < first { return refuse(.alreadyAcknowledged(serverNextSeq: n, firstUnacked: first)) }
        let before = queueCount
        if n - first > before { return refuse(.beyondQueue(serverNextSeq: n, firstUnacked: first, queued: before)) }
        dropQueued(n - first)
        txAcked = n - 1
        state = .connected
        let resend = queue[queueHead...]
        resend.forEach { output($0) }
        return .resumed(ResumeResult(sentNextSeq: lastAcked + 1, serverNextSeq: n, queueBefore: before,
                                     dropped: n - first, retransmitted: resend.count))
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
            if rflags & 0x02 != 0 { peerAcknowledged(try headers.varlen()) }
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

    /// Server SR cap with the client's layout: a, b, c, bytes d, e, bytes f, nextSeq u32, reconnect
    /// u8, serverByte u8, cookie bytes, itemCount varlen. Stores serverByte and cookie.
    @discardableResult
    private func readReliability(_ body: Data) -> ServerReliability? {
        var r = ByteReader(body)
        guard (try? r.raw(3)) != nil, (try? r.bytes()) != nil, (try? r.u8()) != nil, (try? r.bytes()) != nil,
              let next = try? r.u32(), let flag = try? r.u8(), let byte = try? r.u8(), let cookie = try? r.bytes() else {
            parseFailures += 1
            return nil
        }
        serverByte = byte
        reconnectCookie = cookie
        let info = ServerReliability(nextSeq: next, reconnectFlag: flag, serverByte: byte, cookieLength: cookie.count,
                                     itemCount: (try? r.varlen()) ?? 0)
        serverReliability = info
        return info
    }

    /// Server ticket cap: u8 ticketType, then the ticket as varlen bytes (89-byte live body = 1 + 1 + 87).
    /// If the length does not fit, the rest of the body is taken as the ticket.
    private func readTicket(_ body: Data) {
        var r = ByteReader(body)
        guard let type = try? r.u8() else { return }
        var probe = r
        if let ticket = try? probe.bytes(), probe.isAtEnd { serverTicket = (type, ticket) } else { serverTicket = (type, r.rest()) }
    }
}
