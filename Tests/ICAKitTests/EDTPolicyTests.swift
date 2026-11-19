import Testing
import Foundation
import Network
@testable import ICAKit

// HDX over UDP from the ICA file (docs/80 §8.8, D177): the mode, the routes EDT is offered on, the test override, the
// packet size offered, and the transport's behaviour per mode against loopback fakes (a CGP server on TCP, an EDT
// peer on UDP that answers the handshake and nothing else).

private func ica(_ lines: [String]) -> ICAFile {
    ICAFile(text: "[WFClient]\nVersion=2\n[ApplicationServers]\nNotepad=\n[Notepad]\n" + lines.joined(separator: "\n") + "\n")!
}

private func choice(_ lines: [String], env: [String: String] = [:]) throws -> EDTChoice {
    let file = ica(lines)
    return EDTChoice.choose(ica: file, plan: try ICAConnectPlan(ica: file, environment: [:]), environment: env)
}

private let direct = ["Address=192.0.2.12:1494", "CGPAddress=*:2598"]

@Test func edtModeFromTheFile() {
    #expect(EDTMode(hdxOverUDP: "On") == .on && EDTMode(hdxOverUDP: "on") == .on && EDTMode(hdxOverUDP: " ON ") == .on)
    #expect(EDTMode(hdxOverUDP: "Preferred") == .preferred && EDTMode(hdxOverUDP: "pref") == .preferred)
    for value in ["Off", "off", "", "true", "yes", "1", "Diagnostic"] { #expect(EDTMode(hdxOverUDP: value) == .off, "\(value)") }
    #expect(EDTMode(hdxOverUDP: nil) == .off)
}

@Test func edtOverrideIsForTestsOnly() {
    #expect(EDTMode.override(nil) == nil && EDTMode.override("1") == nil && EDTMode.override("x") == nil)
    #expect(EDTMode.override("0") == .off && EDTMode.override("OFF") == .off && EDTMode.override("no") == .off)
    #expect(EDTMode.override("preferred") == .preferred && EDTMode.override("on") == .on)
    // A Developer ID build keeps only the off values (D131's rule for feature switches).
    #expect(TestSwitches.keptInRelease("ICA_EDT", "0") && TestSwitches.keptInRelease("ICA_EDT", "off"))
    #expect(!TestSwitches.keptInRelease("ICA_EDT", "1") && !TestSwitches.keptInRelease("ICA_EDT", "on"))
}

@Test func edtChoiceFollowsTheFileOnDirectRoutes() throws {
    let off = try choice(direct + ["HDXoverUDP=Off", "UDPCGPPort=192.0.2.12:2598"])
    #expect(off.mode == .off && off.target == nil && off.note.contains("TCP only"))
    #expect(try choice(direct).mode == .off)   // no key: off

    let preferred = try choice(direct + ["HDXoverUDP=Preferred", "UDPCGPPort=192.0.2.12:2598", "UDPICAPort=192.0.2.12:1494"])
    #expect(preferred.mode == .preferred && preferred.target?.host == "192.0.2.12" && preferred.target?.port == 2598)
    #expect(preferred.target?.dtlsServerName == nil && preferred.target?.peerIPv4 == [192, 0, 2, 12])
    #expect(preferred.note.contains("raced against TCP"))

    let on = try choice(direct + ["HDXoverUDP=On", "UDPCGPPort=*:2599"])
    #expect(on.mode == .on && on.target?.host == "192.0.2.12" && on.target?.port == 2599 && on.note.contains("EDT only"))
    #expect(try choice(direct + ["HDXoverUDP=pref"]).target?.port == 2598)   // no UDPCGPPort: the VDA, 2598

    // TLS straight to the VDA: DTLS on the TLS endpoint, the handshake's peer address from Address (D148).
    let tls = try choice(direct + ["HDXoverUDP=Preferred", "SSLEnable=On", "SSLProxyHost=vda.example:443", "UDPCGPPort=192.0.2.12:2598"])
    #expect(tls.target?.host == "vda.example" && tls.target?.port == 443 && tls.target?.dtlsServerName == "vda.example")
    #expect(tls.target?.peerIPv4 == [192, 0, 2, 12])
}

@Test func edtChoiceFallsBackToTCPWhereEDTIsNotOffered() throws {
    let gateway = try choice(["Address=;40;STA1;AA", "SSLEnable=On", "SSLProxyHost=gateway.example:443", "CGPSecurityTicket=On",
                              "CGPAddress=*:2598", "HDXoverUDP=On"])
    #expect(gateway.mode == .off && gateway.requested == .on && gateway.target == nil && gateway.note.contains("gateway"))
    let raw = try choice(["Address=192.0.2.12:1494", "HDXoverUDP=Preferred"])
    #expect(raw.mode == .off && raw.note.contains("session reliability"))
    let v6 = try choice(["Address=[2001:db8::12]:1494", "CGPAddress=*:2598", "HDXoverUDP=Preferred"])
    #expect(v6.mode == .off && v6.note.contains("IPv6"))
}

@Test func edtOverrideBeatsTheFile() throws {
    let forcedOff = try choice(direct + ["HDXoverUDP=Preferred"], env: ["ICA_EDT": "0"])
    #expect(forcedOff.mode == .off && forcedOff.note.contains("ICA_EDT=off"))
    #expect(try choice(direct + ["HDXoverUDP=Off"], env: ["ICA_EDT": "on"]).mode == .on)
    #expect(try choice(direct + ["HDXoverUDP=Off"], env: ["ICA_EDT": "1"]).mode == .off)   // 1: the file decides
    #expect(try choice(direct + ["HDXoverUDP=Preferred"], env: ["ICA_EDT_PORT": "2599"]).target?.port == 2599)
}

@Test func edtSessionTakesItsModeFromTheFile() throws {
    let session = try ICASession(ica: ica(direct + ["HDXoverUDP=On"]), configuration: .init())
    #expect(session.edt.mode == .on && session.transport.edtMode == .on && session.transport.edtTarget?.port == 2598)
    let tcp = try ICASession(ica: ica(direct + ["HDXoverUDP=Off"]), configuration: .init())
    #expect(tcp.transport.edtTarget == nil)
}

@Test func edtOfferIsCappedAt1280() {
    // docs/80 §8.8: the VDA sends at the negotiated size; a 1500 offer over a 1280 path lost its packets [L].
    #expect(EDTStream.offer(interfaceMTU: 1500, dtls: false, cap: nil) == 1280)
    #expect(EDTStream.offer(interfaceMTU: 16384, dtls: false, cap: nil) == 1280)
    #expect(EDTStream.offer(interfaceMTU: nil, dtls: false, cap: nil) == 1280)
    #expect(EDTStream.offer(interfaceMTU: 1200, dtls: false, cap: nil) == 1200)
    #expect(EDTStream.offer(interfaceMTU: 1500, dtls: true, cap: nil) == 1240)
    #expect(EDTStream.offer(interfaceMTU: 1500, dtls: false, cap: 1100) == 1100)
    #expect(EDTStream.offer(interfaceMTU: 400, dtls: true, cap: nil) == 576)
}

@Test func edtReportsAPathNarrowerThanTheNegotiatedSize() {
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 9, initialSequence: 1)
    config.probeMTU = true
    let c = EDTConnection(config: config)
    var out: [[UInt8]] = []
    var reported: [Int] = []
    c.send = { out.append($0) }
    c.onPathBelowNegotiated = { reported.append($0) }
    let peer = HandshakePeer()
    c.connect(now: 0, maxPacketSize: 1280)
    c.receive(peer.reply(to: out.removeLast())!, now: 0)
    c.receive(peer.reply(to: out.removeLast())!, now: 0)
    var t = 0.0
    for _ in 0..<40 where !c.mtuProbingDone {
        let probes = out.compactMap { try? EDTPacket.parse($0) }.filter { $0.controlType == .mtuProbe }
        out = []
        for p in probes where p.bytes.count + 28 <= 1100 { c.receive(p.mtuProbeReply(destination: 9)!.bytes, now: t) }
        t += 0.35
        c.tick(now: t)
    }
    #expect(c.mtuProbingDone && reported.count == 1 && reported[0] <= 1100 && reported[0] > 1080)
    #expect(c.pathBelowNegotiated == reported.first)

    // The negotiated size answered: nothing to report.
    let d = EDTConnection(config: config)
    var out2: [[UInt8]] = []
    var reported2: [Int] = []
    d.send = { out2.append($0) }
    d.onPathBelowNegotiated = { reported2.append($0) }
    d.connect(now: 0, maxPacketSize: 1280)
    d.receive(peer.reply(to: out2.removeLast())!, now: 0)
    d.receive(peer.reply(to: out2.removeLast())!, now: 0)
    let probe = out2.compactMap { try? EDTPacket.parse($0) }.first { $0.controlType == .mtuProbe }!
    d.receive(probe.mtuProbeReply(destination: 9)!.bytes, now: 0.02)
    #expect(d.mtuProbingDone && d.pathBelowNegotiated == nil && reported2.isEmpty)
}

/// Answers both handshake rounds as the VDA does (docs/80 §4.1).
private final class HandshakePeer {
    let socket: UInt32 = 0x5118_7AAB
    func reply(to datagram: [UInt8]) -> [UInt8]? {
        guard let p = try? EDTPacket.parse(datagram), let h = p.handshake else { return nil }
        var r = EDTHandshake(version: 7, initialSequence: h.initialSequence, connectionType: h.connectionType,
                             socketID: h.connectionType == 1 ? 0 : socket, cookie: 0x9BD8_11C4, peerIPv4: [127, 0, 0, 1],
                             ext: h.connectionType == 1 ? nil : (socket, h.initialSequence))
        r.maxPacketSize = h.maxPacketSize
        return EDTPacket.handshake(r, destination: h.socketID, reserved: 0).bytes
    }
}

/// A UDP peer on loopback: answers EDT handshakes (`answers`) and drops everything else, i.e. a VDA whose EDT
/// handshake works while nothing more gets through; with `answers = false` a black hole.
private final class SilentEDTPeer: @unchecked Sendable {
    let queue = DispatchQueue(label: "fake.edt")
    private var _answers: Bool
    /// Settable while running (a path that comes back).
    var answers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answers }
        set { lock.lock(); _answers = newValue; lock.unlock() }
    }
    private var listener: NWListener?
    private var flows: [NWConnection] = []
    private let peer = HandshakePeer()
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var _datagrams = 0
    var datagrams: Int { lock.lock(); defer { lock.unlock() }; return _datagrams }

    init(answers: Bool) { _answers = answers }

    func start() async throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.flows.append(c)
            c.start(queue: self.queue)
            self.receive(c)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; continuation.resume()
                case .failed(let error): once.done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data {
                self.lock.lock(); self._datagrams += 1; self.lock.unlock()
                if self.answers, let reply = self.peer.reply(to: [UInt8](data)) {
                    c.send(content: Data(reply), completion: .contentProcessed { _ in })
                }
            }
            self.receive(c)
        }
    }

    func stop() { queue.sync { flows.forEach { $0.cancel() }; listener?.cancel() } }
}

private final class Once: @unchecked Sendable { var done = false }

private func edtPair(answers: Bool, mode: EDTMode, timing: @escaping (inout CGPTransport.Timing) -> Void = { _ in })
    async throws -> (FakeCGPServer, SilentEDTPeer, ResumeClient) {
    let server = FakeCGPServer()
    try await server.start()
    let udp = SilentEDTPeer(answers: answers)
    try await udp.start()
    let client = ResumeClient(port: server.port) { t in
        t.edtOnlyTimeout = 0.5
        t.edtBindTimeout = 1
        timing(&t)
    }
    client.transport.edtTarget = .init(host: "127.0.0.1", port: udp.port)
    client.transport.edtMode = mode
    return (server, udp, client)
}

/// FINISH, then the finish timeout on the client's manual clock.
private func closeOnManualClock(_ client: ResumeClient) async {
    let transport = client.transport
    Task { await transport.close(timeout: 0.5) }
    _ = await eventually(5) { client.transport.status.state == .closing || client.closed }
    client.advance(step: 0.1, limit: 2) { client.closed }
    #expect(client.closed)
}

/// The first bind (and with it the EDT bind watch) is on the wire.
private func bindSent(_ client: ResumeClient) async -> Bool {
    await eventually(5) { client.logs.contains { $0.hasPrefix("→ CGP bind request") } }
}

@Test func edtPreferredLosesTheRaceToTCPWhenUDPIsBlackholed() async throws {
    let (server, udp, client) = try await edtPair(answers: false, mode: .preferred)
    defer { server.stop(); udp.stop() }
    try await client.transport.start()
    #expect(await eventually(10) { client.sawDetect && server.sync { server.detectReplies == 1 } }, "session over TCP")
    #expect(client.logs.contains { $0.hasPrefix("EDT lost the race") }, "\(client.logs)")
    #expect(udp.datagrams > 0)
    await closeOnManualClock(client)
}

@Test func edtPreferredSilentAfterTheHandshakeFallsBackToTCP() async throws {
    // The stock client's lab symptom (docs/80 §2): the handshake completes, nothing else gets through.
    let (server, udp, client) = try await edtPair(answers: true, mode: .preferred)
    defer { server.stop(); udp.stop() }
    try await client.transport.start()
    #expect(client.logs.contains { $0.hasPrefix("EDT won the race") }, "\(client.logs)")
    #expect(await bindSent(client))
    #expect(server.sync { server.binds.count } == 0)
    client.advance(step: 0.1, limit: 3) { client.logs.contains { $0.contains("TCP for the rest of this session") } }
    #expect(await eventually(10) { client.sawDetect && server.sync { server.detectReplies == 1 } }, "\(client.logs)")
    #expect(server.sync { server.binds.count } == 1 && client.transport.transportKind == "TCP")
    await closeOnManualClock(client)
}

@Test func edtOnWithUDPBlockedFailsWithoutTCP() async throws {
    let (server, udp, client) = try await edtPair(answers: false, mode: .on)
    defer { server.stop(); udp.stop() }
    await #expect(throws: CGPTransport.Failure.self) { try await client.transport.start() }
    #expect(server.sync { server.connections } == 0, "no TCP connection with HDXoverUDP=On")
}

@Test func edtOnSilentAfterTheHandshakeEndsTheSession() async throws {
    let (server, udp, client) = try await edtPair(answers: true, mode: .on)
    defer { server.stop(); udp.stop() }
    try await client.transport.start()
    #expect(await bindSent(client))
    client.advance(step: 0.1, limit: 3) { client.closed }
    #expect(client.closed && client.events.last?.contains("HDXoverUDP=On") == true, "\(client.events)")
    #expect(server.sync { server.connections } == 0)
}

@Test func edtKeepsTryingWhileTCPCannotConnect() async throws {
    // A resume while the server is unreachable: TCP fails (here: refused at once), the EDT handshake keeps going and
    // wins once the peer answers again (docs/80 §8.8), instead of giving up after a fixed budget.
    let udp = SilentEDTPeer(answers: false)
    try await udp.start()
    defer { udp.stop() }
    let client = ResumeClient(port: 1)   // nothing listens on loopback port 1: refused at once
    client.transport.edtTarget = .init(host: "127.0.0.1", port: udp.port)
    client.transport.edtMode = .preferred
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { udp.answers = true }
    let started = Date()
    try await client.transport.start()
    #expect(Date().timeIntervalSince(started) > 1.4)
    #expect(client.transport.transportKind == "EDT" && client.logs.contains { $0.contains("EDT connected to 127.0.0.1") },
            "\(client.logs)")
}
