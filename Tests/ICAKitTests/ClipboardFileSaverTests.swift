import Testing
import Foundation
@testable import ICAKit

@Suite struct ClipboardFileSaverTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func uniqueNames() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ClipboardFileSaver.uniqueURL(for: "a.zip", in: dir).lastPathComponent == "a.zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: Data())
        #expect(ClipboardFileSaver.uniqueURL(for: "a.zip", in: dir).lastPathComponent == "a 2.zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a 2.zip").path, contents: Data())
        #expect(ClipboardFileSaver.uniqueURL(for: "a.zip", in: dir).lastPathComponent == "a 3.zip")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        #expect(ClipboardFileSaver.uniqueURL(for: "Folder", in: dir).lastPathComponent == "Folder 2")
    }

    @Test func moveKeepsContentAndRemovesFolder() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging"), dest = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staging.appendingPathComponent("big.zip"))
        try Data("y".utf8).write(to: staging.appendingPathComponent("dir/inner.txt"))
        try Data("old".utf8).write(to: dest.appendingPathComponent("big.zip"))
        let moved = try ClipboardFileSaver.move(from: staging, to: dest)
        #expect(Set(moved.map(\.lastPathComponent)) == ["big 2.zip", "dir"])
        #expect(try Data(contentsOf: dest.appendingPathComponent("big.zip")) == Data("old".utf8))
        #expect(try Data(contentsOf: dest.appendingPathComponent("big 2.zip")) == Data("x".utf8))
        #expect(try Data(contentsOf: dest.appendingPathComponent("dir/inner.txt")) == Data("y".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func keeperHoldsObjectUntilReleased() {
        let keeper = ObjectKeeper()
        weak var weakObject: NSObject?
        do {
            let o = NSObject()
            weakObject = o
            keeper.keep(o)
        }
        #expect(weakObject != nil && keeper.count == 1)
        keeper.release(weakObject!)
        #expect(weakObject == nil && keeper.count == 0)
    }
}
