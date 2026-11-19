import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md §10, mac-S), findings F-08 and F-09: what an EDT peer (the VDA, or
// anyone who can inject into a plain-UDP EDT flow) sends must not make the client hold or walk unbounded state. Offline.

/// Answers our handshakes like the lab VDA (cookie, then its socket id); echoes our ISN as its own.
private func connectedClient(flowWindow: UInt32 = 64) -> (EDTConnection, () -> [EDTPacket]) {
    var config = EDTConnection.Config(peerIPv4: [192, 0, 2, 20], socketID: 9, initialSequence: 500)
    config.probeMTU = false
    config.pacing = false
    config.flowWindow = flowWindow
    let c = EDTConnection(config: config)
    var out: [[UInt8]] = []
    c.send = { out.append($0) }
    func reply(_ datagram: [UInt8]) -> [UInt8] {
        let h = (try! EDTPacket.parse(datagram)).handshake!
        var r = EDTHandshake(version: 7, initialSequence: h.initialSequence, connectionType: h.connectionType,
                             socketID: h.connectionType == 1 ? 0 : 0x5118_7AAB, cookie: 0x9BD8_11C4, peerIPv4: [192, 0, 2, 10],
                             ext: h.connectionType == 1 ? nil : (0x5118_7AAB, h.initialSequence))
        r.maxPacketSize = h.maxPacketSize
        return EDTPacket.handshake(r, destination: h.socketID, reserved: 0).bytes
    }
    c.connect(now: 0)
    c.receive(reply(out.removeLast()), now: 0)
    c.receive(reply(out.removeLast()), now: 0)
    out = []
    return (c, { defer { out = [] }; return out.compactMap { try? EDTPacket.parse($0) } })
}

private func data(_ seq: UInt32) -> [UInt8] {
    EDTPacket.data(sequence: seq, position: 3, inOrder: false, message: seq, timestamp: 0, destination: 9, payload: [1, 2, 3]).bytes
}

@Suite struct F08EDTReceiveBoundsTests {
    /// F-08: a data packet at or beyond our advertised flow window is dropped: not buffered, no gap of NAKs walked for it.
    @Test func dataBeyondTheFlowWindowIsDroppedNotBuffered() {
        let (c, sent) = connectedClient(flowWindow: 64)
        #expect(c.state == .connected(serverSocket: 0x5118_7AAB))
        // The peer's ISN is ours echoed (500). Far ahead: 2^29 packets, then just past the window.
        c.receive(data(500 + (1 << 29)), now: 1)
        c.receive(data(500 + 64), now: 1)
        #expect(c.stats.beyondWindow == 2)
        let naks = sent().filter { $0.controlType == .nak }
        #expect(naks.isEmpty)
        // Inside the window: buffered, the gap NAKed (bounded by the window).
        c.receive(data(500 + 63), now: 1)
        let nak = sent().first { $0.controlType == .nak }
        if case .control(_, _, _, _, _, let body)? = nak {
            #expect(EDTLossList.decode(body).count == 63)
        } else { Issue.record("no NAK for the in-window gap") }
        #expect(c.stats.outOfOrder == 1 && c.stats.beyondWindow == 2)
        // The free buffer reported in the ACK counts only the one buffered packet.
        c.tick(now: 1.02)
        let ack = sent().compactMap(EDTAck.init).last
        #expect(ack?.availableBuffer == 63)
    }

    /// F-08: many packets inside the window but each further ahead do not make the gap walk grow past the window.
    @Test func gapWalkStaysWithinTheWindow() {
        let (c, sent) = connectedClient(flowWindow: 8192)
        let start = Date()
        for k in stride(from: 8191, to: 0, by: -1) { c.receive(data(UInt32(500 + k)), now: 1) }
        #expect(Date().timeIntervalSince(start) < 10)
        _ = sent()
        c.receive(data(500), now: 1)   // fills the head: everything is delivered
        #expect(c.stats.bytesDelivered == 8192 * 3)
    }

    /// F-09: a NAK whose ranges cover the whole sequence space only marks packets actually in flight.
    @Test func nakRangesAreClippedToWhatIsInFlight() {
        // 160 ranges of 2^30 sequence numbers each: 1,280 bytes, a single datagram.
        var body: [UInt8] = []
        for _ in 0..<160 { body += [0x80, 0, 0, 0] + [0x3F, 0xFF, 0xFF, 0xFF] }
        let start = Date()
        let clipped = EDTLossList.decode(body, from: 1000, to: 1010)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(clipped == Array(1000..<1010))
        // Without a window the decoder caps its output.
        #expect(EDTLossList.decode(body).count <= EDTLossList.maxDecoded)
        // A range that wraps around the 31-bit space is clipped too.
        let wrap: [UInt8] = [0xFF, 0xFF, 0xFF, 0xF0] + [0, 0, 0, 5]
        #expect(EDTLossList.decode(wrap, from: 0x7FFF_FFFE, to: 3) == [0x7FFF_FFFE, 0x7FFF_FFFF, 0, 1, 2])

        let (c, sent) = connectedClient()
        c.write(Array(repeating: 7, count: 3000), now: 1)
        let firstData = sent().filter { if case .data = $0 { true } else { false } }
        #expect(!firstData.isEmpty)
        let nak = EDTPacket.control(type: EDTControlType.nak.rawValue, reserved: 0, info: 0, timestamp: 0, destination: 9, body: body)
        let t = Date()
        c.receive(nak.bytes, now: 1.01)
        #expect(Date().timeIntervalSince(t) < 1)
        let resent = sent().filter { if case .data = $0 { true } else { false } }
        #expect(resent.count == firstData.count)
    }
}
