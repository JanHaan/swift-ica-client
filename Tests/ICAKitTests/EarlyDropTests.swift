import Foundation
import Testing
@testable import ICAKit

// notes/early-drop-analysis.md: LED gating, pattern A/B classification, redacted packet ring.

@Test func ledWaitsForTheHostsFirstFramedPacket() {
    var gate = LEDGate()
    // Handshake packets before INIT_CONNECT_RESPONSE never release it.
    let early = gate.hostPacket(type: WDPacketType.initRequest)
    let earlyKey = gate.keyEvent()
    #expect(!early && !earlyKey)
    gate.connectResponseSent()
    #expect(gate.sentAfter == nil)   // nothing right behind INIT_CONNECT_RESPONSE
    let first = gate.hostPacket(type: WDPacketType.command)
    #expect(first && gate.sentAfter == .hostPacket(WDPacketType.command))
    // Once only.
    let again = gate.hostPacket(type: WDPacketType.sessionInfo)
    let key = gate.keyEvent()
    #expect(!again && !key)

    var keyFirst = LEDGate()
    keyFirst.connectResponseSent()
    let byKey = keyFirst.keyEvent()
    let thenHost = keyFirst.hostPacket(type: WDPacketType.command)
    #expect(byKey && keyFirst.sentAfter == .keyEvent && !thenHost)
}

@Test func patternAClosesAfterConnectResponseWithoutHostPackets() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var m = EarlyDropMonitor()
    m.hostPacket(at: t0)                       // INIT_REQUEST etc. (handshake, not framed)
    m.connectResponseSent(at: t0.addingTimeInterval(0.1))
    let drop = m.classify(closedAt: t0.addingTimeInterval(0.125))
    #expect(drop == EarlyDrop(pattern: .a, milliseconds: 25))
    #expect(drop?.summary == "early drop pattern A, closed 25 ms after INIT_CONNECT_RESPONSE")
}

@Test func patternBIsATerminateBeforeThinwireInit() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var m = EarlyDropMonitor()
    m.connectResponseSent(at: t0)
    m.hostPacket(at: t0.addingTimeInterval(0.05))   // 0x44 credential request
    m.terminate(1, at: t0.addingTimeInterval(0.15))
    let drop = m.classify(closedAt: t0.addingTimeInterval(10))
    #expect(drop == EarlyDrop(pattern: .b, milliseconds: 150, terminateReason: 1))
}

@Test func otherEndsAreClassifiedApart() {
    let t0 = Date(timeIntervalSince1970: 1000)
    // Established: not an early drop, even with a later TERMINATE (a logoff).
    var est = EarlyDropMonitor()
    est.connectResponseSent(at: t0)
    est.hostPacket(at: t0)
    est.thinwireInit(at: t0.addingTimeInterval(1))
    est.terminate(1, at: t0.addingTimeInterval(60))
    #expect(est.classify(closedAt: t0.addingTimeInterval(61)) == nil)
    // Closed after host packets, no TERMINATE.
    var late = EarlyDropMonitor()
    late.connectResponseSent(at: t0)
    late.hostPacket(at: t0.addingTimeInterval(0.05))
    #expect(late.classify(closedAt: t0.addingTimeInterval(0.5))?.pattern == .afterHostPackets)
    // Closed before INIT_CONNECT_RESPONSE.
    #expect(EarlyDropMonitor().classify(closedAt: t0) == EarlyDrop(pattern: .beforeConnect))
}

@Test func packetRingKeepsTheLastPacketsAndRedacts() {
    var ring = PacketRing(capacity: 3)
    for i in 0..<5 { ring.received(WDPacket(type: WDPacketType.nop, channel: nil, payload: [UInt8(i)])) }
    #expect(ring.inbound.count == 3)
    #expect(ring.inbound.last?.hasSuffix("WD 0x35 1 B [04]") == true)
    // Credentials, keys and INIT_RESPONSE: type and length only.
    ring.sent([WDPacketType.command, 0x10, 0x00, 0x75, 0x73, 0x65, 0x72])
    ring.sent([WDPacketType.unicodeKey, 0x41, 0x00])
    ring.sentHandshake([WDPacketType.initResponse, 0x99, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
    #expect(ring.outbound.allSatisfy { !$0.contains("[") })
    #expect(ring.outbound[0].hasSuffix("WD 0x44 7 B"))
    // SET_LED and INIT_CONNECT_RESPONSE in full.
    ring.sent([WDPacketType.setLED, 0x20])
    ring.sentHandshake(WDBuild.initConnectResponse)
    #expect(ring.outbound.contains { $0.hasSuffix("WD 0x37 2 B [37 20]") })
    #expect(ring.outbound.last?.hasSuffix("handshake WD 0x04 3 B [04 00 00]") == true)
    // Channel data: channel, length and two bytes.
    #expect(PacketDump.outbound([WDPacketType.virtualWrite8, 4, 12, 0x33, 0xAA, 0xBB, 0xCC]) == "VC ch12 4 B [33 aa]")
    #expect(PacketDump.inbound(WDPacket(type: WDPacketType.virtualWrite16, channel: 9, payload: [1, 2, 3, 4])) == "VC ch9 4 B [01 02]")
    // Session info from the host: tag and value stay out.
    #expect(PacketDump.inbound(WDPacket(type: WDPacketType.sessionInfo, channel: nil, payload: Array("CTXSRVR".utf8) + [0, 1])) == "WD 0x3b 9 B")
    // At most 64 bytes.
    let long = PacketDump.inbound(WDPacket(type: WDPacketType.initRequest, channel: nil, payload: Array(repeating: 0xAB, count: 100)))
    #expect(long.hasSuffix(" …]") && long.components(separatedBy: "ab").count - 1 == 64)
}
