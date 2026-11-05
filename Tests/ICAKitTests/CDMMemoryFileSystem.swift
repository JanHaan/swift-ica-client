import Foundation
@testable import ICAKit

/// In-memory `CDMFileSystem` for server tests: case-insensitive lookups, no symlinks.
final class CDMMemoryFileSystem: CDMFileSystem {
    final class Node {
        var isDirectory: Bool
        var data = Data()
        var children: [String: Node] = [:]
        var modified = Date(timeIntervalSince1970: 1_700_000_000)
        var readOnly = false
        var hidden = false
        /// Set when the session created or wrote it (stands in for the quarantine xattr).
        var quarantined = false
        init(directory: Bool) { isDirectory = directory }
    }

    let root = Node(directory: true)
    var isReadOnly = false
    private(set) var openCount = 0

    init(readOnly: Bool = false) { isReadOnly = readOnly }

    // MARK: Test setup

    @discardableResult
    func add(_ path: String, _ contents: String? = nil, directory: Bool = false) -> Node {
        var node = root
        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            if let child = node.children[part] { node = child; continue }
            let child = Node(directory: !last || directory)
            if last, let contents { child.data = Data(contents.utf8) }
            node.children[part] = child
            node = child
        }
        return node
    }

    func node(_ path: String) -> Node? { try? resolve(CDMPath(path.split(separator: "/").map(String.init))) }

    // MARK: Lookup

    private var ambiguous = false

    private func child(_ name: String, of dir: Node) -> (String, Node)? {
        if let exact = dir.children[name] { return (name, exact) }
        let folded = CDMNames.fold(name)
        let matches = dir.children.filter { CDMNames.fold($0.key) == folded }
        if matches.count > 1 { ambiguous = true; return nil }
        return matches.first.map { ($0.key, $0.value) }
    }

    /// Runs a lookup-based operation; an ambiguous name anywhere becomes `.ambiguous`.
    private func checked<T>(_ body: () throws -> T) throws -> T {
        ambiguous = false
        let result = Result { try body() }
        if ambiguous { throw CDMFSError.ambiguous }
        return try result.get()
    }

    private func resolve(_ path: CDMPath) throws -> Node {
        var node = root
        for (i, c) in path.components.enumerated() {
            guard node.isDirectory else { throw CDMFSError.pathNotFound }
            guard let (_, next) = child(c, of: node) else {
                throw i == path.components.count - 1 ? CDMFSError.notFound : CDMFSError.pathNotFound
            }
            node = next
        }
        return node
    }

    private func parent(_ path: CDMPath) throws -> Node {
        guard !path.isRoot else { throw CDMFSError.accessDenied }
        let p: Node
        do { p = try resolve(path.parent) } catch { throw CDMFSError.pathNotFound }
        guard p.isDirectory else { throw CDMFSError.pathNotFound }
        return p
    }

    private func info(name: String, _ n: Node) -> CDMFileInfo {
        CDMFileInfo(name: name, isDirectory: n.isDirectory, size: UInt64(n.data.count), modified: n.modified,
                    readOnly: n.readOnly, hidden: n.hidden || name.hasPrefix("."))
    }

    // MARK: CDMFileSystem

    func info(_ path: CDMPath) throws -> CDMFileInfo { try checked { try infoUnchecked(path) } }

    private func infoUnchecked(_ path: CDMPath) throws -> CDMFileInfo {
        if path.isRoot { return info(name: "", root) }
        let p = try parent(path)
        guard let (name, n) = child(path.name!, of: p) else { throw CDMFSError.notFound }
        return info(name: name, n)
    }

    func list(_ directory: CDMPath) throws -> [CDMFileInfo] {
        let n: Node
        do { n = try resolve(directory) } catch { throw CDMFSError.pathNotFound }
        guard n.isDirectory else { throw CDMFSError.notDirectory }
        return n.children.map { info(name: $0.key, $0.value) }
    }

    func open(_ path: CDMPath, _ mode: CDMOpenMode) throws -> CDMOpenFile {
        switch mode {
        case .createNew:
            guard !isReadOnly else { throw CDMFSError.accessDenied }
            let p = try parent(path)
            guard child(path.name!, of: p) == nil else { throw CDMFSError.exists }
            let n = Node(directory: false)
            n.quarantined = true
            p.children[path.name!] = n
            openCount += 1
            return File(n, writable: true, fs: self)
        case .existing(let write, let truncate):
            guard !isReadOnly || (!write && !truncate) else { throw CDMFSError.accessDenied }
            let n = try resolve(path)
            if n.isDirectory { throw CDMFSError.isDirectory }
            if (write || truncate) && n.readOnly { throw CDMFSError.accessDenied }
            if truncate { n.data = Data(); n.quarantined = true }
            openCount += 1
            return File(n, writable: write || truncate, fs: self)
        }
    }

    func makeDirectory(_ path: CDMPath) throws {
        guard !isReadOnly else { throw CDMFSError.accessDenied }
        let p = try parent(path)
        guard child(path.name!, of: p) == nil else { throw CDMFSError.exists }
        let n = Node(directory: true)
        n.quarantined = true
        p.children[path.name!] = n
    }

    func removeFile(_ path: CDMPath) throws {
        guard !isReadOnly else { throw CDMFSError.accessDenied }
        let p = try parent(path)
        guard let (name, n) = child(path.name!, of: p) else { throw CDMFSError.notFound }
        if n.isDirectory { throw CDMFSError.isDirectory }
        if n.readOnly { throw CDMFSError.accessDenied }
        p.children[name] = nil
    }

    func removeDirectory(_ path: CDMPath) throws {
        guard !isReadOnly else { throw CDMFSError.accessDenied }
        let p = try parent(path)
        guard let (name, n) = child(path.name!, of: p) else { throw CDMFSError.notFound }
        guard n.isDirectory else { throw CDMFSError.notDirectory }
        guard n.children.isEmpty else { throw CDMFSError.notEmpty }
        p.children[name] = nil
    }

    func rename(_ from: CDMPath, to: CDMPath) throws {
        guard !isReadOnly else { throw CDMFSError.accessDenied }
        let fp = try parent(from)
        guard let (name, n) = child(from.name!, of: fp) else { throw CDMFSError.notFound }
        let tp = try parent(to)
        if let (_, existing) = child(to.name!, of: tp), existing !== n { throw CDMFSError.exists }
        fp.children[name] = nil
        tp.children[to.name!] = n
    }

    func setAttributes(_ path: CDMPath, readOnly: Bool, hidden: Bool) throws {
        guard !isReadOnly else { throw CDMFSError.accessDenied }
        let n = try resolve(path)
        if !n.isDirectory { n.readOnly = readOnly }
        n.hidden = hidden
    }

    final class File: CDMOpenFile {
        let node: Node
        let writable: Bool
        weak var fs: CDMMemoryFileSystem?
        var closed = false
        init(_ node: Node, writable: Bool, fs: CDMMemoryFileSystem) {
            self.node = node
            self.writable = writable
            self.fs = fs
        }
        func read(at offset: UInt64, count: Int) throws -> Data {
            let start = min(Int(offset), node.data.count)
            return node.data.subdata(in: start..<min(node.data.count, start + count))
        }
        func write(_ data: Data, at offset: UInt64) throws -> Int {
            guard writable else { throw CDMFSError.accessDenied }
            node.quarantined = true
            let end = Int(offset) + data.count
            if node.data.count < end { node.data += Data(count: end - node.data.count) }
            node.data.replaceSubrange(Int(offset)..<end, with: data)
            return data.count
        }
        func info() throws -> CDMFileInfo { CDMFileInfo(name: "", isDirectory: false, size: UInt64(node.data.count), modified: node.modified) }
        func truncate(to size: UInt64) throws {
            guard writable else { throw CDMFSError.accessDenied }
            if Int(size) < node.data.count { node.data = node.data.prefix(Int(size)) } else { node.data += Data(count: Int(size) - node.data.count) }
        }
        func setModified(_ date: Date) throws { node.modified = date }
        func close() {
            if !closed { fs?.openCount -= 1 }
            closed = true
        }
    }
}
