import Foundation

/// How the host tells a helper where to check in (docs/99 §4 rendezvous): launch arguments carry the
/// broker's bootstrap name, a per-helper random token and the host's pid (the helper exits with it).
public struct HelperLaunch: Equatable, Sendable {
    public var broker: String
    public var token: String
    public var hostPid: Int32
    /// No AppKit, no windows: the helper only checks in and answers surface probes (dockspike ipc-check).
    public var headless: Bool

    public init(broker: String, token: String, hostPid: Int32, headless: Bool = false) {
        self.broker = broker; self.token = token; self.hostPid = hostPid; self.headless = headless
    }

    public static func brokerName(hostPid: Int32) -> String { "local.alttab.ICAViewer.broker.\(hostPid)" }

    /// 128 random bits, hex.
    public static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(format: "%016llx", rng.next() as UInt64) }.joined()
    }

    public var arguments: [String] {
        ["--broker", broker, "--token", token, "--host-pid", String(hostPid)] + (headless ? ["--headless"] : [])
    }

    /// Parses `arguments`; ignores anything else (LaunchServices may add `-psn_…` or `-NS…` defaults).
    public static func parse(_ args: [String]) -> HelperLaunch? {
        var broker: String?, token: String?, pid: Int32?, headless = false
        var i = 0
        while i < args.count {
            let value = i + 1 < args.count ? args[i + 1] : nil
            switch args[i] {
            case "--broker": broker = value; i += 1
            case "--token": token = value; i += 1
            case "--host-pid": pid = value.flatMap { Int32($0) }; i += 1
            case "--headless": headless = true
            default: break
            }
            i += 1
        }
        guard let broker, !broker.isEmpty, let token, !token.isEmpty, let pid, pid > 0 else { return nil }
        return HelperLaunch(broker: broker, token: token, hostPid: pid, headless: headless)
    }
}
