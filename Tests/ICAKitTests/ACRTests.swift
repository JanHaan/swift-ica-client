import Testing
import Foundation
@testable import ICAKit

// Auto client reconnect (docs/30 §15.6): cap 0x0A, WD flag 0x10, the 0x41 cookie, the reconnect bind and the verdicts.

/// The host's final cap 0x0A body as seen live (docs/30 §15.6): version 0, acrTimeout 120 s, estimated TCP timeout 60 s.
private let liveFinalACRBody: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x78, 0x00, 0x01, 0x00, 0x50, 0x00, 0x3c, 0x00]

@Test func acrCapabilityOnlyWhenEnabled() throws {
    let request = try WDInitRequest(payload: Array(bytes(hex: liveInitRequestHex).dropFirst(3)))
    #expect(request.capability(WDCapability.acrCookie) != nil)
    var policy = WDCapabilityPolicy()
    #expect(!policy.negotiate(server: request.capabilities).contains { $0.id == WDCapability.acrCookie })
    policy.acr = true
    let cap = policy.negotiate(server: request.capabilities).first { $0.id == WDCapability.acrCookie }
    #expect(cap?.bytes == [16, 0, 0x0A, 0, 0x02, 0x00, 0x80, 0x00] + [UInt8](repeating: 0, count: 8))
    policy.acrReplyBody = WDCapabilityPolicy.acrReferenceBody
    let ref = policy.negotiate(server: request.capabilities).first { $0.id == WDCapability.acrCookie }
    #expect(ref?.bytes == [16, 0, 0x0A, 0] + [UInt8](repeating: 0, count: 12))
    // Never advertised if the server does not offer it (§4.2).
    #expect(!policy.negotiate(server: []).contains { $0.id == WDCapability.acrCookie })
}

@Test func acrParametersFromFinalCapability() {
    let params = WDACRParameters([WDCapability(id: 0x05), WDCapability(id: WDCapability.acrCookie, body: liveFinalACRBody)])
    #expect(params == WDACRParameters(version: 0, a: 0, acrTimeout: 120, b: 1, c: 80, estimatedTcpTimeout: 60))
    #expect(params?.enabled == true)
    #expect(WDACRParameters(WDCapability(id: WDCapability.acrCookie, body: [UInt8](repeating: 0, count: 12)))?.enabled == false)
    #expect(WDACRParameters(WDCapability(id: WDCapability.acrCookie, body: [0, 0, 0])) == nil)
    #expect(WDACRParameters([WDCapability(id: 0x05)]) == nil)
}

@Test func wdModuleFlagForACRReconnect() {
    let caps = [WDCapability(id: 0x05)]
    #expect(Array(WDModules.wd(capabilities: caps, channels: [])[48..<52]) == [0x0F, 0, 0, 0])
    #expect(Array(WDModules.wd(capabilities: caps, channels: [], acrReconnect: true)[48..<52]) == [0x1F, 0, 0, 0])
}

@Test func cookieReplyLayout() {
    #expect(WDBuild.acrCookieReply([]) == [0x41, 0x01, 0x00, 0x01])
    #expect(WDBuild.acrCookieReply([0xAA, 0xBB]) == [0x41, 0x03, 0x00, 0x01, 0xAA, 0xBB])
}

/// A driver through the handshake (live INIT_REQUEST, minimal INIT_CONNECTs with the given final caps).
private func connectedDriver(_ config: WinstationDriver.Configuration, finalCaps: [WDCapability] = []) -> (WinstationDriver, () -> [[UInt8]], WDBasicCipher) {
    let wd = WinstationDriver(configuration: config, encryptionKey: 0x42, obfuscationSeed: 0x11)
    wd.register(RecordingEngine("CTXTW  "))
    wd.register(RecordingEngine("CTXTWI\0"))
    final class Box { var sent: [[UInt8]] = [] }
    let box = Box()
    wd.transmit = { box.sent.append($0) }
    wd.receive(Data(bytes(hex: liveInitRequestHex)))
    var pd = [UInt8](repeating: 0, count: 12)
    pd[2] = 1; pd[3] = 4; pd[8] = 0x0B
    let block = WDCapabilityBlock.serialize(finalCaps)
    var wdConnect = [UInt8](repeating: 0, count: 36) + block
    wdConnect[0] = UInt8(wdConnect.count & 0xff); wdConnect[1] = UInt8(wdConnect.count >> 8)
    wdConnect[2] = 0; wdConnect[3] = 2
    wdConnect[32] = UInt8(block.count); wdConnect[34] = 36
    // INIT_CONNECTs, then the framed encryption init request (answered `04 00 <key>`, docs/30 §8.2).
    wd.receive(Data([0x02, 12, 0] + pd + [0x02, UInt8(wdConnect.count & 0xff), UInt8(wdConnect.count >> 8)] + wdConnect
                    + WDFraming.frame([0x02])))
    return (wd, { defer { box.sent = [] }; return box.sent }, WDBasicCipher(key: 0x42))
}

private func serverPacket(_ packet: [UInt8], _ cipher: inout WDBasicCipher) -> Data {
    var p = packet
    cipher.encrypt(&p)
    return Data(WDFraming.frame([0x01] + p))
}

private func decrypted(_ frame: [UInt8], _ cipher: inout WDBasicCipher) -> [UInt8] {
    var p = Array(frame.dropFirst(3))
    cipher.decrypt(&p)
    return p
}

@Test func initResponseCarriesFlag0x10OnlyWithCookie() throws {
    var config = WinstationDriver.Configuration()
    config.logon.initialProgram = "#Calc App"
    config.policy.acr = true
    let wd1 = WinstationDriver(configuration: config)
    wd1.register(RecordingEngine("CTXTW  "))
    var first: [[UInt8]] = []
    wd1.transmit = { first.append($0) }
    wd1.receive(Data(bytes(hex: liveInitRequestHex)))
    try #require(first.count > 1 && first[0].count > 60)
    #expect(Array(first[0][(3 + 48)..<(3 + 52)]) == [0x0F, 0, 0, 0])
    #expect(!wd1.isACRReconnect)

    config.acrReconnectCookie = [1, 2, 3]
    let wd2 = WinstationDriver(configuration: config)
    wd2.register(RecordingEngine("CTXTW  "))
    var second: [[UInt8]] = []
    wd2.transmit = { second.append($0) }
    wd2.receive(Data(bytes(hex: liveInitRequestHex)))
    try #require(second.count > 1)
    #expect(Array(second[0][(3 + 48)..<(3 + 52)]) == [0x1F, 0, 0, 0])
    #expect(wd2.isACRReconnect)

    config.acrReconnectCookie = []
    #expect(!WinstationDriver(configuration: config).isACRReconnect)
}

@Test func cookieIsStoredAndAnsweredOnQuery() {
    var config = WinstationDriver.Configuration()
    config.policy.acr = true
    let (wd, sent, cipher) = connectedDriver(config, finalCaps: [WDCapability(id: WDCapability.acrCookie, body: liveFinalACRBody)])
    var server = cipher, client = cipher
    var events: [String] = []
    wd.onEvent = { event in
        switch event {
        case .acrCookie(let n): events.append("cookie \(n)")
        case .acrQuery(let n): events.append("query \(n)")
        case .acrOther(let sub, let n): events.append("other \(sub) \(n)")
        default: break
        }
    }
    #expect(wd.acrParameters?.acrTimeout == 120)
    #expect(wd.everConnected)
    _ = sent()

    // Query before any cookie: the empty answer.
    wd.receive(serverPacket([0x41, 0x01, 0x00, 0x02], &server))
    var out = sent()
    #expect(out.count == 1 && decrypted(out[0], &client) == [0x41, 0x01, 0x00, 0x01])

    // Sub 1 stores the cookie (the whole payload, its `01` included); a later one replaces it; the query is answered
    // with the latest, repeating that payload after the reply's own `01` (live, D84).
    wd.receive(serverPacket([0x41, 0x04, 0x00, 0x01, 0x10, 0x20, 0x30], &server))
    wd.receive(serverPacket([0x41, 0x05, 0x00, 0x01, 0xA1, 0xA2, 0xA3, 0xA4], &server))
    #expect(sent().isEmpty)
    #expect(wd.acrCookieLength == 5)
    wd.receive(serverPacket([0x41, 0x01, 0x00, 0x02], &server))
    out = sent()
    #expect(out.count == 1 && decrypted(out[0], &client) == [0x41, 0x06, 0x00, 0x01, 0x01, 0xA1, 0xA2, 0xA3, 0xA4])
    wd.receive(serverPacket([0x41, 0x02, 0x00, 0x07, 0x00], &server))
    #expect(events == ["query 0", "cookie 4", "cookie 5", "query 5", "other 7 1"])
}

@Test func reconnectCookieAnswersTheFirstQuery() {
    var config = WinstationDriver.Configuration()
    config.acrReconnectCookie = [9, 8, 7]
    let (wd, sent, cipher) = connectedDriver(config)
    var server = cipher, client = cipher
    _ = sent()
    wd.receive(serverPacket([0x41, 0x01, 0x00, 0x02], &server))
    let out = sent()
    #expect(out.count == 1 && decrypted(out[0], &client) == [0x41, 0x04, 0x00, 0x01, 9, 8, 7])
}

@Test func refusedReplyFormStaysAvailableForDiscovery() {
    var config = WinstationDriver.Configuration()
    config.acrReconnectCookie = [0x01, 0xA1, 0xA2]
    config.acrReplyForm = .afterSub
    let (wd, sent, cipher) = connectedDriver(config)
    var server = cipher, client = cipher
    _ = sent()
    wd.receive(serverPacket([0x41, 0x01, 0x00, 0x02], &server))
    let out = sent()
    #expect(out.count == 1 && decrypted(out[0], &client) == [0x41, 0x03, 0x00, 0x01, 0xA1, 0xA2])
}

@Test func reconnectBindUsesTheServerTicketWithoutResume() throws {
    let s = CGPSession()
    _ = s.bindRequest(ticket: String(repeating: "x", count: 43))
    #expect(s.reconnectTicket == nil)
    _ = try s.feed(CGPSession.signature + Data(CGPFixture.firstBind(ticketType: 0x05)))
    let ticket = try #require(s.reconnectTicket)
    #expect(ticket.type == 0x05 && ticket.length == 87)
    #expect(!ticket.description.contains("A"))   // type and length only

    // A new CGP session for the ACR connect: a first bind, cap 6 = the server ticket, cap 5 in the initial form.
    let acr = CGPSession()
    let bind = acr.bindRequest(reconnect: ticket)
    #expect(acr.state == .binding)
    let viaString = CGPSession().bindRequest(ticket: String(decoding: CGPFixture.ticket, as: UTF8.self))
    // Same bytes as a first bind with that ticket as `Address`, except the type byte.
    #expect(bind.count == viaString.count)
    #expect(acr.bindRequest(reconnect: ticket.withType(0)) == viaString)
    let cap6 = CGPFixture.ticketCap(type: 0x05, CGPFixture.ticket)
    #expect(bind.range(of: Data(cap6)) != nil)
    let initialSR = CGPFixture.cap(5, [1, 1, 1, 2, 5, 0, 1, 2, 5, 0, 0, 0, 0, 0, 0, 2, 0, 0])
    #expect(bind.range(of: Data(initialSR)) != nil)
}

@Test func attemptVerdicts() {
    let now = Date()
    // Reconnected: bind, handshake, cookie query, Thinwire INIT and the app window, no logon UI.
    var ok = ACRAttemptMonitor()
    ok.tlsConnected()
    ok.note(.cgpBound([]))
    ok.note(.wd(.connected(reducerVersion: 3, reducerPower: 0, expanderPower: 19, capabilities: [])))
    ok.note(.wd(.acrQuery(answeredLength: 16)))
    #expect(ok.success == nil)
    ok.thinwireInit(at: now)
    ok.windowAdded(kind: .appWindow, appKey: "exe:C:\\Windows\\System32\\calc.exe", at: now)
    #expect(ok.success == .reconnected)
    #expect(ok.cookieAnswered == 16)

    // Gateway: no bind response, or FINISH reason 0x11 before it.
    var gw = ACRAttemptMonitor()
    gw.tlsConnected()
    #expect(gw.verdict(closed: "transport: reset") == .gatewayRejected("closed without a bind response (transport: reset)"))
    gw.serverFinished(reason: 0x11)
    #expect(gw.verdict(closed: "x") == .gatewayRejected("ticket invalid or unknown (reason 0x11)"))
    #expect(!gw.verdict(closed: "x").isRetryable)

    // No TLS connection at all: retried.
    #expect(ACRAttemptMonitor().verdict(closed: "timeout").isRetryable)

    // Host: TERMINATE after the cookie.
    var host = ACRAttemptMonitor()
    host.tlsConnected()
    host.note(.cgpBound([]))
    host.note(.wd(.connected(reducerVersion: 3, reducerPower: 0, expanderPower: 19, capabilities: [])))
    host.note(.wd(.acrQuery(answeredLength: 16)))
    host.note(.wd(.terminate(reason: 1)))
    #expect(host.verdict(closed: "ended") == .hostRefused("cookie (16 B) refused: TERMINATE reason 1"))

    // Cookie taken (new cookie, Thinwire INIT), then the Windows logon screen and TERMINATE (live, D84 runs 5-6).
    var screen = ACRAttemptMonitor()
    screen.tlsConnected()
    screen.note(.cgpBound([]))
    screen.note(.wd(.connected(reducerVersion: 3, reducerPower: 0, expanderPower: 19, capabilities: [])))
    screen.note(.wd(.acrQuery(answeredLength: 69)))
    screen.note(.wd(.acrCookie(length: 69)))
    screen.thinwireInit(at: now)
    screen.windowAdded(kind: .appWindow, appKey: "exe:C:\\Windows\\System32\\LogonUI.exe", at: now.addingTimeInterval(3))
    #expect(screen.success == nil)
    screen.note(.wd(.terminate(reason: 1)))
    #expect(screen.verdict(closed: "ended by server") == .logonRequired("TERMINATE reason 1 at the logon screen"))
    #expect(!screen.verdict(closed: "x").isRetryable)

    // New logon: the logon UI, then the second Thinwire INIT 12 s later.
    var fresh = ACRAttemptMonitor()
    fresh.tlsConnected()
    fresh.note(.cgpBound([]))
    fresh.thinwireInit(at: now)
    fresh.windowAdded(kind: .appWindow, appKey: "exe:C:\\Windows\\System32\\LogonUI.exe", at: now)
    #expect(fresh.success == nil)
    fresh.thinwireInit(at: now.addingTimeInterval(12))
    #expect(fresh.success == .newLogon)

    // A reconnect may show the logon UI briefly (D18: 1.7 s): still a reconnect.
    var brief = ACRAttemptMonitor()
    brief.thinwireInit(at: now)
    brief.windowAdded(kind: .appWindow, appKey: "exe:C:\\Windows\\System32\\LogonUI.exe", at: now)
    brief.thinwireInit(at: now.addingTimeInterval(1.7))
    brief.windowAdded(kind: .appWindow, appKey: "exe:C:\\Windows\\System32\\calc.exe", at: now.addingTimeInterval(2))
    #expect(brief.success == .reconnected)
}
