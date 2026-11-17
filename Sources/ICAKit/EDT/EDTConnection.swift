import Foundation

/// Client side of an EDT connection (docs/80, D130/D132): a reliable, ordered byte stream over UDP datagrams.
/// - Handshake, keep-alive, shutdown, idle timeout as observed from the VDA [B].
/// - Data, ACK/ACK2/NAK in the public UDT draft's form [P] (what the VDA sends back is logged and checked live [L]):
///   the byte stream is cut into packets of at most `payloadSize` bytes (each a whole message, position `11`);
///   the receiver acknowledges cumulatively every `ackInterval`, reports gaps at once with a NAK (and repeats it),
///   and answers each ACK2; the sender retransmits NAKed packets first, and everything unacknowledged after an RTO.
/// - Congestion control, deliberately conservative: a packet window starting at `initialWindow`, slow start to
///   `ssthresh`, then +1 packet per window acknowledged; on a loss event (NAK or RTO) at most once per RTT the window
///   halves (RTO: back to `initialWindow`). The peer's advertised buffer caps it too.
/// Pure: datagrams go out through `send`, time comes from the `now` arguments; the owner runs `tick` every ~10 ms.
public final class EDTConnection {
    public enum State: Equatable, Sendable {
        case idle
        /// First request sent (version 4), waiting for the cookie.
        case induction
        /// Second request sent (version 7, cookie echoed), waiting for the server's socket id.
        case conclusion
        case connected(serverSocket: UInt32)
        case closed(reason: String)
    }

    public struct Config: Sendable {
        /// Dotted IPv4 of the VDA (the handshake's peer address field) [B].
        public var peerIPv4: [UInt8]
        public var socketID: UInt32
        public var initialSequence: UInt32
        /// Offered maximum packet size, IP + UDP headers included as in UDT [P]. The lab path over Tailscale has an
        /// MTU of 1280, so the default fits it (the stock client offers 1500 and gets IP-fragmented, docs/80 §6).
        public var maxPacketSize: UInt32 = 1280
        public var flowWindow: UInt32 = 8192
        /// Handshake retry interval and count [I] (the stock client never needed a retry).
        public var handshakeRetry: Double = 0.25
        public var handshakeAttempts = 12
        /// Keep-alive when nothing was sent this long (the VDA: 1.006 s) [B].
        public var keepAliveInterval: Double = 1
        /// Give up after this long without a datagram from the peer (the VDA: 20 s) [B].
        public var idleTimeout: Double = 20
        /// Cumulative ACK period (UDT's SYN interval) [P].
        public var ackInterval: Double = 0.01
        /// Congestion window, packets.
        public var initialWindow: Double = 16
        public var maxWindow: Double = 4096
        public var initialSSThresh: Double = 256
        /// Retransmission timeout floor and cap, seconds.
        public var minRTO: Double = 0.2
        public var maxRTO: Double = 3

        public init(peerIPv4: [UInt8], socketID: UInt32 = UInt32.random(in: 1...0x7FFF_FFFF),
                    initialSequence: UInt32 = UInt32.random(in: 0...0x3FFF_FFFF)) {
            self.peerIPv4 = peerIPv4
            self.socketID = socketID
            self.initialSequence = initialSequence
        }
    }

    public struct Stats: Sendable, CustomStringConvertible {
        public var dataSent = 0, dataRetransmitted = 0, dataReceived = 0, duplicatesReceived = 0, outOfOrder = 0
        public var acksSent = 0, acksReceived = 0, ack2Received = 0, naksSent = 0, naksReceived = 0, rtos = 0
        public var keepAlivesReceived = 0, unknownControl = 0
        public var bytesDelivered = 0, bytesSent = 0
        public var description: String {
            "data out \(dataSent) (+\(dataRetransmitted) rtx, \(bytesSent) B), in \(dataReceived) (\(duplicatesReceived) dup, "
                + "\(outOfOrder) out of order, \(bytesDelivered) B delivered); ACK out \(acksSent) in \(acksReceived), ACK2 in \(ack2Received), "
                + "NAK out \(naksSent) in \(naksReceived), RTO \(rtos), keep-alive in \(keepAlivesReceived), unknown control \(unknownControl)"
        }
    }

    public let config: Config
    public private(set) var state: State = .idle
    public private(set) var cookie: UInt32?
    /// Negotiated packet size (the smaller of both offers) and the data bytes per packet (minus IP+UDP 28, EDT 16).
    public private(set) var packetSize: Int
    public var payloadSize: Int { packetSize - 28 - EDTPacket.headerSize }
    public private(set) var stats = Stats()
    public var keepAlivesReceived: Int { stats.keepAlivesReceived }
    /// Smoothed RTT and its variation, seconds.
    public private(set) var rtt: Double = 0.1
    public private(set) var rttVar: Double = 0.05
    public private(set) var window: Double
    public private(set) var ssthresh: Double

    /// Datagrams to the peer.
    public var send: ([UInt8]) -> Void = { _ in }
    /// In-order bytes from the peer (the CGP stream, docs/80 §1).
    public var deliver: ([UInt8]) -> Void = { _ in }
    public var onState: (State) -> Void = { _ in }
    /// Every datagram received, parsed (tests, probes, logs).
    public var onPacket: (EDTPacket) -> Void = { _ in }
    /// Notable protocol events for the log (first ACK/NAK seen, RTOs, unknown control types).
    public var log: (String) -> Void = { _ in }

    private var start: Double = 0
    private var lastSent: Double = 0
    private var lastReceived: Double = 0
    private var attempts = 0
    private var lastHandshake: [UInt8] = []

    // Sender.
    private var pendingBytes: [UInt8] = []
    private var pendingHead = 0
    private var sndNext: UInt32
    private var sndUna: UInt32
    private var nextMessage: UInt32 = 1
    private var inFlight: [UInt32: (payload: [UInt8], sentAt: Double, count: Int)] = [:]
    private var lossList: Set<UInt32> = []
    private var peerWindow: Double = 8192
    private var lastProgress: Double = 0
    private var backoff: Double = 1
    private var lastDecrease: Double = -1

    // Receiver.
    private var rcvNext: UInt32?
    private var buffered: [UInt32: [UInt8]] = [:]
    private var rcvLoss: [UInt32: Double] = [:]
    private var lastAckSeq: UInt32?
    private var lastAckAt: Double = 0
    private var ackNumber: UInt32 = 1
    private var acksAwaiting: [UInt32: Double] = [:]

    public init(config: Config) {
        self.config = config
        packetSize = Int(config.maxPacketSize)
        sndNext = config.initialSequence
        sndUna = config.initialSequence
        window = config.initialWindow
        ssthresh = config.initialSSThresh
    }

    /// The stock client's handshakes carry `0007` in the low half of word 0 [B].
    static let clientReserved: UInt16 = 7

    // MARK: Sequence arithmetic (31 bits)

    static func diff(_ a: UInt32, _ b: UInt32) -> Int {
        let d = Int32(bitPattern: ((a &- b) & 0x7FFF_FFFF) << 1) >> 1
        return Int(d)
    }
    static func add(_ a: UInt32, _ n: Int) -> UInt32 { UInt32(truncatingIfNeeded: Int(a) + n) & 0x7FFF_FFFF }

    // MARK: Public API

    public func connect(now: Double) {
        guard state == .idle else { return }
        start = now
        lastReceived = now
        let h = EDTHandshake(version: 4, initialSequence: config.initialSequence, connectionType: 1, socketID: config.socketID,
                             cookie: 0, peerIPv4: config.peerIPv4)
        var hs = h
        hs.maxPacketSize = config.maxPacketSize
        hs.flowWindow = config.flowWindow
        sendHandshake(hs, now: now)
        set(.induction)
    }

    public func close(now: Double, reason: String = "closed") {
        if case .connected(let server) = state { emit(EDTPacket.shutdown(destination: server), now: now) }
        if case .closed = state { return }
        set(.closed(reason: reason))
    }

    /// Bytes for the peer, in order (the CGP stream). Sent as the window allows.
    public func write(_ bytes: [UInt8], now: Double) {
        guard !bytes.isEmpty else { return }
        pendingBytes += bytes
        pump(now: now)
    }

    /// Bytes not yet acknowledged or not yet sent.
    public var unacknowledgedPackets: Int { inFlight.count }
    public var queuedBytes: Int { pendingBytes.count - pendingHead }

    /// One whole message in one packet (tests; `write` is the stream API).
    public func sendMessage(_ payload: [UInt8], now: Double) {
        guard case .connected = state else { return }
        transmitNew(payload, now: now)
    }

    public func receive(_ datagram: [UInt8], now: Double) {
        guard let packet = try? EDTPacket.parse(datagram) else { return }
        lastReceived = now
        onPacket(packet)
        if packet.destination != config.socketID && packet.destination != 0 { return }
        switch (state, packet) {
        case (.induction, _) where packet.controlType == .handshake:
            guard let h = packet.handshake, h.connectionType == 1, h.cookie != 0 else { return }
            cookie = h.cookie
            var conclusion = EDTHandshake(version: 7, initialSequence: config.initialSequence, connectionType: -1,
                                          socketID: config.socketID, cookie: h.cookie, peerIPv4: config.peerIPv4,
                                          ext: (config.socketID, config.initialSequence))
            conclusion.maxPacketSize = config.maxPacketSize
            conclusion.flowWindow = config.flowWindow
            attempts = 0
            sendHandshake(conclusion, now: now)
            set(.conclusion)
        case (.conclusion, _) where packet.controlType == .handshake:
            guard let h = packet.handshake, h.connectionType == -1, h.socketID != 0 else { return }
            rcvNext = h.initialSequence
            packetSize = max(576, min(Int(config.maxPacketSize), Int(h.maxPacketSize)))
            peerWindow = Double(max(16, min(h.flowWindow, 65536)))
            lastProgress = now
            log("EDT connected: server socket \(String(format: "%08x", h.socketID)), packet size \(packetSize) (payload \(payloadSize) B), "
                + "peer flow window \(h.flowWindow), peer ISN \(h.initialSequence)")
            set(.connected(serverSocket: h.socketID))
            pump(now: now)
        case (.connected(let server), .data(let seq, _, _, _, _, _, let payload)):
            receiveData(seq, payload, server: server, now: now)
        case (.connected(let server), .control(let type, _, let info, _, _, let body)):
            control(type, info: info, body: body, server: server, now: now)
        case (_, _) where packet.controlType == .shutdown:
            if case .closed = state { return }
            set(.closed(reason: "peer shutdown"))
        default:
            break
        }
    }

    /// Timers: handshake retries, ACK, NAK repeats, RTO, keep-alive, idle timeout.
    public func tick(now: Double) {
        switch state {
        case .induction, .conclusion:
            if now - lastReceived >= config.idleTimeout { return set(.closed(reason: "handshake timeout")) }
            if now - lastSent >= config.handshakeRetry {
                guard attempts < config.handshakeAttempts else { return set(.closed(reason: "no handshake reply")) }
                attempts += 1
                send(lastHandshake)
                lastSent = now
            }
        case .connected(let server):
            if now - lastReceived >= config.idleTimeout {
                emit(EDTPacket.shutdown(destination: server), now: now)
                return set(.closed(reason: "peer silent for \(Int(config.idleTimeout)) s"))
            }
            if now - lastAckAt >= config.ackInterval { sendAck(server: server, now: now, force: false) }
            repeatNaks(server: server, now: now)
            checkRTO(now: now)
            pump(now: now)
            if now - lastSent >= config.keepAliveInterval { emit(EDTPacket.keepAlive(destination: server), now: now) }
        default:
            break
        }
    }

    // MARK: Receiver

    private func receiveData(_ seq: UInt32, _ payload: [UInt8], server: UInt32, now: Double) {
        stats.dataReceived += 1
        guard let expected = rcvNext else { return }
        let d = Self.diff(seq, expected)
        if d < 0 || buffered[seq] != nil {
            stats.duplicatesReceived += 1
            return
        }
        rcvLoss[seq] = nil
        if d > 0 {
            stats.outOfOrder += 1
            buffered[seq] = payload
            // New gap(s) up to seq: report at once.
            var newLoss: [UInt32] = []
            var s = expected
            while Self.diff(seq, s) > 0 {
                if buffered[s] == nil, rcvLoss[s] == nil { newLoss.append(s) }
                s = Self.add(s, 1)
                if newLoss.count > 4096 { break }
            }
            for l in newLoss { rcvLoss[l] = now }
            if !newLoss.isEmpty { sendNak(newLoss, server: server, now: now) }
            return
        }
        deliverBytes(payload)
        var next = Self.add(expected, 1)
        while let p = buffered.removeValue(forKey: next) {
            deliverBytes(p)
            next = Self.add(next, 1)
        }
        rcvNext = next
    }

    private func deliverBytes(_ p: [UInt8]) {
        stats.bytesDelivered += p.count
        deliver(p)
    }

    private func sendAck(server: UInt32, now: Double, force: Bool) {
        guard let next = rcvNext else { return }
        if !force, let last = lastAckSeq, last == next, now - lastAckAt < max(0.5, 2 * rtt) { return }
        var ack = EDTAck(ackNumber: ackNumber, lastSequence: next)
        ack.rtt = UInt32(rtt * 1e6)
        ack.rttVariance = UInt32(rttVar * 1e6)
        ack.availableBuffer = UInt32(max(16, Int(config.flowWindow) - buffered.count))
        acksAwaiting[ackNumber] = now
        if acksAwaiting.count > 64 { acksAwaiting = acksAwaiting.filter { now - $0.value < 5 } }
        ackNumber = ackNumber &+ 1
        emit(ack.packet(destination: server, timestamp: micros(now)), now: now)
        stats.acksSent += 1
        lastAckSeq = next
        lastAckAt = now
    }

    private func sendNak(_ seqs: [UInt32], server: UInt32, now: Double) {
        let body = EDTLossList.encode(seqs)
        guard !body.isEmpty else { return }
        emit(.control(type: EDTControlType.nak.rawValue, reserved: 0, info: 0, timestamp: micros(now), destination: server, body: body), now: now)
        stats.naksSent += 1
    }

    private func repeatNaks(server: UInt32, now: Double) {
        guard !rcvLoss.isEmpty else { return }
        let gap = max(0.05, 2 * rtt)
        let due = rcvLoss.filter { now - $0.value >= gap }.map(\.key)
        guard !due.isEmpty else { return }
        for s in due { rcvLoss[s] = now }
        sendNak(due.sorted { Self.diff($0, $1) < 0 }, server: server, now: now)
    }

    // MARK: Control from the peer

    private func control(_ type: UInt16, info: UInt32, body: [UInt8], server: UInt32, now: Double) {
        switch EDTControlType(rawValue: type) {
        case .keepAlive?:
            stats.keepAlivesReceived += 1
        case .ack?:
            stats.acksReceived += 1
            if stats.acksReceived == 1 { log("EDT first ACK from the peer: info \(info), body \(body.count) B \(hex(body.prefix(24)))") }
            guard let ack = EDTAck(.control(type: type, reserved: 0, info: info, timestamp: 0, destination: server, body: body)) else { return }
            if body.count >= 24 {
                // ACK2 lets the peer measure its RTT (UDT) [P]; light ACKs (4 bytes) get none.
                emit(.control(type: EDTControlType.ack2.rawValue, reserved: 0, info: info, timestamp: micros(now), destination: server,
                              body: [0, 0, 0, 0]), now: now)
                if ack.rtt > 0 { updateRTT(Double(ack.rtt) / 1e6) }
                if ack.availableBuffer > 0 { peerWindow = Double(ack.availableBuffer) }
            }
            acknowledge(upTo: ack.lastSequence, now: now)
        case .ack2?:
            stats.ack2Received += 1
            if let sent = acksAwaiting.removeValue(forKey: info) { updateRTT(now - sent) }
        case .nak?:
            stats.naksReceived += 1
            if stats.naksReceived == 1 { log("EDT first NAK from the peer: body \(body.count) B \(hex(body.prefix(24)))") }
            var lost = 0
            for s in EDTLossList.decode(body) where inFlight[s] != nil {
                lossList.insert(s)
                lost += 1
            }
            if lost > 0 { lossEvent(now: now, timeout: false) }
            pump(now: now)
        case .shutdown?:
            set(.closed(reason: "peer shutdown"))
        case .handshake?:
            break  // a late handshake reply
        default:
            stats.unknownControl += 1
            if stats.unknownControl <= 5 { log("EDT unknown control type \(String(format: "0x%04x", type)): info \(info), \(body.count) B \(hex(body.prefix(24)))") }
        }
    }

    private func updateRTT(_ sample: Double) {
        guard sample > 0, sample < 10 else { return }
        rttVar = 0.75 * rttVar + 0.25 * abs(sample - rtt)
        rtt = 0.875 * rtt + 0.125 * sample
    }

    // MARK: Sender

    private func acknowledge(upTo next: UInt32, now: Double) {
        guard Self.diff(next, sndUna) > 0, Self.diff(next, sndNext) <= 0 else { return }
        var acked = 0
        var s = sndUna
        while Self.diff(next, s) > 0 {
            if inFlight.removeValue(forKey: s) != nil { acked += 1 }
            lossList.remove(s)
            s = Self.add(s, 1)
        }
        sndUna = next
        lastProgress = now
        backoff = 1
        // Slow start, then additive increase.
        if window < ssthresh { window += Double(acked) } else { window += Double(acked) / window }
        window = min(window, config.maxWindow)
        pump(now: now)
    }

    private func lossEvent(now: Double, timeout: Bool) {
        if timeout {
            ssthresh = max(config.initialWindow, window / 2)
            window = config.initialWindow
            lastDecrease = now
        } else if now - lastDecrease >= rtt {
            ssthresh = max(config.initialWindow / 2, window / 2)
            window = max(4, window / 2)
            lastDecrease = now
        }
    }

    private var rto: Double { min(config.maxRTO, max(config.minRTO, rtt + 4 * rttVar)) * backoff }

    private func checkRTO(now: Double) {
        guard !inFlight.isEmpty, now - lastProgress >= rto else { return }
        stats.rtos += 1
        if stats.rtos <= 3 || stats.rtos % 20 == 0 { log("EDT retransmission timeout \(stats.rtos): \(inFlight.count) unacknowledged, rto \(Int(rto * 1000)) ms") }
        for s in inFlight.keys { lossList.insert(s) }
        lossEvent(now: now, timeout: true)
        backoff = min(8, backoff * 2)
        lastProgress = now
        pump(now: now)
    }

    private func pump(now: Double) {
        guard case .connected(let server) = state else { return }
        let limit = Int(min(window, peerWindow))
        // Retransmissions first, oldest first.
        if !lossList.isEmpty {
            for s in lossList.sorted(by: { Self.diff($0, $1) < 0 }) {
                lossList.remove(s)
                guard var entry = inFlight[s] else { continue }
                entry.sentAt = now
                entry.count += 1
                inFlight[s] = entry
                stats.dataRetransmitted += 1
                emit(.data(sequence: s, position: 3, inOrder: false, message: s & 0x1FFF_FFFF, timestamp: micros(now),
                           destination: server, payload: entry.payload), now: now)
            }
        }
        while inFlight.count < limit, pendingHead < pendingBytes.count {
            let n = min(payloadSize, pendingBytes.count - pendingHead)
            let chunk = Array(pendingBytes[pendingHead..<(pendingHead + n)])
            pendingHead += n
            transmitNew(chunk, now: now)
        }
        if pendingHead == pendingBytes.count { pendingBytes.removeAll(keepingCapacity: true); pendingHead = 0 }
        else if pendingHead > 1 << 20 { pendingBytes.removeFirst(pendingHead); pendingHead = 0 }
    }

    private func transmitNew(_ payload: [UInt8], now: Double) {
        guard case .connected(let server) = state else { return }
        let seq = sndNext
        sndNext = Self.add(sndNext, 1)
        if inFlight.isEmpty { lastProgress = now }
        inFlight[seq] = (payload, now, 1)
        stats.dataSent += 1
        stats.bytesSent += payload.count
        let packet = EDTPacket.data(sequence: seq, position: 3, inOrder: false, message: nextMessage, timestamp: micros(now),
                                    destination: server, payload: payload)
        nextMessage = (nextMessage &+ 1) & 0x1FFF_FFFF
        if nextMessage == 0 { nextMessage = 1 }
        emit(packet, now: now)
    }

    // MARK: Helpers

    private func sendHandshake(_ h: EDTHandshake, now: Double) {
        let bytes = EDTPacket.handshake(h, destination: 0, reserved: Self.clientReserved).bytes
        lastHandshake = bytes
        send(bytes)
        lastSent = now
    }

    private func emit(_ packet: EDTPacket, now: Double) {
        send(packet.bytes)
        lastSent = now
    }

    private func micros(_ now: Double) -> UInt32 { UInt32(truncatingIfNeeded: Int64((now - start) * 1e6)) }

    private func hex<S: Sequence>(_ b: S) -> String where S.Element == UInt8 { b.map { String(format: "%02x", $0) }.joined() }

    private func set(_ s: State) {
        state = s
        onState(s)
    }
}

/// UDT loss-list encoding [P]: a single sequence number as is; a range as `first | 0x80000000`, then `last`.
public enum EDTLossList {
    public static func encode(_ seqs: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        func u32(_ v: UInt32) { out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var i = 0
        while i < seqs.count {
            var j = i
            while j + 1 < seqs.count, seqs[j + 1] == EDTConnection.add(seqs[j], 1) { j += 1 }
            if j > i { u32(seqs[i] | 0x8000_0000); u32(seqs[j]) } else { u32(seqs[i]) }
            i = j + 1
        }
        return out
    }

    public static func decode(_ body: [UInt8]) -> [UInt32] {
        var out: [UInt32] = []
        var i = 0
        func u32(_ k: Int) -> UInt32 { UInt32(body[k]) << 24 | UInt32(body[k + 1]) << 16 | UInt32(body[k + 2]) << 8 | UInt32(body[k + 3]) }
        while i + 4 <= body.count {
            let v = u32(i)
            if v & 0x8000_0000 != 0, i + 8 <= body.count {
                let first = v & 0x7FFF_FFFF, last = u32(i + 4)
                var s = first
                var n = 0
                while EDTConnection.diff(last, s) >= 0, n < 65536 { out.append(s); s = EDTConnection.add(s, 1); n += 1 }
                i += 8
            } else {
                out.append(v & 0x7FFF_FFFF)
                i += 4
            }
        }
        return out
    }
}
