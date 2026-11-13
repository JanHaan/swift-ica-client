import Testing
import Foundation
@testable import ICAKit

// docs/75: CTXCLIP version 4 discovery (low/high CLIP_INIT, H1 request layout) and the shell file formats.

private func hx(_ s: String) -> Data { Data(bytes(hex: s.replacingOccurrences(of: " ", with: ""))) }

private enum H {
    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    /// Live: `01 00 01 00 04 00` (low 1, high 4).
    static let init14 = hx("01 00 01 00 04 00")
    /// The 7 names this host registers (live order, docs/75 §3).
    static let names: [(UInt16, String)] = [(0xC087, "Rich Text Format"), (0xC088, "Office Drawing Shape Format"),
                                            (0xC089, "PNG+Office Art"), (0xC08A, "Biff8"), (0xC08B, "HTML Format"),
                                            (0xC08C, "FileGroupDescriptorW"), (0xC08D, "FileContents")]
    static func formatNames(_ entries: [(UInt16, String)] = names) -> Data {
        var b = u16(8) + u16(0)
        for (id, name) in entries { b += u16(id) + u32(UInt32(name.utf8.count + 1)) + Array(name.utf8) + [0] }
        return Data(b + [0, 0, 0, 0, 0, 0])
    }
    static func list(_ ids: [UInt16]) -> Data { Data(u16(3) + u16(3) + ids.flatMap { u16($0) + u32(0) } + u16(0)) }
    /// Hypothesis H1: cmd, flags, format, u32 index (10 bytes).
    static func request(_ format: UInt16, index: UInt32, flags: UInt16 = 1) -> Data { Data(u16(4) + u16(flags) + u16(format) + u32(index)) }
    static func response(_ format: UInt16, _ data: Data) -> Data { Data(u16(5) + u16(0) + u16(format) + u32(UInt32(data.count))) + data }
}

private final class FilesHarness {
    let engine: ClipboardEngine
    var writes: [Data] = []
    var events: [ClipboardEngine.Event] = []

    init(maxVersion: UInt16 = 4, files: Bool = true, trace: Bool = false) {
        var config = ClipboardEngine.Config()
        config.maxVersion = maxVersion
        config.files = files
        config.traceWire = trace
        engine = ClipboardEngine(config: config)
        engine.output = { [unowned self] out in if case .channel(let d) = out { writes.append(d) } }
        engine.onEvent = { [unowned self] in events.append($0) }
    }

    func take() -> Data {
        defer { writes = [] }
        return writes.reduce(Data(), +)
    }

    func ready() {
        engine.receive(H.init14)
        engine.receive(H.formatNames())
        _ = take()
        events = []
    }
}

/// Two test files in a fresh temp folder: 37 known bytes and a 70 KB u32 counter pattern.
private func testFolder() throws -> (URL, Data, Data) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipfiles-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = Data("ICA clipboard file test: 37 bytes.\r\n\u{0}".utf8)
    var b = Data(capacity: 70 * 1024)
    for i in 0..<(70 * 1024 / 4) { withUnsafeBytes(of: UInt32(i).littleEndian) { b.append(contentsOf: $0) } }
    try a.write(to: dir.appendingPathComponent("a.txt"))
    try b.write(to: dir.appendingPathComponent("b.bin"))
    return (dir, a, b)
}

// MARK: Version negotiation (docs/75 §4.1)

@Test func clipInitCarriesLowAndHighVersion() {
    var p = ClipboardStreamParser()
    #expect(p.feed(H.init14) == [.initRequest(lowVersion: 1, highVersion: 4)])
    #expect(p.version == 3)   // default cap
    var q = ClipboardStreamParser()
    q.maxVersion = 4
    _ = q.feed(H.init14)
    #expect(q.version == 4)

    // Default engine still answers 3; the discovery build answers 4 with otherwise identical bytes.
    let v3 = FilesHarness(maxVersion: 3, files: false)
    v3.engine.receive(H.init14)
    #expect(v3.take() == hx("02 00 00 00 03 00 00 00 00 00 00 00"))
    let v4 = FilesHarness()
    v4.engine.receive(H.init14)
    #expect(v4.take() == hx("02 00 00 00 04 00 00 00 00 00 00 00"))
    #expect(v4.engine.version == 4)
    #expect(v4.events.map(\.description).contains("← CLIP_INIT host versions 1…4 → CLIP_INIT_REPLY version 4"))
}

// MARK: Hypothesis parser (docs/75 §4.2)

@Test func v4RequestCarriesAnIndex() {
    var p = ClipboardStreamParser()
    p.maxVersion = 4
    _ = p.feed(H.init14)
    // Live v3 bytes `04 00 01 00 0d 00 00 00 00 00` read as H1: index 0, nothing left over.
    #expect(p.feed(hx("04 00 01 00 0d 00 00 00 00 00")) == [.dataRequest(flags: 1, format: 13, index: 0)])
    // Index 1 for the second file stays inside the request, split over writes too.
    let second = H.request(0xC08D, index: 1)
    #expect(p.feed(second.prefix(7)).isEmpty)
    #expect(p.feed(second.dropFirst(7) + H.list([13])) == [.dataRequest(flags: 1, format: 0xC08D, index: 1), .formatList(flags: 3, formats: [13])])
    // H2 (12 bytes, a zero u16 more): skipped and reported, only right after a request.
    #expect(p.feed(H.request(13, index: 2) + hx("00 00")) == [.dataRequest(flags: 1, format: 13, index: 2),
                                                               .padding(bytes: 2, previous: H.request(13, index: 2))])
    // Zeros after anything else are a protocol error at version 4 (never skipped blindly).
    var q = ClipboardStreamParser()
    q.maxVersion = 4
    _ = q.feed(H.init14)
    let out = q.feed(H.list([13]) + hx("00 00 05 00"))
    #expect(out.count == 2)
    if case .unknown(0, _, let head, _) = out.last { #expect(head == hx("00 00 05 00")) } else { Issue.record("expected unknown 0") }

    // At version 3 the old 8-byte read is unchanged: the index's low half is read as the "reserved" u16 and lost,
    // its zero high half is skipped as padding. A FileContents request at v3 therefore has no usable index.
    var v3 = ClipboardStreamParser()
    _ = v3.feed(H.init14)
    let old = v3.feed(H.request(0xC08D, index: 1))
    #expect(old == [.dataRequest(flags: 1, format: 0xC08D), .padding(bytes: 2, previous: H.request(0xC08D, index: 1).prefix(8))])
}

@Test func ourV4RequestMirrorsTheHypothesis() {
    #expect(ClipboardWire.dataRequest(format: 13) == hx("04 00 00 00 0d 00 00 00"))
    #expect(ClipboardWire.dataRequest(format: 0xC08D, index: 1) == hx("04 00 00 00 8d c0 01 00 00 00"))
}

// MARK: FILEGROUPDESCRIPTORW (docs/75 §5)

@Test func fileGroupDescriptorBuildAndParse() throws {
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    let entries = [
        ClipboardFileEntry(name: "a.txt", size: 37, writeTime: when),
        ClipboardFileEntry(name: "dir", size: 0, isDirectory: true),
        ClipboardFileEntry(name: "dir\\b.bin", size: 0x1_0000_0002, writeTime: nil, hidden: true),
    ]
    let d = try ClipboardFileGroup.build(entries)
    #expect(d.count == 4 + 3 * 592)
    let b = [UInt8](d)
    func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
    #expect(u32(0) == 3)
    #expect(u32(4) == 0x8000_4064)                    // FD_ATTRIBUTES|WRITESTIME|FILESIZE|PROGRESSUI|UNICODE
    #expect(u32(4 + 36) == 0x80)                      // FILE_ATTRIBUTE_NORMAL
    let ft = UInt64(u32(4 + 56)) | UInt64(u32(4 + 60)) << 32
    #expect(ft == 116_444_736_000_000_000 + 17_000_000_000_000_000)
    #expect(u32(4 + 64) == 0 && u32(4 + 68) == 37)
    #expect(Array(b[(4 + 72)..<(4 + 84)]) == Array("a.txt".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) + [0, 0])
    #expect(u32(4 + 592 + 36) == 0x10)                // directory
    #expect(u32(4 + 2 * 592) == 0x8000_4044)          // no write time → FD_WRITESTIME cleared
    #expect(u32(4 + 2 * 592 + 36) == 0x02)            // hidden file
    #expect(u32(4 + 2 * 592 + 64) == 1 && u32(4 + 2 * 592 + 68) == 2)

    let back = try ClipboardFileGroup.parse(d)
    #expect(back.map(\.name) == ["a.txt", "dir", "dir\\b.bin"])
    #expect(back.map(\.size) == [37, 0, 0x1_0000_0002])
    #expect(back.map(\.isDirectory) == [false, true, false])
    #expect(back[0].writeTime == when && back[2].writeTime == nil)

    #expect(throws: ClipboardFileGroup.Failure.count(0)) { try ClipboardFileGroup.parse(Data([0, 0, 0, 0])) }
    #expect(throws: ClipboardFileGroup.Failure.length(expected: 596, actual: 100)) { try ClipboardFileGroup.parse(Data([1, 0, 0, 0] + [UInt8](repeating: 0, count: 96))) }
    #expect(throws: ClipboardFileGroup.Failure.nameTooLong(String(repeating: "x", count: 260))) {
        try ClipboardFileGroup.build([ClipboardFileEntry(name: String(repeating: "x", count: 260), size: 1)])
    }
    #expect(ClipboardFileGroup.date(fileTime: ClipboardFileGroup.fileTime(when)) == when)
}

@Test func windowsNameRules() {
    #expect(ClipboardFileGroup.windowsComponent("a:b/c?.txt") == "a_b_c_.txt")
    #expect(ClipboardFileGroup.windowsComponent("notes. . ") == "notes")
    #expect(ClipboardFileGroup.windowsComponent("CON.txt") == "_CON.txt")
    #expect(ClipboardFileGroup.windowsComponent("com1") == "_com1")
    #expect(ClipboardFileGroup.windowsComponent("console.txt") == "console.txt")
    #expect(ClipboardFileGroup.windowsComponent("x\u{1}y") == "x_y")
    #expect(ClipboardFileGroup.windowsComponent("...") == "_")
}

// MARK: Engine: Mac → session (docs/75 §7, E2)

@Test func filesAreAnnouncedAndServedByIndex() throws {
    let (dir, a, b) = try testFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = ClipboardLocalFile.load(directory: dir)
    #expect(files.map(\.entry.name) == ["a.txt", "b.bin"])
    #expect(files.map(\.entry.size) == [UInt64(a.count), UInt64(b.count)])

    let h = FilesHarness()
    h.ready()
    h.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(files: files), takenAt: 2_000))
    #expect(h.take() == ClipboardWire.formatList([0xC08C, 0xC08D]))
    h.engine.receive(H.request(0xC08C, index: 0))
    let descriptor = try ClipboardFileGroup.build(files.map(\.entry))
    #expect(h.take() == ClipboardWire.dataResponse(format: 0xC08C, data: descriptor))
    h.engine.receive(H.request(0xC08D, index: 1))
    #expect(h.take() == ClipboardWire.dataResponse(format: 0xC08D, data: b))
    h.engine.receive(H.request(0xC08D, index: 0))
    #expect(h.take() == ClipboardWire.dataResponse(format: 0xC08D, data: a))
    h.engine.receive(H.request(0xC08D, index: 7))
    #expect(h.take() == ClipboardWire.dataFailure)
    let lines = h.events.map(\.description)
    #expect(lines.contains("← DATA_REQUEST 0xC08D flags 0x0001 index 1 → DATA_RESPONSE \(b.count) B (\"b.bin\")"))
    #expect(lines.contains("← DATA_REQUEST 0xC08D flags 0x0001 index 7 → failure (index out of range (2 files))"))

    // Without the files switch the same snapshot offers nothing (default behaviour unchanged).
    let off = FilesHarness(maxVersion: 3, files: false)
    off.ready()
    off.engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(files: files), takenAt: 2_000))
    #expect(off.take().isEmpty)
    #expect(off.engine.localFormats.isEmpty)
}

// MARK: Engine: session → Mac (docs/75 §6, E3)

@Test func hostFileGroupIsFetchedByIndex() throws {
    let h = FilesHarness()
    h.ready()
    h.engine.receive(H.list([0xC08C, 0xC08D, 15]))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC08C, index: 0))
    let entries = [ClipboardFileEntry(name: "a.txt", size: 3), ClipboardFileEntry(name: "sub", size: 0, isDirectory: true),
                   ClipboardFileEntry(name: "sub\\b.bin", size: 2)]
    h.engine.receive(H.response(0xC08C, try ClipboardFileGroup.build(entries)))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC08D, index: 0))
    h.engine.receive(H.response(0xC08D, Data("abc".utf8)))
    #expect(h.take() == ClipboardWire.dataRequest(format: 0xC08D, index: 2))   // the directory is skipped
    h.engine.receive(H.response(0xC08D, Data([1, 2])))
    var contents: [(UInt32, String?, Data)] = []
    for e in h.events { if case .hostFileContents(let i, let n, let d) = e { contents.append((i, n, d)) } }
    #expect(contents.map(\.0) == [0, 2])
    #expect(contents.map(\.1) == ["a.txt", "sub\\b.bin"])
    #expect(contents.map(\.2) == [Data("abc".utf8), Data([1, 2])])
    #expect(h.events.contains { if case .hostFileGroup(let e) = $0 { return e.count == 3 }; return false })
    #expect(!h.engine.isFetching)

    // Descriptor only (selection check before a delete).
    h.engine.fetchFileContents = false
    h.engine.receive(H.list([0xC08C, 0xC08D]))
    _ = h.take()
    h.engine.receive(H.response(0xC08C, try ClipboardFileGroup.build([ClipboardFileEntry(name: "x", size: 0, isDirectory: true)])))
    #expect(h.take().isEmpty && !h.engine.isFetching)

    // Default build: file formats are not fetched.
    let off = FilesHarness(maxVersion: 3, files: false)
    off.ready()
    off.engine.receive(H.list([0xC08C, 0xC08D]))
    #expect(off.take().isEmpty)
}

@Test func wireTraceShowsBothDirections() {
    let h = FilesHarness(trace: true)
    h.engine.receive(H.init14)
    let lines = h.events.map(\.description)
    #expect(lines.contains("trace ← VC 6 B: 01 00 01 00 04 00"))
    #expect(lines.contains("trace ← msg 01 00 01 00 04 00"))
    #expect(lines.contains("trace → VC 12 B: 02 00 00 00 04 00 00 00 00 00 00 00"))
    // A DATA_RESPONSE message shows its header and at most 64 payload bytes.
    h.events = []
    h.engine.receive(H.formatNames())
    h.engine.receive(H.response(13, Data(repeating: 0x41, count: 200)))
    let msg = h.events.map(\.description).first { $0.hasPrefix("trace ← msg 05 00") }
    #expect(msg.map { $0.split(separator: " ").count - 3 } == 10 + 64)
    // Off by default.
    let quiet = FilesHarness(maxVersion: 3, files: false)
    quiet.engine.receive(H.init14)
    #expect(!quiet.events.contains { if case .trace = $0 { return true }; return false })
}
