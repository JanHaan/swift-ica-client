import Foundation

/// One entry as the drive server sees it.
public struct CDMFileInfo: Equatable, Sendable {
    /// The real name (NFC); empty for the root.
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modified: Date
    /// Not writable by us (no owner write bit, or immutable).
    public var readOnly: Bool
    /// A dot-file or `UF_HIDDEN` (docs/95 §A.7 item 6).
    public var hidden: Bool

    public init(name: String, isDirectory: Bool, size: UInt64 = 0, modified: Date = Date(timeIntervalSince1970: 0),
                readOnly: Bool = false, hidden: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.readOnly = readOnly
        self.hidden = hidden
    }
}

public enum CDMFSError: Error, Equatable, CustomStringConvertible {
    /// The last component does not exist.
    case notFound
    /// A folder on the way is missing or not a folder.
    case pathNotFound
    case exists
    /// Permissions, a read-only drive or an immutable file.
    case accessDenied
    /// A symlink that leaves the shared folder or dangles: never followed.
    case escapes
    case isDirectory
    case notDirectory
    case notEmpty
    /// Not a regular file or folder (FIFO, socket, device).
    case unsupported
    case tooMany
    /// More than one entry matches the name case-insensitively (a case-sensitive volume): refused.
    case ambiguous
    case io(Int32)

    public var description: String {
        switch self {
        case .notFound: return "not found"
        case .pathNotFound: return "path not found"
        case .exists: return "exists"
        case .accessDenied: return "access denied"
        case .escapes: return "refused: leaves the shared folder"
        case .isDirectory: return "is a folder"
        case .notDirectory: return "not a folder"
        case .notEmpty: return "folder not empty"
        case .unsupported: return "not a regular file"
        case .tooMany: return "too many entries"
        case .ambiguous: return "more than one entry matches"
        case .io(let e): return "errno \(e)"
        }
    }

    static func from(errno e: Int32) -> CDMFSError {
        switch e {
        case ENOENT: return .notFound
        case ENOTDIR: return .pathNotFound
        case EEXIST: return .exists
        case EACCES, EPERM, EROFS: return .accessDenied
        case EISDIR: return .isDirectory
        case ENOTEMPTY: return .notEmpty
        case ELOOP: return .escapes  // O_NOFOLLOW(_ANY) met a symlink
        default: return .io(e)
        }
    }
}

public enum CDMOpenMode: Equatable, Sendable {
    /// An existing regular file; `truncate` empties it (CREATE "replace").
    case existing(write: Bool, truncate: Bool)
    /// A new file; `.exists` if the name is taken.
    case createNew
}

/// An open file. Used from one thread at a time.
public protocol CDMOpenFile: AnyObject {
    var writable: Bool { get }
    func read(at offset: UInt64, count: Int) throws -> Data
    func write(_ data: Data, at offset: UInt64) throws -> Int
    func info() throws -> CDMFileInfo
    func truncate(to size: UInt64) throws
    func setModified(_ date: Date) throws
    func close()
}

/// The shared folder behind the drive (docs/95 §A.8 step 4). Paths are validated `CDMPath`s relative to
/// the root; implementations resolve them **case-insensitively** with `CDMNames.fold` (Windows semantics:
/// an exact NFC match wins, else exactly one folded match, else `.ambiguous`), must never reach
/// anything outside the root, and must refuse every mutation when `isReadOnly`. Errors are `CDMFSError`.
public protocol CDMFileSystem: AnyObject {
    var isReadOnly: Bool { get }
    func info(_ path: CDMPath) throws -> CDMFileInfo
    /// The folder's entries (no "." / ".."), regular files and folders only.
    func list(_ directory: CDMPath) throws -> [CDMFileInfo]
    func open(_ path: CDMPath, _ mode: CDMOpenMode) throws -> CDMOpenFile
    func makeDirectory(_ path: CDMPath) throws
    /// A file (never a folder).
    func removeFile(_ path: CDMPath) throws
    /// An empty folder only: never recursive (§A.7 item 3).
    func removeDirectory(_ path: CDMPath) throws
    /// Fails with `.exists` if `to` names another entry; a case-only rename of the same entry is allowed.
    func rename(_ from: CDMPath, to: CDMPath) throws
    /// Read-only ↔ owner write bit (files only); hidden ↔ `UF_HIDDEN` (§A.8 step 4).
    func setAttributes(_ path: CDMPath, readOnly: Bool, hidden: Bool) throws
}

// MARK: - POSIX implementation

/// The shared folder on the Mac's file system (docs/95 §A.7, §A.8 step 4).
///
/// Confinement:
/// - Every request walks from the root's real path one component at a time. Each component is looked up
///   in the folder reached so far (exact `lstat` whose on-disk name folds equal, else a scan of the folder),
///   so a lookup only ever lands on a child of a folder inside the root. A symlink is followed only if its
///   `realpath` stays inside the root (else `.escapes`).
/// - The walk yields symlink-free real paths. Every operation then runs without following **any** symlink:
///   files open with `O_NOFOLLOW_ANY`; name operations (create, mkdir, unlink, rmdir, rename) run with
///   `*at` calls on the parent folder, itself opened with `O_NOFOLLOW_ANY` and checked by `F_GETPATH`; so a
///   folder swapped for a symlink between the walk and the operation fails with `.escapes`. Opened files
///   are checked by `fstat`/`F_GETPATH` before anything is truncated or written.
/// - Hard-linked files (st_nlink > 1) are never opened for writing: the other link may be outside.
/// - Accepted: a handle stays usable if a local Mac process moves the open file out of the folder (the
///   session itself cannot move anything out; CDM has no symlink or link command).
///
/// Files the session creates, writes or replaces, and folders it creates, get a fresh
/// `com.apple.quarantine` value (§A.7 item 4), replacing any earlier one (which may carry a user approval).
public final class CDMPOSIXFileSystem: CDMFileSystem {
    public let root: URL
    public let isReadOnly: Bool
    /// The root's real path (symlinks resolved).
    public let rootPath: String
    /// The agent name in the quarantine value.
    public var quarantineAgent = "ICAViewer"
    /// Entries listed per folder at most.
    public static let maxEntries = 100_000
    /// Test hook: runs after each walk, before the operation (a local process racing us).
    var afterWalk: (() -> Void)?

    public init(root: URL, readOnly: Bool) throws {
        self.root = root
        self.isReadOnly = readOnly
        guard let real = Self.realPath(root.path) else { throw CDMFSError.notFound }
        var st = stat()
        guard lstat(real, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw CDMFSError.notDirectory }
        guard real != "/" else { throw CDMFSError.accessDenied }
        rootPath = real
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    func inside(_ path: String) -> Bool { path == rootPath || path.hasPrefix(rootPath + "/") }

    /// An fd's path is inside the root (also through aliases of the same path).
    func fdInside(_ fd: Int32) -> Bool {
        guard let path = Self.fdPath(fd) else { return false }
        return inside(path) || Self.realPath(path).map(inside) == true
    }

    static func fdPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    /// Result of walking a path: the directory entry itself and, for a symlink, its checked target.
    struct Node {
        /// Real path of the folder holding the entry (nil for the root).
        var parent: String?
        /// The name as found on disk (or as requested when missing).
        var name: String
        /// The entry's path (a symlink itself, not followed).
        var entry: String
        /// The followed path (== entry unless the entry is a symlink); symlink-free.
        var real: String
        var exists: Bool
        var isLink = false
        var st = stat()
    }

    /// Walks `path` from the root (see the type comment). A missing last component gives `exists` false;
    /// a missing folder on the way throws `.pathNotFound`.
    func walk(_ path: CDMPath) throws -> Node {
        let node = try resolve(path)
        afterWalk?()
        return node
    }

    private func resolve(_ path: CDMPath) throws -> Node {
        var dir = rootPath
        if path.isRoot {
            var node = Node(parent: nil, name: "", entry: rootPath, real: rootPath, exists: true)
            guard lstat(rootPath, &node.st) == 0 else { throw CDMFSError.pathNotFound }
            return node
        }
        let components = path.components
        // `CDMPath` can be built by anyone: never trust a component to be a plain name.
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else {
            throw CDMFSError.pathNotFound
        }
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            guard let actual = try lookup(component, in: dir) else {
                if last { return Node(parent: dir, name: component, entry: dir + "/" + component, real: dir + "/" + component, exists: false) }
                throw CDMFSError.pathNotFound
            }
            var node = Node(parent: dir, name: actual, entry: dir + "/" + actual, real: dir + "/" + actual, exists: true)
            guard lstat(node.entry, &node.st) == 0 else {
                if last { node.exists = false; return node }
                throw CDMFSError.pathNotFound
            }
            if node.st.st_mode & S_IFMT == S_IFLNK {
                guard let target = Self.realPath(node.entry), inside(target), stat(target, &node.st) == 0 else { throw CDMFSError.escapes }
                node.real = target
                node.isLink = true
            }
            if last { return node }
            guard node.st.st_mode & S_IFMT == S_IFDIR else { throw CDMFSError.pathNotFound }
            dir = node.real
        }
        preconditionFailure("unreachable")
    }

    /// The on-disk name of `component` in `dir` (see `CDMFileSystem`). An exact `lstat` hit counts only if
    /// the on-disk name folds equal too: APFS's own case folding is wider (ß/SS, ligatures).
    func lookup(_ component: String, in dir: String) throws -> String? {
        var st = stat()
        let wanted = CDMNames.fold(component)
        if lstat(dir + "/" + component, &st) == 0, let disk = Self.diskName(dir + "/" + component),
           disk.precomposedStringWithCanonicalMapping == component.precomposedStringWithCanonicalMapping || CDMNames.fold(disk) == wanted {
            return disk
        }
        let matches = try names(in: dir).filter { CDMNames.fold($0) == wanted }
        if let exact = matches.first(where: { $0.precomposedStringWithCanonicalMapping == component.precomposedStringWithCanonicalMapping }) {
            return exact
        }
        guard matches.count <= 1 else { throw CDMFSError.ambiguous }
        return matches.first
    }

    /// The entry's own name as stored (getattrlist ATTR_CMN_NAME, not following a symlink).
    static func diskName(_ path: String) -> String? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_NAME)
        var buffer = [UInt8](repeating: 0, count: 4 + 8 + 1024)
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let offset = Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            let length = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let start = 4 + offset
            guard length > 1, start >= 12, start + length <= raw.count else { return nil }
            return String(decoding: raw[start..<(start + length - 1)], as: UTF8.self)
        }
    }

    /// Opens a folder by its real path without following any symlink; it must be inside the root.
    func openDirectory(_ path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw CDMFSError.from(errno: errno) == .notFound ? CDMFSError.pathNotFound : CDMFSError.from(errno: errno) }
        guard fdInside(fd) else {
            Darwin.close(fd)
            throw CDMFSError.escapes
        }
        return fd
    }

    /// The names in a folder (no "." / ".."), read through a no-follow fd.
    func names(in dir: String) throws -> [String] {
        let fd = try openDirectory(dir)
        guard let stream = fdopendir(fd) else {
            Darwin.close(fd)
            throw CDMFSError.from(errno: errno)
        }
        defer { closedir(stream) }
        var out: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { out.append(name) }
            if out.count > Self.maxEntries { break }
        }
        return out
    }

    /// Runs `body` with the entry's parent folder fd (no-follow, checked) and the entry's name.
    func withParent<T>(_ node: Node, _ body: (Int32, String) throws -> T) throws -> T {
        guard let parent = node.parent else { throw CDMFSError.accessDenied }
        let fd = try openDirectory(parent)
        defer { Darwin.close(fd) }
        return try body(fd, node.name)
    }

    func makeInfo(name: String, _ st: stat) throws -> CDMFileInfo {
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw CDMFSError.unsupported }
        let immutable = st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return CDMFileInfo(name: name.precomposedStringWithCanonicalMapping, isDirectory: type == S_IFDIR,
                           size: type == S_IFREG ? UInt64(max(0, st.st_size)) : 0, modified: mtime,
                           readOnly: st.st_mode & S_IWUSR == 0 || immutable,
                           hidden: name.hasPrefix(".") || st.st_flags & UInt32(UF_HIDDEN) != 0)
    }

    public func info(_ path: CDMPath) throws -> CDMFileInfo {
        let node = try walk(path)
        guard node.exists else { throw CDMFSError.notFound }
        return try makeInfo(name: node.name, node.st)
    }

    public func list(_ directory: CDMPath) throws -> [CDMFileInfo] {
        let node = try walk(directory)
        guard node.exists else { throw CDMFSError.pathNotFound }
        guard node.st.st_mode & S_IFMT == S_IFDIR else { throw CDMFSError.notDirectory }
        let fd = try openDirectory(node.real)
        defer { Darwin.close(fd) }
        var out: [CDMFileInfo] = []
        for name in try names(in: node.real) {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFLNK {
                // Listed only if it stays inside and resolves (it is followed then).
                guard let target = Self.realPath(node.real + "/" + name), inside(target), stat(target, &st) == 0 else { continue }
            }
            guard let info = try? makeInfo(name: name, st) else { continue }
            out.append(info)
            if out.count >= Self.maxEntries { break }
        }
        return out
    }

    /// Checks a freshly opened fd: a regular file inside the root, not hard-linked when written.
    private func verify(_ fd: Int32, write: Bool) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw CDMFSError.unsupported }
        guard fdInside(fd) else { throw CDMFSError.escapes }
        if write, st.st_nlink > 1 { throw CDMFSError.accessDenied }
    }

    public func open(_ path: CDMPath, _ mode: CDMOpenMode) throws -> CDMOpenFile {
        let node = try walk(path)
        let fd: Int32
        let writable: Bool
        let fresh: Bool
        var truncate = false
        switch mode {
        case .createNew:
            guard !isReadOnly else { throw CDMFSError.accessDenied }
            guard !node.exists else { throw CDMFSError.exists }
            fd = try withParent(node) { dir, name in openat(dir, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) }
            writable = true
            fresh = true
        case .existing(let write, let trunc):
            guard !isReadOnly || (!write && !trunc) else { throw CDMFSError.accessDenied }
            guard node.exists else { throw CDMFSError.notFound }
            let type = node.st.st_mode & S_IFMT
            if type == S_IFDIR { throw CDMFSError.isDirectory }
            guard type == S_IFREG else { throw CDMFSError.unsupported }
            // O_NONBLOCK: never hang on a FIFO swapped in meanwhile (it is refused by `verify`). No O_TRUNC:
            // nothing is changed before the fd is verified.
            fd = Darwin.open(node.real, (write || trunc ? O_RDWR : O_RDONLY) | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            writable = write || trunc
            fresh = false
            truncate = trunc
        }
        guard fd >= 0 else { throw CDMFSError.from(errno: errno) }
        do { try verify(fd, write: writable) } catch {
            Darwin.close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let file = CDMPOSIXFile(fd: fd, writable: writable, agent: quarantineAgent)
        if truncate { try file.truncate(to: 0) }
        if fresh { file.markModified() }
        return file
    }

    public func makeDirectory(_ path: CDMPath) throws {
        guard !isReadOnly else { throw CDMFSError.accessDenied }
        let node = try walk(path)
        guard !node.exists else { throw CDMFSError.exists }
        try withParent(node) { dir, name in
            guard mkdirat(dir, name, 0o755) == 0 else { throw CDMFSError.from(errno: errno) }
            let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return }
            Self.setQuarantine(fd: fd, agent: quarantineAgent)
            Darwin.close(fd)
        }
    }

    public func removeFile(_ path: CDMPath) throws {
        guard !isReadOnly, !path.isRoot else { throw CDMFSError.accessDenied }
        let node = try walk(path)
        guard node.exists else { throw CDMFSError.notFound }
        try withParent(node) { dir, name in
            var lst = stat()
            guard fstatat(dir, name, &lst, AT_SYMLINK_NOFOLLOW) == 0 else { throw CDMFSError.from(errno: errno) }
            if lst.st_mode & S_IFMT == S_IFDIR { throw CDMFSError.isDirectory }
            // DOS semantics: a read-only file cannot be deleted (a symlink entry itself has no such bit).
            if lst.st_mode & S_IFMT == S_IFREG, try makeInfo(name: name, lst).readOnly { throw CDMFSError.accessDenied }
            // unlinkat never follows the last component: a symlink entry is removed, not its target.
            guard unlinkat(dir, name, 0) == 0 else { throw CDMFSError.from(errno: errno) }
        }
    }

    public func removeDirectory(_ path: CDMPath) throws {
        guard !isReadOnly, !path.isRoot else { throw CDMFSError.accessDenied }
        let node = try walk(path)
        guard node.exists else { throw CDMFSError.notFound }
        guard !node.isLink, node.st.st_mode & S_IFMT == S_IFDIR else { throw CDMFSError.notDirectory }
        try withParent(node) { dir, name in
            guard unlinkat(dir, name, AT_REMOVEDIR) == 0 else { throw CDMFSError.from(errno: errno) }
        }
    }

    public func rename(_ from: CDMPath, to: CDMPath) throws {
        guard !isReadOnly, !from.isRoot, !to.isRoot, let newName = to.name else { throw CDMFSError.accessDenied }
        let source = try walk(from)
        guard source.exists else { throw CDMFSError.notFound }
        let target = try walk(to)
        try withParent(source) { sourceDir, sourceName in
            try withParent(target) { targetDir, targetName in
                var flags = UInt32(RENAME_EXCL)
                if target.exists {
                    // The same entry under another case or normalisation: a plain rename changes only the name.
                    var a = stat(), b = stat()
                    guard fstatat(sourceDir, sourceName, &a, AT_SYMLINK_NOFOLLOW) == 0,
                          fstatat(targetDir, targetName, &b, AT_SYMLINK_NOFOLLOW) == 0,
                          a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw CDMFSError.exists }
                    flags = 0
                }
                guard renameatx_np(sourceDir, sourceName, targetDir, newName, flags) == 0 else { throw CDMFSError.from(errno: errno) }
            }
        }
    }

    public func setAttributes(_ path: CDMPath, readOnly: Bool, hidden: Bool) throws {
        guard !isReadOnly, !path.isRoot else { throw CDMFSError.accessDenied }
        let node = try walk(path)
        guard node.exists else { throw CDMFSError.notFound }
        let type = node.st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw CDMFSError.unsupported }
        let fd = Darwin.open(node.real, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CDMFSError.from(errno: errno) }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == type, fdInside(fd) else { throw CDMFSError.escapes }
        if type == S_IFREG {
            let mode = readOnly ? st.st_mode & ~S_IWUSR : st.st_mode | S_IWUSR
            if mode != st.st_mode, fchmod(fd, mode & 0o7777) != 0 { throw CDMFSError.from(errno: errno) }
        }
        // A dot-file is hidden by its name; the flag is left alone there.
        if !node.name.hasPrefix(".") {
            let flags = hidden ? st.st_flags | UInt32(UF_HIDDEN) : st.st_flags & ~UInt32(UF_HIDDEN)
            if flags != st.st_flags, fchflags(fd, flags) != 0 { throw CDMFSError.from(errno: errno) }
        }
    }

    // MARK: Quarantine

    public static let quarantineName = "com.apple.quarantine"

    /// `flags;hex time;agent;` — 0x0081: downloaded, not approved by the user (no 0x0040), so Gatekeeper
    /// checks it.
    static func quarantineValue(agent: String) -> [UInt8] {
        Array(String(format: "0081;%08x;%@;", UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)), agent).utf8)
    }

    @discardableResult
    static func setQuarantine(fd: Int32, agent: String) -> Bool {
        let value = quarantineValue(agent: agent)
        return fsetxattr(fd, quarantineName, value, value.count, 0, 0) == 0
    }
}

/// An open regular file of `CDMPOSIXFileSystem`.
final class CDMPOSIXFile: CDMOpenFile {
    private var fd: Int32
    let writable: Bool
    private let agent: String
    private var quarantined = false

    init(fd: Int32, writable: Bool, agent: String) {
        self.fd = fd
        self.writable = writable
        self.agent = agent
    }

    deinit { close() }

    /// Contents come from the session: a fresh quarantine value once per handle, replacing any earlier
    /// value (an old one may carry the user's approval).
    func markModified() {
        guard !quarantined, fd >= 0 else { return }
        quarantined = true
        CDMPOSIXFileSystem.setQuarantine(fd: fd, agent: agent)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard fd >= 0 else { throw CDMFSError.accessDenied }
        var data = Data(count: count)
        var done = 0
        let failure: Int32? = data.withUnsafeMutableBytes { buffer -> Int32? in
            while done < count {
                let n = pread(fd, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return errno }
                if n == 0 { break }
                done += n
            }
            return nil
        }
        if let failure { throw CDMFSError.from(errno: failure) }
        data.count = done
        return data
    }

    func write(_ data: Data, at offset: UInt64) throws -> Int {
        guard fd >= 0, writable else { throw CDMFSError.accessDenied }
        markModified()
        var done = 0
        let failure: Int32? = data.withUnsafeBytes { buffer -> Int32? in
            while done < data.count {
                let n = pwrite(fd, buffer.baseAddress! + done, data.count - done, off_t(offset) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return errno }
                done += n
            }
            return nil
        }
        if let failure, done == 0 { throw CDMFSError.from(errno: failure) }
        return done
    }

    func info() throws -> CDMFileInfo {
        var st = stat()
        guard fd >= 0, fstat(fd, &st) == 0 else { throw CDMFSError.accessDenied }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return CDMFileInfo(name: "", isDirectory: false, size: UInt64(max(0, st.st_size)), modified: mtime,
                           readOnly: st.st_mode & S_IWUSR == 0, hidden: st.st_flags & UInt32(UF_HIDDEN) != 0)
    }

    func truncate(to size: UInt64) throws {
        guard fd >= 0, writable else { throw CDMFSError.accessDenied }
        markModified()
        guard ftruncate(fd, off_t(size)) == 0 else { throw CDMFSError.from(errno: errno) }
    }

    func setModified(_ date: Date) throws {
        guard fd >= 0 else { throw CDMFSError.accessDenied }
        let seconds = date.timeIntervalSince1970
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1e9))]
        guard futimens(fd, &times) == 0 else { throw CDMFSError.from(errno: errno) }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
