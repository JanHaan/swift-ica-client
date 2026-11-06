import Testing
import Foundation
@testable import ICAKit

// MARK: Fake host (test only)

private func p(_ text: String) -> Data { Data(text.utf8) }

/// Inline engine over a memory FS; replies collected per channel write.
private final class CDMHarness {
    let fs: CDMMemoryFileSystem
    let engine: CDMEngine
    var writes: [Data] = []
    var events: [String] = []
    private var nextID: UInt8 = 0

    init(readOnly: Bool = false, utf8: Bool = true, connect: Bool = true) {
        fs = CDMMemoryFileSystem(readOnly: readOnly)
        var config = CDMEngine.Config(fileSystem: fs, letter: "M", label: "Citrix Shared")
        config.backlogLimit = 1 << 20
        engine = CDMEngine(config: config)
        engine.serverForTesting.timeZone = TimeZone(identifier: "UTC")!
        engine.output = { [unowned self] out in if case .channel(let d) = out { writes.append(d) } }
        engine.onEvent = { [unowned self] in events.append($0.description) }
        if connect {
            _ = send(.connect(fields: [16, 0, 0, utf8 ? 0x10 : 0, 0, 0, 0, 0]))
        }
    }

    /// Sends one request; returns the reply bytes (nil if none came).
    func send(_ body: CDMRequestBody) -> Data? {
        nextID &+= 1
        let before = writes.count
        engine.receive(CDMRequest(id: nextID, body).encode())
        return writes.count > before ? writes.last : nil
    }

    var lastID: UInt8 { nextID }

    // Typed helpers.
    func create(_ path: String, access: UInt16 = 2, disposition: UInt16 = 5, attributes: UInt16 = 0) -> (ctx: UInt16, st: UInt16) {
        var r = ByteReader(send(.create(path: p(path), access: access, disposition: disposition, attributes: attributes, unknown1: 0, unknown2: 0))!)
        _ = try! r.u16()
        return (try! r.u16(), try! r.u16())
    }
    func open(_ path: String, mode: UInt16 = 0) -> (ctx: UInt16, st: UInt16) {
        var r = ByteReader(send(.open(path: p(path), mode: mode))!)
        _ = try! r.u16()
        return (try! r.u16(), try! r.u16())
    }
    func write(_ ctx: UInt16, _ data: Data, at offset: UInt32 = 0) -> (written: UInt16, st: UInt16) {
        var r = ByteReader(send(.write(handle: ctx, offset: offset, data: data))!)
        _ = try! r.u16()
        #expect(try! r.u16() == ctx)
        return (try! r.u16(), try! r.u16())
    }
    func read(_ ctx: UInt16, at offset: UInt32 = 0, count: UInt16 = 4096) -> (data: Data, st: UInt16) {
        var r = ByteReader(send(.read(handle: ctx, offset: offset, count: count))!)
        _ = try! r.u16()
        #expect(try! r.u16() == ctx)
        _ = try! r.u16(); _ = try! r.u16()
        let n = try! r.u16(), st = try! r.u16()
        return (try! r.raw(Int(n)), st)
    }
    func status(_ body: CDMRequestBody) -> UInt16 {
        var r = ByteReader(send(body)!)
        _ = try! r.u16()
        return try! r.u16()
    }
}

/// A decoded find reply.
private struct FindReply {
    var command: UInt8
    var ctx: UInt16
    var st: UInt16
    var names: [(short: String, long: String, attributes: UInt16, size: UInt32)] = []

    init(_ data: Data, utf8: Bool = true) {
        var r = ByteReader(data)
        command = try! r.u8()
        _ = try! r.u8()
        ctx = try! r.u16()
        let bytes = try! r.u16()
        st = try! r.u16()
        let count = try! r.u8()
        #expect(r.remaining == Int(bytes))
        for _ in 0..<count {
            _ = try! r.u16(); _ = try! r.u16()
            let size = try! r.u32(), attributes = try! r.u16()
            let s = Int(try! r.u8()), l = utf8 ? Int(try! r.u16()) : Int(try! r.u8())
            let short = String(decoding: try! r.raw(s).prefix { $0 != 0 }, as: UTF8.self)
            let long = String(decoding: try! r.raw(l), as: UTF8.self)
            names.append((short, long, attributes, size))
        }
        #expect(r.isAtEnd)
    }

    var longNames: [String] { names.map { $0.long.isEmpty ? $0.short : $0.long } }
}

/// Serialized: the CDM tests are CPU-heavy (debug-build string work) and would otherwise starve the
/// timing-based CGP tests running in parallel.
@Suite(.serialized) struct CDMProtocolTests {
    // MARK: Module (§A.1)

    @Test func cdmModuleGolden() {
        func hex(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }
        let date = Date(timeIntervalSince1970: 0)
        let m = WDModules.cdm(drives: [("M", false)], date: date)
        let dosStamp = Array(m[28...31])  // local-time header date/time, checked elsewhere
        // docs/95 §A.1 LIVE FINDING, the 70-byte example (byte count and "remaining" are patched later).
        let expected = hex("46 00 00 03 01 0A") + [UInt8](repeating: 0, count: 13) + hex("49 43 41 00 00 00 00 00 00") + dosStamp
            + hex("00 00 00 00 0A 00 00 00 00 03 00 00 24 F4 14 10 01 00 42 00 01 00") + [UInt8](repeating: 0, count: 12)
            + hex("4D 00 02 00")
        #expect(m.count == 70)
        #expect(WDModules.initResponsePackets([m])[0].dropFirst(3).elementsEqual(expected))
        // Two drives: offset still 66, 8 entry bytes, 74 bytes; no drives: offset 0, 66 bytes.
        let two = WDModules.cdm(drives: [("M", false), ("n", true)], date: date)
        #expect(two.count == 74)
        #expect(Array(two[48...53]) == hex("02 00 42 00 01 00"))
        #expect(Array(two[66...]) == hex("4D 00 02 00 4E 00 01 00"))
        let none = WDModules.cdm(drives: [], date: date)
        #expect(none.count == 66 && Array(none[48...51]) == [0, 0, 0, 0])
    }

    @Test func cdmModuleInInitResponseAndBindTable() throws {
        let wd = WinstationDriver(configuration: {
            var c = WinstationDriver.Configuration()
            c.logon.initialProgram = "#Notepad"
            return c
        }())
        wd.register(ThinwireEngine())
        let engine = CDMEngine(config: CDMEngine.Config(fileSystem: CDMMemoryFileSystem(), letter: "P"))
        #expect(wd.register(engine) == 10)
        let (modules, names) = try wd.buildModules()
        let index = try #require(names.firstIndex(of: "CTXCDM "))
        let module = modules[index]
        #expect(module.count == 70)
        #expect(module[5] == 10 && module[41] == 3 && module[50] == 66 && module[66] == 0x50)  // max version 10, flow 3, offset, letter P
        // WD module bind table: "CTXCDM " NUL 0A 00.
        let bind: [UInt8] = Array("CTXCDM ".utf8) + [0, 10, 0]
        #expect(modules[0].indices.contains { i in i + bind.count <= modules[0].count && Array(modules[0][i..<i + bind.count]) == bind })
    }

    // MARK: Wire (§A.2, §A.3)

    private let allRequests: [CDMRequestBody] = [
        .connect(fields: [16, 1, 2, 0x10, 4, 5, 6, 7]),
        .create(path: p("M:\\a.txt"), access: 2, disposition: 5, attributes: 0x20, unknown1: 7, unknown2: 9),
        .open(path: p("M:\\dir\\b"), mode: 0x42),
        .close(handle: 3),
        .read(handle: 1, offset: 0x1234_5678, count: 4096),
        .write(handle: 1, offset: 9, data: Data([1, 2, 3, 0, 5])),
        .findFirst(path: p("M:\\*.*"), bufferSize: 4000, maxEntries: 50),
        .findNext(handle: 2, bufferSize: 4000, maxEntries: 50),
        .findClose(handle: 2),
        .getAttributes(path: p("M:\\")),
        .setAttributes(path: p("M:\\x"), attributes: 3),
        .getDateTime(handle: 1),
        .setDateTime(handle: 1, time: 0x6000, date: 0x5A21),
        .delete(path: p("M:\\x")),
        .rename(from: p("M:\\old name"), to: p("M:\\neu")),
        .createDirectory(path: p("M:\\d"), unknown1: 1, unknown2: 2, date: 3, time: 4),
        .deleteDirectory(path: p("M:\\d")),
        .readConditional(handle: 1, time: 2, date: 3, offset: 4, unknown: 5, count: 6),
        .changeSize(handle: 1, size: 100),
        .seek(handle: 1, offset: 0, mode: 2),
        .volumeInfo(path: p("M:\\"), flags: 1),
        .findFirstIndex(path: p("M:\\*"), bufferSize: 512, index: 3, maxEntries: 0),
    ]

    @Test func cdmRequestRoundTripsWholeSplitAndMerged() {
        let requests = allRequests.enumerated().map { CDMRequest(id: UInt8($0.offset), $0.element) }
        let stream = requests.reduce(Data()) { $0 + $1.encode() }
        // One message per feed.
        for request in requests {
            var parser = CDMStreamParser()
            #expect(parser.feed(request.encode()) == [.request(request)])
        }
        // All merged into one write.
        var merged = CDMStreamParser()
        #expect(merged.feed(stream) == requests.map { .request($0) })
        // One byte at a time: nothing comes out early, everything in order.
        var split = CDMStreamParser()
        var out: [CDMStreamParser.Item] = []
        for b in stream { out += split.feed(Data([b])) }
        #expect(out == requests.map { .request($0) })
        #expect(split.bufferedCount == 0)
        // Arbitrary cuts (7-byte writes).
        var cuts = CDMStreamParser()
        out = []
        var i = 0
        while i < stream.count { out += cuts.feed(stream.subdata(in: i..<min(stream.count, i + 7))); i += 7 }
        #expect(out == requests.map { .request($0) })
    }

    @Test func cdmUnknownCommandIsFatal() {
        let good = CDMRequest(id: 1, .close(handle: 1))
        for bad: UInt8 in [0x10, 0x12, 0x13, 0x19, 0x1F, 0x20, 0x97, 0xFF] {
            var parser = CDMStreamParser()
            let items = parser.feed(good.encode() + Data([bad, 0x05, 1, 2, 3]) + good.encode())
            #expect(items.count == 2)
            #expect(items[0] == .request(good))
            #expect(items[1] == .fatal(command: bad, head: Data([bad, 0x05, 1, 2, 3]) + good.encode()))
            #expect(parser.failed)
            #expect(parser.feed(good.encode()).isEmpty)
        }
    }

    @Test func cdmReplyLayouts() {
        let connect = CDMRequest(id: 0x42, .connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0]))
        #expect(CDMReply(to: connect, .connect(caps: CDMWire.capsUTF8)).encode() == Data([0x97, 0x42, 0, 0, 1, 0, 0x0A, 0, 0x09, 0]))
        let r = CDMRequest(id: 7, .read(handle: 2, offset: 0, count: 3))
        #expect(CDMReply(to: r, .read(2, date: 0, time: 0, status: 0, data: Data([9, 8, 7]))).encode()
                == Data([0x83, 7, 2, 0, 0, 0, 0, 0, 3, 0, 0, 0, 9, 8, 7]))
        let index = CDMRequest(id: 1, .findFirstIndex(path: p("M:\\*"), bufferSize: 1, index: 0, maxEntries: 1))
        #expect(CDMReply(to: index, .find(0xFFFF, status: CDMStatus.noMoreFiles, count: 0, entries: Data())).encode()
                == Data([0x85, 1, 0xFF, 0xFF, 0, 0, 0x01, 0x12, 0]))
        let rename = CDMRequest(id: 3, .rename(from: Data(), to: Data()))
        #expect(CDMReply(to: rename, .rename(status: CDMStatus.fileExists)).encode() == Data([0x8D, 3, 0x0C, 0x50, 0, 0]))
        let volume = CDMRequest(id: 4, .volumeInfo(path: Data(), flags: 0))
        #expect(CDMReply(to: volume, .volume(status: 0, label: p("Mac"))).encode()
                == Data([0x96, 4, 0, 0, 0x41, 0x40, 0x40, 0x40, 0x20, 0x20, 0x20, 0x20, 0, 0, 0x10, 0] + [UInt8](repeating: 0, count: 8)
                        + [3, 0, 0, 0] + Array("Mac".utf8)))
    }

    @Test func cdmDosTime() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
        let stamp = CDMDosTime(date, timeZone: utc)
        #expect(stamp.date == UInt16(2023 - 1980) << 9 | 11 << 5 | 14)
        #expect(stamp.time == 22 << 11 | 13 << 5 | 10)
        #expect(stamp.date(timeZone: utc) == date)
        #expect(CDMDosTime(Date(timeIntervalSince1970: 0), timeZone: utc) == CDMDosTime(date: 1 << 5 | 1, time: 0))
        #expect(CDMDosTime(date: 0, time: 0).date(timeZone: utc) == nil)
        #expect(CDMDosTime(date: 43 << 9 | 2 << 5 | 31, time: 0).date(timeZone: utc) == nil)  // 31 February
    }

    // MARK: Paths (§A.2, §A.7)

    @Test func cdmPathParsing() {
        func ok(_ s: String, pattern: Bool = false) -> [String]? {
            if case .success(let path) = CDMNames.parse(p(s), utf8: true, letter: "M", pattern: pattern) { return path.components }
            return nil
        }
        #expect(ok("M:\\") == [])
        #expect(ok("M:") == [])
        #expect(ok("m:\\Dir\\File.txt") == ["Dir", "File.txt"])
        #expect(ok("M:/a//b\\.\\c") == ["a", "b", "c"])
        #expect(ok("M:\\e\u{301}") == ["\u{e9}"])  // NFD in, NFC out
        #expect(ok("M:\\docs\\*.txt", pattern: true) == ["docs", "*.txt"])
        // A NUL cuts the string, as in the reference (a trailing NUL from the host must not fail paths).
        #expect(ok("M:\\a.txt\0") == ["a.txt"])
        #expect(ok("M:\\a\0\\..\\..\\etc") == ["a"])
        #expect(ok("\0M:\\a") == nil)
        let refused = [
            "M:\\..", "M:\\a\\..\\..\\etc", "M:\\a\\..", "N:\\a", "\\\\server\\share", "\\a", "M:a", "C:\\Windows",
            "M:\\a:stream", "M:\\CON", "M:\\nul.txt", "M:\\com1 .log", "M:\\*.txt", "M:\\a\\?\\b",
            "M:\\...", "M:\\ ", "M:\\\u{FF0E}\u{FF0E}", "M:\\.\u{200B}.", "M:\\..\u{FEFF}", "M:\\a\u{7}b", "M:\\a|b",
            "M:\\" + String(repeating: "x", count: 256),
        ]
        for s in refused { #expect(ok(s) == nil, "\(s.debugDescription) should be refused") }
        #expect(ok("M:\\a\\*", pattern: false) == nil)
        let long = "M:\\" + Array(repeating: "abc", count: 9000).joined(separator: "\\")
        #expect(CDMNames.parse(p(long), utf8: true, letter: "M") == .failure(.tooLong(long.utf8.count)))
        // V1: bytes are code points; invalid UTF-8 in V2 is refused.
        #expect(CDMNames.parse(Data([0x4D, 0x3A, 0x5C, 0xE4]), utf8: false, letter: "M") == .success(CDMPath(["ä"])))
        #expect(CDMNames.parse(Data([0x4D, 0x3A, 0x5C, 0xE4]), utf8: true, letter: "M") == .failure(.encoding))
    }

    @Test func cdmWildcardsAndShortNameRules() {
        #expect(CDMNames.matches("*.*", "README"))
        #expect(CDMNames.matches("*", ".hidden"))
        #expect(CDMNames.matches("*.TXT", "notes.txt"))
        #expect(!CDMNames.matches("*.txt", "notes.txt.bak"))
        #expect(CDMNames.matches("a?c.*", "abc"))
        #expect(CDMNames.matches("<.TXT", "x.txt"))   // NT DOS_STAR
        #expect(!CDMNames.matches("a*", "banana"))
        #expect(CDMNames.matches("*an*", "banana"))
        #expect(CDMNames.fits83("ABC.TXT", utf8: true))
        #expect(CDMNames.fits83("readme", utf8: true))
        #expect(!CDMNames.fits83("Long name.txt", utf8: true))
        #expect(!CDMNames.fits83(".profile", utf8: true))
        #expect(!CDMNames.fits83("a.b.c", utf8: true))
        #expect(!CDMNames.fits83("ä.txt", utf8: false))
    }

    // MARK: Server against the memory FS

    @Test func cdmConnectNegotiatesEncoding() {
        let h = CDMHarness(connect: false)
        #expect(h.send(.connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0])) == Data([0x97, 1, 0, 0, 1, 0, 0x0A, 0, 0x09, 0]))
        #expect(h.engine.serverForTesting.utf8)
        let v1 = CDMHarness(connect: false)
        #expect(v1.send(.connect(fields: [16, 0, 0, 0, 0, 0, 0, 0])) == Data([0x97, 1, 0, 0, 1, 0, 0x0A, 0, 0x03, 0]))
        #expect(!v1.engine.serverForTesting.utf8)
    }

    @Test func cdmCreateWriteReadClose() throws {
        let h = CDMHarness()
        let (ctx, st) = h.create("M:\\Notes.txt")
        #expect(st == 0 && ctx == 1)
        #expect(h.write(ctx, p("hello ")) == (6, 0))
        #expect(h.write(ctx, p("world"), at: 6) == (5, 0))
        #expect(h.read(ctx, count: 100) == (p("hello world"), 0))
        #expect(h.read(ctx, at: 6, count: 3) == (p("wor"), 0))
        #expect(h.read(ctx, at: 50, count: 3) == (Data(), 0))
        #expect(h.send(.close(handle: ctx)) == nil)  // CLOSE has no reply
        #expect(h.fs.node("Notes.txt")?.data == p("hello world"))
        #expect(h.fs.node("Notes.txt")?.quarantined == true)
        #expect(h.fs.openCount == 0)
        // Bad handle after close.
        #expect(h.read(ctx).st == CDMStatus.accessDenied)
        // Reply ids echo request ids.
        #expect(h.send(.getAttributes(path: p("M:\\notes.TXT")))![1] == h.lastID)
        // Never contents in the log.
        #expect(!h.events.joined().contains("hello"))
        #expect(h.events.contains { $0.contains("CLOSE ctx 1 \(CDMPath(["Notes.txt"]).logLabel): read 14 B, written 11 B") })
        #expect(!h.events.joined().contains("Notes"))   // file names never reach the log
    }

    @Test func cdmCreateDispositions() {
        let h = CDMHarness()
        h.fs.add("a.txt", "old")
        #expect(h.create("M:\\a.txt", disposition: 1).st == CDMStatus.fileExists)
        #expect(h.create("M:\\missing.txt", disposition: 2).st == CDMStatus.fileNotFoundCreate)
        let open = h.create("M:\\A.TXT", access: 0, disposition: 2)
        #expect(open.st == 0)
        #expect(h.read(open.ctx).data == p("old"))
        #expect(h.write(open.ctx, p("x")).st == CDMStatus.accessDenied)  // opened for reading
        let created = h.create("M:\\new.txt", disposition: 3)
        #expect(created.st == 0 && created.ctx == 2)                     // lowest free handle
        let replaced = h.create("M:\\a.txt", disposition: 5)
        #expect(replaced.st == 0)
        #expect(h.fs.node("a.txt")?.data == Data())
        #expect(h.create("M:\\nodir\\x.txt").st == CDMStatus.pathNotFound)
        #expect(h.create("M:\\").st == CDMStatus.accessDenied)
        #expect(h.open("M:\\nothere").st == CDMStatus.fileNotFound)
        #expect(h.open("M:\\..\\x").st == CDMStatus.pathNotFound)
        #expect(h.open("M:\\a.txt").ctx == 4)
    }

    @Test func cdmReadOnlyDriveRefusesEveryMutation() {
        let h = CDMHarness(readOnly: true)
        h.fs.add("doc.txt", "keep")
        h.fs.add("dir", directory: true)
        let deny = CDMStatus.accessDenied
        #expect(h.create("M:\\new.txt", access: 0, disposition: 1).st == deny)
        #expect(h.create("M:\\new.txt", access: 0, disposition: 3).st == deny)
        #expect(h.create("M:\\doc.txt", access: 0, disposition: 5).st == deny)
        #expect(h.create("M:\\doc.txt", access: 1, disposition: 2).st == deny)
        #expect(h.open("M:\\doc.txt", mode: 2).st == deny)
        let ro = h.open("M:\\doc.txt", mode: 0x40)
        #expect(ro.st == 0)
        #expect(h.read(ro.ctx).data == p("keep"))
        #expect(h.write(ro.ctx, p("x")).st == deny)
        var r = ByteReader(h.send(.changeSize(handle: ro.ctx, size: 0))!)
        _ = try! r.u16(); _ = try! r.u16()
        #expect(try! r.u16() == deny)
        #expect(h.status(.delete(path: p("M:\\doc.txt"))) == deny)
        #expect(h.status(.rename(from: p("M:\\doc.txt"), to: p("M:\\x.txt"))) == deny)
        #expect(h.status(.createDirectory(path: p("M:\\d2"), unknown1: 0, unknown2: 0, date: 0, time: 0)) == deny)
        #expect(h.status(.deleteDirectory(path: p("M:\\dir"))) == deny)
        #expect(h.status(.setAttributes(path: p("M:\\doc.txt"), attributes: 0)) == deny)
        r = ByteReader(h.send(.setDateTime(handle: ro.ctx, time: 0, date: 0x5A21))!)
        _ = try! r.u16(); _ = try! r.u16()
        #expect(try! r.u16() == deny)
        #expect(h.fs.node("doc.txt")?.data == p("keep"))
        #expect(h.fs.node("new.txt") == nil && h.fs.node("d2") == nil)
        // Entries carry the read-only attribute.
        let find = FindReply(h.send(.findFirst(path: p("M:\\*.*"), bufferSize: 4096, maxEntries: 50))!)
        #expect(find.names.allSatisfy { $0.attributes & CDMAttributes.readOnly != 0 })
    }

    @Test func cdmFindWildcardsPagingAndShortNames() {
        let h = CDMHarness()
        h.fs.add("b.txt", "12")
        h.fs.add("A.TXT", "1")
        h.fs.add("notes.md", "")
        h.fs.add("Long file name.txt", "abc")
        h.fs.add(".DS_Store", "")
        h.fs.add("Folder", directory: true)
        h.fs.add("bad:name", "")         // not valid on Windows: left out
        // All entries, sorted, no "." / "..", folders flagged, dot-files hidden.
        var find = FindReply(h.send(.findFirst(path: p("M:\\*.*"), bufferSize: 4096, maxEntries: 100))!)
        #expect(find.command == 0x85 && find.ctx == 0xFFFF && find.st == CDMStatus.noMoreFiles)
        #expect(find.longNames == [".DS_Store", "A.TXT", "b.txt", "Folder", "Long file name.txt", "notes.md"])
        #expect(find.names.first { $0.short == "Folder" }!.attributes == CDMAttributes.directory)
        #expect(find.names[0].attributes == CDMAttributes.hidden)
        let long = find.names.first { $0.long == "Long file name.txt" }!
        #expect(long.short == "LONGFI~1.TXT" && long.size == 3)
        #expect(h.events.contains { $0.contains("names not valid on Windows left out") })
        // Filter.
        find = FindReply(h.send(.findFirst(path: p("M:\\*.txt"), bufferSize: 4096, maxEntries: 100))!)
        #expect(find.longNames == ["A.TXT", "b.txt", "Long file name.txt"])
        // A name without wildcards is the folder to list (reference, §A.5): a file fails with PATH_NOT_FOUND.
        h.fs.add("Folder/inner.txt", "i")
        find = FindReply(h.send(.findFirst(path: p("M:\\FOLDER"), bufferSize: 4096, maxEntries: 100))!)
        #expect(find.longNames == ["inner.txt"] && find.st == CDMStatus.noMoreFiles)
        find = FindReply(h.send(.findFirst(path: p("M:\\notes.MD"), bufferSize: 4096, maxEntries: 100))!)
        #expect(find.st == CDMStatus.pathNotFound && find.ctx == 0xFFFF)
        find = FindReply(h.send(.findFirst(path: p("M:\\nope"), bufferSize: 4096, maxEntries: 100))!)
        #expect(find.st == CDMStatus.pathNotFoundSearch)
        find = FindReply(h.send(.findFirst(path: p("M:\\nodir\\*"), bufferSize: 4096, maxEntries: 100))!)
        #expect(find.st == CDMStatus.pathNotFoundSearch)
        // The short name is stable and maps back on lookup.
        let open = h.open("M:\\LONGFI~1.TXT")
        #expect(open.st == 0)
        #expect(h.read(open.ctx).data == p("abc"))
        // Paging by maxEntries: the rest stays (unlike the reference).
        find = FindReply(h.send(.findFirst(path: p("M:\\*"), bufferSize: 4096, maxEntries: 2))!)
        #expect(find.st == 0 && find.ctx == 1 && find.names.count == 2)
        var all = find.longNames
        while true {
            let next = FindReply(h.send(.findNext(handle: 1, bufferSize: 4096, maxEntries: 2))!)
            #expect(next.command == 0x86)
            all += next.longNames
            if next.st == CDMStatus.noMoreFiles { #expect(next.ctx == 0xFFFF); break }
        }
        #expect(all == [".DS_Store", "A.TXT", "b.txt", "Folder", "Long file name.txt", "notes.md"])
        // Paging by buffer size.
        find = FindReply(h.send(.findFirst(path: p("M:\\*"), bufferSize: 40, maxEntries: 100))!)
        #expect(find.st == 0 && find.names.count == 1)
        #expect(h.send(.findClose(handle: find.ctx)) == nil)
        #expect(h.engine.serverForTesting.openSearchCount == 0)
        // FIND_FIRST_INDEX starts at the index (fixed reference bug).
        find = FindReply(h.send(.findFirstIndex(path: p("M:\\*"), bufferSize: 4096, index: 4, maxEntries: 100))!)
        #expect(find.longNames == ["Long file name.txt", "notes.md"])
    }

    @Test func cdmFindCodePageEntries() {
        let h = CDMHarness(utf8: false)
        h.fs.add("für.txt", "x")
        h.fs.add("ABC.TXT", "x")
        let find = FindReply(h.send(.findFirst(path: p("M:\\*.*"), bufferSize: 4096, maxEntries: 100))!, utf8: false)
        #expect(find.names.map(\.short) == ["ABC.TXT", "FR~1.TXT"])
        #expect(find.names[1].long == "f?r.txt")
        // V1 paths are bytes as code points: "für.txt" in Latin-1 finds the file.
        #expect(h.status(.getAttributes(path: Data([0x4D, 0x3A, 0x5C, 0x66, 0xFC, 0x72, 0x2E, 0x74, 0x78, 0x74]))) == 0)
    }

    @Test func cdmAttributesDirectoriesRenameDelete() {
        let h = CDMHarness()
        h.fs.add("dir/inner.txt", "1")
        h.fs.add("x.txt", "123")
        var r = ByteReader(h.send(.getAttributes(path: p("M:\\X.txt")))!)
        _ = try! r.u16()
        #expect(try! r.u16() == 0 && (try! r.u32()) == 3 && (try! r.u16()) == 0)
        #expect(try! r.u16() == CDMDosTime(Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!).date)
        r = ByteReader(h.send(.getAttributes(path: p("M:\\")))!)
        _ = try! r.u16(); _ = try! r.u16(); _ = try! r.u32()
        #expect(try! r.u16() == CDMAttributes.directory)
        #expect(h.status(.getAttributes(path: p("M:\\none"))) == CDMStatus.fileNotFound)
        // Folders: mkdir, exists, no recursive delete.
        let mkdir = CDMRequestBody.createDirectory(path: p("M:\\new"), unknown1: 0, unknown2: 0, date: 0, time: 0)
        #expect(h.status(mkdir) == 0)
        #expect(h.fs.node("new")?.quarantined == true)
        #expect(h.status(mkdir) == CDMStatus.fileExists)
        #expect(h.status(.deleteDirectory(path: p("M:\\dir"))) == CDMStatus.accessDenied)
        #expect(h.fs.node("dir/inner.txt") != nil)
        #expect(h.status(.deleteDirectory(path: p("M:\\"))) == CDMStatus.accessDenied)
        #expect(h.status(.delete(path: p("M:\\dir"))) == CDMStatus.accessDenied)
        #expect(h.status(.delete(path: p("M:\\dir\\inner.txt"))) == 0)
        #expect(h.status(.deleteDirectory(path: p("M:\\dir"))) == 0)
        // Rename: move, refuse to overwrite, case-only rename allowed.
        #expect(h.status(.rename(from: p("M:\\x.txt"), to: p("M:\\new\\y.txt"))) == 0)
        h.fs.add("z.txt", "z")
        #expect(h.status(.rename(from: p("M:\\z.txt"), to: p("M:\\new\\Y.TXT"))) == CDMStatus.fileExists)
        #expect(h.status(.rename(from: p("M:\\z.txt"), to: p("M:\\Z.txt"))) == 0)
        #expect(h.fs.node("Z.txt") != nil)
        #expect(h.status(.rename(from: p("M:\\none"), to: p("M:\\q"))) == CDMStatus.fileNotFound)
        #expect(h.status(.rename(from: p("M:\\Z.txt"), to: p("M:\\..\\escape"))) == CDMStatus.pathNotFound)
        // Read-only attribute blocks DELETE (DOS semantics) until cleared.
        #expect(h.status(.setAttributes(path: p("M:\\Z.txt"), attributes: 0x03)) == 0)
        #expect(h.fs.node("Z.txt")!.readOnly && h.fs.node("Z.txt")!.hidden)
        #expect(h.status(.delete(path: p("M:\\Z.txt"))) == CDMStatus.accessDenied)
        #expect(h.status(.setAttributes(path: p("M:\\Z.txt"), attributes: 0)) == 0)
        #expect(h.status(.delete(path: p("M:\\Z.txt"))) == 0)
    }

    @Test func cdmSeekDateTimeChangeSizeVolume() {
        let h = CDMHarness()
        h.fs.add("f.bin", "0123456789")
        let ctx = h.open("M:\\f.bin", mode: 2).ctx
        #expect(h.send(.seek(handle: ctx, offset: 0, mode: 0)) == nil)   // only mode 2 replies
        #expect(h.send(.seek(handle: ctx, offset: 0, mode: 1)) == nil)
        #expect(h.send(.seek(handle: ctx, offset: 0, mode: 2)) == Data([0x95, h.lastID, UInt8(ctx), 0, 10, 0, 0, 0, 0, 0]))
        var r = ByteReader(h.send(.changeSize(handle: ctx, size: 4))!)
        _ = try! r.u16(); _ = try! r.u16()
        #expect(try! r.u16() == 0)
        #expect(h.fs.node("f.bin")?.data == p("0123"))
        let stamp = CDMDosTime(date: 44 << 9 | 3 << 5 | 7, time: 12 << 11 | 30 << 5 | 5)
        r = ByteReader(h.send(.setDateTime(handle: ctx, time: stamp.time, date: stamp.date))!)
        _ = try! r.u16(); _ = try! r.u16()
        #expect(try! r.u16() == 0)
        r = ByteReader(h.send(.getDateTime(handle: ctx))!)
        _ = try! r.u16(); _ = try! r.u16()
        #expect(try! r.u16() == stamp.date && (try! r.u16()) == stamp.time && (try! r.u16()) == 0)
        // READ_CONDITIONAL always returns the data, notModified 0.
        let rc = h.send(.readConditional(handle: ctx, time: 0xFFFF, date: 0xFFFF, offset: 1, unknown: 0, count: 2))!
        #expect(rc == Data([0x91, h.lastID, UInt8(ctx), 0, 0, 0, 0, 0, 2, 0, 0, 0]) + p("12") + Data([0, 0]))
        // Volume info: constants and the label.
        let v = h.send(.volumeInfo(path: p("M:\\"), flags: 0))!
        #expect(v.suffix(17) == Data([13, 0, 0, 0]) + p("Citrix Shared"))
        #expect(Data(v.prefix(4)) == Data([0x96, h.lastID, 0, 0]))
        #expect(h.status(.volumeInfo(path: p("X:\\"), flags: 0)) == CDMStatus.volumeDenied)
    }

    @Test func cdmHandleLimit() {
        let h = CDMHarness()
        h.fs.add("f", "x")
        for i in 1...CDMServer.maxFiles { #expect(h.open("M:\\f").ctx == UInt16(i)) }
        #expect(h.open("M:\\f") == (0xFFFF, CDMStatus.failure))
        #expect(h.fs.openCount == CDMServer.maxFiles)
        _ = h.send(.close(handle: 17))
        #expect(h.open("M:\\f").ctx == 17)
        h.engine.shutdown()
        #expect(h.fs.openCount == 0)
    }

    // MARK: Engine

    @Test func cdmEngineSplitDeliveryAndFatalStop() {
        let h = CDMHarness()
        h.fs.add("a.txt", "A")
        let requests = [CDMRequest(id: 10, .getAttributes(path: p("M:\\a.txt"))),
                        CDMRequest(id: 11, .close(handle: 9)),
                        CDMRequest(id: 12, .getAttributes(path: p("M:\\b.txt")))]
        let stream = requests.reduce(Data()) { $0 + $1.encode() } + Data([0x1E, 0x00]) + requests[0].encode()
        let before = h.writes.count
        for b in stream { h.engine.receive(Data([b])) }
        let replies = Array(h.writes[before...])
        #expect(replies.map { $0[1] } == [10, 12])          // in order, CLOSE silent
        #expect(replies[1][2] == 0x01 && replies[1][3] == 0x02) // FILE_NOT_FOUND
        #expect(h.engine.stopReason?.contains("OPEN_PLUS") == true)
        #expect(h.events.contains { $0.hasPrefix("protocol error: unknown command OPEN_PLUS") })
        h.engine.receive(requests[0].encode())
        #expect(h.writes.count == before + 2)                 // never answers again
    }

    @Test func cdmEnginePacesOnBacklogAndUsesIOQueue() async {
        let fs = CDMMemoryFileSystem()
        fs.add("a.txt", "A")
        var config = CDMEngine.Config(fileSystem: fs)
        config.backlogLimit = 100
        let engine = CDMEngine(config: config)
        var writes: [Data] = []
        var backlog = 1000
        var timers: [() -> Void] = []
        engine.output = { if case .channel(let d) = $0 { writes.append(d) } }
        engine.backlog = { backlog }
        engine.scheduleAfter = { _, block in timers.append(block) }
        let request = CDMRequest(id: 1, .getAttributes(path: p("M:\\a.txt")))
        engine.receive(CDMRequest(id: 0, .connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0])).encode() + request.encode())
        #expect(writes.isEmpty && timers.count == 1 && engine.queuedCount == 2)
        timers.removeFirst()()                                  // still over the limit: re-armed
        #expect(writes.isEmpty && timers.count == 1)
        backlog = 0
        timers.removeFirst()()
        #expect(writes.count == 2 && engine.queuedCount == 0)
        #expect(writes[1][0] == 0x88 && writes[1][2] == 0 && writes[1][3] == 0)

        // With an I/O queue: replies come back through `schedule`, in order.
        /// Hands non-Sendable values to the test's own serial queues.
        final class Unchecked<T>: @unchecked Sendable {
            let value: T
            init(_ value: T) { self.value = value }
        }
        let session = DispatchQueue(label: "test.session")
        let threaded = Unchecked(CDMEngine(config: CDMEngine.Config(fileSystem: fs)))
        threaded.value.ioQueue = DispatchQueue(label: "test.io")
        threaded.value.schedule = { block in
            let b = Unchecked(block)
            session.async { b.value() }
        }
        let ids: [UInt8] = await withCheckedContinuation { c in
            var got: [UInt8] = []
            threaded.value.output = { if case .channel(let d) = $0 { got.append(d[1]); if got.count == 21 { c.resume(returning: got) } } }
            session.async {
                var stream = CDMRequest(id: 0, .connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0])).encode()
                for i in 1...20 { stream += CDMRequest(id: UInt8(i), .getAttributes(path: p("M:\\a.txt"))).encode() }
                threaded.value.receive(stream)
            }
        }
        #expect(ids == Array(0...20))
    }

    @Test func cdmLargeTransferInChunks() {
        let h = CDMHarness()
        let size = 1 << 20
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let ctx = h.create("M:\\big.bin").ctx
        let chunk = 4096
        var offset = 0
        while offset < size {
            let piece = payload.subdata(in: offset..<min(size, offset + chunk))
            // Each request arrives in two VC writes.
            let bytes = CDMRequest(id: 1, .write(handle: ctx, offset: UInt32(offset), data: piece)).encode()
            h.engine.receive(bytes.prefix(1000))
            h.engine.receive(bytes.dropFirst(1000))
            offset += chunk
        }
        #expect(h.fs.node("big.bin")?.data == payload)
        var back = Data()
        while back.count < size {
            let (data, st) = h.read(ctx, at: UInt32(back.count), count: 4096)
            #expect(st == 0 && !data.isEmpty)
            back += data
        }
        #expect(back == payload)
        #expect(h.read(ctx, at: UInt32(size), count: 4096).data.isEmpty)
    }

    // MARK: Settings

    @Test func cdmSettingsRefuseBroadFolders() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/"), home: home) != nil)
        #expect(CDMSettings.refusal(home, home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Users"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Users/someone/Library/Mail"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/System/Library"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Volumes"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Users/someone/Citrix Shared"), home: home) == nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Volumes/USB/Share"), home: home) == nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Volumes/USB"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Users/someone/.ssh"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Users/someone/.config/share"), home: home) != nil)
        #expect(CDMSettings.refusal(URL(fileURLWithPath: "/Users/someone/Documents/.shared"), home: home) != nil)
        let defaults = UserDefaults(suiteName: "cdm-test-\(UUID().uuidString)")!
        var s = CDMSettings.load(defaults: defaults, env: [:])
        #expect(s.enabled && !s.readOnly && s.letter == "M" && s.folder.lastPathComponent == "Citrix Shared")
        s.readOnly = true
        s.enabled = false
        s.save(to: defaults)
        #expect(CDMSettings.load(defaults: defaults, env: [:]) == s)
        #expect(CDMSettings.load(defaults: defaults, env: ["ICA_CDM": "1", "ICA_CDM_LETTER": "q"]).enabled)
        #expect(CDMSettings.load(defaults: defaults, env: ["ICA_CDM_LETTER": "q"]).letter == "Q")
    }

    // MARK: Security review fixes

    @Test func cdmShortNamesScaleLinearly() {
        let h = CDMHarness()
        for i in 0..<16_000 { h.fs.add(String(format: "Same stem name %05d.txt", i), "") }
        let start = Date()
        var all: [String] = []
        var find = FindReply(h.send(.findFirst(path: p("M:\\*"), bufferSize: 0xFFFF, maxEntries: 255))!)
        all += find.names.map(\.short)
        while find.st == 0 {
            find = FindReply(h.send(.findNext(handle: find.ctx, bufferSize: 0xFFFF, maxEntries: 255))!)
            all += find.names.map(\.short)
        }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(all.count == 16_000 && Set(all).count == 16_000)
        #expect(all.first == "SAMEST~1.TXT" && all.contains("SA~16000.TXT"))
    }

    @Test func cdmEngineQueueOverflowStopsChannel() {
        let fs = CDMMemoryFileSystem()
        let engine = CDMEngine(config: CDMEngine.Config(fileSystem: fs))
        var writes = 0
        var events: [String] = []
        engine.output = { _ in writes += 1 }
        engine.onEvent = { events.append($0.description) }
        engine.backlog = { 1 << 30 }                  // transport never drains: requests pile up
        engine.scheduleAfter = { _, _ in }
        let one = CDMRequest(id: 1, .getAttributes(path: p("M:\\a"))).encode()
        engine.receive(Data(repeating: 0, count: 0) + Data((0..<CDMEngine.maxQueuedRequests).map { _ in one }.joined()))
        #expect(engine.stopReason == nil && engine.queuedCount == CDMEngine.maxQueuedRequests)
        engine.receive(one)
        #expect(engine.stopReason?.contains("flooded") == true && engine.queuedCount == 0 && writes == 0)
        #expect(events.contains { $0.contains("flooded") })
        // Bytes bound: 3 writes of 4 KB fit, 8 MiB worth does not.
        let bytes = CDMEngine(config: CDMEngine.Config(fileSystem: fs))
        bytes.backlog = { 1 << 30 }
        bytes.scheduleAfter = { _, _ in }
        let big = CDMRequest(id: 1, .write(handle: 1, offset: 0, data: Data(count: 0xFFFF))).encode()
        for _ in 0..<(CDMEngine.maxQueuedBytes / (0xFFFF + 16)) { bytes.receive(big) }
        #expect(bytes.stopReason == nil)
        bytes.receive(big)
        #expect(bytes.stopReason?.contains("flooded") == true)
    }

    @Test func cdmRetainedSearchesAreBounded() {
        let h = CDMHarness()
        let server = h.engine.serverForTesting
        server.maxRetainedFindBytes = 200_000
        for i in 0..<1_000 { h.fs.add(String(format: "a long file name number %04d.txt", i), "") }
        // Each search keeps ~1000 × 57 B ≈ 57 KB: three fit the cap, older ones are dropped.
        for _ in 0..<10 { #expect(FindReply(h.send(.findFirst(path: p("M:\\*"), bufferSize: 512, maxEntries: 1))!).st == 0) }
        #expect(server.retainedFindBytes <= 200_000 && server.openSearchCount == 3)
        #expect(h.events.filter { $0.hasPrefix("find: dropping") }.count == 7)
        // One listing above the cap is cut, never kept whole.
        server.maxRetainedFindBytes = 10_000
        let cut = FindReply(h.send(.findFirst(path: p("M:\\*"), bufferSize: 0xFFFF, maxEntries: 255))!)
        #expect(cut.st == CDMStatus.noMoreFiles && cut.names.count < 200)
        #expect(h.events.contains { $0.contains("listing cut") })
    }

    @Test func cdmTrailingDotsSpacesAndReadOnlyHandles() {
        let h = CDMHarness()
        #expect(h.create("M:\\name.", disposition: 1).st == CDMStatus.pathNotFound)
        #expect(h.create("M:\\name ", disposition: 1).st == CDMStatus.pathNotFound)
        #expect(h.status(.createDirectory(path: p("M:\\dir."), unknown1: 0, unknown2: 0, date: 0, time: 0)) == CDMStatus.pathNotFound)
        h.fs.add("f.txt", "x")
        #expect(h.status(.rename(from: p("M:\\f.txt"), to: p("M:\\g.txt "))) == CDMStatus.pathNotFound)
        #expect(h.fs.node("f.txt") != nil)
        // SET_DATE_TIME needs a handle opened for writing.
        let ro = h.open("M:\\f.txt", mode: 0)
        var r = ByteReader(h.send(.setDateTime(handle: ro.ctx, time: 0, date: 44 << 9 | 1 << 5 | 1))!)
        _ = try! r.u16(); _ = try! r.u16()
        #expect(try! r.u16() == CDMStatus.accessDenied)
        #expect(h.fs.node("f.txt")!.modified == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func cdmWildcardMatchingIsLinear() {
        let name = String(repeating: "a", count: 255)
        let pattern = String(repeating: "*a", count: 120) + "b"
        let start = Date()
        for _ in 0..<300 { #expect(!CDMNames.matches(pattern, name)) }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(CDMNames.matches("*a*b*c", "xxaxxbxxc") && !CDMNames.matches("*a*b*c", "xxaxxcxxb"))
        #expect(CDMNames.matches("a*", "a") && CDMNames.matches("*", "") && !CDMNames.matches("?", ""))
    }
}
