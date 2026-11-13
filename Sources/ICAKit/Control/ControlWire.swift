import Foundation

/// Wire format of the control virtual channel `CTXCTL ` (docs/55-session-sharing.md §4–§8). Every message in both
/// directions is `u16 L | u8 command | u8 0 | L payload bytes` (§4.2); a message may span VC writes and one write may
/// carry several messages. All integers LE; strings UTF-16LE.
public enum ControlWire {
    public static let channelName = "CTXCTL "
    /// VD versions 1…2, host module name "ICA" (§4.1).
    public static let versionLow: UInt8 = 1
    public static let versionHigh: UInt8 = 2
    /// The 4-byte message header (§4.2).
    public static let headerSize = 4

    /// Commands (§4.3; the names are ours).
    public enum Command {
        public static let capabilityRequest: UInt8 = 0x00
        public static let capabilityResponse: UInt8 = 0x01
        public static let capabilityCommit: UInt8 = 0x02
        public static let launchRequest: UInt8 = 0x03
        public static let launchResponse: UInt8 = 0x04
        public static let urlRedirection: UInt8 = 0x09
        public static let pnpEventResponse: UInt8 = 0x0C
        public static let sessionEvent: UInt8 = 0x0F
    }

    /// Capability ids the client answers (§5.2); 7 (webcam PnP) is never sent.
    public enum Capability {
        public static let version1: UInt16 = 1
        public static let version2: UInt16 = 2
        public static let commandLineLimit: UInt16 = 3
        public static let launchData: UInt16 = 5
        public static let sessionEvents: UInt16 = 6
        public static let pnpWebcam: UInt16 = 7
        public static let urlRedirection: UInt16 = 0x0A
    }

    /// Launch statuses (§7.2). 5 has no name and the reference ignores it.
    public static func statusName(_ status: UInt32) -> String {
        switch status {
        case 0: return "SUCCESS"
        case 1: return "INCORRECT_PARAMETER"
        case 2: return "PERMISSION_VIOLATION"
        case 3: return "PERMISSION_MISMATCH"
        case 4: return "BAD_APP_CONFIG"
        case 6: return "LAUNCH_ERROR"
        case 7: return "BAD_COMMAND_LINE"
        case 8: return "NOT_LOGGED_IN"
        default: return "status \(status)"
        }
    }

    /// The u32 status of a 0x04 payload (§7.1), nil if shorter than 4 bytes.
    public static func launchStatus(_ payload: [UInt8]) -> UInt32? { payload.count >= 4 ? u32(payload, 0) : nil }

    /// Status 5: the reference neither names nor dequeues it (§7.2).
    public static let ignoredStatus: UInt32 = 5

    /// One framed message: header plus payload.
    public static func message(_ command: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff), command, 0] + payload
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i + 1 < b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : 0 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        i + 3 < b.count ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 : 0
    }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> UInt32($0 * 8)) & 0xff) } }
    static func utf16z(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [0, 0] }
}

/// Reassembles `CTXCTL` messages from VC writes (§4.2): split and merged writes both work; the payload is handed
/// over once all L bytes are there.
struct ControlStreamParser {
    private var buffer: [UInt8] = []

    struct Message: Equatable {
        var command: UInt8
        var payload: [UInt8]
    }

    var pendingBytes: Int { buffer.count }

    mutating func feed(_ data: [UInt8]) -> [Message] {
        buffer += data
        var out: [Message] = []
        var start = 0
        while buffer.count - start >= ControlWire.headerSize {
            let length = Int(ControlWire.u16(buffer, start))
            guard buffer.count - start >= ControlWire.headerSize + length else { break }
            let body = start + ControlWire.headerSize
            out.append(Message(command: buffer[start + 2], payload: Array(buffer[body..<(body + length)])))
            start = body + length
        }
        if start > 0 { buffer.removeFirst(start) }
        return out
    }
}

/// One capability of a 0x00/0x02 payload (§5.1): id, the host's len byte (header included) and its data.
public struct ControlCapability: Equatable, Sendable, CustomStringConvertible {
    public var id: UInt16
    public var length: UInt8
    public var data: [UInt8]

    public init(id: UInt16, length: UInt8, data: [UInt8]) {
        self.id = id
        self.length = length
        self.data = data
    }

    public var description: String {
        String(format: "0x%02X(len %d", id, length) + (data.isEmpty ? ")" : ": " + data.map { String(format: "%02X", $0) }.joined(separator: " ") + ")")
    }

    /// Parses `u16 offset | u8 count | …` and the chained capabilities (§5.1). Stops at the first one that does not
    /// fit (a short or zero len would loop or overrun).
    public static func parseList(_ payload: [UInt8]) -> [ControlCapability] {
        guard payload.count >= 3 else { return [] }
        var position = Int(ControlWire.u16(payload, 0))
        let count = Int(payload[2])
        var out: [ControlCapability] = []
        for _ in 0..<count {
            guard position + 4 <= payload.count else { break }
            let length = Int(payload[position + 2])
            guard length >= 4, position + length <= payload.count else { break }
            out.append(ControlCapability(id: ControlWire.u16(payload, position), length: UInt8(length),
                                         data: Array(payload[(position + 4)..<(position + length)])))
            position += length
        }
        return out
    }

    /// The client capability response payload (§5.2): `u16 4 | u8 n | u8 0` and one answer per known host
    /// capability, each with the host's len byte; its data padded or cut to that length.
    /// `hasLaunchData`: our own app holds a command line (cap 5). `echo`: otherwise unanswered ids whose host data is
    /// sent back unchanged (discovery, docs/76 §7.2 V7: cap 9; §7.4 V13: also 7); empty by default.
    public static func response(to host: [ControlCapability], hasLaunchData: Bool,
                                echo: Set<UInt16> = []) -> (payload: [UInt8], answered: [ControlCapability]) {
        var answered: [ControlCapability] = []
        for cap in host {
            var data: [UInt8]
            switch cap.id {
            case ControlWire.Capability.version1: data = [0x01, 0, 0, 0]
            case ControlWire.Capability.version2: data = [0x02, 0, 0, 0, 0, 0, 0, 0]
            case ControlWire.Capability.commandLineLimit:
                let limit = ControlWire.u16(cap.data, 0) & ~1
                guard limit != 0 else { continue }
                data = ControlWire.le16(limit) + [0, 0] + (cap.length == 10 ? [0, 0] : [])
            case ControlWire.Capability.launchData: data = [hasLaunchData ? 1 : 0, 0, 0, 0]
            case ControlWire.Capability.sessionEvents: data = ControlWire.le32(ControlWire.u32(cap.data, 0) == 1 ? 1 : 0)
            case ControlWire.Capability.urlRedirection: data = []
            case let id where echo.contains(id): data = cap.data   // also 7 (webcam PnP) when listed (V13)
            default: continue   // 7 (webcam PnP) and unknown ids are not echoed unless listed
            }
            let size = max(0, Int(cap.length) - 4)
            if data.count < size { data += [UInt8](repeating: 0, count: size - data.count) }
            answered.append(ControlCapability(id: cap.id, length: cap.length, data: Array(data.prefix(size))))
        }
        var payload = ControlWire.le16(4) + [UInt8(answered.count), 0]
        for cap in answered { payload += ControlWire.le16(cap.id) + [cap.length, 0] + cap.data }
        return (payload, answered)
    }

    /// Cap 3's limit (bytes, & ~1), or nil if absent.
    public static func commandLineLimit(_ caps: [ControlCapability]) -> Int? {
        caps.first { $0.id == ControlWire.Capability.commandLineLimit }.map { Int(ControlWire.u16($0.data, 0) & ~1) }
    }
}

/// A program to start in the running session (§6.1): the published app and its command line, from an ICA file.
/// Nothing else of the file is used (no ticket, no LaunchReference).
public struct ControlLaunch: Equatable, Sendable {
    /// `InitialProgram` as in the ICA file, e.g. `#Calculator`.
    public var initialProgram: String
    public var commandLine: String

    public init(initialProgram: String, commandLine: String = "") {
        self.initialProgram = initialProgram
        self.commandLine = commandLine
    }

    public init(ica: ICAFile) {
        self.init(initialProgram: ica["InitialProgram"] ?? "", commandLine: Self.commandLine(ica))
    }

    /// `LongCommandLine` + `LongCommandLine000`, `001`, … up to the first missing index (max 999), each piece longer
    /// than 2 characters and wrapped in `"` without those quotes; else `cmdLine`; else empty (§6.1).
    public static func commandLine(_ ica: ICAFile) -> String {
        if let first = ica["LongCommandLine"] {
            var pieces = [first]
            for i in 0...999 {
                guard let piece = ica[String(format: "LongCommandLine%03d", i)] else { break }
                pieces.append(piece)
            }
            return pieces.map(unquoted).joined()
        }
        return ica["cmdLine"] ?? ""
    }

    static func unquoted(_ piece: String) -> String {
        piece.count > 2 && piece.hasPrefix("\"") && piece.hasSuffix("\"") ? String(piece.dropFirst().dropLast()) : piece
    }

    /// The application string as sent (§6.2), without its NUL: `#Name` → `#"Name""`. nil if `InitialProgram` does not
    /// start with `#` (the reference then drops the launch silently).
    public var applicationString: String? {
        guard initialProgram.hasPrefix("#") else { return nil }
        var name = String(initialProgram.dropFirst())
        if !name.hasPrefix("\"") { name = "\"" + name }
        if !name.hasSuffix("\"") { name += "\"" }
        return "#" + name + "\""
    }

    /// The command line after the limit (§6.3): with `2 × chars + 2 > limit` cut to `(limit − 2) / 2` characters
    /// (UTF-16 units); no cap 3 (limit 0) leaves it empty.
    public func limitedCommandLine(limit: Int) -> String {
        let units = Array(commandLine.utf16)
        guard !units.isEmpty, 2 * units.count + 2 > limit else { return commandLine }
        let keep = max(0, (limit - 2) / 2)
        return String(decoding: units.prefix(keep), as: UTF16.self)
    }

    /// The whole 0x03 message (§6.4), header included; nil without a valid application string.
    public func request(commandLineLimit limit: Int) -> [UInt8]? {
        guard let app = applicationString else { return nil }
        let a = ControlWire.utf16z(app)
        let c = ControlWire.utf16z(limitedCommandLine(limit: limit))
        var payload = ControlWire.le16(12) + ControlWire.le16(UInt16(12 + a.count)) + [0, 0, 0, 0] + ControlWire.le32(0)
        payload += a + c
        return ControlWire.message(ControlWire.Command.launchRequest, payload)
    }
}
