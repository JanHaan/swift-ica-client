import Testing
import Foundation
@testable import ICAKit

// Synthetic captures (neutral data, documentation addresses) for the pcap(ng) reader (lab backlog 0.3).

private let client = ([UInt8]([192, 0, 2, 10]), UInt16(50000))
private let server = ([UInt8]([192, 0, 2, 20]), UInt16(2598))

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

/// Ethernet + IPv4 + TCP or UDP.
private func frame(from: ([UInt8], UInt16), to: ([UInt8], UInt16), tcp: Bool = true, seq: UInt32 = 0, flags: UInt8 = 0x18,
                   id: UInt16 = 1, vlan: Bool = false, payload: [UInt8]) -> [UInt8] {
    let l4: [UInt8] = tcp
        ? be16(from.1) + be16(to.1) + be32(seq) + be32(0) + [0x50, flags] + be16(65535) + [0, 0, 0, 0] + payload
        : be16(from.1) + be16(to.1) + be16(UInt16(8 + payload.count)) + [0, 0] + payload
    let ip: [UInt8] = [0x45, 0] + be16(UInt16(20 + l4.count)) + be16(id) + [0x40, 0, 64, tcp ? 6 : 17, 0, 0] + from.0 + to.0
    let eth: [UInt8] = [2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2] + (vlan ? [0x81, 0x00, 0x00, 0x07] : []) + [0x08, 0x00]
    return eth + ip + l4
}

/// pcapng: SHB, one IDB (Ethernet, optional if_tsresol), EPBs; little-endian.
private func pcapng(_ frames: [(time: UInt64, bytes: [UInt8])], tsresol: UInt8? = nil) -> Data {
    func block(_ type: UInt32, _ body: [UInt8]) -> [UInt8] {
        let padded = body + [UInt8](repeating: 0, count: (4 - body.count % 4) % 4)
        let total = UInt32(12 + padded.count)
        return le32(type) + le32(total) + padded + le32(total)
    }
    var out = block(0x0A0D_0D0A, le32(0x1A2B_3C4D) + le16(1) + le16(0) + [UInt8](repeating: 0xFF, count: 8))
    var idb = le16(1) + le16(0) + le32(0)
    if let r = tsresol { idb += le16(9) + le16(1) + [r, 0, 0, 0] + le16(0) + le16(0) }
    out += block(1, idb)
    for f in frames {
        out += block(6, le32(0) + le32(UInt32(f.time >> 32)) + le32(UInt32(f.time & 0xFFFF_FFFF))
                     + le32(UInt32(f.bytes.count)) + le32(UInt32(f.bytes.count)) + f.bytes)
    }
    return Data(out)
}

/// Classic pcap, big-endian, microseconds.
private func pcapBE(_ frames: [(sec: UInt32, usec: UInt32, bytes: [UInt8])]) -> Data {
    var out = be32(0xA1B2_C3D4) + be16(2) + be16(4) + be32(0) + be32(0) + be32(65535) + be32(1)
    for f in frames { out += be32(f.sec) + be32(f.usec) + be32(UInt32(f.bytes.count)) + be32(UInt32(f.bytes.count)) + f.bytes }
    return Data(out)
}

@Test func pcapngReadsFramesWithTimestamps() throws {
    let p = Array("hello".utf8)
    let data = pcapng([(1_700_000_000_000_000, frame(from: client, to: server, payload: p)),
                       (1_700_000_000_250_000, frame(from: server, to: client, payload: p))])
    let frames = try CaptureFile.read(data)
    #expect(frames.count == 2)
    #expect(frames[0].linkType == CaptureLinkType.ethernet)
    #expect(abs(frames[1].time - frames[0].time - 0.25) < 1e-9)
    let packet = try #require(CapturedPacket.parse(frames[0]))
    #expect(packet.transport == .tcp)
    #expect(packet.source == CaptureEndpoint("192.0.2.10", 50000))
    #expect(packet.destination.port == 2598)
    #expect(packet.payload == p)
}

@Test func pcapngHonoursTimestampResolution() throws {
    // if_tsresol 9: nanoseconds.
    let data = pcapng([(1_500_000_000, frame(from: client, to: server, payload: [1]))], tsresol: 9)
    let frames = try CaptureFile.read(data)
    #expect(abs(frames[0].time - 1.5) < 1e-9)
}

@Test func classicPcapBigEndianAndVLAN() throws {
    let data = pcapBE([(10, 500_000, frame(from: client, to: server, vlan: true, payload: [9, 8, 7]))])
    let frames = try CaptureFile.read(data)
    #expect(frames.count == 1)
    #expect(abs(frames[0].time - 10.5) < 1e-9)
    #expect(CapturedPacket.parse(frames[0])?.payload == [9, 8, 7])
}

@Test func rejectsUnknownFiles() {
    #expect(throws: CaptureFileError.unknownFormat(0x6c6c6568)) { try CaptureFile.read(Data("hello world".utf8)) }
}

@Test func tcpReassemblyOrdersDropsDuplicatesAndFillsGaps() {
    var d = TCPDirection()
    func seg(_ seq: UInt32, _ bytes: String, flags: UInt8 = 0x18, t: Double) -> CapturedPacket {
        CapturedPacket(time: t, transport: .tcp, source: CaptureEndpoint("a", 1), destination: CaptureEndpoint("b", 2),
                       ipID: nil, seq: seq, flags: flags, payload: Array(bytes.utf8))
    }
    d.add(seg(999, "", flags: 0x02, t: 0))      // SYN: data starts at 1000
    d.add(seg(1004, "EFGH", t: 2))               // out of order
    d.add(seg(1000, "ABCD", t: 3))               // fills the hole
    d.add(seg(1000, "ABCD", t: 4))               // retransmission
    d.add(seg(1002, "CDEFGHIJ", t: 5))           // overlapping retransmission with new bytes
    d.add(seg(1014, "OP", t: 6))                 // after a lost segment (1010..1013)
    d.finish()
    #expect(String(decoding: d.bytes, as: UTF8.self) == "ABCDEFGHIJ\0\0\0\0OP")
    #expect(d.duplicates == 1)
    #expect(d.gaps == 1 && d.missingBytes == 4)
    #expect(d.time(atEnd: 8) == 3)               // EFGH (sent at t=2) became contiguous with the t=3 segment
    #expect(d.time(atEnd: 10) == 5)
}

@Test func tcpReassemblyWrapsSequenceNumbers() {
    var d = TCPDirection()
    func seg(_ seq: UInt32, _ bytes: [UInt8]) -> CapturedPacket {
        CapturedPacket(time: 0, transport: .tcp, source: CaptureEndpoint("a", 1), destination: CaptureEndpoint("b", 2),
                       ipID: nil, seq: seq, payload: bytes)
    }
    d.add(seg(0xFFFF_FFFE, [1, 2]))
    d.add(seg(0x0000_0002, [5]))
    d.add(seg(0x0000_0000, [3, 4]))
    d.finish()
    #expect(d.bytes == [1, 2, 3, 4, 5])
}

@Test func captureSplitsConnectionsUnwrapsCGPAndListsUDP() throws {
    // Client → server: CGP signature, a bind-like packet (cmd 0x01), a data packet (0x0a), a data-with-ack packet
    // (0x0b, delta 3) whose length needs the two-byte varlen.
    let bind: [UInt8] = [0x03, 0x01, 0x00, 0x00]
    let ica1: [UInt8] = [0x7F, 0x7F, 0x49, 0x43, 0x41, 0x00]
    let ica2 = [UInt8](repeating: 0x42, count: 200)
    var w = ByteWriter()
    w.raw(CGPSession.signature)
    w.raw(bind)
    w.varlen(1 + ica1.count); w.u8(0x0a); w.raw(ica1)
    w.varlen(2 + ica2.count); w.u8(0x0b); w.u8(0x03); w.raw(ica2)
    let c2s = [UInt8](w.data)
    let s2c: [UInt8] = [UInt8](CGPSession.signature) + [0x02, 0x0a, 0x99]
    let base: UInt64 = 1_000_000
    let isn: UInt32 = 7000
    var frames: [(UInt64, [UInt8])] = [
        (base, frame(from: client, to: server, seq: isn, flags: 0x02, id: 1, payload: [])),
        (base + 1000, frame(from: server, to: client, seq: 90, flags: 0x12, id: 2, payload: [])),
        // The client stream in two segments, the second sent first; the first one logged twice (pktmon copy).
        (base + 2000, frame(from: client, to: server, seq: isn + 1 + 20, id: 4, payload: Array(c2s[20...]))),
        (base + 3000, frame(from: client, to: server, seq: isn + 1, id: 3, payload: Array(c2s[..<20]))),
        (base + 3001, frame(from: client, to: server, seq: isn + 1, id: 3, payload: Array(c2s[..<20]))),
        (base + 4000, frame(from: server, to: client, seq: 91, id: 5, payload: s2c)),
        // EDT-like UDP both ways, and unrelated traffic.
        (base + 5000, frame(from: (client.0, 50001), to: (server.0, 1494), tcp: false, id: 6, payload: [0xAA, 0x01])),
        (base + 6000, frame(from: (server.0, 1494), to: (client.0, 50001), tcp: false, id: 7, payload: [0xBB])),
        (base + 7000, frame(from: client, to: (server.0, 443), id: 8, payload: [1, 2, 3])),
    ]
    // A second connection: raw ICA on 1494.
    frames.append((base + 8000, frame(from: (client.0, 50002), to: (server.0, 1494), seq: 1, id: 9, payload: ica1)))
    let capture = ICACapture(frames: try CaptureFile.read(pcapng(frames)))
    #expect(capture.frames == 10)
    #expect(capture.skipped == 1)
    #expect(capture.duplicateFrames == 1)
    #expect(capture.connections.count == 2)
    let cgp = capture.connections[0]
    #expect(cgp.client == CaptureEndpoint("192.0.2.10", 50000))
    #expect(cgp.c2s.sawSyn)
    #expect(cgp.c2s.bytes == c2s)
    let c = ICAStreamExtract(cgp.c2s.bytes), s = ICAStreamExtract(cgp.s2c.bytes)
    #expect(c.isCGP && s.isCGP)
    #expect(c.ica == ica1 + ica2)
    #expect(c.commands == [0x01: 1, 0x0a: 1, 0x0b: 1])
    #expect(c.log.count == 1 && c.log[0].hasPrefix("cmd 0x01 len 3"))
    #expect(c.leftover == 0)
    #expect(s.ica == [0x99])
    // ICA offset 6 (end of the detect bytes) came with the first CGP data packet, which ends at TCP offset 7+4+8.
    #expect(c.tcpOffset(forICAEnd: 6) == 19)
    #expect(c.tcpOffset(forICAEnd: 206) == c2s.count)
    let raw = capture.connections[1]
    #expect(raw.server.port == 1494)
    let r = ICAStreamExtract(raw.c2s.bytes)
    #expect(!r.isCGP && r.ica == ica1)
    #expect(capture.datagrams.count == 2)
    #expect(capture.datagrams[0].fromClient && capture.datagrams[0].payload == [0xAA, 0x01])
    #expect(!capture.datagrams[1].fromClient && capture.datagrams[1].server.port == 1494)
}

@Test func parsesIPv6UDP() throws {
    let src: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
    let dst: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [2]
    let udp = be16(40000) + be16(2598) + be16(10) + [0, 0] + [0x01, 0x02]
    let ip: [UInt8] = [0x60, 0, 0, 0] + be16(UInt16(udp.count)) + [17, 64] + src + dst
    let eth: [UInt8] = [2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 0x86, 0xDD]
    let p = try #require(CapturedPacket.parse(CapturedFrame(time: 0, linkType: CaptureLinkType.ethernet, bytes: eth + ip + udp)))
    #expect(p.transport == .udp)
    #expect(p.source.address == "2001:db8:0:0:0:0:0:1")
    #expect(p.destination.port == 2598)
    #expect(p.payload == [0x01, 0x02])
}

@Test func reassemblesIPv4FragmentsOfUDP() throws {
    // One 1400-byte UDP datagram in two fragments (1280-byte path), the second logged twice and before the first.
    let payload = (0..<1400).map { UInt8($0 & 0xFF) }
    let udp = be16(50001) + be16(2598) + be16(UInt16(8 + payload.count)) + [0, 0] + payload
    func fragment(_ part: ArraySlice<UInt8>, offset: Int, more: Bool) -> [UInt8] {
        let field = UInt16(offset / 8) | (more ? 0x2000 : 0)
        let ip: [UInt8] = [0x45, 0] + be16(UInt16(20 + part.count)) + be16(77) + be16(field) + [64, 17, 0, 0] + client.0 + server.0
        return [2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 0x08, 0x00] + ip + part
    }
    let a = fragment(udp[0..<1256], offset: 0, more: true), b = fragment(udp[1256...], offset: 1256, more: false)
    let capture = ICACapture(frames: try CaptureFile.read(pcapng([(10, b), (20, a), (30, b)])))
    #expect(capture.reassembledDatagrams == 1)
    #expect(capture.datagrams.count == 1)
    #expect(capture.datagrams.first?.payload == payload)
    #expect(capture.datagrams.first?.fromClient == true)
    // Only the first fragment: kept cut short, with the declared length.
    let lone = ICACapture(frames: try CaptureFile.read(pcapng([(20, a)])))
    #expect(lone.incompleteFragments == 1)
    #expect(lone.datagrams.first?.payload == Array(payload.prefix(1248)))
    #expect(lone.datagrams.first?.declaredLength == 1400)
}
