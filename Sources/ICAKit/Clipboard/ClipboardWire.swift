import Foundation

/// Wire format of the clipboard channel `CTXCLIP` (docs/70-clipboard.md §2, §3, §9).
/// Every message is `u16 command, u16 flags, …`, little-endian, with **no length field**: each layout is
/// fixed or self-delimiting, so the parser must know every command exactly or it loses sync for good.
public enum ClipboardWire {
    public static let channelName = "CTXCLIP"
    /// Fixed channel number (docs/30 §10, docs/70 §1.1).
    public static let channelNumber: UInt8 = 17

    public enum Command: UInt16, Sendable {
        case initRequest = 0x0001       // CLIP_INIT, H→C, 6 bytes
        case initReply = 0x0002         // CLIP_INIT_REPLY, C→H, 12 bytes
        case formatList = 0x0003        // FORMAT_LIST, both
        case dataRequest = 0x0004       // DATA_REQUEST, both, 8 bytes
        case dataResponse = 0x0005      // DATA_RESPONSE, both
        case formatNames = 0x0008       // FORMAT_NAMES, H→C
        case formatNamesReply = 0x0009  // FORMAT_NAMES_REPLY, C→H
    }

    // Flags (§3.3).
    /// Set in every non-empty client FORMAT_LIST.
    public static let flagList: UInt16 = 0x0001
    /// FORMAT_LIST: more than one entry; the list ends with a bare u16 0.
    public static let flagMulti: UInt16 = 0x0002
    /// FORMAT_LIST: no entries follow. DATA_RESPONSE: failure, no data follows.
    public static let flagNone: UInt16 = 0x0004
    /// FORMAT_LIST (with 0x0004): the clipboard is empty.
    public static let flagEmpty: UInt16 = 0x0008

    /// Our default maximum (docs/70). 4 only in the discovery build (`ClipboardEngine.Config.maxVersion`, docs/75 §4.1).
    public static let maxClientVersion: UInt16 = 3
    /// Version 4: the host's DATA_REQUEST is read with a u32 index (hypothesis H1, docs/75 §4.2).
    public static let filesVersion: UInt16 = 4
    /// Versions ≥ 2 exchange FORMAT_NAMES before READY (§3.2.2).
    public static let namesVersion: UInt16 = 2
    /// Client → host VC write size (§2.2). 4996 needs WD cap 0x10, which we never negotiate.
    public static let writeSplit = 1020
    /// Entries of a host list we keep (§3.2.5, §4.8).
    public static let hostListCapacity = 100
    public static let registeredRange: ClosedRange<UInt16> = 0xC000...0xFFFF
    /// CF_PRIVATEFIRST…LAST: dropped from incoming host lists (§4.1).
    public static let privateRange: ClosedRange<UInt16> = 0x0200...0x02FF

    // MARK: Client → host builders (§3.2)

    /// CLIP_INIT_REPLY: `02 00 00 00 <u16 version> 00×6`.
    public static func initReply(version: UInt16) -> Data {
        var w = ByteWriter()
        w.u16(Command.initReply.rawValue)
        w.u16(0)
        w.u16(version)
        w.raw([UInt8](repeating: 0, count: 6))
        return w.data
    }

    /// FORMAT_NAMES_REPLY: every id the host named, in order, with length 0, then the zero terminator entry.
    public static func formatNamesReply(ids: [UInt16]) -> Data {
        var w = ByteWriter()
        w.u16(Command.formatNamesReply.rawValue)
        w.u16(0)
        for id in ids {
            w.u16(id)
            w.u32(0)
        }
        w.u16(0)
        w.u32(0)
        return w.data
    }

    /// The client "empty" FORMAT_LIST, exactly `03 00 0C 00` (§3.2.5).
    public static let emptyFormatList = Data([0x03, 0x00, 0x0C, 0x00])

    /// Client FORMAT_LIST: empty form, single form (flags 0x0001) or multi form (flags 0x0003, bare u16 0 at the end).
    public static func formatList(_ ids: [UInt16]) -> Data {
        guard !ids.isEmpty else { return emptyFormatList }
        var w = ByteWriter()
        w.u16(Command.formatList.rawValue)
        w.u16(ids.count > 1 ? flagList | flagMulti : flagList)
        for id in ids {
            w.u16(id)
            w.u32(0)
        }
        if ids.count > 1 { w.u16(0) }
        return w.data
    }

    /// DATA_REQUEST: `04 00 00 00 <u16 format> 00 00`; with `index` (version 4, hypothesis H1 of docs/75
    /// §4.2) `04 00 00 00 <u16 format> <u32 index>`, 10 bytes.
    public static func dataRequest(format: UInt16, index: UInt32? = nil) -> Data {
        var w = ByteWriter()
        w.u16(Command.dataRequest.rawValue)
        w.u16(0)
        w.u16(format)
        if let index { w.u32(index) } else { w.u16(0) }
        return w.data
    }

    /// Success DATA_RESPONSE: `05 00 00 00 <u16 format> <u32 length> data`.
    public static func dataResponse(format: UInt16, data: Data) -> Data {
        var w = ByteWriter()
        w.u16(Command.dataResponse.rawValue)
        w.u16(0)
        w.u16(format)
        w.u32(UInt32(data.count))
        w.raw(data)
        return w.data
    }

    /// Failure DATA_RESPONSE: `05 00 04 00`.
    public static let dataFailure = Data([0x05, 0x00, 0x04, 0x00])

    /// One client message as VC writes of at most `limit` bytes (§2.2).
    public static func split(_ message: Data, limit: Int = writeSplit) -> [Data] {
        precondition(limit > 0)
        var out: [Data] = []
        var start = message.startIndex
        while start < message.endIndex {
            let end = min(message.endIndex, start + limit)
            out.append(message.subdata(in: start..<end))
            start = end
        }
        return out
    }
}

/// One entry of the host's registered-format table (FORMAT_NAMES, §3.2.3).
public struct ClipboardFormatName: Equatable, Sendable {
    public let id: UInt16
    /// The name bytes as sent (the trailing NUL, if any, included).
    public let raw: Data
    /// One byte per character (bytes map 1:1 to code points), trailing NULs removed.
    public var name: String {
        var bytes = [UInt8](raw)
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    public init(id: UInt16, raw: Data) {
        self.id = id
        self.raw = raw
    }

    public init(id: UInt16, name: String, nul: Bool = true) {
        self.id = id
        raw = Data(name.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } + (nul ? [0] : []))
    }
}

/// A parsed host → client message.
public enum ClipboardHostMessage: Equatable, Sendable {
    /// Offset 2 is the host's lowest version, offset 4 its highest (docs/75 §4.1; live `01 00 04 00`).
    case initRequest(lowVersion: UInt16, highVersion: UInt16)
    case formatNames(flags: UInt16, entries: [ClipboardFormatName])
    /// `formats` is empty for the "no list" form (flags 0x0004); 0x0008 then means "clipboard empty".
    case formatList(flags: UInt16, formats: [UInt16])
    /// `index`: the u32 after the format at version 4 (hypothesis H1, docs/75 §4.2); nil at version ≤ 3.
    case dataRequest(flags: UInt16, format: UInt16, index: UInt32? = nil)
    /// `data` is nil when `length` was over the parser's cap: the bytes were consumed and discarded.
    case dataResponse(format: UInt16, length: Int, data: Data?)
    case dataFailure(flags: UInt16)
    /// Unknown command: the rest of the buffered bytes was dropped (§2.1 [P]). `head` is the first
    /// ≤ 16 bytes at the failing position; `previous` the header (≤ 16 bytes, never DATA_RESPONSE payload)
    /// of the message before it.
    case unknown(command: UInt16, flags: UInt16?, head: Data, previous: Data)
    /// A layout we cannot trust (absurd name length or entry count): buffered bytes dropped like `unknown`.
    case malformed(command: UInt16, flags: UInt16, reason: String, head: Data, previous: Data)
    /// u16 zero words where a command should start, skipped. Command 0 does not exist; live (host version
    /// 4), a DATA_REQUEST was followed by such bytes, so the host's request is longer than §3.2.6 says or
    /// padded. `previous` is the header of the message they followed. At version 4 only right after a
    /// DATA_REQUEST (anything else is a protocol error), so a non-zero field is never skipped silently.
    case padding(bytes: Int, previous: Data)
}

/// Incremental host-stream parser (§2.1). Messages are not aligned to VC writes: a message that is not
/// complete yet waits for more bytes (the parse restarts at its first byte). DATA_RESPONSE payloads are
/// consumed as they arrive, so a large transfer is never re-parsed and bytes beyond `dataCap` are not
/// kept at all (§3.2.7 [P]).
public struct ClipboardStreamParser {
    /// Largest DATA_RESPONSE payload kept (§4.8: 64 MiB host → Mac).
    public var dataCap: Int
    /// Name lengths above this cannot be real format names; treated as a lost sync.
    public static let maxNameLength = 0x1_0000
    /// Entry counts above this cannot be real lists; treated as a lost sync.
    public static let maxEntries = 0x4000
    /// Bytes of a message header kept for diagnostics.
    public static let headLength = 16

    /// Highest version we answer; with the host's CLIP_INIT it sets `version` (and so the request layout).
    public var maxVersion: UInt16 = ClipboardWire.maxClientVersion
    /// Negotiated version as seen by the parser (0 before CLIP_INIT).
    public private(set) var version: UInt16 = 0
    /// Discovery trace: keep the raw bytes of each message (`raw`, aligned with the last `feed` result):
    /// the whole message, but for DATA_RESPONSE only the 10 header bytes and up to `rawPayload` payload bytes.
    public var keepRaw = false
    public static let rawPayload = 64
    public private(set) var raw: [Data] = []

    private var buffer = Data()
    private var payload: Payload?
    /// Header bytes of the last message parsed (never payload bytes).
    private var previous = Data()
    private var previousCommand: UInt16 = 0

    private struct Payload {
        let format: UInt16
        let length: Int
        var remaining: Int
        var data: Data?
        var preview: Data?
    }

    public init(dataCap: Int = 64 << 20) { self.dataCap = dataCap }

    /// Bytes held for an incomplete message (excluding a payload in progress).
    public var bufferedCount: Int { buffer.count }
    /// True while inside a DATA_RESPONSE payload.
    public var inPayload: Bool { payload != nil }

    public mutating func reset() {
        buffer = Data()
        payload = nil
    }

    public mutating func feed(_ data: Data) -> [ClipboardHostMessage] {
        buffer.append(data)
        raw = []
        var out: [ClipboardHostMessage] = []
        var position = buffer.startIndex
        while position < buffer.endIndex {
            if payload != nil {
                // Take the payload out first so its Data is uniquely referenced and grows in place.
                var p = payload!
                payload = nil
                let take = min(p.remaining, buffer.endIndex - position)
                p.data?.append(buffer[position..<(position + take)])
                if var preview = p.preview, preview.count < 10 + Self.rawPayload {
                    preview.append(buffer[position..<(position + min(take, 10 + Self.rawPayload - preview.count))])
                    p.preview = preview
                }
                position += take
                p.remaining -= take
                if p.remaining > 0 { payload = p; break }
                out.append(.dataResponse(format: p.format, length: p.length, data: p.data))
                if keepRaw { raw.append(p.preview ?? Data()) }
                continue
            }
            let rest = buffer[position...]
            guard let (parsed, used) = Self.parseOne(rest, previous: previous, version: version, previousCommand: previousCommand)
            else { break }
            position += used
            switch parsed {
            case .message(let message):
                out.append(message)
                if keepRaw { raw.append(Data(rest.prefix(used))) }
                switch message {
                case .unknown, .malformed:
                    if keepRaw { raw[raw.count - 1] = Data(rest.prefix(Self.headLength)) }
                    // No way to find the next message: drop everything buffered (§2.1 [P]).
                    buffer = Data()
                    previousCommand = 0
                    return out
                case .padding:
                    break
                case .initRequest(_, let high):
                    version = min(maxVersion, high)
                    fallthrough
                default:
                    previous = Data(rest.prefix(min(used, Self.headLength)))
                    previousCommand = UInt16(rest[rest.startIndex]) | UInt16(rest[rest.startIndex + 1]) << 8
                }
            case .responseHeader(let format, let length):
                previous = Data(rest.prefix(10))
                previousCommand = ClipboardWire.Command.dataResponse.rawValue
                if length == 0 {
                    out.append(.dataResponse(format: format, length: 0, data: Data()))
                    if keepRaw { raw.append(previous) }
                } else {
                    let keep = length <= dataCap
                    payload = Payload(format: format, length: length, remaining: length,
                                      data: keep ? Data(capacity: min(length, 1 << 20)) : nil,
                                      preview: keepRaw ? previous : nil)
                }
            }
        }
        buffer = position < buffer.endIndex ? Data(buffer[position...]) : Data()
        return out
    }

    private enum Parsed {
        case message(ClipboardHostMessage)
        case responseHeader(format: UInt16, length: Int)
    }

    /// One message from the start of `bytes`, or nil if more bytes are needed.
    private static func parseOne(_ bytes: Data, previous: Data, version: UInt16, previousCommand: UInt16) -> (Parsed, Int)? {
        var r = ByteReader(bytes)
        func used() -> Int { r.offset - bytes.startIndex }
        func head() -> Data { Data(bytes.prefix(headLength)) }
        let v4 = version >= ClipboardWire.filesVersion
        do {
            let command = try r.u16()
            if command == 0, v4, previousCommand != ClipboardWire.Command.dataRequest.rawValue {
                // At version 4 zeros are skipped only right after a DATA_REQUEST (docs/75 §4.2).
                return (.message(.unknown(command: 0, flags: bytes.count >= 4 ? UInt16(bytes[bytes.startIndex + 2]) | UInt16(bytes[bytes.startIndex + 3]) << 8 : nil,
                                          head: head(), previous: previous)), used())
            }
            if command == 0 {
                // Zero words where a command should start: skip all of them that are here.
                var n = 2
                while bytes.count >= n + 2, bytes[bytes.startIndex + n] == 0, bytes[bytes.startIndex + n + 1] == 0 { n += 2 }
                return (.message(.padding(bytes: n, previous: previous)), n)
            }
            guard let known = ClipboardWire.Command(rawValue: command),
                  [.initRequest, .formatList, .dataRequest, .dataResponse, .formatNames].contains(known) else {
                let flags: UInt16? = bytes.count >= 4 ? UInt16(bytes[bytes.startIndex + 2]) | UInt16(bytes[bytes.startIndex + 3]) << 8 : nil
                return (.message(.unknown(command: command, flags: flags, head: head(), previous: previous)), used())
            }
            let flags = try r.u16()
            func malformed(_ reason: String) -> (Parsed, Int) {
                (.message(.malformed(command: command, flags: flags, reason: reason, head: head(), previous: previous)), used())
            }
            switch known {
            case .initRequest:
                let high = try r.u16()
                return (.message(.initRequest(lowVersion: flags, highVersion: high)), used())
            case .formatNames:
                var entries: [ClipboardFormatName] = []
                while true {
                    let id = try r.u16()
                    let length = try r.u32()
                    guard length <= UInt32(maxNameLength) else { return malformed("name length \(length)") }
                    let name = try r.raw(Int(length))
                    if id == 0 { break }  // terminator entry; its length was read (and its bytes consumed) too
                    entries.append(ClipboardFormatName(id: id, raw: name))
                    guard entries.count <= maxEntries else { return malformed("over \(maxEntries) names") }
                }
                return (.message(.formatNames(flags: flags, entries: entries)), used())
            case .formatList:
                if flags & ClipboardWire.flagNone != 0 { return (.message(.formatList(flags: flags, formats: [])), used()) }
                if flags & ClipboardWire.flagMulti == 0 {
                    let id = try r.u16()
                    _ = try r.u32()
                    return (.message(.formatList(flags: flags, formats: [id])), used())
                }
                var formats: [UInt16] = []
                while true {
                    let id = try r.u16()
                    if id == 0 { break }  // bare u16 terminator, no u32 after it
                    _ = try r.u32()
                    formats.append(id)
                    guard formats.count <= maxEntries else { return malformed("over \(maxEntries) formats") }
                }
                return (.message(.formatList(flags: flags, formats: formats)), used())
            case .dataRequest:
                let format = try r.u16()
                if v4 {
                    // Hypothesis H1 (docs/75 §4.2): u32 index after the format, 10 bytes in all.
                    let index = try r.u32()
                    return (.message(.dataRequest(flags: flags, format: format, index: index)), used())
                }
                _ = try r.u16()
                return (.message(.dataRequest(flags: flags, format: format)), used())
            case .dataResponse:
                if flags & ClipboardWire.flagNone != 0 { return (.message(.dataFailure(flags: flags)), used()) }
                let format = try r.u16()
                let length = try r.u32()
                return (.responseHeader(format: format, length: Int(length)), used())
            case .initReply, .formatNamesReply:
                return (.message(.unknown(command: command, flags: flags, head: head(), previous: previous)), used())
            }
        } catch {
            return nil
        }
    }
}
