import Foundation

/// Wire format of HDX webcam redirection over the multimedia channel `CTXMM  ` (channel 18, docs/98b-webcam.md).
/// Every message in both directions starts with `u16 length (header included), u8 command, u8 flags` (§2);
/// several messages may share one VC write and one message may span writes. All integers LE; GUIDs in Windows
/// binary layout.
public enum WebcamWire {
    public static let channelName = "CTXMM  "
    public static let channelNumber: UInt8 = 18
    /// Min 3 / max 0, as the reference sends them (§1.1; "max < min" as CTXCLIP 1/0). 3/3 is only a diagnostic (§13 W6).
    public static let versionLow: UInt8 = 3
    public static let versionHigh: UInt8 = 0
    /// VD data at module offset 48: u16 4996 (WD max virtual write 5000 − the 4-byte header), `84 13` (§1.2).
    public static let maxChannelWrite: UInt16 = 0x1384
    /// Message header size (§2).
    public static let headerSize = 4

    /// Host → client commands (§3.1).
    public enum HostCommand {
        public static let bindRequest: UInt8 = 0x00
        public static let bindCommit: UInt8 = 0x01
        public static let createContext: UInt8 = 0x02
        public static let updateContext: UInt8 = 0x03
        public static let destroyContext: UInt8 = 0x04
        public static let transmit: UInt8 = 0x05
        public static let control: UInt8 = 0x06
    }

    /// Client → host commands (§3.2; the names are ours).
    public enum ClientCommand {
        public static let bindResponse: UInt8 = 0x80
        public static let contextReject: UInt8 = 0x81
        public static let transmit: UInt8 = 0x85
        public static let captureContextResponse: UInt8 = 0x86
    }

    /// CREATE_CONTEXT property types (§5.1).
    public enum Property {
        public static let allocator: UInt32 = 0
        public static let type: UInt32 = 1
        public static let priority: UInt32 = 2
        public static let device: UInt32 = 3
    }

    /// CONTROL types (§6).
    public enum Control {
        public static let play: UInt32 = 0
        public static let pause: UInt32 = 1
        public static let stop: UInt32 = 2
        public static let flush: UInt32 = 3
        public static let endOfStream: UInt32 = 4

        public static func name(_ type: UInt32) -> String {
            switch type {
            case play: return "PLAY"
            case pause: return "PAUSE"
            case stop: return "STOP"
            case flush: return "FLUSH"
            case endOfStream: return "END_OF_STREAM"
            default: return "control \(type)"
            }
        }
    }

    /// Status values (§5.4): E_FAIL after BIND, `0x40001` before BIND and for every client-side device failure.
    public enum Status {
        public static let ok: UInt32 = 0
        public static let failed: UInt32 = 0x8000_4005
        public static let deviceFailure: UInt32 = 0x0004_0001
    }

    /// TRANSMIT fragments carry at most this many data bytes (§7).
    public static let fragmentData = 4000
    /// The [I] max sample buffer size in the 0x86 success: 352·288·3, constant (§5.3).
    public static let maxSampleBuffer: UInt32 = 0x4A400

    /// Encoder bits the host offers in its TYPE properties (§5.1; logged as "VDA Supported Encoder Formats").
    public enum EncoderBits {
        public static let legacy: UInt32 = 1
        public static let h264: UInt32 = 2
    }

    public enum GUID {
        /// MEDIATYPE_Video ('vids').
        public static let mediaTypeVideo: [UInt8] = [0x76, 0x69, 0x64, 0x73, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        /// MEDIASUBTYPE_H264 ('H264').
        public static let subtypeH264: [UInt8] = [0x48, 0x32, 0x36, 0x34, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        /// FORMAT_VideoInfo.
        public static let formatVideoInfo: [UInt8] = [0x80, 0x9F, 0x58, 0x05, 0x56, 0xC3, 0xCE, 0x11, 0xBF, 0x01, 0x00, 0xAA, 0x00, 0x55, 0x59, 0x5A]
        /// D124B2B1-8968-4AE8-B288-FE16EA34B0CE ([I] Theora, the legacy subtype; recognised, never answered).
        public static let subtypeLegacy: [UInt8] = [0xB1, 0xB2, 0x24, 0xD1, 0x68, 0x89, 0xE8, 0x4A, 0xB2, 0x88, 0xFE, 0x16, 0xEA, 0x34, 0xB0, 0xCE]
    }
}

/// The format this client always answers (§5.3): H.264, 352×288, 15 fps, 160 kbit/s. The reference does not
/// negotiate; the host's TYPE format block is only logged.
public struct WebcamFormat: Equatable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var bitRate: Int

    public init(width: Int = 352, height: Int = 288, frameRate: Int = 15, bitRate: Int = 160_000) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = bitRate
    }

    public static let standard = WebcamFormat()

    public var description: String { "H.264 \(width)×\(height) \(frameRate) fps \(bitRate / 1000) kbit/s" }
}

/// One element of a capability, property or control list (§2.1): `u32 length (8 + payload), u32 type, payload`.
public struct WebcamElement: Equatable, Sendable {
    public var type: UInt32
    public var payload: Data

    public init(type: UInt32, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public init(type: UInt32, _ bytes: [UInt8]) { self.init(type: type, payload: Data(bytes)) }

    public var encoded: [UInt8] {
        var w = ByteWriter()
        w.u32(UInt32(8 + payload.count))
        w.u32(type)
        w.raw(payload)
        return [UInt8](w.data)
    }

    /// Little-endian u32 at `offset` of the payload, nil if it is too short.
    func u32(at offset: Int) -> UInt32? {
        guard payload.count >= offset + 4 else { return nil }
        var r = ByteReader(payload.subdata(in: payload.startIndex + offset..<payload.startIndex + offset + 4))
        return try? r.u32()
    }

    func u8(at offset: Int) -> UInt8? {
        guard payload.count > offset else { return nil }
        return payload[payload.startIndex + offset]
    }

    public var description: String {
        "type \(type) [" + payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ") + (payload.count > 16 ? " …" : "") + "]"
    }
}

/// The capture device a CREATE_CONTEXT names (§5.1 DEVICE): the UTF-16 path `<friendly name>@device:pnp:<id>`.
public struct WebcamDeviceProperty: Equatable, Sendable {
    public var flags: UInt16
    public var nameLength: UInt32
    /// The decoded path, trailing NULs stripped.
    public var path: String

    public init(flags: UInt16 = 0, nameLength: UInt32 = 0, path: String) {
        self.flags = flags
        self.nameLength = nameLength
        self.path = path
    }

    static let pnpMarker = "@device:pnp:"

    /// The friendly name (before `@device:pnp:`, or the whole path without it).
    public var friendlyName: String {
        guard let r = path.range(of: Self.pnpMarker) else { return path }
        return String(path[..<r.lowerBound])
    }

    /// The device id after `@device:pnp:`; nil without the marker.
    public var deviceID: String? {
        guard let r = path.range(of: Self.pnpMarker) else { return nil }
        return String(path[r.upperBound...])
    }
}

/// One TYPE property (§5.1): the three GUIDs, cbFormat, and the format block (logged for §13 W12).
public struct WebcamMediaType: Equatable, Sendable {
    public var majorType: [UInt8]
    public var subtype: [UInt8]
    public var formatType: [UInt8]
    public var formatSize: UInt32
    public var formatBlock: Data

    /// The encoder bit this subtype stands for (H.264 = 2, legacy = 1, else 0).
    public var encoderBit: UInt32 {
        if subtype == WebcamWire.GUID.subtypeH264 { return WebcamWire.EncoderBits.h264 }
        if subtype == WebcamWire.GUID.subtypeLegacy { return WebcamWire.EncoderBits.legacy }
        return 0
    }

    /// GUID in registry form, e.g. `34363248-0000-0010-8000-00AA00389B71`.
    public static func guidString(_ g: [UInt8]) -> String {
        guard g.count == 16 else { return g.map { String(format: "%02X", $0) }.joined() }
        let d1 = UInt32(g[0]) | UInt32(g[1]) << 8 | UInt32(g[2]) << 16 | UInt32(g[3]) << 24
        let d2 = UInt16(g[4]) | UInt16(g[5]) << 8, d3 = UInt16(g[6]) | UInt16(g[7]) << 8
        return String(format: "%08X-%04X-%04X-", d1, d2, d3) + g[8..<10].map { String(format: "%02X", $0) }.joined()
            + "-" + g[10..<16].map { String(format: "%02X", $0) }.joined()
    }
}

/// CREATE_CONTEXT_REQUEST (0x02, §5.1).
public struct WebcamContextRequest: Equatable, Sendable {
    public var major: UInt32
    public var minor: UInt32
    public var third: UInt32
    public var properties: [WebcamElement]
    public var mediaTypes: [WebcamMediaType]
    public var device: WebcamDeviceProperty?
    /// Parts that did not parse and were skipped (logged; the request is still answered).
    public var issues: [String] = []

    /// ORed encoder bits of all TYPE properties.
    public var encoderBits: UInt32 { mediaTypes.reduce(0) { $0 | $1.encoderBit } }

    /// A capture-device context the client serves: a DEVICE property and minor ≠ 0 (§5.1 decision).
    public var isDeviceContext: Bool { device != nil && minor != 0 }
}

/// One parsed host message (§3.1).
public enum WebcamHostMessage: Equatable, Sendable {
    case bindRequest([WebcamElement])
    case bindCommit([WebcamElement])
    case createContext(WebcamContextRequest)
    case updateContext(length: Int)
    case destroyContext(major: UInt32, minor: UInt32)
    case transmit(length: Int)
    case control(major: UInt32, minor: UInt32, controls: [UInt32])
    case unknown(command: UInt8, length: Int)
    /// A message whose fields do not fit its length: skipped by L (§2).
    case malformed(command: UInt8, length: Int, reason: String)

    public var name: String {
        switch self {
        case .bindRequest: return "BIND_REQUEST"
        case .bindCommit: return "BIND_COMMIT"
        case .createContext: return "CREATE_CONTEXT"
        case .updateContext: return "UPDATE_CONTEXT"
        case .destroyContext: return "DESTROY_CONTEXT"
        case .transmit: return "TRANSMIT"
        case .control: return "CONTROL"
        case .unknown: return "unknown"
        case .malformed: return "malformed"
        }
    }
}

/// Parsers and builders for single messages (§3–§7).
public enum WebcamMessage {
    enum Failure: Error, CustomStringConvertible {
        case truncated(String), badElement(Int)
        var description: String {
            switch self {
            case .truncated(let what): return "truncated \(what)"
            case .badElement(let length): return "element length \(length)"
            }
        }
    }

    /// Parses `count` elements starting at `offset` of `body` (§2.1). An element whose length is < 8 or runs past
    /// the body ends the list with an error.
    static func elements(_ body: Data, offset: Int, count: Int) throws -> [WebcamElement] {
        var out: [WebcamElement] = []
        var at = body.startIndex + offset
        for _ in 0..<count {
            guard body.endIndex - at >= 8 else { throw Failure.truncated("element header") }
            var r = ByteReader(body.subdata(in: at..<at + 8))
            let length = Int(try r.u32()), type = try r.u32()
            guard length >= 8, length <= body.endIndex - at else { throw Failure.badElement(length) }
            out.append(WebcamElement(type: type, payload: body.subdata(in: at + 8..<at + length)))
            at += length
        }
        return out
    }

    /// The list start: the body-relative list offset, never inside the fixed part (larger values skip the excess).
    static func listStart(_ listOffset: UInt16, fixed: Int) -> Int { max(Int(listOffset), fixed) }

    /// One host message from its full `L`-byte slice (header included).
    public static func parse(_ message: Data) -> WebcamHostMessage {
        let bytes = message.startIndex
        let length = message.count
        guard length >= WebcamWire.headerSize else { return .malformed(command: 0, length: length, reason: "shorter than the header") }
        let command = message[bytes + 2]
        let body = message.subdata(in: bytes + 4..<message.endIndex)
        do {
            var r = ByteReader(body)
            switch command {
            case WebcamWire.HostCommand.bindRequest, WebcamWire.HostCommand.bindCommit:
                let listOffset = try r.u16(), count = Int(try r.u8())
                _ = try r.u8()
                let list = try elements(body, offset: listStart(listOffset, fixed: 4), count: count)
                return command == WebcamWire.HostCommand.bindRequest ? .bindRequest(list) : .bindCommit(list)
            case WebcamWire.HostCommand.createContext:
                return .createContext(try contextRequest(body))
            case WebcamWire.HostCommand.updateContext:
                return .updateContext(length: length)
            case WebcamWire.HostCommand.destroyContext:
                return .destroyContext(major: try r.u32(), minor: try r.u32())
            case WebcamWire.HostCommand.transmit:
                return .transmit(length: length)
            case WebcamWire.HostCommand.control:
                let major = try r.u32(), minor = try r.u32()
                let listOffset = try r.u16(), count = Int(try r.u8())
                _ = try r.u8()
                let list = try elements(body, offset: listStart(listOffset, fixed: 12), count: count)
                return .control(major: major, minor: minor, controls: list.map(\.type))
            default:
                return .unknown(command: command, length: length)
            }
        } catch {
            return .malformed(command: command, length: length, reason: "\(error)")
        }
    }

    static func contextRequest(_ body: Data) throws -> WebcamContextRequest {
        var r = ByteReader(body)
        let major = try r.u32(), minor = try r.u32(), third = try r.u32()
        let listOffset = try r.u16(), count = Int(try r.u8())
        _ = try r.u8()
        // Once the handles are read the host gets an answer whatever follows (a silent drop could leave the host app
        // waiting): a broken element ends the list, a truncated TYPE is skipped (we answer H.264 anyway), a truncated
        // DEVICE still marks a device context, with an empty path. Each case is noted in `issues`. [P]
        var request = WebcamContextRequest(major: major, minor: minor, third: third, properties: [], mediaTypes: [], device: nil)
        do {
            request.properties = try elements(body, offset: listStart(listOffset, fixed: 16), count: count)
        } catch {
            request.properties = []
            var at = listStart(listOffset, fixed: 16)
            for _ in 0..<count {
                guard let one = try? elements(body, offset: at, count: 1).first else { break }
                request.properties.append(one)
                at += 8 + one.payload.count
            }
            request.issues.append("property list cut after \(request.properties.count) of \(count): \(error)")
        }
        for element in request.properties {
            switch element.type {
            case WebcamWire.Property.type:
                do {
                    var p = ByteReader(element.payload)
                    let major = [UInt8](try p.raw(16)), sub = [UInt8](try p.raw(16)), format = [UInt8](try p.raw(16))
                    let size = try p.u32()
                    _ = try p.raw(12)
                    request.mediaTypes.append(WebcamMediaType(majorType: major, subtype: sub, formatType: format, formatSize: size,
                                                              formatBlock: p.rest()))
                } catch {
                    request.issues.append("TYPE property of \(element.payload.count) B truncated: skipped")
                }
            case WebcamWire.Property.device:
                do {
                    var p = ByteReader(element.payload)
                    let subHeader = Int(try p.u16()), flags = try p.u16()
                    let nameLength = try p.u32(), pathLength = Int(try p.u32())
                    // [P] skip a longer sub-header by its excess (the reference skips 12 bytes, §5.1 quirks).
                    if subHeader > 12 { _ = try p.raw(subHeader - 12) }
                    let raw = try p.raw(pathLength)
                    var units: [UInt16] = stride(from: raw.startIndex, to: raw.endIndex - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                    while units.last == 0 { units.removeLast() }
                    request.device = WebcamDeviceProperty(flags: flags, nameLength: nameLength, path: String(decoding: units, as: UTF16.self))
                } catch {
                    request.device = WebcamDeviceProperty(path: "")
                    request.issues.append("DEVICE property of \(element.payload.count) B truncated: device context with an empty path")
                }
            default:
                break
            }
        }
        return request
    }

    private static func header(_ writer: inout ByteWriter, length: Int, command: UInt8, flags: UInt8 = 0) {
        writer.u16(UInt16(length))
        writer.u8(command)
        writer.u8(flags)
    }

    // MARK: Client messages

    /// The answer elements for a host capability list (§4.1): type 0 echoes the host's u32, type 1 is u32 1, types
    /// 3/4/5/7 are u8 0, type 6 echoes its u8 plus a zero pad; type 2 and unknown types are dropped. Host order, no
    /// padding (odd element lengths are normal).
    public static func bindAnswers(_ host: [WebcamElement]) -> [WebcamElement] {
        host.compactMap { e in
            switch e.type {
            case 0: return WebcamElement(type: 0, [UInt8](le32(e.u32(at: 0) ?? 0)))
            case 1: return WebcamElement(type: 1, le32(1))
            case 3, 4, 5, 7: return WebcamElement(type: e.type, [0])
            case 6: return WebcamElement(type: 6, [e.u8(at: 0) ?? 0, 0])
            default: return nil
            }
        }
    }

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }

    /// BIND_RESPONSE 0x80 (§4.2): `len 80 00`, list offset 4, n, 0, then the answers.
    public static func bindResponse(answers: [WebcamElement]) -> [UInt8] {
        let list = answers.flatMap(\.encoded)
        var w = ByteWriter()
        header(&w, length: 8 + list.count, command: WebcamWire.ClientCommand.bindResponse)
        w.u16(4)
        w.u8(UInt8(answers.count))
        w.u8(0)
        w.raw(list)
        return [UInt8](w.data)
    }

    /// CONTEXT_REJECT 0x81 for a non-device context, 20 bytes (§5.4).
    public static func contextReject(major: UInt32, minor: UInt32, status: UInt32) -> [UInt8] {
        var w = ByteWriter()
        header(&w, length: 20, command: WebcamWire.ClientCommand.contextReject)
        w.u32(major)
        w.u32(minor)
        w.u32(status)
        w.u32(0)
        return [UInt8](w.data)
    }

    /// CAPTURE_CONTEXT_RESPONSE 0x86 error, 24 bytes, empty list (§5.4).
    public static func captureContextError(major: UInt32, minor: UInt32, status: UInt32 = WebcamWire.Status.deviceFailure) -> [UInt8] {
        var w = ByteWriter()
        header(&w, length: 24, command: WebcamWire.ClientCommand.captureContextResponse)
        w.u32(major)
        w.u32(minor)
        w.u32(status)
        w.u32(0)
        w.u16(24)
        w.u8(0)
        w.u8(0)
        return [UInt8](w.data)
    }

    /// The 88-byte format block ([I] VIDEOINFOHEADER, §5.3). biCompression is the reversed I420 FOURCC `30 32 34 49`,
    /// exactly as the reference writes it.
    public static func formatBlock(_ f: WebcamFormat) -> [UInt8] {
        var w = ByteWriter()
        w.raw([UInt8](repeating: 0, count: 32))  // rcSource, rcTarget
        w.u32(UInt32(f.bitRate))
        w.u32(0)                                  // dwBitErrorRate
        w.raw([UInt8](repeating: 0, count: 8))   // AvgTimePerFrame
        w.u32(40)                                 // biSize
        w.u32(UInt32(f.width))
        w.u32(UInt32(f.height))
        w.u16(1)                                  // biPlanes
        w.u16(12)                                 // biBitCount
        w.raw([0x30, 0x32, 0x34, 0x49])           // biCompression "024I"
        w.u32(UInt32(f.width * f.height * 12 / 8))
        w.raw([UInt8](repeating: 0, count: 16))  // biXPels, biYPels, biClrUsed, biClrImportant
        return [UInt8](w.data)
    }

    /// CAPTURE_CONTEXT_RESPONSE 0x86 success, 208 bytes (§5.3): status 0, buffer 0x4A400, the message-relative list
    /// offset 24, an ALLOCATOR {8, 0x4A400, 1, 0} and the H.264 TYPE with its format block.
    public static func captureContextSuccess(major: UInt32, minor: UInt32, format: WebcamFormat = .standard) -> [UInt8] {
        var allocator = ByteWriter()
        allocator.u32(8)
        allocator.u32(WebcamWire.maxSampleBuffer)
        allocator.u32(1)
        allocator.u32(0)
        let block = formatBlock(format)
        var type = ByteWriter()
        type.raw(WebcamWire.GUID.mediaTypeVideo)
        type.raw(WebcamWire.GUID.subtypeH264)
        type.raw(WebcamWire.GUID.formatVideoInfo)
        type.u32(UInt32(block.count))
        type.u32(0)
        type.u32(0)
        type.u32(0)
        type.raw(block)
        let list = WebcamElement(type: WebcamWire.Property.allocator, payload: allocator.data).encoded
            + WebcamElement(type: WebcamWire.Property.type, payload: type.data).encoded
        var w = ByteWriter()
        header(&w, length: 24 + list.count, command: WebcamWire.ClientCommand.captureContextResponse)
        w.u32(major)
        w.u32(minor)
        w.u32(WebcamWire.Status.ok)
        w.u32(WebcamWire.maxSampleBuffer)
        w.u16(24)
        w.u8(2)
        w.u8(0)
        w.raw(list)
        return [UInt8](w.data)
    }

    /// One encoded frame as TRANSMIT 0x85 fragments of ≤ 4000 data bytes (§7): the first carries the handles, the
    /// sample element (length 8 + 32 + whole sample, 7 zero u32: no timestamps, no flags) and the sample length; the
    /// rest only `u16 (4 + n), 85, more`. `more` is 1 on every fragment but the last.
    public static func transmit(major: UInt32, minor: UInt32, sample: Data, fragmentSize: Int = WebcamWire.fragmentData) -> [[UInt8]] {
        let total = sample.count
        var out: [[UInt8]] = []
        var at = sample.startIndex
        repeat {
            let n = min(fragmentSize, sample.endIndex - at)
            let more: UInt8 = at + n < sample.endIndex ? 1 : 0
            var w = ByteWriter()
            if out.isEmpty {
                header(&w, length: 4 + 52 + n, command: WebcamWire.ClientCommand.transmit, flags: more)
                w.u32(major)
                w.u32(minor)
                w.u16(12)
                w.u8(1)
                w.u8(0)
                w.u32(UInt32(8 + 32 + total))
                w.u32(0)
                w.raw([UInt8](repeating: 0, count: 28))
                w.u32(UInt32(total))
            } else {
                header(&w, length: 4 + n, command: WebcamWire.ClientCommand.transmit, flags: more)
            }
            w.raw(sample.subdata(in: at..<at + n))
            out.append([UInt8](w.data))
            at += n
        } while at < sample.endIndex
        return out
    }
}

/// Reassembles length-prefixed messages from VC writes (§2): split and merged writes, each message handed over as
/// its own L-byte slice. L < 4 is a protocol error: the rest of the buffer is dropped.
public struct WebcamStreamParser {
    private var buffer = Data()
    public private(set) var protocolErrors = 0

    public init() {}

    public var buffered: Int { buffer.count }

    public mutating func reset() { buffer = Data() }

    /// Complete messages (header included) in order; `onError` gets a line per dropped buffer.
    public mutating func feed(_ data: Data, onError: (String) -> Void = { _ in }) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= WebcamWire.headerSize {
            let length = Int(buffer[at]) | Int(buffer[at + 1]) << 8
            guard length >= WebcamWire.headerSize else {
                protocolErrors += 1
                onError("message length \(length) < 4 at command 0x\(String(format: "%02x", buffer[at + 2])): \(buffer.endIndex - at) B dropped")
                at = buffer.endIndex
                break
            }
            guard buffer.endIndex - at >= length else { break }
            out.append(buffer.subdata(in: at..<at + length))
            at += length
        }
        buffer = at == buffer.endIndex ? Data() : buffer.subdata(in: at..<buffer.endIndex)
        return out
    }
}
