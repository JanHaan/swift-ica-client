import Foundation

/// The drive server behind `CTXCDM ` (docs/95 §A.3–§A.5, §A.8 step 3): one request in, at most one reply
/// out, strictly in order. The session is untrusted (§A.7): every path is parsed and confined, every
/// mutation is refused on a read-only drive, and handles are bounded.
///
/// Not thread-safe: call from one serial queue. The log lines it returns carry command names, sizes,
/// statuses and paths relative to the shared folder only, never file contents.
public final class CDMServer {
    public static let maxFiles = 256
    public static let maxSearches = 64
    /// Encoded find entries kept for FIND_NEXT across all searches at most.
    public var maxRetainedFindBytes = 16 << 20
    /// Generated 8.3 names kept per session at most; beyond that the tables start over.
    public static let maxShortNames = 200_000
    /// Volume label bytes at most (Windows allows 32 characters).
    public static let maxLabelBytes = 32

    public let fileSystem: CDMFileSystem
    public let letter: Character
    public let label: String
    public var timeZone: TimeZone = .current
    /// UTF-8 paths and V2 find entries, from CONNECT (§A.3). Before CONNECT: code page (V1).
    public private(set) var utf8 = false
    public private(set) var connected = false

    public var readOnly: Bool { fileSystem.isReadOnly }
    public var openFileCount: Int { files.count }
    public var openSearchCount: Int { searches.count }

    public struct Result {
        public var reply: CDMReply?
        public var log: [String]
    }

    private final class OpenFile {
        let file: CDMOpenFile
        let path: CDMPath
        var bytesRead = 0
        var bytesWritten = 0
        init(file: CDMOpenFile, path: CDMPath) {
            self.file = file
            self.path = path
        }
    }

    private struct Search {
        var entries: [Data]
        /// Sum of the encoded entries (what this search retains).
        var size: Int
        var next: Int
        var path: CDMPath
        var used: Int
    }

    /// Generated 8.3 names of one folder, stable for the session (§A.5 [P]).
    private struct ShortNames {
        var byLong: [String: String] = [:]
        var byShort: [String: String] = [:]
        /// Next `~N` per stem, so N names of one stem cost O(N), not O(N²).
        var nextIndex: [String: Int] = [:]
    }

    private var files: [UInt16: OpenFile] = [:]
    private var searches: [UInt16: Search] = [:]
    private var shortNames: [String: ShortNames] = [:]
    private var shortNameCount = 0
    private var useCounter = 0
    private var log: [String] = []

    public init(fileSystem: CDMFileSystem, letter: Character = "M", label: String = "Mac") {
        self.fileSystem = fileSystem
        self.letter = Character(letter.uppercased())
        self.label = label
    }

    /// Closes every handle (session end).
    public func closeAll() {
        for (_, f) in files { f.file.close() }
        files = [:]
        searches = [:]
    }

    public func handle(_ request: CDMRequest) -> Result {
        log = []
        let reply = dispatch(request)
        return Result(reply: reply, log: log)
    }

    // MARK: Dispatch

    private func dispatch(_ request: CDMRequest) -> CDMReply? {
        func reply(_ body: CDMReplyBody) -> CDMReply { CDMReply(to: request, body) }
        let name = request.command.name
        switch request.body {
        case .connect(let fields):
            utf8 = fields.count > 3 && fields[3] & CDMWire.connectUTF8 != 0
            connected = true
            let caps = utf8 ? CDMWire.capsUTF8 : CDMWire.capsCodePage
            note(String(format: "CONNECT fields [%@] → %@, caps 0x%02X", fields.map { String(format: "%04X", $0) }.joined(separator: " "),
                        utf8 ? "UTF-8" : "code page", caps))
            return reply(.connect(caps: caps))

        case let .create(raw, access, disposition, attributes, _, _):
            let (ctx, st) = create(raw, access: access, disposition: disposition, attributes: attributes)
            return reply(.handle(ctx, status: st))

        case let .open(raw, mode):
            let (ctx, st) = open(raw, mode: mode)
            return reply(.handle(ctx, status: st))

        case .close(let ctx):
            if let f = files.removeValue(forKey: ctx) {
                f.file.close()
                note("CLOSE ctx \(ctx) \(f.path): read \(f.bytesRead) B, written \(f.bytesWritten) B")
            } else {
                note("CLOSE ctx \(ctx): unknown handle")
            }
            return nil

        case let .read(ctx, offset, count):
            let (data, st) = read(ctx, offset: offset, count: count)
            return reply(.read(ctx, date: 0, time: 0, status: st, data: data))

        case let .readConditional(ctx, _, _, offset, _, count):
            // Always the data, never "unchanged": never stale (§A.3 [P]).
            let (data, st) = read(ctx, offset: offset, count: count)
            return reply(.readConditional(ctx, date: 0, time: 0, status: st, data: data, notModified: 0))

        case let .write(ctx, offset, data):
            let (written, st) = write(ctx, offset: offset, data: data)
            return reply(.write(ctx, written: written, status: st))

        case let .findFirst(raw, bufferSize, maxEntries):
            let (ctx, st, count, entries) = findFirst(raw, start: 0, bufferSize: bufferSize, maxEntries: maxEntries, name: name)
            return reply(.find(ctx, status: st, count: count, entries: entries))

        case let .findFirstIndex(raw, bufferSize, index, maxEntries):
            let (ctx, st, count, entries) = findFirst(raw, start: Int(index), bufferSize: bufferSize, maxEntries: maxEntries, name: name)
            return reply(.find(ctx, status: st, count: count, entries: entries))

        case let .findNext(ctx, bufferSize, maxEntries):
            let (next, st, count, entries) = findNext(ctx, bufferSize: bufferSize, maxEntries: maxEntries)
            return reply(.find(next, status: st, count: count, entries: entries))

        case .findClose(let ctx):
            searches.removeValue(forKey: ctx)
            return nil

        case .getAttributes(let raw):
            switch path(raw) {
            case .failure(let st):
                note("\(name) → \(CDMStatus.label(st))")
                return reply(.attributes(status: st, size: 0, attributes: 0, date: 0, time: 0))
            case .success(let p):
                do {
                    let info = try fileSystem.info(p)
                    let stamp = CDMDosTime(info.modified, timeZone: timeZone)
                    return reply(.attributes(status: CDMStatus.success, size: Self.clamp(info.size), attributes: attributes(info),
                                             date: stamp.date, time: stamp.time))
                } catch {
                    let st = status(error, missing: CDMStatus.fileNotFound)
                    if st != CDMStatus.fileNotFound { note("\(name) \(p) → \(CDMStatus.label(st)) (\(error))") }
                    return reply(.attributes(status: st, size: 0, attributes: 0, date: 0, time: 0))
                }
            }

        case let .setAttributes(raw, attributes):
            return reply(.status(mutate(name, raw) { p in
                guard !p.isRoot else { return }
                try fileSystem.setAttributes(p, readOnly: attributes & CDMAttributes.readOnly != 0,
                                             hidden: attributes & CDMAttributes.hidden != 0)
            }))

        case .getDateTime(let ctx):
            guard let f = files[ctx] else { return reply(.dateTime(ctx, date: 0, time: 0, status: CDMStatus.accessDenied)) }
            do {
                let stamp = CDMDosTime(try f.file.info().modified, timeZone: timeZone)
                return reply(.dateTime(ctx, date: stamp.date, time: stamp.time, status: CDMStatus.success))
            } catch {
                return reply(.dateTime(ctx, date: 0, time: 0, status: status(error)))
            }

        case let .setDateTime(ctx, time, date):
            guard let f = files[ctx], f.file.writable, !readOnly else { return reply(.handleStatus(ctx, status: denied(name))) }
            // 0/0 or an invalid stamp: nothing to change.
            guard let value = CDMDosTime(date: date, time: time).date(timeZone: timeZone) else {
                return reply(.handleStatus(ctx, status: CDMStatus.success))
            }
            do {
                try f.file.setModified(value)
                return reply(.handleStatus(ctx, status: CDMStatus.success))
            } catch {
                note("\(name) ctx \(ctx) \(f.path) → \(error)")
                return reply(.handleStatus(ctx, status: status(error)))
            }

        case .delete(let raw):
            return reply(.status(mutate(name, raw, missing: CDMStatus.fileNotFound) { p in
                guard !p.isRoot else { throw CDMFSError.accessDenied }
                try fileSystem.removeFile(p)
            }))

        case let .rename(rawFrom, rawTo):
            guard !readOnly else { return reply(.rename(status: denied(name))) }
            switch (path(rawFrom), path(rawTo)) {
            case (.success(let from), .success(let to)):
                do {
                    guard let newName = to.name, CDMNames.isCreatableName(newName) else { throw CDMFSError.pathNotFound }
                    try fileSystem.rename(from, to: to)
                    note("\(name) \(from) → \(to)")
                    return reply(.rename(status: CDMStatus.success))
                } catch {
                    let st = status(error, missing: CDMStatus.fileNotFound)
                    note("\(name) \(from) → \(to): \(CDMStatus.label(st)) (\(error))")
                    return reply(.rename(status: st))
                }
            case (.failure(let st), _), (_, .failure(let st)):
                note("\(name) → \(CDMStatus.label(st))")
                return reply(.rename(status: st))
            }

        case .createDirectory(let raw, _, _, _, _):
            return reply(.status(mutate(name, raw, other: CDMStatus.writeFault) { p in
                guard !p.isRoot else { throw CDMFSError.exists }
                guard CDMNames.isCreatableName(p.name!) else { throw CDMFSError.pathNotFound }
                try fileSystem.makeDirectory(p)
            }))

        case .deleteDirectory(let raw):
            return reply(.status(mutate(name, raw, missing: CDMStatus.fileNotFound) { p in
                guard !p.isRoot else { throw CDMFSError.accessDenied }
                try fileSystem.removeDirectory(p)
            }))

        case let .changeSize(ctx, size):
            guard let f = files[ctx], f.file.writable, !readOnly else { return reply(.handleStatus(ctx, status: denied(name))) }
            do {
                try f.file.truncate(to: UInt64(size))
                note("\(name) ctx \(ctx) \(f.path) → \(size) B")
                return reply(.handleStatus(ctx, status: CDMStatus.success))
            } catch {
                note("\(name) ctx \(ctx) \(f.path) → \(error)")
                return reply(.handleStatus(ctx, status: status(error)))
            }

        case let .seek(ctx, _, mode):
            // Only "from the end" has a reply (§A.3); positions are per request anyway.
            guard mode == 2 else {
                note("\(name) ctx \(ctx) mode \(mode): no reply")
                return nil
            }
            guard let f = files[ctx] else { return reply(.seek(ctx, size: 0, status: CDMStatus.accessDenied)) }
            do {
                return reply(.seek(ctx, size: Self.clamp(try f.file.info().size), status: CDMStatus.success))
            } catch {
                return reply(.seek(ctx, size: 0, status: status(error)))
            }

        case .volumeInfo(let raw, _):
            guard case .success(let p) = path(raw), (try? fileSystem.info(p)) != nil else {
                note("\(name) → ACCESS_DENIED 0x0502")
                return reply(.volume(status: CDMStatus.volumeDenied, label: Data()))
            }
            return reply(.volume(status: CDMStatus.success, label: labelBytes()))
        }
    }

    // MARK: Paths

    /// Parses and confines a wire path; generated 8.3 names map back to the real names (§A.2).
    private enum PathResult {
        case success(CDMPath)
        case failure(UInt16)
    }

    private func path(_ raw: Data, pattern: Bool = false) -> PathResult {
        switch CDMNames.parse(raw, utf8: utf8, letter: letter, pattern: pattern) {
        case .failure(let why):
            note("path refused: \(why)")
            return .failure(CDMStatus.pathNotFound)
        case .success(let parsed):
            var resolved = CDMPath.root
            for (index, component) in parsed.components.enumerated() {
                var real = component
                let isPattern = pattern && index == parsed.components.count - 1 && CDMNames.hasWildcard(component)
                if !isPattern, let long = shortNames[resolved.key]?.byShort[CDMNames.fold(component)],
                   case .some(CDMFSError.notFound) = Self.probe(fileSystem, resolved.appending(component)) {
                    real = long
                }
                resolved = resolved.appending(real)
            }
            return .success(resolved)
        }
    }

    /// The error `info` gives for `path`, or nil if it exists.
    private static func probe(_ fs: CDMFileSystem, _ path: CDMPath) -> CDMFSError? {
        do { _ = try fs.info(path); return nil } catch { return error as? CDMFSError ?? .io(EIO) }
    }

    // MARK: Files

    private func allocateFile(_ file: CDMOpenFile, path: CDMPath) -> UInt16? {
        guard files.count < Self.maxFiles else { file.close(); return nil }
        var ctx: UInt16 = 1
        while files[ctx] != nil { ctx += 1 }
        files[ctx] = OpenFile(file: file, path: path)
        return ctx
    }

    private func create(_ raw: Data, access: UInt16, disposition: UInt16, attributes: UInt16) -> (UInt16, UInt16) {
        let name = "CREATE"
        let write = access & 0x03 != 0
        let createBit = disposition & 0x01 != 0, openBit = disposition & 0x02 != 0, replaceBit = disposition & 0x04 != 0
        // The reference checks the drive's permission first: write access, "create new" and "replace" (§A.3).
        if readOnly, write || replaceBit || disposition == 1 { return (CDMWire.noHandle, denied(name)) }
        guard case .success(let p) = path(raw) else { return (CDMWire.noHandle, CDMStatus.pathNotFound) }
        guard !p.isRoot else { return (CDMWire.noHandle, CDMStatus.accessDenied) }
        guard files.count < Self.maxFiles else {
            note("\(name) \(p): \(Self.maxFiles) handles open")
            return (CDMWire.noHandle, CDMStatus.failure)
        }
        let existing: CDMFileInfo?
        do { existing = try fileSystem.info(p) } catch CDMFSError.notFound { existing = nil } catch {
            let st = status(error)
            note("\(name) \(p) → \(CDMStatus.label(st)) (\(error))")
            return (CDMWire.noHandle, st)
        }
        let mode: CDMOpenMode
        let action: String
        if let existing {
            if existing.isDirectory { return (CDMWire.noHandle, CDMStatus.accessDenied) }
            if replaceBit { mode = .existing(write: true, truncate: true); action = "replaced" }
            else if openBit { mode = .existing(write: write, truncate: false); action = "opened" }
            else { return (CDMWire.noHandle, CDMStatus.fileExists) }
        } else {
            guard createBit else { return (CDMWire.noHandle, CDMStatus.fileNotFoundCreate) }
            if readOnly { return (CDMWire.noHandle, denied(name)) }
            guard CDMNames.isCreatableName(p.name!) else {
                note("\(name) \(p): a name ending in a dot or space is never created")
                return (CDMWire.noHandle, CDMStatus.pathNotFound)
            }
            mode = .createNew
            action = "created"
        }
        do {
            let file = try fileSystem.open(p, mode)
            if mode == .createNew, attributes & (CDMAttributes.readOnly | CDMAttributes.hidden) != 0 {
                try? fileSystem.setAttributes(p, readOnly: attributes & CDMAttributes.readOnly != 0,
                                              hidden: attributes & CDMAttributes.hidden != 0)
            }
            guard let ctx = allocateFile(file, path: p) else { return (CDMWire.noHandle, CDMStatus.failure) }
            note(String(format: "%@ %@ access %d disposition %d → ctx %d %@", name, p.description, access, disposition, ctx, action))
            return (ctx, CDMStatus.success)
        } catch {
            let st = status(error, missing: CDMStatus.fileNotFoundCreate, other: CDMStatus.failure)
            note("\(name) \(p) → \(CDMStatus.label(st)) (\(error))")
            return (CDMWire.noHandle, st)
        }
    }

    private func open(_ raw: Data, mode: UInt16) -> (UInt16, UInt16) {
        let name = "OPEN"
        let write = mode & 0x03 != 0
        if readOnly, write { return (CDMWire.noHandle, denied(name)) }
        guard case .success(let p) = path(raw) else { return (CDMWire.noHandle, CDMStatus.pathNotFound) }
        guard !p.isRoot else { return (CDMWire.noHandle, CDMStatus.accessDenied) }
        guard files.count < Self.maxFiles else {
            note("\(name) \(p): \(Self.maxFiles) handles open")
            return (CDMWire.noHandle, CDMStatus.failure)
        }
        do {
            let file = try fileSystem.open(p, .existing(write: write, truncate: false))
            guard let ctx = allocateFile(file, path: p) else { return (CDMWire.noHandle, CDMStatus.failure) }
            note(String(format: "%@ %@ mode 0x%02X → ctx %d", name, p.description, mode, ctx))
            return (ctx, CDMStatus.success)
        } catch {
            let st = status(error, missing: CDMStatus.fileNotFound, other: CDMStatus.failure)
            if st != CDMStatus.fileNotFound { note("\(name) \(p) → \(CDMStatus.label(st)) (\(error))") }
            return (CDMWire.noHandle, st)
        }
    }

    private func read(_ ctx: UInt16, offset: UInt32, count: UInt16) -> (Data, UInt16) {
        guard let f = files[ctx] else { return (Data(), CDMStatus.accessDenied) }
        do {
            let data = try f.file.read(at: UInt64(offset), count: Int(count))
            f.bytesRead += data.count
            return (data, CDMStatus.success)
        } catch {
            note("READ ctx \(ctx) \(f.path) at \(offset) → \(error)")
            return (Data(), status(error, other: CDMStatus.failure))
        }
    }

    private func write(_ ctx: UInt16, offset: UInt32, data: Data) -> (UInt16, UInt16) {
        guard let f = files[ctx], f.file.writable, !readOnly else { return (0, denied("WRITE")) }
        do {
            let n = try f.file.write(data, at: UInt64(offset))
            f.bytesWritten += n
            return (UInt16(clamping: n), CDMStatus.success)
        } catch {
            note("WRITE ctx \(ctx) \(f.path) \(data.count) B at \(offset) → \(error)")
            return (0, status(error, other: CDMStatus.failure))
        }
    }

    /// A path-based mutation: refused on a read-only drive, logged with its outcome.
    private func mutate(_ name: String, _ raw: Data, missing: UInt16 = CDMStatus.fileNotFound, other: UInt16 = CDMStatus.failure,
                        _ body: (CDMPath) throws -> Void) -> UInt16 {
        guard !readOnly else { return denied(name) }
        switch path(raw) {
        case .failure(let st):
            note("\(name) → \(CDMStatus.label(st))")
            return st
        case .success(let p):
            do {
                try body(p)
                note("\(name) \(p)")
                return CDMStatus.success
            } catch {
                let st = status(error, missing: missing, other: other)
                note("\(name) \(p) → \(CDMStatus.label(st)) (\(error))")
                return st
            }
        }
    }

    // MARK: Find (§A.5)

    private typealias FindResult = (UInt16, UInt16, UInt8, Data)

    private func findFirst(_ raw: Data, start: Int, bufferSize: UInt16, maxEntries: UInt8, name: String) -> FindResult {
        let parsed: CDMPath
        switch path(raw, pattern: true) {
        case .failure(let st): return (CDMWire.noHandle, st, 0, Data())
        case .success(let p): parsed = p
        }
        // A last component with wildcards filters its folder (docs/95 §A.8 step 5). Without wildcards it
        // names the folder to list, as in the reference (§A.5); a file there fails with PATH_NOT_FOUND.
        let directory: CDMPath
        let pattern: String
        if let last = parsed.name, CDMNames.hasWildcard(last) {
            directory = parsed.parent
            pattern = last
        } else {
            directory = parsed
            pattern = "*"
        }
        let infos: [CDMFileInfo]
        do { infos = try fileSystem.list(directory) } catch {
            let st = (error as? CDMFSError) == .notDirectory ? CDMStatus.pathNotFound
                : status(error, missing: CDMStatus.pathNotFoundSearch, path: CDMStatus.pathNotFoundSearch)
            note("\(name) \(parsed) → \(CDMStatus.label(st)) (\(error))")
            return (CDMWire.noHandle, st, 0, Data())
        }
        let valid = infos.filter { CDMNames.isValidName($0.name) }
        if valid.count < infos.count { note("\(name) \(directory): \(infos.count - valid.count) names not valid on Windows left out") }
        let keyed = valid.map { (key: CDMNames.fold($0.name), info: $0) }.sorted { $0.key < $1.key }
        let sorted = keyed.map(\.info)
        let names = Set(keyed.map(\.key))
        var entries: [Data] = []
        var size = 0
        for info in sorted {
            let (short, long) = shortName(for: info.name, in: directory, taken: names)
            let shortText = String(decoding: short.prefix { $0 != 0 }, as: UTF8.self)
            guard CDMNames.matches(pattern, info.name) || CDMNames.matches(pattern, shortText) else { continue }
            let stamp = CDMDosTime(info.modified, timeZone: timeZone)
            let entry = CDMFindEntry(stamp: stamp, size: Self.clamp(info.size), attributes: attributes(info),
                                     shortName: short, longName: long).encode(utf8: utf8)
            if size + entry.count > maxRetainedFindBytes {
                note("\(name) \(parsed): listing cut at \(entries.count) entries (\(maxRetainedFindBytes >> 20) MiB)")
                break
            }
            size += entry.count
            entries.append(entry)
        }
        var search = Search(entries: entries, size: size, next: min(max(0, start), entries.count), path: parsed, used: 0)
        let (count, bytes) = batch(&search, bufferSize: bufferSize, maxEntries: maxEntries)
        guard search.next < search.entries.count else {
            note("\(name) \(parsed) → \(count) of \(entries.count), complete")
            return (CDMWire.noHandle, CDMStatus.noMoreFiles, count, bytes)
        }
        let ctx = allocateSearch(search)
        note("\(name) \(parsed) → \(count) of \(entries.count), find ctx \(ctx)")
        return (ctx, CDMStatus.success, count, bytes)
    }

    private func findNext(_ ctx: UInt16, bufferSize: UInt16, maxEntries: UInt8) -> FindResult {
        guard var search = searches[ctx] else { return (CDMWire.noHandle, CDMStatus.noMoreFiles, 0, Data()) }
        let (count, bytes) = batch(&search, bufferSize: bufferSize, maxEntries: maxEntries)
        guard search.next < search.entries.count else {
            searches.removeValue(forKey: ctx)
            return (CDMWire.noHandle, CDMStatus.noMoreFiles, count, bytes)
        }
        useCounter += 1
        search.used = useCounter
        searches[ctx] = search
        return (ctx, CDMStatus.success, count, bytes)
    }

    /// Entries until the next would overflow `bufferSize` or `maxEntries` (0 = 255) are in. Unlike the
    /// reference, whatever stopped the loop, the rest stays for FIND_NEXT (§A.8 step 5). An entry that
    /// cannot fit even an empty buffer is skipped, so a search always makes progress.
    private func batch(_ search: inout Search, bufferSize: UInt16, maxEntries: UInt8) -> (UInt8, Data) {
        let limit = maxEntries == 0 ? 255 : Int(maxEntries)
        var out = Data()
        var count = 0
        while search.next < search.entries.count, count < limit {
            let entry = search.entries[search.next]
            if out.count + entry.count > Int(bufferSize) {
                if count == 0, entry.count > Int(bufferSize) {
                    note("find: an entry of \(entry.count) B does not fit a \(bufferSize) B buffer; skipped")
                    search.next += 1
                    continue
                }
                break
            }
            out += entry
            count += 1
            search.next += 1
        }
        return (UInt8(count), out)
    }

    /// Bytes all open searches retain.
    public var retainedFindBytes: Int { searches.values.reduce(0) { $0 + $1.size } }

    private func allocateSearch(_ search: Search) -> UInt16 {
        // Bounded by count and by retained bytes: the least recently used searches go first.
        while !searches.isEmpty, searches.count >= Self.maxSearches || retainedFindBytes + search.size > maxRetainedFindBytes,
              let oldest = searches.min(by: { $0.value.used < $1.value.used })?.key {
            note("find: dropping find ctx \(oldest) (\(searches.count) searches, \(retainedFindBytes) B retained)")
            searches.removeValue(forKey: oldest)
        }
        var ctx: UInt16 = 1
        while searches[ctx] != nil { ctx += 1 }
        useCounter += 1
        var s = search
        s.used = useCounter
        searches[ctx] = s
        return ctx
    }

    /// `(short, long)` wire names: an 8.3 name as it is with an empty long name, else a generated
    /// `BASE~N.EXT` padded with NULs to 12 bytes (as the reference pads) and the real name (§A.5).
    private func shortName(for name: String, in directory: CDMPath, taken: Set<String>) -> (Data, Data) {
        if CDMNames.fits83(name, utf8: utf8) { return (CDMNames.encode(name, utf8: utf8), Data()) }
        let key = directory.key
        let short: String
        if let known = shortNames[key]?.byLong[name] {
            short = known
        } else {
            if shortNameCount >= Self.maxShortNames {
                // Bounded memory; earlier short names stop mapping back (lookups then find nothing).
                note("short names: \(shortNameCount) generated; tables start over")
                shortNames = [:]
                shortNameCount = 0
            }
            let (base, ext) = CDMNames.shortStem(name)
            let stem = base + "." + ext
            // Mutated in place (a copied table would make every name O(table size)).
            if shortNames[key] == nil { shortNames[key] = ShortNames() }
            var n = shortNames[key]!.nextIndex[stem] ?? 1
            var candidate = ""
            repeat {
                let suffix = "~\(n)"
                candidate = String(base.prefix(max(1, 8 - suffix.count))) + suffix + (ext.isEmpty ? "" : "." + ext)
                n += 1
            } while shortNames[key]!.byShort[candidate] != nil || taken.contains(candidate)
            short = candidate
            shortNames[key]!.nextIndex[stem] = n
            shortNames[key]!.byLong[name] = short
            shortNames[key]!.byShort[short] = name
            shortNameCount += 1
        }
        var bytes = Data(short.utf8)
        if bytes.count < 12 { bytes += Data(count: 12 - bytes.count) }
        return (bytes, CDMNames.encode(name, utf8: utf8))
    }

    // MARK: Helpers

    private func attributes(_ info: CDMFileInfo) -> UInt16 {
        var a: UInt16 = info.isDirectory ? CDMAttributes.directory : 0
        if info.readOnly || readOnly { a |= CDMAttributes.readOnly }
        if info.hidden { a |= CDMAttributes.hidden }
        return a
    }

    private func labelBytes() -> Data {
        var text = label
        while CDMNames.encode(text, utf8: utf8).count > Self.maxLabelBytes { text.removeLast() }
        return CDMNames.encode(text, utf8: utf8)
    }

    /// Sizes over 4 GiB are reported as 0xFFFFFFFF (§A.8 step 4).
    static func clamp(_ size: UInt64) -> UInt32 { UInt32(min(size, 0xFFFF_FFFF)) }

    private func denied(_ name: String) -> UInt16 {
        note("\(name) refused\(readOnly ? ": read-only drive" : "")")
        return CDMStatus.accessDenied
    }

    /// Error → status (§A.4): a missing last component, a missing folder, then the rest.
    private func status(_ error: Error, missing: UInt16 = CDMStatus.fileNotFound, path: UInt16 = CDMStatus.pathNotFound,
                        other: UInt16 = CDMStatus.failure) -> UInt16 {
        switch error as? CDMFSError {
        case .notFound: return missing
        case .pathNotFound, .notDirectory: return path
        case .exists: return CDMStatus.fileExists
        case .accessDenied, .escapes, .isDirectory, .notEmpty, .unsupported, .ambiguous: return CDMStatus.accessDenied
        case .tooMany, .io, .none: return other
        }
    }

    private func note(_ line: String) { log.append(line) }
}
