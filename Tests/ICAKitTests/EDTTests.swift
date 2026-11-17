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
    c.tick(now: 1.5)
    #expect(outbox.count == 1 && (try? EDTPacket.parse(outbox[0]))?.controlType == .keepAlive)
    #expect((try? EDTPacket.parse(outbox[0]))?.destination == vda.socket)
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

@Test func edtConnectionDeliversDataInOrderAndAcks() {
    let vda = FakeVDA()
    let c = EDTConnection(config: EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 3, initialSequence: 40))
    var out: [[UInt8]] = []
    var got: [[UInt8]] = []
    c.send = { out.append($0) }
    c.deliver = { got.append($0) }
    c.connect(now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    c.receive(vda.reply(to: out.removeLast())!, now: 0)
    // The fake VDA's ISN is ours echoed (40): data 41 before 40 waits; a duplicate of 40 is dropped.
    func data(_ seq: UInt32, _ b: UInt8) -> [UInt8] {
        EDTPacket.data(sequence: seq, position: 3, inOrder: false, message: seq, timestamp: 0, destination: 3, payload: [b]).bytes
    }
    c.receive(data(41, 2), now: 1)
    #expect(got.isEmpty)
    c.receive(data(40, 1), now: 1)
    c.receive(data(40, 1), now: 1)
    #expect(got == [[1], [2]])
    let acks = out.compactMap { try? EDTPacket.parse($0) }.compactMap(EDTAck.init)
    #expect(acks.last?.lastSequence == 42)
    // Our own data: sequence from our ISN, a whole message, numbered from 1.
    out = []
    c.sendMessage([0xAA], now: 2)
    #expect((try? EDTPacket.parse(out[0])) == .data(sequence: 40, position: 3, inOrder: false, message: 1,
                                                     timestamp: 2_000_000, destination: vda.socket, payload: [0xAA]))
}

@Test func edtFeatureIsOffByDefault() {
    #expect(!EDTFeature.enabled([:]))
    #expect(EDTFeature.enabled(["ICA_EDT": "1"]))
}
