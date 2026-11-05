import Foundation
import PDFKit

/// Checks a job's data before anything is shown (docs/97 §6.3 step 1; PDFKit replaces the reference's
/// text checks of §3.9). Thread-safe: uses its own `PDFDocument`.
public enum PrintDocument {
    public struct Info: Equatable, Sendable {
        public var pageCount: Int
        /// The PDF `Title` attribute, if any. For the UI only: never log it (log its length).
        public var title: String?
        public var byteCount: Int
        /// The data ends with `%%EOF` (optionally followed by whitespace), as the reference requires.
        public var hasEOF: Bool
        public var producerLength: Int
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case empty
        case notPDF
        case unreadable
        case locked
        case noPages

        public var description: String {
            switch self {
            case .empty: return "no data"
            case .notPDF: return "not a PDF (no %PDF- header)"
            case .unreadable: return "PDFKit cannot read it"
            case .locked: return "password protected"
            case .noPages: return "no pages"
            }
        }
    }

    /// `%PDF-` must start within the first 1024 bytes (PDF 1.7 §7.5.2 tolerates leading junk).
    public static func hasHeader(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(1024)), magic = Array("%PDF-".utf8)
        guard head.count >= magic.count else { return false }
        return (0...(head.count - magic.count)).contains { head[$0..<$0 + magic.count].elementsEqual(magic) }
    }

    public static func endsWithEOF(_ data: Data) -> Bool {
        var tail = [UInt8](data.suffix(32))
        while let last = tail.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x00 { tail.removeLast() }
        return tail.suffix(5).elementsEqual(Array("%%EOF".utf8))
    }

    public static func inspect(_ data: Data) -> Result<Info, Refusal> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard hasHeader(data) else { return .failure(.notPDF) }
        guard let document = PDFDocument(data: data) else { return .failure(.unreadable) }
        guard !document.isLocked else { return .failure(.locked) }
        guard document.pageCount > 0 else { return .failure(.noPages) }
        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String
        return .success(Info(pageCount: document.pageCount, title: title?.isEmpty == false ? title : nil, byteCount: data.count,
                             hasEOF: endsWithEOF(data), producerLength: producer?.count ?? 0))
    }

    /// Longest file name produced, in UTF-8 bytes including ".pdf" (APFS allows 255).
    public static let maxFileNameBytes = 200

    /// A file name from a document title: no path separators or control characters, at most
    /// `maxFileNameBytes` UTF-8 bytes (whole characters), never empty or hidden.
    public static func fileName(title: String?, fallback: String) -> String {
        let cleaned = (title ?? "").unicodeScalars.map { s -> Character in
            s.value < 0x20 || s.value == 0x7F || "/:\\".unicodeScalars.contains(s) ? "_" : Character(s)
        }
        var name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = fallback }
        let limit = maxFileNameBytes - 4
        var out = "", bytes = 0
        for c in name {
            let n = String(c).utf8.count
            guard bytes + n <= limit else { break }
            out.append(c)
            bytes += n
        }
        return (out.isEmpty ? String(fallback.utf8.prefix(limit)) ?? "Print job" : out) + ".pdf"
    }
}

/// Print job files: one folder per process, `<pid>-<uuid>`, under `~/Library/Caches/ICAViewer/print/` (0700),
/// files 0600. The folder is removed at quit (`removeAll`); `removeStale` removes folders of processes that
/// are gone (docs/97 §6.3 step 5), never those of a running ICAViewer. At most `maxBytes` are held.
public final class PrintSpool: @unchecked Sendable {
    public let base: URL
    public let folder: URL
    /// Total size of the files this spool holds at once; a write beyond it fails with `.full`.
    public let maxBytes: Int
    private let lock = NSLock()
    private var sizes: [URL: Int] = [:]

    /// Bytes currently held.
    public var heldBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return sizes.values.reduce(0, +)
    }

    public static var defaultBase: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("ICAViewer", isDirectory: true).appendingPathComponent("print", isDirectory: true)
    }

    public init(base: URL = PrintSpool.defaultBase, maxBytes: Int = 1 << 30, pid: Int32 = getpid()) {
        self.base = base
        self.maxBytes = maxBytes
        folder = base.appendingPathComponent("\(pid)-\(UUID().uuidString)", isDirectory: true)
    }

    public enum Failure: Error, CustomStringConvertible {
        case create(String, Int32)
        case full(Int)
        public var description: String {
            switch self {
            case let .create(what, code): return "cannot create \(what): \(String(cString: strerror(code)))"
            case .full(let limit): return "the print spool is full (\(limit >> 20) MiB held)"
            }
        }
    }

    private func makeDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw Failure.create("folder", errno) }
    }

    /// Writes `data` as a new 0600 file named `name` (a job subfolder keeps names unique). Any thread.
    public func write(_ data: Data, name: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard sizes.values.reduce(0, +) + data.count <= maxBytes else { throw Failure.full(maxBytes) }
        try makeDirectory(base.deletingLastPathComponent())
        try makeDirectory(base)
        try makeDirectory(folder)
        let jobFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try makeDirectory(jobFolder)
        let url = jobFolder.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.create("file", errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data) } catch {
            try? FileManager.default.removeItem(at: jobFolder)
            throw error
        }
        sizes[url] = data.count
        return url
    }

    /// Removes one job file and its folder.
    public func remove(_ url: URL) {
        let jobFolder = url.deletingLastPathComponent()
        guard jobFolder.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: jobFolder)
        lock.lock()
        sizes[url] = nil
        lock.unlock()
    }

    /// Removes this process's folder (at quit).
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder)
        sizes = [:]
    }

    /// Whether process `pid` still runs (EPERM: it runs under another user).
    public static func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Removes folders `<pid>-…` whose process is gone; folders in another format only when last changed more
    /// than `age` ago. Never this spool's own folder.
    public func removeStale(olderThan age: TimeInterval = 86_400, now: Date = Date(),
                            alive: (Int32) -> Bool = PrintSpool.processAlive) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items where item.standardizedFileURL != folder.standardizedFileURL {
            let name = item.lastPathComponent
            if let dash = name.firstIndex(of: "-"), let pid = Int32(name[..<dash]), pid > 0 {
                if !alive(pid) { try? fm.removeItem(at: item) }
                continue
            }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > age { try? fm.removeItem(at: item) }
        }
    }
}

/// The printing setting (docs/97 §6.2 feature switch, D24): receive jobs for the host's Citrix PDF
/// Printer, and which action the job window offers first. Applies at connect.
public struct PrintSettings: Equatable, Sendable {
    public enum Action: String, Sendable, CaseIterable {
        /// The macOS print panel (PDFKit print operation).
        case printDialog = "print"
        /// Open the PDF in Preview.
        case preview
    }

    /// Off until the live checks L1–L3 (docs/97 §10) pass (§6.2: "default on once L1–L3 pass").
    public static let defaultEnabled = false

    public var enabled = PrintSettings.defaultEnabled
    public var action = Action.printDialog

    public init() {}

    public static let enabledKey = "printing.enabled"
    public static let actionKey = "printing.action"

    /// From UserDefaults; ICA_PRINTING=0/1 and ICA_PRINT_ACTION=print|preview override (automated runs).
    public static func load(defaults: UserDefaults = .standard,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> PrintSettings {
        var s = PrintSettings()
        if defaults.object(forKey: enabledKey) != nil { s.enabled = defaults.bool(forKey: enabledKey) }
        if let a = defaults.string(forKey: actionKey).flatMap(Action.init(rawValue:)) { s.action = a }
        if let v = env["ICA_PRINTING"]?.lowercased() {
            if ["0", "off", "no"].contains(v) { s.enabled = false } else if ["1", "on", "yes"].contains(v) { s.enabled = true }
        }
        if let a = env["ICA_PRINT_ACTION"].flatMap({ Action(rawValue: $0.lowercased()) }) { s.action = a }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(action.rawValue, forKey: Self.actionKey)
    }
}
