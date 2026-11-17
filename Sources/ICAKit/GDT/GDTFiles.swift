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
    /// A file we offered that cannot be read now (deleted, permissions, swapped) [P].
    public static let statusAccessDenied: UInt32 = 0x8007_0005  // E_ACCESSDENIED
    /// A read that failed after its begin message promised a length [P; the host's reaction is untested].
    public static let statusFail: UInt32 = 0x8000_4005  // E_FAIL

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
    /// Whether file `index` can be read now (OpenStream refuses it otherwise); nil = always.
    public var check: ((_ index: Int) -> Bool)?

    public init(entries: [ClipboardFileEntry], check: ((_ index: Int) -> Bool)? = nil,
                read: @escaping (_ index: Int, _ offset: UInt64, _ length: Int) -> Data?) {
        self.entries = entries
        self.check = check
        self.read = read
    }

    public init(files: [ClipboardLocalFile]) {
        self.init(entries: files.map(\.entry), check: { i in i < files.count && files[i].isReadable }) { i, offset, length in
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
    /// A host Read of file `index` failed (not readable, or shorter than announced).
    case serveFailed(index: Int, why: String)
    case hostRelease(stream: UInt64, known: Bool)
    // Session → Mac (we read the host's files)
    case fetchStarted(systemFormat: UInt32)
    case fileGroup([ClipboardFileEntry])
    case receivedFile(index: Int, name: String, url: URL, bytes: Int)
    /// One file of a fetch failed; the fetch goes on with the next file.
    case fileFailed(index: Int, why: String)
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
        case .serveFailed(let i, let why): return "serving file \(i) failed: \(why)"
        case .hostRelease(let s, let known): return String(format: "← Release stream %016llx", s) + (known ? "" : " (unknown)")
        case .fetchStarted(let f): return "→ GetData FileGroupDescriptorW (systemFormat 0x\(String(f, radix: 16)))"
        case .fileGroup(let e): return "← FILEGROUPDESCRIPTORW \(e.count) entries: " + e.map { "\"\($0.name)\" \($0.isDirectory ? "dir" : "\($0.size) B")" }.joined(separator: ", ")
        case .receivedFile(let i, let name, let url, let n): return "received file \(i) \"\(name)\" \(n) B → \(url.path)"
        case .fileFailed(let i, let why): return "file \(i) failed: \(why)"
        case .fetchFailed(let why): return "fetch failed: \(why)"
        case .fetchDone(let n): return "fetch done: \(n) files"
        case .unexpected(let m, let why): return String(format: "unexpected cmd 0x%02x seq %u (%@)", m.command, m.seq, why)
        }
    }
}

/// What a fetch reports to its own observer (`GDTFileTransfer.fetch(_:systemFormat:observer:)`), on the session queue.
/// Exactly one of `done` / `failed` ends it.
public enum GDTFetchUpdate: Sendable, Equatable {
    case group([ClipboardFileEntry])
    /// Bytes of file `index` written so far.
    case progress(index: Int, bytes: Int)
    case file(index: Int, url: URL, bytes: Int)
    case fileFailed(index: Int, why: String)
    case done(files: Int)
    case failed(String)
}

/// What a fetch does after the host's FILEGROUPDESCRIPTORW.
public enum GDTFetchMode: Sendable {
    /// Every file (at most `maxFiles`, each at most `maxFileSize`) as `<directory>/<last path component>`, 0600
    /// (icactl cliptest-files).
    case flat(URL)
    /// Nothing: the descriptor is the result (the host list arrived; the contents come at the paste).
    case descriptor
    /// The files of `targets` (entry index → a new file's URL; its folder must exist). With `expect`, the descriptor
    /// must list the same names and sizes, else the fetch fails (the host clipboard changed since).
    case files(targets: [Int: URL], expect: [ClipboardFileEntry]?)
}

/// The file protocol of CTXGDT on top of `GDTEngine` (docs/76 §7.17). Mac → session: answers the host's GetData
/// (FileGroupDescriptorW), OpenStream, Seek, Read and Release from `source`; a Read's data goes out in slices while
/// the transport backlog is low (`backlog`), and host requests that arrive meanwhile wait their turn. Session → Mac:
/// `fetch` asks for the host's descriptor, then opens, reads and releases one stream per file, written to disk as it
/// arrives. A fetch with no host answer for `stallTimeout` fails (needs `scheduleAfter`). Call everything on the
/// session queue.
public final class GDTFileTransfer {
    var send: ([UInt8], String) -> Void = { _, _ in }
    var takeSeq: () -> UInt32 = { 1 }
    var emit: (GDTFileEvent) -> Void = { _ in }

    /// Runs a block on the session queue after a delay (stall timeout, output pacing). Without it nothing times out
    /// and output is never paced.
    public var scheduleAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    /// Unacknowledged bytes in the transport; served file data waits while it is above `backlogLimit`.
    public var backlog: (() -> Int)?
    public var backlogLimit = 2 << 20
    /// Largest message we write (each fits one WD virtual write at the default 1460-byte out buffer).
    public var maxMessage = 1400
    /// File bytes read from disk per slice when serving a host Read.
    public var serveSlice = 60 << 10
    /// Read count per request when reading the host's files. The stock client asked the file size [B].
    public var readSize = 65536
    /// Reads kept outstanding per stream for a file of known size (1 = strict request/response, as recorded). Read has
    /// no offset: more than one relies on the host answering one request at a time, in order (docs/76 §7.17 [B]);
    /// replies are matched to the oldest outstanding Read by seq [H for more than 1].
    public var readAhead = 1
    /// Bytes accepted per host file (larger ones are skipped in `.flat`, fail in `.files`).
    public var maxFileSize = 64 << 20
    public var maxFiles = 16
    /// A fetch fails when the host has not answered for this long [P].
    public var stallTimeout: TimeInterval = 20
    /// OpenStream's file-index offset, parsing and building.
    public var indexOffset: Int? = GDTWire.openStreamIndexOffset
    /// Received files (`.files` mode): permissions and the quarantine agent (nil: no quarantine attribute).
    public var filePermissions: mode_t = 0o644
    public var quarantineAgent: String? = "ICAViewer"

    // Mac → session
    public private(set) var source: GDTFileSource?
    private struct Stream { var index: Int; var position: UInt64 }
    private var streams: [UInt64: Stream] = [:]
    private var nextStream: UInt64 = 0x0000_0001_4744_5000
    private var opens = 0
    /// File indices whose bytes went out completely at least once.
    public private(set) var servedFiles: Set<Int> = []
    /// A host Read being answered in slices; host requests wait in `held` meanwhile.
    private struct Serve { var seq: UInt32; var stream: UInt64; var index: Int; var requested: UInt32; var left: Int; var position: UInt64; var sent: Int }
    private var serving: Serve?
    private var held: [GDTMessage] = []
    private var pumpScheduled = false
    public var isServing: Bool { serving != nil }

    // Session → Mac
    private enum Step: Equatable { case descriptor, open(Int), read(Int), release(Int) }
    private struct Fetch {
        var id: Int
        var mode: GDTFetchMode
        var observer: ((GDTFetchUpdate) -> Void)?
        var systemFormat: UInt32
        var dataObj: UInt64
        var seq: UInt32 = 0
        var step = Step.descriptor
        var entries: [ClipboardFileEntry] = []
        var chunk: [UInt8] = []
        var expected = 0
        /// Outstanding Reads of the current file, oldest first (`end`: the read past the announced size).
        var pending: [(seq: UInt32, count: UInt32, end: Bool)] = []
        /// Bytes of the Read being answered so far, and why its bytes are not kept (checked at its end).
        var got = 0
        var skip: String?
        /// A Read returned the end of the stream; the rest of `pending` drains, then the stream is released.
        var ending = false
        var stream: UInt64 = 0
        var output: FileHandle?
        var outputURL: URL?
        var written = 0
        /// Why the current file is given up (its stream is released, the file is not kept).
        var abandon: String?
        var lastCount: UInt32 = 0
        var received = 0
    }
    private var fetch: Fetch?
    private var fetchCount = 0
    /// Host activity for our fetch (the stall watchdog compares it).
    private var activity = 0
    /// Seqs of requests whose fetch ended: their replies are dropped quietly (an OpenStream that still succeeds is
    /// released).
    private var abandonedSeqs: Set<UInt32> = []
    public var isFetching: Bool { fetch != nil }
    public private(set) var receivedFiles: [URL] = []

    public init() {}

    /// The Mac clipboard's files (nil: none; GetData is then refused). A Read being served for the old files ends with
    /// a failure status.
    public func offer(_ source: GDTFileSource?) {
        self.source = source
        streams = [:]
        opens = 0
        servedFiles = []
        // The requests that waited behind it then meet the new files (their old streams are unknown now).
        if serving != nil { finishServe(status: GDTWire.statusFail, why: "the Mac clipboard changed") }
    }

    public func receive(_ m: GDTMessage) {
        typealias C = GDTWire.Command
        switch m.command {
        case C.getData, C.openStream, C.seek, C.read, C.release:
            // One host request at a time: those behind a Read in progress wait for its end message.
            if serving != nil {
                guard held.count < 256 else { return emit(.unexpected(m, why: "too many host requests waiting")) }
                return held.append(m)
            }
            hostRequest(m)
        case C.getDataBegin, C.getDataData, C.getDataEnd, C.openStreamReply, C.readBegin, C.readData, C.readEnd, C.releaseReply:
            reply(m)
        case C.open, C.openReply, C.openAck: break
        default: emit(.unexpected(m, why: "unknown command"))
        }
    }

    private func hostRequest(_ m: GDTMessage) {
        typealias C = GDTWire.Command
        switch m.command {
        case C.getData: hostGetData(m)
        case C.openStream: hostOpenStream(m)
        case C.seek: hostSeek(m)
        case C.read: hostRead(m)
        default: hostRelease(m)
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
        var status = GDTWire.statusInvalid
        if let found, let source, Int(found.index) < source.entries.count, !source.entries[Int(found.index)].isDirectory {
            if source.check?(Int(found.index)) ?? true {
                nextStream &+= 0x10
                streams[nextStream] = Stream(index: Int(found.index), position: 0)
                stream = nextStream
                status = GDTWire.statusOK
            } else {
                status = GDTWire.statusAccessDenied
                emit(.serveFailed(index: Int(found.index), why: "not readable any more"))
            }
        }
        opens += 1
        emit(.hostOpenStream(seq: m.seq, index: found?.index, indexOffset: found?.offset, stream: stream, body: m.body))
        send(GDTWire.openStreamReply(seq: m.seq, status: status, stream: stream ?? 0), "OpenStream reply")
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

    /// Read: begin (the length: what is left of the file, at most `count`), the data in slices, end. The first slice is
    /// read before the begin goes out, so a file that cannot be read is refused with an error status and no length.
    private func hostRead(_ m: GDTMessage) {
        guard m.body.count >= 12 else { return emit(.unexpected(m, why: "Read body \(m.body.count) B")) }
        let s = m.handle
        let count = LEBytes.u32(m.body, 8)
        guard let stream = streams[s], let source else {
            emit(.hostRead(stream: s, index: nil, requested: count, returned: 0, position: 0))
            for r in GDTWire.readReply(seq: m.seq, stream: s, data: [], status: GDTWire.statusInvalid, maxMessage: maxMessage) { send(r, "Read reply") }
            return
        }
        let entry = source.entries[stream.index]
        let want = Int(min(UInt64(count), entry.size &- min(stream.position, entry.size)))
        guard want > 0 else {
            emit(.hostRead(stream: s, index: stream.index, requested: count, returned: 0, position: stream.position))
            for r in GDTWire.readReply(seq: m.seq, stream: s, data: [], maxMessage: maxMessage) { send(r, "Read reply") }
            return
        }
        guard let first = source.read(stream.index, stream.position, min(want, serveSlice)), !first.isEmpty else {
            emit(.hostRead(stream: s, index: stream.index, requested: count, returned: 0, position: stream.position))
            emit(.serveFailed(index: stream.index, why: "not readable"))
            for r in GDTWire.readReply(seq: m.seq, stream: s, data: [], status: GDTWire.statusAccessDenied, maxMessage: maxMessage) { send(r, "Read reply") }
            return
        }
        var begin = LEBytes(); begin.u64(s); begin.u32(UInt32(want))
        send(GDTWire.message(GDTWire.Command.readBegin, seq: m.seq, begin.bytes), "Read reply")
        serving = Serve(seq: m.seq, stream: s, index: stream.index, requested: count, left: want, position: stream.position, sent: 0)
        sendSlice([UInt8](first))
        pumpServe()
    }

    private func sendSlice(_ bytes: [UInt8]) {
        guard var job = serving else { return }
        let part = bytes.count > job.left ? Array(bytes.prefix(job.left)) : bytes
        for piece in GDTWire.chunks(part, room: maxMessage - GDTWire.headerSize - 10) {
            var c = LEBytes(); c.u64(job.stream); c.u16(UInt16(piece.count))
            send(GDTWire.message(GDTWire.Command.readData, seq: job.seq, c.bytes + piece), "Read reply")
        }
        job.left -= part.count
        job.position += UInt64(part.count)
        job.sent += part.count
        serving = job
    }

    private var backlogHigh: Bool {
        guard let backlog, scheduleAfter != nil else { return false }
        return backlog() > backlogLimit
    }

    private func pumpServe() {
        while let job = serving {
            if job.left == 0 { return finishServe(status: GDTWire.statusOK, why: nil) }
            if backlogHigh { return schedulePump() }
            guard let data = source?.read(job.index, job.position, min(job.left, serveSlice)), !data.isEmpty else {
                return finishServe(status: GDTWire.statusFail, why: "the file ended after \(job.position) B or could not be read")
            }
            sendSlice([UInt8](data))
        }
    }

    private func schedulePump() {
        guard !pumpScheduled, let scheduleAfter else { return }
        pumpScheduled = true
        scheduleAfter(0.05) { [weak self] in
            self?.pumpScheduled = false
            self?.pumpServe()
        }
    }

    /// The end message of the Read being served; then the host requests that waited.
    private func finishServe(status: UInt32, why: String?) {
        guard let job = serving else { return }
        serving = nil
        var end = LEBytes(); end.u64(job.stream); end.u32(status)
        send(GDTWire.message(GDTWire.Command.readEnd, seq: job.seq, end.bytes), "Read reply")
        if var stream = streams[job.stream] {
            stream.position = job.position
            streams[job.stream] = stream
        }
        emit(.hostRead(stream: job.stream, index: job.index, requested: job.requested, returned: job.sent, position: job.position))
        if let why { emit(.serveFailed(index: job.index, why: why)) }
        if status == GDTWire.statusOK, let entry = source?.entries[safe: job.index], job.position >= entry.size, !servedFiles.contains(job.index) {
            servedFiles.insert(job.index)
            emit(.servedFile(index: job.index, name: entry.name, bytes: Int(entry.size)))
        }
        while serving == nil, !held.isEmpty { hostRequest(held.removeFirst()) }
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
        fetch(.flat(directory), systemFormat: systemFormat)
    }

    /// Starts a fetch (see `GDTFetchMode`); `observer` hears its progress and exactly one `done` or `failed`. A fetch
    /// in progress fails ("replaced") and its stream is released.
    public func fetch(_ mode: GDTFetchMode, systemFormat: UInt32, observer: ((GDTFetchUpdate) -> Void)? = nil) {
        if fetch != nil { fail("replaced by a newer fetch") }
        fetchCount += 1
        // The stock client's dataObj values look random [B]; ours are too.
        var f = Fetch(id: fetchCount, mode: mode, observer: observer, systemFormat: systemFormat, dataObj: UInt64.random(in: 1...UInt64.max))
        f.seq = takeSeq()
        fetch = f
        receivedFiles = []
        emit(.fetchStarted(systemFormat: systemFormat))
        send(GDTWire.getData(seq: f.seq, GDTGetData(dataObj: f.dataObj, ctxFormat: GDTWire.fileGroupFormat, systemFormat: systemFormat)), "GetData")
        arm()
    }

    /// Ends the fetch in progress (its observer hears `failed(why)`); an open stream is released.
    public func cancelFetch(_ why: String = "cancelled") {
        guard fetch != nil else { return }
        fail(why)
    }

    private func fail(_ why: String) {
        guard let f = fetch else { return }
        fetch = nil
        abandonedSeqs.insert(f.seq)
        for p in f.pending { abandonedSeqs.insert(p.seq) }
        discardOutput(f)
        // Reading: release the stream we hold (its answer and the late answer to the Read are dropped). Opening: a late
        // successful OpenStream reply is released when it comes (`reply`). Releasing: already on its way.
        if case .read = f.step, f.stream != 0 {
            let seq = takeSeq()
            abandonedSeqs.insert(seq)
            send(GDTWire.release(seq: seq, stream: f.stream), "Release (fetch ended)")
        }
        if abandonedSeqs.count > 64 { abandonedSeqs = Set(abandonedSeqs.sorted().suffix(32)) }
        emit(.fetchFailed(why))
        f.observer?(.failed(why))
    }

    private func discardOutput(_ f: Fetch) {
        try? f.output?.close()
        if let url = f.outputURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Stall watchdog: fails the fetch when no host answer came within `stallTimeout`; re-arms while answers come.
    private func arm() {
        guard let scheduleAfter, let f = fetch else { return }
        let id = f.id, mark = activity
        scheduleAfter(stallTimeout) { [weak self] in
            guard let self, let f = self.fetch, f.id == id else { return }
            if self.activity == mark { return self.fail("no answer from the host within \(Int(self.stallTimeout)) s") }
            self.arm()
        }
    }

    private func reply(_ m: GDTMessage) {
        typealias C = GDTWire.Command
        guard var f = fetch, m.seq == f.seq || m.seq == f.pending.first?.seq else {
            if abandonedSeqs.contains(m.seq) {
                // A stream opened for a fetch that has ended: give it back.
                if m.command == C.openStreamReply, m.body.count >= 12, LEBytes.u32(m.body, 0) == GDTWire.statusOK {
                    let seq = takeSeq()
                    abandonedSeqs.insert(seq)
                    send(GDTWire.release(seq: seq, stream: LEBytes.u64(m.body, 4)), "Release (fetch ended)")
                }
                return
            }
            return emit(.unexpected(m, why: "no request of ours with this seq"))
        }
        activity &+= 1
        let b = m.body
        switch (f.step, m.command) {
        case (.descriptor, C.getDataBegin):
            guard b.count >= 12 else { return fail("begin body \(b.count) B") }
            f.expected = Int(LEBytes.u32(b, 8))
            f.chunk = []
            guard f.expected <= 4 + 1000 * ClipboardFileGroup.entrySize + 4096 else { return fail("descriptor of \(f.expected) B") }
            fetch = f
        case (.descriptor, C.getDataData):
            guard b.count >= 10 else { return fail("data body \(b.count) B") }
            let n = Int(LEBytes.u16(b, 8))
            guard b.count >= 10 + n, f.chunk.count + n <= max(f.expected, 0) else { return fail("data chunk \(n) B does not fit") }
            f.chunk += b[10..<(10 + n)]
            fetch = f
        case (.read(let i), C.readBegin):
            guard b.count >= 12, let head = f.pending.first else { return fail("begin body \(b.count) B") }
            f.expected = Int(LEBytes.u32(b, 8))
            f.got = 0
            guard f.expected <= Int(head.count) else { return fail("the host sends \(f.expected) B for a read of \(head.count)") }
            // Checked before any byte is written; the bytes of such a read are dropped and the file given up at its end.
            let entry = f.entries[i]
            let known = entry.flags & ClipboardFileGroup.fdFileSize != 0
            let after = f.written + f.expected
            f.skip = after > maxFileSize ? "over the \(maxFileSize) B cap"
                : known && UInt64(after) > entry.size ? "the host sends more than the \(entry.size) B it announced" : nil
            fetch = f
        case (.read, C.readData):
            guard b.count >= 10 else { return fail("data body \(b.count) B") }
            let n = Int(LEBytes.u16(b, 8))
            guard b.count >= 10 + n, f.got + n <= max(f.expected, 0) else { return fail("data chunk \(n) B does not fit") }
            // Straight to disk: nothing of a file is held in memory beyond one message.
            if n > 0, f.skip == nil, f.abandon == nil {
                do { try f.output?.write(contentsOf: Data(b[10..<(10 + n)])) } catch {
                    f.skip = "cannot write: \(error.localizedDescription)"
                }
            }
            f.got += n
            fetch = f
        case (.descriptor, C.getDataEnd):
            let status = b.count >= 12 ? LEBytes.u32(b, 8) : 0xFFFF_FFFF
            guard status == GDTWire.statusOK else { return fail(String(format: "GetData status 0x%08x", status)) }
            do { f.entries = try ClipboardFileGroup.parse(Data(f.chunk), maxEntries: 1000) } catch {
                return fail("FILEGROUPDESCRIPTORW not usable: \(error)")
            }
            f.chunk = []
            if case .files(_, let expect?) = f.mode, !Self.sameGroup(expect, f.entries) {
                fetch = f
                return fail("the host clipboard changed (another file group)")
            }
            fetch = f
            emit(.fileGroup(f.entries))
            f.observer?(.group(f.entries))
            openNext(after: -1)
        case (.open(let i), C.openStreamReply):
            guard b.count >= 12 else { return fail("OpenStream reply \(b.count) B") }
            let status = LEBytes.u32(b, 0)
            guard status == GDTWire.statusOK else {
                discardOutput(f)
                f.output = nil; f.outputURL = nil
                fetch = f
                fileFailed(i, String(format: "OpenStream status 0x%08x", status))
                return openNext(after: i)
            }
            f.stream = LEBytes.u64(b, 4)
            f.pending = []
            f.ending = false
            f.skip = nil
            fetch = f
            fillReads(i)
        case (.read(let i), C.readEnd):
            let status = b.count >= 12 ? LEBytes.u32(b, 8) : 0xFFFF_FFFF
            guard f.got == f.expected else { return fail("Read: \(f.got) of \(f.expected) B") }
            f.pending.removeFirst()
            if let head = f.pending.first { f.seq = head.seq }
            let got = f.got
            f.got = 0
            if status >= 0x8000_0000 { f.abandon = f.abandon ?? String(format: "Read status 0x%08x", status) }
            if let skip = f.skip { f.abandon = f.abandon ?? skip; f.skip = nil }
            if f.abandon != nil {
                // Replies still due for this stream are dropped; the Release reply comes after them.
                for p in f.pending { abandonedSeqs.insert(p.seq) }
                f.pending = []
                fetch = f
                return releaseCurrent(i)
            }
            f.written += got
            fetch = f
            if got > 0 { f.observer?(.progress(index: i, bytes: f.written)) }
            // The end of the stream: a read with no bytes (the host says S_FALSE there [B]).
            if got == 0 || status != GDTWire.statusOK { f.ending = true; fetch = f }
            if f.ending {
                guard f.pending.isEmpty else { return }
                let entry = f.entries[i]
                if entry.flags & ClipboardFileGroup.fdFileSize != 0, UInt64(f.written) != entry.size {
                    f.abandon = "\(f.written) of the \(entry.size) B the host announced"
                    fetch = f
                }
                releaseCurrent(i)
            } else {
                fillReads(i)
            }
        case (.release(let i), C.releaseReply):
            if let why = f.abandon {
                discardOutput(f)
                f.output = nil; f.outputURL = nil; f.abandon = nil
                fetch = f
                fileFailed(i, why)
            } else {
                store(i)
            }
            openNext(after: i)
        default:
            emit(.unexpected(m, why: "not expected now"))
        }
    }

    /// Same names and sizes (and kinds) in the same order.
    static func sameGroup(_ a: [ClipboardFileEntry], _ b: [ClipboardFileEntry]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.name == $1.name && $0.size == $1.size && $0.isDirectory == $1.isDirectory }
    }

    private func fileFailed(_ i: Int, _ why: String) {
        guard let f = fetch else { return }
        emit(.fileFailed(index: i, why: why))
        f.observer?(.fileFailed(index: i, why: why))
    }

    /// The next file to read after `i`, its output file created first (a file that cannot be created fails alone).
    private func openNext(after i: Int) {
        guard var f = fetch else { return }
        f.output = nil; f.outputURL = nil; f.written = 0; f.abandon = nil; f.stream = 0; f.lastCount = 0
        f.pending = []; f.ending = false; f.skip = nil; f.got = 0
        fetch = f
        var candidates: [Int]
        switch f.mode {
        case .descriptor: candidates = []
        case .flat:
            candidates = Array(0..<min(f.entries.count, maxFiles)).filter { !f.entries[$0].isDirectory && f.entries[$0].size <= UInt64(maxFileSize) }
        case .files(let targets, _):
            candidates = targets.keys.sorted().filter { $0 < f.entries.count && !f.entries[$0].isDirectory }
        }
        for next in candidates where next > i {
            if case .files = f.mode, f.entries[next].size > UInt64(maxFileSize) {
                fileFailed(next, "\(f.entries[next].size) B is over the \(maxFileSize) B cap")
                continue
            }
            guard let (handle, url) = createOutput(next, f) else { continue }
            f.output = handle
            f.outputURL = url
            f.seq = takeSeq()
            f.step = .open(next)
            fetch = f
            send(GDTWire.openStream(seq: f.seq, index: UInt32(next), indexOffset: indexOffset), "OpenStream file \(next)")
            return arm()
        }
        fetch = nil
        emit(.fetchDone(files: f.received))
        f.observer?(.done(files: f.received))
    }

    private func createOutput(_ i: Int, _ f: Fetch) -> (FileHandle, URL)? {
        var url: URL
        var permissions: mode_t = filePermissions
        switch f.mode {
        case .descriptor: return nil
        case .flat(let directory):
            let name = Self.localName(f.entries[i].name, index: i)
            url = directory.appendingPathComponent(name)
            var n = 1
            while FileManager.default.fileExists(atPath: url.path) {
                n += 1
                url = directory.appendingPathComponent("\(n)-\(name)")
            }
            permissions = 0o600
        case .files(let targets, _):
            guard let target = targets[i] else { return nil }
            url = target
        }
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard fd >= 0 else {
            fileFailed(i, "cannot create the file: \(String(cString: strerror(errno)))")
            return nil
        }
        if case .files = f.mode, let agent = quarantineAgent { CDMPOSIXFileSystem.setQuarantine(fd: fd, agent: agent) }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), url)
    }

    /// Keeps up to `readAhead` Reads outstanding (one for a file of unknown size): the remaining bytes in `readSize`
    /// counts, then one more Read for the end of the stream (the stock client asked the same count again there [B]).
    private func fillReads(_ i: Int) {
        guard var f = fetch else { return }
        let entry = f.entries[i]
        let known = entry.flags & ClipboardFileGroup.fdFileSize != 0
        let depth = known ? max(1, readAhead) : 1
        var sent = false
        while f.pending.count < depth, !f.ending, !f.pending.contains(where: \.end) {
            let count: UInt32
            var end = false
            if known {
                let asked = f.pending.reduce(UInt64(0)) { $0 + UInt64($1.count) }
                let covered = UInt64(f.written) + asked
                if covered < entry.size {
                    count = UInt32(min(entry.size - covered, UInt64(readSize)))
                } else {
                    count = max(1, f.lastCount)
                    end = true
                }
            } else {
                count = UInt32(readSize)
            }
            f.lastCount = count
            let seq = takeSeq()
            f.pending.append((seq, count, end))
            f.step = .read(i)
            fetch = f
            send(GDTWire.read(seq: seq, stream: f.stream, count: count), "Read file \(i)")
            sent = true
        }
        if let head = f.pending.first { f.seq = head.seq }
        fetch = f
        if sent { arm() }
    }

    private func releaseCurrent(_ i: Int) {
        guard var f = fetch else { return }
        f.seq = takeSeq()
        f.step = .release(i)
        fetch = f
        send(GDTWire.release(seq: f.seq, stream: f.stream), "Release file \(i)")
        arm()
    }

    private func store(_ i: Int) {
        guard var f = fetch, let url = f.outputURL else { return }
        try? f.output?.close()
        f.output = nil
        let entry = f.entries[i]
        var attributes: [FileAttributeKey: Any] = [:]
        if let t = entry.writeTime { attributes[.modificationDate] = t }
        if case .files = f.mode, entry.attributes & 0x1 != 0 { attributes[.posixPermissions] = NSNumber(value: 0o444) }   // FILE_ATTRIBUTE_READONLY
        if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path) }
        if case .files = f.mode, entry.attributes & ClipboardFileGroup.attributeHidden != 0 { _ = chflags(url.path, UInt32(UF_HIDDEN)) }
        f.received += 1
        f.outputURL = nil
        fetch = f
        receivedFiles.append(url)
        emit(.receivedFile(index: i, name: entry.name, url: url, bytes: f.written))
        f.observer?(.file(index: i, url: url, bytes: f.written))
    }

    /// The last path component of a Windows relative name, safe as a Mac file name ("/" and ":" → "_", no "."/"..").
    public static func localName(_ windowsName: String, index: Int) -> String {
        let last = windowsName.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        let clean = last.replacingOccurrences(of: ":", with: "_").filter { $0 != "\0" }
        return clean.isEmpty || clean == "." || clean == ".." ? "file-\(index)" : clean
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
