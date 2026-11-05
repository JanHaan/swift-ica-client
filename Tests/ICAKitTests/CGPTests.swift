import Testing
import Foundation
@testable import ICAKit

@Test func bindRequestMatchesWorkedExample() {
    // docs/20-transport.md §7.1: T = 50 → length field A6 01, 175 bytes in total.
    let data = CGPSession().bindRequest(ticket: String(repeating: "x", count: 50))
    #expect(data.count == 175)
    #expect(Array(data.prefix(14)) == [0x1a, 0x43, 0x47, 0x50, 0x2f, 0x30, 0x31, 0xa6, 0x01, 0x01, 0x00, 0x00, 0x00, 0x06])
    #expect(Array(data.suffix(9)) == [0x08, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00])
}

@Test func channelOpenMatchesWorkedExample() {
    let expected: [UInt8] = [0x1d, 0x06, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x12, 0x01, 0x0e]
        + Array("127.0.0.1:1494".utf8) + [0x03, 0x00]
    #expect(Array(CGPSession().channelOpenRequest()) == expected)
}

@Test func parsesSignatureAndDataAcrossChunks() throws {
    let session = CGPSession()
    let stream = CGPSession.signature + Data([0x07, 0x0a]) + CGPSession.icaDetect
    var events: [CGPSession.Event] = []
    for byte in stream { events += try session.feed(Data([byte])) }
    #expect(events.count == 2)
    if case .data(let payload) = events.last { #expect(payload == CGPSession.icaDetect) } else { Issue.record("no data") }
}
