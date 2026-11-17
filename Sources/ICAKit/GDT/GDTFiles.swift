import Foundation

// CTXGDT clipboard file transfer (docs/76-gdt.md §7.17): the message layout read from a black-box relay recording of
// the stock client's own session (D79 method), both directions. Every message is `cmd u8, seq u32, total u16`
// (7 bytes) + body, all little-endian. A request carries the sender's seq (host even, client odd); every reply
// message carries the request's seq.

extension GDTWire {
    /// Command bytes [B: relay recording, docs/76 §7.17].
    public enum Command {
        public static let open: UInt8 = 0x01, openReply: UInt8 = 0x02, openAck: UInt8 = 0x03
        /// OpenStream (FileContents of one file) → OpenStreamReply `status u32, stream u64`.
        public static let openStream: UInt8 = 0x04, openStreamReply: UInt8 = 0x05
        /// Release `stream u64` → ReleaseReply with the same body.
        public static let release: UInt8 = 0x06, releaseReply: UInt8 = 0x07
        /// Seek `stream u64, move i64, origin u8` → SeekReply `stream u64, status u32, position u64`.
        public static let seek: UInt8 = 0x0A, seekReply: UInt8 = 0x0B
        /// Read `stream u64, count u32` → ReadBegin `stream, length u32`, ReadData `stream, u16 n, n bytes` (0…k),
        /// ReadEnd `stream, status u32`.
        public static let read: UInt8 = 0x0C, readBegin: UInt8 = 0x0D, readData: UInt8 = 0x0E, readEnd: UInt8 = 0x0F
        /// GetData (FORMATETC fields) → GetDataBegin `dataObj u64, length u32`, GetDataData `dataObj, u16 n, n bytes`,
        /// GetDataEnd `dataObj, status u32, tymed u32`.
        public static let getData: UInt8 = 0x14, getDataBegin: UInt8 = 0x15, getDataData: UInt8 = 0x16, getDataEnd: UInt8 = 0x17
    }

    public static let headerSize = 7
    /// GetData's `ctxFormat` for FileGroupDescriptorW in both directions [B]; `systemFormat` is 0 from the host and
    /// the host's registered CTXCLIP id from the stock client.
    public static let fileGroupFormat: UInt32 = 2
    /// OpenStream body: 53 bytes, u32 0x34, 45 zero bytes, u32 file index (lindex) [B: 0x34 and zeros for index 0
    /// in the recording; V: index 1 at body offset 49 from the host in run L1, docs/76 §7.17].
    public static let openStreamBodySize = 53
    public static let openStreamMarker: UInt32 = 0x34
    public static let openStreamIndexOffset: Int? = 49
    /// The host's largest message: 4999 bytes, the module's max packet size [V]. Ours stay at 1400 (one WD write
    /// each at the default out buffer), which the host accepts [V].
    public static let hostMaxMessage = 4999
    /// S_OK / S_FALSE, and the failure we send for a request we cannot serve [P: HRESULT values; H: use].
    public static let statusOK: UInt32 = 0, statusFalse: UInt32 = 1
    public static let statusFormat: UInt32 = 0x8004_0064   // DV_E_FORMATETC
    public static let statusInvalid: UInt32 = 0x8007_0057  // E_INVALIDARG

    /// One message's bytes: header with `total` = 7 + body.
    public static func message(_ command: UInt8, seq: UInt32, _ body: [UInt8]) -> [UInt8] {
        var w = LEBytes()
        w.u8(command); w.u32(seq); w.u16(UInt16(clamping: headerSize + body.count))
        return w.bytes + body
    }

    public static func getData(seq: UInt32, _ request: GDTGetData) -> [UInt8] { message(Command.getData, seq: seq, request.body) }

    /// GetData answer: begin (total length), the data in chunks so that each message is at most `maxMessage`
    /// bytes, end (status, tymed). The recording has one chunk (596 B of a 613 B message) [B]; more chunks [H].
    public static func getDataReply(seq: UInt32, dataObj: UInt64, data: [UInt8], status: UInt32 = statusOK,
                                    tymed: UInt32 = TYMED.hglobal, maxMessage: Int = 1400) -> [[UInt8]] {
        var begin = LEBytes(); begin.u64(dataObj); begin.u32(UInt32(data.count))
        var out = [message(Command.getDataBegin, seq: seq, begin.bytes)]
        out += chunks(data, room: maxMessage - headerSize - 10).map { part in
            var c = LEBytes(); c.u64(dataObj); c.u16(UInt16(part.count)); return message(Command.getDataData, seq: seq, c.bytes + part)
        }
        var end = LEBytes(); end.u64(dataObj); end.u32(status); end.u32(tymed)
        out.append(message(Command.getDataEnd, seq: seq, end.bytes))
        return out
    }

    public static func openStream(seq: UInt32, index: UInt32, indexOffset: Int?) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: openStreamBodySize)
        LEBytes.put(openStreamMarker, into: &body, at: 0)
        if let o = indexOffset, o + 4 <= body.count { LEBytes.put(index, into: &body, at: o) }
        return message(Command.openStream, seq: seq, body)
    }

    public static func openStreamReply(seq: UInt32, status: UInt32, stream: UInt64) -> [UInt8] {
        var w = LEBytes(); w.u32(status); w.u64(stream)
        return message(Command.openStreamReply, seq: seq, w.bytes)
    }

    public static func seek(seq: UInt32, stream: UInt64, move: Int64, origin: UInt8) -> [UInt8] {
        var w = LEBytes(); w.u64(stream); w.u64(UInt64(bitPattern: move)); w.u8(origin)
        return message(Command.seek, seq: seq, w.bytes)
    }

    public static func seekReply(seq: UInt32, stream: UInt64, status: UInt32, position: UInt64) -> [UInt8] {
        var w = LEBytes(); w.u64(stream); w.u32(status); w.u64(position)
        return message(Command.seekReply, seq: seq, w.bytes)
    }

    public static func read(seq: UInt32, stream: UInt64, count: UInt32) -> [UInt8] {
        var w = LEBytes(); w.u64(stream); w.u32(count)
        return message(Command.read, seq: seq, w.bytes)
    }

    /// Read answer: begin (length), data chunks (none for 0 bytes), end (status). The stock client answers
    /// status 0 even at the end of the stream; the host answers 1 (S_FALSE) there [B].
    public static func readReply(seq: UInt32, stream: UInt64, data: [UInt8], status: UInt32 = statusOK, maxMessage: Int = 1400) -> [[UInt8]] {
        var begin = LEBytes(); begin.u64(stream); begin.u32(UInt32(data.count))
        var out = [message(Command.readBegin, seq: seq, begin.bytes)]
        out += chunks(data, room: maxMessage - headerSize - 10).map { part in
            var c = LEBytes(); c.u64(stream); c.u16(UInt16(part.count)); return message(Command.readData, seq: seq, c.bytes + part)
        }
        var end = LEBytes(); end.u64(stream); end.u32(status)
        out.append(message(Command.readEnd, seq: seq, end.bytes))
        return out
    }

    public static func release(seq: UInt32, stream: UInt64, reply: Bool = false) -> [UInt8] {
        var w = LEBytes(); w.u64(stream)
        return message(reply ? Command.releaseReply : Command.release, seq: seq, w.bytes)
    }

    static func chunks(_ data: [UInt8], room: Int) -> [[UInt8]] {
        let size = max(1, min(room, Int(UInt16.max)))
        return stride(from: 0, to: data.count, by: size).map { Array(data[$0..<min(data.count, $0 + size)]) }
    }

    /// The file index of a host OpenStream body: the u32 at `indexOffset` (49); with nil (discovery) 0 for an all-zero
    /// body after the marker, else the u32 at the first nonzero byte after the marker if it is small (< 0x10000),
    /// else nil. Returns the offset it used.
    public static func openStreamIndex(_ body: [UInt8], indexOffset: Int? = openStreamIndexOffset) -> (index: UInt32, offset: Int?)? {
        guard body.count >= 4 else { return nil }
        if let o = indexOffset {
            guard o + 4 <= body.count else { return nil }
            return (LEBytes.u32(body, o), o)
        }
        guard let k = body.indices.dropFirst(4).first(where: { body[$0] != 0 }) else { return (0, nil) }
        var v: UInt32 = 0
        for i in 0..<4 where k + i < body.count { v |= UInt32(body[k + i]) << (8 * UInt32(i)) }
        return v < 0x10000 ? (v, k) : nil
    }
}

/// GetData's body: FORMATETC's fields without the target device and aspect, 24 bytes [B, docs/76 §7.16].
public struct GDTGetData: Equatable, Sendable {
    public var dataObj: UInt64
    public var ctxFormat: UInt32
    public var systemFormat: UInt32
    public var lindex: Int32
    public var tymed: UInt32

    public init(dataObj: UInt64, ctxFormat: UInt32, systemFormat: UInt32, lindex: Int32 = -1, tymed: UInt32 = GDTWire.TYMED.hglobal) {
        self.dataObj = dataObj
        self.ctxFormat = ctxFormat
        self.systemFormat = systemFormat
        self.lindex = lindex
        self.tymed = tymed
    }

    public init?(body b: [UInt8]) {
        guard b.count >= 24 else { return nil }
        self.init(dataObj: LEBytes.u64(b, 0), ctxFormat: LEBytes.u32(b, 8), systemFormat: LEBytes.u32(b, 12),
                  lindex: Int32(bitPattern: LEBytes.u32(b, 16)), tymed: LEBytes.u32(b, 20))
    }

    public var body: [UInt8] {
        var w = LEBytes(); w.u64(dataObj); w.u32(ctxFormat); w.u32(systemFormat); w.u32(UInt32(bitPattern: lindex)); w.u32(tymed)
        return w.bytes
    }
}

/// One whole CTXGDT message.
public struct GDTMessage: Equatable, Sendable {
    public var command: UInt8
    public var seq: UInt32
    public var body: [UInt8]

    public init(command: UInt8, seq: UInt32, body: [UInt8]) {
        self.command = command
        self.seq = seq
        self.body = body
    }

    /// Exactly one message (total = count), else nil.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= GDTWire.headerSize, Int(LEBytes.u16(bytes, 5)) == bytes.count else { return nil }
        self.init(command: bytes[0], seq: LEBytes.u32(bytes, 1), body: Array(bytes[GDTWire.headerSize...]))
    }

    public var bytes: [UInt8] { GDTWire.message(command, seq: seq, body) }
    /// The stream / data-object handle that starts most bodies (0 if the body is shorter).
    public var handle: UInt64 { body.count >= 8 ? LEBytes.u64(body, 0) : 0 }
}

/// Splits host writes into messages by the header's total. A message may span writes; a write holds one or more
/// messages. A leftover shorter than a header, or a bad total, is dropped when the next write comes.
public struct GDTMessageReader: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var dropped = 0

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [GDTMessage] {
        if buffer.count < GDTWire.headerSize, !buffer.isEmpty { dropped += buffer.count; buffer = [] }
        buffer += bytes
        var out: [GDTMessage] = []
        while buffer.count >= GDTWire.headerSize {
            let total = Int(LEBytes.u16(buffer, 5))
            guard total >= GDTWire.headerSize else { dropped += buffer.count; buffer = []; break }
            guard buffer.count >= total else { break }
            out.append(GDTMessage(command: buffer[0], seq: LEBytes.u32(buffer, 1), body: Array(buffer[GDTWire.headerSize..<total])))
            buffer.removeFirst(total)
        }
        return out
    }
}

/// Little-endian helpers for this file.
struct LEBytes {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * UInt32($1)) } }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
    static func put(_ v: UInt32, into b: inout [UInt8], at o: Int) { for i in 0..<4 { b[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
}

/// Files offered to the host (Mac → session): descriptor entries and a reader per index.
public struct GDTFileSource {
    public var entries: [ClipboardFileEntry]
    public var read: (_ index: Int, _ offset: UInt64, _ length: Int) -> Data?

    public init(entries: [ClipboardFileEntry], read: @escaping (_ index: Int, _ offset: UInt64, _ length: Int) -> Data?) {
        self.entries = entries
        self.read = read
    }

    public init(files: [ClipboardLocalFile]) {
        self.init(entries: files.map(\.entry)) { i, offset, length in
            i < files.count ? files[i].read(offset: offset, length: length) : nil
        }
    }

    /// In-memory contents (tests).
    public init(entries: [ClipboardFileEntry], contents: [Data]) {
        self.init(entries: entries) { i, offset, length in
            guard i < contents.count else { return nil }
            let d = contents[i]
            let start = Int(min(offset, UInt64(d.count)))
            return d.subdata(in: start..<min(d.count, start + length))
        }
    }
}

public enum GDTFileEvent: CustomStringConvertible {
    // Mac → session (the host reads our files)
    case hostGetData(seq: UInt32, GDTGetData, served: Int?)
    case hostOpenStream(seq: UInt32, index: UInt32?, indexOffset: Int?, stream: UInt64?, body: [UInt8])
    case hostSeek(stream: UInt64, move: Int64, origin: UInt8, position: UInt64?)
    case hostRead(stream: UInt64, index: Int?, requested: UInt32, returned: Int, position: UInt64)
    /// All bytes of file `index` went out on one stream.
    case servedFile(index: Int, name: String, bytes: Int)
    case hostRelease(stream: UInt64, known: Bool)
    // Session → Mac (we read the host's files)
    case fetchStarted(systemFormat: UInt32)
    case fileGroup([ClipboardFileEntry])
    case receivedFile(index: Int, name: String, url: URL, bytes: Int)
    case fetchFailed(String)
    case fetchDone(files: Int)
    case unexpected(GDTMessage, why: String)

    public var description: String {
        switch self {
        case .hostGetData(let seq, let g, let served):
            return "← GetData seq \(seq) dataObj \(String(format: "%016llx", g.dataObj)) ctxFormat \(g.ctxFormat) systemFormat 0x\(String(g.systemFormat, radix: 16)) " +
                "lindex \(g.lindex) tymed \(g.tymed) → " + (served.map { "FILEGROUPDESCRIPTORW \($0) B" } ?? "refused")
        case .hostOpenStream(let seq, let index, let offset, let stream, let body):
            return "← OpenStream seq \(seq) index \(index.map(String.init) ?? "?") (offset \(offset.map(String.init) ?? "-")) → " +
                (stream.map { String(format: "stream %016llx", $0) } ?? "refused") + "; body " + GDTHexLog.hex(body)
        case .hostSeek(let s, let move, let origin, let pos):
            return String(format: "← Seek stream %016llx move %lld origin %d → ", s, move, origin) + (pos.map { "position \($0)" } ?? "refused")
        case .hostRead(let s, let index, let requested, let returned, let pos):
            return String(format: "← Read stream %016llx", s) + " file \(index.map(String.init) ?? "?") count \(requested) → \(returned) B, position \(pos)"
        case .servedFile(let i, let name, let n): return "served file \(i) \"\(name)\" \(n) B completely"
        case .hostRelease(let s, let known): return String(format: "← Release stream %016llx", s) + (known ? "" : " (unknown)")
        case .fetchStarted(let f): return "→ GetData FileGroupDescriptorW (systemFormat 0x\(String(f, radix: 16)))"
        case .fileGroup(let e): return "← FILEGROUPDESCRIPTORW \(e.count) entries: " + e.map { "\"\($0.name)\" \($0.isDirectory ? "dir" : "\($0.size) B")" }.joined(separator: ", ")
        case .receivedFile(let i, let name, let url, let n): return "received file \(i) \"\(name)\" \(n) B → \(url.path)"
        case .fetchFailed(let why): return "fetch failed: \(why)"
        case .fetchDone(let n): return "fetch done: \(n) files"
        case .unexpected(let m, let why): return String(format: "unexpected cmd 0x%02x seq %u (%@)", m.command, m.seq, why)
        }
    }
}

/// The file protocol of CTXGDT on top of `GDTEngine` (docs/76 §7.17). Mac → session: answers the host's GetData
/// (FileGroupDescriptorW), OpenStream, Seek, Read and Release from `source`. Session → Mac: `fetch` asks for the
/// host's descriptor, then opens, reads and releases one stream per file and writes the files into a directory.
/// Call everything on the session queue.
public final class GDTFileTransfer {
    var send: ([UInt8], String) -> Void = { _, _ in }
    var takeSeq: () -> UInt32 = { 1 }
    var emit: (GDTFileEvent) -> Void = { _ in }

    /// Largest message we write (each fits one WD virtual write at the default 1460-byte out buffer).
    public var maxMessage = 1400
    /// Read count per request when reading the host's files. The stock client asked the file size [B].
    public var readSize = 65536
    /// Bytes accepted per host file (larger ones are dropped).
    public var maxFileSize = 64 << 20
    public var maxFiles = 16
    /// OpenStream's file-index offset, parsing and building.
    public var indexOffset: Int? = GDTWire.openStreamIndexOffset

    // Mac → session
    public private(set) var source: GDTFileSource?
    private struct Stream { var index: Int; var position: UInt64 }
    private var streams: [UInt64: Stream] = [:]
    private var nextStream: UInt64 = 0x0000_0001_4744_5000
    private var opens = 0
    /// File indices whose bytes went out completely at least once.
    public private(set) var servedFiles: Set<Int> = []

    // Session → Mac
    private enum Step: Equatable { case descriptor, open(Int), read(Int), release(Int) }
    private struct Fetch {
        var systemFormat: UInt32
        var directory: URL
        var dataObj: UInt64
        var seq: UInt32 = 0
        var step = Step.descriptor
        var entries: [ClipboardFileEntry] = []
        var chunk: [UInt8] = []
        var expected = 0
        var stream: UInt64 = 0
        var file: [UInt8] = []
        var lastCount: UInt32 = 0
        var received = 0
    }
    private var fetch: Fetch?
    public var isFetching: Bool { fetch != nil }
    public private(set) var receivedFiles: [URL] = []

    public init() {}

    /// The Mac clipboard's files (nil: none; GetData is then refused).
    public func offer(_ source: GDTFileSource?) {
        self.source = source
        streams = [:]
        opens = 0
        servedFiles = []
    }

    public func receive(_ m: GDTMessage) {
        typealias C = GDTWire.Command
        switch m.command {
        case C.getData: hostGetData(m)
        case C.openStream: hostOpenStream(m)
        case C.seek: hostSeek(m)
        case C.read: hostRead(m)
        case C.release: hostRelease(m)
        case C.getDataBegin, C.getDataData, C.getDataEnd, C.openStreamReply, C.readBegin, C.readData, C.readEnd, C.releaseReply:
            reply(m)
        case C.open, C.openReply, C.openAck: break
        default: emit(.unexpected(m, why: "unknown command"))
        }
    }

    // MARK: Mac → session

    private func hostGetData(_ m: GDTMessage) {
        guard let g = GDTGetData(body: m.body) else { return emit(.unexpected(m, why: "GetData body \(m.body.count) B")) }
        var data: [UInt8]?
        if g.ctxFormat == GDTWire.fileGroupFormat, g.lindex == -1, let source, !source.entries.isEmpty {
            data = (try? ClipboardFileGroup.build(source.entries)).map { [UInt8]($0) }
        }
        emit(.hostGetData(seq: m.seq, g, served: data?.count))
        let replies = GDTWire.getDataReply(seq: m.seq, dataObj: g.dataObj, data: data ?? [],
                                           status: data == nil ? GDTWire.statusFormat : GDTWire.statusOK, tymed: g.tymed, maxMessage: maxMessage)
        for r in replies { send(r, "GetData reply") }
    }

    private func hostOpenStream(_ m: GDTMessage) {
        let found = GDTWire.openStreamIndex(m.body, indexOffset: indexOffset)
        var stream: UInt64?
        if let found, let source, Int(found.index) < source.entries.count, !source.entries[Int(found.index)].isDirectory {
            nextStream &+= 0x10
            streams[nextStream] = Stream(index: Int(found.index), position: 0)
            stream = nextStream
        }
        opens += 1
        emit(.hostOpenStream(seq: m.seq, index: found?.index, indexOffset: found?.offset, stream: stream, body: m.body))
        send(GDTWire.openStreamReply(seq: m.seq, status: stream == nil ? GDTWire.statusInvalid : GDTWire.statusOK, stream: stream ?? 0), "OpenStream reply")
    }

    private func hostSeek(_ m: GDTMessage) {
        guard m.body.count >= 17 else { return emit(.unexpected(m, why: "Seek body \(m.body.count) B")) }
        let s = m.handle
        let move = Int64(bitPattern: LEBytes.u64(m.body, 8))
        let origin = m.body[16]
        var position: UInt64?
        if var stream = streams[s], let source {
            let size = Int64(clamping: source.entries[stream.index].size)
            let base: Int64 = origin == 0 ? 0 : origin == 1 ? Int64(clamping: stream.position) : size
            let target = base &+ move
            if origin <= 2, target >= 0 {
                stream.position = UInt64(target)
                streams[s] = stream
                position = stream.position
            }
        }
        emit(.hostSeek(stream: s, move: move, origin: origin, position: position))
        send(GDTWire.seekReply(seq: m.seq, stream: s, status: position == nil ? GDTWire.statusInvalid : GDTWire.statusOK, position: position ?? 0), "Seek reply")
    }

    private func hostRead(_ m: GDTMessage) {
        guard m.body.count >= 12 else { return emit(.unexpected(m, why: "Read body \(m.body.count) B")) }
        let s = m.handle
        let count = LEBytes.u32(m.body, 8)
        guard var stream = streams[s], let source else {
            emit(.hostRead(stream: s, index: nil, requested: count, returned: 0, position: 0))
            for r in GDTWire.readReply(seq: m.seq, stream: s, data: [], status: GDTWire.statusInvalid, maxMessage: maxMessage) { send(r, "Read reply") }
            return
        }
        let entry = source.entries[stream.index]
        let want = Int(min(UInt64(count), entry.size &- min(stream.position, entry.size), UInt64(maxFileSize)))
        let data = want > 0 ? source.read(stream.index, stream.position, want).map { [UInt8]($0) } : []
        let before = stream.position
        stream.position += UInt64(data?.count ?? 0)
        streams[s] = stream
        emit(.hostRead(stream: s, index: stream.index, requested: count, returned: data?.count ?? 0, position: stream.position))
        for r in GDTWire.readReply(seq: m.seq, stream: s, data: data ?? [], status: data == nil ? GDTWire.statusInvalid : GDTWire.statusOK,
                                   maxMessage: maxMessage) { send(r, "Read reply") }
        if let data, !data.isEmpty, before < entry.size, stream.position >= entry.size, !servedFiles.contains(stream.index) {
            servedFiles.insert(stream.index)
            emit(.servedFile(index: stream.index, name: entry.name, bytes: Int(entry.size)))
        }
    }

    private func hostRelease(_ m: GDTMessage) {
        let s = m.handle
        let known = streams.removeValue(forKey: s) != nil
        emit(.hostRelease(stream: s, known: known))
        send(GDTWire.release(seq: m.seq, stream: s, reply: true), "Release reply")
    }

    // MARK: Session → Mac

    /// Asks the host for its FileGroupDescriptorW (`systemFormat` = the host's registered CTXCLIP id) and then every
    /// file's contents; the files go into `directory` (created 0700). A fetch in progress is replaced.
    public func fetch(systemFormat: UInt32, into directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return emit(.fetchFailed("cannot create \(directory.path): \(error)"))
        }
        // The stock client's dataObj values look random [B]; ours are too.
        var f = Fetch(systemFormat: systemFormat, directory: directory, dataObj: UInt64.random(in: 1...UInt64.max))
        f.seq = takeSeq()
        fetch = f
        receivedFiles = []
        emit(.fetchStarted(systemFormat: systemFormat))
        send(GDTWire.getData(seq: f.seq, GDTGetData(dataObj: f.dataObj, ctxFormat: GDTWire.fileGroupFormat, systemFormat: systemFormat)), "GetData")
    }

    public func cancelFetch() { fetch = nil }

    private func fail(_ why: String) {
        fetch = nil
        emit(.fetchFailed(why))
    }

    private func reply(_ m: GDTMessage) {
        typealias C = GDTWire.Command
        guard var f = fetch, m.seq == f.seq else { return emit(.unexpected(m, why: "no request of ours with this seq")) }
        let b = m.body
        switch (f.step, m.command) {
        case (.descriptor, C.getDataBegin), (.read, C.readBegin):
            guard b.count >= 12 else { return fail("begin body \(b.count) B") }
            f.expected = Int(LEBytes.u32(b, 8))
            f.chunk = []
            guard f.expected <= maxFileSize else { return fail("\(f.expected) B announced, over the cap") }
            fetch = f
        case (.descriptor, C.getDataData), (.read, C.readData):
            guard b.count >= 10 else { return fail("data body \(b.count) B") }
            let n = Int(LEBytes.u16(b, 8))
            guard b.count >= 10 + n, f.chunk.count + n <= max(f.expected, 0) else { return fail("data chunk \(n) B does not fit") }
            f.chunk += b[10..<(10 + n)]
            fetch = f
        case (.descriptor, C.getDataEnd):
            let status = b.count >= 12 ? LEBytes.u32(b, 8) : 0xFFFF_FFFF
            guard status == GDTWire.statusOK else { return fail(String(format: "GetData status 0x%08x", status)) }
            do { f.entries = try ClipboardFileGroup.parse(Data(f.chunk), maxEntries: 1000) } catch {
                return fail("FILEGROUPDESCRIPTORW not usable: \(error)")
            }
            fetch = f
            emit(.fileGroup(f.entries))
            openNext(after: -1)
        case (.open(let i), C.openStreamReply):
            guard b.count >= 12 else { return fail("OpenStream reply \(b.count) B") }
            let status = LEBytes.u32(b, 0)
            guard status == GDTWire.statusOK else {
                emit(.fetchFailed(String(format: "OpenStream file %d status 0x%08x", i, status)))
                return openNext(after: i)
            }
            f.stream = LEBytes.u64(b, 4)
            f.file = []
            fetch = f
            readNext(i)
        case (.read(let i), C.readEnd):
            let status = b.count >= 12 ? LEBytes.u32(b, 8) : 0xFFFF_FFFF
            let got = f.chunk
            guard got.count == f.expected else { return fail("Read: \(got.count) of \(f.expected) B") }
            f.file += got
            guard f.file.count <= maxFileSize else { return fail("file \(i) over the cap") }
            fetch = f
            // The end of the stream: a read with no bytes (the host says S_FALSE there [B]) or a failure.
            if got.isEmpty || status != GDTWire.statusOK {
                releaseCurrent(i)
            } else {
                readNext(i)
            }
        case (.release(let i), C.releaseReply):
            store(i)
            openNext(after: i)
        default:
            emit(.unexpected(m, why: "not expected now"))
        }
    }

    private func openNext(after i: Int) {
        guard var f = fetch else { return }
        let limit = min(f.entries.count, maxFiles)
        guard let next = (i + 1..<max(i + 1, limit)).first(where: { !f.entries[$0].isDirectory && f.entries[$0].size <= UInt64(maxFileSize) }) else {
            fetch = nil
            return emit(.fetchDone(files: f.received))
        }
        f.seq = takeSeq()
        f.step = .open(next)
        fetch = f
        send(GDTWire.openStream(seq: f.seq, index: UInt32(next), indexOffset: indexOffset), "OpenStream file \(next)")
    }

    private func readNext(_ i: Int) {
        guard var f = fetch else { return }
        let size = f.entries[i].size
        let remaining = size > UInt64(f.file.count) ? size - UInt64(f.file.count) : 0
        // The stock client asked the file size, then the same count again for the end of the stream [B].
        let count = remaining > 0 ? UInt32(min(remaining, UInt64(readSize))) : max(1, f.lastCount)
        f.lastCount = count
        f.seq = takeSeq()
        f.step = .read(i)
        f.chunk = []
        f.expected = 0
        fetch = f
        send(GDTWire.read(seq: f.seq, stream: f.stream, count: count), "Read file \(i)")
    }

    private func releaseCurrent(_ i: Int) {
        guard var f = fetch else { return }
        f.seq = takeSeq()
        f.step = .release(i)
        fetch = f
        send(GDTWire.release(seq: f.seq, stream: f.stream), "Release file \(i)")
    }

    private func store(_ i: Int) {
        guard var f = fetch else { return }
        let name = Self.localName(f.entries[i].name, index: i)
        var url = f.directory.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = f.directory.appendingPathComponent("\(n)-\(name)")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(f.file), attributes: [.posixPermissions: 0o600]) else {
            return emit(.fetchFailed("cannot write \(url.path)"))
        }
        if let t = f.entries[i].writeTime { try? FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: url.path) }
        f.received += 1
        fetch = f
        receivedFiles.append(url)
        emit(.receivedFile(index: i, name: f.entries[i].name, url: url, bytes: f.file.count))
    }

    /// The last path component of a Windows relative name, safe as a Mac file name ("/" and ":" → "_", no "."/"..").
    public static func localName(_ windowsName: String, index: Int) -> String {
        let last = windowsName.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        let clean = last.replacingOccurrences(of: ":", with: "_").filter { $0 != "\0" }
        return clean.isEmpty || clean == "." || clean == ".." ? "file-\(index)" : clean
    }
}
