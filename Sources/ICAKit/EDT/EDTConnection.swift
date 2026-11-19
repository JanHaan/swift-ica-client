import Foundation

/// Client side of an EDT connection (docs/80, D130/D132): a reliable, ordered byte stream over UDP datagrams.
/// - Handshake, keep-alive, shutdown, idle timeout as observed from the VDA [B].
/// - Data, ACK/ACK2/NAK in the public UDT draft's form [P] (what the VDA sends back is logged and checked live [L]):
///   the byte stream is cut into packets of at most `payloadSize` bytes (each a whole message, position `11`);
///   the receiver acknowledges cumulatively every `ackInterval`, reports gaps at once with a NAK (and repeats it),
///   and answers each ACK2; the sender retransmits NAKed packets first, and everything unacknowledged after an RTO.
/// - Congestion control (D135): a packet window from `initialWindow`, slow start to the first loss, then +12.5 % per
///   RTT while the RTT stays near its minimum, else +1 packet per RTT; a decrease (×0.875, at most once per RTT) only on
///   congestion: ≥ 10 % of the window lost in one epoch or the RTT up by half, so random loss of a few percent does not
///   throttle it; an RTO drops to `initialWindow`. The peer's advertised buffer caps the window.
/// - Pacing (D135): packets leave at window/RTT per second (a token bucket refilled on every call, at most two ticks'
///   worth at once), so an ACK never releases a burst.
/// - Path MTU (D135): data starts at `minPacketSize` and is raised by binary-search probes (type 0x20) that the VDA
///   echoes as type 0x21 of the same size [L]; without any echo, `fallbackPacketSize`. Probes from the peer are echoed.
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
        /// Path MTU discovery (D135): data starts at `minPacketSize` (IPv4's guaranteed 576) and probes go up to the
        /// negotiated size; with no echo at all, `fallbackPacketSize` (the negotiated size if smaller). Off: the
        /// negotiated size from the start.
        public var probeMTU = true
        public var minPacketSize = 576
        public var fallbackPacketSize = 1280
        /// Rate pacing (D135).
        public var pacing = true
        /// Multiplicative decrease on congestion, and the loss share of an epoch that counts as congestion.
        public var decrease: Double = 0.875
        public var congestionLossShare: Double = 0.1
        /// Handshake retry interval and count [I] (the stock client never needed a retry).
        public var handshakeRetry: Double = 0.1
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
        /// Data packets at or beyond our advertised flow window, dropped unbuffered (F-08).
        public var beyondWindow = 0
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
    /// Negotiated packet size (the smaller of both offers), the size data uses now (raised by probes), and the data
    /// bytes per packet (minus IP+UDP 28, EDT 16).
    public private(set) var packetSize: Int
    public private(set) var sendPacketSize: Int
    public var payloadSize: Int { sendPacketSize - 28 - EDTPacket.headerSize }
    /// Probe results for the log: (size, answered).
    public private(set) var probeLog: [(size: Int, answered: Bool)] = []
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
    /// Probing found the path narrower than the negotiated packet size (the size it carries), once per connection.
    public var onPathBelowNegotiated: (Int) -> Void = { _ in }
    /// Notable protocol events for the log (first ACK/NAK seen, RTOs, unknown control types).
    public var log: (String) -> Void = { _ in }

    private var start: Double = 0
    private var offer: UInt32 = 1280
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
    private var minRTT: Double = .infinity
    private var epochStart: Double = 0
    private var epochLosses = 0
    private var tokens: Double = 4
    private var lastRefill: Double = 0
    // Path MTU probing.
    private var probing: (size: Int, counter: UInt32, sentAt: Double, tries: Int)?
    private var probeLow = 0
    private var probeHigh = 0
    private var probeCounter: UInt32 = 0x100
    private var probeReplies = 0
    private var probeDone = false

    // Receiver.
    private var rcvNext: UInt32?
    private var buffered: [UInt32: [UInt8]] = [:]
    /// The highest sequence number buffered out of order (nil when everything received was delivered).
    private var rcvHighest: UInt32?
    private var rcvLoss: [UInt32: Double] = [:]
    private var lastAckSeq: UInt32?
    private var lastAckAt: Double = 0
    private var ackNumber: UInt32 = 1
    private var acksAwaiting: [UInt32: Double] = [:]
    // Receive-side estimates reported in every full ACK (UDT [P]): the sender's rate control grows from them (D135).
    private var lastArrival: Double?
    private var arrivalIntervals: [Double] = []
    private var pairStart: (seq: UInt32, at: Double)?
    private var pairIntervals: [Double] = []

    public init(config: Config) {
        self.config = config
        packetSize = Int(config.maxPacketSize)
        sendPacketSize = Int(config.maxPacketSize)
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

    /// `maxPacketSize`: the offer for this connection (EDTStream passes the route's interface MTU), else the config's.
    public func connect(now: Double, maxPacketSize: Int? = nil) {
        guard state == .idle else { return }
        start = now
        lastReceived = now
        offer = UInt32(max(config.minPacketSize, min(65_535, maxPacketSize ?? Int(config.maxPacketSize))))
        let h = EDTHandshake(version: 4, initialSequence: config.initialSequence, connectionType: 1, socketID: config.socketID,
                             cookie: 0, peerIPv4: config.peerIPv4)
        var hs = h
        hs.maxPacketSize = offer
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
            conclusion.maxPacketSize = offer
            conclusion.flowWindow = config.flowWindow
            attempts = 0
            sendHandshake(conclusion, now: now)
            set(.conclusion)
        case (.conclusion, _) where packet.controlType == .handshake:
            guard let h = packet.handshake, h.connectionType == -1, h.socketID != 0 else { return }
            rcvNext = h.initialSequence
            packetSize = max(config.minPacketSize, min(Int(offer), Int(h.maxPacketSize)))
            sendPacketSize = config.probeMTU ? min(packetSize, config.minPacketSize) : packetSize
            peerWindow = Double(max(16, min(h.flowWindow, 65536)))
            lastProgress = now
            lastRefill = now
            epochStart = now
            log("EDT connected: server socket \(String(format: "%08x", h.socketID)), packet size \(packetSize) (offered \(offer)), "
                + "sending at \(sendPacketSize)\(config.probeMTU ? " until probed" : ""), peer flow window \(h.flowWindow), peer ISN \(h.initialSequence)")
            set(.connected(serverSocket: h.socketID))
            if config.probeMTU && packetSize > sendPacketSize {
                probeLow = sendPacketSize
                probeHigh = packetSize
                sendProbe(size: packetSize, server: h.socketID, now: now)
            } else {
                probeDone = true
            }
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
            probeTimeout(server: server, now: now)
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
        noteArrival(seq, now: now)
        guard let expected = rcvNext else { return }
        let d = Self.diff(seq, expected)
        if d < 0 || buffered[seq] != nil {
            stats.duplicatesReceived += 1
            return
        }
        // UDT's receiver buffer (F-08): a packet at or beyond the window we advertised is dropped, so a peer (or an
        // injected datagram) cannot make us buffer or walk gaps without bound. A correct peer never sends one; the
        // packet is lost to it, and its retransmission comes once the window has moved.
        if d >= Int(config.flowWindow) {
            stats.beyondWindow += 1
            if stats.beyondWindow == 1 || stats.beyondWindow % 1000 == 0 {
                log("EDT data \(d) packets ahead of the next expected, beyond the flow window \(config.flowWindow): dropped (\(stats.beyondWindow) so far)")
            }
            return
        }
        rcvLoss[seq] = nil
        if d > 0 {
            stats.outOfOrder += 1
            buffered[seq] = payload
            // A new gap opens only past the highest packet received so far: report it at once. Walking from there (not
            // from the next expected) keeps the work per packet bounded by how far the highest moves (F-08).
            let highest = rcvHighest ?? Self.add(expected, -1)
            guard Self.diff(seq, highest) > 0 else { return }   // fills an old gap
            rcvHighest = seq
            var newLoss: [UInt32] = []
            var s = Self.add(highest, 1)
            while Self.diff(seq, s) > 0 {
                if buffered[s] == nil, rcvLoss[s] == nil { newLoss.append(s) }
                s = Self.add(s, 1)
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
        if let h = rcvHighest, Self.diff(next, h) > 0 { rcvHighest = nil }
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
        ack.receiveRate = UInt32(min(Double(UInt32.max), arrivalRate))
        ack.linkCapacity = UInt32(min(Double(UInt32.max), linkCapacity))
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

    // MARK: Receive-side estimates (UDT [P], D135)

    /// Arrival intervals of the last 16 data packets and the gaps of packet pairs (sequence ≡ 0 then ≡ 1 mod 16, which
    /// a UDT sender sends back to back): the packet arrival rate and the link capacity, in packets per second.
    private func noteArrival(_ seq: UInt32, now: Double) {
        if let last = lastArrival {
            arrivalIntervals.append(now - last)
            if arrivalIntervals.count > 16 { arrivalIntervals.removeFirst() }
        }
        lastArrival = now
        if seq & 0xF == 0 {
            pairStart = (seq, now)
        } else if seq & 0xF == 1, let p = pairStart, seq == Self.add(p.seq, 1) {
            pairIntervals.append(now - p.at)
            if pairIntervals.count > 16 { pairIntervals.removeFirst() }
            pairStart = nil
        }
    }

    /// Packets per second from the median-filtered intervals (UDT: intervals within 1/8…8× the median), 0 if unknown.
    public var arrivalRate: Double { Self.rate(arrivalIntervals, minimum: 8) }
    public var linkCapacity: Double { Self.rate(pairIntervals, minimum: 4) }

    static func rate(_ intervals: [Double], minimum: Int) -> Double {
        guard intervals.count >= minimum else { return 0 }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 0 else { return 0 }
        let kept = intervals.filter { $0 > median / 8 && $0 < median * 8 }
        guard kept.count > intervals.count / 2 else { return 0 }
        let mean = kept.reduce(0, +) / Double(kept.count)
        return mean > 0 ? 1 / mean : 0
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
            // Only what is in flight can be lost: the ranges are clipped to it (F-09).
            for s in EDTLossList.decode(body, from: sndUna, to: sndNext) where inFlight[s] != nil {
                lossList.insert(s)
                lost += 1
            }
            if lost > 0 { lossEvent(now: now, timeout: false, lost: lost) }
            pump(now: now)
        case .shutdown?:
            set(.closed(reason: "peer shutdown"))
        case .handshake?:
            break  // a late handshake reply
        case .mtuProbe?:
            // The peer probes its path to us: echo it at the same size [I] (the VDA does so for ours [L]).
            let probe = EDTPacket.control(type: type, reserved: 0, info: info, timestamp: 0, destination: server, body: body)
            if let reply = probe.mtuProbeReply(destination: server) { emit(reply, now: now) }
        case .mtuProbeReply?:
            probeAnswered(size: body.count + EDTPacket.headerSize + 28, server: server, now: now)
        default:
            stats.unknownControl += 1
            if stats.unknownControl <= 5 { log("EDT unknown control type \(String(format: "0x%04x", type)): info \(info), \(body.count) B \(hex(body.prefix(24)))") }
        }
    }

    private func updateRTT(_ sample: Double) {
        guard sample > 0, sample < 10 else { return }
        minRTT = min(minRTT, sample)
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
        // Slow start to the first loss; then +12.5 % per RTT while the RTT stays near its minimum (no queue
        // building), else +1 packet per RTT.
        if window < ssthresh {
            window += Double(acked)
        } else if minRTT.isFinite, rtt < 1.25 * minRTT + 0.002 {
            window += Double(acked) * 0.125
        } else {
            window += Double(acked) / window
        }
        window = min(window, config.maxWindow)
        pump(now: now)
    }

    /// `lost`: packets newly reported lost (NAK). A decrease needs a congestion signal: in the current epoch (one RTT)
    /// at least `congestionLossShare` of the window lost, or the RTT up by half over its minimum. Random loss of a few
    /// percent alone does not shrink the window (retransmission repairs it); it only ends slow start.
    private func lossEvent(now: Double, timeout: Bool, lost: Int = 0) {
        if timeout {
            ssthresh = max(config.initialWindow, window / 2)
            window = config.initialWindow
            lastDecrease = now
            return
        }
        if now - epochStart >= max(rtt, 0.01) { epochStart = now; epochLosses = 0 }
        epochLosses += lost
        if window < ssthresh { ssthresh = window }
        let heavy = Double(epochLosses) >= max(3, config.congestionLossShare * window)
        let queueing = minRTT.isFinite && rtt > 1.5 * minRTT + 0.005
        guard heavy || queueing, now - lastDecrease >= rtt else { return }
        window = max(4, window * config.decrease)
        ssthresh = window
        lastDecrease = now
        epochLosses = 0
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

    private func refill(now: Double) {
        guard config.pacing else { return }
        let rate = min(window, peerWindow) / max(rtt, 0.002)   // packets per second
        tokens = min(max(2, rate * 0.02), tokens + (now - lastRefill) * rate)
        lastRefill = now
    }

    private func takeToken() -> Bool {
        guard config.pacing else { return true }
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    private func pump(now: Double) {
        guard case .connected(let server) = state else { return }
        refill(now: now)
        let limit = Int(min(window, peerWindow))
        // Retransmissions first, oldest first.
        if !lossList.isEmpty {
            for s in lossList.sorted(by: { Self.diff($0, $1) < 0 }) {
                guard takeToken() else { break }
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
        while inFlight.count < limit, pendingHead < pendingBytes.count, takeToken() {
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

    // MARK: Path MTU probing (D135)

    private var probeWait: Double { max(0.3, 3 * rtt) }

    /// `size`: the IP packet size under test (the datagram is `size - 28` bytes).
    private func sendProbe(size: Int, server: UInt32, now: Double) {
        probeCounter &+= 1
        let tries = (probing?.size == size ? probing!.tries : 0) + 1
        probing = (size, probeCounter, now, tries)
        emit(EDTPacket.mtuProbe(destination: server, counter: probeCounter, size: size - 28), now: now)
    }

    private func probeAnswered(size: Int, server: UInt32, now: Double) {
        guard let p = probing, size == p.size else { return }
        probeReplies += 1
        probing = nil
        probeLog.append((size, true))
        probeLow = max(probeLow, size)
        if size > sendPacketSize {
            sendPacketSize = size
            log("EDT path MTU: \(size) B answered, sending at \(size) (payload \(payloadSize) B)")
        }
        nextProbe(server: server, now: now)
    }

    private func probeTimeout(server: UInt32, now: Double) {
        guard let p = probing, now - p.sentAt >= probeWait else { return }
        if p.tries < 2 { return sendProbe(size: p.size, server: server, now: now) }
        probing = nil
        probeLog.append((p.size, false))
        if probeReplies == 0 && p.size <= config.minPacketSize {
            // No echo even at the minimum: a peer without probe replies. Use the usual safe size.
            probeDone = true
            sendPacketSize = min(packetSize, config.fallbackPacketSize)
            return log("EDT path MTU: no probe answered; sending at \(sendPacketSize) without probing")
        }
        probeHigh = p.size - 1
        nextProbe(server: server, now: now)
    }

    private func nextProbe(server: UInt32, now: Double) {
        if probeHigh - probeLow < 16 {
            if probeReplies == 0, probeLog.last?.size != config.minPacketSize {
                // Nothing answered yet: check the minimum itself before concluding (fallback above).
                return sendProbe(size: config.minPacketSize, server: server, now: now)
            }
            probeDone = true
            log("EDT path MTU: done, sending at \(sendPacketSize) B (probes: "
                + probeLog.map { "\($0.size)\($0.answered ? "+" : "-")" }.joined(separator: " ") + ")")
            if let narrower = pathBelowNegotiated {
                // The peer sends at the negotiated size, which our probes say the path does not carry (docs/80 §8.8).
                log("EDT path MTU: the path carries \(narrower) B, less than the negotiated \(packetSize) B; the server's "
                    + "larger packets may be lost on the way to us")
                onPathBelowNegotiated(narrower)
            }
            return
        }
        let mid = ((probeLow + probeHigh + 1) / 2) & ~3
        sendProbe(size: max(probeLow + 4, mid), server: server, now: now)
    }

    public var mtuProbingDone: Bool { probeDone }

    /// After probing: the largest size the path carried, when that is below the negotiated size (the peer's packets at
    /// the negotiated size may then never reach us, docs/80 §8.8); nil while probing, or when the negotiated size fits.
    public var pathBelowNegotiated: Int? {
        probeDone && probeReplies > 0 && sendPacketSize < packetSize ? sendPacketSize : nil
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

    /// Most sequence numbers `decode(_:)` returns for one body (F-09): a 1,280-byte NAK of 160 ranges once expanded to
    /// ten million.
    public static let maxDecoded = 65_536

    /// The sequence numbers of a loss list, at most `maxDecoded`.
    public static func decode(_ body: [UInt8]) -> [UInt32] {
        var out: [UInt32] = []
        forEachRange(body) { first, last in
            var s = first
            while EDTConnection.diff(last, s) >= 0, out.count < maxDecoded { out.append(s); s = EDTConnection.add(s, 1) }
            return out.count < maxDecoded
        }
        return out
    }

    /// The sequence numbers of a loss list within `[from, to)` (31-bit, wrapping): each range is clipped to that interval
    /// before it is walked, so the work is bounded by the interval, not by what the peer claims (F-09).
    public static func decode(_ body: [UInt8], from lower: UInt32, to upper: UInt32) -> [UInt32] {
        let span = EDTConnection.diff(upper, lower)
        guard span > 0 else { return [] }
        var out: [UInt32] = []
        forEachRange(body) { first, last in
            // Offsets from `lower`, clipped to [0, span).
            let a = max(0, EDTConnection.diff(first, lower)), b = min(span - 1, EDTConnection.diff(last, lower))
            if a <= b, EDTConnection.diff(last, first) >= 0 {
                for k in a...b { out.append(EDTConnection.add(lower, k)) }
            }
            return out.count < span
        }
        return out
    }

    /// Calls `body` with each (first, last) of the list (a single number as (n, n)) until it returns false.
    private static func forEachRange(_ list: [UInt8], _ body: (UInt32, UInt32) -> Bool) {
        var i = 0
        func u32(_ k: Int) -> UInt32 { UInt32(list[k]) << 24 | UInt32(list[k + 1]) << 16 | UInt32(list[k + 2]) << 8 | UInt32(list[k + 3]) }
        while i + 4 <= list.count {
            let v = u32(i)
            let keepGoing: Bool
            if v & 0x8000_0000 != 0, i + 8 <= list.count {
                keepGoing = body(v & 0x7FFF_FFFF, u32(i + 4) & 0x7FFF_FFFF)
                i += 8
            } else {
                keepGoing = body(v & 0x7FFF_FFFF, v & 0x7FFF_FFFF)
                i += 4
            }
            if !keepGoing { return }
        }
    }
}
