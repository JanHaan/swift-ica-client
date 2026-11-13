import Foundation

/// The virtual channels the stock Mac client announces to this host, from its own log (D57 policy: names, channel
/// numbers and versions only; "Virtual Channel X ch:N Vl:h loaded" and "WdOpenVirtualChannel open vc name X,
/// channel id: N") [B]. For docs/76 §7.4 V12 only: announce the same set with the same numbers.
public enum StockChannels {
    public struct Entry: Sendable, Equatable {
        /// Wire name, 7 bytes: space padded or NUL terminated as the stock log shows it.
        public var name: String
        public var channel: UInt8
        /// nil: no version in the log (built-in channels); a stub then announces 1…1 [H].
        public var versionLow: UInt8?
        public var versionHigh: UInt8?
    }

    private static func e(_ name: String, _ channel: UInt8, _ low: UInt8? = nil, _ high: UInt8? = nil) -> Entry {
        Entry(name: name, channel: channel, versionLow: low, versionHigh: high)
    }

    /// In channel order. The trailing space / NUL follows the log ("CTXCAM ," vs "CTXMOB,").
    public static let all: [Entry] = [
        e("ctxdt\0\0", 3), e("CTXCPM ", 4, 4, 7), e("CTXTWI\0", 7), e("CTXTW  ", 9), e("CTXCDM ", 10, 1, 9),
        e("CTXTUI\0", 12), e("CTXGUSB", 13, 1, 1), e("CTXCAM ", 14, 1, 4), e("CTXEUEM", 15, 1, 1), e("CTXCTL ", 16, 1, 2),
        e("CTXCLIP", 17, 0, 3), e("CTXMM  ", 18, 1, 2), e("CTXIME ", 19, 2, 2), e("CTXSCRD", 20, 1, 1), e("CTXNSAP", 21, 1, 1),
        e("CTXMTOP", 22, 1, 1), e("CTXMOB\0", 23, 0, 1), e("CTXFIDO", 24, 1, 1), e("CTXAPPP", 25, 1, 1), e("CTXCSB ", 26, 1, 2),
        e("CTXPFWD", 27, 1, 2), e("CTXTLMT", 28, 1, 1), e("CTXGDT\0", 29, 1, 1), e("CTXMTCH", 30, 0, 1), e("MSTEAMS", 31),
        e("MSTEAM1", 32), e("MSTEAM2", 33),
    ]

    /// Channels we have an engine for (their modules come from the engine, versions included).
    public static let engineBacked: Set<String> = ["CTXTW  ", "CTXTWI\0", "CTXCLIP", "CTXCDM ", "CTXCPM ", "CTXCAM ", "CTXMM  ",
                                                   "CTXCTL ", "CTXGDT\0"]

    /// Module-header names and versions of the stock client's INIT_RESPONSE ("SendAllInitResponse: Module: <NAME>,
    /// (ICA) class 3, ver A-B") [B], keyed by `WDModuleOverride.key`. The name→VC pairing is ours, by the matching
    /// versions of the "loaded" lines [H]; CTXBCR → CTXCSB (browser content redirection) is the least certain. Names
    /// longer than 12 bytes are cut by the module header (docs/30 §5.2).
    public static let moduleNames: [String: WDModuleOverride] = [
        "CTXGDT": .init(name: "ClientGDT", versionLow: 1, versionHigh: 1),
        "CTXCDM": .init(name: "ClientDrive", versionLow: 1, versionHigh: 9),
        "CTXCLIP": .init(name: "Clipboard", versionLow: 0, versionHigh: 3),
        "CTXCTL": .init(name: "ControlChannel", versionLow: 1, versionHigh: 2),
        "CTXCAM": .init(name: "ClientAudio", versionLow: 1, versionHigh: 4),
        "CTXIME": .init(name: "IMEChannel", versionLow: 2, versionHigh: 2),
        "CTXMTCH": .init(name: "MultiTouch", versionLow: 0, versionHigh: 1),
        "CTXEUEM": .init(name: "UserExperience", versionLow: 1, versionHigh: 1),
        "CTXSCRD": .init(name: "ClientSCardV2", versionLow: 1, versionHigh: 1),
        "CTXFIDO": .init(name: "ClientFido2", versionLow: 1, versionHigh: 1),
        "CTXAPPP": .init(name: "ClientAppP", versionLow: 1, versionHigh: 1),
        "CTXMOB": .init(name: "ClientMobile", versionLow: 0, versionHigh: 1),
        "CTXTLMT": .init(name: "ClientCTXTLMT", versionLow: 1, versionHigh: 1),
        "CTXMTOP": .init(name: "ICAClientMTOP", versionLow: 1, versionHigh: 1),
        "CTXNSAP": .init(name: "NetScalerAppFlow", versionLow: 1, versionHigh: 1),
        "CTXCSB": .init(name: "CTXBCR", versionLow: 1, versionHigh: 2),
        "CTXPFWD": .init(name: "CTXPFWD", versionLow: 1, versionHigh: 2),
    ]

    /// Name → stock channel number, for `WinstationDriver.Configuration.channelOverrides`.
    public static var channelMap: [String: UInt8] { Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.channel) }) }

    /// Stub engines for every stock channel without an engine of ours.
    public static func stubs() -> [StubChannelEngine] {
        all.filter { !engineBacked.contains($0.name) }.map {
            StubChannelEngine(name: $0.name, versionLow: $0.versionLow ?? 1, versionHigh: $0.versionHigh ?? 1)
        }
    }
}

/// A channel that is only announced (docs/76 §7.4 V11/V12): the generic 48-byte VD module with the given versions,
/// host name "ICA", no flow control, no VD data. Host writes are counted and the first ones logged; nothing is
/// ever sent. Session queue only.
public final class StubChannelEngine: VirtualChannelEngine, VirtualChannelModule {
    public let channelName: String
    public var output: ((ChannelOutput) -> Void)?
    public let versionLow: UInt8
    public let versionHigh: UInt8
    public var onEvent: (String) -> Void = { _ in }
    public private(set) var hostWrites = 0
    public private(set) var hostBytes = 0
    /// How many host writes are logged (head bytes in hex).
    public var logFirst = 3

    public init(name: String, versionLow: UInt8 = 1, versionHigh: UInt8 = 1) {
        channelName = name
        self.versionLow = versionLow
        self.versionHigh = versionHigh
    }

    /// The name without NUL / space padding, for logs.
    public var label: String { channelName.trimmingCharacters(in: CharacterSet(charactersIn: " \0")) }

    public func module(channel: UInt8, date: Date) -> [UInt8] {
        let identity = WDModuleIdentity(moduleClass: .vd, versionLow: versionLow, versionHigh: versionHigh, name: "", hostName: "ICA")
        return WDModules.vdHeader(identity, channel: channel, date: date).bytes()
    }

    public func receive(_ data: Data) {
        hostWrites += 1
        hostBytes += data.count
        if hostWrites <= logFirst {
            onEvent("← \(label) #\(hostWrites) \(data.count) B: " + GDTHexLog.hex(data.prefix(32)) + (data.count > 32 ? " …" : ""))
        }
    }

    /// `CTXFILE` or `CTXFILE:1-2` (versions) → a stub; nil if malformed. The name is padded to 7 with spaces.
    public static func parse(_ text: String) -> StubChannelEngine? {
        let parts = text.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let raw = parts.first, !raw.isEmpty, raw.utf8.count <= 7 else { return nil }
        let name = raw + String(repeating: " ", count: 7 - raw.utf8.count)
        guard parts.count == 2 else { return StubChannelEngine(name: name) }
        let v = parts[1].split(separator: "-").map { UInt8($0) }
        guard v.count == 2, let low = v[0], let high = v[1] else { return nil }
        return StubChannelEngine(name: name, versionLow: low, versionHigh: high)
    }
}
