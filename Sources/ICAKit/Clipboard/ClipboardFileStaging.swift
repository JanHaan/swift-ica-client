import Foundation

// Session → Mac clipboard files (docs/75 §6): the host's FILEGROUPDESCRIPTORW becomes a staging plan (safe Mac names,
// folders, the top-level items the pasteboard offers), a staging folder per transfer under
// ~/Library/Caches/ICAViewer/clipboard-files/, and a wait the pasteboard's data provider blocks on (bounded) while the
// session queue fetches the files over CTXGDT.

/// Where every entry of a host file group goes, relative to the transfer folder (`/`-separated Mac paths).
public struct ClipboardStagingPlan: Equatable, Sendable {
    /// A top-level file or folder: one pasteboard item.
    public struct Item: Equatable, Sendable {
        public var path: String
        public var isDirectory: Bool
        /// Entry indices of the files inside (a file item: itself).
        public var files: [Int]
    }

    public var items: [Item] = []
    /// Folders to create, parents first.
    public var directories: [String] = []
    /// Entry index → relative path of each file.
    public var files: [Int: String] = [:]
    public var totalBytes: UInt64 = 0

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case unsafeName(String)
        case tooMany(Int)
        case tooLarge(UInt64)
        public var description: String {
            switch self {
            case .empty: return "no files"
            case .unsafeName(let n): return "unsafe name \"\(n)\""
            case .tooMany(let n): return "more than \(n) files and folders"
            case .tooLarge(let n): return "more than \(n >> 20) MB"
            }
        }
    }

    /// Mac rules for one Windows path component (docs/75 §6.5): `/`, `:` and control characters (U+0001–U+001F, U+007F)
    /// become `_`; at most 255 UTF-8 bytes, keeping the extension. Nil for an empty name, `.` or `..`.
    public static func macComponent(_ component: String) -> String? {
        var out = String(String.UnicodeScalarView(component.unicodeScalars.compactMap { s -> Unicode.Scalar? in
            if s.value == 0 { return nil }
            return s == "/" || s == ":" || s.value < 0x20 || s.value == 0x7F ? "_" : s
        }))
        guard !out.isEmpty, out != ".", out != ".." else { return nil }
        if out.utf8.count > 255 {
            let ext = (out as NSString).pathExtension
            let keep = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
            var stem = ext.isEmpty || ext.utf8.count > 32 ? out : (out as NSString).deletingPathExtension
            while stem.utf8.count + keep.utf8.count > 255 { stem.removeLast() }
            out = stem + keep
        }
        return out
    }

    /// The components of a Windows relative path (`dir\sub\file.txt`). Throws for an absolute path (`\x`, `\\server`,
    /// `C:`), or a component that is empty, `.` or `..` (traversal).
    public static func components(_ windowsPath: String) throws -> [String] {
        let p = windowsPath
        if p.hasPrefix("\\") || p.hasPrefix("/") { throw Failure.unsafeName(p) }
        let scalars = Array(p.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":", CharacterSet.letters.contains(scalars[0]) { throw Failure.unsafeName(p) }
        let parts = p.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        return try parts.map { part in
            guard let c = macComponent(part) else { throw Failure.unsafeName(p) }
            return c
        }
    }

    /// The plan for `entries` (descriptor order). Names that collide (case-insensitively, as on APFS) get " 2", " 3"
    /// before the extension, as Finder names copies; a folder listed twice is one folder. A file's folder that has no
    /// entry of its own is created anyway. A path below a file is refused.
    public static func make(_ entries: [ClipboardFileEntry], maxEntries: Int = 1000, maxTotal: UInt64 = .max) throws -> ClipboardStagingPlan {
        guard !entries.isEmpty else { throw Failure.empty }
        guard entries.count <= maxEntries else { throw Failure.tooMany(maxEntries) }
        var plan = ClipboardStagingPlan()
        /// Lowercased host path (sanitised components) → our path; and the kinds of our paths (lowercased).
        var assigned: [String: String] = [:]
        var kinds: [String: Bool] = [:]
        var itemIndex: [String: Int] = [:]

        func unique(_ path: String) -> String {
            guard kinds[path.lowercased()] != nil else { return path }
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension
            let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            var n = 2
            while true {
                let candidate = (dir.isEmpty ? "" : dir + "/") + (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                if kinds[candidate.lowercased()] == nil { return candidate }
                n += 1
            }
        }

        /// Our path for the folder of host components `comps` (created when missing).
        func folder(_ comps: [String]) throws -> String {
            let key = comps.joined(separator: "/").lowercased()
            if let ours = assigned[key] {
                guard kinds[ours.lowercased()] == true else { throw Failure.unsafeName(comps.joined(separator: "\\")) }
                return ours
            }
            let parent = comps.count > 1 ? try folder(Array(comps.dropLast())) : ""
            let ours = unique((parent.isEmpty ? "" : parent + "/") + comps.last!)
            assigned[key] = ours
            kinds[ours.lowercased()] = true
            plan.directories.append(ours)
            if comps.count == 1 {
                itemIndex[ours] = plan.items.count
                plan.items.append(Item(path: ours, isDirectory: true, files: []))
            }
            return ours
        }

        for (i, e) in entries.enumerated() {
            let comps = try components(e.name)
            if e.isDirectory {
                _ = try folder(comps)
                continue
            }
            let parent = comps.count > 1 ? try folder(Array(comps.dropLast())) : ""
            let ours = unique((parent.isEmpty ? "" : parent + "/") + comps.last!)
            assigned[comps.joined(separator: "/").lowercased()] = ours
            kinds[ours.lowercased()] = false
            plan.files[i] = ours
            plan.totalBytes += e.size
            guard plan.totalBytes <= maxTotal else { throw Failure.tooLarge(maxTotal) }
            if comps.count == 1 {
                itemIndex[ours] = plan.items.count
                plan.items.append(Item(path: ours, isDirectory: false, files: [i]))
            } else {
                let top = String(ours.split(separator: "/").first!)
                if let k = itemIndex[top] { plan.items[k].files.append(i) }
            }
        }
        return plan
    }
}

/// Transfer folders `<pid>-<uuid>` under `~/Library/Caches/ICAViewer/clipboard-files/` (0700). A new host file group
/// removes this process's earlier folders (`removeOwn`), as does quitting; at launch, folders of processes that are
/// gone are removed (`removeStale`), never those of a running ICAViewer. Any thread.
public final class ClipboardStagingArea: @unchecked Sendable {
    public let base: URL
    private let pid: Int32
    private let lock = NSLock()

    public static var defaultBase: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("ICAViewer", isDirectory: true).appendingPathComponent("clipboard-files", isDirectory: true)
    }

    public init(base: URL = ClipboardStagingArea.defaultBase, pid: Int32 = getpid()) {
        self.base = base
        self.pid = pid
    }

    public enum Failure: Error, CustomStringConvertible {
        case create(String, Int32)
        public var description: String {
            switch self { case let .create(what, code): return "cannot create \(what): \(String(cString: strerror(code)))" }
        }
    }

    private func makeDirectory(_ url: URL, _ mode: mode_t = 0o700) throws {
        if mkdir(url.path, mode) != 0, errno != EEXIST { throw Failure.create(url.lastPathComponent, errno) }
    }

    /// A new, empty transfer folder (0700) with the plan's folders inside (0755, quarantined).
    public func newFolder(for plan: ClipboardStagingPlan, quarantineAgent: String? = "ICAViewer") throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try makeDirectory(base.deletingLastPathComponent())
        try makeDirectory(base)
        let folder = base.appendingPathComponent("\(pid)-\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(folder)
        for dir in plan.directories {
            let url = folder.appendingPathComponent(dir, isDirectory: true)
            try makeDirectory(url, 0o755)
            if let agent = quarantineAgent { Self.quarantine(url, agent: agent) }
        }
        return folder
    }

    static func quarantine(_ url: URL, agent: String) {
        let value = CDMPOSIXFileSystem.quarantineValue(agent: agent)
        _ = setxattr(url.path, CDMPOSIXFileSystem.quarantineName, value, value.count, 0, XATTR_NOFOLLOW)
    }

    /// This process's folders.
    public var ownFolders: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { $0.hasPrefix("\(pid)-") }.map { base.appendingPathComponent($0, isDirectory: true) }
    }

    /// Removes this process's folders except `keep`.
    public func removeOwn(except keep: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        for url in ownFolders where url.standardizedFileURL != keep?.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes folders of processes that no longer run (and malformed names).
    public func removeStale(isRunning: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        lock.lock()
        defer { lock.unlock() }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            if let p = name.split(separator: "-").first.flatMap({ Int32($0) }), p == pid || isRunning(p) { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }
}

/// One session → Mac transfer that the pasteboard waits on: the session queue feeds `update` with the fetch's
/// progress; the main thread blocks in `wait(item:)` until that item's files are there, the transfer failed, or the
/// deadline passed. Any thread.
public final class ClipboardFileWait: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case ready(URL)
        /// Some files of a folder item failed; the folder holds the rest.
        case partial(URL, failed: Int)
        case failed(String)
        case timedOut
    }

    public let plan: ClipboardStagingPlan
    public let folder: URL
    public let deadline: Date
    private let condition = NSCondition()
    private var done: Set<Int> = []
    private var failed: [Int: String] = [:]
    private var bytes: [Int: Int] = [:]
    private var ended = false
    private var failure: String?

    public init(plan: ClipboardStagingPlan, folder: URL, deadline: Date) {
        self.plan = plan
        self.folder = folder
        self.deadline = deadline
    }

    /// Entry index → destination URL, for `GDTFetchMode.files`.
    public var targets: [Int: URL] { plan.files.mapValues { folder.appendingPathComponent($0) } }

    public func url(item k: Int) -> URL { folder.appendingPathComponent(plan.items[k].path, isDirectory: plan.items[k].isDirectory) }

    /// From the fetch (session queue).
    public func update(_ u: GDTFetchUpdate) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        switch u {
        case .group: break
        case .progress(let i, let n): bytes[i] = n
        case .file(let i, _, let n): done.insert(i); bytes[i] = n
        case .fileFailed(let i, let why): failed[i] = why
        case .done:
            ended = true
            for i in plan.files.keys where !done.contains(i) && failed[i] == nil { failed[i] = "not received" }
        case .failed(let why):
            ended = true
            failure = why
        }
    }

    /// Bytes received so far and the plan's total.
    public var progress: (bytes: UInt64, total: UInt64) {
        condition.lock()
        defer { condition.unlock() }
        return (UInt64(bytes.values.reduce(0, +)), plan.totalBytes)
    }

    public var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return ended
    }

    /// The reason the transfer failed, or nil.
    public var failureReason: String? {
        condition.lock()
        defer { condition.unlock() }
        return failure
    }

    /// Files that failed, with their reasons.
    public var failedFiles: [Int: String] {
        condition.lock()
        defer { condition.unlock() }
        return failed
    }

    private func outcome(item k: Int) -> Outcome? {
        let item = plan.items[k]
        let missing = item.files.filter { !done.contains($0) && failed[$0] == nil }
        if missing.isEmpty {
            let bad = item.files.filter { failed[$0] != nil }
            if !item.isDirectory, let i = bad.first { return .failed(failed[i]!) }
            return bad.isEmpty ? .ready(url(item: k)) : .partial(url(item: k), failed: bad.count)
        }
        if let failure { return .failed(failure) }
        return nil
    }

    /// Blocks until item `k` is complete, the transfer fails, or `deadline`; `tick` runs about every `interval` on the
    /// calling thread while it waits (progress display).
    public func wait(item k: Int, interval: TimeInterval = 0.1, tick: () -> Void = {}) -> Outcome {
        guard plan.items.indices.contains(k) else { return .failed("no such item") }
        while true {
            condition.lock()
            if let o = outcome(item: k) { condition.unlock(); return o }
            let now = Date()
            if now >= deadline { condition.unlock(); return .timedOut }
            _ = condition.wait(until: min(deadline, now.addingTimeInterval(interval)))
            let result = outcome(item: k)
            condition.unlock()
            if let result { return result }
            tick()
        }
    }
}

/// How a session → Mac file group reaches the Mac pasteboard (docs/75 §11.5): small groups stay lazy (promised file
/// URLs, fetched while the paste waits, bounded); larger ones are fetched in the background at copy time with a
/// progress window and published as plain file URLs when complete; above the soft limit the user confirms first.
public struct ClipboardTransferPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case lazy, background, confirm }

    /// Largest total fetched while a paste waits on the main thread.
    public var lazyMax: UInt64 = 50 << 20
    /// Above this the user is asked first (nil: never).
    public var softLimit: UInt64? = 10_000_000_000

    public init(lazyMax: UInt64 = 50 << 20, softLimit: UInt64? = 10_000_000_000) {
        self.lazyMax = lazyMax
        self.softLimit = softLimit
    }

    public func decide(total: UInt64) -> Decision {
        if let softLimit, total > softLimit { return .confirm }
        return total > lazyMax ? .background : .lazy
    }

    /// Free space needed on the staging volume: the files plus 10 % headroom.
    public static func needed(total: UInt64) -> UInt64 { total + total / 10 }

    /// False only when the free space is known and short (nil free space: unknown, the write fails if it must).
    public static func enoughSpace(free: Int64?, total: UInt64) -> Bool {
        guard let free, free >= 0 else { return true }
        return UInt64(free) >= needed(total: total)
    }
}

extension ClipboardFileWait {
    /// Every item's outcome once the transfer has ended (nil while it runs); never blocks.
    public var outcomes: [Outcome]? {
        guard isFinished else { return nil }
        return plan.items.indices.map { wait(item: $0) }
    }
}
