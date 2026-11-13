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

/// A Mac file offered to the host (Mac → session): its descriptor entry and a reader. The file is opened
/// once (read-only, no symlink follow) so a later rename or swap on disk cannot change what is served.
public final class ClipboardLocalFile: @unchecked Sendable {
    public let entry: ClipboardFileEntry
    private let handle: FileHandle?
    private let lock = NSLock()

    public init(entry: ClipboardFileEntry, handle: FileHandle?) {
        self.entry = entry
        self.handle = handle
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

    /// `length` bytes from `offset` (fewer at the end of the file); nil on error.
    public func read(offset: UInt64 = 0, length: Int? = nil) -> Data? {
        guard let handle else { return nil }
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seek(toOffset: offset)
            let want = length ?? Int(clamping: entry.size &- min(offset, entry.size))
            return try handle.read(upToCount: want) ?? Data()
        } catch {
            return nil
        }
    }
}
