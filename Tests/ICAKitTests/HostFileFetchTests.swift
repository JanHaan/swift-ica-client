import Foundation
import Testing
@testable import ICAKit

// Synthetic names and data only.
@Suite struct HostFileFetchTests {
    @Test func splitsDriveAndUNCPaths() {
        #expect(HostFileFetch.split("H:\\sample.zip")! == ("H:\\", "sample.zip"))
        #expect(HostFileFetch.split("h:\\a\\b c\\x.bin")! == ("h:\\a\\b c", "x.bin"))
        #expect(HostFileFetch.split("\\\\server\\share\\x.txt")! == ("\\\\server\\share", "x.txt"))
    }

    @Test func refusesBadPaths() {
        for p in ["sample.zip", "H:sample.zip", "H:\\", "H:\\a\\", "H:\\*.zip", "H:\\a?.zip", "H:\\..\\x", "H:\\a\\.\\x",
                  "H:/x.zip", "H:\\x.zip.", "H:\\x.zip ", "\\\\server\\x.txt", "\\\\server\\\\share\\x", "H:\\a\u{1}b", "1:\\x"] {
            #expect(HostFileFetch.split(p) == nil, "\(p)")
        }
    }

    private func entry(_ name: String, size: UInt64 = 10, dir: Bool = false, sizeFlag: Bool = true) -> ClipboardFileEntry {
        var e = ClipboardFileEntry(name: name, size: size, isDirectory: dir)
        if !sizeFlag { e.flags &= ~ClipboardFileGroup.fdFileSize }
        return e
    }

    @Test func groupMustBeExactlyTheOneFile() {
        #expect(HostFileFetch.check([entry("sample.zip")], name: "sample.zip", cap: 100) == .success(entry("sample.zip")))
        #expect(HostFileFetch.check([entry("SAMPLE.ZIP")], name: "sample.zip", cap: 100) == .success(entry("SAMPLE.ZIP")))
        #expect(HostFileFetch.check([], name: "sample.zip", cap: 100) == .failure(.empty))
        #expect(HostFileFetch.check([entry("sample.zip"), entry("other.txt")], name: "sample.zip", cap: 100) == .failure(.count(2)))
        #expect(HostFileFetch.check([entry("other.zip")], name: "sample.zip", cap: 100) == .failure(.otherName("other.zip")))
        #expect(HostFileFetch.check([entry("dir\\sample.zip")], name: "sample.zip", cap: 100) == .failure(.otherName("dir\\sample.zip")))
        #expect(HostFileFetch.check([entry("sample.zip", dir: true)], name: "sample.zip", cap: 100) == .failure(.directory))
        #expect(HostFileFetch.check([entry("sample.zip", sizeFlag: false)], name: "sample.zip", cap: 100) == .failure(.sizeUnknown))
        #expect(HostFileFetch.check([entry("sample.zip", size: 101)], name: "sample.zip", cap: 100) == .failure(.tooLarge(size: 101, cap: 100)))
    }

    @Test func testGroup() {
        #expect(HostFileFetch.isTestGroup(appNames: ["Explorer Citrix ABC"]))
        #expect(HostFileFetch.isTestGroup(appNames: ["Mail XYZ", "Editor abc "]))
        #expect(!HostFileFetch.isTestGroup(appNames: ["Mail XYZ", "ABCX Tool"]))
        #expect(!HostFileFetch.isTestGroup(appNames: []))
    }

    @Test func destinationNeverClobbers() {
        let dir = URL(fileURLWithPath: "/tmp/dest", isDirectory: true)
        #expect(HostFileFetch.destination(in: dir, name: "a.zip") { _ in false }.lastPathComponent == "a.zip")
        let taken: Set<String> = ["/tmp/dest/a.zip", "/tmp/dest/a-2.zip"]
        #expect(HostFileFetch.destination(in: dir, name: "a.zip") { taken.contains($0) }.lastPathComponent == "a-3.zip")
        #expect(HostFileFetch.destination(in: dir, name: "noext") { $0 == "/tmp/dest/noext" }.lastPathComponent == "noext-2")
    }

    @Test func progressEveryStepAndOnceAtTheEnd() {
        var p = HostFileFetch.Progress(total: 10, step: 4)
        let lines = [1, 3, 4, 5, 9, 10, 10].map { p.update(UInt64($0), elapsed: 1) != nil }
        #expect(lines == [false, false, true, false, true, true, false])
        var big = HostFileFetch.Progress(total: 8 << 20)
        #expect(big.update(4 << 20, elapsed: 2) == "4.0 of 8.0 MiB (50 %), 2.00 MiB/s")
    }

    @Test func streamingSHA256() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.bin")
        try Data("abc".utf8).write(to: url)
        let (hex, n) = try HostFileFetch.sha256(fileAt: url)
        #expect(n == 3 && hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let big = Data((0..<(3 << 20)).map { UInt8($0 % 253) })
        try big.write(to: url)
        let (_, m) = try HostFileFetch.sha256(fileAt: url)
        #expect(m == UInt64(big.count))
    }
}

@Suite struct ClipboardTransferPolicyTests {
    @Test func decisions() {
        let p = ClipboardTransferPolicy(lazyMax: 50 << 20, softLimit: 10_000_000_000)
        #expect(p.decide(total: 0) == .lazy)
        #expect(p.decide(total: 50 << 20) == .lazy)
        #expect(p.decide(total: (50 << 20) + 1) == .background)
        #expect(p.decide(total: 10_000_000_000) == .background)
        #expect(p.decide(total: 10_000_000_001) == .confirm)
        #expect(ClipboardTransferPolicy(softLimit: nil).decide(total: 1 << 40) == .background)
    }

    @Test func freeSpaceHeadroom() {
        #expect(ClipboardTransferPolicy.needed(total: 1000) == 1100)
        #expect(ClipboardTransferPolicy.enoughSpace(free: 1100, total: 1000))
        #expect(!ClipboardTransferPolicy.enoughSpace(free: 1099, total: 1000))
        #expect(ClipboardTransferPolicy.enoughSpace(free: nil, total: 1 << 40))
    }

    @Test func outcomesOnlyWhenFinished() {
        let plan = try! ClipboardStagingPlan.make([ClipboardFileEntry(name: "a.bin", size: 3), ClipboardFileEntry(name: "b.bin", size: 2)],
                                                  maxTotal: .max)
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let w = ClipboardFileWait(plan: plan, folder: folder, deadline: .distantFuture)
        #expect(w.outcomes == nil)
        w.update(.file(index: 0, url: folder.appendingPathComponent("a.bin"), bytes: 3))
        w.update(.fileFailed(index: 1, why: "host error"))
        w.update(.done(files: 1))
        #expect(w.outcomes == [.ready(folder.appendingPathComponent("a.bin")), .failed("host error")])
    }
}
