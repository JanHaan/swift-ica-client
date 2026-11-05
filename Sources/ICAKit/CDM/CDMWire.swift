import Foundation

/// Wire format of client drive mapping, channel `CTXCDM ` (docs/95-file-transfer.md §A).
///
/// Every message is `u8 command, u8 request id`, then a fixed layout per command whose variable strings
/// take their lengths from earlier fields (§A.2). There is **no length field**: a command we do not know
/// cannot be skipped, so the parser stops for good there (§A.8 step 2). All integers are little-endian.
public enum CDMWire {
    public static let channelName = "CTXCDM "
    /// Fixed channel number (docs/30 §10, docs/95 §A.1).
    public static let channelNumber: UInt8 = 10
    /// Module class VD, versions 1…10 (§A.1).
    public static let versionLow: UInt8 = 1
    public static let versionHigh: UInt8 = 10
    /// Flow-control type 3 (VirtualFlow_Cdm) with VDFLOWCDM { MaxWindowSize, MaxByteCount } (§A.1). The
    /// client never acknowledges anything on this flow type.
    public static let flowType: UInt8 = 3
    public static let maxWindowSize: UInt16 = 62500
    public static let maxByteCount: UInt16 = 4116

    /// A reply's command byte is the request's with this bit set (§A.2).
    public static let replyBit: UInt8 = 0x80
    /// "No handle" (§A.3 field constants).
    public static let noHandle: UInt16 = 0xFFFF
    /// CONNECT flags bit: UTF-8 paths and V2 find entries (§A.3).
    public static let connectUTF8: UInt16 = 0x10
    /// CONNECT reply caps (§A.3).
    public static let capsUTF8: UInt16 = 0x01 | 0x08
    public static let capsCodePage: UInt16 = 0x01 | 0x02

    public enum Command: UInt8, Sendable, CaseIterable {
        case create = 0x00
        case open = 0x01
        case close = 0x02
        case read = 0x03
        case write = 0x04
        case findFirst = 0x05
        case findNext = 0x06
        case findClose = 0x07
        case getAttributes = 0x08
        case setAttributes = 0x09
        case getDateTime = 0x0A
        case setDateTime = 0x0B
        case delete = 0x0C
        case rename = 0x0D
        case createDirectory = 0x0E
        case deleteDirectory = 0x0F
        case readConditional = 0x11
        case changeSize = 0x14
        case seek = 0x15
        case volumeInfo = 0x16
        case connect = 0x17
        case findFirstIndex = 0x18

        /// The engine's debug names (§A.3).
        public var name: String {
            switch self {
            case .create: return "CREATE"
            case .open: return "OPEN"
            case .close: return "CLOSE"
            case .read: return "READ"
            case .write: return "WRITE"
            case .findFirst: return "FIND_FIRST"
            case .findNext: return "FIND_NEXT"
            case .findClose: return "FIND_CLOSE"
            case .getAttributes: return "GET_ATTRIBUTES"
            case .setAttributes: return "SET_ATTRIBUTES"
            case .getDateTime: return "GET_DATE_TIME"
            case .setDateTime: return "SET_DATE_TIME"
            case .delete: return "DELETE"
            case .rename: return "RENAME"
            case .createDirectory: return "CREATE_DIRECTORY"
            case .deleteDirectory: return "DELETE_DIRECTORY"
            case .readConditional: return "READ_CONDITIONAL"
            case .changeSize: return "FILE_CHANGE_SIZE"
            case .seek: return "FILE_SEEK"
            case .volumeInfo: return "VOLUME_INFO"
            case .connect: return "CONNECT"
            case .findFirstIndex: return "FIND_FIRST_INDEX"
            }
        }

        /// Commands the host must not see answered: CLOSE and FIND_CLOSE have no reply (§A.3); FILE_SEEK
        /// replies only for mode 2.
        public var hasReply: Bool { self != .close && self != .findClose }

        /// Reply command byte. FIND_FIRST_INDEX answers as FIND_FIRST (0x85, §A.3).
        public var replyCommand: UInt8 { (self == .findFirstIndex ? Command.findFirst.rawValue : rawValue) | CDMWire.replyBit }
    }

    /// Names the engine knows but never dispatches, for logs (§A.3 rows 0x12/0x13, 0x19–0x1F).
    public static func unknownName(_ command: UInt8) -> String {
        switch command {
        case 0x12: return "FILE_LOCK"
        case 0x13: return "FILE_UNLOCK"
        case 0x19: return "WRITE_PRE_BURST"
        case 0x1A: return "WRITE_IN_BURST"
        case 0x1B: return "STOPPED_BURST_WRITES"
        case 0x1C: return "CLOSE_PLUS"
        case 0x1D: return "CREATE_PLUS"
        case 0x1E: return "OPEN_PLUS"
        case 0x1F: return "GET_ATTRIBUTES_PLUS"
        default: return String(format: "0x%02X", command)
        }
    }
}

/// Status codes (§A.4): low byte = DOS error class, high byte = DOS error code.
public enum CDMStatus {
    public static let success: UInt16 = 0x0000
    /// FILE_NOT_FOUND, class 1: OPEN of a missing file, a missing entry.
    public static let fileNotFound: UInt16 = 0x0201
    /// FILE_NOT_FOUND, class 8: CREATE "open existing" of a missing file.
    public static let fileNotFoundCreate: UInt16 = 0x0208
    /// PATH_NOT_FOUND, class 1: bad path.
    public static let pathNotFound: UInt16 = 0x0301
    /// PATH_NOT_FOUND, class 8: missing folder in a search.
    public static let pathNotFoundSearch: UInt16 = 0x0308
    /// ACCESS_DENIED, class 2: VOLUME_INFO on an unresolvable path.
    public static let volumeDenied: UInt16 = 0x0502
    /// ACCESS_DENIED, class 3: no permission, bad handle, read-only drive, not empty (§A.4 [P]).
    public static let accessDenied: UInt16 = 0x0503
    public static let noMoreFiles: UInt16 = 0x1201
    /// WRITE_FAULT: CREATE_DIRECTORY failed.
    public static let writeFault: UInt16 = 0x1D0E
    public static let fileExists: UInt16 = 0x500C
    /// Generic failure.
    public static let failure: UInt16 = 0xFF0E

    public static func label(_ status: UInt16) -> String {
        switch status {
        case success: return "ok"
        case fileNotFound, fileNotFoundCreate: return String(format: "FILE_NOT_FOUND 0x%04X", status)
        case pathNotFound, pathNotFoundSearch: return String(format: "PATH_NOT_FOUND 0x%04X", status)
        case volumeDenied, accessDenied: return String(format: "ACCESS_DENIED 0x%04X", status)
        case noMoreFiles: return "NO_MORE_FILES"
        case writeFault: return "WRITE_FAULT"
        case fileExists: return "FILE_EXISTS"
        default: return String(format: "0x%04X", status)
        }
    }
}

/// DOS attributes (§A.3 field constants).
public enum CDMAttributes {
    public static let readOnly: UInt16 = 0x01
    public static let hidden: UInt16 = 0x02
    public static let system: UInt16 = 0x04
    public static let volume: UInt16 = 0x08
    public static let directory: UInt16 = 0x10
    public static let archive: UInt16 = 0x20
}

/// DOS date and time in local time (§A.3): date = (year−1980)<<9 | month<<5 | day, the year clamped to
/// 1980…2099; time = hour<<11 | minute<<5 | second/2.
public struct CDMDosTime: Equatable, Sendable {
    public var date: UInt16
    public var time: UInt16

    public init(date: UInt16, time: UInt16) {
        self.date = date
        self.time = time
    }

    public init(_ value: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        let year = c.year ?? 1980
        if year < 1980 {
            self.init(date: 1 << 5 | 1, time: 0)  // 1980-01-01 00:00:00
        } else if year > 2099 {
            self.init(date: UInt16(2099 - 1980) << 9 | 12 << 5 | 31, time: 23 << 11 | 59 << 5 | 29)
        } else {
            self.init(date: UInt16(year - 1980) << 9 | UInt16(c.month ?? 1) << 5 | UInt16(c.day ?? 1),
                      time: UInt16(c.hour ?? 0) << 11 | UInt16(c.minute ?? 0) << 5 | UInt16((c.second ?? 0) / 2))
        }
    }

    /// The moment, or nil for an invalid stamp (month 0, day 0, hour 24, …).
    public func date(timeZone: TimeZone = .current) -> Date? {
        var c = DateComponents()
        c.year = 1980 + Int(date >> 9)
        c.month = Int(date >> 5 & 0x0F)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int(time >> 5 & 0x3F)
        c.second = Int(time & 0x1F) * 2
        guard (1...12).contains(c.month!), (1...31).contains(c.day!), c.hour! < 24, c.minute! < 60, c.second! < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let value = calendar.date(from: c),
              calendar.component(.day, from: value) == c.day else { return nil }  // e.g. 31 February
        return value
    }
}

// MARK: - Requests (host → client)

public enum CDMRequestBody: Equatable, Sendable {
    case create(path: Data, access: UInt16, disposition: UInt16, attributes: UInt16, unknown1: UInt16, unknown2: UInt16)
    case open(path: Data, mode: UInt16)
    case close(handle: UInt16)
    case read(handle: UInt16, offset: UInt32, count: UInt16)
    case write(handle: UInt16, offset: UInt32, data: Data)
    case findFirst(path: Data, bufferSize: UInt16, maxEntries: UInt8)
    case findNext(handle: UInt16, bufferSize: UInt16, maxEntries: UInt8)
    case findClose(handle: UInt16)
    case getAttributes(path: Data)
    case setAttributes(path: Data, attributes: UInt16)
    case getDateTime(handle: UInt16)
    case setDateTime(handle: UInt16, time: UInt16, date: UInt16)
    case delete(path: Data)
    case rename(from: Data, to: Data)
    case createDirectory(path: Data, unknown1: UInt16, unknown2: UInt16, date: UInt16, time: UInt16)
    case deleteDirectory(path: Data)
    case readConditional(handle: UInt16, time: UInt16, date: UInt16, offset: UInt32, unknown: UInt32, count: UInt16)
    case changeSize(handle: UInt16, size: UInt32)
    case seek(handle: UInt16, offset: UInt32, mode: UInt8)
    case volumeInfo(path: Data, flags: UInt16)
    /// The eight u16 fields; only `fields[3] & 0x10` (UTF-8) is used (§A.3).
    case connect(fields: [UInt16])
    case findFirstIndex(path: Data, bufferSize: UInt16, index: UInt16, maxEntries: UInt8)

    public var command: CDMWire.Command {
        switch self {
        case .create: return .create
        case .open: return .open
        case .close: return .close
        case .read: return .read
        case .write: return .write
        case .findFirst: return .findFirst
        case .findNext: return .findNext
        case .findClose: return .findClose
        case .getAttributes: return .getAttributes
        case .setAttributes: return .setAttributes
        case .getDateTime: return .getDateTime
        case .setDateTime: return .setDateTime
        case .delete: return .delete
        case .rename: return .rename
        case .createDirectory: return .createDirectory
        case .deleteDirectory: return .deleteDirectory
        case .readConditional: return .readConditional
        case .changeSize: return .changeSize
        case .seek: return .seek
        case .volumeInfo: return .volumeInfo
        case .connect: return .connect
        case .findFirstIndex: return .findFirstIndex
        }
    }
}

public struct CDMRequest: Equatable, Sendable {
    public var id: UInt8
    public var body: CDMRequestBody
    public init(id: UInt8, _ body: CDMRequestBody) {
        self.id = id
        self.body = body
    }
    public var command: CDMWire.Command { body.command }

    /// The request's wire bytes (the fake host in tests and icactl use it).
    public func encode() -> Data {
        var w = ByteWriter()
        w.u8(command.rawValue)
        w.u8(id)
        func len(_ d: Data) { w.u16(UInt16(clamping: d.count)) }
        switch body {
        case let .create(path, access, disposition, attributes, u1, u2):
            len(path); w.u16(access); w.u16(disposition); w.u16(attributes); w.u16(u1); w.u16(u2); w.raw(path)
        case let .open(path, mode):
            len(path); w.u16(mode); w.raw(path)
        case let .close(h), let .findClose(h), let .getDateTime(h):
            w.u16(h)
        case let .read(h, offset, count):
            w.u16(h); w.u32(offset); w.u16(count)
        case let .write(h, offset, data):
            w.u16(h); w.u32(offset); len(data); w.raw(data)
        case let .findFirst(path, bufferSize, maxEntries):
            len(path); w.u16(bufferSize); w.u8(maxEntries); w.raw(path)
        case let .findNext(h, bufferSize, maxEntries):
            w.u16(h); w.u16(bufferSize); w.u8(maxEntries)
        case let .getAttributes(path), let .delete(path), let .deleteDirectory(path):
            len(path); w.raw(path)
        case let .setAttributes(path, attributes):
            len(path); w.u16(attributes); w.raw(path)
        case let .setDateTime(h, time, date):
            w.u16(h); w.u16(time); w.u16(date)
        case let .rename(from, to):
            len(from); len(to); w.raw(from); w.raw(to)
        case let .createDirectory(path, u1, u2, date, time):
            len(path); w.u16(u1); w.u16(u2); w.u16(date); w.u16(time); w.raw(path)
        case let .readConditional(h, time, date, offset, unknown, count):
            w.u16(h); w.u16(time); w.u16(date); w.u32(offset); w.u32(unknown); w.u16(count)
        case let .changeSize(h, size):
            w.u16(h); w.u32(size)
        case let .seek(h, offset, mode):
            w.u16(h); w.u32(offset); w.u8(mode)
        case let .volumeInfo(path, flags):
            len(path); w.u16(flags); w.raw(path)
        case let .connect(fields):
            for i in 0..<8 { w.u16(i < fields.count ? fields[i] : 0) }
        case let .findFirstIndex(path, bufferSize, index, maxEntries):
            len(path); w.u16(bufferSize); w.u16(index); w.u8(maxEntries); w.raw(path)
        }
        return w.data
    }
}

/// Incremental host-stream parser (§A.2). Messages are not aligned to VC writes: an incomplete message
/// waits for more bytes and is parsed again from its first byte. The largest message is bounded by its
/// u16 length fields (RENAME: 6 + 2 × 65535 bytes), so the buffer is bounded too.
///
/// Unknown commands (0x10, 0x12, 0x13, 0x19 and up, and anything with the reply bit) are **fatal**: the
/// stream has no length field to skip them, so the parser stops for good, drops what it holds and
/// ignores every later byte (§A.8 step 2). Nothing else is fatal: every known layout is self-delimiting,
/// so bad field values (absurd paths, bad handles) are the server's business and get an error reply.
public struct CDMStreamParser {
    public enum Item: Equatable, Sendable {
        case request(CDMRequest)
        /// The stream is lost. `head` is the first ≤ 16 bytes at the failing position.
        case fatal(command: UInt8, head: Data)
    }

    public static let headLength = 16

    private var buffer = Data()
    public private(set) var failed = false

    public init() {}

    /// Bytes held for an incomplete message.
    public var bufferedCount: Int { buffer.count }

    public mutating func feed(_ data: Data) -> [Item] {
        guard !failed else { return [] }
        buffer.append(data)
        var out: [Item] = []
        var position = buffer.startIndex
        while position < buffer.endIndex {
            let rest = buffer[position...]
            switch Self.parseOne(rest) {
            case .needMore:
                buffer = Data(rest)
                return out
            case .request(let request, let used):
                out.append(.request(request))
                position += used
            case .fatal(let command):
                out.append(.fatal(command: command, head: Data(rest.prefix(Self.headLength))))
                failed = true
                buffer = Data()
                return out
            }
        }
        buffer = Data()
        return out
    }

    private enum Parsed {
        case needMore
        case request(CDMRequest, Int)
        case fatal(UInt8)
    }

    private static func parseOne(_ bytes: Data) -> Parsed {
        var r = ByteReader(bytes)
        guard let first = try? r.u8() else { return .needMore }
        guard let command = CDMWire.Command(rawValue: first) else { return .fatal(first) }
        do {
            let id = try r.u8()
            let body: CDMRequestBody
            switch command {
            case .create:
                let n = try r.u16(), access = try r.u16(), disposition = try r.u16(), attributes = try r.u16()
                let u1 = try r.u16(), u2 = try r.u16()
                body = .create(path: try r.raw(Int(n)), access: access, disposition: disposition, attributes: attributes,
                               unknown1: u1, unknown2: u2)
            case .open:
                let n = try r.u16(), mode = try r.u16()
                body = .open(path: try r.raw(Int(n)), mode: mode)
            case .close: body = .close(handle: try r.u16())
            case .read:
                let h = try r.u16(), offset = try r.u32(), count = try r.u16()
                body = .read(handle: h, offset: offset, count: count)
            case .write:
                let h = try r.u16(), offset = try r.u32(), n = try r.u16()
                body = .write(handle: h, offset: offset, data: try r.raw(Int(n)))
            case .findFirst:
                let n = try r.u16(), size = try r.u16(), max = try r.u8()
                body = .findFirst(path: try r.raw(Int(n)), bufferSize: size, maxEntries: max)
            case .findNext:
                let h = try r.u16(), size = try r.u16(), max = try r.u8()
                body = .findNext(handle: h, bufferSize: size, maxEntries: max)
            case .findClose: body = .findClose(handle: try r.u16())
            case .getAttributes: body = .getAttributes(path: try r.raw(Int(try r.u16())))
            case .setAttributes:
                let n = try r.u16(), attributes = try r.u16()
                body = .setAttributes(path: try r.raw(Int(n)), attributes: attributes)
            case .getDateTime: body = .getDateTime(handle: try r.u16())
            case .setDateTime:
                let h = try r.u16(), time = try r.u16(), date = try r.u16()
                body = .setDateTime(handle: h, time: time, date: date)
            case .delete: body = .delete(path: try r.raw(Int(try r.u16())))
            case .rename:
                let a = try r.u16(), b = try r.u16()
                let from = try r.raw(Int(a))
                body = .rename(from: from, to: try r.raw(Int(b)))
            case .createDirectory:
                let n = try r.u16(), u1 = try r.u16(), u2 = try r.u16(), date = try r.u16(), time = try r.u16()
                body = .createDirectory(path: try r.raw(Int(n)), unknown1: u1, unknown2: u2, date: date, time: time)
            case .deleteDirectory: body = .deleteDirectory(path: try r.raw(Int(try r.u16())))
            case .readConditional:
                let h = try r.u16(), time = try r.u16(), date = try r.u16(), offset = try r.u32()
                let unknown = try r.u32(), count = try r.u16()
                body = .readConditional(handle: h, time: time, date: date, offset: offset, unknown: unknown, count: count)
            case .changeSize:
                let h = try r.u16()
                body = .changeSize(handle: h, size: try r.u32())
            case .seek:
                let h = try r.u16(), offset = try r.u32()
                body = .seek(handle: h, offset: offset, mode: try r.u8())
            case .volumeInfo:
                let n = try r.u16(), flags = try r.u16()
                body = .volumeInfo(path: try r.raw(Int(n)), flags: flags)
            case .connect:
                var fields: [UInt16] = []
                for _ in 0..<8 { fields.append(try r.u16()) }
                body = .connect(fields: fields)
            case .findFirstIndex:
                let n = try r.u16(), size = try r.u16(), index = try r.u16(), max = try r.u8()
                body = .findFirstIndex(path: try r.raw(Int(n)), bufferSize: size, index: index, maxEntries: max)
            }
            return .request(CDMRequest(id: id, body), r.offset - bytes.startIndex)
        } catch {
            return .needMore
        }
    }
}

// MARK: - Replies (client → host)

public enum CDMReplyBody: Equatable, Sendable {
    /// CREATE, OPEN: `ctx, st`.
    case handle(UInt16, status: UInt16)
    /// READ: `ctx, u16 date, u16 time, u16 len, st, data`. The reference always sends date/time 0.
    case read(UInt16, date: UInt16, time: UInt16, status: UInt16, data: Data)
    /// READ_CONDITIONAL: the READ reply, then `u16 notModified` (§A.3).
    case readConditional(UInt16, date: UInt16, time: UInt16, status: UInt16, data: Data, notModified: UInt16)
    /// WRITE: `ctx, u16 written, st`.
    case write(UInt16, written: UInt16, status: UInt16)
    /// FIND_FIRST/NEXT/FIRST_INDEX: `findCtx, u16 entryBytes, st, u8 count, entries`.
    case find(UInt16, status: UInt16, count: UInt8, entries: Data)
    /// GET_ATTRIBUTES: `st, u32 size, u16 attributes, u16 date, u16 time`.
    case attributes(status: UInt16, size: UInt32, attributes: UInt16, date: UInt16, time: UInt16)
    /// SET_ATTRIBUTES, DELETE, CREATE_DIRECTORY, DELETE_DIRECTORY: `st`.
    case status(UInt16)
    /// GET_DATE_TIME: `ctx, u16 date, u16 time, st`.
    case dateTime(UInt16, date: UInt16, time: UInt16, status: UInt16)
    /// SET_DATE_TIME, FILE_CHANGE_SIZE: `ctx, st`.
    case handleStatus(UInt16, status: UInt16)
    /// RENAME: `st, u16 0`.
    case rename(status: UInt16)
    /// FILE_SEEK (mode 2 only): `ctx, u32 fileSize, st`.
    case seek(UInt16, size: UInt32, status: UInt16)
    /// VOLUME_INFO: `st, u32 0x40404041, u32 0x20202020, u32 0x00100000, u32 0, u32 0, u16 labelLen, u16 0, label`.
    case volume(status: UInt16, label: Data)
    /// CONNECT: `u8 0, u8 0, u16 1, u16 10, u16 caps`.
    case connect(caps: UInt16)
}

public struct CDMReply: Equatable, Sendable {
    /// The reply command byte (request command | 0x80; 0x85 for FIND_FIRST_INDEX).
    public var command: UInt8
    public var id: UInt8
    public var body: CDMReplyBody

    public init(to request: CDMRequest, _ body: CDMReplyBody) {
        command = request.command.replyCommand
        id = request.id
        self.body = body
    }

    public init(command: UInt8, id: UInt8, _ body: CDMReplyBody) {
        self.command = command
        self.id = id
        self.body = body
    }

    public var status: UInt16 {
        switch body {
        case .handle(_, let st), .read(_, _, _, let st, _), .readConditional(_, _, _, let st, _, _), .write(_, _, let st),
             .find(_, let st, _, _), .attributes(let st, _, _, _, _), .status(let st), .dateTime(_, _, _, let st),
             .handleStatus(_, let st), .rename(let st), .seek(_, _, let st), .volume(let st, _):
            return st
        case .connect: return CDMStatus.success
        }
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.u8(command)
        w.u8(id)
        switch body {
        case let .handle(ctx, st):
            w.u16(ctx); w.u16(st)
        case let .read(ctx, date, time, st, data):
            w.u16(ctx); w.u16(date); w.u16(time); w.u16(UInt16(clamping: data.count)); w.u16(st); w.raw(data)
        case let .readConditional(ctx, date, time, st, data, notModified):
            w.u16(ctx); w.u16(date); w.u16(time); w.u16(UInt16(clamping: data.count)); w.u16(st); w.raw(data)
            w.u16(notModified)
        case let .write(ctx, written, st):
            w.u16(ctx); w.u16(written); w.u16(st)
        case let .find(ctx, st, count, entries):
            w.u16(ctx); w.u16(UInt16(clamping: entries.count)); w.u16(st); w.u8(count); w.raw(entries)
        case let .attributes(st, size, attributes, date, time):
            w.u16(st); w.u32(size); w.u16(attributes); w.u16(date); w.u16(time)
        case let .status(st):
            w.u16(st)
        case let .dateTime(ctx, date, time, st):
            w.u16(ctx); w.u16(date); w.u16(time); w.u16(st)
        case let .handleStatus(ctx, st):
            w.u16(ctx); w.u16(st)
        case let .rename(st):
            w.u16(st); w.u16(0)
        case let .seek(ctx, size, st):
            w.u16(ctx); w.u32(size); w.u16(st)
        case let .volume(st, label):
            w.u16(st)
            for v: UInt32 in [0x4040_4041, 0x2020_2020, 0x0010_0000, 0, 0] { w.u32(v) }
            w.u16(UInt16(clamping: label.count)); w.u16(0); w.raw(label)
        case let .connect(caps):
            w.u8(0); w.u8(0); w.u16(1); w.u16(10); w.u16(caps)
        }
        return w.data
    }
}

/// One find entry (§A.5). V1 (code page): `u16 time, u16 date, u32 size, u16 attributes, u8 shortLen,
/// u8 longLen, short, long`; V2 (UTF-8): the same with a u16 longLen.
public struct CDMFindEntry: Equatable, Sendable {
    public var stamp: CDMDosTime
    public var size: UInt32
    public var attributes: UInt16
    public var shortName: Data
    /// Empty when the name fits 8.3 (then `shortName` is the name).
    public var longName: Data

    public init(stamp: CDMDosTime, size: UInt32, attributes: UInt16, shortName: Data, longName: Data) {
        self.stamp = stamp
        self.size = size
        self.attributes = attributes
        self.shortName = shortName
        self.longName = longName
    }

    public func encode(utf8: Bool) -> Data {
        var w = ByteWriter()
        w.u16(stamp.time)
        w.u16(stamp.date)
        w.u32(size)
        w.u16(attributes)
        w.u8(UInt8(clamping: shortName.count))
        if utf8 { w.u16(UInt16(clamping: longName.count)) } else { w.u8(UInt8(clamping: longName.count)) }
        w.raw(shortName.prefix(255))
        w.raw(utf8 ? longName.prefix(0xFFFF) : longName.prefix(255))
        return w.data
    }
}
