import Foundation

/// HDX over UDP as the ICA file asks for it (docs/80 §8.8, D177). The server's administrator decides (adaptive transport
/// policy → `HDXoverUDP` in the launch file); ICA Viewer has no setting of its own.
public enum EDTMode: String, Sendable, Equatable {
    /// TCP only; no UDP datagram is sent.
    case off
    /// EDT and TCP race; TCP when EDT does not answer in time (§8.4).
    case preferred
    /// EDT only; no TCP connection. A blocked UDP path is an error.
    case on

    /// `HDXoverUDP`: `On`, `Preferred` or `pref` (any case); anything else, or no key, is off (docs/10, docs/20 §6).
    public init(hdxOverUDP value: String?) {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": self = .on
        case "preferred", "pref": self = .preferred
        default: self = .off
        }
    }

    /// `ICA_EDT`, a test override: `0`/`off`/`no` → off, `preferred`/`pref` → preferred, `on` → on; unset, `1` or
    /// anything else → nil (the file decides). A Developer ID build keeps only the off values (TestSwitches).
    public static func override(_ value: String?) -> EDTMode? {
        switch value?.lowercased() {
        case "0", "off", "no": .off
        case "preferred", "pref": .preferred
        case "on": .on
        default: nil
        }
    }
}

/// What a session does about EDT: the mode in effect, where EDT goes, and one log line that says why.
public struct EDTChoice: Sendable {
    /// In effect: `.off` also when the file asks for EDT on a route we do not offer it on.
    public var mode: EDTMode
    /// What the file (or `ICA_EDT`) asked for.
    public var requested: EDTMode
    public var target: CGPTransport.EDTTarget?
    public var note: String

    /// The rules of docs/80 §8.8. `environment`: `ICA_EDT` (override), `ICA_EDT_PORT` (the UDP port, tests).
    public static func choose(ica: ICAFile, plan: ICAConnectPlan, environment: [String: String]) -> EDTChoice {
        let raw = ica["HDXoverUDP"]
        let override = EDTMode.override(environment["ICA_EDT"])
        let requested = override ?? EDTMode(hdxOverUDP: raw)
        let source = "HDXoverUDP=\(raw ?? "(none)")" + (override.map { ", ICA_EDT=\($0.rawValue)" } ?? "")
        func tcpOnly(_ why: String) -> EDTChoice { EDTChoice(mode: .off, requested: requested, target: nil, note: "EDT: \(source): \(why)") }
        guard requested != .off else { return tcpOnly("TCP only") }
        // EDT carries the CGP stream (§1); the server offers it with session reliability only [B]. UDPICAPort (EDT
        // without CGP) was never seen in use (§7.2).
        guard plan.usesCGP else { return tcpOnly("not offered without session reliability (no CGPAddress); TCP only") }
        // Through a NetScaler Gateway EDT needs the gateway's DTLS; not built or tested (§8.6a).
        guard plan.route == .direct else { return tcpOnly("not offered through a gateway; TCP only") }
        let port = environment["ICA_EDT_PORT"].flatMap(UInt16.init)
        let addressIPv4 = ica["Address"].flatMap { Self.ipv4(String($0.split(separator: ":").first ?? "")) }
        let target: CGPTransport.EDTTarget
        if plan.tls {
            // TLS straight to the VDA: EDT inside DTLS on the TLS endpoint (D148); UDPCGPPort names the plain port.
            target = .init(host: plan.host, port: port ?? plan.port, dtlsServerName: plan.host, peerIPv4: addressIPv4)
        } else {
            // `UDPCGPPort=<vda>:2598` [B]; a `*` host (as in CGPAddress) means the VDA's address.
            var udp = ica["UDPCGPPort"].flatMap(Self.endpoint) ?? (plan.host, ICAConnectPlan.cgpPort)
            if udp.host == "*" { udp.host = plan.host }
            target = .init(host: udp.host, port: port ?? udp.port, peerIPv4: Self.ipv4(udp.host) ?? addressIPv4)
        }
        // The handshake carries the VDA's IPv4 address (§4.1); an IPv6-only VDA was never seen.
        guard !target.host.contains(":") else {
            return tcpOnly("not offered to an IPv6 address; TCP only")
        }
        let how = requested == .on ? "EDT only" : "EDT raced against TCP"
        let wire = target.dtlsServerName == nil ? "UDP" : "DTLS"
        return EDTChoice(mode: requested, requested: requested, target: target,
                         note: "EDT: \(source): \(how), \(wire) \(target.host):\(target.port)")
    }

    static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    /// `host:port` (an IPv6 literal in brackets is returned with its colons, which `choose` then refuses).
    static func endpoint(_ value: String) -> (host: String, port: UInt16)? {
        guard let colon = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: colon)...]) else { return nil }
        let host = value[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }
}
