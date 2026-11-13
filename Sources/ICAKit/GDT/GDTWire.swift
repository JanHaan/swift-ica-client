import Foundation

/// `CTXGDT` (docs/76-gdt.md): the channel the stock Mac client uses for clipboard file contents (D57). Only the
/// name, the number and the version are known [B]; the message layout is being discovered from the host's writes
/// to our own client, so this file holds constants and the discovery hex logger, no message parser.
public enum GDTWire {
    /// 6 characters plus NUL, like `CTXTWI\0` (docs/30 §10); the bind entry is `43 54 58 47 44 54 00 00 1D 00`.
    public static let channelName = "CTXGDT\0"
    /// The stock client logs ch 29 [B]. The host maps names to numbers through our bind table, so the number is
    /// ours to choose; 29 keeps the traces comparable.
    public static let channelNumber: UInt8 = 29
    /// The stock client logs version 1 [B]: min 1 / max 1, host module name "ICA" (the generic VD, docs/30 §5.5).
    public static let versionLow: UInt8 = 1
    public static let versionHigh: UInt8 = 1

    /// TYMED values (Microsoft Learn, TYMED enumeration) [P]; candidates for the `tymed` field of GetData (§3).
    public enum TYMED {
        public static let hglobal: UInt32 = 1, file: UInt32 = 2, istream: UInt32 = 4, istorage: UInt32 = 8
        public static let gdi: UInt32 = 16, mfpict: UInt32 = 32, enhmf: UInt32 = 64, null: UInt32 = 0
    }
    /// sizeof(FILEDESCRIPTORW) (Microsoft Learn) [P].
    public static let fileDescriptorSize = 592
}

/// One host write on CTXGDT (one reassembled WD virtual write, docs/30 §9.3), as the discovery log shows it.
public struct GDTHostWrite: Sendable, Equatable {
    /// 1-based, in arrival order.
    public var index: Int
    /// Seconds since the engine was created.
    public var elapsed: TimeInterval
    /// WD packet type that carried it (0x2F/0x30/0x31), when the session reported it.
    public var wdType: UInt8?
    public var bytes: [UInt8]

    public init(index: Int, elapsed: TimeInterval, wdType: UInt8?, bytes: [UInt8]) {
        self.index = index
        self.elapsed = elapsed
        self.wdType = wdType
        self.bytes = bytes
    }
}

/// The discovery hex logger: header candidates (the first 16 bytes as u8, u16 LE and u32 LE), the total length,
/// up to `limit` payload bytes in hex, and printable ASCII / UTF-16LE runs (format and file names show up there).
public enum GDTHexLog {
    public static let defaultLimit = 256

    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Little-endian u16 / u32 words of the first `count` bytes (incomplete tail words are left out).
    public static func words(_ bytes: [UInt8], size: Int, count: Int = 16) -> [UInt32] {
        let head = Array(bytes.prefix(count))
        return stride(from: 0, to: head.count - size + 1, by: size).map { at in
            (0..<size).reduce(UInt32(0)) { $0 | UInt32(head[at + $1]) << (8 * UInt32($1)) }
        }
    }

    /// The header candidates in one line: `u16 0001 002c … u32 0x002c0001 …`.
    public static func header(_ bytes: [UInt8]) -> String {
        let u16 = words(bytes, size: 2).map { String(format: "%04x", $0) }.joined(separator: " ")
        let u32 = words(bytes, size: 4).map { String(format: "0x%08x", $0) }.joined(separator: " ")
        return "u16 [\(u16)] u32 [\(u32)]"
    }

    /// Printable runs of at least `minimum` characters: ASCII bytes, and UTF-16LE code units < 0x80 at either
    /// alignment. Each as `@offset "text"` (`a` ASCII, `w` UTF-16LE).
    public static func strings(_ bytes: [UInt8], minimum: Int = 4) -> [String] {
        func printable(_ b: UInt8) -> Bool { b >= 0x20 && b < 0x7F }
        var found: [String] = []
        var start = -1
        for i in 0...bytes.count {
            if i < bytes.count, printable(bytes[i]) { if start < 0 { start = i }; continue }
            if start >= 0, i - start >= minimum, let text = String(bytes: bytes[start..<i], encoding: .ascii) {
                found.append("a@\(start) \"\(text)\"")
            }
            start = -1
        }
        for phase in 0..<2 {
            var run: [UInt8] = []
            var at = 0
            func flush() {
                if run.count >= minimum, let text = String(bytes: run, encoding: .ascii) { found.append("w@\(at) \"\(text)\"") }
                run = []
            }
            var i = phase
            while i + 1 < bytes.count {
                if printable(bytes[i]) && bytes[i + 1] == 0 {
                    if run.isEmpty { at = i }
                    run.append(bytes[i])
                } else {
                    flush()
                }
                i += 2
            }
            flush()
        }
        return found
    }

    /// One line per write, for the main log.
    public static func line(_ w: GDTHostWrite, direction: String = "←", limit: Int = defaultLimit) -> String {
        var text = String(format: "%@ GDT #%d +%.3fs", direction, w.index, w.elapsed)
        if let type = w.wdType { text += String(format: " wd 0x%02x", type) }
        text += " total \(w.bytes.count) B"
        guard !w.bytes.isEmpty else { return text }
        text += " | " + header(w.bytes)
        text += " | " + hex(w.bytes.prefix(limit)) + (w.bytes.count > limit ? " …" : "")
        let found = strings(w.bytes)
        if !found.isEmpty { text += " | strings " + found.joined(separator: ", ") }
        return text
    }

    /// The `line` plus a 16-bytes-per-row dump with offsets (up to `limit` bytes), for `.session/gdt/<run>.log`.
    public static func dump(_ w: GDTHostWrite, direction: String = "←", limit: Int = defaultLimit) -> [String] {
        var lines = [line(w, direction: direction, limit: limit)]
        let shown = Array(w.bytes.prefix(limit))
        for row in stride(from: 0, to: shown.count, by: 16) {
            let slice = shown[row..<min(shown.count, row + 16)]
            let ascii = String(slice.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "    %04x  ", row) + hex(slice).padding(toLength: 47, withPad: " ", startingAt: 0) + "  |" + ascii + "|")
        }
        if w.bytes.count > limit { lines.append("    … \(w.bytes.count - limit) more bytes not shown") }
        return lines
    }
}

/// Counters over all host writes (the cliptest-files summary).
public struct GDTStatistics: Sendable, Equatable {
    public private(set) var packets = 0
    public private(set) var bytes = 0
    /// First byte → count (empty writes are not counted here).
    public private(set) var leadingBytes: [UInt8: Int] = [:]
    /// First u16 LE → count (writes of at least 2 bytes).
    public private(set) var leadingWords: [UInt16: Int] = [:]
    /// Sizes in arrival order, the first `sizeCap` only.
    public private(set) var sizes: [Int] = []
    public private(set) var minSize: Int?
    public private(set) var maxSize: Int?
    public static let sizeCap = 64

    public init() {}

    public mutating func add(_ data: [UInt8]) {
        packets += 1
        bytes += data.count
        if let first = data.first { leadingBytes[first, default: 0] += 1 }
        if data.count >= 2 { leadingWords[UInt16(data[0]) | UInt16(data[1]) << 8, default: 0] += 1 }
        if sizes.count < Self.sizeCap { sizes.append(data.count) }
        minSize = min(minSize ?? data.count, data.count)
        maxSize = max(maxSize ?? data.count, data.count)
    }

    public var summary: String {
        guard packets > 0 else { return "0 host GDT packets" }
        let lead = leadingBytes.sorted { $0.key < $1.key }.map { String(format: "%02x×%d", $0.key, $0.value) }.joined(separator: " ")
        let words = leadingWords.sorted { $0.key < $1.key }.map { String(format: "%04x×%d", $0.key, $0.value) }.joined(separator: " ")
        return "\(packets) host GDT packets, \(bytes) B, sizes \(minSize ?? 0)…\(maxSize ?? 0) [" +
            sizes.map(String.init).joined(separator: " ") + (packets > sizes.count ? " …" : "") +
            "], leading bytes {\(lead)}, leading u16 {\(words)}"
    }
}

/// `.session/gdt/<run>.log`-style file (directory 0700, file 0600), one line per call, time-stamped. Test data only:
/// the discovery runs carry nothing but the test's own files.
public final class GDTLogFile: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private let start: Date

    public init(directory: URL, runID: String, start: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("\(runID).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        self.start = start
    }

    deinit { try? handle.close() }

    public func write(_ lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = String(format: "%8.3f ", Date().timeIntervalSince(start))
        handle.write(Data(lines.enumerated().map { ($0.offset == 0 ? stamp : String(repeating: " ", count: stamp.count)) + $0.element + "\n" }
            .joined().utf8))
    }

    public func write(_ line: String) { write([line]) }
}
