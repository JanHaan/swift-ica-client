import Foundation

/// Discovery engine for `CTXGDT` (docs/76-gdt.md §6): announces the channel, records every host write, and by
/// default answers nothing. Replies are added as `Responder`s (iteration 2 onwards); `ICA_GDT_ECHO_INIT` is the
/// first one.
///
/// - Module: the generic 48-byte VD (docs/30 §5.5), versions `Config.versionLow…versionHigh` (1…1), host name
///   "ICA", flow type 0, no VD data; channel 29, bind entry `CTXGDT\0 1D 00` from the WD module's table.
/// - Every host write goes to `onEvent(.hostWrite)` (log it with `GDTHexLog`) and into `statistics`.
///
/// Call everything on the session queue; `onEvent` is called there.
public final class GDTEngine: VirtualChannelEngine, VirtualChannelModule {
    /// How the optional init answer is built from the host's first write (docs/76 §6.2) [H].
    public enum InitReply: Equatable, Sendable {
        /// The host's bytes unchanged.
        case echo
        /// The host's bytes with the byte at `offset` incremented (the INIT → INIT_REPLY habit of CTXCLIP and
        /// CTXCTL, where the reply's command is the request's + 1).
        case incrementByte(offset: Int)
        /// Fixed bytes.
        case literal([UInt8])

        /// `ICA_GDT_ECHO_INIT`: `1`/`echo` → `.echo`, `inc` → `.incrementByte(0)`, `inc@N` → `.incrementByte(N)`,
        /// `hex:01 00 …` → `.literal`. Anything else (or unset): nil.
        public init?(environment value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != "0" else { return nil }
            switch value.lowercased() {
            case "1", "echo": self = .echo
            case "inc": self = .incrementByte(offset: 0)
            default:
                if value.lowercased().hasPrefix("inc@"), let n = Int(value.dropFirst(4)), n >= 0 {
                    self = .incrementByte(offset: n)
                } else if value.lowercased().hasPrefix("hex:"), let bytes = GDTEngine.parseHex(String(value.dropFirst(4))), !bytes.isEmpty {
                    self = .literal(bytes)
                } else {
                    return nil
                }
            }
        }

        func reply(to bytes: [UInt8]) -> [UInt8] {
            switch self {
            case .echo: return bytes
            case .incrementByte(let offset):
                var out = bytes
                if offset < out.count { out[offset] &+= 1 }
                return out
            case .literal(let bytes): return bytes
            }
        }
    }

    public struct Config: Sendable {
        public var versionLow = GDTWire.versionLow
        public var versionHigh = GDTWire.versionHigh
        /// VD-specific data after the 48-byte common part (docs/30 §5.5); empty by default. Variant V1 puts the
        /// stock client's "maxPacketSize 4999" there as u16 `87 13`, the way CTXMM carries 4996 (docs/98b §1.3).
        public var vdData: [UInt8] = []
        /// Answer the host's first write if it looks like an init (≤ `initMaxSize` bytes, before we sent anything).
        public var initReply: InitReply?
        public var initMaxSize = 128
        /// Payload bytes per write in the hex log.
        public var logLimit = GDTHexLog.defaultLimit

        public init() {}

        /// `ICA_GDT=1` enables the channel; `ICA_GDT_VERSION=N` sets min = max = N, `=L-H` min L and max H;
        /// `ICA_GDT_VDDATA=<hex>` the VD data; `ICA_GDT_ECHO_INIT` see `InitReply`. Nil without `ICA_GDT=1` (no
        /// module, no bind entry: default behaviour).
        public static func fromEnvironment(_ env: [String: String]) -> Config? {
            guard env["ICA_GDT"] == "1" else { return nil }
            var c = Config()
            if let text = env["ICA_GDT_VERSION"] {
                let parts = text.split(separator: "-").map { UInt8($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 1, let v = parts[0] { c.versionLow = v; c.versionHigh = v }
                if parts.count == 2, let low = parts[0], let high = parts[1] { c.versionLow = low; c.versionHigh = high }
            }
            if let text = env["ICA_GDT_VDDATA"], let bytes = GDTEngine.parseHex(text) { c.vdData = bytes }
            c.initReply = InitReply(environment: env["ICA_GDT_ECHO_INIT"])
            return c
        }
    }

    public enum Event: CustomStringConvertible {
        /// The module as handed to the WD.
        case module([UInt8])
        case hostWrite(GDTHostWrite)
        /// One of our writes went out (a responder, `ICA_GDT_ECHO_INIT` or `send`).
        case sent(GDTHostWrite, reason: String)
        case log(String)

        public var description: String {
            switch self {
            case .module(let bytes): return "CTXGDT module \(bytes.count) B: " + GDTHexLog.hex(bytes)
            case .hostWrite(let w): return GDTHexLog.line(w)
            case .sent(let w, let reason): return GDTHexLog.line(w, direction: "→") + " (\(reason))"
            case .log(let text): return text
            }
        }
    }

    /// A reply rule: given a host write and everything received so far, the bytes to send (nil: not mine).
    /// The first responder that returns bytes wins; its `name` goes into the log.
    public struct Responder {
        public var name: String
        public var reply: (_ write: GDTHostWrite, _ history: [GDTHostWrite]) -> [UInt8]?
        public init(name: String, reply: @escaping (_ write: GDTHostWrite, _ history: [GDTHostWrite]) -> [UInt8]?) {
            self.name = name
            self.reply = reply
        }
    }

    public let channelName = GDTWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: (Event) -> Void = { _ in }
    public let config: Config
    /// Tried in order for every host write. Set before `start`; the init reply (if configured) is the first.
    public var responders: [Responder] = []
    public private(set) var statistics = GDTStatistics()
    /// Every host write, in order (discovery runs are short; capped at `historyCap`).
    public private(set) var history: [GDTHostWrite] = []
    public static let historyCap = 4096
    public private(set) var sentCount = 0
    public private(set) var moduleBytes: [UInt8]?

    private let start: Date
    private let now: () -> Date
    private var pendingWDType: UInt8?
    private var hostIndex = 0

    public init(config: Config = Config(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
        start = now()
        if let initReply = config.initReply {
            let limit = config.initMaxSize
            responders.append(Responder(name: "init reply") { [unowned self] write, _ in
                guard write.index == 1, self.sentCount == 0, !write.bytes.isEmpty, write.bytes.count <= limit else { return nil }
                return initReply.reply(to: write.bytes)
            })
        }
    }

    public func module(channel: UInt8, date: Date) -> [UInt8] {
        let identity = WDModuleIdentity(moduleClass: .vd, versionLow: config.versionLow, versionHigh: config.versionHigh,
                                        name: "", hostName: "ICA")
        var w = WDModules.vdHeader(identity, channel: channel, date: date)
        w.raw(config.vdData)
        let bytes = w.bytes()
        moduleBytes = bytes
        onEvent(.module(bytes))
        return bytes
    }

    /// The WD packet type of the next `receive` (the session reports it just before; for the log only).
    public func noteWDPacketType(_ type: UInt8) { pendingWDType = type }

    public func receive(_ data: Data) {
        hostIndex += 1
        let write = GDTHostWrite(index: hostIndex, elapsed: now().timeIntervalSince(start), wdType: pendingWDType, bytes: [UInt8](data))
        pendingWDType = nil
        statistics.add(write.bytes)
        if history.count < Self.historyCap { history.append(write) }
        onEvent(.hostWrite(write))
        for responder in responders {
            if let reply = responder.reply(write, history) {
                send(reply, reason: "\(responder.name) to #\(write.index)")
                break
            }
        }
    }

    /// Writes raw bytes on CTXGDT (discovery: a hello, or a hand-made reply).
    public func send(_ bytes: [UInt8], reason: String = "send") {
        guard let output else { return onEvent(.log("CTXGDT: no output yet, \(bytes.count) B not sent (\(reason))")) }
        sentCount += 1
        onEvent(.sent(GDTHostWrite(index: sentCount, elapsed: now().timeIntervalSince(start), wdType: nil, bytes: bytes), reason: reason))
        output(.channel(Data(bytes)))
    }

    /// `01 00 2c 00`, `01002c00` or `0x01,0x00`: hex bytes, separators ignored. Nil on an odd digit count or a non-hex character.
    public static func parseHex(_ text: String) -> [UInt8]? {
        let digits = text.replacingOccurrences(of: "0x", with: "").filter { !" ,:;\t\n-".contains($0) }
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            guard let b = UInt8(digits[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
