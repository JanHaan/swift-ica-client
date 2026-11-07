import Testing
import Foundation
import CoreGraphics
@testable import ICAKit

private func hex(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }
private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

/// Inline engine; everything it emits in order, with ACKs, replies and events kept apart.
private final class PrinterHarness {
    enum Out: Equatable {
        case reply([UInt8])
        case ack(UInt16)
        case event(String)
        case job(Int, Int)
    }

    let engine: PrinterEngine
    var outputs: [Out] = []
    var jobs: [PrintJob] = []
    var refused: [(Int, String)] = []

    init(config: PrinterEngine.Config = PrinterEngine.Config()) {
        engine = PrinterEngine(config: config)
        engine.output = { [unowned self] out in
            switch out {
            case .channel(let d): outputs.append(.reply([UInt8](d)))
            case let .wdPacket(type, body):
                let b = [UInt8](body)
                #expect(type == 0x32 && b.count == 3 && b[0] == 4)
                outputs.append(.ack(UInt16(b[1]) | UInt16(b[2]) << 8))
            }
        }
        engine.onEvent = { [unowned self] event in
            switch event {
            case .job(let job):
                jobs.append(job)
                outputs.append(.job(job.id, job.data.count))
            case let .jobRefused(id, reason):
                refused.append((id, reason))
            default: break
            }
        }
    }

    @discardableResult
    func feed(_ bytes: [UInt8]) -> [Out] {
        let before = outputs.count
        engine.receive(Data(bytes))
        return Array(outputs[before...])
    }

    @discardableResult
    func feed(_ request: PrinterRequest) -> [Out] { feed([UInt8](request.encode())) }

    var replies: [[UInt8]] { outputs.compactMap { if case .reply(let r) = $0 { return r } else { return nil } } }
    var acks: [UInt16] { outputs.compactMap { if case .ack(let a) = $0 { return a } else { return nil } } }
}

private let printerName = ascii("Citrix PDF Printer") + [0]

/// A PDF made with CoreGraphics: `pages` pages, an optional title, optional user password.
private func makePDF(pages: Int, title: String? = nil, password: String? = nil) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    var info: [CFString: Any] = [:]
    if let title { info[kCGPDFContextTitle] = title }
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password + "-owner"
    }
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, info as CFDictionary)!
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 100, height: 20))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@Suite struct PrintingModuleTests {
    @Test func moduleGolden56Bytes() {
        let date = Date(timeIntervalSince1970: 0)
        let m = WDModules.printer(date: date)
        let dosStamp = Array(m[28...31])
        // docs/97 §1.2, PDF-mode column (byte count and "modules remaining" are patched by initResponsePackets).
        let expected = hex("38 00 00 03 04 07") + [UInt8](repeating: 0, count: 13) + hex("49 43 41 00 00 00 00 00 00") + dosStamp
            + hex("00 00 00 00") + hex("04 00 00 00") + hex("00 01 00 00 24 F4 06 10") + hex("00 00 00 00 00 00 00 80")
        #expect(m.count == 56)
        #expect(expected.count == 56)
        let packet = WDModules.initResponsePackets([m])[0]
        #expect(Array(packet.prefix(3)) == hex("01 38 00"))
        #expect(packet.dropFirst(3).elementsEqual(expected))
        // Without cap 0x21 the channel field would be a mask; we always pass the number.
        #expect(Array(WDModules.printer(channel: 4, date: date)[36...39]) == hex("04 00 00 00"))
    }

    @Test func moduleInInitResponseAndBindTable() throws {
        let wd = WinstationDriver(configuration: {
            var c = WinstationDriver.Configuration()
            c.logon.initialProgram = "#Notepad Demo"
            return c
        }())
        wd.register(ThinwireEngine())
        wd.register(ClipboardEngine(config: ClipboardEngine.Config()))
        let engine = PrinterEngine()
        #expect(wd.register(engine) == 4)
        let (modules, names) = try wd.buildModules()
        let index = try #require(names.firstIndex(of: "CTXCPM "))
        #expect(index > names.firstIndex(of: "CTXCLIP")!)
        let module = modules[index]
        #expect(module.count == 56)
        #expect(module[3] == 3 && module[4] == 4 && module[5] == 7 && module[41] == 1)
        #expect(Array(module[44...47]) == hex("24 F4 06 10") && Array(module[54...55]) == hex("00 80"))
        // WD module bind table: "CTXCPM " NUL 04 00 (docs/97 §1.3).
        let bind = hex("43 54 58 43 50 4D 20 00 04 00")
        #expect(modules[0].indices.contains { i in i + bind.count <= modules[0].count && Array(modules[0][i..<i + bind.count]) == bind })
    }
}

@Suite struct PrintingWireTests {
    private let all: [PrinterRequest] = [
        PrinterRequest(tag: 1, .connect2(a: 0x1234, b: 0x5678, version: 4, flags: 0xABCD)),
        PrinterRequest(tag: 2, .queryMetafile),
        PrinterRequest(tag: 3, .setMetafile(size: 37, entries: [PrinterMetafileEntry(first: Data(ascii("PDF\0")),
                                                                                  second: Data(ascii("Citrix PDF Universal Printer\0")))])),
        PrinterRequest(tag: 4, .enumPrinters(index: 0, maxSize: 4096)),
        PrinterRequest(tag: 5, .open(flags: 0x11, name: Data(printerName))),
        PrinterRequest(tag: 6, .getInfo(context: 1, flags: 0x0A, size: 0x100)),
        PrinterRequest(tag: 7, .write(context: 1, data: Data(repeating: 0x41, count: 300))),
        PrinterRequest(tag: 8, .close(context: 1)),
    ]

    @Test func requestLayouts() {
        #expect([UInt8](all[0].encode()) == hex("48 01 34 12 78 56 04 00 CD AB"))
        #expect([UInt8](all[1].encode()) == hex("4C 02"))
        #expect([UInt8](all[2].encode()) == hex("4D 03 01 00 25 00 04 1D 00 01") + ascii("PDF\0Citrix PDF Universal Printer\0"))
        #expect([UInt8](all[3].encode()) == hex("40 04 00 00 00 10"))
        #expect([UInt8](all[4].encode()) == hex("41 05 13 11") + printerName)
        #expect([UInt8](all[5].encode()) == hex("45 06 01 00 0A 00 00 00 00 01"))
        #expect([UInt8](all[6].encode()).prefix(6).elementsEqual(hex("44 07 01 00 2C 01")))
        #expect([UInt8](all[7].encode()) == hex("42 08 01 00"))
    }

    @Test func parseRoundTripWholeAndByteByByte() {
        let stream = all.flatMap { [UInt8]($0.encode()) }
        var whole = PrinterStreamParser()
        let items = whole.feed(Data(stream))
        #expect(items.map(\.request) == all)
        #expect(items.map(\.length) == all.map { $0.encode().count })
        #expect(whole.bufferedCount == 0)
        var split = PrinterStreamParser()
        var got: [PrinterStreamParser.Item] = []
        for b in stream { got += split.feed(Data([b])) }
        #expect(got == items)
        // Odd split points: 3 and 5 bytes.
        for size in [3, 5, 4101] {
            var p = PrinterStreamParser()
            var g: [PrinterStreamParser.Item] = []
            var i = 0
            while i < stream.count { g += p.feed(Data(stream[i..<min(stream.count, i + size)])); i += size }
            #expect(g == items)
        }
    }

    @Test func unknownCommandConsumesHeaderOnly() {
        var p = PrinterStreamParser()
        #expect(p.feed(Data([0x47])).isEmpty)
        let items = p.feed(Data(hex("09 42 0A 01 00")))
        #expect(items.map(\.request) == [PrinterRequest(tag: 9, .unknown(0x47)), PrinterRequest(tag: 10, .close(context: 1))])
        #expect(items.map(\.length) == [2, 4])
    }

    @Test func replyLayouts() {
        let ascii45 = PrinterReply.queryMetafile(tag: 2, encoding: .ascii)
        #expect([UInt8](ascii45) == hex("CC 02 00 00 01 00 25 00 04 1D 00 01") + ascii("PDF\0Citrix PDF Universal Printer\0"))
        #expect(ascii45.count == 45)
        let utf78 = [UInt8](PrinterReply.queryMetafile(tag: 2, encoding: .utf16))
        #expect(utf78.count == 78)
        #expect(Array(utf78.prefix(12)) == hex("CC 02 00 00 01 00 46 00 08 3A 00 01"))
        #expect(Array(utf78[12..<20]) == hex("50 00 44 00 46 00 00 00"))
        #expect(Array(utf78[76...]) == hex("00 00"))
        #expect([UInt8](PrinterReply.setMetafile(tag: 3)) == hex("CD 03 00 00"))
        #expect([UInt8](PrinterReply.enumEmpty(tag: 4)) == hex("C0 04 08 12 00 00 00 00"))
        #expect([UInt8](PrinterReply.open(tag: 5, result: 0, context: 1)) == hex("C1 05 00 00 01 00"))
        #expect([UInt8](PrinterReply.open(tag: 5, result: PrinterWire.Result.accessDenied, context: 0xFFFF)) == hex("C1 05 07 0C FF FF"))
        #expect([UInt8](PrinterReply.write(tag: 6, result: 0, size: 4096)) == hex("C4 06 00 00 00 10"))
        #expect([UInt8](PrinterReply.write(tag: 6, result: PrinterWire.Result.writeUnknownContext, size: 0)) == hex("C4 06 0E FF 00 00"))
        #expect([UInt8](PrinterReply.close(tag: 7, result: 0)) == hex("C2 07 00 00"))
        #expect([UInt8](PrinterReply.close(tag: 7, result: PrinterWire.Result.invalidHandle)) == hex("C2 07 07 06"))
        let info = [UInt8](PrinterReply.getInfo(tag: 8, result: 0, devmode: PrinterDevmode()))
        #expect(info.count == 65)
        #expect(Array(info.prefix(14)) == hex("C5 08 00 00 00 00 00 00 0A 00 00 00 33 00"))
        // Devmode (§3.6): mask 0x9F03, portrait [P], A4, 0, 0, 0, copies 1, source 7, quality 3, mono, simplex, 0, 0, 0.
        #expect(Array(info[14..<44]) == hex("03 9F 00 00 01 00 09 00 00 00 00 00 00 00 01 00 07 00 03 00 01 00 01 00 00 00 00 00 00 00"))
        #expect(info[44...].allSatisfy { $0 == 0 })
    }

    @Test func ackPackets() {
        func values(_ length: Int) -> [[UInt8]] {
            PrinterReply.acks(channel: 4, length: length).compactMap { out in
                guard case let .wdPacket(type, body) = out, type == 0x32 else { return nil }
                return [UInt8](body)
            }
        }
        #expect(values(4102) == [hex("04 06 10")])
        #expect(values(65535) == [hex("04 FF FF")])
        // A WRITE of 65535 data bytes is 65541 bytes long: split, adding up to the length.
        #expect(values(65541) == [hex("04 FF FF"), hex("04 06 00")])
        #expect(values(2 * 65535 + 1) == [hex("04 FF FF"), hex("04 FF FF"), hex("04 01 00")])
    }

    @Test func encodingDecode() {
        #expect(PrinterWire.Encoding.utf16.decode(Data(hex("43 00 69 00 00 00"))) == "Ci\0")
        #expect(PrinterWire.Encoding.ascii.decode(Data(hex("41 E4 00"))) == "Aä\0")
        #expect(PrinterEngine.dropTerminator("Citrix PDF Printer\0") == "Citrix PDF Printer")
        #expect(PrinterEngine.dropTerminator("Name \0\0") == "Name ")
    }
}

@Suite struct PrintingEngineTests {
    /// The worked exchange of docs/97 §4 (ASCII), one command at a time.
    @Test func workedExchange() {
        let h = PrinterHarness()
        #expect(h.feed(hex("48 01 00 00 00 00 04 00 00 00")) == [.ack(10)])
        #expect(h.engine.encoding == .ascii)
        #expect(h.feed(hex("4C 02")) == [.reply(hex("CC 02 00 00 01 00 25 00 04 1D 00 01") + ascii("PDF\0Citrix PDF Universal Printer\0")),
                                         .ack(2)])
        let set = hex("4D 03 01 00 25 00 04 1D 00 01") + ascii("PDF\0Citrix PDF Universal Printer\0")
        #expect(h.feed(set) == [.reply(hex("CD 03 00 00")), .ack(UInt16(set.count))])
        #expect(h.feed(hex("40 04 00 00 00 10")) == [.reply(hex("C0 04 08 12 00 00 00 00")), .ack(6)])
        let open = hex("41 05 13 11") + printerName
        #expect(h.feed(open) == [.reply(hex("C1 05 00 00 01 00")), .ack(UInt16(open.count))])
        let pdf = [UInt8](makePDF(pages: 1))
        var expected = Data()
        var tag: UInt8 = 6
        var offset = 0
        while offset < pdf.count {
            let chunk = Array(pdf[offset..<min(pdf.count, offset + 4096)])
            let out = h.feed(PrinterRequest(tag: tag, .write(context: 1, data: Data(chunk))))
            #expect(out == [.reply(hex("C4") + [tag, 0, 0, UInt8(chunk.count & 0xff), UInt8(chunk.count >> 8)]), .ack(UInt16(6 + chunk.count))])
            expected.append(contentsOf: chunk)
            offset += 4096
            tag &+= 1
        }
        // CLOSE: reply first, then the job, then the ACK of the CLOSE command.
        let out = h.feed([0x42, tag, 0x01, 0x00])
        #expect(out == [.reply([0xC2, tag, 0, 0]), .job(1, pdf.count), .ack(4)])
        #expect(h.jobs.count == 1 && h.jobs[0].data == expected && h.jobs[0].printerName == "Citrix PDF Printer")
        #expect(h.engine.openContexts.isEmpty)
        if case .success(let info) = PrintDocument.inspect(h.jobs[0].data) { #expect(info.pageCount == 1) } else { Issue.record("job is not a PDF") }
    }

    @Test func utf16AfterConnectVersion5() {
        let h = PrinterHarness()
        h.feed(hex("48 01 00 00 00 00 05 00 00 00"))
        #expect(h.engine.encoding == .utf16)
        let r = h.feed(hex("4C 02"))
        guard case .reply(let bytes) = r.first else { Issue.record("no reply"); return }
        #expect(bytes.count == 78)
        let name = PrinterWire.Encoding.utf16.encode("Citrix PDF Printer\0")
        let out = h.feed([0x41, 0x03, UInt8(name.count), 0x11] + name)
        #expect(out.first == .reply(hex("C1 03 00 00 01 00")))
        h.feed(PrinterRequest(tag: 4, .write(context: 1, data: Data([1, 2, 3]))))
        h.feed(hex("42 05 01 00"))
        #expect(h.jobs.first?.printerName == "Citrix PDF Printer")
    }

    @Test func splitAndMergedWritesGiveIdenticalOutput() {
        let pdf = makePDF(pages: 3)
        var stream = hex("48 01 00 00 00 00 04 00 00 00 4C 02 40 03 00 00 00 10") + hex("41 04 13 11") + printerName
        var tag: UInt8 = 5
        var offset = 0
        let bytes = [UInt8](pdf)
        while offset < bytes.count {
            stream += [UInt8](PrinterRequest(tag: tag, .write(context: 1, data: Data(bytes[offset..<min(bytes.count, offset + 4096)]))).encode())
            offset += 4096
            tag &+= 1
        }
        stream += [0x42, tag, 0x01, 0x00]
        let merged = PrinterHarness()
        merged.feed(stream)
        for size in [1, 7, 1000, 5000] {
            let split = PrinterHarness()
            var i = 0
            while i < stream.count { split.feed(Array(stream[i..<min(stream.count, i + size)])); i += size }
            #expect(split.outputs == merged.outputs)
        }
        // One ACK per command, the ACK values add up to every byte received.
        #expect(merged.acks.map(Int.init).reduce(0, +) == stream.count)
        #expect(merged.engine.bytesAcknowledged == stream.count)
        #expect(merged.jobs.first?.data == pdf)
    }

    @Test func flowControlAcksOnlyCompleteCommands() {
        let h = PrinterHarness()
        h.feed(hex("41 01 13 11") + printerName)
        let write = [UInt8](PrinterRequest(tag: 2, .write(context: 1, data: Data(repeating: 7, count: 4096))).encode())
        #expect(write.count == 4102)
        #expect(h.feed(Array(write[..<1])).isEmpty)
        #expect(h.feed(Array(write[1..<4000])).isEmpty)
        #expect(h.feed(Array(write[4000...])) == [.reply(hex("C4 02 00 00 00 10")), .ack(4102)])
        // Untagged WRITE: no reply, still an ACK.
        #expect(h.feed(PrinterRequest(tag: 0, .write(context: 1, data: Data([1])))) == [.ack(7)])
        // Unknown command: ACK 2, the stream continues.
        #expect(h.feed(hex("47 09 42 0A 01 00")) == [.ack(2), .reply(hex("C2 0A 00 00")), .job(1, 4097), .ack(4)])
        #expect(h.engine.commandCounts["UNKNOWN_47"] == 1)
    }

    @Test func openRefusedWithoutFlags() {
        let h = PrinterHarness()
        for flags: UInt8 in [0x00, 0x01, 0x10] {
            #expect(h.feed([0x41, 0x01, UInt8(printerName.count), flags] + printerName).first == .reply(hex("C1 01 07 0C FF FF")))
        }
        #expect(h.engine.openContexts.isEmpty)
        #expect(h.feed([0x41, 0x02, UInt8(printerName.count), 0x13] + printerName).first == .reply(hex("C1 02 00 00 01 00")))
    }

    @Test func writeToUnknownContextSkipsItsData() {
        let h = PrinterHarness()
        // Quirk §3.4: the data of a WRITE to an unknown context is consumed, so the next command parses.
        let out = h.feed([UInt8](PrinterRequest(tag: 3, .write(context: 5, data: Data(hex("42 04 01 00 42 04")))).encode()) + hex("40 05 00 00 00 10"))
        #expect(out == [.reply(hex("C4 03 0E FF 00 00")), .ack(12), .reply(hex("C0 05 08 12 00 00 00 00")), .ack(6)])
        // Untagged: no reply, ACK only.
        #expect(h.feed(PrinterRequest(tag: 0, .write(context: 9, data: Data([1, 2])))) == [.ack(8)])
        #expect(h.jobs.isEmpty && h.engine.openContexts.isEmpty)
    }

    @Test func writeToPDFContextWithoutOpenIsAccepted() {
        let h = PrinterHarness()
        #expect(h.feed(PrinterRequest(tag: 1, .write(context: 1, data: Data([1, 2, 3])))).first == .reply(hex("C4 01 00 00 03 00")))
        h.feed(hex("42 02 01 00"))
        #expect(h.jobs.count == 1 && h.jobs[0].printerName == "")
    }

    @Test func closeWithoutDataOrUnknownContext() {
        let h = PrinterHarness()
        #expect(h.feed(hex("42 01 03 00")) == [.reply(hex("C2 01 07 06")), .ack(4)])
        h.feed(hex("41 02 13 11") + printerName)
        #expect(h.feed(hex("42 03 01 00")) == [.reply(hex("C2 03 07 06")), .ack(4)])
        #expect(h.jobs.isEmpty && h.engine.openContexts.isEmpty)
    }

    @Test func getInfoOnPDFContextAnswersDefaults() {
        // Quirk §3.6: the reference throws for context 1; we answer result 0 with the defaults.
        var config = PrinterEngine.Config()
        config.devmode.orientation = 2
        let h = PrinterHarness(config: config)
        let out = h.feed(hex("45 01 01 00 0A 00 00 00 00 01"))
        guard case .reply(let r) = out.first else { Issue.record("no reply"); return }
        #expect(r.count == 65 && Array(r[0...3]) == hex("C5 01 00 00") && Array(r[18...19]) == hex("02 00"))
        #expect(out.last == .ack(10))
        // Other flags or another context: 0x0607, same layout.
        for request in [hex("45 02 01 00 01 00 00 00 00 01"), hex("45 02 02 00 0A 00 00 00 00 01")] {
            guard case .reply(let e) = h.feed(request).first else { Issue.record("no reply"); return }
            #expect(e.count == 65 && Array(e[2...3]) == hex("07 06"))
        }
    }

    @Test func jobCapRefusesAndKeepsAcking() {
        var config = PrinterEngine.Config()
        config.maxJobBytes = 10_000
        let h = PrinterHarness(config: config)
        h.feed(hex("41 01 13 11") + printerName)
        for tag: UInt8 in 2...5 {
            let out = h.feed(PrinterRequest(tag: tag, .write(context: 1, data: Data(repeating: 1, count: 4096))))
            #expect(out == [.reply([0xC4, tag, 0, 0, 0, 0x10]), .ack(4102)])
        }
        #expect(h.refused.count == 1 && h.refused[0].0 == 1)
        #expect(h.feed(hex("42 06 01 00")) == [.reply(hex("C2 06 07 06")), .ack(4)])
        #expect(h.jobs.isEmpty)
        // The next job is fine again.
        h.feed(hex("41 07 13 11") + printerName)
        h.feed(PrinterRequest(tag: 8, .write(context: 1, data: Data(repeating: 1, count: 4096))))
        h.feed(hex("42 09 01 00"))
        #expect(h.jobs.map(\.id) == [2] && h.jobs[0].data.count == 4096)
    }

    @Test func maximalWriteIsAckedInTwoPackets() {
        let h = PrinterHarness()
        h.feed(hex("41 01 13 11") + printerName)
        let out = h.feed(PrinterRequest(tag: 0, .write(context: 1, data: Data(repeating: 1, count: 65535))))
        #expect(out == [.ack(65535), .ack(6)])
        #expect(h.engine.bytesAcknowledged == 23 + 65541)
    }

    @Test func hostNamesFromMetafileAndOpen() {
        let h = PrinterHarness()
        h.feed(hex("4D 01 01 00 25 00 04 1D 00 01") + ascii("PDF\0Citrix PDF Universal Printer\0"))
        h.feed(hex("41 02 13 11") + printerName)
        #expect(h.engine.hostNames == ["PDF", "Citrix PDF Universal Printer", "Citrix PDF Printer"])
    }

    @Test func defaultCapIs256MiB() {
        #expect(PrinterEngine.Config().maxJobBytes == 256 << 20)
    }

    @Test func newOpenReplacesUnfinishedJob() {
        let h = PrinterHarness()
        h.feed(hex("41 01 13 11") + printerName)
        h.feed(PrinterRequest(tag: 2, .write(context: 1, data: Data([1, 2]))))
        h.feed(hex("41 03 13 11") + printerName)
        #expect(h.refused.map(\.0) == [1])
        h.feed(PrinterRequest(tag: 4, .write(context: 1, data: Data([9]))))
        h.feed(hex("42 05 01 00"))
        #expect(h.jobs.map(\.id) == [2] && h.jobs[0].data == Data([9]))
    }

    @Test func shutdownDiscardsOpenJobAndStops() {
        let h = PrinterHarness()
        h.feed(hex("41 01 13 11") + printerName)
        h.feed(PrinterRequest(tag: 2, .write(context: 1, data: Data([1, 2]))))
        h.engine.shutdown()
        #expect(h.refused.map(\.0) == [1])
        #expect(h.feed(hex("42 03 01 00")).isEmpty)
        #expect(h.jobs.isEmpty)
    }

    @Test func eventsCarryNoJobData() {
        let h = PrinterHarness()
        var lines: [String] = []
        h.engine.onEvent = { lines.append($0.description) }
        h.feed(hex("41 01 13 11") + printerName)
        h.feed(PrinterRequest(tag: 2, .write(context: 1, data: Data(ascii("SECRET-CONTENT")))))
        h.feed(hex("42 03 01 00"))
        #expect(!lines.isEmpty)
        #expect(!lines.contains { $0.contains("SECRET") })
        #expect(lines.contains { $0.contains("job 1: 14 B in 1 writes") })
    }
}

@Suite struct PrintingDocumentTests {
    @Test func validPDF() throws {
        let data = makePDF(pages: 2, title: "Unbenannt - Editor")
        guard case .success(let info) = PrintDocument.inspect(data) else { Issue.record("refused"); return }
        #expect(info.pageCount == 2 && info.title == "Unbenannt - Editor" && info.byteCount == data.count && info.hasEOF)
    }

    @Test func refusals() {
        #expect(PrintDocument.inspect(Data()) == .failure(.empty))
        #expect(PrintDocument.inspect(Data("hello world".utf8)) == .failure(.notPDF))
        #expect(PrintDocument.inspect(Data("%PDF-1.4\n garbage without objects\n%%EOF\n".utf8)) == .failure(.unreadable))
        #expect(PrintDocument.inspect(makePDF(pages: 1, password: "pw")) == .failure(.locked))
    }

    @Test func headerAndEOFChecks() {
        #expect(PrintDocument.hasHeader(Data("junk\n%PDF-1.7".utf8)))
        #expect(!PrintDocument.hasHeader(Data("%PD".utf8)))
        #expect(PrintDocument.endsWithEOF(Data("...\n%%EOF\r\n".utf8)))
        #expect(!PrintDocument.endsWithEOF(Data("...\n%%EO".utf8)))
    }

    @Test func fileNames() {
        #expect(PrintDocument.fileName(title: "a/b:c\\d", fallback: "x") == "a_b_c_d.pdf")
        #expect(PrintDocument.fileName(title: "..hidden", fallback: "x") == "hidden.pdf")
        #expect(PrintDocument.fileName(title: "  ", fallback: "Print job 3") == "Print job 3.pdf")
        #expect(PrintDocument.fileName(title: nil, fallback: "Print job 3") == "Print job 3.pdf")
        // At most 200 UTF-8 bytes including ".pdf", whole characters only.
        let long = PrintDocument.fileName(title: String(repeating: "é", count: 200), fallback: "x")
        #expect(long.utf8.count == 200 && long.hasSuffix(".pdf") && long.count == 98 + 4)
        let emoji = PrintDocument.fileName(title: String(repeating: "😀", count: 100), fallback: "x")
        #expect(emoji.utf8.count <= 200 && emoji.utf8.count == 49 * 4 + 4)
        #expect(PrintDocument.fileName(title: String(repeating: "a", count: 500), fallback: "x").utf8.count == 200)
        #expect(PrintDocument.fileName(title: "...", fallback: "Print job 7") == "Print job 7.pdf")
    }
}

@Suite struct PrintingSpoolTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("printspool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func writeIsPrivateAndRemovable() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = PrintSpool(base: root.appendingPathComponent("ICAViewer/print"))
        let a = try spool.write(Data([1, 2, 3]), name: "Doc.pdf")
        let b = try spool.write(Data([4]), name: "Doc.pdf")
        #expect(a != b && a.lastPathComponent == "Doc.pdf")
        #expect(try Data(contentsOf: a) == Data([1, 2, 3]))
        #expect(try mode(a) == 0o600)
        #expect(try mode(spool.folder) == 0o700 && mode(spool.base) == 0o700 && mode(a.deletingLastPathComponent()) == 0o700)
        spool.remove(a)
        #expect(!FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        // Removing a path outside the spool does nothing.
        let outside = root.appendingPathComponent("keep/file.pdf")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: outside)
        spool.remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        spool.removeAll()
        #expect(!FileManager.default.fileExists(atPath: spool.folder.path))
    }

    @Test func removeStaleOnlyForDeadProcesses() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("print")
        let dead = PrintSpool(base: base, pid: 900_001), running = PrintSpool(base: base, pid: 900_002)
        let current = PrintSpool(base: base, pid: 900_001)   // same pid as `dead`: its own folder still stays
        for spool in [dead, running, current] { _ = try spool.write(Data([1]), name: "a.pdf") }
        #expect(dead.folder.lastPathComponent.hasPrefix("900001-"))
        let oldStyle = base.appendingPathComponent("legacy"), recentStyle = base.appendingPathComponent("recent")
        for url in [oldStyle, recentStyle] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: oldStyle.path)
        current.removeStale(alive: { $0 == 900_002 })
        #expect(!FileManager.default.fileExists(atPath: dead.folder.path))
        #expect(FileManager.default.fileExists(atPath: running.folder.path))
        #expect(FileManager.default.fileExists(atPath: current.folder.path))
        #expect(!FileManager.default.fileExists(atPath: oldStyle.path))
        #expect(FileManager.default.fileExists(atPath: recentStyle.path))
        #expect(PrintSpool.processAlive(getpid()))
    }

    @Test func byteCapRefusesWrites() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = PrintSpool(base: root.appendingPathComponent("print"), maxBytes: 10)
        let a = try spool.write(Data(count: 6), name: "a.pdf")
        #expect(throws: PrintSpool.Failure.self) { try spool.write(Data(count: 5), name: "b.pdf") }
        #expect(spool.heldBytes == 6)
        spool.remove(a)
        _ = try spool.write(Data(count: 10), name: "c.pdf")
        #expect(spool.heldBytes == 10)
        #expect(PrintSpool(base: root).maxBytes == 1 << 30)
    }
}

@Suite struct PrintingSettingsTests {
    @Test func loadSaveAndOverrides() throws {
        let name = "printing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var s = PrintSettings.load(defaults: defaults, env: [:])
        #expect(s.enabled == PrintSettings.defaultEnabled && s.action == .printDialog)
        s.enabled = true
        s.action = .preview
        s.save(to: defaults)
        #expect(PrintSettings.load(defaults: defaults, env: [:]) == s)
        #expect(PrintSettings.load(defaults: defaults, env: ["ICA_PRINTING": "0"]).enabled == false)
        #expect(PrintSettings.load(defaults: defaults, env: ["ICA_PRINT_ACTION": "print"]).action == .printDialog)
        s.enabled = false
        s.save(to: defaults)
        #expect(PrintSettings.load(defaults: defaults, env: ["ICA_PRINTING": "1"]).enabled)
    }
}

@Suite struct PrintTestGateTests {
    @Test func dialogNeedsEnumAndAPDFPrinter() {
        #expect(PrintTestGate.mayOpenDialog(enumCount: 0, hostNames: ["Citrix PDF Printer"]) != .proceed)
        #expect(PrintTestGate.mayOpenDialog(enumCount: 1, hostNames: []) != .proceed)
        // Live: the host sent nothing on CTXCPM; its printers (PDFCreator, a paper printer) are server-side.
        #expect(PrintTestGate.mayOpenDialog(enumCount: 0, hostNames: []) != .proceed)
        #expect(PrintTestGate.mayOpenDialog(enumCount: 2, hostNames: ["HP LaserJet"]) != .proceed)
        #expect(PrintTestGate.mayOpenDialog(enumCount: 1, hostNames: ["PDF", "Citrix PDF Universal Printer"]) == .proceed)
        #expect(PrintTestGate.mayOpenDialog(enumCount: 1, hostNames: ["citrix pdf printer"]) == .proceed)
    }

    @Test func enterNeedsEveryCheck() {
        let shot = Date(timeIntervalSince1970: 1_000)
        let ok = PrintTestGate.Decision.proceed
        #expect(PrintTestGate.mayConfirm(confirmEnv: true, dialogGate: ok, screenshotSaved: shot, confirmCreated: shot.addingTimeInterval(30)) == .proceed)
        #expect(PrintTestGate.mayConfirm(confirmEnv: false, dialogGate: ok, screenshotSaved: shot, confirmCreated: shot.addingTimeInterval(30)) != .proceed)
        #expect(PrintTestGate.mayConfirm(confirmEnv: true, dialogGate: .refuse("no PDF"), screenshotSaved: shot,
                                         confirmCreated: shot.addingTimeInterval(30)) != .proceed)
        #expect(PrintTestGate.mayConfirm(confirmEnv: true, dialogGate: ok, screenshotSaved: nil, confirmCreated: shot) != .proceed)
        // Timeout: no file.
        #expect(PrintTestGate.mayConfirm(confirmEnv: true, dialogGate: ok, screenshotSaved: shot, confirmCreated: nil) != .proceed)
        // A file from before this run's screenshot (stale) does not count.
        #expect(PrintTestGate.mayConfirm(confirmEnv: true, dialogGate: ok, screenshotSaved: shot, confirmCreated: shot.addingTimeInterval(-60)) != .proceed)
    }

    @Test func confirmationFilePerRun() throws {
        let a = PrintTestGate.newRunID(), b = PrintTestGate.newRunID()
        #expect(a != b && a.count == 12)
        #expect(PrintTestGate.confirmFileName(runID: a) == "printtest-confirm-\(a)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(PrintTestGate.confirmFileName(runID: a))
        #expect(PrintTestGate.confirmationDate(at: file) == nil)
        try Data().write(to: file)
        #expect(PrintTestGate.confirmationDate(at: file) != nil)
        // A symlink or a folder does not count.
        let link = dir.appendingPathComponent(PrintTestGate.confirmFileName(runID: b))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(PrintTestGate.confirmationDate(at: link) == nil)
        let folder = dir.appendingPathComponent("printtest-confirm-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(PrintTestGate.confirmationDate(at: folder) == nil)
    }
}
