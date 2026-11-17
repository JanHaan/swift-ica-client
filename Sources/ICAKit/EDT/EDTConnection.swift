import Foundation

/// Client side of an EDT connection, skeleton (docs/80, D130): the two-round handshake, keep-alive, shutdown and an
/// idle timeout as observed [B]; data as whole messages with in-order delivery and cumulative ACKs in the UDT draft's
/// form [P], unobserved [I] (no loss recovery, no congestion control yet). Pure: datagrams go out through `send`,
/// time comes from `tick(now:)`; the caller owns the socket and the timer.
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
        public var maxPacketSize: UInt32 = 1500
        public var flowWindow: UInt32 = 16384
        /// Handshake retry interval and count [I] (the stock client never needed a retry).
        public var handshakeRetry: Double = 0.25
        public var handshakeAttempts = 20
        /// Keep-alive when nothing was sent this long (the VDA: 1.006 s) [B].
        public var keepAliveInterval: Double = 1
        /// Give up after this long without a datagram from the peer (the VDA: 20 s) [B].
        public var idleTimeout: Double = 20

        public init(peerIPv4: [UInt8], socketID: UInt32 = UInt32.random(in: 1...0x7FFF_FFFF),
                    initialSequence: UInt32 = UInt32.random(in: 0...0x7FFF_FFFF)) {
            self.peerIPv4 = peerIPv4
            self.socketID = socketID
            self.initialSequence = initialSequence
        }
    }

    public let config: Config
    public private(set) var state: State = .idle
    public private(set) var cookie: UInt32?
    /// Datagrams to the peer.
    public var send: ([UInt8]) -> Void = { _ in }
    /// In-order payloads from the peer (the CGP stream, docs/80 §1).
    public var deliver: ([UInt8]) -> Void = { _ in }
    public var onState: (State) -> Void = { _ in }
    /// Every datagram received, parsed (tests, probes).
    public var onPacket: (EDTPacket) -> Void = { _ in }
    public private(set) var keepAlivesReceived = 0

    private var start: Double = 0
    private var lastSent: Double = 0
    private var lastReceived: Double = 0
    private var attempts = 0
    private var lastHandshake: [UInt8] = []
    private var nextSequence: UInt32
    private var nextMessage: UInt32 = 1
    private var expectedSequence: UInt32?
    private var pending: [UInt32: [UInt8]] = [:]
    private var ackNumber: UInt32 = 1

    public init(config: Config) {
        self.config = config
        nextSequence = config.initialSequence
    }

    /// The stock client's handshakes carry `0007` in the low half of word 0 [B].
    static let clientReserved: UInt16 = 7

    public func connect(now: Double) {
        guard state == .idle else { return }
        start = now
        lastReceived = now
        let h = EDTHandshake(version: 4, initialSequence: config.initialSequence, connectionType: 1, socketID: config.socketID,
                             cookie: 0, peerIPv4: config.peerIPv4)
        sendHandshake(h, now: now)
        set(.induction)
    }

    public func close(now: Double, reason: String = "closed") {
        if case .connected(let server) = state { emit(EDTPacket.shutdown(destination: server), now: now) }
        if case .closed = state { return }
        set(.closed(reason: reason))
    }

    /// One whole message (position `11`) [B]; in order [I].
    public func sendMessage(_ payload: [UInt8], now: Double) {
        guard case .connected(let server) = state else { return }
        let packet = EDTPacket.data(sequence: nextSequence, position: 3, inOrder: false, message: nextMessage,
                                    timestamp: micros(now), destination: server, payload: payload)
        nextSequence = (nextSequence &+ 1) & 0x7FFF_FFFF
        nextMessage = (nextMessage &+ 1) & 0x1FFF_FFFF
        emit(packet, now: now)
    }

    public func receive(_ datagram: [UInt8], now: Double) {
        guard let packet = try? EDTPacket.parse(datagram) else { return }
        lastReceived = now
        onPacket(packet)
        if packet.destination != config.socketID && packet.destination != 0 { return }
        switch (state, packet.controlType) {
        case (.induction, .handshake?):
            guard let h = packet.handshake, h.connectionType == 1, h.cookie != 0 else { return }
            cookie = h.cookie
            let conclusion = EDTHandshake(version: 7, initialSequence: config.initialSequence, connectionType: -1,
                                          socketID: config.socketID, cookie: h.cookie, peerIPv4: config.peerIPv4,
                                          ext: (config.socketID, config.initialSequence))
            attempts = 0
            sendHandshake(conclusion, now: now)
            set(.conclusion)
        case (.conclusion, .handshake?):
            guard let h = packet.handshake, h.connectionType == -1, h.socketID != 0 else { return }
            expectedSequence = h.initialSequence
            set(.connected(serverSocket: h.socketID))
        case (.connected, .keepAlive?):
            keepAlivesReceived += 1
        case (_, .shutdown?):
            if case .closed = state { return }
            set(.closed(reason: "peer shutdown"))
        case (.connected(let server), nil):
            guard case .data(let seq, _, _, _, _, _, let payload) = packet else { return }
            accept(seq, payload)
            // Cumulative ACK of the next expected sequence, UDT style [P][I].
            if let next = expectedSequence {
                let ack = EDTAck(ackNumber: ackNumber, lastSequence: next)
                ackNumber &+= 1
                emit(ack.packet(destination: server, timestamp: micros(now)), now: now)
            }
        default:
            break
        }
    }

    /// Timers: handshake retries, keep-alive, idle timeout.
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
            if now - lastSent >= config.keepAliveInterval { emit(EDTPacket.keepAlive(destination: server), now: now) }
        default:
            break
        }
    }

    private func accept(_ seq: UInt32, _ payload: [UInt8]) {
        guard let expected = expectedSequence else { return }
        let ahead = (seq &- expected) & 0x7FFF_FFFF
        guard ahead < 0x4000_0000 else { return }  // older than expected: a duplicate
        pending[seq] = payload
        while let next = expectedSequence, let p = pending.removeValue(forKey: next) {
            deliver(p)
            expectedSequence = (next &+ 1) & 0x7FFF_FFFF
        }
    }

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

    private func set(_ s: State) {
        state = s
        onState(s)
    }
}
