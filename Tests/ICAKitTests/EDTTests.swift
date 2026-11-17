import Foundation
import Testing
@testable import ICAKit

// EDT skeleton (docs/80, D130): synthetic datagrams built from the documented layout; documentation address
// 192.0.2.20 as the VDA, made-up ids.

private func hex(_ s: String) -> [UInt8] { bytes(hex: s.replacingOccurrences(of: " ", with: "")) }

@Test func edtFirstRequestMatchesTheObservedLayout() {
    // docs/80 §4.1, first request: word 0 80000007, version 4, stream, ISN, 1500, 16384, type 1, our id, cookie 0,
    // the VDA address little-endian + 12 zero bytes.
    let h = EDTHandshake(version: 4, initialSequence: 0x1122_3344, connectionType: 1, socketID: 0x0A0B_0C0D, cookie: 0,
                         peerIPv4: [192, 0, 2, 20])
    let bytes = EDTPacket.handshake(h, destination: 0, reserved: 7).bytes
    #expect(bytes == hex("80000007 00000000 00000000 00000000 00000004 00000001 11223344 000005dc 00004000 00000001"
                         + " 0a0b0c0d 00000000 140200c0 00000000 00000000 00000000"))
    #expect(bytes.count == 64)
    let back = try? EDTPacket.parse(bytes)
    #expect(back?.handshake == h)
    #expect(back?.handshake?.peerIPv4 == [192, 0, 2, 20])
}

@Test func edtSecondRoundCarriesTheExtension() throws {
    let h = EDTHandshake(version: 7, initialSequence: 5, connectionType: -1, socketID: 9, cookie: 0xC00C1E,
                         peerIPv4: [192, 0, 2, 20], ext: (9, 5))
    let bytes = EDTPacket.handshake(h, destination: 0, reserved: 7).bytes
    #expect(bytes.count == 72)
    #expect(Array(bytes[36..<40]) == [0xFF, 0xFF, 0xFF, 0xFF])          // connection type −1
    #expect(Array(bytes[64..<72]) == [0, 0, 0, 9, 0, 0, 0, 5])          // (socket id, ISN)
    let parsed = try #require(try EDTPacket.parse(bytes).handshake)
    #expect(parsed.ext?.socketID == 9 && parsed.ext?.sequence == 5 && parsed.connectionType == -1)
}

@Test func edtKeepAliveShutdownAndDataHeaders() throws {
    #expect(EDTPacket.keepAlive(destination: 0x0A0B_0C0D).bytes == hex("80010000 00000000 00000000 0a0b0c0d 00000000"))
    #expect(EDTPacket.shutdown(destination: 0x51).bytes == hex("80050000 00000000 00000000 00000051 00000000"))
    // The one data packet seen: sequence = ISN, word 1 c0000001 (a whole message, number 1), timestamp µs.
    let data = EDTPacket.data(sequence: 0x795D_AD65, position: 3, inOrder: false, message: 1, timestamp: 35_098_865,
                              destination: 0x5118_7AAF, payload: [0x1A, 0x43, 0x47, 0x50])
    #expect(Array(data.bytes.prefix(16)) == hex("795dad65 c0000001 021790f1 51187aaf"))
    #expect(try EDTPacket.parse(data.bytes) == data)
    #expect(throws: EDTWireError.tooShort(3)) { try EDTPacket.parse([1, 2, 3]) }
}

@Test func edtMTUProbeDeclaresLengthMinus28() throws {
    // docs/80 §6: 1472-, 997- and 996-byte probes declared 0x5a4, 0x3c9, 0x3c8.
    for (size, rest) in [(1472, 0x5A4), (997, 0x3C9), (996, 0x3C8)] {
        let p = EDTPacket.mtuProbe(destination: 1, counter: 0x527D_586A, size: size)
        #expect(p.bytes.count == size)
        #expect(Array(p.bytes.prefix(4)) == [0x80, 0x20, 0, 0])
        let f = try #require(try EDTPacket.parse(p.bytes).mtuProbeFields)
        #expect(f.counter == 0x527D_586A && f.rest == UInt32(rest))
    }
}

@Test func edtAckRoundTripsInTheDraftLayout() {
    var ack = EDTAck(ackNumber: 3, lastSequence: 100)
    ack.rtt = 2000
    let p = ack.packet(destination: 7, timestamp: 1)
    #expect(p.controlType == .ack)
    #expect(EDTAck(p) == ack)
}

/// A fake VDA answering like the lab one (docs/80 §4): cookie, then its socket id; keep-alives; shutdown.
private final class FakeVDA {
    let cookie: UInt32 = 0x9BD8_11C4, socket: UInt32 = 0x5118_7AAB
    var received: [EDTPacket] = []
    func reply(to datagram: [UInt8]) -> [UInt8]? {
        guard let p = try? EDTPacket.parse(datagram) else { return nil }
        received.append(p)
        guard let h = p.handshake else { return nil }
        var r = EDTHandshake(version: 7, initialSequence: h.initialSequence, connectionType: h.connectionType,
                             socketID: h.connectionType == 1 ? 0 : socket, cookie: cookie, peerIPv4: [192, 0, 2, 10],
                             ext: h.connectionType == 1 ? nil : (socket, h.initialSequence))
        r.maxPacketSize = h.maxPacketSize
        return EDTPacket.handshake(r, destination: h.socketID, reserved: 0).bytes
    }
}

@Test func edtConnectionHandshakeKeepAliveAndShutdown() {
    let vda = FakeVDA()
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 0x0D40_DFE7, initialSequence: 0x12EC_2685)
    config.idleTimeout = 20
    config.probeMTU = false
    let c = EDTConnection(config: config)
    var outbox: [[UInt8]] = []
    c.send = { outbox.append($0) }
    c.connect(now: 0)
    #expect(c.state == .induction)
    #expect(vda.received.isEmpty && outbox.count == 1)
    c.receive(vda.reply(to: outbox.removeFirst())!, now: 0.003)
    #expect(c.state == .conclusion && c.cookie == vda.cookie)
    let second = outbox.removeFirst()
    #expect(second.count == 72 && (try? EDTPacket.parse(second))?.handshake?.cookie == vda.cookie)
    c.receive(vda.reply(to: second)!, now: 0.007)
    #expect(c.state == .connected(serverSocket: vda.socket))

    // Keep-alives both ways.
    c.receive(EDTPacket.keepAlive(destination: config.socketID).bytes, now: 1.0)
    #expect(c.keepAlivesReceived == 1)
    // Idle: something goes out at least once a second (the repeated cumulative ACK or a keep-alive), to the server.
    c.tick(now: 1.5)
    let idle = outbox.compactMap { try? EDTPacket.parse($0) }
    #expect(!idle.isEmpty && idle.allSatisfy { $0.destination == vda.socket })
    #expect(idle.allSatisfy { $0.controlType == .ack || $0.controlType == .keepAlive })
    outbox = []

    // The peer's shutdown closes; nothing more is sent.
    c.receive(EDTPacket.shutdown(destination: config.socketID).bytes, now: 2)
    #expect(c.state == .closed(reason: "peer shutdown"))
    c.tick(now: 10)
    #expect(outbox.isEmpty)
}

@Test func edtConnectionRetriesTimesOutAndClosesOnSilence() {
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 1, initialSequence: 1)
    config.handshakeAttempts = 2
    let c = EDTConnection(config: config)
    var sent = 0
    c.send = { _ in sent += 1 }
    c.connect(now: 0)
    c.tick(now: 0.3)
    c.tick(now: 0.6)
    #expect(sent == 3)
    c.tick(now: 0.9)
    #expect(c.state == .closed(reason: "no handshake reply"))

    // Connected, then the peer goes silent: shutdown after the idle timeout.
    let vda = FakeVDA()
    let d = EDTConnection(config: EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 2, initialSequence: 2))
    var out: [[UInt8]] = []
    d.send = { out.append($0) }
    d.connect(now: 0)
    d.receive(vda.reply(to: out.removeLast())!, now: 0)
    d.receive(vda.reply(to: out.removeLast())!, now: 0)
    d.tick(now: 20.5)
    #expect(d.state == .closed(reason: "peer silent for 20 s"))
    #expect((try? EDTPacket.parse(out.last!))?.controlType == .shutdown)
}

@Test func edtConnectionDeliversDataInOrderNaksGapsAndAcks() {
    let vda = FakeVDA()
    let c = EDTConnection(config: EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 3, initialSequence: 40))
    var out: [[UInt8]] = []
    var got: [[UInt8]] = []
    c.send = { out.append($0) }
    c.deliver = { got.append($0) }
    c.connect(now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    // The fake VDA's ISN is ours echoed (40): 41 before 40 waits and NAKs 40 at once; a duplicate of 40 is dropped.
    func data(_ seq: UInt32, _ b: UInt8) -> [UInt8] {
        EDTPacket.data(sequence: seq, position: 3, inOrder: false, message: seq, timestamp: 0, destination: 3, payload: [b]).bytes
    }
    c.receive(data(41, 2), now: 1)
    #expect(got.isEmpty)
    let nak = out.compactMap { try? EDTPacket.parse($0) }.first { $0.controlType == .nak }
    if case .control(_, _, _, _, _, let body)? = nak { #expect(EDTLossList.decode(body) == [40]) } else { Issue.record("no NAK") }
    c.receive(data(40, 1), now: 1)
    c.receive(data(40, 1), now: 1)
    #expect(got == [[1], [2]])
    #expect(c.stats.duplicatesReceived == 1)
    // The cumulative ACK goes out on the next tick: next expected 42, our RTT in µs, a free buffer.
    out = []
    c.tick(now: 1.02)
    let ack = out.compactMap { try? EDTPacket.parse($0) }.compactMap(EDTAck.init).last
    #expect(ack?.lastSequence == 42)
    #expect((ack?.availableBuffer ?? 0) > 0)
    // The peer's ACK2 for it gives an RTT sample.
    let before = c.rtt
    c.receive(EDTPacket.control(type: EDTControlType.ack2.rawValue, reserved: 0, info: ack!.ackNumber, timestamp: 0,
                                destination: 3, body: [0, 0, 0, 0]).bytes, now: 1.03)
    #expect(c.stats.ack2Received == 1 && c.rtt < before)
}

/// A connected client with captured output (data packets parsed).
private func connected(window: Double = 16, probe: Bool = false, pacing: Bool = false) -> (EDTConnection, () -> [EDTPacket], FakeVDA) {
    let vda = FakeVDA()
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 5, initialSequence: 1000)
    config.initialWindow = window
    config.probeMTU = probe
    config.pacing = pacing
    let c = EDTConnection(config: config)
    var out: [[UInt8]] = []
    c.send = { out.append($0) }
    c.connect(now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    out = []
    return (c, { defer { out = [] }; return out.compactMap { try? EDTPacket.parse($0) } }, vda)
}

private func ackFrom(_ vda: FakeVDA, next: UInt32, number: UInt32 = 1) -> [UInt8] {
    var a = EDTAck(ackNumber: number, lastSequence: next)
    a.rtt = 20_000
    a.availableBuffer = 8192
    return a.packet(destination: 5, timestamp: 0).bytes
}

@Test func edtStreamIsCutToThePayloadSizeAndLimitedByTheWindow() {
    let (c, take, vda) = connected(window: 4)
    // Packet size 1280 (ours; the fake VDA echoes it): 1280 - 28 - 16 = 1236 data bytes per packet.
    #expect(c.payloadSize == 1236)
    c.write([UInt8](repeating: 7, count: 1236 * 6 + 10), now: 1)
    var sent = take().compactMap { p -> (UInt32, Int)? in
        if case .data(let seq, _, _, _, _, _, let payload) = p { return (seq, payload.count) } else { return nil }
    }
    #expect(sent.map(\.0) == [1000, 1001, 1002, 1003])            // window 4
    #expect(sent.allSatisfy { $0.1 == 1236 })
    #expect(c.queuedBytes == 1236 * 2 + 10)
    // ACK of 1000…1001: two more go out, the window grows (slow start).
    c.receive(ackFrom(vda, next: 1002), now: 1.05)
    sent = take().compactMap { p -> (UInt32, Int)? in
        if case .data(let seq, _, _, _, _, _, let payload) = p { return (seq, payload.count) } else { return nil }
    }
    #expect(sent.map(\.0) == [1004, 1005, 1006])
    #expect(sent.last?.1 == 10)
    #expect(c.window == 6)
    // A full ACK answers with ACK2 and empties the flight.
    c.receive(ackFrom(vda, next: 1007, number: 2), now: 1.1)
    #expect(take().contains { $0.controlType == .ack2 })
    #expect(c.unacknowledgedPackets == 0)
}

@Test func edtNakRetransmitsAndShrinksTheWindowOncePerRTTOnHeavyLoss() {
    let (c, take, vda) = connected(window: 16)
    c.write([UInt8](repeating: 1, count: 1236 * 10), now: 1)
    _ = take()
    let nak = EDTPacket.control(type: EDTControlType.nak.rawValue, reserved: 0, info: 0, timestamp: 0, destination: 5,
                                body: EDTLossList.encode([1002, 1003, 1004, 1007]))
    c.receive(nak.bytes, now: 1.02)
    let resent = take().compactMap { p -> UInt32? in if case .data(let s, _, _, _, _, _, _) = p { return s } else { return nil } }
    #expect(resent == [1002, 1003, 1004, 1007])
    #expect(c.stats.dataRetransmitted == 4)
    // 4 of a 16-packet window lost in one epoch (≥ 10 %): congestion, ×0.875 (slow start ends at the first loss).
    #expect(c.window == 14)
    c.receive(nak.bytes, now: 1.03)                                  // the same epoch: no second decrease
    #expect(c.window == 14)
    _ = vda
}

@Test func edtRetransmissionTimeoutResendsEverythingUnacknowledged() {
    let (c, take, _) = connected(window: 16)
    c.write([UInt8](repeating: 2, count: 1236 * 3), now: 1)
    _ = take()
    c.tick(now: 1.1)                                                 // before the RTO (≥ 200 ms)
    #expect(!take().contains { if case .data = $0 { return true } else { return false } })
    c.tick(now: 1.5)
    let resent = take().compactMap { p -> UInt32? in if case .data(let s, _, _, _, _, _, _) = p { return s } else { return nil } }
    #expect(resent.sorted() == [1000, 1001, 1002])
    #expect(c.stats.rtos == 1 && c.window == 16)
}

@Test func edtLossListEncodesRanges() {
    #expect(EDTLossList.encode([5]) == [0, 0, 0, 5])
    #expect(EDTLossList.encode([5, 6, 7, 9]) == [0x80, 0, 0, 5, 0, 0, 0, 7, 0, 0, 0, 9])
    #expect(EDTLossList.decode(EDTLossList.encode([5, 6, 7, 9])) == [5, 6, 7, 9])
    // Wrap at 2^31.
    #expect(EDTLossList.decode(EDTLossList.encode([0x7FFF_FFFF, 0])) == [0x7FFF_FFFF, 0])
    #expect(EDTConnection.diff(0, 0x7FFF_FFFF) == 1 && EDTConnection.add(0x7FFF_FFFF, 1) == 0)
}

@Test func edtOurDataStartsAtOurISN() {
    let (c, take, vda) = connected()
    c.sendMessage([0xAA], now: 2)
    #expect(take().first == .data(sequence: 1000, position: 3, inOrder: false, message: 1, timestamp: 2_000_000,
                                  destination: vda.socket, payload: [0xAA]))
}

@Test func edtRandomLossDoesNotShrinkALargeWindow() {
    // D135: one lost packet in a 200-packet window is random loss (< 10 %, RTT flat): repaired, no decrease.
    let (c, take, vda) = connected(window: 200)
    c.write([UInt8](repeating: 3, count: 1236 * 200), now: 1)
    _ = take()
    c.receive(EDTPacket.control(type: EDTControlType.nak.rawValue, reserved: 0, info: 0, timestamp: 0, destination: 5,
                                body: EDTLossList.encode([1050])).bytes, now: 1.02)
    #expect(c.window == 200 && c.stats.dataRetransmitted == 1)
    _ = vda
}

@Test func edtPacingSpreadsTheWindowOverTheRTT() {
    // D135: with pacing a full window does not leave at once: the bucket allows ~2 ticks' worth (≥ 2 packets).
    let (c, take, _) = connected(window: 64, pacing: true)
    c.write([UInt8](repeating: 4, count: 1236 * 64), now: 1)
    let first = take().filter { if case .data = $0 { return true } else { return false } }.count
    #expect(first < 64 && first >= 2)
    // Ticks across one RTT (0.1 s by default) release the rest.
    var total = first
    for i in 1...12 { c.tick(now: 1 + Double(i) * 0.01); total += take().filter { if case .data = $0 { return true } else { return false } }.count }
    #expect(total == 64)
}

@Test func edtPathMTUProbesUpAndUsesTheAnsweredSize() {
    // D135: data starts at 576; the VDA answers a 1280 probe → data at 1280 (1236 B payload).
    let (c, take, vda) = connected(probe: true)
    #expect(c.sendPacketSize == 576 && c.payloadSize == 532)
    c.tick(now: 0.4)                                   // the first probe went out with the handshake; its retry now
    let probe = take().first { $0.controlType == .mtuProbe }!
    #expect(probe.bytes.count == 1280 - 28)
    c.receive(probe.mtuProbeReply(destination: 5)!.bytes, now: 0.02)
    #expect(c.sendPacketSize == 1280 && c.payloadSize == 1236 && c.mtuProbingDone)
    _ = vda
}

@Test func edtPathMTUSearchesDownWhenBigProbesAreLost() {
    // The 1280 probe is lost twice; the search then narrows on answered/lost probes, ending within 16 bytes.
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 6, initialSequence: 1)
    config.probeMTU = true
    let c = EDTConnection(config: config)
    var out: [[UInt8]] = []
    c.send = { out.append($0) }
    let vda = FakeVDA()
    c.connect(now: 0, maxPacketSize: 1280)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    let pathMTU = 1100
    var t = 0.0
    for _ in 0..<40 {
        let probes = out.compactMap { try? EDTPacket.parse($0) }.filter { $0.controlType == .mtuProbe }
        out = []
        for p in probes where p.bytes.count + 28 <= pathMTU { c.receive(p.mtuProbeReply(destination: 6)!.bytes, now: t) }
        t += 0.35
        c.tick(now: t)
        if c.mtuProbingDone { break }
    }
    #expect(c.mtuProbingDone)
    #expect(c.sendPacketSize <= pathMTU && c.sendPacketSize > pathMTU - 20)
}

@Test func edtWithoutProbeRepliesFallsBackTo1280() {
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 7, initialSequence: 1)
    config.probeMTU = true
    let c = EDTConnection(config: config)
    var out: [[UInt8]] = []
    c.send = { out.append($0) }
    let vda = FakeVDA()
    c.connect(now: 0, maxPacketSize: 1500)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    var t = 0.0
    for _ in 0..<80 where !c.mtuProbingDone { t += 0.35; c.tick(now: t) }
    #expect(c.mtuProbingDone && c.sendPacketSize == 1280)
}

@Test func edtEchoesThePeersProbes() {
    let (c, take, _) = connected()
    let probe = EDTPacket.mtuProbe(destination: 5, counter: 9, size: 1000)
    c.receive(probe.bytes, now: 1)
    let reply = take().first { $0.controlType == .mtuProbeReply }
    #expect(reply?.bytes.count == 1000 && reply?.mtuProbeFields?.counter == 9)
}

@Test func edtAcksReportArrivalRateAndLinkCapacity() {
    // D135: a UDT sender sizes its window from the receive rate in our ACKs (0 kept the VDA at ~16 packets per RTT).
    let (c, take, _) = connected()
    func data(_ seq: UInt32) -> [UInt8] {
        EDTPacket.data(sequence: seq, position: 3, inOrder: false, message: 1, timestamp: 0, destination: 5, payload: [0]).bytes
    }
    // The fake VDA's ISN is ours (1000): pairs at 1008/1009 and 1024/1025 come back to back (0.1 ms), the rest 1 ms apart.
    var t = 1.0
    for seq in UInt32(1000)..<1040 {
        let pairSecond = seq & 0xF == 1
        t += pairSecond ? 0.0001 : 0.001
        c.receive(data(seq), now: t)
    }
    #expect(abs(c.arrivalRate - 1000) < 150)          // ~1 ms apart (the pair gaps are filtered out)
    #expect(c.linkCapacity == 0)                        // 1008 is not ≡ 0 mod 16 here: only 1024/1025 → too few pairs
    c.tick(now: t + 0.02)
    let ack = take().compactMap(EDTAck.init).last
    #expect(ack.map { abs(Double($0.receiveRate) - 1000) < 150 } == true)
}

@Test func edtLinkCapacityFromPacketPairs() {
    var gaps = [Double](repeating: 0.0001, count: 8)
    #expect(abs(EDTConnection.rate(gaps, minimum: 4) - 10_000) < 1)
    gaps[0] = 0.01                                       // an outlier (≥ 8× the median) is ignored
    #expect(abs(EDTConnection.rate(gaps, minimum: 4) - 10_000) < 1)
    #expect(EDTConnection.rate([0.001, 0.001], minimum: 4) == 0)
}

@Test func edtFeatureIsOffByDefault() {
    #expect(!EDTFeature.enabled([:]))
    #expect(EDTFeature.enabled(["ICA_EDT": "1"]))
}

// EDT target selection in ICASession (D148): plain UDP for a direct CGP file, DTLS on the TLS port for a direct TLS file,
// nothing through a gateway. ICA_EDT=1 is set in the process for this test only (other sessions built meanwhile only
// gain a target they never connect).
@Test func edtTargetFollowsThePlan() throws {
    func ica(_ lines: [String]) -> ICAFile {
        ICAFile(text: "[WFClient]\nVersion=2\n[ApplicationServers]\nNotepad=\n[Notepad]\n" + lines.joined(separator: "\n") + "\nHDXoverUDP=Preferred\n")!
    }
    setenv("ICA_EDT", "1", 1)
    defer { unsetenv("ICA_EDT") }
    let plain = try ICASession(ica: ica(["Address=192.0.2.12:1494", "CGPAddress=*:2598", "UDPCGPPort=192.0.2.12:2598"]),
                               configuration: .init())
    #expect(plain.transport.edtTarget?.port == 2598 && plain.transport.edtTarget?.dtlsServerName == nil)
    let tls = try ICASession(ica: ica(["Address=192.0.2.12:1494", "SSLEnable=On", "SSLProxyHost=vda.example:443", "CGPAddress=*:2598"]),
                             configuration: .init())
    #expect(tls.transport.edtTarget?.host == "vda.example" && tls.transport.edtTarget?.port == 443)
    #expect(tls.transport.edtTarget?.dtlsServerName == "vda.example" && tls.transport.edtTarget?.peerIPv4 == [192, 0, 2, 12])
    let gateway = try ICASession(ica: ica(["Address=;40;STA1;AA", "SSLEnable=On", "SSLProxyHost=gateway.example:443",
                                           "CGPSecurityTicket=On", "CGPAddress=*:2598"]), configuration: .init())
    #expect(gateway.transport.edtTarget == nil)
}
