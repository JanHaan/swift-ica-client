import Testing
import Foundation
@testable import ICAKit

// Synthetic messages built from the documented layout (docs/76 §7.17); no recorded bytes.
private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
private func msg(_ cmd: UInt8, _ seq: UInt32, _ body: [UInt8]) -> [UInt8] { [cmd] + u32(seq) + u16(UInt16(7 + body.count)) + body }

/// An engine with its output collected as parsed messages.
private final class Harness {
    let engine = GDTEngine()
    var out: [GDTMessage] = []
    var raw: [[UInt8]] = []
    var events: [GDTFileEvent] = []
    init() {
        engine.output = { [unowned self] in
            if case .channel(let d) = $0 { raw.append([UInt8](d)); out.append(GDTMessage([UInt8](d))!) }
        }
        engine.onEvent = { [unowned self] in if case .file(let e) = $0 { events.append(e) } }
    }
    func host(_ bytes: [UInt8]) { engine.receive(Data(bytes)) }
    func take() -> [GDTMessage] { defer { out = [] }; return out }
}

private let entries = [
    ClipboardFileEntry(name: "one.txt", size: 5, writeTime: Date(timeIntervalSince1970: 1_700_000_000)),
    ClipboardFileEntry(name: "two.bin", size: 3000, writeTime: Date(timeIntervalSince1970: 1_700_000_100)),
]
private let contents = [Data("Hello".utf8), Data((0..<3000).map { UInt8($0 % 251) })]

@Suite struct GDTWireLayoutTests {
    @Test func headerAndSizes() throws {
        let g = GDTWire.getData(seq: 5, GDTGetData(dataObj: 0x1122_3344_5566_7788, ctxFormat: 2, systemFormat: 0xC0AA))
        #expect(g.count == 31)
        #expect(Array(g.prefix(7)) == [0x14, 5, 0, 0, 0, 31, 0])
        #expect(Array(g[15...]) == u32(2) + u32(0xC0AA) + u32(0xFFFF_FFFF) + u32(1))
        let o = GDTWire.openStream(seq: 7, index: 0, indexOffset: GDTWire.openStreamIndexOffset)
        #expect(o.count == 60 && o[0] == 0x04 && Array(o[7...10]) == u32(0x34) && o[11...].allSatisfy { $0 == 0 })
        let o1 = GDTWire.openStream(seq: 9, index: 1, indexOffset: GDTWire.openStreamIndexOffset)
        #expect(Array(o1[7...10]) == u32(0x34) && o1[11..<56].allSatisfy { $0 == 0 } && Array(o1[56...]) == u32(1))
        #expect(GDTWire.openStreamReply(seq: 7, status: 0, stream: 9).count == 19)
        #expect(GDTWire.seek(seq: 1, stream: 9, move: 0, origin: 1).count == 24)
        #expect(GDTWire.seekReply(seq: 1, stream: 9, status: 0, position: 0).count == 27)
        #expect(GDTWire.read(seq: 1, stream: 9, count: 5).count == 19)
        #expect(GDTWire.release(seq: 1, stream: 9).count == 15)
        #expect(GDTWire.release(seq: 1, stream: 9, reply: true)[0] == 0x07)
        let r = GDTWire.readReply(seq: 3, stream: 9, data: Array("abc".utf8))
        #expect(r.map(\.count) == [19, 20, 19] && r.map { $0[0] } == [0x0D, 0x0E, 0x0F])
        #expect(Array(r[1][15...]) == u16(3) + Array("abc".utf8))
        #expect(GDTWire.readReply(seq: 3, stream: 9, data: []).map { $0[0] } == [0x0D, 0x0F])
        let message = try #require(GDTMessage(g))
        #expect(message.command == 0x14 && message.seq == 5 && message.bytes == g)
        #expect(GDTMessage(Array(g.dropLast())) == nil)
    }

    @Test func getDataReplyChunksAndRoundTrip() {
        let data = (0..<3000).map { UInt8($0 & 0xFF) }
        let parts = GDTWire.getDataReply(seq: 12, dataObj: 0, data: data, maxMessage: 1400)
        #expect(parts.first?[0] == 0x15 && parts.last?[0] == 0x17 && parts.allSatisfy { $0.count <= 1400 })
        #expect(parts.first?.count == 19 && parts.last?.count == 23)
        #expect(Array(parts.last![15...]) == u32(0) + u32(1))
        let joined = parts.dropFirst().dropLast().flatMap { Array($0[17...]) }
        #expect(joined == data)
    }

    @Test func openStreamIndexFinding() {
        var body = [UInt8](repeating: 0, count: 53)
        body[0] = 0x34
        #expect(GDTWire.openStreamIndex(body, indexOffset: nil)! == (0, nil))
        body[20] = 1
        #expect(GDTWire.openStreamIndex(body, indexOffset: nil)! == (1, 20))
        #expect(GDTWire.openStreamIndex(body, indexOffset: 20)! == (1, 20))
        body[21] = 0xFF; body[22] = 0xFF
        #expect(GDTWire.openStreamIndex(body, indexOffset: nil) == nil)
    }

    @Test func readerSplitsAndJoins() {
        var reader = GDTMessageReader()
        let a = msg(0x0C, 2, u64(9) + u32(5)), b = msg(0x06, 4, u64(9))
        #expect(reader.push(a + b).map(\.command) == [0x0C, 0x06])
        #expect(reader.push(Array(a.prefix(10))).isEmpty)
        #expect(reader.push(Array(a.dropFirst(10))).map(\.seq) == [2])
        #expect(reader.push([0x00, 0x01]).isEmpty)
        #expect(reader.push(b).map(\.command) == [0x06])   // the stray 2 bytes are dropped
        #expect(reader.dropped == 2)
    }
}

@Suite struct GDTMacToSessionTests {
    @Test func servesDescriptorAndContents() throws {
        let h = Harness()
        h.engine.files.offer(GDTFileSource(entries: entries, contents: contents))
        // GetData FileGroupDescriptorW: dataObj 0, ctxFormat 2, systemFormat 0, lindex -1, tymed 1.
        h.host(msg(0x14, 12, u64(0) + u32(2) + u32(0) + u32(0xFFFF_FFFF) + u32(1)))
        let reply = h.take()
        #expect(reply.map(\.command) == [0x15, 0x16, 0x17] && reply.allSatisfy { $0.seq == 12 })
        let expected = try [UInt8](ClipboardFileGroup.build(entries))
        #expect(reply[0].body == u64(0) + u32(UInt32(expected.count)))
        #expect(reply[1].body == u64(0) + u16(UInt16(expected.count)) + expected)
        #expect(reply[2].body == u64(0) + u32(0) + u32(1))
        #expect(try ClipboardFileGroup.parse(Data(Array(reply[1].body[10...]))).map(\.name) == ["one.txt", "two.bin"])

        // OpenStream, all zero after the marker = file 0.
        h.host(msg(0x04, 14, u32(0x34) + [UInt8](repeating: 0, count: 49)))
        let open = h.take()
        #expect(open.count == 1 && open[0].command == 0x05 && open[0].seq == 14 && Array(open[0].body.prefix(4)) == u32(0))
        let stream = LEBytes.u64(open[0].body, 4)
        #expect(stream != 0)
        // Seek CUR 0 and SET 0, as Explorer does first.
        h.host(msg(0x0A, 16, u64(stream) + u64(0) + [1]))
        h.host(msg(0x0A, 18, u64(stream) + u64(0) + [0]))
        #expect(h.take().map { $0.bytes } == [GDTWire.seekReply(seq: 16, stream: stream, status: 0, position: 0),
                                              GDTWire.seekReply(seq: 18, stream: stream, status: 0, position: 0)])
        // Read 5 → begin 5, data, end 0; again → begin 0, end 0 (no data message).
        h.host(msg(0x0C, 20, u64(stream) + u32(5)))
        h.host(msg(0x0C, 22, u64(stream) + u32(5)))
        let reads = h.take()
        #expect(reads.map(\.command) == [0x0D, 0x0E, 0x0F, 0x0D, 0x0F])
        #expect(reads[1].body == u64(stream) + u16(5) + Array("Hello".utf8))
        #expect(reads[2].body == u64(stream) + u32(0) && reads[3].body == u64(stream) + u32(0))
        #expect(h.engine.files.servedFiles == [0])
        // Release → the same body back as 0x07.
        h.host(msg(0x06, 24, u64(stream)))
        #expect(h.take().map(\.bytes) == [msg(0x07, 24, u64(stream))])
    }

    @Test func secondFileByIndexInChunks() {
        let h = Harness()
        h.engine.files.offer(GDTFileSource(entries: entries, contents: contents))
        // The file index is the body's last u32 (offset 49).
        h.host(msg(0x04, 2, u32(0x34) + [UInt8](repeating: 0, count: 45) + u32(1)))
        let stream = LEBytes.u64(h.take()[0].body, 4)
        #expect(h.events.contains { if case .hostOpenStream(_, 1, 49, _, _) = $0 { return true }; return false })
        h.host(msg(0x0C, 4, u64(stream) + u32(65536)))
        let reads = h.take()
        #expect(reads.first?.command == 0x0D && reads.last?.command == 0x0F && reads.allSatisfy { $0.bytes.count <= 1400 })
        #expect(LEBytes.u32(reads[0].body, 8) == 3000)
        let data = reads.filter { $0.command == 0x0E }.flatMap { Array($0.body[10...]) }
        #expect(Data(data) == contents[1])
        #expect(h.engine.files.servedFiles == [1])
        // Seek to the end: position = size.
        h.host(msg(0x0A, 6, u64(stream) + u64(0) + [2]))
        #expect(LEBytes.u64(h.take()[0].body, 12) == 3000)
    }

    @Test func refusesWithoutFilesAndForUnknownStreams() {
        let h = Harness()
        h.host(msg(0x14, 2, u64(0) + u32(2) + u32(0) + u32(0xFFFF_FFFF) + u32(1)))
        let r = h.take()
        #expect(r.map(\.command) == [0x15, 0x17] && LEBytes.u32(r[1].body, 8) == GDTWire.statusFormat)
        h.host(msg(0x0C, 4, u64(77) + u32(5)))
        let read = h.take()
        #expect(read.map(\.command) == [0x0D, 0x0F] && LEBytes.u32(read[1].body, 8) == GDTWire.statusInvalid)
        // Off: nothing answered.
        var c = GDTEngine.Config()
        c.fileTransfer = false
        let off = GDTEngine(config: c)
        var out: [Data] = []
        off.output = { if case .channel(let d) = $0 { out.append(d) } }
        off.receive(Data(msg(0x14, 2, u64(0) + u32(2) + u32(0) + u32(0xFFFF_FFFF) + u32(1))))
        #expect(out.isEmpty)
        #expect(GDTEngine.Config.fromEnvironment(["ICA_GDT": "1", "ICA_GDT_FILES": "0"])?.fileTransfer == false)
    }
}

@Suite struct GDTSessionToMacTests {
    @Test func fetchesDescriptorThenEachFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdt-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        // The opening reply takes seq 1, so our first request is 3.
        let tail: [UInt8] = [0x00, 0x00, 0x00, 0x1D, 0x00, 0x07] + (1...7).flatMap { [UInt8($0), 0, 0] as [UInt8] }
        h.host([0x01, 0x02] + tail)
        #expect(h.raw.first?.prefix(2) == [0x02, 0x01])
        h.out = []
        h.engine.files.fetch(systemFormat: 0xC0AA, into: dir)
        let get = h.take()
        #expect(get.count == 1 && get[0].command == 0x14 && get[0].seq == 3)
        let g = try #require(GDTGetData(body: get[0].body))
        #expect(g.ctxFormat == 2 && g.systemFormat == 0xC0AA && g.lindex == -1 && g.tymed == 1 && g.dataObj != 0)

        // The host's descriptor in two data chunks.
        let fgd = try [UInt8](ClipboardFileGroup.build(entries))
        h.host(msg(0x15, 3, u64(g.dataObj) + u32(UInt32(fgd.count))))
        h.host(msg(0x16, 3, u64(g.dataObj) + u16(600) + Array(fgd[..<600])))
        h.host(msg(0x16, 3, u64(g.dataObj) + u16(UInt16(fgd.count - 600)) + Array(fgd[600...])))
        h.host(msg(0x17, 3, u64(g.dataObj) + u32(0) + u32(1)))
        var sent = h.take()
        #expect(sent.count == 1 && sent[0].command == 0x04 && sent[0].seq == 5 && sent[0].bytes.count == 60)

        func serve(_ index: Int, openSeq: UInt32, stream: UInt64) {
            h.host(msg(0x05, openSeq, u32(0) + u64(stream)))
            let data = [UInt8](contents[index])
            var offset = 0
            while true {
                let read = h.take()
                #expect(read.count == 1 && read.first?.command == 0x0C && read.first?.handle == stream)
                guard let r = read.first, r.command == 0x0C else { return }
                let n = min(Int(LEBytes.u32(r.body, 8)), data.count - offset)
                h.host(msg(0x0D, r.seq, u64(stream) + u32(UInt32(n))))
                if n > 0 { h.host(msg(0x0E, r.seq, u64(stream) + u16(UInt16(n)) + Array(data[offset..<offset + n]))) }
                h.host(msg(0x0F, r.seq, u64(stream) + u32(n == 0 ? 1 : 0)))
                offset += n
                if n == 0 { break }
            }
            let release = h.take()
            #expect(release.count == 1 && release.first?.command == 0x06 && release.first?.handle == stream)
            if let r = release.first { h.host(msg(0x07, r.seq, u64(stream))) }
        }
        h.engine.files.readSize = 1024
        serve(0, openSeq: sent[0].seq, stream: 0x0000_0000_0500_0010)
        sent = h.take()
        #expect(sent.count == 1 && sent.first?.command == 0x04 && sent.first.map { LEBytes.u32($0.body, 49) } == 1)
        serve(1, openSeq: sent.first?.seq ?? 0, stream: 0x0000_0000_0500_0020)
        #expect(h.take().isEmpty)
        #expect(h.events.contains { if case .fetchDone(2) = $0 { return true }; return false })
        #expect(try Data(contentsOf: dir.appendingPathComponent("one.txt")) == contents[0])
        #expect(try Data(contentsOf: dir.appendingPathComponent("two.bin")) == contents[1])
        #expect(!h.engine.files.isFetching)
    }

    @Test func failsOnABadDescriptorAndIgnoresStrangers() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdt-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        h.engine.files.fetch(systemFormat: 0xC0AA, into: dir)
        let seq = h.take()[0].seq
        h.host(msg(0x0D, seq + 2, u64(1) + u32(0)))   // not our seq
        #expect(h.events.contains { if case .unexpected = $0 { return true }; return false })
        h.host(msg(0x15, seq, u64(0) + u32(3)))
        h.host(msg(0x16, seq, u64(0) + u16(3) + [1, 2, 3]))
        h.host(msg(0x17, seq, u64(0) + u32(0) + u32(1)))
        #expect(h.events.contains { if case .fetchFailed = $0 { return true }; return false })
        #expect(h.take().isEmpty && !h.engine.files.isFetching)
    }

    @Test func localNames() {
        #expect(GDTFileTransfer.localName("dir\\a.txt", index: 0) == "a.txt")
        #expect(GDTFileTransfer.localName("..", index: 3) == "file-3")
        #expect(GDTFileTransfer.localName("a:b", index: 0) == "a_b")
    }
}
