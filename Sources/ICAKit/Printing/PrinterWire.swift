import Foundation

/// Wire format of the client printing channel `CTXCPM ` (channel 4, docs/97-printing.md §1–§3).
/// Every packet starts with `u8 command, u8 tag`; replies are `request | 0x80` with the request's tag.
/// There are no length fields: the parser knows each command's layout (§2, §3). All integers LE.
public enum PrinterWire {
    public static let channelName = "CTXCPM "
    public static let channelNumber: UInt8 = 4
    /// Min / max version (§1.1).
    public static let versionLow: UInt8 = 4
    public static let versionHigh: UInt8 = 7
    /// Flow type 1 = ACK (`VirtualFlow_Ack`, §1.2) with MaxWindowSize 62500, WindowSize 4102.
    public static let flowType: UInt8 = 1
    public static let maxWindowSize: UInt16 = 62500
    public static let windowSize: UInt16 = 4102
    /// Capability flags in PDF mode (§1.2 offset 54): 0x8000 only, ASCII strings, no printers.
    public static let pdfModeFlags: UInt16 = 0x8000
    /// The context of the host's PDF printer (§3.3).
    public static let pdfContext: UInt16 = 1
    /// OPEN is accepted only with both bits (§3.3).
    public static let openRequiredFlags: UInt8 = 0x11
    /// GET_INFO flags the reference answers with success for context 1 (§3.6).
    public static let getInfoFlags: UInt32 = 0x0A
    /// Fixed header of an ENUM reply (§3.2: the 19 of `maxSize − 19`).
    public static let enumReplyOverhead = 19

    public enum Command: UInt8, CaseIterable, Sendable {
        case enumPrinters = 0x40
        case open = 0x41
        case close = 0x42
        case write = 0x44
        case getInfo = 0x45
        case connect2 = 0x48
        case queryMetafile = 0x4C
        case setMetafile = 0x4D

        public var name: String {
            switch self {
            case .enumPrinters: return "ENUM"
            case .open: return "OPEN"
            case .close: return "CLOSE"
            case .write: return "WRITE"
            case .getInfo: return "GET_INFO"
            case .connect2: return "CONNECT2"
            case .queryMetafile: return "QUERY_METAFILE"
            case .setMetafile: return "SET_METAFILE"
            }
        }

        public var reply: UInt8 { rawValue | 0x80 }
    }

    /// Result words, `(code << 8) | class`, so the class byte goes first on the wire (§2.1).
    public enum Result {
        public static let success: UInt16 = 0x0000
        /// ENUM: all printers enumerated.
        public static let noMoreEntries: UInt16 = 0x1208
        /// OPEN refused (flags lack 0x11).
        public static let accessDenied: UInt16 = 0x0C07
        /// CLOSE with no data / unknown context; GET_INFO failure.
        public static let invalidHandle: UInt16 = 0x0607
        /// WRITE to an unknown context.
        public static let writeUnknownContext: UInt16 = 0xFF0E
    }

    /// String encoding of OPEN names and METAFILE/ENUM strings; UTF-16LE after CONNECT2 with version ≥ 5 (§3.1).
    public enum Encoding: Sendable, Equatable {
        case ascii, utf16

        /// Bytes of `text`; ASCII mode writes Latin-1 (`?` for anything else).
        public func encode(_ text: String) -> [UInt8] {
            switch self {
            case .ascii: return text.unicodeScalars.map { $0.value < 0x100 ? UInt8($0.value) : 0x3F }
            case .utf16: return text.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            }
        }

        public func decode(_ bytes: Data) -> String {
            switch self {
            case .ascii: return String(bytes.map { Character(Unicode.Scalar($0)) })
            case .utf16:
                let b = [UInt8](bytes)
                let units = stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self)
            }
        }
    }

    /// The metafile driver advertised in the QUERY_METAFILE reply (§3.8).
    public static let metafileFormat = "PDF"
    public static let metafileDriver = "Citrix PDF Universal Printer"
}

/// One SET_METAFILE entry: `u8 len1, u8 len2, u8 x, u8 flags, len1 + len2 bytes` (§3.7).
public struct PrinterMetafileEntry: Equatable, Sendable {
    public var unknown: UInt8
    public var flags: UInt8
    public var first: Data
    public var second: Data

    public init(unknown: UInt8 = 0, flags: UInt8 = 1, first: Data, second: Data) {
        self.unknown = unknown
        self.flags = flags
        self.first = first
        self.second = second
    }
}

/// A host → client command (§3).
public enum PrinterRequestBody: Equatable, Sendable {
    /// 0x48: `u16 a, u16 b, u16 version, u16 flags`; no reply (§3.1).
    case connect2(a: UInt16, b: UInt16, version: UInt16, flags: UInt16)
    /// 0x4C: no payload (§3.8).
    case queryMetafile
    /// 0x4D: `u16 count, u16 size`, then `count` entries (§3.7). `size` is kept as sent.
    case setMetafile(size: UInt16, entries: [PrinterMetafileEntry])
    /// 0x40: `u16 index, u16 maxSize` (§3.2).
    case enumPrinters(index: UInt16, maxSize: UInt16)
    /// 0x41: `u8 nameLen, u8 flags, name` (§3.3). The name's last character is a terminator.
    case open(flags: UInt8, name: Data)
    /// 0x45: `u16 context, u32 flags, u16 size` (§3.6).
    case getInfo(context: UInt16, flags: UInt32, size: UInt16)
    /// 0x44: `u16 context, u16 size, data` (§3.4).
    case write(context: UInt16, data: Data)
    /// 0x42: `u16 context` (§3.5).
    case close(context: UInt16)
    /// A command byte without a handler: only the two header bytes are consumed (§3.10).
    case unknown(UInt8)
}

public struct PrinterRequest: Equatable, Sendable {
    public var tag: UInt8
    public var body: PrinterRequestBody

    public init(tag: UInt8, _ body: PrinterRequestBody) {
        self.tag = tag
        self.body = body
    }

    public var commandByte: UInt8 {
        switch body {
        case .connect2: return PrinterWire.Command.connect2.rawValue
        case .queryMetafile: return PrinterWire.Command.queryMetafile.rawValue
        case .setMetafile: return PrinterWire.Command.setMetafile.rawValue
        case .enumPrinters: return PrinterWire.Command.enumPrinters.rawValue
        case .open: return PrinterWire.Command.open.rawValue
        case .getInfo: return PrinterWire.Command.getInfo.rawValue
        case .write: return PrinterWire.Command.write.rawValue
        case .close: return PrinterWire.Command.close.rawValue
        case .unknown(let byte): return byte
        }
    }

    /// Wire bytes, as the host sends them (tests and the fake host).
    public func encode() -> Data {
        var w = ByteWriter()
        w.u8(commandByte)
        w.u8(tag)
        switch body {
        case let .connect2(a, b, version, flags):
            w.u16(a); w.u16(b); w.u16(version); w.u16(flags)
        case .queryMetafile, .unknown:
            break
        case let .setMetafile(size, entries):
            w.u16(UInt16(entries.count)); w.u16(size)
            for e in entries {
                w.u8(UInt8(e.first.count)); w.u8(UInt8(e.second.count)); w.u8(e.unknown); w.u8(e.flags)
                w.raw(e.first); w.raw(e.second)
            }
        case let .enumPrinters(index, maxSize):
            w.u16(index); w.u16(maxSize)
        case let .open(flags, name):
            w.u8(UInt8(name.count)); w.u8(flags); w.raw(name)
        case let .getInfo(context, flags, size):
            w.u16(context); w.u32(flags); w.u16(size)
        case let .write(context, data):
            w.u16(context); w.u16(UInt16(data.count)); w.raw(data)
        case let .close(context):
            w.u16(context)
        }
        return w.data
    }
}

/// Splits the channel byte stream into commands. A command that is not complete yet waits for more data
/// (the reference rewinds to the command start, §1.4); each parsed command comes with its byte length,
/// which is what the per-command ACK reports.
public struct PrinterStreamParser {
    public struct Item: Equatable, Sendable {
        public var request: PrinterRequest
        /// Bytes this command occupied in the stream (the ACK value, §1.4).
        public var length: Int
    }

    private var buffer = Data()

    public init() {}

    /// Bytes held for an incomplete command.
    public var bufferedCount: Int { buffer.count }

    public mutating func feed(_ data: Data) -> [Item] {
        buffer.append(data)
        var out: [Item] = []
        var position = buffer.startIndex
        while position < buffer.endIndex {
            let rest = buffer[position...]
            guard let (request, used) = Self.parseOne(rest) else { break }
            out.append(Item(request: request, length: used))
            position += used
        }
        buffer = position == buffer.endIndex ? Data() : Data(buffer[position...])
        return out
    }

    public mutating func reset() { buffer = Data() }

    /// One command and its length, or nil if `bytes` holds only part of it.
    static func parseOne(_ bytes: Data) -> (PrinterRequest, Int)? {
        var r = ByteReader(bytes)
        do {
            let command = try r.u8(), tag = try r.u8()
            let body: PrinterRequestBody
            switch PrinterWire.Command(rawValue: command) {
            case .connect2:
                body = .connect2(a: try r.u16(), b: try r.u16(), version: try r.u16(), flags: try r.u16())
            case .queryMetafile:
                body = .queryMetafile
            case .setMetafile:
                let count = try r.u16(), size = try r.u16()
                var entries: [PrinterMetafileEntry] = []
                entries.reserveCapacity(Int(min(count, 64)))
                for _ in 0..<count {
                    let l1 = try r.u8(), l2 = try r.u8(), x = try r.u8(), flags = try r.u8()
                    entries.append(PrinterMetafileEntry(unknown: x, flags: flags, first: try r.raw(Int(l1)), second: try r.raw(Int(l2))))
                }
                body = .setMetafile(size: size, entries: entries)
            case .enumPrinters:
                body = .enumPrinters(index: try r.u16(), maxSize: try r.u16())
            case .open:
                let n = try r.u8(), flags = try r.u8()
                body = .open(flags: flags, name: try r.raw(Int(n)))
            case .getInfo:
                body = .getInfo(context: try r.u16(), flags: try r.u32(), size: try r.u16())
            case .write:
                let context = try r.u16(), n = try r.u16()
                body = .write(context: context, data: try r.raw(Int(n)))
            case .close:
                body = .close(context: try r.u16())
            case nil:
                body = .unknown(command)
            }
            return (PrinterRequest(tag: tag, body), r.offset - bytes.startIndex)
        } catch {
            return nil
        }
    }
}

/// The devmode subset in a GET_INFO reply, 51 bytes (§3.6). Defaults are the reference's, except
/// orientation: portrait (§7, [P]) instead of the reference's landscape.
public struct PrinterDevmode: Equatable, Sendable {
    public var fields: UInt32 = 0x0000_9F03
    public var orientation: UInt16 = 1
    public var paperSize: UInt16 = 9
    public var paperLength: UInt16 = 0
    public var paperWidth: UInt16 = 0
    public var scale: UInt16 = 0
    public var copies: UInt16 = 1
    public var defaultSource: UInt16 = 7
    public var printQuality: UInt16 = 3
    public var color: UInt16 = 1
    public var duplex: UInt16 = 1
    public var yResolution: UInt16 = 0
    public var ttOption: UInt16 = 0
    public var collate: UInt16 = 0

    public static let byteCount = 51

    public init() {}

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.u32(fields)
        for v in [orientation, paperSize, paperLength, paperWidth, scale, copies, defaultSource, printQuality, color, duplex,
                  yResolution, ttOption, collate] { w.u16(v) }
        for _ in 0..<5 { w.u32(0) }
        w.u8(0)
        return [UInt8](w.data)
    }
}

/// Client → host replies (§3).
public enum PrinterReply {
    private static func header(_ command: PrinterWire.Command, _ tag: UInt8) -> ByteWriter {
        var w = ByteWriter()
        w.u8(command.reply)
        w.u8(tag)
        return w
    }

    /// 0xCC: one entry advertising PDF; 45 bytes in ASCII, 78 in UTF-16 (§3.8).
    public static func queryMetafile(tag: UInt8, encoding: PrinterWire.Encoding) -> Data {
        let first = encoding.encode(PrinterWire.metafileFormat + "\0")
        let second = encoding.encode(PrinterWire.metafileDriver + "\0")
        var w = header(.queryMetafile, tag)
        w.u16(PrinterWire.Result.success)
        w.u16(1)
        w.u16(UInt16(4 + first.count + second.count))
        w.u8(UInt8(first.count)); w.u8(UInt8(second.count)); w.u8(0); w.u8(1)
        w.raw(first); w.raw(second)
        return w.data
    }

    /// 0xCD: `CD tt 00 00` (§3.7).
    public static func setMetafile(tag: UInt8) -> Data {
        var w = header(.setMetafile, tag)
        w.u16(PrinterWire.Result.success)
        return w.data
    }

    /// 0xC0 in PDF mode: no printers, `C0 tt 08 12 00 00 00 00` (§3.2).
    public static func enumEmpty(tag: UInt8) -> Data {
        var w = header(.enumPrinters, tag)
        w.u16(PrinterWire.Result.noMoreEntries)
        w.u16(0)
        w.u16(0)
        return w.data
    }

    /// 0xC1: `C1 tt <u16 result> <u16 context>` (§3.3).
    public static func open(tag: UInt8, result: UInt16, context: UInt16) -> Data {
        var w = header(.open, tag)
        w.u16(result)
        w.u16(context)
        return w.data
    }

    /// 0xC4: `C4 tt <u16 result> <u16 size>` (§3.4).
    public static func write(tag: UInt8, result: UInt16, size: UInt16) -> Data {
        var w = header(.write, tag)
        w.u16(result)
        w.u16(size)
        return w.data
    }

    /// 0xC2: `C2 tt <u16 result>` (§3.5).
    public static func close(tag: UInt8, result: UInt16) -> Data {
        var w = header(.close, tag)
        w.u16(result)
        return w.data
    }

    /// 0xC5, 65 bytes: `result, u32 status 0, u32 flags 0x0A, u16 51, devmode` (§3.6).
    public static func getInfo(tag: UInt8, result: UInt16, devmode: PrinterDevmode) -> Data {
        var w = header(.getInfo, tag)
        w.u16(result)
        w.u32(0)
        w.u32(PrinterWire.getInfoFlags)
        w.u16(UInt16(PrinterDevmode.byteCount))
        w.raw(devmode.encode())
        return w.data
    }

    /// Flow-control ACKs for one parsed command of `length` bytes: WD packets `32 <ch> <u16 n>` (§1.4). A
    /// command longer than 65535 bytes (a WRITE of up to 65535 data bytes plus its 6-byte header) is
    /// acknowledged in several packets that add up to `length`.
    public static func acks(channel: UInt8, length: Int) -> [ChannelOutput] {
        var left = max(0, length)
        var out: [ChannelOutput] = []
        repeat {
            let n = UInt16(min(left, 0xFFFF))
            out.append(.wdPacket(type: WDPacketType.virtualAck, body: Data([channel, UInt8(n & 0xff), UInt8(n >> 8)])))
            left -= Int(n)
        } while left > 0
        return out
    }
}
