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
guard let gatewayText = env["CITRIX_GATEWAY_URL"], !gatewayText.isEmpty else {
    fail("CITRIX_GATEWAY_URL is not set: add CITRIX_GATEWAY_URL=https://<your gateway> to \(envPath)")
}
guard let gateway = URL(string: gatewayText + "/"), gateway.scheme == "https", gateway.host != nil else {
    fail("bad CITRIX_GATEWAY_URL (expected https://<host>)")
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
            return totp.freshCode(statePath: sessionDir.appendingPathComponent("totp-last").path)
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
    // icactl session [resource] — full ICA session: logon, capture channel data to .session/last/, then logoff.
    // ICA_CAPTURE_REPLAY=1 writes the captures to .session/replay/ instead (the set the replay tests read).
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
        let replay = ProcessInfo.processInfo.environment["ICA_CAPTURE_REPLAY"] == "1"
        let dir = sessionDir.appendingPathComponent(replay ? "replay" : "last")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        say("captures go to \(dir.path)")
        try await runSession(ica: ica, seconds: seconds, captureDir: dir)
    } catch {
        fail("\(error)")
    }

case "droptest":
    // icactl droptest [resource] — like `session`, but drops the TCP connection once after
    // ICA_TEST_DROP_AFTER s (alias ICA_DROP_AFTER; default 15, no FINISH), lets CGP session reliability resume (docs/20 §3.12),
    // logs the resume details, and logs off ICA_DUMP_SECONDS (default 60) after the start.
    // ICA_TEST_BLACKHOLE_AFTER=<s>[:<d>] instead stalls the socket to exercise the liveness path.
    let name = args.first ?? env["CITRIX_RESOURCE"] ?? "Calculator"
    guard name == "Calculator" || name == "Notepad" else { fail("drop tests are limited to \"Calculator\" and \"Notepad\"") }
    let seconds = Double(ProcessInfo.processInfo.environment["ICA_DUMP_SECONDS"] ?? "") ?? 60
    let blackhole = ProcessInfo.processInfo.environment["ICA_TEST_BLACKHOLE_AFTER"] != nil
    let dropEnv = ProcessInfo.processInfo.environment["ICA_TEST_DROP_AFTER"] ?? ProcessInfo.processInfo.environment["ICA_DROP_AFTER"]
    let dropAfter = blackhole ? nil : dropEnv.flatMap(Double.init) ?? 15
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        // Captures go to .session/droptest/, so the replay set (.session/ch9-*) stays as it is.
        let dir = sessionDir.appendingPathComponent("droptest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await runSession(ica: ica, seconds: seconds, dropAfter: dropAfter, captureDir: dir)
    } catch {
        fail("\(error)")
    }

case "cliptest":
    // icactl cliptest [resource] — clipboard channel test, Notepad only (docs/70 §8): handshake and the
    // host's format names; Mac → host (announce a test string, Ctrl+V into Notepad) and host → Mac
    // (Ctrl+A, Ctrl+C, compare). Input only in a session this run logged on itself; never saves.
    let name = args.first ?? "Notepad"
    guard name == "Notepad" else { fail("cliptest is limited to \"Notepad\"") }
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        try await runClipTest(ica: ica)
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
      icactl session [resource]          launch, logon, capture to .session/last/ (ICA_CAPTURE_REPLAY=1: .session/replay/), log off
      icactl droptest [resource]         session with one link drop after ICA_TEST_DROP_AFTER s and a CGP resume
      icactl cliptest                    clipboard test in "Notepad" (Notepad): paste in, copy out, never saves

    ICA_LOGOFF_IF_ONLY=<exe>[,<exe>]     session: also log off a reconnected session, but only if every window
                                         seen belongs to one of these executables (or logonui.exe/cmd.exe)
    """)
}

// MARK: - Session command

/// Saves every payload of one channel to <dir>/ch<N>-<seq>.bin (0600, first `limit`).
final class ChannelCapture {
    let number: UInt8
    let name: String
    let dir: URL
    var writes = 0
    var bytes = 0
    var saved = 0
    let limit = 300

    init(number: UInt8, name: String, dir: URL) {
        self.number = number
        self.name = name
        self.dir = dir
    }

    func record(_ data: [UInt8]) {
        if writes == 0 {
            // First payload of this run: drop this channel's files from an earlier run.
            let prefix = "ch\(number)-"
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where file.hasPrefix(prefix) && file.hasSuffix(".bin") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
        writes += 1
        bytes += data.count
        if saved < limit {
            saved += 1
            let path = dir.appendingPathComponent(String(format: "ch%d-%04d.bin", number, saved)).path
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

func runSession(ica: ICAFile, seconds: Double, dropAfter: Double? = nil, captureDir: URL) async throws {
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
    if let dropAfter { session.transport.testDropAfter = dropAfter }
    let seamless = session.seamless
    let thinwire = session.thinwire

    var windowLines: [String] = []
    // ICA_LOGOFF_IF_ONLY (guarded logoff of a reconnect): every window's process id and app key, and
    // when the host last (re-)enumerated its windows: a TWI host init, or a PAUSE/RESUME that was really
    // sent (ICASession.lastPauseResumeSent). Session queue only.
    let guardList = ProcessInfo.processInfo.environment["ICA_LOGOFF_IF_ONLY"].map(GuardedLogoff.parseList)
    var windowsSeen = SeenWindows()
    var lastHostInit: Date?
    // Log off only a session this run logged on itself; a reconnect (maybe the user's own session,
    // shared by the store) is only disconnected (same rule as ICAViewer, D18/D20).
    var logon = FreshLogonDetector()
    func logonVerdict(_ gap: TimeInterval?, _ what: String) {
        guard let gap else { return }
        say(logon.isFresh ? "fresh logon (logon UI, then \(what) after \(Int(gap)) s)"
                          : String(format: "reconnect pattern (\(what) %.1f s after the logon UI)", gap))
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady(let host):
            lastHostInit = Date()
            say("TWI host init: flags 0x\(String(host.flags.rawValue, radix: 16))")
            logonVerdict(logon.hostInit(), "host init")
        case .seamlessStateChanged(let active): say("TWI seamless active: \(active)")
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            let line = "window \(w.id) \(w.kind) \"\(w.title)\" \(w.windowRect.width)x\(w.windowRect.height)"
            windowLines.append(line)
            say("TWI " + line)
        case .windowRemoved(let w): say("TWI window \(w.id) removed")
        case .windowChanged(let w, _): windowsSeen.note(w)
        default: break
        }
    }
    var frames = 0
    thinwire.log = { say($0) }
    session.onThinwireInit = { info in
        say("Thinwire INIT \(info.width)x\(info.height) profile \(info.profile)")
        logonVerdict(logon.thinwireInit(), "Thinwire INIT")
    }
    thinwire.onUpdate = { _ in frames += 1 }
    let captures = [ChannelCapture(number: 9, name: "CTXTW", dir: captureDir), ChannelCapture(number: 12, name: "CTXTWI", dir: captureDir)]

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
        case .suspended(let info):
            let s = session.transport.status
            say("CGP suspended: \(info.reason); deadline in \(Int(info.deadline.timeIntervalSinceNow)) s, dimming \(info.dimming.map(String.init) ?? "-"); " +
                "sent \(s.sent), acked \(s.acknowledged), queue \(s.queued) packets / \(s.queuedBytes) B, received sequenced \(s.receivedSequenced)")
        case .resuming(let attempt): say("CGP resume attempt \(attempt)")
        case .resumed(let r):
            let s = session.transport.status
            say("CGP resumed: nextSeq sent \(r.sentNextSeq), received \(r.serverNextSeq); queue \(r.queueBefore) → dropped \(r.dropped), " +
                "retransmitted \(r.retransmitted); now sent \(s.sent), acked \(s.acknowledged), queue \(s.queued), ack overrun \(s.ackOverrun)")
            say("   check §3.12.12 #4: server nextSeq \(r.serverNextSeq) vs our sent+1 before retransmit \(s.sent + 1) (equal when nothing was lost)")
        case .gaveUp(let g):
            say("CGP gave up: \(g.message) (\(g.cause)); relaunch \(g.offerRelaunch ? "offered" : "not offered")" +
                (g.relaunchNotBefore.map { ", not before \(Int($0.timeIntervalSinceNow)) s" } ?? ""))
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
                let path = captureDir.appendingPathComponent("initconnect-\(remaining).bin").path
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
    if session.isClosed, let reason = terminateReason { ending = "ended by server before the dump time was over (TERMINATE reason \(reason))" }
    let fresh: Bool = await withCheckedContinuation { c in session.perform { c.resume(returning: logon.isFresh) } }
    var mayLogoff = fresh
    if !session.isClosed, session.isEstablished, !fresh, let guardList {
        // Reconnect: windows are re-announced after the PAUSE/RESUME; give them at least 10 s (at most 30 s more).
        let waitUntil = Date().addingTimeInterval(30)
        while !session.isClosed, Date() < waitUntil {
            let since: Date? = await withCheckedContinuation { c in
                session.perform { c.resume(returning: [lastHostInit, session.lastPauseResumeSent].compactMap { $0 }.max()) }
            }
            if let since, Date().timeIntervalSince(since) >= 10 { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let decision: GuardedLogoff.Decision = await withCheckedContinuation { c in
            session.perform {
                c.resume(returning: GuardedLogoff.decide(allowList: guardList, windowExecutables: windowsSeen.executables(seamless.model)))
            }
        }
        switch decision {
        case .allowed(let seen):
            say("guarded logoff: allowed (windows: \(seen.joined(separator: ", ")))")
            mayLogoff = true
        case .refused(let seen):
            say("guarded logoff refused: \(seen.isEmpty ? "no window seen" : seen.joined(separator: ", "))")
        }
    }
    if !session.isClosed, !session.isEstablished {
        say("session never got past the handshake: disconnecting")
        await session.close()
        ending = "disconnected before the session was established"
    } else if !session.isClosed, !mayLogoff {
        say("not a fresh logon by this run: disconnecting without logoff")
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else if !session.isClosed {
        let canLogoff: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if canLogoff {
            say("→ TWI LOGOFF")
            let logoffDeadline = Date().addingTimeInterval(25)
            while Date() < logoffDeadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
            ending = !session.isClosed ? "logoff sent, server did not end the session in 25 s"
                : terminateReason.map { "logged off (server ended the session: TERMINATE reason \($0))" } ?? "logged off (server ended the session)"
        } else {
            ending = "no TWI channel to log off; disconnect only"
        }
        if !session.isClosed { await session.close() }
    }

    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        session.perform {
            say("\n=== summary ===")
            say("connected: \(connectedAt.map { _ in "yes" } ?? "no"), terminate reason: \(terminateReason.map(String.init) ?? "none"), CGP keepalives: \(keepalives)")
            let t = session.transport.status
            say("  CGP: resumes \(t.resumes), attempts \(t.attempts), sent \(t.sent), acked \(t.acknowledged), queue \(t.queued), " +
                "received sequenced \(t.receivedSequenced), our keepalives \(t.keepalivesSent), acks \(t.acksSent), ack overrun \(t.ackOverrun)")
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

/// TWI windows seen in a run (session queue): process id and app key per window, for the guarded logoff.
struct SeenWindows {
    private var windows: [UInt32: (pid: UInt32?, appKey: String)] = [:]

    mutating func note(_ w: TWIWindow) {
        let old = windows[w.id]
        windows[w.id] = (w.processId ?? old?.pid, w.appKey)
    }

    /// Executable path per window: from the TWI process table, else an `exe:` app key; nil if unknown.
    func executables(_ model: WindowModel) -> [String?] { windows.keys.map { single($0, model) } }

    func appKey(_ id: UInt32) -> String? { windows[id]?.appKey }

    /// Executable path of one window, if known.
    func single(_ id: UInt32, _ model: WindowModel) -> String? {
        guard let entry = windows[id] else { return nil }
        if let pid = entry.pid, let p = model.processes[pid], !p.executablePath.isEmpty { return p.executablePath }
        return entry.appKey.hasPrefix("exe:") ? String(entry.appKey.dropFirst(4)) : nil
    }

    func basenames(_ model: WindowModel) -> [String] { executables(model).map { $0.map(GuardedLogoff.basename) ?? GuardedLogoff.unknown } }
}

// MARK: - Clipboard test (docs/70 §8)

/// Runs `body` on the session queue and returns its result.
func onSession<T>(_ session: ICASession, _ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in session.perform { c.resume(returning: body()) } }
}

/// Polls `condition` (on the session queue) every 100 ms for up to `seconds`.
func waitFor(_ session: ICASession, _ seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !session.isClosed {
        if await onSession(session, condition) { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return await onSession(session, condition)
}

func runClipTest(ica: ICAFile) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    // Umlauts, a non-BMP character and a line break: exercises UTF-16, surrogates and CRLF ↔ LF.
    let testText = "CTXCLIP-Test äöü ß € 😀\nZeile 2"
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config, clipboard: ClipboardEngine.Config())
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless

    // Session-queue state.
    var logon = FreshLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var ready = false
    var namesCount = 0
    var pasteServed: Int?
    var hostText: (equal: Bool, units: Int, echo: Bool)?
    var terminateReason: UInt8?

    clip.onEvent = { event in
        say("clip: \(event)")
        switch event {
        case .ready: ready = true
        case .formatNames(let entries):
            namesCount = entries.count
            for e in entries { say(String(format: "clip:   name 0x%04X \"%@\" (%ld B)", e.id, e.name, e.raw.count)) }
        case .hostRequest(let format, let served, let bytes) where format == ClipboardFormat.unicodeText && served:
            pasteServed = bytes
        case .hostClipboard(let content, _, let echo):
            if let text = content.text { hostText = (text == testText, text.utf16.count, echo) }
        default: break
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            say("TWI host init")
            if let gap = logon.hostInit() { say(logon.isFresh ? "fresh logon (host init after \(Int(gap)) s)" : "reconnect pattern (host init)") }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, _): windowsSeen.note(w)
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
            say("TWI window \(w.id) removed")
        default: break
        }
    }
    session.onThinwireInit = { info in
        say("Thinwire INIT \(info.width)x\(info.height)")
        if let gap = logon.thinwireInit() { say(logon.isFresh ? "fresh logon (Thinwire INIT after \(Int(gap)) s)" : "reconnect pattern (Thinwire INIT)") }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .suspended(let info): say("CGP suspended: \(info.reason)")
        case .resumed: say("CGP resumed")
        case .wd(let e):
            switch e {
            case .initResponseSent(let modules, _): say("→ INIT_RESPONSE modules \(modules.joined(separator: ", "))")
            case .connected: say("WD connected")
            case .terminate(let reason):
                terminateReason = reason
                say("← TERMINATE reason \(reason)")
            case .droppedChannelData(let channel, let bytes): if channel == ClipboardWire.channelNumber { say("dropped clipboard data \(bytes) B") }
            case .failure(let text): say("WD failure: \(text)")
            default: break
            }
        default: break
        }
    }

    // Ctrl+<key> as scancodes (left Ctrl 0x1D). Input is dropped while suspended.
    func ctrl(_ key: UInt8) {
        session.sendInput { wd in
            wd.keyScancode(0x1D, up: false)
            wd.keyScancode(key, up: false)
            wd.keyScancode(key, up: true)
            wd.keyScancode(0x1D, up: true)
        }
    }

    try await session.start()
    let start = Date()
    let gotReady = await waitFor(session, 90) { ready }
    say(gotReady ? "clipboard channel ready" : "clipboard channel NOT ready after 90 s (no CLIP_INIT, or the module was refused)")
    // The Notepad window, in a session this run logged on itself.
    let notepad: () -> UInt32? = {
        // Notepad by executable, else by the published app's key ("app:Notepad").
        appWindows.first { id in
            if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == "notepad.exe" }
            let key = windowsSeen.appKey(id)?.lowercased() ?? ""
            return key.contains("notepad") || key == "app:editor ekm"
        }
    }
    let found = await waitFor(session, max(5, 120 - Date().timeIntervalSince(start))) { logon.isFresh && notepad() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { notepad() }
    var steps: [String] = []
    if !fresh {
        say("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !gotReady || !found || target == nil {
        say("no Notepad window or no clipboard channel: no input is sent")
    } else if let target {
        say("Notepad window \(target): activating; waiting 3 s")
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // (a) Mac → host: announce the test string, then paste with Ctrl+V.
        await onSession(session) { pasteServed = nil }
        say("(a) announcing the test string (\(testText.utf16.count) UTF-16 units), then Ctrl+V")
        session.clipboardAnnounce(ClipboardSnapshot(content: ClipboardContent(text: testText)))
        try await Task.sleep(nanoseconds: 300_000_000)
        ctrl(0x2F)
        let served = await waitFor(session, 8) { pasteServed != nil }
        let bytes = await onSession(session) { pasteServed }
        steps.append(served ? "paste: host fetched CF_UNICODETEXT (\(bytes ?? 0) B)" : "paste: host did NOT request CF_UNICODETEXT within 8 s")
        say(steps.last!)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // (b) Host → Mac: select all and copy; the eager fetch delivers the text.
        await onSession(session) { hostText = nil }
        say("(b) Ctrl+A, Ctrl+C")
        ctrl(0x1E)
        try await Task.sleep(nanoseconds: 300_000_000)
        ctrl(0x2E)
        _ = await waitFor(session, 10) { hostText != nil }
        if let result = await onSession(session, { hostText }) {
            steps.append("copy: host → client text \(result.equal ? "EQUALS" : "does NOT equal") the test string (\(result.units) units, expected \(testText.utf16.count))\(result.echo ? ", flagged as echo" : "")")
        } else {
            steps.append("copy: no host text within 10 s")
        }
        say(steps.last!)

        // Remove the test text again (Ctrl+A, Delete); nothing is ever saved.
        ctrl(0x1E)
        session.sendInput { wd in
            wd.keyScancodes([0xE0, 0x53], up: false)
            wd.keyScancodes([0xE0, 0x53], up: true)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // End: log off only a fresh session (the unsaved Notepad text is discarded by the logoff; no keys are
    // sent to any "save changes?" prompt). Otherwise disconnect with CGP FINISH.
    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            say("→ TWI LOGOFF")
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            let names = await onSession(session) { windowsSeen.basenames(seamless.model) }
            say("logoff did not end the session in 25 s (windows seen: \(Set(names).sorted().joined(separator: ", "))); disconnecting")
            await session.close()
            ending = sent ? "logoff sent but the session did not end (maybe a save prompt); disconnected" : "TWI not ready; disconnected"
        }
    }
    let summary = await onSession(session) { (clip.version, namesCount, clip.hostFormats) }
    say("\n=== cliptest summary ===")
    say("clipboard ready: \(gotReady), version \(summary.0), host format names: \(summary.1), last host list: \(summary.2.map { clip.label($0) })")
    say("fresh logon: \(fresh)")
    for step in steps { say("  " + step) }
    say("end: \(ending)")
}
