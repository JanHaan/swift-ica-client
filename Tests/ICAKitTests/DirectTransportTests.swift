import Foundation
import Network
import Testing
@testable import ICAKit

// Direct mode transport (docs/16 §4): ICA file → route/socket/framing, the raw ICA start (SOCKS5, detect), the CGP
// bind without ticket, and a raw session over loopback. Synthetic files; example host names and documentation IPs.

private func ica(_ lines: [String]) -> ICAFile {
    ICAFile(text: "[WFClient]\nVersion=2\n[ApplicationServers]\nNotepad=\n[Notepad]\n" + lines.joined(separator: "\n") + "\n")!
}

// MARK: - Transport selection

@Suite struct ConnectPlanTests {
    @Test func gatewayFileKeepsTheGatewayPath() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=;40;STA0123;0123456789ABCDEF", "SSLEnable=On",
                                                "SSLProxyHost=gateway.example:443", "CGPSecurityTicket=On", "CGPAddress=*:2598"]),
                                      environment: [:])
        #expect(plan.route == .gateway)
        #expect(plan.host == "gateway.example" && plan.port == 443 && plan.tls)
        #expect(plan.framing == .cgp(ticket: ";40;STA0123;0123456789ABCDEF"))
        #expect(plan.encryption == .basic)
    }

    @Test func gatewayFileWithoutSSLEnableStillGoesToTheGateway() throws {
        // The old rule needed only SSLProxyHost, Address and CGPSecurityTicket=On.
        let plan = try ICAConnectPlan(ica: ica(["Address=;40;STA1;AA", "SSLProxyHost=gateway.example:443", "CGPSecurityTicket=On"]),
                                      environment: [:])
        #expect(plan.route == .gateway && plan.tls && plan.framing == .cgp(ticket: ";40;STA1;AA"))
    }

    @Test func gatewayPortDefaultsTo443() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=;40;STA1;AA", "SSLEnable=1", "SSLProxyHost=gateway.example",
                                                "CGPSecurityTicket=On"]), environment: [:])
        #expect(plan.port == 443)
    }

    @Test func gatewayWithoutSessionReliabilityUsesSOCKS5WithTheTicket() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=;40;STA1;ABCDEF", "SSLEnable=On", "SSLProxyHost=gateway.example:443"]),
                                      environment: [:])
        #expect(plan.route == .gateway && plan.tls && plan.host == "gateway.example")
        #expect(plan.framing == .raw(socks: .init(host: ";40;STA1;ABCDEF", port: 1494, username: nil, password: nil)))
    }

    @Test func plainTCPWithCGPAddressGoesToTheVDAOn2598WithoutTicket() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=192.0.2.12:1494", "SSLEnable=Off", "CGPAddress=*:2598",
                                                "CGPSecurityTicket=Off", "EncryptionLevelSession=Basic"]), environment: [:])
        #expect(plan.route == .direct)
        #expect(plan.host == "192.0.2.12" && plan.port == 2598 && !plan.tls)
        #expect(plan.framing == .cgp(ticket: nil))
        #expect(plan.usesCGP)
    }

    @Test func cgpAddressPortWins() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=vda.example", "CGPAddress=*:2600"]), environment: [:])
        #expect(plan.host == "vda.example" && plan.port == 2600)
    }

    @Test func plainTCPWithoutCGPIsRawICAOnTheAddressPort() throws {
        let a = try ICAConnectPlan(ica: ica(["Address=192.0.2.12"]), environment: [:])
        #expect(a.route == .direct && a.host == "192.0.2.12" && a.port == 1494 && !a.tls && a.framing == .raw(socks: nil))
        let b = try ICAConnectPlan(ica: ica(["Address=vda.example:1600", "SSLEnable=Off"]), environment: [:])
        #expect(b.host == "vda.example" && b.port == 1600)
    }

    @Test func ticketOnWithoutProxyIsADirectCGPBindWithoutTicket() throws {
        // CGPSecurityTicket=On only makes sense with a gateway; without one the host part of Address is a host.
        let plan = try ICAConnectPlan(ica: ica(["Address=192.0.2.12", "CGPSecurityTicket=On"]), environment: [:])
        #expect(plan.route == .direct && plan.port == 2598 && plan.framing == .cgp(ticket: nil))
    }

    @Test func tlsToTheVDAWithoutProxyHost() throws {
        let file = ica(["Address=vda.example:1494", "SSLEnable=On", "Username=user1", "ClearPassword=pw"])
        let plan = try ICAConnectPlan(ica: file, environment: [:])
        #expect(plan.route == .direct && plan.tls && plan.host == "vda.example" && plan.port == 443)
        #expect(plan.framing == .raw(socks: .init(host: "vda.example", port: 1494, username: "user1", password: "pw")))
        let noSocks = try ICAConnectPlan(ica: file, environment: ["ICA_DIRECT_TLS_SOCKS": "0"])
        #expect(noSocks.framing == .raw(socks: nil))
    }

    @Test func tlsToTheVDANamedBySSLProxyHostWithSessionReliability() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=192.0.2.12:1494", "SSLEnable=On", "SSLProxyHost=vda.example:443",
                                                "CGPAddress=*:2598"]), environment: [:])
        #expect(plan.route == .direct && plan.tls && plan.host == "vda.example" && plan.port == 443)
        #expect(plan.framing == .cgp(ticket: nil))
    }

    @Test func secureICAIsRefusedUnlessOverridden() throws {
        for level in ["RC5 (128 bit)", "RC5 (40 bit)", "RC5 (128 bit - Login Only)", "EncRC5-56"] {
            #expect(throws: ICAConnectPlan.Failure.unsupportedEncryption(level)) {
                try ICAConnectPlan(ica: ica(["Address=192.0.2.12", "EncryptionLevelSession=\(level)"]), environment: [:])
            }
        }
        let plan = try ICAConnectPlan(ica: ica(["Address=192.0.2.12", "EncryptionLevelSession=RC5 (128 bit)"]),
                                      environment: ["ICA_IGNORE_ENCRYPTION_LEVEL": "1"])
        #expect(plan.encryption == .secureICA("RC5 (128 bit)"))
        #expect(ICAEncryptionLevel("Basic") == .basic && ICAEncryptionLevel(nil) == .basic && ICAEncryptionLevel("Encrypt") == .basic)
    }

    @Test func missingOrTicketLikeAddressWithoutGatewayFails() {
        #expect(throws: ICAConnectPlan.Failure.missingAddress) { try ICAConnectPlan(ica: ica(["SSLEnable=Off"]), environment: [:]) }
        #expect(throws: ICAConnectPlan.Failure.badAddress) { try ICAConnectPlan(ica: ica(["Address=;40;STA1;AB"]), environment: [:]) }
    }

    @Test func ipv6AndUDPFlags() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=[2001:db8::12]:1494", "HDXoverUDP=Preferred"]), environment: [:])
        #expect(plan.host == "2001:db8::12" && plan.port == 1494 && plan.ignoresUDP)
        #expect(plan.description.contains("HDXoverUDP ignored"))
    }

    @Test func descriptionNeverShowsTheTicket() throws {
        let plan = try ICAConnectPlan(ica: ica(["Address=;40;STA1;SECRETSECRET", "SSLEnable=On", "SSLProxyHost=gateway.example",
                                                "CGPSecurityTicket=On"]), environment: [:])
        #expect(!plan.description.contains("SECRET"))
    }

    @Test func sessionShareKeyForDirectTLSUsesTheAddress() {
        let key = SessionShareKey(ica: ica(["Address=vda.example:1494", "SSLEnable=On", "TWIMode=On", "SessionsharingKey=k"]))
        #expect(key.connectHost == "vda.example" && key.connectPort == 1494 && key.sslEnabled)
    }

    @Test func icaSessionAcceptsDirectFiles() throws {
        let session = try ICASession(ica: ica(["Address=192.0.2.12", "CGPAddress=*:2598"]), configuration: .init())
        #expect(session.host == "192.0.2.12" && session.port == 2598 && session.plan.route == .direct)
        #expect(throws: ICASession.Failure.self) {
            try ICASession(ica: ica(["Address=192.0.2.12", "EncryptionLevelSession=RC5 (56 bit)"]), configuration: .init())
        }
    }
}

// MARK: - Raw ICA start

@Suite struct RawICAHandshakeTests {
    let detect = CGPSession.icaDetect

    @Test func detectSplitAcrossChunksIsAnsweredOnceAndTheRestGoesUp() {
        var h = RawICAHandshake(socks: nil)
        #expect(h.start().write.isEmpty)
        var out = h.feed(detect.prefix(3))
        #expect(out.write.isEmpty && out.ica.isEmpty && h.phase == .detect)
        out = h.feed(detect.suffix(3) + detect + Data([0x01, 0x02]))
        #expect(out.write == [detect] && out.detected)
        #expect(out.ica == Data([0x01, 0x02]) && h.phase == .open)
        out = h.feed(Data([0x03]) + detect)
        #expect(out.write.isEmpty && out.ica == Data([0x03]) + detect)   // after the start, detect bytes are WD data
    }

    @Test func partialRepeatAtTheEndWaits() {
        var h = RawICAHandshake(socks: nil)
        var out = h.feed(detect + detect.prefix(2))
        #expect(out.detected && out.ica.isEmpty && h.phase == .detect)
        out = h.feed(detect.suffix(4) + Data([0x09]))
        #expect(!out.detected && out.write.isEmpty && out.ica == Data([0x09]) && h.phase == .open)
    }

    @Test func socksWithoutAuthToADomainName() {
        var h = RawICAHandshake(socks: .init(host: "vda.example", port: 1494, username: nil, password: nil))
        #expect(h.start().write == [Data([0x05, 0x02, 0x00, 0x02])])
        var out = h.feed(Data([0x05, 0x00]))
        let name = Array("vda.example".utf8)
        #expect(out.write == [Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x05, 0xd6])])
        // RFC 1928 reply with an IPv4 bound address; the 7 bytes after the first 3 are skipped before the detect.
        out = h.feed(Data([0x05, 0x00, 0x00, 0x01, 192, 0, 2, 12, 0x05, 0xd6]) + detect + Data([0x42]))
        #expect(out.detected && out.write == [detect] && out.ica == Data([0x42]))
    }

    @Test func socksUserPasswordAndIPv4Target() {
        var h = RawICAHandshake(socks: .init(host: "192.0.2.12", port: 2000, username: "u", password: "pw"))
        var out = h.feed(Data([0x05, 0x02]))
        #expect(out.write == [Data([0x01, 0x01, 0x75, 0x02, 0x70, 0x77])])
        #expect(!out.log.joined().contains("pw"))
        out = h.feed(Data([0x01, 0x00]))
        #expect(out.write == [Data([0x05, 0x01, 0x00, 0x01, 192, 0, 2, 12, 0x07, 0xd0])])
    }

    @Test func socksRefusalFails() {
        var h = RawICAHandshake(socks: .init(host: "t", port: 1494, username: nil, password: nil))
        _ = h.feed(Data([0x05, 0x00]))
        let out = h.feed(Data([0x05, 0x04, 0x00]))
        #expect(out.failure?.contains("host unreachable") == true && h.phase == .failed)
    }
}

// MARK: - Direct CGP bind

@Suite struct DirectCGPBindTests {
    /// docs/20 §7.2: caps 5, 9, 7, 1 exactly as in §7.1, no caps 6 and 2; 106 bytes in one send.
    static let expected: [UInt8] = [0x1a, 0x43, 0x47, 0x50, 0x2f, 0x30, 0x31, 0x62, 0x01, 0x00, 0x00, 0x00, 0x04]
        + [0x18, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x02, 0x05, 0x00, 0x01, 0x02, 0x05, 0x00,
           0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00]
        + [0x0f, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0xb4, 0x00, 0x01, 0x00, 0x19, 0x00, 0x0a, 0x00]
        + [0x0e, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0xb8, 0x0b, 0x00, 0x00, 0xb8, 0x0b, 0x00, 0x00]
        + [0x24, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x16]
        + Array("Citrix.TcpProxyService".utf8)

    @Test func firstBindMatchesTheSpec() {
        let s = CGPSession()
        let bind = Array(s.bindRequestWithoutTicket())
        #expect(bind.count == 106)
        #expect(bind == Self.expected)
        #expect(!s.bindCarriesTicket && s.state == .binding)
    }

    @Test func resumeBindKeepsTheFourCapsAndCarriesTheCookie() throws {
        let s = CGPSession()
        _ = s.bindRequestWithoutTicket()
        // Even if the VDA sends a cap 6, the resume keeps the first bind's caps (same caps, same order) [I].
        _ = try s.feed(CGPSession.signature + Data(CGPFixture.firstBind()))
        s.openChannel()
        _ = try s.feed(Data(CGPFixture.openResponse() + CGPFixture.data(Array(CGPSession.icaDetect))))
        s.suspend()
        let bind = Array(s.resumeBindRequest())
        #expect(bind[0..<7] == ArraySlice(CGPSession.signature))
        // count byte after the 2-byte length and the 4 header bytes
        let lengthBytes = bind[7] & 0x80 != 0 ? 2 : 1
        #expect(bind[7 + lengthBytes + 4] == 0x04)
        #expect(!containsSubsequence(bind, CGPFixture.ticket))
        #expect(containsSubsequence(bind, CGPFixture.cookie))
        #expect(containsSubsequence(bind, CGPFixture.openRequest))
        #expect(Array(bind.suffix(22)) == Array("Citrix.TcpProxyService".utf8))
    }

    private func containsSubsequence(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard b.count <= a.count else { return false }
        return (0...(a.count - b.count)).contains { Array(a[$0..<$0 + b.count]) == b }
    }
}

// MARK: - Raw ICA over loopback

/// A raw ICA "VDA" on loopback TCP: sends the detect string twice, expects the client's detect reply, then echoes.
private final class FakeRawVDA: @unchecked Sendable {
    let queue = DispatchQueue(label: "fake.raw")
    private var listener: NWListener?
    private var connection: NWConnection?
    private(set) var port: UInt16 = 0
    private(set) var received = Data()

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

    private func accept(_ c: NWConnection) {
        connection = c
        c.start(queue: queue)
        c.send(content: CGPSession.icaDetect + CGPSession.icaDetect, completion: .idempotent)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { received.append(data) }
            if received.count >= 6, received.prefix(6) == CGPSession.icaDetect, received.count > 6 {
                // Echo what came after the detect reply.
                c.send(content: Data(received.dropFirst(6)), completion: .idempotent)
                received = received.prefix(6)
            }
            if complete || error != nil { return }
            receive(c)
        }
    }

    func close() { connection?.cancel() }
    func stop() { listener?.cancel(); connection?.cancel() }
    func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var data = Data()
    func add(_ event: CGPTransport.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .detect: events.append("detect")
        case .data(let d): data.append(d)
        case .closed: events.append("closed")
        default: break
        }
    }
    var snapshot: ([String], Data) { lock.lock(); defer { lock.unlock() }; return (events, data) }
}

@Test func rawTransportOverLoopbackAnswersDetectAndPassesDataBothWays() async throws {
    let vda = FakeRawVDA()
    try await vda.start()
    defer { vda.stop() }
    let queue = DispatchQueue(label: "test.raw")
    let transport = CGPTransport(host: "127.0.0.1", port: vda.port, tls: false, framing: .raw(socks: nil), queue: queue)
    let recorder = Recorder()
    transport.onEvent = { recorder.add($0) }
    try await transport.start()
    func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
    #expect(await wait { recorder.snapshot.0.contains("detect") })
    #expect(await wait { vda.sync { vda.received } == CGPSession.icaDetect })
    #expect(transport.status.state == .connected)
    transport.send(Data([0x10, 0x20, 0x30]), piggybackAck: true)
    #expect(await wait { recorder.snapshot.1 == Data([0x10, 0x20, 0x30]) })
    // A dead link ends a raw session (no SR).
    vda.close()
    #expect(await wait { recorder.snapshot.0.contains("closed") })
    #expect(transport.isClosed)
    #expect(recorder.snapshot.0.filter { $0 == "detect" }.count == 1)
}
