import Testing
import Foundation
@testable import ICAKit

// D90: clipboard file copy in the app, offline. Synthetic data and neutral names only: the Mac snapshot (folders,
// names, caps, lazy reads), the session → Mac staging plan (name rules), staging folders and their cleanup, the
// pasteboard's bounded wait, and the CTXGDT error paths (stall, cancel, size lies, unreadable files, pacing).

private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
private func msg(_ cmd: UInt8, _ seq: UInt32, _ body: [UInt8]) -> [UInt8] { [cmd] + u32(seq) + u16(UInt16(7 + body.count)) + body }

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipbridge-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A GDT engine with parsed output and a manual clock for `scheduleAfter`.
private final class GDTHarness {
    let engine = GDTEngine()
    var out: [GDTMessage] = []
    var events: [GDTFileEvent] = []
    var updates: [GDTFetchUpdate] = []
    var timers: [(TimeInterval, () -> Void)] = []
    var backlog = 0
    init(scheduled: Bool = false) {
        engine.output = { [unowned self] in if case .channel(let d) = $0 { out.append(GDTMessage([UInt8](d))!) } }
        engine.onEvent = { [unowned self] in if case .file(let e) = $0 { events.append(e) } }
        if scheduled {
            engine.files.scheduleAfter = { [unowned self] delay, block in timers.append((delay, block)) }
            engine.files.backlog = { [unowned self] in backlog }
        }
    }
    func host(_ bytes: [UInt8]) { engine.receive(Data(bytes)) }
    func take() -> [GDTMessage] { defer { out = [] }; return out }
    /// Runs the timers queued so far (one round).
    func fire() { let t = timers; timers = []; for (_, b) in t { b() } }
    func observe(_ u: GDTFetchUpdate) { updates.append(u) }
    func descriptor(seq: UInt32, dataObj: UInt64, _ entries: [ClipboardFileEntry]) throws {
        let fgd = try [UInt8](ClipboardFileGroup.build(entries))
        host(msg(0x15, seq, u64(dataObj) + u32(UInt32(fgd.count))))
        host(msg(0x16, seq, u64(dataObj) + u16(UInt16(fgd.count)) + fgd))
        host(msg(0x17, seq, u64(dataObj) + u32(0) + u32(1)))
    }
}

@Suite struct ClipboardMacSnapshotTests {
    @Test func foldersBecomeRelativeEntriesAndOddItemsAreLeftOut() throws {
        let dir = try tempDir("snap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let top = dir.appendingPathComponent("Folder One")
        try fm.createDirectory(at: top.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: top.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 3000).write(to: top.appendingPathComponent("inner/b.bin"))
        try Data("x".utf8).write(to: top.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: top.appendingPathComponent("._a.txt"))
        try fm.createSymbolicLink(at: top.appendingPathComponent("link"), withDestinationURL: top.appendingPathComponent("a.txt"))
        let locked = top.appendingPathComponent("locked.txt")
        try Data("secret".utf8).write(to: locked)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o600) }
        let single = dir.appendingPathComponent("what?.txt")
        try Data("one".utf8).write(to: single)

        let s = ClipboardFileSnapshot.make(urls: [top, single])
        #expect(s.refused == nil)
        #expect(s.entries.map(\.name) == ["Folder One", "Folder One\\a.txt", "Folder One\\inner", "Folder One\\inner\\b.bin", "what_.txt"])
        #expect(s.entries.map(\.isDirectory) == [true, false, true, false, false])
        #expect(s.totalBytes == 5 + 3000 + 3)
        #expect(Set(s.skipped.map(\.why)) == ["a symbolic link or alias", "not readable"])
        #expect(Set(s.skipped.map(\.name)) == ["Folder One/link", "Folder One/locked.txt"])
        // The descriptor round-trips, folder before its contents.
        let parsed = try ClipboardFileGroup.parse(ClipboardFileGroup.build(s.entries))
        #expect(parsed.map(\.name) == s.entries.map(\.name) && parsed[0].isDirectory)
        // Lazy reads by path; a directory reads nothing.
        #expect(s.files[1].read(offset: 1, length: 3) == Data("lph".utf8))
        #expect(s.files[3].read()?.count == 3000)
        #expect(s.files[0].read() == nil && !s.files[0].isReadable)
        #expect(s.files[1].isReadable)
    }

    @Test func aSwappedOrRemovedFileIsNotServed() throws {
        let dir = try tempDir("swap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.txt")
        try Data("original".utf8).write(to: url)
        let s = ClipboardFileSnapshot.make(urls: [url])
        let file = try #require(s.files.first)
        #expect(file.read() == Data("original".utf8))
        // Replaced by another file of the same name: other inode, refused.
        try FileManager.default.removeItem(at: url)
        try Data("replaced".utf8).write(to: url)
        #expect(file.read() == nil && !file.isReadable)
        try FileManager.default.removeItem(at: url)
        #expect(file.read() == nil)
    }

    @Test func capsRefuseTheWholeSetAndNamesStayUnique() throws {
        let dir = try tempDir("caps")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a_b", "a:b", "con.txt", "x.txt"] { try Data("1234".utf8).write(to: dir.appendingPathComponent(name)) }
        let s = ClipboardFileSnapshot.make(urls: [dir])
        let folder = dir.lastPathComponent
        // "a:b" becomes "a_b" and so the real "a_b" becomes "a_b (2)"; CON is a Windows device name.
        #expect(s.entries.map(\.name) == [folder] + ["a_b", "a_b (2)", "_con.txt", "x.txt"].map { folder + "\\" + $0 })
        var limits = ClipboardFileSnapshot.Limits()
        limits.maxEntries = 3
        let many = ClipboardFileSnapshot.make(urls: [dir], limits: limits)
        #expect(many.refused == .tooMany(3) && many.files.isEmpty)
        limits = ClipboardFileSnapshot.Limits()
        limits.maxTotal = 10
        let big = ClipboardFileSnapshot.make(urls: [dir], limits: limits)
        #expect(big.refused == .tooLarge(10) && big.files.isEmpty)
    }
}

@Suite struct ClipboardStagingPlanTests {
    @Test func windowsNamesBecomeSafeMacNames() throws {
        #expect(ClipboardStagingPlan.macComponent("a:b/c") == "a_b_c")
        #expect(ClipboardStagingPlan.macComponent("tab\tand\u{7F}") == "tab_and_")
        #expect(ClipboardStagingPlan.macComponent("..") == nil && ClipboardStagingPlan.macComponent(".") == nil)
        #expect(ClipboardStagingPlan.macComponent("") == nil)
        let long = String(repeating: "ü", count: 200) + ".txt"
        let cut = try #require(ClipboardStagingPlan.macComponent(long))
        #expect(cut.utf8.count <= 255 && cut.hasSuffix(".txt"))
        #expect(try ClipboardStagingPlan.components("dir\\sub\\f.txt") == ["dir", "sub", "f.txt"])
        #expect(try ClipboardStagingPlan.components("../x") == [".._x"])   // "/" is no separator: no traversal
        for bad in ["..\\x", "dir\\..\\x", "\\x", "\\\\server\\share\\x", "C:\\x", "c:x", "dir\\\\x", "dir\\"] {
            #expect(throws: ClipboardStagingPlan.Failure.self) { try ClipboardStagingPlan.components(bad) }
        }
    }

    @Test func foldersFilesAndCollisions() throws {
        let entries = [
            ClipboardFileEntry(name: "Pics", size: 0, isDirectory: true),
            ClipboardFileEntry(name: "Pics\\one.png", size: 10),
            ClipboardFileEntry(name: "pics\\sub\\two.png", size: 20),   // other case, implicit "sub"
            ClipboardFileEntry(name: "note.txt", size: 3),
            ClipboardFileEntry(name: "NOTE.txt", size: 4),               // collides on APFS
            ClipboardFileEntry(name: "loose\\three.bin", size: 5),       // folder without its own entry
            ClipboardFileEntry(name: "Pics", size: 0, isDirectory: true), // listed twice
        ]
        let plan = try ClipboardStagingPlan.make(entries)
        #expect(plan.items.map(\.path) == ["Pics", "note.txt", "NOTE 2.txt", "loose"])
        #expect(plan.items.map(\.isDirectory) == [true, false, false, true])
        #expect(plan.items[0].files == [1, 2] && plan.items[3].files == [5])
        #expect(plan.directories == ["Pics", "Pics/sub", "loose"])
        #expect(plan.files == [1: "Pics/one.png", 2: "Pics/sub/two.png", 3: "note.txt", 4: "NOTE 2.txt", 5: "loose/three.bin"])
        #expect(plan.totalBytes == 42)
    }

    @Test func refusals() {
        #expect(throws: ClipboardStagingPlan.Failure.empty) { try ClipboardStagingPlan.make([]) }
        #expect(throws: ClipboardStagingPlan.Failure.unsafeName("..\\etc")) { try ClipboardStagingPlan.make([ClipboardFileEntry(name: "..\\etc", size: 1)]) }
        // A path below a file.
        #expect(throws: ClipboardStagingPlan.Failure.self) {
            try ClipboardStagingPlan.make([ClipboardFileEntry(name: "f", size: 1), ClipboardFileEntry(name: "f\\g", size: 1)])
        }
        let three = (0..<3).map { ClipboardFileEntry(name: "f\($0)", size: 100) }
        #expect(throws: ClipboardStagingPlan.Failure.tooMany(2)) { try ClipboardStagingPlan.make(three, maxEntries: 2) }
        #expect(throws: ClipboardStagingPlan.Failure.tooLarge(250)) { try ClipboardStagingPlan.make(three, maxTotal: 250) }
    }
}

@Suite struct ClipboardStagingAreaTests {
    @Test func foldersAreCreatedPrivateAndCleanedUp() throws {
        let base = try tempDir("area").appendingPathComponent("clipboard-files")
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let area = ClipboardStagingArea(base: base, pid: 4242)
        let plan = try ClipboardStagingPlan.make([ClipboardFileEntry(name: "d\\x.txt", size: 1)])
        let first = try area.newFolder(for: plan)
        let second = try area.newFolder(for: plan)
        #expect(first.lastPathComponent.hasPrefix("4242-") && first != second)
        let attrs = try FileManager.default.attributesOfItem(atPath: first.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("d").path))
        #expect(getxattr(first.appendingPathComponent("d").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        // The next copy keeps only the newest; quit removes all of ours.
        area.removeOwn(except: second)
        #expect(!FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
        // Launch: folders of processes that are gone go, running ones stay.
        for name in ["1111-gone", "2222-alive", "junk"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        area.removeStale { $0 == 2222 }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: base.path))
        #expect(left == ["2222-alive", second.lastPathComponent])
        area.removeOwn()
        #expect(area.ownFolders.isEmpty)
    }
}

@Suite struct ClipboardFileWaitTests {
    private func plan() throws -> ClipboardStagingPlan {
        try ClipboardStagingPlan.make([ClipboardFileEntry(name: "a.txt", size: 2), ClipboardFileEntry(name: "d\\b.txt", size: 3),
                                       ClipboardFileEntry(name: "d\\c.txt", size: 4)])
    }

    @Test func itemsBecomeReadyAsTheirFilesArrive() throws {
        let p = try plan()
        let folder = URL(fileURLWithPath: "/nonexistent-staging")
        let w = ClipboardFileWait(plan: p, folder: folder, deadline: Date().addingTimeInterval(10))
        #expect(w.targets[1]?.path == "/nonexistent-staging/d/b.txt")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            w.update(.progress(index: 0, bytes: 1))
            w.update(.file(index: 0, url: folder.appendingPathComponent("a.txt"), bytes: 2))
        }
        var ticks = 0
        #expect(w.wait(item: 0, interval: 0.01) { ticks += 1 } == .ready(folder.appendingPathComponent("a.txt")))
        // The folder: one file fails, the other arrives → partial.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            w.update(.fileFailed(index: 1, why: "test"))
            w.update(.file(index: 2, url: folder.appendingPathComponent("d/c.txt"), bytes: 4))
            w.update(.done(files: 2))
        }
        #expect(w.wait(item: 1) == .partial(w.url(item: 1), failed: 1))
        #expect(w.isFinished && w.progress == (6, 9))
    }

    @Test func failuresAndTimeoutsEndTheWait() throws {
        let p = try plan()
        let w = ClipboardFileWait(plan: p, folder: URL(fileURLWithPath: "/x"), deadline: Date().addingTimeInterval(10))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { w.update(.failed("host error")) }
        #expect(w.wait(item: 1) == .failed("host error"))
        #expect(w.failureReason == "host error")
        let late = ClipboardFileWait(plan: p, folder: URL(fileURLWithPath: "/x"), deadline: Date().addingTimeInterval(0.05))
        let started = Date()
        #expect(late.wait(item: 0) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 2)
        // `done` without a file: that file failed.
        let short = ClipboardFileWait(plan: p, folder: URL(fileURLWithPath: "/x"), deadline: Date().addingTimeInterval(10))
        short.update(.done(files: 0))
        #expect(short.wait(item: 0) == .failed("not received"))
        #expect(short.wait(item: 9) == .failed("no such item"))
    }
}

@Suite struct GDTFetchModeTests {
    private let entries = [ClipboardFileEntry(name: "a.txt", size: 5, writeTime: Date(timeIntervalSince1970: 1_700_000_000)),
                           ClipboardFileEntry(name: "d", size: 0, isDirectory: true),
                           ClipboardFileEntry(name: "d\\b.bin", size: 3)]

    /// Serves file `data` on `stream` for the open request just sent.
    private func serve(_ h: GDTHarness, open: GDTMessage, stream: UInt64, _ data: [UInt8], extra: [UInt8] = []) {
        h.host(msg(0x05, open.seq, u32(0) + u64(stream)))
        var offset = 0
        let all = data + extra
        while true {
            let sent = h.take()
            guard let r = sent.first, r.command == 0x0C else { h.out = sent; break }
            let n = min(Int(LEBytes.u32(r.body, 8)), all.count - offset)
            h.host(msg(0x0D, r.seq, u64(stream) + u32(UInt32(n))))
            if n > 0 { h.host(msg(0x0E, r.seq, u64(stream) + u16(UInt16(n)) + Array(all[offset..<offset + n]))) }
            h.host(msg(0x0F, r.seq, u64(stream) + u32(n == 0 ? 1 : 0)))
            offset += n
        }
    }

    @Test func descriptorOnlyThenFilesIntoTargets() throws {
        let dir = try tempDir("targets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = GDTHarness()
        h.engine.files.fetch(.descriptor, systemFormat: 0xC0AA) { h.observe($0) }
        let get = try #require(h.take().first)
        try h.descriptor(seq: get.seq, dataObj: LEBytes.u64(get.body, 0), entries)
        #expect(h.take().isEmpty)   // no OpenStream for a descriptor fetch
        #expect(h.updates == [.group(try ClipboardFileGroup.parse(ClipboardFileGroup.build(entries))), .done(files: 0)])

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
        h.updates = []
        let targets = [0: dir.appendingPathComponent("a.txt"), 2: dir.appendingPathComponent("d/b.bin")]
        h.engine.files.fetch(.files(targets: targets, expect: entries), systemFormat: 0xC0AA) { h.observe($0) }
        let get2 = try #require(h.take().first)
        try h.descriptor(seq: get2.seq, dataObj: LEBytes.u64(get2.body, 0), entries)
        let open0 = try #require(h.take().first)
        #expect(open0.command == 0x04 && LEBytes.u32(open0.body, 49) == 0)
        serve(h, open: open0, stream: 0x51, Array("hello".utf8))
        let rel0 = try #require(h.take().last)
        h.host(msg(0x07, rel0.seq, u64(0x51)))
        let open2 = try #require(h.take().first)
        #expect(open2.command == 0x04 && LEBytes.u32(open2.body, 49) == 2)
        serve(h, open: open2, stream: 0x52, [1, 2, 3])
        let rel2 = try #require(h.take().last)
        h.host(msg(0x07, rel2.seq, u64(0x52)))
        #expect(h.take().isEmpty)
        #expect(FileManager.default.contents(atPath: targets[0]!.path) == Data("hello".utf8))
        #expect(FileManager.default.contents(atPath: targets[2]!.path) == Data([1, 2, 3]))
        #expect(h.updates.last == .done(files: 2))
        #expect(h.updates.contains(.progress(index: 2, bytes: 3)))
    }

    @Test func filesModeWritesQuarantinedFilesAndChecksSizes() throws {
        let dir = try tempDir("files")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
        let h = GDTHarness()
        let targets = [0: dir.appendingPathComponent("a.txt"), 2: dir.appendingPathComponent("d/b.bin")]
        h.engine.files.fetch(.files(targets: targets, expect: nil), systemFormat: 0xC0AA) { h.observe($0) }
        let get = try #require(h.take().first)
        try h.descriptor(seq: get.seq, dataObj: 9, entries)
        var sent = h.take()
        // File 0: exact.
        serve(h, open: sent[0], stream: 0x61, Array("hello".utf8))
        let rel0 = try #require(h.out.last)
        #expect(rel0.command == 0x06)
        h.out = []
        h.host(msg(0x07, rel0.seq, u64(0x61)))
        // File 2 (the directory has no stream): the host sends more than the 3 bytes it announced.
        sent = h.take()
        #expect(sent.count == 1 && LEBytes.u32(sent[0].body, 49) == 2)
        serve(h, open: sent[0], stream: 0x62, [1, 2, 3], extra: [4])
        let rel2 = try #require(h.out.last)
        #expect(rel2.command == 0x06 && rel2.handle == 0x62)
        h.out = []
        h.host(msg(0x07, rel2.seq, u64(0x62)))
        #expect(h.take().isEmpty)
        let a = dir.appendingPathComponent("a.txt").path
        #expect(FileManager.default.contents(atPath: a) == Data("hello".utf8))
        #expect(getxattr(a, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        #expect((try FileManager.default.attributesOfItem(atPath: a)[.modificationDate] as? Date)?.timeIntervalSince1970 == 1_700_000_000)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("d/b.bin").path))   // partial file removed
        #expect(h.updates.contains(.file(index: 0, url: targets[0]!, bytes: 5)))
        #expect(h.updates.contains { if case .fileFailed(2, let why) = $0 { return why.contains("more than") }; return false })
        #expect(h.updates.last == .done(files: 1))
    }

    @Test func aChangedHostClipboardFailsTheFetch() throws {
        let h = GDTHarness()
        h.engine.files.fetch(.files(targets: [0: URL(fileURLWithPath: "/tmp/never")], expect: entries), systemFormat: 1) { h.observe($0) }
        let get = try #require(h.take().first)
        try h.descriptor(seq: get.seq, dataObj: 1, [ClipboardFileEntry(name: "other.txt", size: 5)])
        #expect(h.take().isEmpty)
        #expect(h.updates == [.failed("the host clipboard changed (another file group)")])
        #expect(!h.engine.files.isFetching)
    }

    @Test func stallTimeoutReleasesTheOpenStream() throws {
        let dir = try tempDir("stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = GDTHarness(scheduled: true)
        h.engine.files.fetch(.files(targets: [0: dir.appendingPathComponent("a.txt")], expect: nil), systemFormat: 1) { h.observe($0) }
        let get = try #require(h.take().first)
        try h.descriptor(seq: get.seq, dataObj: 1, entries)
        let open = try #require(h.take().first)
        h.host(msg(0x05, open.seq, u32(0) + u64(0x71)))
        let read = try #require(h.take().first)
        #expect(read.command == 0x0C)
        h.host(msg(0x0D, read.seq, u64(0x71) + u32(5)))   // the begin comes, then nothing
        // Answers came since the timers were armed: they re-arm; the next round with no answer fails.
        h.fire()
        #expect(h.updates.allSatisfy { if case .failed = $0 { return false }; return true })
        h.fire()
        #expect(h.updates.last == .failed("no answer from the host within 20 s"))
        let release = try #require(h.take().last)
        #expect(release.command == 0x06 && release.handle == 0x71)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
        // Late answers to the dead fetch are dropped quietly.
        h.host(msg(0x0F, read.seq, u64(0x71) + u32(0)))
        h.host(msg(0x07, release.seq, u64(0x71)))
        #expect(!h.events.contains { if case .unexpected = $0 { return true }; return false })
    }

    @Test func cancelWhileOpeningReleasesTheLateStream() throws {
        let dir = try tempDir("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = GDTHarness()
        h.engine.files.fetch(.files(targets: [0: dir.appendingPathComponent("a.txt")], expect: nil), systemFormat: 1) { h.observe($0) }
        let get = try #require(h.take().first)
        try h.descriptor(seq: get.seq, dataObj: 1, entries)
        let open = try #require(h.take().first)
        h.engine.files.cancelFetch("the host clipboard changed")
        #expect(h.updates.last == .failed("the host clipboard changed"))
        #expect(h.take().isEmpty)
        h.host(msg(0x05, open.seq, u32(0) + u64(0x81)))
        let release = h.take()
        #expect(release.count == 1 && release[0].command == 0x06 && release[0].handle == 0x81)
        // A newer fetch replaces one in progress.
        h.engine.files.fetch(.descriptor, systemFormat: 1) { h.observe($0) }
        h.engine.files.fetch(.descriptor, systemFormat: 1) { h.observe($0) }
        #expect(h.updates.last == .failed("replaced by a newer fetch"))
    }

    @Test func aHostErrorStatusFailsOneFileOnly() throws {
        let dir = try tempDir("status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = GDTHarness()
        let two = [ClipboardFileEntry(name: "x", size: 2), ClipboardFileEntry(name: "y", size: 1)]
        let targets = [0: dir.appendingPathComponent("x"), 1: dir.appendingPathComponent("y")]
        h.engine.files.fetch(.files(targets: targets, expect: nil), systemFormat: 1) { h.observe($0) }
        let get = try #require(h.take().first)
        try h.descriptor(seq: get.seq, dataObj: 1, two)
        let open0 = try #require(h.take().first)
        h.host(msg(0x05, open0.seq, u32(0x8007_0005) + u64(0)))   // access denied, no stream
        let open1 = try #require(h.take().first)
        #expect(LEBytes.u32(open1.body, 49) == 1)
        serve(h, open: open1, stream: 0x91, [9])
        let rel = try #require(h.take().last)
        h.host(msg(0x07, rel.seq, u64(0x91)))
        #expect(h.updates.contains { if case .fileFailed(0, _) = $0 { return true }; return false })
        #expect(h.updates.last == .done(files: 1))
        #expect(!FileManager.default.fileExists(atPath: targets[0]!.path))
    }
}

@Suite struct GDTServeTests {
    private let entries = [ClipboardFileEntry(name: "big.bin", size: 200_000)]
    private let data = Data((0..<200_000).map { UInt8($0 % 253) })

    @Test func dataIsPacedByTheBacklogAndRequestsWait() throws {
        let h = GDTHarness(scheduled: true)
        h.engine.files.offer(GDTFileSource(entries: entries, contents: [data]))
        h.host(msg(0x04, 2, u32(0x34) + [UInt8](repeating: 0, count: 49)))
        let stream = LEBytes.u64(h.take()[0].body, 4)
        h.backlog = 3 << 20   // over the 2 MiB limit after the first slice
        h.host(msg(0x0C, 4, u64(stream) + u32(1_000_000)))
        // A Seek and a Release arrive while the Read is being answered: they wait.
        h.host(msg(0x0A, 6, u64(stream) + u64(0) + [0]))
        var got = h.take()
        #expect(got.first?.command == 0x0D && LEBytes.u32(got[0].body, 8) == 200_000)
        #expect(!got.contains { $0.command == 0x0F || $0.command == 0x0B })
        let firstSlice = got.filter { $0.command == 0x0E }.reduce(0) { $0 + Int(LEBytes.u16($1.body, 8)) }
        #expect(firstSlice == h.engine.files.serveSlice)
        h.fire()
        #expect(h.take().isEmpty)   // still high
        h.backlog = 0
        h.fire()
        got = h.take()
        #expect(got.map(\.command).suffix(2) == [0x0F, 0x0B])   // end, then the waiting Seek's reply
        #expect(got.allSatisfy { $0.bytes.count <= 1400 })
        #expect(h.engine.files.servedFiles == [0] && !h.engine.files.isServing)
    }

    @Test func unreadableFilesAreRefusedWithAnErrorStatus() {
        let h = GDTHarness()
        var readable = true
        h.engine.files.offer(GDTFileSource(entries: [ClipboardFileEntry(name: "f", size: 10)], check: { _ in readable }) { _, _, _ in nil })
        h.host(msg(0x04, 2, u32(0x34) + [UInt8](repeating: 0, count: 49)))
        let open = h.take()
        #expect(LEBytes.u32(open[0].body, 0) == 0)
        let stream = LEBytes.u64(open[0].body, 4)
        h.host(msg(0x0C, 4, u64(stream) + u32(10)))
        let read = h.take()
        #expect(read.map(\.command) == [0x0D, 0x0F] && LEBytes.u32(read[0].body, 8) == 0)
        #expect(LEBytes.u32(read[1].body, 8) == GDTWire.statusAccessDenied)
        readable = false
        h.host(msg(0x04, 6, u32(0x34) + [UInt8](repeating: 0, count: 49)))
        #expect(LEBytes.u32(h.take()[0].body, 0) == GDTWire.statusAccessDenied)
        #expect(h.events.contains { if case .serveFailed(0, _) = $0 { return true }; return false })
    }

    @Test func aFileThatShrinksEndsWithAFailure() {
        let h = GDTHarness()
        h.engine.files.serveSlice = 4
        var calls = 0
        h.engine.files.offer(GDTFileSource(entries: [ClipboardFileEntry(name: "f", size: 10)]) { _, _, n in
            calls += 1
            return calls == 1 ? Data(repeating: 1, count: n) : Data()
        })
        h.host(msg(0x04, 2, u32(0x34) + [UInt8](repeating: 0, count: 49)))
        let stream = LEBytes.u64(h.take()[0].body, 4)
        h.host(msg(0x0C, 4, u64(stream) + u32(10)))
        let read = h.take()
        #expect(read.first?.command == 0x0D && LEBytes.u32(read[0].body, 8) == 10)
        #expect(read.last?.command == 0x0F && LEBytes.u32(read.last!.body, 8) == GDTWire.statusFail)
        #expect(h.engine.files.servedFiles.isEmpty)
    }
}

@Suite struct ClipboardFilesOverGDTTests {
    private static func list(_ ids: [UInt16]) -> Data { Data(u16(3) + u16(3) + ids.flatMap { u16($0) + u32(0) } + u16(0)) }
    private static let names: [(UInt16, String)] = [(0xC08B, "HTML Format"), (0xC08C, "FileGroupDescriptorW"), (0xC08D, "FileContents")]

    private func ready(_ engine: ClipboardEngine) {
        engine.receive(Data([0x01, 0x00, 0x01, 0x00, 0x04, 0x00]))
        var b = u16(8) + u16(0)
        for (id, name) in Self.names { b += u16(id) + u32(UInt32(name.utf8.count + 1)) + Array(name.utf8) + [0] }
        engine.receive(Data(b + [0, 0, 0, 0, 0, 0]))
    }

    @Test func aHostFileGroupIsLeftToCTXGDT() {
        var config = ClipboardEngine.Config()
        config.maxVersion = 4
        config.files = true
        let engine = ClipboardEngine(config: config)
        var writes: [Data] = []
        var events: [ClipboardEngine.Event] = []
        engine.output = { if case .channel(let d) = $0 { writes.append(d) } }
        engine.onEvent = { events.append($0) }
        engine.filesOverGDT = true
        ready(engine)
        writes = []
        // Files plus text in one host list: nothing on CTXCLIP, the group goes to CTXGDT.
        engine.receive(Self.list([0xC08C, 0xC08D, 13]))
        #expect(writes.isEmpty && !engine.isFetching)
        #expect(events.contains { if case .hostFileGroupListed(0xC08C) = $0 { return true }; return false })
        // A list without files is fetched as before.
        engine.receive(Self.list([13]))
        #expect(writes.first.map { [UInt8]($0.prefix(6)) } == [0x04, 0x00, 0x00, 0x00, 0x0D, 0x00])
    }

    @Test func announcedFilesAreHandedToCTXGDT() throws {
        let dir = try tempDir("announce")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("f.txt"))
        var config = ClipboardEngine.Config()
        config.maxVersion = 4
        config.files = true
        let engine = ClipboardEngine(config: config)
        engine.output = { _ in }
        var offered: [[String]] = []
        engine.localFilesChanged = { offered.append($0.map(\.entry.name)) }
        ready(engine)
        let snapshot = ClipboardFileSnapshot.make(urls: [dir.appendingPathComponent("f.txt")])
        engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "f.txt", files: snapshot.files), takenAt: ClipboardClock.now()))
        #expect(engine.localFormats == [13, 0xC08C, 0xC08D])
        engine.announceLocal(ClipboardSnapshot(content: nil, takenAt: ClipboardClock.now()))
        #expect(offered == [["f.txt"], []])
    }

    @Test func hostWritesFollowTheSyncRules() {
        final class Board: ClipboardPasteboard {
            var changeCount = 1
            func readContent() -> ClipboardContent? { nil }
            func writeContent(_ content: ClipboardContent) -> Int { changeCount += 1; return changeCount }
        }
        let board = Board()
        let sync = ClipboardSync(pasteboard: board)
        sync.channelReady()
        var wrote = 0
        #expect(sync.hostWrite(summary: "files") { wrote += 1; board.changeCount += 1; return board.changeCount })
        #expect(wrote == 1 && sync.ownWrite == board.changeCount)
        #expect(!sync.check("poll"))   // our own write is not announced back
        board.changeCount += 1         // the user copies on the Mac meanwhile
        #expect(!sync.hostWrite(summary: "files") { wrote += 1; return 0 })
        #expect(wrote == 1)
        #expect(!sync.hostWrite(summary: "files", echo: true) { wrote += 1; return 0 })
    }
}
