import Testing
import Foundation
import Network
@testable import ICAKit

/// In-process CGP server on loopback TCP (no TLS), written from docs/20 §3.3–3.12 on the server
/// side: counts the client's sequenced packets, acks them, keeps its own retransmit queue, and
/// answers a resume bind with nextSeq = received + 1 followed by its unacknowledged packets.
/// All state lives on `queue`. Nothing runs on a timer: keepalives go out when the test calls
/// `sendKeepalive`, so their timing is explicit relative to the client's manual clock.
final class FakeCGPServer: @unchecked Sendable {
    struct Bind {
        var reconnect: UInt8
        var nextSeq: UInt32
        var serverByte: UInt8
        var cookie: [UInt8]
        var ticketType: UInt8
        var ticket: [UInt8]
        var item: [UInt8]
        var capOrder: [Int]
    }

    let queue = DispatchQueue(label: "fake.cgp")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    // Behaviour (set on `queue` or before the client connects).
    var srTimeout = 180
    var keepaliveMs: UInt32 = 3000
    var refuseResume = false
    var finishResumeReason: UInt8?
    var closeResumeAttempts = 0
    var rejectConnections = false
    /// Close the connection right after the first bind response (the early drop, D10).
    var dropAfterBind = false
    /// Drop the link once this many client packets have been processed: the rest of that read is
    /// lost and `loseOnDrop` server packets are queued but never written (in flight).
    var dropAtClientPacket: Int?
    var loseOnDrop = 0
    /// Stop reading and writing (keepalives included) without closing: a stalled path.
    var stalled = false

    private var connection: NWConnection?
    private var generation = 0
    private var buffer = Data()
    private var sawSignature = false
    private var writing = true

    // Client → server.
    private(set) var received = 0
    private(set) var lastAckedToClient = 0
    private(set) var clientICA = Data()
    private(set) var detectReplies = 0
    private(set) var binds: [Bind] = []
    private(set) var finishRequests = 0
    private(set) var finishResponses = 0
    private(set) var connections = 0
    private(set) var resumeProblems: [String] = []

    // Server → client.
    private var txQueue: [Data] = []
    private(set) var txAcked = 0
    private(set) var txSent = 0
    let stream = U32Stream()
    private var cookie: [UInt8] = Array(repeating: 0xa1, count: 16)
    private var ticket: [UInt8] = Array(repeating: 0x54, count: 87)
    private var ticketType: UInt8 = 0x02
    private(set) var keepalivesSent = 0

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = CGPSink()   // non-empty once resumed
            listener.stateUpdateHandler = { state in
                guard done.packets.isEmpty else { return }
                switch state {
                case .ready: done.packets.append(Data()); continuation.resume()
                case .failed(let error): done.packets.append(Data()); continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    /// One server keepalive (what a keepalive timer with `keepaliveMs` would send). Call on `queue`.
    func sendKeepalive() {
        keepalivesSent += 1
        write(Data([0x03, 0x05, 0x08, 0x00]))
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            listener?.cancel()
        }
    }

    func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    private func accept(_ c: NWConnection) {
        if rejectConnections { c.cancel(); return }
        connections += 1
        connection?.cancel()
        generation += 1
        connection = c
        buffer = Data()
        sawSignature = false
        writing = true
        stalled = false
        let current = generation
        c.start(queue: queue)
        receive(c, current)
        TestSignal.shared.notify()
    }

    private func receive(_ c: NWConnection, _ current: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, current == self.generation else { return }
            defer { TestSignal.shared.notify() }
            if let data, !data.isEmpty, !self.stalled { self.consume(data) }
            if complete || error != nil {
                if current == self.generation { self.connection = nil }
                return
            }
            self.receive(c, current)
        }
    }

    private func write(_ data: Data) {
        guard writing, !stalled, let connection else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Ends the current connection (TCP FIN, no CGP FINISH).
    func drop() {
        generation += 1
        connection?.cancel()
        connection = nil
        TestSignal.shared.notify()
    }

    // MARK: Server → client

    /// Next chunk of the server's u32 counter stream as one sequenced data packet.
    func sendChunk(_ count: Int) { sendData(stream.next(count)) }

    /// Writes only the first half of the next data packet, then closes: the client holds a partial
    /// packet when the link dies. The whole packet stays queued for the resume.
    func dropMidPacket() {
        writing = false
        sendChunk(8)
        guard let packet = txQueue.last, let connection else { return }
        connection.send(content: packet.prefix(packet.count / 2), completion: .contentProcessed { _ in })
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.drop() }
    }

    private func sendData(_ ica: Data) {
        let delta = received - lastAckedToClient
        let packet: [UInt8]
        if delta > 0, connection != nil {
            packet = CGPFixture.dataWithAck(delta, Array(ica))
            lastAckedToClient = received
        } else {
            packet = CGPFixture.data(Array(ica))
        }
        sendSequenced(Data(packet))
    }

    private func sendSequenced(_ packet: Data) {
        txSent += 1
        txQueue.append(CGPSession.zeroingAck(packet))
        write(packet)
    }

    private func clientAcked(_ n: Int) {
        txAcked += n
        txQueue.removeFirst(min(n, txQueue.count))
    }

    // MARK: Client → server

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        if !sawSignature {
            guard buffer.count >= 7 else { return }
            guard buffer.prefix(7) == CGPSession.signature else { resumeProblems.append("bad client signature"); return drop() }
            buffer = Data(buffer.dropFirst(7))
            sawSignature = true
        }
        while true {
            var r = ByteReader(buffer)
            guard let length = try? r.varlen(), r.remaining >= length, length >= 1 else { break }
            let header = r.offset
            let frame = Data(buffer.prefix(header + length))
            let packet = Data(buffer.dropFirst(header).prefix(length))
            buffer = Data(buffer.dropFirst(header + length))
            process(packet, frame: frame)
            if connection == nil { return }
            if let at = dropAtClientPacket, received >= at {
                dropAtClientPacket = nil
                writing = false
                for _ in 0..<loseOnDrop { sendChunk(5) }
                drop()
                return
            }
        }
        if received - lastAckedToClient >= 3 {
            write(Data(CGPFixture.ack(received - lastAckedToClient)))
            lastAckedToClient = received
        }
    }

    private func process(_ packet: Data, frame: Data) {
        var r = ByteReader(packet)
        guard let command = try? r.u8() else { return }
        switch command {
        case 0x01:
            bind(r.rest())
        case 0x06:
            received += 1
            // Open response, then the ICA detect string, both sequenced.
            sendSequenced(Data(CGPFixture.openResponse()))
            sendSequenced(Data(CGPFixture.data(Array(CGPSession.icaDetect))))
        case 0x0a:
            received += 1
            ica(r.rest())
        case 0x0b:
            clientAcked((try? r.varlen()) ?? 0)
            received += 1
            ica(r.rest())
        case 0x05:
            guard (try? r.u8()) == 0x08, let rflags = try? r.u8() else { return }
            if rflags & 0x02 != 0 { clientAcked((try? r.varlen()) ?? 0) }
            if rflags & 0x01 != 0 { received += 1 }
        case 0x03: finishRequests += 1
        case 0x04: finishResponses += 1
        default: resumeProblems.append("unexpected client command \(command)")
        }
    }

    private func ica(_ payload: Data) {
        if payload == CGPSession.icaDetect { detectReplies += 1 } else { clientICA.append(payload) }
    }

    private func bind(_ body: Data) {
        var r = ByteReader(body)
        _ = try? r.u8(); _ = try? r.u16()
        var info = Bind(reconnect: 0, nextSeq: 0, serverByte: 0, cookie: [], ticketType: 0, ticket: [], item: [], capOrder: [])
        for _ in 0..<((try? r.varlen()) ?? 0) {
            guard var c = (try? r.bytes()).map(ByteReader.init), (try? c.u16()) != nil, let id = try? c.u16(), (try? c.u16()) != nil else { break }
            info.capOrder.append(Int(id))
            if id == 5 {
                _ = try? c.raw(3); _ = try? c.bytes(); _ = try? c.u8(); _ = try? c.bytes()
                info.nextSeq = (try? c.u32()) ?? 0
                info.reconnect = (try? c.u8()) ?? 0
                info.serverByte = (try? c.u8()) ?? 0
                info.cookie = Array((try? c.bytes()) ?? Data())
                if (try? c.varlen()) == 1 { info.item = Array(c.rest()) }
            } else if id == 6 {
                info.ticketType = (try? c.u8()) ?? 0
                info.ticket = Array((try? c.bytes()) ?? Data())
            }
        }
        binds.append(info)
        if info.reconnect == 0 {
            write(CGPSession.signature + Data(CGPFixture.bindResponse([
                CGPFixture.ticketCap(type: ticketType, ticket),
                CGPFixture.srCap(nextSeq: 0, serverByte: 0x02, cookie: cookie),
                CGPFixture.paramsCap(timeout: srTimeout, dimming: 80),
                CGPFixture.keepaliveCap(c2h: keepaliveMs, h2c: keepaliveMs),
                CGPFixture.servicesCap])))
            if dropAfterBind { queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.drop() } }
            return
        }
        if closeResumeAttempts > 0 { closeResumeAttempts -= 1; return drop() }
        if let reason = finishResumeReason {
            return write(CGPSession.signature + Data(CGPFixture.finish(reason: reason)))
        }
        if refuseResume {
            return write(CGPSession.signature + Data(CGPFixture.bindResponse([
                CGPFixture.srCap(nextSeq: 0, reconnect: 1, serverByte: 0x02, cookie: [])])))
        }
        // Check what the client claims against our state.
        if info.cookie != cookie { resumeProblems.append("stale cookie") }
        if info.ticket != ticket || info.ticketType != ticketType { resumeProblems.append("stale ticket") }
        let wanted = Int(info.nextSeq)
        if wanted < txAcked + 1 || wanted - (txAcked + 1) > txQueue.count {
            resumeProblems.append("client nextSeq \(wanted) outside \(txAcked + 1)…\(txAcked + txQueue.count + 1)")
            return drop()
        }
        clientAcked(wanted - (txAcked + 1))
        // A new cookie and ticket for the next resume (§3.12.10).
        cookie = cookie.map { $0 &+ 1 }
        ticket = ticket.map { $0 &+ 1 }
        ticketType &+= 1
        write(CGPSession.signature + Data(CGPFixture.bindResponse([
            CGPFixture.ticketCap(type: ticketType, ticket),
            CGPFixture.srCap(nextSeq: UInt32(received + 1), reconnect: 1, serverByte: 0x02, cookie: cookie)])))
        lastAckedToClient = received
        txQueue.forEach(write)
    }
}

/// Consecutive u32 values (big-endian) split into chunks; `verify` checks a received stream has
/// every value exactly once and in order.
final class U32Stream: @unchecked Sendable {
    private(set) var produced: UInt32 = 0

    func next(_ count: Int) -> Data {
        var d = Data()
        for _ in 0..<count {
            withUnsafeBytes(of: produced.bigEndian) { d.append(contentsOf: $0) }
            produced += 1
        }
        return d
    }

    static func verify(_ data: Data, count: UInt32) -> String? {
        guard data.count == Int(count) * 4 else { return "\(data.count / 4) values, expected \(count)" }
        let bytes = [UInt8](data)
        for i in 0..<Int(count) {
            let v = bytes[(4 * i)..<(4 * i + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if v != UInt32(i) { return "value \(v) at index \(i)" }
        }
        return nil
    }
}


/// The client side: a `CGPTransport` on a manual clock with short timings, collecting ICA bytes and
/// events. Its timers only run when the test advances `clock`; the network is real (loopback).
final class ResumeClient: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.cgp.client")
    let clock = ManualCGPClock()
    let transport: CGPTransport
    let stream = U32Stream()
    /// Mark the transport established at the detect string (the real session waits for Thinwire INIT).
    var establishOnDetect = true
    private let lock = NSLock()
    private var _ica = Data()
    private var _events: [String] = []
    private var _logs: [String] = []
    private var _keepalives = 0
    private var _closedAt: TimeInterval?
    private var _giveUp: CGPTransport.GiveUp?
    private var _resumes: [CGPSession.ResumeResult] = []
    private var _detect = false
    private var _closed = false

    init(port: UInt16, configure: (inout CGPTransport.Timing) -> Void = { _ in }) {
        _ = TestCPULoad.started
        transport = CGPTransport(host: "127.0.0.1", port: port, tls: false, ticket: "STA-TICKET", queue: queue, clock: clock)
        var timing = CGPTransport.Timing()
        timing.startDelay = 0.05
        timing.retryDelay = 0.05
        // TLSStream's connect timeout runs on real time: only a hang guard here.
        timing.connectTimeout = 30
        timing.firstReadTimeout = 2
        timing.tick = 0.05
        timing.livenessInterval = 0.1
        configure(&timing)
        transport.timing = timing
        transport.onEvent = { [weak self] event in self?.record(event) }
    }

    private func record(_ event: CGPTransport.Event) {
        lock.lock()
        switch event {
        case .data(let d): _ica.append(d)
        case .detect:
            _detect = true
            if establishOnDetect { transport.markEstablished() }
        case .suspended(let s): _events.append("suspended: \(s.reason)")
        case .resuming(let n): _events.append("resuming \(n)")
        case .resumed(let r): _resumes.append(r); _events.append("resumed")
        case .gaveUp(let g): _giveUp = g; _events.append("gave up")
        case .closed(let reason): _closed = true; _closedAt = clock.elapsed; _events.append("closed: \(reason)")
        case .keepalive: _keepalives += 1
        case .log(let text): _logs.append(text)
        case .bound, .channelOpened: break
        }
        lock.unlock()
        TestSignal.shared.notify()
    }

    private func read<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var ica: Data { read { _ica } }
    var events: [String] { read { _events } }
    var logs: [String] { read { _logs } }
    /// Server keepalives received.
    var keepalives: Int { read { _keepalives } }
    /// Clock time of the close.
    var closedAt: TimeInterval? { read { _closedAt } }
    var giveUp: CGPTransport.GiveUp? { read { _giveUp } }
    var resumes: [CGPSession.ResumeResult] { read { _resumes } }
    var sawDetect: Bool { read { _detect } }
    var closed: Bool { read { _closed } }
    var suspensions: Int { read { _events.filter { $0.hasPrefix("suspended") }.count } }
    var attemptsStarted: Int { read { _events.filter { $0.hasPrefix("resuming") }.count } }

    func sendChunk(_ count: Int) {
        let data = stream.next(count)
        transport.send(data, piggybackAck: true)
    }

    /// Time passes on the client (system awake).
    func advance(_ seconds: TimeInterval) { clock.advance(by: seconds) }

    /// Advances in `step`s until `condition` holds (checked between steps; timers record their
    /// events synchronously), at most `limit` s.
    @discardableResult
    func advance(step: TimeInterval = 0.05, limit: TimeInterval, until condition: () -> Bool) -> Bool {
        var elapsed = 0.0
        while !condition(), elapsed < limit {
            clock.advance(by: step)
            elapsed += step
        }
        return condition()
    }

    /// Everything handed to the transport queue so far (`perform` from outside is async) has run.
    func barrier() { queue.sync {} }
}

/// Starts server and client and waits for the detect exchange.
private func connectPair(configureServer: (FakeCGPServer) -> Void = { _ in },
                         timing: (inout CGPTransport.Timing) -> Void = { _ in }) async throws -> (FakeCGPServer, ResumeClient) {
    let server = FakeCGPServer()
    configureServer(server)
    try await server.start()
    let client = ResumeClient(port: server.port, configure: timing)
    try await client.transport.start()
    let ready = await eventually { client.sawDetect && server.sync { server.detectReplies == 1 } }
    #expect(ready, "detect exchange")
    return (server, client)
}

/// Sends `rounds` chunks each way, alternating, with a short pause (interleaving only; no time
/// passes on the client's clock).
private func exchange(_ server: FakeCGPServer, _ client: ResumeClient, rounds: Int) async {
    for i in 0..<rounds {
        client.sendChunk(1 + i % 7)
        server.queue.async { server.sendChunk(1 + i % 5) }
        if i % 4 == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
}

/// `seconds` pass on the client in steps of the server's keepalive interval. Each step starts with
/// a server keepalive (what the server's keepalive timer sends); with `delivered`, the client has
/// received it before its clock moves on. Stops early once `until` holds; returns `until()`.
@discardableResult
private func pump(_ server: FakeCGPServer, _ client: ResumeClient, _ seconds: TimeInterval, delivered: Bool = true,
                  until: () -> Bool = { false }, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    let step = Double(server.sync { server.keepaliveMs }) / 1000
    var elapsed = 0.0
    while elapsed < seconds - 1e-9, !until() {
        let before = client.keepalives
        server.sync { server.sendKeepalive() }
        if delivered {
            #expect(await eventually { client.keepalives > before }, "server keepalive delivered", sourceLocation: sourceLocation)
        }
        let d = min(step, seconds - elapsed)
        client.advance(d)
        elapsed += d
    }
    return until()
}

/// The start or retry delay passes until resume attempt `n` begins.
private func startAttempt(_ client: ResumeClient, _ n: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    client.barrier()
    #expect(client.advance(limit: 5) { client.attemptsStarted >= n }, "attempt \(n) started: \(client.events)", sourceLocation: sourceLocation)
}

/// Resume attempt `n` has failed (the retry is scheduled).
private func expectAttemptFailed(_ client: ResumeClient, _ n: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
    #expect(await eventually { client.logs.contains { $0.hasPrefix("resume attempt \(n) failed") } },
            "attempt \(n) failed: \(client.events)", sourceLocation: sourceLocation)
    client.barrier()
}

/// Suspension `n` happens, the start delay passes and resume `n` completes.
private func expectResume(_ client: ResumeClient, _ n: Int, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation) async {
    #expect(await eventually { client.suspensions >= n }, "suspension \(n) \(comment): \(client.events)", sourceLocation: sourceLocation)
    startAttempt(client, client.attemptsStarted + 1, sourceLocation: sourceLocation)
    #expect(await eventually { client.resumes.count >= n }, "resume \(n) \(comment): \(client.events)", sourceLocation: sourceLocation)
}

/// `close(timeout:)` from CONNECTED: FINISH goes out; the fake server never answers it, so the close
/// timeout passes on the client's clock.
private func closeConnected(_ client: ResumeClient, _ server: FakeCGPServer, timeout: TimeInterval) async {
    let closing = Task { await client.transport.close(timeout: timeout) }
    #expect(await eventually { server.sync { server.finishRequests } >= 1 }, "FINISH request on the wire")
    client.advance(timeout)
    await closing.value
}

/// Both streams complete, without gap or duplicate.
private func expectStreamsComplete(_ server: FakeCGPServer, _ client: ResumeClient, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clientTotal = client.stream.produced
    let serverTotal = server.sync { server.stream.produced }
    let done = await eventually {
        client.ica.count == Int(serverTotal) * 4 && server.sync { server.clientICA.count } == Int(clientTotal) * 4
    }
    #expect(done, "streams complete: client got \(client.ica.count / 4)/\(serverTotal), server got \(server.sync { server.clientICA.count } / 4)/\(clientTotal)", sourceLocation: sourceLocation)
    #expect(U32Stream.verify(client.ica, count: serverTotal) == nil, "server → client: \(U32Stream.verify(client.ica, count: serverTotal) ?? "")", sourceLocation: sourceLocation)
    let toServer = server.sync { server.clientICA }
    #expect(U32Stream.verify(toServer, count: clientTotal) == nil, "client → server: \(U32Stream.verify(toServer, count: clientTotal) ?? "")", sourceLocation: sourceLocation)
}

/// Session reliability against the fake server (docs/20 §3.12, D27, D50). Every client timer runs
/// on the client's manual clock, so load can delay these tests but not change their outcome.
@Suite struct CGPResumeEndToEndTests {

@Test func resumeAfterServerDropKeepsBothStreamsIntact() async throws {
    let (server, client) = try await connectPair()
    defer { server.stop() }
    await exchange(server, client, rounds: 40)
    // Drop mid-stream: client packets of that read are lost, 3 server packets never leave.
    server.queue.async {
        server.dropAtClientPacket = server.received + 5
        server.loseOnDrop = 3
    }
    await exchange(server, client, rounds: 30)   // continues while suspended: queued on both sides
    await expectResume(client, 1, "first resume")
    await exchange(server, client, rounds: 20)
    await expectStreamsComplete(server, client)

    // A second drop: the resume bind must carry the cookie and ticket of the last resume response.
    server.queue.async { server.drop() }
    await exchange(server, client, rounds: 10)
    await expectResume(client, 2, "second resume")
    await expectStreamsComplete(server, client)

    let binds = server.sync { server.binds }
    #expect(binds.count == 3)
    #expect(binds.map(\.reconnect) == [0, 1, 1])
    #expect(binds.allSatisfy { $0.capOrder == [5, 9, 7, 1, 6, 2] })
    #expect(binds[1].cookie == Array(repeating: 0xa1, count: 16) && binds[1].ticketType == 0x02)
    #expect(binds[2].cookie == Array(repeating: 0xa2, count: 16) && binds[2].ticketType == 0x03)
    #expect(binds[2].ticket == Array(repeating: 0x55, count: 87))
    #expect(binds[1].item == CGPFixture.openRequest && binds[2].item == CGPFixture.openRequest)
    #expect(binds[0].ticket == Array("STA-TICKET".utf8))
    #expect(server.sync { server.resumeProblems }.isEmpty, "\(server.sync { server.resumeProblems })")
    #expect(server.sync { (server.detectReplies, server.finishRequests) } == (1, 0))
    let first = client.resumes[0]
    #expect(first.retransmitted > 0, "client packets queued during the outage were retransmitted")
    #expect(first.dropped + first.retransmitted == first.queueBefore)
    let status = client.transport.status
    #expect(status.state == .connected && status.ackOverrun == 0)
    await closeConnected(client, server, timeout: 1)
    #expect(client.events.last == "closed: closed after finish timeout", "\(client.events)")
    #expect(server.sync { server.finishRequests } == 1)   // FINISH only from CONNECTED
}

@Test func resumeAfterClientDropAndAFailedFirstAttempt() async throws {
    // Client-side abrupt drop (test hook); the server closes the first resume connection without a
    // bind response; the client retries from state 6 and resumes (deviation, §3.12.1).
    let server = FakeCGPServer()
    server.closeResumeAttempts = 1
    try await server.start()
    defer { server.stop() }
    let client = ResumeClient(port: server.port)
    client.transport.testDropAfter = 0.4
    try await client.transport.start()
    #expect(await eventually { client.sawDetect })
    await exchange(server, client, rounds: 15)
    client.advance(0.4)                          // the drop hook fires
    #expect(client.suspensions == 1, "\(client.events)")
    await exchange(server, client, rounds: 15)   // queued while suspended
    startAttempt(client, 1)
    await expectAttemptFailed(client, 1)
    startAttempt(client, 2)
    #expect(await eventually { client.resumes.count == 1 }, "\(client.events)")
    await exchange(server, client, rounds: 10)
    await expectStreamsComplete(server, client)
    #expect(client.events.filter { $0.hasPrefix("resuming") }.count == 2)
    #expect(server.sync { server.binds.count } == 3)
    #expect(server.sync { server.resumeProblems }.isEmpty)
    #expect(client.transport.status.attempts == 2)
}

@Test func resumeRefusedWithNextSeqZeroGivesUpWithoutFinish() async throws {
    let (server, client) = try await connectPair { $0.refuseResume = true }
    defer { server.stop() }
    await exchange(server, client, rounds: 5)
    server.queue.async { server.drop() }
    #expect(await eventually { client.suspensions == 1 }, "\(client.events)")
    startAttempt(client, 1)
    #expect(await eventually { client.closed }, "\(client.events)")
    guard let g = client.giveUp else { Issue.record("no give-up"); return }
    if case .refused(.refused) = g.cause {} else { Issue.record("cause \(g.cause)") }
    #expect(g.message == "The session could not be resumed." && g.offerRelaunch)
    #expect(server.sync { (server.finishRequests, server.finishResponses) } == (0, 0))
    #expect(client.transport.status.state == .failed)
}

@Test func serverFinishInStateSixIsAnsweredAndEndsSR() async throws {
    let (server, client) = try await connectPair { $0.finishResumeReason = 0x11 }
    defer { server.stop() }
    server.queue.async { server.drop() }
    #expect(await eventually { client.suspensions == 1 }, "\(client.events)")
    startAttempt(client, 1)
    #expect(await eventually { client.closed }, "\(client.events)")
    #expect(client.giveUp?.message == "The gateway rejected the reconnect ticket.")
    // The FINISH_RESPONSE is on the wire before the give-up; wait for the server to read it.
    #expect(await eventually { server.sync { server.finishResponses } >= 1 })
    #expect(server.sync { (server.finishRequests, server.finishResponses) } == (0, 1))
}

@Test func deadlineEndsSRWhenTheServerIsUnreachable() async throws {
    // Cap 9 timeout 1 s is T_sr; every new connection is rejected.
    let (server, client) = try await connectPair { $0.srTimeout = 1 }
    defer { server.stop() }
    let started = client.clock.elapsed
    server.sync {
        server.rejectConnections = true
        server.drop()
    }
    #expect(await eventually { client.suspensions == 1 }, "\(client.events)")
    for n in 1...2 {
        startAttempt(client, n)
        await expectAttemptFailed(client, n)
    }
    // Retries go on until the T_sr timer (a wall timer) ends SR.
    #expect(client.advance(limit: 5) { client.closed }, "\(client.events)")
    let elapsed = (client.closedAt ?? .infinity) - started
    #expect(elapsed >= 1 && elapsed < 3, "gave up after \(elapsed) s")
    if case .deadline = client.giveUp?.cause {} else { Issue.record("cause \(String(describing: client.giveUp?.cause))") }
    #expect(client.transport.status.attempts >= 2)
}

@Test func livenessTimeoutSuspendsAStalledLinkAndResumes() async throws {
    // Server keepalives every 100 ms; liveness limit 0.5 s. The server stalls without closing.
    let (server, client) = try await connectPair(configureServer: { $0.keepaliveMs = 100 }) { $0.livenessMinimum = 0.5 }
    defer { server.stop() }
    await exchange(server, client, rounds: 10)
    await pump(server, client, 0.8)
    #expect(client.events.isEmpty, "keepalives keep the link alive: \(client.events)")
    server.sync { server.stalled = true }
    await exchange(server, client, rounds: 10)
    // Stalled: the keepalives are not written, nothing arrives, liveness suspends.
    #expect(await pump(server, client, 2, delivered: false) { client.suspensions == 1 }, "\(client.events)")
    await expectResume(client, 1)
    #expect(client.events.first?.contains("nothing received") == true, "\(client.events)")
    await exchange(server, client, rounds: 10)
    await expectStreamsComplete(server, client)
}

@Test func userCloseWhileSuspendedSendsNoFinish() async throws {
    let (server, client) = try await connectPair { $0.rejectConnections = false }
    defer { server.stop() }
    server.queue.async {
        server.rejectConnections = true
        server.drop()
    }
    #expect(await eventually { client.events.contains { $0.hasPrefix("suspended") } })
    await client.transport.close(timeout: 1)
    #expect(client.closed && client.giveUp == nil)
    #expect(client.events.last == "closed: closed while suspended (no FINISH)")
    #expect(server.sync { server.finishRequests } == 0)
}

@Test func blackholeHookStallsTheSocketUntilLivenessSuspends() async throws {
    // ICA_TEST_BLACKHOLE_AFTER=0.3:60 equivalent: no reads or writes for 60 s (real) while the
    // server keeps sending keepalives → liveness (0.5 s) suspends.
    let server = FakeCGPServer()
    server.keepaliveMs = 100
    try await server.start()
    defer { server.stop() }
    let client = ResumeClient(port: server.port) { $0.livenessMinimum = 0.5 }
    client.transport.configureTestHooks(from: ["ICA_TEST_BLACKHOLE_AFTER": "0.3:60"])
    try await client.transport.start()
    #expect(await eventually { client.sawDetect })
    await exchange(server, client, rounds: 10)
    await pump(server, client, 0.3)              // healthy until the hook fires at 0.3 s
    #expect(client.events.isEmpty, "\(client.events)")
    #expect(client.logs.contains { $0.hasPrefix("test: blackhole") }, "hook fired")
    #expect(await pump(server, client, 2, delivered: false) { client.suspensions == 1 }, "\(client.events)")
    await expectResume(client, 1)
    #expect(client.events.first?.contains("nothing received") == true, "\(client.events)")
    await exchange(server, client, rounds: 10)
    await expectStreamsComplete(server, client)
}

@Test func wakeCheckSuspendsWhenNothingArrives() async throws {
    let (server, client) = try await connectPair(configureServer: { $0.keepaliveMs = 100 }) { $0.wakeCheckMinimum = 0.3 }
    defer { server.stop() }
    client.advance(0.05)               // a quiet moment: data after the wake is distinguishable
    client.transport.systemDidWake()   // link alive: the server's data arrives in time, no suspend
    client.barrier()
    await pump(server, client, 0.5)
    #expect(client.events.isEmpty, "\(client.events)")
    server.sync { server.stalled = true }
    client.advance(0.05)
    client.transport.systemDidWake()
    client.barrier()
    #expect(client.advance(limit: 1) { client.suspensions == 1 }, "\(client.events)")
    await expectResume(client, 1)
    #expect(client.events.first?.contains("after wake") == true, "\(client.events)")
    await exchange(server, client, rounds: 5)
    await expectStreamsComplete(server, client)
}

@Test func offlineEventSuspendsAfterVerificationAndOnlineResumes() async throws {
    let (server, client) = try await connectPair(configureServer: { $0.keepaliveMs = 100 }) { $0.pathVerification = 0.3 }
    defer { server.stop() }
    server.sync { server.stalled = true }
    client.advance(0.05)
    client.transport.networkChanged(online: false)
    client.barrier()
    #expect(client.advance(limit: 1) { client.events.contains { $0.hasPrefix("suspended") } }, "\(client.events)")
    client.advance(0.3)   // attempts come due but wait for the network
    #expect(client.transport.status.attempts == 0, "no attempt while offline")
    client.sendChunk(3)   // built while offline: queued
    client.transport.networkChanged(online: true)
    await expectResume(client, 1)
    await expectStreamsComplete(server, client)
}

@Test func dropInTheMiddleOfAPacketDiscardsThePartAndResumes() async throws {
    let (server, client) = try await connectPair()
    defer { server.stop() }
    await exchange(server, client, rounds: 20)
    #expect(await eventually { client.ica.count == Int(server.sync { server.stream.produced }) * 4 })
    server.queue.async { server.dropMidPacket() }
    await expectResume(client, 1)
    await exchange(server, client, rounds: 10)
    await expectStreamsComplete(server, client)
    #expect(server.sync { server.resumeProblems }.isEmpty)
}

@Test func networkEventOnAHealthyLinkDoesNotSuspend() async throws {
    let (server, client) = try await connectPair(configureServer: { $0.keepaliveMs = 100 }) { $0.pathVerification = 0.3 }
    defer { server.stop() }
    client.advance(0.05)
    client.transport.networkChanged(online: true)    // path change while connected
    client.transport.networkChanged(online: false)
    client.barrier()
    await pump(server, client, 0.7)
    #expect(client.events.isEmpty, "\(client.events)")
    #expect(client.transport.status.state == .connected)
}

@Test func tickThatSeesASleepGapRunsTheWakeCheck() async throws {
    let (server, client) = try await connectPair(configureServer: { $0.keepaliveMs = 100 }) { $0.wakeCheckMinimum = 0.3 }
    defer { server.stop() }
    // Healthy link: a sleep gap only triggers a keepalive and a check that passes.
    client.clock.sleep(for: 60)   // system sleep: the continuous clock runs on, the uptime clock stops
    client.advance(0.05)          // the next tick sees the gap
    #expect(client.logs.contains { $0.hasPrefix("sleep gap seen by the timer") }, "\(client.logs.suffix(3))")
    await pump(server, client, 0.6)
    #expect(client.events.isEmpty, "\(client.events)")
    // Dead link after the "sleep": suspended by the wake check, not by the 25 s liveness rule.
    server.sync { server.stalled = true }
    client.clock.sleep(for: 60)
    #expect(client.advance(limit: 1) { client.suspensions == 1 }, "\(client.events)")
    await expectResume(client, 1)
    #expect(client.events.first?.contains("sleep gap") == true, "\(client.events)")
    await expectStreamsComplete(server, client)
}

@Test func queueOverLimitWhileConnectedKeepsTheSessionWithoutSR() async throws {
    let (server, client) = try await connectPair()
    defer { server.stop() }
    client.transport.perform { client.transport.cgp.queueLimit = 64 }
    server.queue.async { server.stalled = true }   // no acks: the queue grows
    for _ in 0..<10 { client.sendChunk(8) }
    #expect(await eventually { client.transport.cgp.reliabilityAbandoned })
    server.queue.async { server.stalled = false }
    #expect(client.transport.status.state == .connected && client.transport.status.queued == 0)
    // A later dead link gives up at once: no resume attempt.
    server.queue.async { server.drop() }
    #expect(await eventually { client.closed }, "\(client.events)")
    if case .queueOverflow = client.giveUp?.cause {} else { Issue.record("\(String(describing: client.giveUp?.cause))") }
    #expect(client.transport.status.attempts == 0)
}

@Test func closeAfterTerminateEndsTheSessionWithoutResume() async throws {
    // Live: after WD TERMINATE the host closes TCP without CGP FINISH.
    let (server, client) = try await connectPair()
    defer { server.stop() }
    await exchange(server, client, rounds: 5)
    client.transport.expectServerClose("WD TERMINATE 1")
    client.barrier()
    server.queue.async { server.drop() }
    #expect(await eventually { client.closed }, "\(client.events)")
    #expect(!client.events.contains { $0.hasPrefix("suspended") || $0.hasPrefix("resuming") }, "\(client.events)")
    #expect(client.events.last?.hasPrefix("closed: ended by server: connection closed after WD TERMINATE 1") == true, "\(client.events)")
    #expect(client.giveUp == nil && client.transport.status.attempts == 0)
    #expect(client.transport.status.state == .closed)
    #expect(server.sync { server.finishRequests } == 0)
}

@Test func earlyDropBeforeEstablishmentClosesWithoutSR() async throws {
    // The gateway drops the link right after the bind response, before the session is established.
    let server = FakeCGPServer()
    server.dropAfterBind = true
    try await server.start()
    defer { server.stop() }
    let client = ResumeClient(port: server.port)
    client.establishOnDetect = false
    try await client.transport.start()
    #expect(await eventually { client.closed }, "\(client.events)")
    #expect(!client.events.contains { $0.hasPrefix("suspended") || $0.hasPrefix("resuming") }, "\(client.events)")
    #expect(client.events.last?.hasPrefix("closed: early drop: link closed before the session was established") == true, "\(client.events)")
    #expect(client.giveUp == nil && client.transport.status.attempts == 0 && !client.transport.isEstablished)
    #expect(server.sync { (server.connections, server.finishRequests) } == (1, 0))
}

}
