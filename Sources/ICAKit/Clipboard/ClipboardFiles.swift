import Foundation

/// Clipboard files as the Windows shell formats `FileGroupDescriptorW` / `FileContents` (docs/75 §5).
/// Experimental: used only with `ClipboardEngine.Config.files` (the v4 discovery test, docs/75 §10).
public enum ClipboardFileFormat {
    public static let groupDescriptorName = "FileGroupDescriptorW"
    public static let contentsName = "FileContents"
}

/// One FILEDESCRIPTORW entry (docs/75 §5): a relative Windows path (`dir\file.txt`), size, write time, attributes.
public struct ClipboardFileEntry: Equatable, Sendable {
    public var name: String
    public var size: UInt64
    public var writeTime: Date?
    public var isDirectory: Bool
    /// FILE_ATTRIBUTE_* as sent or received.
    public var attributes: UInt32
    /// dwFlags as sent or received.
    public var flags: UInt32

    public init(name: String, size: UInt64, writeTime: Date? = nil, isDirectory: Bool = false, hidden: Bool = false) {
        self.name = name
        self.size = isDirectory ? 0 : size
        self.writeTime = writeTime
        self.isDirectory = isDirectory
        attributes = isDirectory ? ClipboardFileGroup.attributeDirectory | (hidden ? ClipboardFileGroup.attributeHidden : 0)
            : (hidden ? ClipboardFileGroup.attributeHidden : ClipboardFileGroup.attributeNormal)
        flags = ClipboardFileGroup.flagsSent
    }

    public init(name: String, size: UInt64, writeTime: Date?, attributes: UInt32, flags: UInt32) {
        self.name = name
        self.size = size
        self.writeTime = writeTime
        self.attributes = attributes
        self.flags = flags
        isDirectory = attributes & ClipboardFileGroup.attributeDirectory != 0
    }
}

/// FILEGROUPDESCRIPTORW: `u32 cItems` + cItems × 592-byte FILEDESCRIPTORW, little-endian (docs/75 §5).
public enum ClipboardFileGroup {
    public static let entrySize = 592
    public static let nameOffset = 72
    /// WCHAR[260] including the terminating NUL.
    public static let nameUnits = 260

    // dwFlags
    public static let fdAttributes: UInt32 = 0x0004
    public static let fdWriteTime: UInt32 = 0x0020
    public static let fdFileSize: UInt32 = 0x0040
    public static let fdProgressUI: UInt32 = 0x4000
    public static let fdUnicode: UInt32 = 0x8000_0000
    /// What we send (docs/75 §7.2 step 3).
    public static let flagsSent = fdAttributes | fdWriteTime | fdFileSize | fdProgressUI | fdUnicode

    // dwFileAttributes
    public static let attributeHidden: UInt32 = 0x0002
    public static let attributeDirectory: UInt32 = 0x0010
    public static let attributeNormal: UInt32 = 0x0080

    public enum Failure: Error, Equatable {
        case truncated(Int)
        case count(UInt32)
        case length(expected: Int, actual: Int)
        case nameTooLong(String)
    }

    /// 100 ns intervals between 1601-01-01 and 1970-01-01.
    static let epochDelta: UInt64 = 116_444_736_000_000_000

    public static func fileTime(_ date: Date) -> UInt64 {
        let t = date.timeIntervalSince1970
        guard t > -11_644_473_600 else { return 0 }
        return UInt64((t * 10_000_000).rounded()) &+ epochDelta
    }

    public static func date(fileTime: UInt64) -> Date? {
        guard fileTime != 0 else { return nil }
        return Date(timeIntervalSince1970: (Double(fileTime) - Double(epochDelta)) / 10_000_000)
    }

    public static func build(_ entries: [ClipboardFileEntry]) throws -> Data {
        var w = ByteWriter()
        w.u32(UInt32(entries.count))
        for e in entries {
            let units = Array(e.name.utf16)
            guard units.count < nameUnits else { throw Failure.nameTooLong(e.name) }
            let flags = e.writeTime == nil ? e.flags & ~fdWriteTime : e.flags
            w.u32(flags)
            w.raw([UInt8](repeating: 0, count: 16 + 8 + 8))   // clsid, sizel, pointl
            w.u32(e.attributes)
            w.raw([UInt8](repeating: 0, count: 16))            // creation and access time
            let ft = e.writeTime.map(fileTime) ?? 0
            w.u32(UInt32(ft & 0xFFFF_FFFF))
            w.u32(UInt32(ft >> 32))
            w.u32(UInt32(e.size >> 32))
            w.u32(UInt32(e.size & 0xFFFF_FFFF))
            for u in units { w.u16(u) }
            w.raw([UInt8](repeating: 0, count: 2 * (nameUnits - units.count)))
        }
        return w.data
    }

    /// Strict: the length must be exactly 4 + 592·n, n ≥ 1 and ≤ `maxEntries`.
    public static func parse(_ data: Data, maxEntries: Int = 1000) throws -> [ClipboardFileEntry] {
        let b = [UInt8](data)
        guard b.count >= 4 else { throw Failure.truncated(b.count) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        let n = u32(0)
        guard n >= 1, n <= UInt32(maxEntries) else { throw Failure.count(n) }
        let expected = 4 + Int(n) * entrySize
        // Some writers pad the HGLOBAL; accept trailing bytes but never fewer.
        guard b.count >= expected else { throw Failure.length(expected: expected, actual: b.count) }
        return (0..<Int(n)).map { i in
            let o = 4 + i * entrySize
            var units: [UInt16] = []
            for k in 0..<nameUnits {
                let u = UInt16(b[o + nameOffset + 2 * k]) | UInt16(b[o + nameOffset + 2 * k + 1]) << 8
                if u == 0 { break }
                units.append(u)
            }
            let flags = u32(o)
            let ft = UInt64(u32(o + 56)) | UInt64(u32(o + 60)) << 32
            let size = UInt64(u32(o + 64)) << 32 | UInt64(u32(o + 68))
            return ClipboardFileEntry(name: String(decoding: units, as: UTF16.self),
                                      size: flags & fdFileSize != 0 ? size : 0,
                                      writeTime: flags & fdWriteTime != 0 ? date(fileTime: ft) : nil,
                                      attributes: flags & fdAttributes != 0 ? u32(o + 36) : 0, flags: flags)
        }
    }

    /// Windows name rules for one path component (docs/75 §7.2 step 5): `<>:"/\|?*` and U+0000–U+001F
    /// become `_`, trailing dots and spaces are stripped, reserved device names get a `_` prefix.
    public static func windowsComponent(_ name: String) -> String {
        var out = String(name.unicodeScalars.map { s -> Character in
            "<>:\"/\\|?*".unicodeScalars.contains(s) || s.value < 0x20 ? "_" : Character(s)
        })
        while let last = out.last, last == "." || last == " " { out.removeLast() }
        if out.isEmpty { out = "_" }
        let stem = out.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })
        if reserved.contains(stem) { out = "_" + out }
        return out
    }
}

/// A Mac file offered to the host (Mac → session): its descriptor entry and a reader. Either the file is opened once
/// (`open`, read-only, no symlink follow: icactl), or it is opened at each read by path and must still be the same file
/// (device and inode of the snapshot, `snapshot`), so a later rename or swap on disk cannot change what is served and
/// no descriptor stays open per offered file. A directory entry has neither and reads as nil.
public final class ClipboardLocalFile: @unchecked Sendable {
    public let entry: ClipboardFileEntry
    private let handle: FileHandle?
    private let path: String?
    private let identity: (device: UInt64, inode: UInt64)?
    private let lock = NSLock()

    public init(entry: ClipboardFileEntry, handle: FileHandle?) {
        self.entry = entry
        self.handle = handle
        path = nil
        identity = nil
    }

    /// Reads by path; `device`/`inode` are the snapshot's (`stat`).
    public init(entry: ClipboardFileEntry, path: String, device: UInt64, inode: UInt64) {
        self.entry = entry
        handle = nil
        self.path = path
        identity = (device, inode)
    }

    /// Opens a regular file; nil for anything else (symlink, directory, device) or on error.
    public static func open(_ url: URL, name: String) -> ClipboardLocalFile? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let entry = ClipboardFileEntry(name: ClipboardFileGroup.windowsComponent(name), size: UInt64(st.st_size), writeTime: mtime,
                                       hidden: name.hasPrefix("."))
        return ClipboardLocalFile(entry: entry, handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    /// The regular files directly in `directory` (no recursion), sorted by name.
    public static func load(directory: URL) -> [ClipboardLocalFile] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        return names.compactMap { open(directory.appendingPathComponent($0), name: $0) }
    }

    /// The same regular file as at the snapshot, opened read-only without following a symlink; -1 otherwise.
    private func openSame() -> Int32 {
        guard let path, let identity else { return -1 }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return -1 }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              UInt64(st.st_dev) == identity.device, UInt64(st.st_ino) == identity.inode else { close(fd); return -1 }
        return fd
    }

    /// Whether the file can be read now (by-path files: still the snapshot's file).
    public var isReadable: Bool {
        if entry.isDirectory { return false }
        if handle != nil { return true }
        let fd = openSame()
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    /// `length` bytes from `offset` (fewer at the end of the file); nil on error.
    public func read(offset: UInt64 = 0, length: Int? = nil) -> Data? {
        let want = length ?? Int(clamping: entry.size &- min(offset, entry.size))
        if let handle {
            lock.lock()
            defer { lock.unlock() }
            do {
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: want) ?? Data()
            } catch {
                return nil
            }
        }
        let fd = openSame()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out = Data(count: max(0, want))
        var got = 0
        let ok: Bool = out.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            while got < want {
                let n = pread(fd, base + got, want - got, off_t(offset) + off_t(got))
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { break }
                got += n
            }
            return true
        }
        guard ok else { return nil }
        out.count = got
        return out
    }
}

/// The Mac pasteboard's files as one FILEGROUPDESCRIPTORW (Mac → session, docs/75 §7.2): folders are walked depth-first
/// into DIRECTORY entries followed by their contents with relative `dir\sub\file` names (Explorer's convention);
/// each name follows the Windows rules (`windowsComponent`), is NFC and unique per folder (case-insensitive). Files are
/// read later, by path, only while they are still the same file (`ClipboardLocalFile`). Symbolic links, devices and
/// unreadable items are left out and listed in `skipped`; Finder's `.DS_Store` and AppleDouble `._*` files are left
/// out silently. Over a cap nothing is offered (`refused`).
public struct ClipboardFileSnapshot {
    public struct Limits: Sendable {
        public var maxEntries = 1000
        /// Total bytes of all files (FD_FILESIZE carries 64 bits, but one Read count is a u32).
        public var maxTotal: UInt64 = 4 << 30
        /// A relative path in cFileName: WCHAR[260] with its NUL.
        public var maxPathUnits = 259
        public init() {}
    }

    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case tooMany(Int)
        case tooLarge(UInt64)
        public var description: String {
            switch self {
            case .tooMany(let n): return "more than \(n) files and folders"
            case .tooLarge(let n): return "more than \(n >> 20) MB"
            }
        }
    }

    /// Descriptor order: each folder before its contents.
    public var files: [ClipboardLocalFile] = []
    /// Mac names (relative to the copied item) and why they were left out.
    public var skipped: [(name: String, why: String)] = []
    public var refused: Refusal?
    public var entries: [ClipboardFileEntry] { files.map(\.entry) }
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.entry.size } }

    public static func make(urls: [URL], limits: Limits = Limits()) -> ClipboardFileSnapshot {
        var s = ClipboardFileSnapshot()
        var topNames = Set<String>()
        for url in urls where url.isFileURL {
            if s.refused != nil { break }
            s.add(path: url.path, macName: url.lastPathComponent, parent: nil, used: &topNames, limits: limits)
        }
        if s.refused != nil { s.files = [] }
        return s
    }

    static func ignored(_ name: String) -> Bool { name == ".DS_Store" || name.hasPrefix("._") }

    /// `name` as a Windows component, NFC, unique among `used` (lowercased): "name (2).ext".
    static func uniqueComponent(_ macName: String, used: inout Set<String>) -> String {
        let base = ClipboardFileGroup.windowsComponent(macName.precomposedStringWithCanonicalMapping)
        var candidate = base
        var n = 1
        while used.contains(candidate.lowercased()) {
            n += 1
            let ext = (base as NSString).pathExtension
            let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private mutating func add(path: String, macName: String, parent: (windows: String, mac: String)?, used: inout Set<String>, limits: Limits) {
        let shown = parent.map { $0.mac + "/" + macName } ?? macName
        var st = stat()
        guard lstat(path, &st) == 0 else { return skipped.append((shown, "not found")) }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else {
            return skipped.append((shown, kind == S_IFLNK ? "a symbolic link or alias" : "not a file or folder"))
        }
        let component = Self.uniqueComponent(macName, used: &used)
        let windows = parent.map { $0.windows + "\\" + component } ?? component
        guard windows.utf16.count <= limits.maxPathUnits else { return skipped.append((shown, "path too long for Windows")) }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let hidden = macName.hasPrefix(".") || st.st_flags & UInt32(UF_HIDDEN) != 0
        if kind == S_IFREG {
            guard access(path, R_OK) == 0 else { return skipped.append((shown, "not readable")) }
            let size = UInt64(max(0, st.st_size))
            guard totalBytes + size <= limits.maxTotal else { refused = .tooLarge(limits.maxTotal); return }
            guard files.count < limits.maxEntries else { refused = .tooMany(limits.maxEntries); return }
            let entry = ClipboardFileEntry(name: windows, size: size, writeTime: mtime, hidden: hidden)
            files.append(ClipboardLocalFile(entry: entry, path: path, device: UInt64(st.st_dev), inode: UInt64(st.st_ino)))
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return skipped.append((shown, "folder not readable"))
        }
        guard files.count < limits.maxEntries else { refused = .tooMany(limits.maxEntries); return }
        files.append(ClipboardLocalFile(entry: ClipboardFileEntry(name: windows, size: 0, writeTime: mtime, isDirectory: true, hidden: hidden),
                                        handle: nil))
        var inner = Set<String>()
        for name in names.sorted() where !Self.ignored(name) {
            if refused != nil { return }
            add(path: (path as NSString).appendingPathComponent(name), macName: name, parent: (windows, shown), used: &inner, limits: limits)
        }
    }
}
