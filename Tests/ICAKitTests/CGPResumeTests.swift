import Testing
import Foundation
@testable import ICAKit

// Server → client CGP packets built byte by byte from docs/20 §3.3–3.7 (independent of the client code).
enum CGPFixture {
    static func varlen(_ v: Int) -> [UInt8] { v < 0x80 ? [UInt8(v)] : [UInt8(v & 0x7f) | 0x80, UInt8(v >> 7)] }
    static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> UInt32(8 * $0)) & 0xff) } }
    static func packet(_ command: UInt8, _ body: [UInt8]) -> [UInt8] { varlen(body.count + 1) + [command] + body }
    static func cap(_ id: Int, _ body: [UInt8]) -> [UInt8] { varlen(6 + body.count) + u16(0) + u16(id) + [0, 0] + body }

    /// SR cap in the client's layout (§3.5): live server body is 34 B with a 16-byte cookie.
    static func srCap(nextSeq: UInt32, reconnect: UInt8 = 0, serverByte: UInt8, cookie: [UInt8]) -> [UInt8] {
        cap(5, [1, 1, 1, 2, 5, 0, 1, 2, 5, 0] + u32(nextSeq) + [reconnect, serverByte] + varlen(cookie.count) + cookie + [0])
    }
    static func ticketCap(type: UInt8, _ ticket: [UInt8]) -> [UInt8] { cap(6, [type] + varlen(ticket.count) + ticket) }
    static func paramsCap(timeout: Int = 180, dimming: Int = 80) -> [UInt8] {
        cap(9, [1] + u16(timeout) + u16(1) + u16(dimming) + u16(60) + [0x0e])   // 10 bytes, as live (D3e)
    }
    static func keepaliveCap(c2h: UInt32 = 3000, h2c: UInt32 = 3000) -> [UInt8] { cap(7, u32(c2h) + u32(h2c)) }
    static var servicesCap: [UInt8] {
        let name = Array("Citrix.TcpProxyService".utf8)
        let entry = u16(1) + [1, 0, 0] + varlen(name.count) + name
        return cap(1, [1] + varlen(entry.count) + entry)
    }
    static func bindResponse(_ caps: [[UInt8]]) -> [UInt8] { packet(0x02, [0, 0, 0] + varlen(caps.count) + caps.flatMap { $0 }) }
    static func openResponse(status: Int = 0) -> [UInt8] { packet(0x07, [0x08, 0x01, 0x00] + u16(status) + u16(0) + [0, 0, 0]) }
    static func data(_ ica: [UInt8]) -> [UInt8] { packet(0x0a, ica) }
    static func dataWithAck(_ ack: Int, _ ica: [UInt8]) -> [UInt8] { packet(0x0b, varlen(ack) + ica) }
    static func ack(_ n: Int) -> [UInt8] { packet(0x05, [0x08, 0x02] + varlen(n)) }
    static func finish(type: UInt8 = 0, reason: UInt8) -> [UInt8] { packet(0x03, [0x00, type, reason]) }

    static let cookie = (0..<16).map { UInt8(0xc0 + $0) }
    static let ticket = (0..<87).map { UInt8(0x41 + $0 % 26) }
    static let openRequest: [UInt8] = [0x1d, 0x06, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x12, 0x01, 0x0e]
        + Array("127.0.0.1:1494".utf8) + [0x03, 0x00]

    static func firstBind(serverByte: UInt8 = 0x07, ticketType: UInt8 = 0x05) -> [UInt8] {
        bindResponse([ticketCap(type: ticketType, ticket), srCap(nextSeq: 0, serverByte: serverByte, cookie: cookie),
                      paramsCap(), keepaliveCap(), servicesCap])
    }
}

/// Collects what a session writes through `output`.
final class CGPSink: @unchecked Sendable {
    var packets: [Data] = []
}

/// A session past the first bind with the default channel open: rx 2 (open response, detect).
private func connectedSession() throws -> (CGPSession, CGPSink) {
    let s = CGPSession()
    let sink = CGPSink()
    s.output = { sink.packets.append($0) }
    _ = s.bindRequest(ticket: String(repeating: "x", count: 50))
    _ = try s.feed(CGPSession.signature + Data(CGPFixture.firstBind()))
    s.openChannel()
    _ = try s.feed(Data(CGPFixture.openResponse() + CGPFixture.data(Array(CGPSession.icaDetect))))
    return (s, sink)
}

@Test func firstBindStoresReconnectState() throws {
    let (s, sink) = try connectedSession()
    #expect(s.state == .connected)
    #expect(s.reconnectCookie == Data(CGPFixture.cookie))
    #expect(s.serverByte == 0x07)
    #expect(s.serverTicket?.type == 0x05)
    #expect(s.serverTicket?.ticket == Data(CGPFixture.ticket))
    #expect(s.reliabilityParams == CGPSession.ReliabilityParams(timeout: 180, uiFlags: 1, dimming: 80, tcpTimeout: 60))
    #expect(s.keepaliveIntervals?.h2c == 3000)
    #expect(s.serverReliability?.cookieLength == 16)
    // The open request went out once, unchanged, and is the stored item.
    #expect(sink.packets == [Data(CGPFixture.openRequest)])
    #expect(s.channelOpenPacket == Data(CGPFixture.openRequest))
    #expect(s.receivedSequenced == 2)
    #expect(s.txSent == 1 && s.queueCount == 1)
}

@Test func resumeBindMatchesWorkedExample() throws {
    // docs/20 §3.12.5: cookie 16 B, ticket 87 B, item 30 B → L = 249 (F9 01), 258 bytes.
    let (s, _) = try connectedSession()
    _ = try s.feed(Data(CGPFixture.data([1, 2]) + CGPFixture.data([3]) + CGPFixture.data([4])))   // rx 5
    s.sendDetectReply()
    s.suspend()
    let bind = s.resumeBindRequest()
    var e: [UInt8] = [0x1a, 0x43, 0x47, 0x50, 0x2f, 0x30, 0x31, 0xf9, 0x01, 0x01, 0x00, 0x00, 0x00, 0x06]
    e += [0x46, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x02, 0x05, 0x00, 0x01, 0x02, 0x05, 0x00]
    e += [0x06, 0x00, 0x00, 0x00, 0x01, 0x07, 0x10] + CGPFixture.cookie + [0x01]
    e += CGPFixture.openRequest
    e += [0x0f, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0xb4, 0x00, 0x01, 0x00, 0x19, 0x00, 0x0a, 0x00]
    e += [0x0e, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0xb8, 0x0b, 0x00, 0x00, 0xb8, 0x0b, 0x00, 0x00]
    e += [0x24, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x16] + Array("Citrix.TcpProxyService".utf8)
    e += [0x5f, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x05, 0x57] + CGPFixture.ticket
    e += [0x08, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00]
    #expect(e.count == 258)
    #expect(Array(bind) == e)
    #expect(s.state == .resuming)
    #expect(s.unacknowledged == 0)   // nextSeq acknowledged everything received
}

@Test func resumeBindFallsBackToSTATicketWithoutServerCap6() throws {
    let s = CGPSession()
    _ = s.bindRequest(ticket: "STA")
    _ = try s.feed(CGPSession.signature + Data(CGPFixture.bindResponse([
        CGPFixture.srCap(nextSeq: 0, serverByte: 2, cookie: [9, 9]), CGPFixture.servicesCap])))
    s.openChannel()
    s.suspend()
    let bind = Array(s.resumeBindRequest())
    #expect(bind.suffix(9) == [0x08, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00])
    let cap6: [UInt8] = [0x0b, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x03] + Array("STA".utf8)
    #expect(Array(bind.dropLast(9).suffix(cap6.count)) == cap6)
}

@Test func ackFieldIsZeroedInStoredCopies() {
    // 1-byte and 2-byte varlen acks in 0x0B; ack in a flagged 0x06; lengths and rflags unchanged.
    let short = Data(CGPFixture.dataWithAck(7, [0xaa, 0xbb]))
    #expect(Array(CGPSession.zeroingAck(short)) == [0x04, 0x0b, 0x00, 0xaa, 0xbb])
    let long = Data(CGPFixture.dataWithAck(300, [0xaa]))
    #expect(Array(CGPSession.zeroingAck(long)) == [0x04, 0x0b, 0x80, 0x00, 0xaa])
    let flagged = Data(CGPFixture.packet(0x06, [0x08, 0x03, 0x05, 0x01, 0x00]))
    #expect(Array(CGPSession.zeroingAck(flagged)) == [0x06, 0x06, 0x08, 0x03, 0x00, 0x01, 0x00])
    let plain = Data(CGPFixture.data([1, 2, 3]))
    #expect(CGPSession.zeroingAck(plain) == plain)
}

@Test func sentPacketCarriesAckButQueueCopyDoesNot() throws {
    let (s, sink) = try connectedSession()
    _ = try s.feed(Data(CGPFixture.data([1]) + CGPFixture.data([2]) + CGPFixture.data([3])))   // rx 5, unacked 5
    sink.packets.removeAll()
    s.sendData(Data([0x10, 0x20]))
    #expect(sink.packets == [Data([0x04, 0x0b, 0x05, 0x10, 0x20])])
    #expect(s.queuedPackets.last == Data([0x04, 0x0b, 0x00, 0x10, 0x20]))
    #expect(s.unacknowledged == 0)
    // Without piggybacking: plain 0x0A.
    s.sendData(Data([0x30]), piggybackAck: false)
    #expect(sink.packets.last == Data([0x02, 0x0a, 0x30]))
}

@Test func peerAcksFreeOldestQueueEntries() throws {
    let (s, _) = try connectedSession()                     // packet 1: open request
    for i in 0..<9 { s.sendData(Data([UInt8(i)]), piggybackAck: false) }   // packets 2…10
    #expect(s.queueCount == 10 && s.firstUnacked == 1)
    _ = try s.feed(Data(CGPFixture.dataWithAck(3, [0xee])))   // 0x0B ack field
    #expect(s.txAcked == 3 && s.queueCount == 7 && s.firstUnacked == 4)
    #expect(s.queuedPackets.first == Data([0x02, 0x0a, 0x02]))
    _ = try s.feed(Data(CGPFixture.ack(2)))                    // flagged 0x05, rflags bit 1
    #expect(s.txAcked == 5 && s.queueCount == 5)
    _ = try s.feed(Data([0x05, 0x05, 0x09, 0x02, 0x02, 0x01]))  // ack inside an extension block
    #expect(s.txAcked == 6 && s.queueCount == 4)
    #expect(s.queueBytes == 4 * 3)
    #expect(s.ackOverrun == 0)
}

@Test func receivedSequencedCountsOnlySequencedPackets() throws {
    let (s, _) = try connectedSession()   // open response (rflags 01) + detect (0x0A) = 2
    _ = try s.feed(Data(CGPFixture.ack(1) + [0x03, 0x05, 0x08, 0x00] + [0x01, 0x05]))   // acks, keepalives: not counted
    #expect(s.receivedSequenced == 2)
    _ = try s.feed(Data(CGPFixture.dataWithAck(0, [1]) + CGPFixture.packet(0x05, [0x08, 0x01])))
    #expect(s.receivedSequenced == 4)
}

@Test func detectReplyIsCountedAndQueued() throws {
    let (s, sink) = try connectedSession()
    sink.packets.removeAll()
    s.sendDetectReply()
    #expect(sink.packets == [Data([0x07, 0x0a, 0x7f, 0x7f, 0x49, 0x43, 0x41, 0x00])])
    #expect(s.txSent == 2 && s.queueCount == 2)
}

@Test func keepaliveFormAndNeverQueued() throws {
    let (s, _) = try connectedSession()
    #expect(s.keepalive() == Data([0x04, 0x05, 0x08, 0x02, 0x02]))   // pending ack of 2
    #expect(s.keepalive() == Data([0x03, 0x05, 0x08, 0x00]))
    #expect(s.queueCount == 1 && s.txSent == 1)
}

@Test func nothingIsWrittenOrAckedWhileSuspended() throws {
    let (s, sink) = try connectedSession()
    _ = try s.feed(Data((0..<6).flatMap { CGPFixture.data([UInt8($0)]) }))   // rx 8: ack due
    s.suspend()
    sink.packets.removeAll()
    #expect(s.pendingAck() == nil)
    s.sendData(Data([0x42]))
    #expect(sink.packets.isEmpty)
    #expect(s.queuedPackets.last == Data([0x02, 0x0a, 0x42]))   // built without the pending ack
    #expect(s.unacknowledged == 8)
}

@Test func parserResetsOnNewConnection() throws {
    let (s, _) = try connectedSession()
    _ = try s.feed(Data([0x05, 0x0a, 0x01]))   // partial packet when the link dies
    s.suspend()
    _ = s.resumeBindRequest()
    #expect(throws: CGPSession.Failure.self) { _ = try s.feed(Data(CGPFixture.data([1, 2, 3, 4, 5, 6]))) }   // no signature
    let s2 = try connectedSession().0
    _ = try s2.feed(Data([0x05, 0x0a, 0x01]))
    s2.suspend()
    _ = s2.resumeBindRequest()
    let events = try s2.feed(CGPSession.signature + Data(CGPFixture.bindResponse([
        CGPFixture.srCap(nextSeq: 2, reconnect: 1, serverByte: 7, cookie: CGPFixture.cookie)])))
    #expect(events.count == 2)
    if case .resumed = events.last {} else { Issue.record("not resumed: \(events)") }
    #expect(s2.receivedSequenced == 2)   // the partial packet was not counted
}

@Test func packetBeforeResumeResponseIsAProtocolError() throws {
    let (s, _) = try connectedSession()
    s.suspend()
    _ = s.resumeBindRequest()
    #expect(throws: CGPSession.Failure.self) { _ = try s.feed(CGPSession.signature + Data(CGPFixture.data([1]))) }
}

/// Session with packets 1…6 sent (open request + 5 data), server acked 2, then suspended and resumed.
private func resumedSession(serverNextSeq: UInt32, extra: [[UInt8]] = []) throws -> (CGPSession, CGPSink, [CGPSession.Event]) {
    let (s, sink) = try connectedSession()
    for i in 0..<5 { s.sendData(Data([0xd0 + UInt8(i)]), piggybackAck: false) }
    _ = try s.feed(Data(CGPFixture.ack(2)))
    s.suspend()
    s.sendData(Data([0xe0]))                     // packet 7, built while suspended
    _ = s.resumeBindRequest()
    sink.packets.removeAll()
    let response = CGPFixture.bindResponse([CGPFixture.ticketCap(type: 0x09, [1, 2, 3]),
                                            CGPFixture.srCap(nextSeq: serverNextSeq, reconnect: 1, serverByte: 0x33, cookie: [7, 7, 7])]
                                           + extra)
    let events = try s.feed(CGPSession.signature + Data(response))
    return (s, sink, events)
}

@Test func resumeResponseDropsAcknowledgedAndRetransmitsTheRest() throws {
    // Packets 2…6 carry d0…d4, 7 carries e0. Queue holds 3…7 (firstUnacked 3); server expects 5 →
    // drop 3, 4; resend 5, 6, 7 in order.
    let (s, sink, events) = try resumedSession(serverNextSeq: 5, extra: [CGPFixture.paramsCap(timeout: 9, dimming: 1)])
    guard case .resumed(let r) = events.last else { Issue.record("not resumed: \(events)"); return }
    #expect(r.serverNextSeq == 5 && r.sentNextSeq == 3 && r.queueBefore == 5 && r.dropped == 2 && r.retransmitted == 3)
    #expect(sink.packets == [Data([0x02, 0x0a, 0xd3]), Data([0x02, 0x0a, 0xd4]), Data([0x02, 0x0a, 0xe0])])
    #expect(s.state == .connected && s.txAcked == 4 && s.firstUnacked == 5)
    // Caps 5 and 6 replace the reconnect state; cap 9 is ignored on resume.
    #expect(s.reconnectCookie == Data([7, 7, 7]) && s.serverByte == 0x33)
    #expect(s.serverTicket?.type == 0x09 && s.serverTicket?.ticket == Data([1, 2, 3]))
    #expect(s.reliabilityParams?.timeout == 180)
    // New packets follow the retransmits.
    s.sendData(Data([0xf0]), piggybackAck: false)
    #expect(sink.packets.last == Data([0x02, 0x0a, 0xf0]))
    // The next resume bind carries the new cookie and ticket.
    s.suspend()
    let bind = Array(s.resumeBindRequest())
    #expect(bind.contains(subsequence: [0x01, 0x33, 0x03, 7, 7, 7, 0x01]))
    #expect(bind.contains(subsequence: [0x0b, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x09, 0x03, 1, 2, 3]))
}

@Test func resumeResponseWithNothingLost() throws {
    let (s, sink, events) = try resumedSession(serverNextSeq: 3)
    guard case .resumed(let r) = events.last else { Issue.record("not resumed"); return }
    #expect(r.dropped == 0 && r.retransmitted == 5 && sink.packets.count == 5)
    #expect(s.queueCount == 5)
}

@Test func resumeRefusals() throws {
    for (n, expected) in [(UInt32(0), "refused"), (2, "alreadyAcknowledged"), (9, "beyondQueue")] {
        let (s, sink, events) = try resumedSession(serverNextSeq: n)
        guard case .resumeRefused(let why) = events.last else { Issue.record("n=\(n): \(events)"); continue }
        let kind: String
        switch why {
        case .refused: kind = "refused"
        case .noReliabilityCap: kind = "noReliabilityCap"
        case .alreadyAcknowledged: kind = "alreadyAcknowledged"
        case .beyondQueue: kind = "beyondQueue"
        }
        #expect(kind == expected)
        #expect(s.state == .failed && sink.packets.isEmpty)
    }
    // N = firstUnacked + queue length (8) is the edge that still resumes: everything dropped.
    let (_, sink, events) = try resumedSession(serverNextSeq: 8)
    if case .resumed(let r) = events.last { #expect(r.dropped == 5 && r.retransmitted == 0 && sink.packets.isEmpty) }
    else { Issue.record("n=8 not resumed") }
    // A resume response without SR cap.
    let (s, _) = try connectedSession()
    s.suspend()
    _ = s.resumeBindRequest()
    let events2 = try s.feed(CGPSession.signature + Data(CGPFixture.bindResponse([CGPFixture.servicesCap])))
    if case .resumeRefused(.noReliabilityCap) = events2.last {} else { Issue.record("\(events2)") }
}

@Test func queueLimitReported() throws {
    let (s, _) = try connectedSession()
    s.suspend()
    let block = Data(repeating: 0x55, count: 16_000)
    var ok = true
    var n = 0
    while ok, n < 1000 { ok = s.sendData(block); n += 1 }
    #expect(!ok)
    #expect(s.queueBytes > s.queueLimit)
    #expect(n == CGPSession.defaultQueueLimit / (block.count + 3) + 1)
}

@Test func abandonedReliabilityStopsStoringButKeepsSending() throws {
    let (s, sink) = try connectedSession()
    s.abandonReliability()
    sink.packets.removeAll()
    #expect(s.sendData(Data([1]), piggybackAck: false))
    #expect(sink.packets == [Data([0x02, 0x0a, 0x01])])
    #expect(s.queueCount == 0 && s.queueBytes == 0 && s.txSent == 2)
    _ = try s.feed(Data(CGPFixture.ack(2)))
    #expect(s.ackOverrun == 0)
}

@Test func unknownSequencedCommandCountsTowardNextSeq() throws {
    let (s, _) = try connectedSession()   // rx 2
    let events = try s.feed(Data(CGPFixture.packet(0x0c, [0x08, 0x01, 0xaa, 0xbb])))   // sequenced, unknown
    #expect(s.receivedSequenced == 3)
    if case .other(let command, _) = events.first { #expect(command == 0x0c) } else { Issue.record("\(events)") }
    _ = try s.feed(Data(CGPFixture.packet(0x0d, [0x08, 0x02, 0x01])))   // unknown, ack only
    #expect(s.receivedSequenced == 3 && s.txAcked == 1)
    _ = try s.feed(Data(CGPFixture.packet(0x0e, [])))   // no flags: reported, not fatal
    #expect(s.receivedSequenced == 3)
}

@Test func failureKeepsThePacketsParsedBeforeIt() throws {
    let (s, _) = try connectedSession()
    // Two data packets, then a BIND_REQUEST from the server (a protocol error).
    let result = s.consume(Data(CGPFixture.data([1]) + CGPFixture.data([2]) + CGPFixture.packet(0x01, [0, 0, 0, 0])))
    #expect(result.error != nil)
    #expect(result.events.count == 2)
    if case .data(let d) = result.events.last { #expect(d == Data([2])) } else { Issue.record("\(result.events)") }
    #expect(s.receivedSequenced == 4)
}

@Test func giveUpMessagesFollowTheTable() {
    let later = Date().addingTimeInterval(100)
    #expect(CGPTransport.giveUpInfo(.deadline, notBefore: later).message == "Unable to re-establish a connection to the server.")
    #expect(CGPTransport.giveUpInfo(.offline, notBefore: later).message == "Check your network connection.")
    #expect(CGPTransport.giveUpInfo(.refused(.refused), notBefore: later).relaunchNotBefore == nil)
    #expect(CGPTransport.giveUpInfo(.refused(.beyondQueue(serverNextSeq: 9, firstUnacked: 3, queued: 5)), notBefore: later).relaunchNotBefore == later)
    #expect(CGPTransport.giveUpInfo(.serverFinish(reason: 0x11), notBefore: later).message == "The gateway rejected the reconnect ticket.")
    #expect(CGPTransport.giveUpInfo(.serverFinish(reason: 0x01), notBefore: later).message == "The session could not be resumed.")
    #expect(CGPTransport.giveUpInfo(.serverFinish(reason: 0x03), notBefore: later).message == "An administrator disconnected the session.")
    #expect(CGPTransport.giveUpInfo(.serverFinish(reason: 0x00), notBefore: later).offerRelaunch == false)
}

extension Array where Element == UInt8 {
    func contains(subsequence: [UInt8]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return (0...(count - subsequence.count)).contains { Array(self[$0..<($0 + subsequence.count)]) == subsequence }
    }
}

@Test func freshLogonNeedsLogonUIThenALateSecondInit() {
    let t0 = Date()
    // Fresh logon: logon UI, post-logon Thinwire INIT 12 s later.
    var fresh = FreshLogonDetector()
    #expect(fresh.thinwireInit(at: t0) == nil)
    fresh.windowAdded(appKey: "C:\\Windows\\System32\\LogonUI.exe", at: t0)
    #expect(fresh.thinwireInit(at: t0.addingTimeInterval(12)) == 12)
    #expect(fresh.isFresh)
    // Reconnect after the logon UI: second INIT only 1.7 s later.
    var quick = FreshLogonDetector()
    quick.windowAdded(appKey: "c:\\windows\\system32\\logonui.exe", at: t0)
    _ = quick.hostInit(at: t0)
    _ = quick.hostInit(at: t0.addingTimeInterval(1.7))
    #expect(!quick.isFresh && quick.sawLogonUI)
    // Plain reconnect: no logon UI at all, however many inits.
    var plain = FreshLogonDetector()
    plain.windowAdded(appKey: "C:\\Program Files\\App\\app.exe", at: t0)
    for i in 0..<3 { _ = plain.thinwireInit(at: t0.addingTimeInterval(Double(i) * 10)) }
    #expect(!plain.isFresh && !plain.sawLogonUI)
}
