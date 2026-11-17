import CryptoKit
import Foundation

/// Checks for `icactl fetch-file` (one named file from a session's Explorer to the Mac over CTXGDT): the host path,
/// the session gate, the host's file group, the local destination, progress and the file's SHA-256. No I/O to the
/// session here; everything is pure or local.
public enum HostFileFetch {
    /// Characters a Windows file name may not contain (plus control characters).
    static let forbidden = Set("<>:\"/\\|?*")

    /// `H:\dir\file.ext` → folder `H:\dir` (`H:\` for the root) and leaf `file.ext`; also `\\server\share\file`.
    /// Nil for a relative path, an empty or invalid leaf, wildcards, `.`/`..` segments or a trailing dot or space.
    public static func split(_ path: String) -> (folder: String, name: String)? {
        guard !path.contains("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        let isDrive = path.count >= 3 && path.first!.isASCII && path.first!.isLetter
            && path.dropFirst().hasPrefix(":\\")
        let isUNC = path.hasPrefix("\\\\")
        guard isDrive || isUNC else { return nil }
        guard let cut = path.lastIndex(of: "\\") else { return nil }
        let name = String(path[path.index(after: cut)...])
        guard isValidName(name) else { return nil }
        var folder = String(path[..<cut])
        let segments = folder.split(separator: "\\", omittingEmptySubsequences: true).dropFirst()
        guard !segments.contains(where: { $0 == "." || $0 == ".." || !isValidName(String($0)) }) else { return nil }
        if isDrive {
            if folder.count == 2 { folder += "\\" }   // H: → H:\ (the drive root)
        } else {
            // \\server\share at least, and the file sits in or below the share.
            guard folder.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false).count >= 2,
                  !folder.dropFirst(2).contains("\\\\") else { return nil }
        }
        return (folder, name)
    }

    /// A single Windows file name: non-empty, at most 255 UTF-16 units, no forbidden characters, not `.`/`..`, no
    /// trailing dot or space.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf16.count <= 255, name != ".", name != ".." else { return false }
        guard !name.contains(where: { forbidden.contains($0) }), !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return false }
        return !name.hasSuffix(".") && !name.hasSuffix(" ")
    }

    public enum GroupProblem: Error, Equatable, CustomStringConvertible {
        case empty
        case count(Int)
        case otherName(String)
        case directory
        case sizeUnknown
        case tooLarge(size: UInt64, cap: UInt64)

        public var description: String {
            switch self {
            case .empty: return "the host's file list is empty"
            case .count(let n): return "the host's file list has \(n) entries, expected exactly 1"
            case .otherName(let n): return "the host's only entry is \"\(n)\", not the requested file"
            case .directory: return "the host's only entry is a folder"
            case .sizeUnknown: return "the host does not announce the file's size"
            case .tooLarge(let s, let cap): return "\(s) B is over the \(cap) B cap"
            }
        }
    }

    /// The host's file group must be exactly one regular file named `name` (Windows: case-insensitive), with a
    /// known size of at most `cap` bytes.
    public static func check(_ entries: [ClipboardFileEntry], name: String, cap: UInt64) -> Result<ClipboardFileEntry, GroupProblem> {
        guard !entries.isEmpty else { return .failure(.empty) }
        guard entries.count == 1 else { return .failure(.count(entries.count)) }
        let e = entries[0]
        guard e.name.caseInsensitiveCompare(name) == .orderedSame, !e.name.contains("\\"), !e.name.contains("/") else {
            return .failure(.otherName(e.name))
        }
        guard !e.isDirectory else { return .failure(.directory) }
        guard e.flags & ClipboardFileGroup.fdFileSize != 0 else { return .failure(.sizeUnknown) }
        guard e.size <= cap else { return .failure(.tooLarge(size: e.size, cap: cap)) }
        return .success(e)
    }

    /// True if any of the session's app names is in the ABC test group (`… ABC`, case-insensitive).
    public static func isTestGroup(appNames: [String]) -> Bool {
        appNames.contains { $0.trimmingCharacters(in: .whitespaces).uppercased().hasSuffix(" ABC") }
    }

    /// A destination in `directory` that does not exist yet: `name`, else `stem-2.ext`, `stem-3.ext`, …
    public static func destination(in directory: URL, name: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let first = directory.appendingPathComponent(name)
        if !exists(first.path) { return first }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        while true {
            let url = directory.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            if !exists(url.path) { return url }
            n += 1
        }
    }

    /// Progress lines every `step` bytes (and at the end); feed it the running byte count.
    public struct Progress {
        public let total: UInt64
        public let step: UInt64
        private var next: UInt64
        private var finished = false

        public init(total: UInt64, step: UInt64 = 4 << 20) {
            self.total = total
            self.step = max(1, step)
            next = self.step
        }

        /// The line to print for `bytes` written so far: at each step boundary crossed and once at `total`.
        public mutating func update(_ bytes: UInt64, elapsed: TimeInterval) -> String? {
            guard !finished else { return nil }
            if bytes >= total { finished = true } else if bytes >= next { next = (bytes / step + 1) * step } else { return nil }
            return Self.line(bytes, total: total, elapsed: elapsed)
        }

        public static func line(_ bytes: UInt64, total: UInt64, elapsed: TimeInterval) -> String {
            let mib = Double(bytes) / 1_048_576
            let pct = total > 0 ? Double(bytes) * 100 / Double(total) : 100
            let rate = elapsed > 0 ? mib / elapsed : 0
            return String(format: "%.1f of %.1f MiB (%.0f %%), %.2f MiB/s", mib, Double(total) / 1_048_576, pct, rate)
        }
    }

    /// SHA-256 of a file, read in 1 MiB slices (the file is never held in memory).
    public static func sha256(fileAt url: URL) throws -> (hex: String, bytes: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: UInt64 = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
            bytes += UInt64(data.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}
