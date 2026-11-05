import Testing
import Foundation
@testable import ICAKit

/// A fresh temp folder with a shared root inside it and a sibling "outside" folder holding a secret.
private final class TempTree {
    let base: URL
    let root: URL
    let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cdm-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Shared", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        for d in [root, outside] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func file(_ relative: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func link(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(relative).path, withDestinationPath: destination)
    }

    func contents(_ relative: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    func quarantine(_ relative: String) -> String? {
        let path = root.appendingPathComponent(relative).path
        let n = getxattr(path, CDMPOSIXFileSystem.quarantineName, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: n)
        _ = getxattr(path, CDMPOSIXFileSystem.quarantineName, &buffer, n, 0, XATTR_NOFOLLOW)
        return String(decoding: buffer, as: UTF8.self)
    }
}

private func path(_ s: String) -> CDMPath { CDMPath(s.split(separator: "/").map(String.init)) }

private func fsError(_ body: () throws -> Void) -> CDMFSError? {
    do { try body(); return nil } catch { return error as? CDMFSError ?? .io(-1) }
}

/// Serialized: the CDM tests are CPU-heavy (debug-build string work) and would otherwise starve the
/// timing-based CGP tests running in parallel.
@Suite(.serialized) struct CDMFileSystemTests {
    @Test func cdmPOSIXSymlinksOutAreRefused() throws {
        let t = try TempTree()
        let fs = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        try t.file("inside.txt", "ok")
        try t.link("outDir", to: t.outside.path)                         // absolute, out
        try t.link("outRel", to: "../outside")                           // relative, out
        try t.link("outFile", to: t.outside.appendingPathComponent("secret.txt").path)
        try t.link("dangling", to: "nowhere/at/all")
        try t.link("upAndBack", to: "../Shared/inside.txt")              // leaves by name, lands inside: allowed
        for name in ["outDir", "outRel", "outFile", "dangling"] {
            #expect(fsError { _ = try fs.info(path(name)) } == .escapes, "\(name)")
        }
        #expect(fsError { _ = try fs.open(path("outDir/secret.txt"), .existing(write: false, truncate: false)) } == .escapes)
        #expect(fsError { _ = try fs.open(path("outRel/secret.txt"), .existing(write: false, truncate: false)) } == .escapes)
        #expect(fsError { _ = try fs.open(path("outFile"), .existing(write: true, truncate: false)) } == .escapes)
        #expect(fsError { _ = try fs.open(path("outDir/new.txt"), .createNew) } == .escapes)
        #expect(fsError { _ = try fs.list(path("outDir")) } == .escapes)
        #expect(fsError { try fs.makeDirectory(path("outRel/sub")) } == .escapes)
        #expect(fsError { try fs.rename(path("inside.txt"), to: path("outDir/stolen.txt")) } == .escapes)
        #expect(fsError { try fs.removeFile(path("outDir/secret.txt")) } == .escapes)
        #expect(fsError { try fs.setAttributes(path("outFile"), readOnly: true, hidden: false) } == .escapes)
        // Listing leaves out what it cannot follow; the inside link is listed as the file it points to.
        let names = try fs.list(.root).map(\.name).sorted()
        #expect(names == ["inside.txt", "upAndBack"])
        let file = try fs.open(path("upAndBack"), .existing(write: false, truncate: false))
        #expect(try file.read(at: 0, count: 10) == Data("ok".utf8))
        file.close()
        // Nothing outside changed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.outside.path) == ["secret.txt"])
        #expect(try String(contentsOf: t.outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "secret")
    }

    @Test func cdmPOSIXSymlinkedRootAndInsideLinks() throws {
        let t = try TempTree()
        try t.file("sub/a.txt", "A")
        try t.link("subLink", to: "sub")
        let alias = t.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: t.root.path)
        let fs = try CDMPOSIXFileSystem(root: alias, readOnly: false)
        #expect(fs.rootPath.hasSuffix("/Shared"))
        let f = try fs.open(path("subLink/a.txt"), .existing(write: false, truncate: false))
        #expect(try f.read(at: 0, count: 5) == Data("A".utf8))
        #expect(try fs.list(path("subLink")).map(\.name) == ["a.txt"])
        #expect(try fs.info(path("subLink")).isDirectory)
    }

    @Test func cdmPOSIXCaseAndNormalisationInsensitive() throws {
        let t = try TempTree()
        try t.file("Report.TXT", "r")
        try t.file("Cafe\u{301}.txt", "nfd")   // NFD on disk
        let fs = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        #expect(try fs.info(path("report.txt")).size == 1)
        #expect(try fs.info(path("REPORT.txt")).isDirectory == false)
        let f = try fs.open(path("caf\u{e9}.TXT"), .existing(write: false, truncate: false))  // NFC, other case
        #expect(try f.read(at: 0, count: 9) == Data("nfd".utf8))
        #expect(try fs.list(.root).map(\.name).contains("Caf\u{e9}.txt"))  // names out in NFC
        // Case-only rename of the same entry.
        try fs.rename(path("report.txt"), to: path("REPORT.TXT"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.root.path).contains("REPORT.TXT"))
        // A different entry is never overwritten.
        try t.file("other.txt", "o")
        #expect(fsError { try fs.rename(path("other.txt"), to: path("report.txt")) } == .exists)
        #expect(t.contents("REPORT.TXT") == "r")
    }

    @Test func cdmPOSIXQuarantineOnSessionFiles() throws {
        let t = try TempTree()
        try t.file("mine.txt", "local")
        try t.file("downloaded.txt", "dl")
        let preset = Array("0083;00000001;Safari;".utf8)
        #expect(setxattr(t.root.appendingPathComponent("downloaded.txt").path, CDMPOSIXFileSystem.quarantineName, preset, preset.count, 0, 0) == 0)
        let fs = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        // Created by the session.
        let created = try fs.open(path("new.exe"), .createNew)
        #expect(try created.write(Data("MZ".utf8), at: 0) == 2)
        created.close()
        let q = try #require(t.quarantine("new.exe"))
        #expect(q.hasPrefix("0081;") && q.hasSuffix(";ICAViewer;"))
        try fs.makeDirectory(path("App.app"))
        #expect(t.quarantine("App.app") != nil)
        // Read by the session: untouched.
        let read = try fs.open(path("mine.txt"), .existing(write: false, truncate: false))
        _ = try read.read(at: 0, count: 5)
        read.close()
        #expect(t.quarantine("mine.txt") == nil)
        // Opened for writing but never written: untouched; written: quarantined.
        let open = try fs.open(path("mine.txt"), .existing(write: true, truncate: false))
        #expect(t.quarantine("mine.txt") == nil)
        _ = try open.write(Data("L".utf8), at: 0)
        open.close()
        #expect(t.quarantine("mine.txt") != nil)
        #expect(t.contents("mine.txt") == "Local")
        // An existing value (maybe user-approved, 0x0040) is replaced by a fresh unapproved one.
        let dl = try fs.open(path("downloaded.txt"), .existing(write: true, truncate: true))
        _ = try dl.write(Data("new".utf8), at: 0)
        dl.close()
        let fresh = try #require(t.quarantine("downloaded.txt"))
        #expect(fresh.hasPrefix("0081;") && fresh.hasSuffix(";ICAViewer;"))
    }

    @Test func cdmPOSIXReadOnlyAndSpecialFiles() throws {
        let t = try TempTree()
        try t.file("doc.txt", "keep")
        try t.file("dir/x", "x")
        #expect(mkfifo(t.root.appendingPathComponent("pipe").path, 0o644) == 0)
        let ro = try CDMPOSIXFileSystem(root: t.root, readOnly: true)
        #expect(fsError { _ = try ro.open(path("doc.txt"), .existing(write: true, truncate: false)) } == .accessDenied)
        #expect(fsError { _ = try ro.open(path("doc.txt"), .existing(write: false, truncate: true)) } == .accessDenied)
        #expect(fsError { _ = try ro.open(path("n.txt"), .createNew) } == .accessDenied)
        #expect(fsError { try ro.makeDirectory(path("d")) } == .accessDenied)
        #expect(fsError { try ro.removeFile(path("doc.txt")) } == .accessDenied)
        #expect(fsError { try ro.removeDirectory(path("dir")) } == .accessDenied)
        #expect(fsError { try ro.rename(path("doc.txt"), to: path("e.txt")) } == .accessDenied)
        #expect(fsError { try ro.setAttributes(path("doc.txt"), readOnly: true, hidden: true) } == .accessDenied)
        let reader = try ro.open(path("doc.txt"), .existing(write: false, truncate: false))
        #expect(!reader.writable)
        #expect(fsError { _ = try reader.write(Data("x".utf8), at: 0) } == .accessDenied)
        #expect(t.contents("doc.txt") == "keep")
        // A FIFO is never listed or opened (and opening never blocks).
        #expect(fsError { _ = try ro.open(path("pipe"), .existing(write: false, truncate: false)) } == .unsupported)
        #expect(try ro.list(.root).map(\.name).sorted() == ["dir", "doc.txt"])

        let rw = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        // No recursive delete.
        #expect(fsError { try rw.removeDirectory(path("dir")) } == .notEmpty)
        #expect(t.contents("dir/x") == "x")
        #expect(fsError { try rw.removeFile(path("dir")) } == .isDirectory)
        #expect(fsError { try rw.removeDirectory(.root) } == .accessDenied)
        // Read-only attribute ↔ owner write bit; DOS semantics: no delete while read-only. Hidden ↔ UF_HIDDEN.
        try rw.setAttributes(path("doc.txt"), readOnly: true, hidden: true)
        let info = try rw.info(path("doc.txt"))
        #expect(info.readOnly && info.hidden)
        #expect(fsError { try rw.removeFile(path("doc.txt")) } == .accessDenied)
        #expect(fsError { _ = try rw.open(path("doc.txt"), .existing(write: true, truncate: false)) } == .accessDenied)
        try rw.setAttributes(path("doc.txt"), readOnly: false, hidden: false)
        try rw.removeFile(path("doc.txt"))
        #expect(t.contents("doc.txt") == nil)
    }

    /// The whole stack over a real folder: wire requests in, replies out, bytes on disk.
    @Test func cdmPOSIXEndToEnd() throws {
        let t = try TempTree()
        try t.file(".DS_Store", "")
        let engine = CDMEngine(config: CDMEngine.Config(fileSystem: try CDMPOSIXFileSystem(root: t.root, readOnly: false)))
        var replies: [Data] = []
        engine.output = { if case .channel(let d) = $0 { replies.append(d) } }
        func send(_ body: CDMRequestBody) -> Data? {
            let n = replies.count
            engine.receive(CDMRequest(id: 1, body).encode())
            return replies.count > n ? replies.last : nil
        }
        func status(_ reply: Data?, at offset: Int) -> UInt16 { UInt16(reply![offset]) | UInt16(reply![offset + 1]) << 8 }
        _ = send(.connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0]))
        #expect(status(send(.createDirectory(path: Data("M:\\Projekte".utf8), unknown1: 0, unknown2: 0, date: 0, time: 0)), at: 2) == 0)
        let create = send(.create(path: Data("M:\\projekte\\Bericht über.docx".utf8), access: 2, disposition: 5, attributes: 0x20,
                                  unknown1: 0, unknown2: 0))!
        let ctx = UInt16(create[2]) | UInt16(create[3]) << 8
        #expect(status(create, at: 4) == 0)
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        var offset = 0
        while offset < payload.count {
            let piece = payload.subdata(in: offset..<min(payload.count, offset + 4000))
            let r = send(.write(handle: ctx, offset: UInt32(offset), data: piece))!
            #expect(status(r, at: 6) == 0)
            offset += piece.count
        }
        _ = send(.close(handle: ctx))
        let onDisk = try Data(contentsOf: t.root.appendingPathComponent("Projekte/Bericht über.docx"))
        #expect(onDisk == payload)
        #expect(t.quarantine("Projekte/Bericht über.docx") != nil)
        // Escapes through the wire are refused before any file system call.
        #expect(status(send(.open(path: Data("M:\\..\\outside\\secret.txt".utf8), mode: 0)), at: 4) == CDMStatus.pathNotFound)
        #expect(status(send(.open(path: Data("C:\\Users\\secret.txt".utf8), mode: 0)), at: 4) == CDMStatus.pathNotFound)
        // Listing with the hidden dot-file.
        let find = send(.findFirst(path: Data("M:\\*".utf8), bufferSize: 4096, maxEntries: 50))!
        #expect(find[2] == 0xFF && find[3] == 0xFF && status(find, at: 6) == CDMStatus.noMoreFiles && find[8] == 2)
        // Not a recursive delete.
        #expect(status(send(.deleteDirectory(path: Data("M:\\Projekte".utf8))), at: 2) == CDMStatus.accessDenied)
        #expect(FileManager.default.fileExists(atPath: t.root.appendingPathComponent("Projekte/Bericht über.docx").path))
        engine.shutdown()
    }

    /// Random paths built from hostile pieces, through the wire, against a real folder: nothing outside the
    /// root is ever read, changed or created (§A.8 step 8).
    @Test func cdmPathEscapeFuzz() throws {
        let t = try TempTree()
        try t.file("sub/a.txt", "inside")
        try t.file("Long file name.txt", "long")
        try t.link("outDir", to: t.outside.path)
        try t.link("outRel", to: "../outside")
        let engine = CDMEngine(config: CDMEngine.Config(fileSystem: try CDMPOSIXFileSystem(root: t.root, readOnly: false)))
        var replies: [Data] = []
        engine.output = { if case .channel(let d) = $0 { replies.append(d) } }
        engine.receive(CDMRequest(id: 0, .connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0])).encode())
        engine.receive(CDMRequest(id: 0, .findFirst(path: Data("M:\\*".utf8), bufferSize: 4096, maxEntries: 50)).encode())
        let pieces = ["..", ".", "...", "outDir", "outRel", "sub", "a.txt", "secret.txt", "outside", "Shared", "LONGFI~1.TXT",
                      "\0", ":", "a:b", "\u{FF0E}\u{FF0E}", ".\u{200B}.", "e\u{301}", "CON", "*", "?", "%2e%2e", "~", "", " "]
        let prefixes = ["M:\\", "M:", "m:/", "C:\\", "\\\\", "\\", "", "M:\\..\\", "M:\\sub\\..\\..\\"]
        let separators = ["\\", "/", "\\\\"]
        var rng = SystemRandomNumberGenerator()
        func randomPath() -> Data {
            var s = prefixes.randomElement(using: &rng)!
            for i in 0..<Int.random(in: 0...5, using: &rng) {
                if i > 0 { s += separators.randomElement(using: &rng)! }
                s += pieces.randomElement(using: &rng)!
            }
            return Data(s.utf8)
        }
        for i in 0..<3000 {
            let a = randomPath(), b = randomPath()
            let body: CDMRequestBody
            switch i % 9 {
            case 0: body = .open(path: a, mode: 2)
            case 1: body = .create(path: a, access: 2, disposition: UInt16(i % 6), attributes: 0, unknown1: 0, unknown2: 0)
            case 2: body = .getAttributes(path: a)
            case 3: body = .findFirst(path: a, bufferSize: 4096, maxEntries: 50)
            case 4: body = .rename(from: a, to: b)
            case 5: body = .delete(path: a)
            case 6: body = .createDirectory(path: a, unknown1: 0, unknown2: 0, date: 0, time: 0)
            case 7: body = .deleteDirectory(path: a)
            default: body = .setAttributes(path: a, attributes: 1)
            }
            engine.receive(CDMRequest(id: UInt8(truncatingIfNeeded: i), body).encode())
            // Read whatever got opened, then close it.
            if case .open = body, let r = replies.last, r[0] == 0x81, r[4] == 0, r[5] == 0 {
                let ctx = UInt16(r[2]) | UInt16(r[3]) << 8
                engine.receive(CDMRequest(id: 1, .read(handle: ctx, offset: 0, count: 100)).encode())
                engine.receive(CDMRequest(id: 1, .close(handle: ctx)).encode())
            }
        }
        #expect(engine.stopReason == nil)
        #expect(!replies.contains { $0.range(of: Data("secret".utf8)) != nil && $0[0] == 0x83 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.outside.path) == ["secret.txt"])
        #expect(try String(contentsOf: t.outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "secret")
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.base.path).sorted() == ["Shared", "outside"])
        engine.shutdown()
    }

    /// Random bytes never crash the parser: every feed ends in requests, a wait for more, or a fatal stop.
    @Test func cdmParserFuzz() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var parser = CDMStreamParser()
            var bytes = [UInt8](repeating: 0, count: Int.random(in: 0...300, using: &rng))
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...0x1F, using: &rng) }
            var offset = 0
            while offset < bytes.count {
                let n = Int.random(in: 1...40, using: &rng)
                _ = parser.feed(Data(bytes[offset..<min(bytes.count, offset + n)]))
                offset += n
            }
            #expect(parser.bufferedCount <= 6 + 2 * 0xFFFF)
        }
    }

    @Test func cdmPOSIXRefusesHandBuiltPaths() throws {
        let t = try TempTree()
        let fs = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        for bad in [[".."], ["..", "outside", "secret.txt"], ["a/../../outside"], [""], ["."], ["x\0y"]] {
            #expect(fsError { _ = try fs.info(CDMPath(bad)) } == .pathNotFound, "\(bad)")
            #expect(fsError { _ = try fs.open(CDMPath(bad), .createNew) } == .pathNotFound, "\(bad)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.outside.path) == ["secret.txt"])
    }

    // MARK: Security review fixes

    /// Folding is per character and one-to-one: ß ≠ SS, ﬁ ≠ FI; ambiguous matches are refused.
    @Test func cdmFoldingIsSimpleAndNeverWidens() throws {
        #expect(CDMNames.fold("straße.txt") == "STRAßE.TXT")
        #expect(CDMNames.fold("ﬁle.txt") == "ﬁLE.TXT")
        #expect(CDMNames.fold("Ärger") == "ÄRGER")
        let t = try TempTree()
        try t.file("straße.txt", "keep")
        try t.file("file.txt", "keep too")
        let engine = CDMEngine(config: CDMEngine.Config(fileSystem: try CDMPOSIXFileSystem(root: t.root, readOnly: false)))
        var replies: [Data] = []
        engine.output = { if case .channel(let d) = $0 { replies.append(d) } }
        engine.receive(CDMRequest(id: 0, .connect(fields: [16, 0, 0, 0x10, 0, 0, 0, 0])).encode())
        engine.receive(CDMRequest(id: 1, .delete(path: Data("M:\\STRASSE.TXT".utf8))).encode())
        #expect(replies.last!.suffix(2) == Data([0x01, 0x02]))  // FILE_NOT_FOUND
        engine.receive(CDMRequest(id: 2, .create(path: Data("M:\\ﬁle.txt".utf8), access: 2, disposition: 5, attributes: 0,
                                                unknown1: 0, unknown2: 0)).encode())
        engine.receive(CDMRequest(id: 3, .getAttributes(path: Data("M:\\STRAẞE.TXT".utf8))).encode())  // capital ẞ: not a simple pair
        #expect(t.contents("straße.txt") == "keep")
        #expect(t.contents("file.txt") == "keep too")
        // The memory FS (and so the server) refuses ambiguous names on a case-sensitive volume.
        let fs = CDMMemoryFileSystem()
        fs.add("a.txt", "1")
        fs.add("A.TXT", "2")
        #expect(fsError { _ = try fs.info(path("a.TXT")) } == .ambiguous)
        #expect(try fs.info(path("a.txt")).size == 1)  // an exact match still wins
    }

    /// A folder swapped for a symlink to outside between the walk and the operation (a local process racing
    /// us): every operation fails, nothing outside is read, changed, created or truncated.
    @Test func cdmPOSIXSwapAfterWalkIsRefused() throws {
        let t = try TempTree()
        try t.file("outside-copy.txt", "x")
        let decoy = t.outside.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: decoy.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: decoy.appendingPathComponent("d"), withIntermediateDirectories: true)
        let fs = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        let sub = t.root.appendingPathComponent("sub")
        func prepare() throws {
            try? FileManager.default.removeItem(at: sub)
            try t.file("sub/a.txt", "inside")
            try FileManager.default.createDirectory(at: sub.appendingPathComponent("d"), withIntermediateDirectories: true)
        }
        fs.afterWalk = {
            try? FileManager.default.removeItem(at: sub)
            try? FileManager.default.createSymbolicLink(at: sub, withDestinationURL: decoy)
        }
        let operations: [(String, () throws -> Void)] = [
            ("open read", { _ = try fs.open(path("sub/a.txt"), .existing(write: false, truncate: false)) }),
            ("open write", { _ = try fs.open(path("sub/a.txt"), .existing(write: true, truncate: false)) }),
            ("replace", { _ = try fs.open(path("sub/a.txt"), .existing(write: true, truncate: true)) }),
            ("create", { _ = try fs.open(path("sub/new.txt"), .createNew) }),
            ("mkdir", { try fs.makeDirectory(path("sub/newdir")) }),
            ("delete", { try fs.removeFile(path("sub/a.txt")) }),
            ("rmdir", { try fs.removeDirectory(path("sub/d")) }),
            ("rename out", { try fs.rename(path("sub/a.txt"), to: path("moved.txt")) }),
            ("rename in", { try fs.rename(path("outside-copy.txt"), to: path("sub/planted.txt")) }),
            ("attributes", { try fs.setAttributes(path("sub/a.txt"), readOnly: true, hidden: true) }),
            ("list", { _ = try fs.list(path("sub")) }),
        ]
        for (name, op) in operations {
            try prepare()
            let error = fsError(op)
            #expect(error == .escapes || error == .pathNotFound, "\(name): \(String(describing: error))")
        }
        fs.afterWalk = nil
        #expect(try String(contentsOf: decoy.appendingPathComponent("a.txt"), encoding: .utf8) == "outside")
        #expect(try FileManager.default.contentsOfDirectory(atPath: decoy.path).sorted() == ["a.txt", "d"])
        var st = stat()
        #expect(stat(decoy.appendingPathComponent("a.txt").path, &st) == 0 && st.st_mode & S_IWUSR != 0 && st.st_flags & UInt32(UF_HIDDEN) == 0)
        #expect(t.quarantine("../outside/sub/a.txt") == nil)
    }

    @Test func cdmPOSIXHardLinksAreNotWritten() throws {
        let t = try TempTree()
        let outsideFile = t.outside.appendingPathComponent("secret.txt")
        #expect(link(outsideFile.path, t.root.appendingPathComponent("hard.txt").path) == 0)
        let fs = try CDMPOSIXFileSystem(root: t.root, readOnly: false)
        #expect(fsError { _ = try fs.open(path("hard.txt"), .existing(write: true, truncate: false)) } == .accessDenied)
        #expect(fsError { _ = try fs.open(path("hard.txt"), .existing(write: true, truncate: true)) } == .accessDenied)
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "secret")
    }
}
