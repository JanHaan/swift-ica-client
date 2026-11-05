import Foundation
import ICAKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let envPath = ProcessInfo.processInfo.environment["ICA_ENV"] ?? root.appendingPathComponent(".env").path
let sessionDir = root.appendingPathComponent(".session")
let cookiePath = sessionDir.appendingPathComponent("cookies.plist").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Hides token-like runs (long base64/hex) and known secret XML elements in a response body.
func redact(_ text: String) -> String {
    var out = text
    for element in ["StateContext", "Ticket", "Token", "Password"] {
        out = out.replacingOccurrences(
            of: "(<[^>/]*\(element)[^>]*>)[^<]+", with: "$1<redacted>", options: .regularExpression)
    }
    return out.replacingOccurrences(of: "[A-Za-z0-9+/_=%-]{40,}", with: "<long>", options: .regularExpression)
}

func printResponse(_ response: HTTPClient.Response, limit: Int) {
    print("status \(response.status)  final \(response.url.host ?? "")\(response.url.path)")
    let shown = ["Location", "Content-Type", "CitrixWebReceiver-Authenticate", "X-Citrix-ExplicitAuthProtocol",
                 "X-Citrix-GatewayLoginWithoutPassword", "X-Citrix-AM-GatewayAuthType"]
    for name in shown { if let value = response.header(name) { print("\(name): \(redact(value))") } }
    for (name, value) in response.headers where name.lowercased().hasPrefix("x-citrix") && !shown.contains(name) {
        print("\(name): \(redact(value))")
    }
    print("---")
    if let ica = ICAFile(text: response.text), response.text.contains("=") {
        print(ica.redactedDescription)
    } else {
        let body = redact(response.text)
        print(body.count > limit ? String(body.prefix(limit)) + "\n… (\(body.count) chars)" : body)
    }
}

let env: Env
do { env = try Env(path: envPath) } catch { fail("cannot read \(envPath)") }
guard let gateway = URL(string: (env["CITRIX_GATEWAY_URL"] ?? "https://gateway.example.com") + "/") else {
    fail("bad CITRIX_GATEWAY_URL")
}
try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
let http = HTTPClient()
try? http.loadCookies(from: cookiePath)

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

switch command {
case "login":
    guard let user = env["CITRIX_USERNAME"], let password = env["CITRIX_PASSWORD"] else {
        fail("CITRIX_USERNAME and CITRIX_PASSWORD must be set in .env")
    }
    let username = env["CITRIX_DOMAIN"].map { "\($0)\\\(user)" } ?? user
    let totp = env["CITRIX_TOTP_SECRET"].flatMap {
        TOTP(base32Secret: $0, digits: Int(env["CITRIX_TOTP_DIGITS"] ?? "") ?? 6,
             period: Int(env["CITRIX_TOTP_PERIOD"] ?? "") ?? 30,
             algorithm: TOTP.Algorithm(rawValue: (env["CITRIX_TOTP_ALGORITHM"] ?? "SHA1").uppercased()) ?? .sha1)
    }
    let passcode: () -> String? = {
        if let totp {
            // Avoid posting a code that expires in flight.
            if totp.secondsRemaining() < 3 { Thread.sleep(forTimeInterval: Double(totp.secondsRemaining()) + 0.5) }
            return totp.code()
        }
        print("Passcode: ", terminator: "")
        return readLine()
    }
    do {
        try await GatewayLogon(http: http, base: gateway).logon(
            .init(username: username, password: password, passcode: passcode))
        try http.saveCookies(to: cookiePath)
        print("logged on; cookies: \(http.cookieNames.joined(separator: ", "))")
    } catch {
        fail("\(error)")
    }

case "req":
    // icactl req GET|POST <path-or-url> [key=value ...] [--limit N]
    guard args.count >= 2 else { fail("usage: icactl req GET|POST <path> [key=value ...]") }
    let method = args.removeFirst().uppercased()
    let target = args.removeFirst()
    var limit = 4000
    var form: [(String, String)] = []
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        if arg == "--limit", let n = iterator.next().flatMap(Int.init) { limit = n; continue }
        guard let eq = arg.firstIndex(of: "=") else { fail("bad field \(arg)") }
        form.append((String(arg[..<eq]), String(arg[arg.index(after: eq)...])))
    }
    guard let url = URL(string: target, relativeTo: gateway) else { fail("bad path") }
    var headers = ["X-Citrix-IsUsingHTTPS": "Yes", "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
    if let csrf = http.cookie("CsrfToken") { headers["Csrf-Token"] = csrf }
    do {
        let response = try await http.send(method, url, headers: headers, form: form.isEmpty ? nil : form)
        try http.saveCookies(to: cookiePath)
        printResponse(response, limit: limit)
    } catch {
        fail("\(error)")
    }

case "list":
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        try http.saveCookies(to: cookiePath)
        for resource in resources.sorted(by: { $0.name < $1.name }) {
            let flags = (resource.disabled == true ? " (disabled)" : "")
                + (resource.clienttypes.map { " [\($0.joined(separator: ","))]" } ?? "")
            print("\(resource.name)\(flags)")
        }
        print("\(resources.count) resources")
    } catch {
        fail("\(error)")
    }

case "launch":
    // icactl launch <resource name>  — saves the ICA file to .session/last.ica and prints it redacted
    guard let name = args.first ?? env["CITRIX_RESOURCE"] else { fail("usage: icactl launch <resource name>") }
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name })
            ?? resources.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            fail("no resource named \(name)")
        }
        let text = try await store.launchICA(resource)
        try http.saveCookies(to: cookiePath)
        let path = sessionDir.appendingPathComponent("last.ica").path
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        print("saved \(path) for \(resource.name)")
        print(ICAFile(text: text)?.redactedDescription ?? "(not an ICA file)")
    } catch {
        fail("\(error)")
    }

case "connect", "session":
    // icactl session [resource] — full ICA session: logon, capture channel data to .session/, then logoff.
    // ICA_DUMP_SECONDS (default 20) keeps it up; ICA_CREDS_IN_UI=1 skips cap 0x12 (logon strings in the UI module).
    let name = args.first ?? env["CITRIX_RESOURCE"] ?? "Calculator"
    guard name == "Calculator" || ProcessInfo.processInfo.environment["ICA_ALLOW_ANY_RESOURCE"] == "1" else {
        fail("live tests are limited to \"Calculator\"")
    }
    let seconds = Double(ProcessInfo.processInfo.environment["ICA_DUMP_SECONDS"] ?? "") ?? 20
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        try await runSession(ica: ica, seconds: seconds)
    } catch {
        fail("\(error)")
    }

case "cookies":
    print(http.cookieNames.joined(separator: "\n"))

default:
    print("""
    usage:
      icactl login                       nFactor logon at the gateway, saves cookies in .session/
      icactl req GET|POST <path> [k=v]   request with saved cookies (bodies redacted)
      icactl cookies                     list saved cookie names
      icactl session [resource]          launch, logon, capture channel data, log off (ICA_DUMP_SECONDS)
    """)
}

// MARK: - Session command

/// Saves every payload of one channel to .session/ch<N>-<seq>.bin (0600, first `limit`).
final class ChannelCapture {
    let number: UInt8
    let name: String
    var writes = 0
    var bytes = 0
    var saved = 0
    let limit = 300

    init(number: UInt8, name: String) {
        self.number = number
        self.name = name
    }

    func record(_ data: [UInt8]) {
        if writes == 0 {
            // First payload of this run: drop this channel's files from an earlier run.
            let prefix = "ch\(number)-"
            for file in (try? FileManager.default.contentsOfDirectory(atPath: sessionDir.path)) ?? []
            where file.hasPrefix(prefix) && file.hasSuffix(".bin") {
                try? FileManager.default.removeItem(at: sessionDir.appendingPathComponent(file))
            }
        }
        writes += 1
        bytes += data.count
        if saved < limit {
            saved += 1
            let path = sessionDir.appendingPathComponent(String(format: "ch%d-%04d.bin", number, saved)).path
            FileManager.default.createFile(atPath: path, contents: Data(data), attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Session-info tags whose values are safe to print (server/VDA identity, not user or session secrets).
/// (Statics, not globals: top-level globals declared below the command switch are not yet initialised.)
enum SessionTags { static let printable: Set<String> = ["CTXSRVR", "CTXVERS", "CTXTYPE", "CTXDG00", "CTXDG01", "CTXDG02", "CTXDG03", "CTXDG04"] }

enum Clock { static let start = Date() }
/// Log line with seconds since the first log line.
func say(_ text: String) { print(String(format: "%6.2f ", Date().timeIntervalSince(Clock.start)) + text) }

func hexLine(_ bytes: [UInt8], limit: Int = 48) -> String {
    bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ") + (bytes.count > limit ? " … (\(bytes.count)B)" : "")
}

func runSession(ica: ICAFile, seconds: Double) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    if ProcessInfo.processInfo.environment["ICA_CREDS_IN_UI"] == "1" { config.policy.credentialRequest = false }
    if let flags = ProcessInfo.processInfo.environment["ICA_REDUCER_FLAGS"].flatMap({ UInt16($0, radix: 16) }) {
        config.policy.reducerFlags = flags
    }
    let width = Int(ProcessInfo.processInfo.environment["ICA_WIDTH"] ?? "") ?? 1920
    let height = Int(ProcessInfo.processInfo.environment["ICA_HEIGHT"] ?? "") ?? 1080
    config.display = WDDisplay(width: width, height: height)
    let session = try ICASession(ica: ica, configuration: config)
    let seamless = session.seamless
    let thinwire = session.thinwire

    var windowLines: [String] = []
    seamless.onEvent = { event in
        switch event {
        case .channelReady(let host): say("TWI host init: flags 0x\(String(host.flags.rawValue, radix: 16))")
        case .seamlessStateChanged(let active): say("TWI seamless active: \(active)")
        case .windowAdded(let w):
            let line = "window \(w.id) \(w.kind) \"\(w.title)\" \(w.windowRect.width)x\(w.windowRect.height)"
            windowLines.append(line)
            say("TWI " + line)
        case .windowRemoved(let w): say("TWI window \(w.id) removed")
        default: break
        }
    }
    var frames = 0
    thinwire.log = { say($0) }
    thinwire.onInit = { info in say("Thinwire INIT \(info.width)x\(info.height) profile \(info.profile)") }
    thinwire.onUpdate = { _ in frames += 1 }
    let captures = [ChannelCapture(number: 9, name: "CTXTW"), ChannelCapture(number: 12, name: "CTXTWI")]

    var packetCounts: [String: (count: Int, bytes: Int)] = [:]
    var dropped: [UInt8: Int] = [:]
    var keepalives = 0
    var connectedAt: Date?
    var terminateReason: UInt8?
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .cgpBound(let caps): say("← CGP bind response: \(caps.map(\.description).joined(separator: ", "))")
        case .channelOpened(let status): say("← CGP channel open: status \(status)")
        case .detect: say("← ICA detect, replied")
        case .keepalive(let raw):
            keepalives += 1
            if keepalives == 1 { say("← CGP keepalive [\(hexLine([UInt8](raw)))] (further ones counted)") }
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(let e):
            switch e {
            case .initRequest(let r):
                say("← INIT_REQUEST level \(r.level), \(r.capabilities.count) caps, host OS \(r.hostOS.map(String.init) ?? "?"), wheel \(r.extendedMouse)")
                for cap in r.capabilities { say("     " + cap.description) }
            case .initResponseSent(let modules, let negotiated):
                say("→ INIT_RESPONSE modules \(modules.joined(separator: ", "))")
                say("     negotiated: \(negotiated.map(\.description).joined(separator: ", "))")
            case .initConnect(let remaining, let moduleClass, let payload):
                // Hex only for WD/PD/VD modules; other classes may echo client data.
                let shown = [2, 3, 4].contains(moduleClass) ? " [\(hexLine(payload, limit: 40))]" : " (\(payload.count)B)"
                say("← INIT_CONNECT remaining \(remaining) class \(moduleClass)" + shown)
                let path = sessionDir.appendingPathComponent("initconnect-\(remaining).bin").path
                FileManager.default.createFile(atPath: path, contents: Data(payload), attributes: [.posixPermissions: 0o600])
            case .connected(let version, let rp, let ep, let caps):
                connectedAt = Date()
                say("→ INIT_CONNECT_RESPONSE; connected (reducer v\(version), powers \(rp)/\(ep)); final caps: \(caps.map(\.description).joined(separator: ", "))")
            case .encryption(let mode): say("encryption established: \(mode)")
            case .sessionInfo(let tag, let value):
                if SessionTags.printable.contains(tag) {
                    let text = String(decoding: value.filter { $0 != 0 }, as: UTF8.self)
                    say("← session info \(tag) = \(text)")
                } else {
                    say("← session info \(tag) (\(value.count)B, not shown)")
                }
            case .credentialRequest(let answered): say("← credential request 0x44; answered: \(answered) (strings not shown)")
            case .setLED(let mask): say("← LED 0x\(String(mask, radix: 16))")
            case .mousePosition(let x, let y): say("← mouse position \(x),\(y)")
            case .terminate(let reason):
                terminateReason = reason
                say("← TERMINATE reason \(reason); acked")
            case .packet(let p):
                if let ch = p.channel, let capture = captures.first(where: { $0.number == ch }) { capture.record(p.payload) }
                let key = p.channel.map { "VC ch\($0)" } ?? WDPacketType.name(p.type)
                packetCounts[key, default: (0, 0)].count += 1
                packetCounts[key, default: (0, 0)].bytes += p.payload.count
                if p.channel == nil, ![0x00, 0x02, 0x05, 0x3B, 0x44, 0x3F].contains(p.type), packetCounts[key]!.count <= 3 {
                    say("← \(key) (\(p.payload.count)B)")
                }
            case .droppedChannelData(let channel, let bytes): dropped[channel, default: 0] += bytes
            case .failure(let text): say("WD failure: \(text)")
            }
        }
    }

    try await session.start()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }

    var ending = "session ended before the dump time was over"
    if !session.isClosed {
        let canLogoff: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if canLogoff {
            say("→ TWI LOGOFF")
            let logoffDeadline = Date().addingTimeInterval(25)
            while Date() < logoffDeadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
            ending = session.isClosed ? "logged off (server ended the session)" : "logoff sent, server did not end the session in 25 s"
        } else {
            ending = "no TWI channel to log off; disconnect only"
        }
        if !session.isClosed { await session.close() }
    }

    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        session.perform {
            say("\n=== summary ===")
            say("connected: \(connectedAt.map { _ in "yes" } ?? "no"), terminate reason: \(terminateReason.map(String.init) ?? "none"), CGP keepalives: \(keepalives)")
            for (key, value) in packetCounts.sorted(by: { $0.key < $1.key }) {
                say(String(format: "  %-18@ %6d packets %9d bytes", key as NSString, value.count, value.bytes))
            }
            for (channel, bytes) in dropped.sorted(by: { $0.key < $1.key }) { say("  dropped ch\(channel): \(bytes) bytes") }
            for capture in captures {
                say("  ch\(capture.number) \(capture.name): \(capture.writes) writes, \(capture.bytes) bytes, \(capture.saved) files saved")
            }
            say("  Thinwire: \(thinwire.stats.commands) commands, \(frames) updates, \(thinwire.stats.errors) errors, \(thinwire.stats.resyncs) resyncs")
            if let fb = thinwire.framebuffer, let png = ProcessInfo.processInfo.environment["ICA_PNG"] {
                let url = URL(fileURLWithPath: png)
                if fb.writePNG(to: url) { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            }
            say("  TWI messages: \(seamless.messageCounts.sorted { $0.key < $1.key }.map { String(format: "0x%02x×%d", $0.key, $0.value) }.joined(separator: " ")), malformed \(seamless.malformedCount)")
            for line in windowLines { say("  " + line) }
            say("end: \(ending)")
            c.resume()
        }
    }
}
