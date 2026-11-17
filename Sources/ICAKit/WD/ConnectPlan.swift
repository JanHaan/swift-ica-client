import Foundation
import Network

/// Where and how an ICA file is connected (docs/16-direct-mode.md §4, docs/10 A.3, docs/20 §2.2–2.7). Pure: built from
/// the ICA file alone, so the selection is unit-tested without a network.
///
/// | ICA file | Route |
/// |---|---|
/// | `SSLEnable=On`, `SSLProxyHost`, `CGPSecurityTicket=On` | gateway: TLS to `SSLProxyHost`, CGP bind with the STA ticket in `Address` (unchanged) |
/// | `SSLEnable=On`, `SSLProxyHost`, ticket off, `Address` a STA ticket | gateway without SR: TLS, SOCKS5 CONNECT with the ticket |
/// | `SSLEnable=On`, `Address` a host | direct TLS to the VDA: CGP without ticket if SR is on, else SOCKS5 to `Address` [I] |
/// | `SSLEnable=Off`, CGP on (`CGPAddress`, or `CGPSecurityTicket=On`) | TCP to `Address` host, CGP port (2598), CGP without ticket |
/// | `SSLEnable=Off`, CGP off | TCP to `Address` (1494), raw ICA |
public struct ICAConnectPlan: Equatable, Sendable, CustomStringConvertible {
    public enum Route: String, Equatable, Sendable {
        /// Through a NetScaler Gateway (`SSLProxyHost` + STA ticket).
        case gateway
        /// Straight to the VDA, no gateway.
        case direct
    }

    /// What runs on the socket after TCP (and TLS).
    public enum Framing: Equatable, Sendable {
        /// CGP (session reliability); `ticket` is the STA ticket for the gateway, nil for a direct bind (docs/20 §7.2).
        case cgp(ticket: String?)
        /// Raw ICA (detect handshake, then the WD byte stream), optionally after a SOCKS5 CONNECT (docs/20 §2.6).
        case raw(socks: SOCKSTarget?)
    }

    /// SOCKS5 CONNECT target (docs/20 §2.6): `Address` host or ticket, and port; `Username`/`ClearPassword` for the
    /// user/password method. Secrets: never logged (`description` shows lengths only).
    public struct SOCKSTarget: Equatable, Sendable {
        public var host: String
        public var port: UInt16
        public var username: String?
        public var password: String?
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case missingAddress
        case badAddress
        /// `EncryptionLevelSession` asks for SecureICA (RC5), which this client does not implement (docs/20 §5.3).
        case unsupportedEncryption(String)

        public var description: String {
            switch self {
            case .missingAddress: "the ICA file has no Address"
            case .badAddress: "the ICA file's Address is not a host[:port]"
            case .unsupportedEncryption(let level):
                "the server requires ICA encryption \"\(level)\" (SecureICA/RC5), which this client does not support; "
                    + "ask for Basic encryption or TLS (SSLEnable=On) on the delivery group"
            }
        }
    }

    public var route: Route
    public var host: String
    public var port: UInt16
    public var tls: Bool
    public var framing: Framing
    public var encryption: ICAEncryptionLevel
    /// `HDXoverUDP` asks for EDT, which we do not offer: TCP only (docs/20 §6). For the log.
    public var ignoresUDP: Bool

    public var usesCGP: Bool { if case .cgp = framing { true } else { false } }

    public var description: String {
        let what: String
        switch framing {
        case .cgp(let ticket): what = ticket == nil ? "CGP, no ticket" : "CGP with STA ticket (\(ticket!.count) chars)"
        case .raw(let socks):
            what = socks.map { "SOCKS5 to \(route == .gateway ? "ticket (\($0.host.count) chars)" : "\($0.host):\($0.port)"), raw ICA" }
                ?? "raw ICA"
        }
        return "\(route.rawValue) \(tls ? "TLS" : "TCP") \(host):\(port), \(what), encryption \(encryption)"
            + (ignoresUDP ? ", HDXoverUDP ignored (TCP only)" : "")
    }

    public static let icaPort: UInt16 = 1494
    public static let cgpPort: UInt16 = 2598
    public static let sslPort: UInt16 = 443

    /// `environment`: `ICA_DIRECT_TLS_SOCKS=0` sends raw ICA right after the TLS handshake to a VDA instead of a SOCKS5
    /// CONNECT first (docs/16 §4.2, an assumption for the lab to settle). `ICA_IGNORE_ENCRYPTION_LEVEL=1` connects even
    /// when the file asks for RC5 (the server then decides).
    public init(ica: ICAFile, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        encryption = ICAEncryptionLevel(ica["EncryptionLevelSession"])
        if case .secureICA(let name) = encryption, environment["ICA_IGNORE_ENCRYPTION_LEVEL"] != "1" {
            throw Failure.unsupportedEncryption(name)
        }
        let udp = ica["HDXoverUDP"]?.lowercased() ?? ""
        ignoresUDP = ["on", "pref", "preferred", "true"].contains(udp)
        let address = ica["Address"].flatMap { $0.isEmpty ? nil : $0 }
        let proxy = ica["SSLProxyHost"].flatMap { $0.isEmpty ? nil : $0 }
        let cgpTicket = ica.bool("CGPSecurityTicket")
        let cgpAddress = ica["CGPAddress"].flatMap { $0.isEmpty ? nil : $0 }
        let sslOn = ica.bool("SSLEnable")

        // 1. The gateway path, exactly as before (docs/10 A.7, docs/20 §7.1). As before, `SSLProxyHost` + ticket +
        //    `CGPSecurityTicket=On` suffice when `Address` is a ticket, whatever `SSLEnable` says.
        if let proxy, let address, cgpTicket, sslOn || Self.looksLikeTicket(address) {
            route = .gateway
            (host, port) = Self.endpoint(proxy, defaultPort: Self.sslPort)
            tls = true
            framing = .cgp(ticket: address)
            return
        }
        guard let address else { throw Failure.missingAddress }
        let username = ica["Username"].flatMap { $0.isEmpty ? nil : $0 }
        let password = ica["ClearPassword"].flatMap { $0.isEmpty ? nil : $0 }

        // 2. Gateway without session reliability: SOCKS5 with the STA ticket inside TLS (docs/20 §2.6, §7.3).
        if sslOn, let proxy, Self.looksLikeTicket(address) {
            route = .gateway
            (host, port) = Self.endpoint(proxy, defaultPort: Self.sslPort)
            tls = true
            let (target, targetPort) = Self.ticketTarget(address)
            framing = .raw(socks: SOCKSTarget(host: target, port: targetPort, username: username, password: password))
            return
        }
        guard !Self.looksLikeTicket(address) else { throw Failure.badAddress }
        route = .direct
        let (addressHost, addressPort) = Self.endpoint(address, defaultPort: Self.icaPort)
        guard !addressHost.isEmpty else { throw Failure.badAddress }
        let cgp = cgpTicket || cgpAddress != nil

        // 3. HDX TLS straight to the VDA [I]: the TLS peer is `SSLProxyHost` (the VDA's certificate name) when present,
        //    else the `Address` host; port from `SSLProxyHost`, else 443 (docs/16 §4.2).
        if sslOn {
            tls = true
            if let proxy { (host, port) = Self.endpoint(proxy, defaultPort: Self.sslPort) } else { (host, port) = (addressHost, Self.sslPort) }
            if cgp {
                framing = .cgp(ticket: nil)
            } else if environment["ICA_DIRECT_TLS_SOCKS"] == "0" {
                framing = .raw(socks: nil)
            } else {
                framing = .raw(socks: SOCKSTarget(host: addressHost, port: addressPort, username: username, password: password))
            }
            return
        }

        // 4. Plain TCP: CGP on its port (only the port of `CGPAddress` counts, docs/10 A.3), else raw ICA on 1494.
        tls = false
        host = addressHost
        if cgp {
            port = cgpAddress.map { Self.endpoint($0, defaultPort: Self.cgpPort).1 } ?? Self.cgpPort
            framing = .cgp(ticket: nil)
        } else {
            port = addressPort
            framing = .raw(socks: nil)
        }
    }

    /// An STA ticket (`;40;STA<id>;<hex>`, docs/10 A.7 [I]) rather than a host: contains `;` or a space (never in a
    /// host name or IP literal), or is a long single label without dots or colons (a bare ticket string; a VDA in an
    /// ICA file is an IP address or an FQDN) [I].
    static func looksLikeTicket(_ address: String) -> Bool {
        if address.contains(";") || address.contains(" ") { return true }
        return !address.contains(".") && !address.contains(":") && !address.hasPrefix("[") && address.count >= 24
    }

    /// The SOCKS5 domain-name target for a ticket: the text before the last `:` if a numeric port follows, else all.
    static func ticketTarget(_ address: String) -> (String, UInt16) {
        if let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]) {
            return (String(address[..<colon]), port)
        }
        return (address, icaPort)
    }

    /// `host`, `host:port`, `[v6]:port`, or a bare IPv6 literal (no port).
    static func endpoint(_ text: String, defaultPort: UInt16) -> (String, UInt16) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            let host = String(text[..<colon])
            // `*` (as in `CGPAddress=*:2598`) means "the same host"; the caller only uses the port then.
            return (host, UInt16(text[text.index(after: colon)...]) ?? defaultPort)
        }
        return (text, defaultPort)
    }
}

/// `EncryptionLevelSession` (docs/10 A.3, docs/20 §2.2, §5.2–5.3). Our stack always has the basic encryption PD
/// (PDCRYPT1); SecureICA (PDCRYPT2, RC5) is not implemented.
public enum ICAEncryptionLevel: Equatable, Sendable, CustomStringConvertible {
    /// Absent, `Basic`, `Encrypt`: the basic PD, which the server may or may not switch on.
    case basic
    /// RC5 at any strength, including "login only" (`EncRC5-0`).
    case secureICA(String)

    public init(_ value: String?) {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        // Names seen in public client docs: `Basic`, `RC5 (128 bit)`, `RC5 (40 bit)`, `RC5 (56 bit)`,
        // `RC5 (128 bit - Login Only)`; driver names `EncRC5-0/40/56/128` (docs/00 linux OEM guide) [P].
        if lower.contains("rc5") || lower.hasPrefix("encrc5") || lower.contains("secureica")
            || lower.range(of: #"-(0|40|56|128)$"#, options: .regularExpression) != nil {
            self = .secureICA(text)
        } else {
            self = .basic
        }
    }

    public var description: String {
        switch self {
        case .basic: "basic"
        case .secureICA(let name): "SecureICA \(name)"
        }
    }
}

/// The raw ICA start (no CGP): optional SOCKS5 CONNECT (docs/20 §2.6), then the ICA detect exchange (§7.3): the server
/// sends `7F 7F 49 43 41 00` (perhaps more than once), the client answers it once, everything after goes to the WD.
/// Pure: `start()` and `feed(_:)` return what to write and what to hand to the WD.
public struct RawICAHandshake: Sendable {
    public enum Phase: Equatable, Sendable {
        case socksMethod, socksAuth, socksConnect, detect, open, failed
    }

    public struct Output: Equatable, Sendable {
        /// Bytes to write, in order.
        public var write: [Data] = []
        /// ICA bytes for the WD.
        public var ica = Data()
        /// The detect string arrived (first time only).
        public var detected = false
        /// Log lines without secrets.
        public var log: [String] = []
        /// Set when the handshake failed; the connection must be closed.
        public var failure: String?
    }

    public private(set) var phase: Phase
    private let socks: ICAConnectPlan.SOCKSTarget?
    private var buffer = Data()
    private var replied = false
    private var wdStarted = false

    public init(socks: ICAConnectPlan.SOCKSTarget?) {
        self.socks = socks
        phase = socks == nil ? .detect : .socksMethod
    }

    /// The first write after connect: the SOCKS5 greeting, or nothing (the server speaks first, [I] docs/20 §7.3).
    public func start() -> Output {
        guard socks != nil else { return Output() }
        // Version 5, two methods: no authentication, user/password (docs/20 §2.6).
        return Output(write: [Data([0x05, 0x02, 0x00, 0x02])], log: ["→ SOCKS5 greeting"])
    }

    /// SOCKS5 reply codes 1–8 (RFC 1928), as the gateway uses them for ticket errors (docs/10 A.7).
    static func socksError(_ code: UInt8) -> String {
        switch code {
        case 1: "general failure (invalid or expired ticket?)"
        case 2: "connection not allowed"
        case 3: "network unreachable"
        case 4: "host unreachable (ticketing service or VDA)"
        case 5: "connection refused"
        case 6: "TTL expired"
        case 7: "command not supported"
        case 8: "address type not supported"
        default: "code \(code)"
        }
    }

    public mutating func feed(_ chunk: Data) -> Output {
        var out = Output()
        buffer.append(chunk)
        while true {
            switch phase {
            case .failed:
                buffer.removeAll()
                return out
            case .open:
                // Until the first WD byte went up, a repeated detect string (even in a later segment) is stripped.
                if !wdStarted {
                    let detect = CGPSession.icaDetect
                    while buffer.starts(with: detect) { buffer.removeFirst(detect.count) }
                    if buffer.isEmpty || detect.starts(with: buffer) { return out }
                    wdStarted = true
                }
                out.ica.append(buffer)
                buffer.removeAll()
                return out
            case .socksMethod:
                guard buffer.count >= 2 else { return out }
                let method = buffer[buffer.startIndex + 1]
                guard buffer[buffer.startIndex] == 0x05 else { return fail(&out, "SOCKS5: bad method reply") }
                buffer.removeFirst(2)
                if method == 0x02 {
                    var w = Data([0x01])
                    let user = Data((socks?.username ?? "").utf8.prefix(255))
                    let pass = Data((socks?.password ?? "").utf8.prefix(255))
                    w.append(UInt8(user.count)); w.append(user)
                    w.append(UInt8(pass.count)); w.append(pass)
                    out.write.append(w)
                    out.log.append("← SOCKS5 method user/password; → credentials (\(user.count)/\(pass.count) B)")
                    phase = .socksAuth
                } else if method == 0x00 {
                    out.log.append("← SOCKS5 method none")
                    out.write.append(connectRequest())
                    out.log.append("→ SOCKS5 CONNECT")
                    phase = .socksConnect
                } else {
                    return fail(&out, "SOCKS5: no acceptable method (0x\(String(method, radix: 16)))")
                }
            case .socksAuth:
                guard buffer.count >= 2 else { return out }
                let status = buffer[buffer.startIndex + 1]
                buffer.removeFirst(2)
                guard status == 0 else { return fail(&out, "SOCKS5: user/password refused") }
                out.write.append(connectRequest())
                out.log.append("→ SOCKS5 CONNECT")
                phase = .socksConnect
            case .socksConnect:
                // Only the first 3 bytes are checked (docs/20 §2.6); the bound address that follows in RFC 1928 is
                // skipped below by scanning for the detect string.
                guard buffer.count >= 3 else { return out }
                let reply = buffer[buffer.startIndex + 1]
                guard buffer[buffer.startIndex] == 0x05 else { return fail(&out, "SOCKS5: bad CONNECT reply") }
                guard reply == 0 else { return fail(&out, "SOCKS5 CONNECT refused: " + Self.socksError(reply)) }
                buffer.removeFirst(3)
                out.log.append("← SOCKS5 CONNECT accepted")
                phase = .detect
            case .detect:
                let detect = CGPSession.icaDetect
                guard let range = buffer.range(of: detect) else {
                    // Keep a possible partial detect string at the end; drop anything before it (the SOCKS bound
                    // address, [I]). Bounded: never keep more than the detect length.
                    if buffer.count > detect.count { buffer = buffer.suffix(detect.count - 1) }
                    return out
                }
                if range.lowerBound > buffer.startIndex {
                    out.log.append("   \(range.lowerBound - buffer.startIndex) B before the ICA detect string skipped")
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                // Further detect strings straight after the first are stripped, never answered (docs/20 §3.12.6).
                while buffer.starts(with: detect) { buffer.removeFirst(detect.count) }
                if !replied {
                    replied = true
                    out.detected = true
                    out.write.append(detect)
                    out.log.append("← ICA detect; → detect reply")
                }
                // A partial repeat at the very end: wait for more before opening.
                if !buffer.isEmpty, detect.starts(with: buffer) { return out }
                phase = .open
            }
        }
    }

    private func connectRequest() -> Data {
        guard let socks else { return Data() }
        var w = Data([0x05, 0x01, 0x00])
        if let v4 = IPv4Address(socks.host) {
            w.append(0x01); w.append(v4.rawValue)
        } else if let v6 = IPv6Address(socks.host) {
            w.append(0x04); w.append(v6.rawValue)
        } else {
            let name = Data(socks.host.utf8.prefix(255))
            w.append(0x03); w.append(UInt8(name.count)); w.append(name)
        }
        w.append(UInt8(socks.port >> 8)); w.append(UInt8(socks.port & 0xff))
        return w
    }

    private mutating func fail(_ out: inout Output, _ why: String) -> Output {
        phase = .failed
        out.failure = why
        buffer.removeAll()
        return out
    }
}
