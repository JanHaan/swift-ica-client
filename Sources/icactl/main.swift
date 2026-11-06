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
// The store's device id cookie survives the empty-jar gateway logon (docs/90 §8.6); ICA_NO_DEVICE_ID=1
// turns that off (§11 item 7: is the id new after an empty-jar logon?).
if ProcessInfo.processInfo.environment["ICA_NO_DEVICE_ID"] != "1" {
    StoreClient.deviceIdentity = FileDeviceIdentity(path: sessionDir.appendingPathComponent("device-id.plist").path)
}

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

case "cdmtest":
    // icactl cdmtest [resource] — client drive mapping test, Notepad only (docs/95 "To verify live"): maps a
    // fresh temp folder as drive M and records what the host sends. In a session this run logged on itself:
    // Notepad opens \\Client\M$\cdmtest-probe.txt via Ctrl+O; with ICA_CDMTEST_SAVE=1 also Save As
    // \\Client\M$\cdmtest-saved.txt. Only paths on the mapped drive are ever typed.
    let name = args.first ?? "Notepad"
    guard name == "Notepad" else { fail("cdmtest is limited to \"Notepad\"") }
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        try await runCDMTest(ica: ica, save: ProcessInfo.processInfo.environment["ICA_CDMTEST_SAVE"] == "1")
    } catch {
        fail("\(error)")
    }

case "printtest":
    // icactl printtest [resource] — client printing test, Notepad only (docs/97 §10 L1–L5): announces the PDF-mode
    // CTXCPM module and logs every host command. In a session this run logged on itself: types a test line in
    // Notepad, Ctrl+P, saves a framebuffer screenshot of the print dialog to .session/printtest-dialog.png; only
    // with ICA_PRINTTEST_CONFIRM=1 and .session/printtest-confirm-<runid> created after that screenshot (the run id is
    // logged) presses Enter and saves the job to .session/printtest.pdf, otherwise Esc. No Ctrl+P at all unless the
    // host sent an ENUM and a *PDF* printer/driver name over CTXCPM (PrintTestGate). Never saves the document.
    let name = args.first ?? "Notepad"
    guard name == "Notepad" else { fail("printtest is limited to \"Notepad\"") }
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        try await runPrintTest(ica: ica, confirm: ProcessInfo.processInfo.environment["ICA_PRINTTEST_CONFIRM"] == "1")
    } catch {
        fail("\(error)")
    }

case "audiotest":
    // icactl audiotest [resource] — client audio test, Notepad only (docs/98 §14 L1–L5, §13): announces the
    // 55-byte CTXCAM module (playback only, caps 0x10; the microphone is never opened) and logs everything on
    // ch 19: INIT, the credits we send, the host's format list and our reply. In a session this run logged on
    // itself it makes Notepad play the "cannot find" sound with keys only (Ctrl+F, "zzqxj", Enter, then Esc,
    // Esc) and writes the decoded audio to .session/audiotest.wav. Plays nothing aloud unless
    // ICA_AUDIOTEST_PLAY=1. Never saves the document; logs off only its own fresh session.
    // "Sound ABC" / "Sound XYZ" (the Windows Sound control panel): screenshot of its window to
    // .session/audiotest-sound-0.png; only with ICA_AUDIOTEST_KEYS (e.g. "ctrl+tab,tab,alt+t") exactly those keys,
    // 1.5 s apart, a screenshot after each (-<n>.png). No other input; Enter/Space only if written in the sequence.
    let name = args.first ?? "Notepad"
    let soundApps = ["Sound ABC", "Sound XYZ"]
    guard name == "Notepad" || soundApps.contains(name) else {
        fail("audiotest is limited to \"Notepad\", \"Sound ABC\" and \"Sound XYZ\"")
    }
    let keysText = soundApps.contains(name) ? ProcessInfo.processInfo.environment["ICA_AUDIOTEST_KEYS"] : nil
    if !soundApps.contains(name), ProcessInfo.processInfo.environment["ICA_AUDIOTEST_KEYS"] != nil {
        fail("ICA_AUDIOTEST_KEYS applies only to the Sound apps")
    }
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        // Validate the sequence before anything is launched (layout-independent check; the real parse uses the
        // session's layout below).
        if let keysText { _ = try AudioTestKeys.parse(keysText, keyboardLayout: 0x0409) }
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        let keys = try keysText.map { try AudioTestKeys.parse($0, keyboardLayout: WDLogon(ica: ica).keyboardLayout) }
        try await runAudioTest(ica: ica, play: ProcessInfo.processInfo.environment["ICA_AUDIOTEST_PLAY"] == "1",
                               soundApp: soundApps.contains(name) ? name : nil, keys: keys)
    } catch {
        fail("\(error)")
    }

case "sessions":
    // icactl sessions list|probe|disconnect|logoff|reconnect|disconnect-device|logoff-device (docs/90)
    await sessionsCommand(args)

case "resources":
    // icactl resources [filter] — read-only store resource list (names, optionally filtered, case-insensitive).
    let filter = args.first?.lowercased()
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        let names = resources.map(\.name).filter { filter == nil || $0.lowercased().contains(filter!) }.sorted()
        print("\(names.count) of \(resources.count) resources")
        names.forEach { print("  \($0)") }
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
      icactl cdmtest                     drive mapping test in "Notepad": temp folder as M:, Notepad opens a file
                                         from it (ICA_CDMTEST_SAVE=1: also Save As into it); fresh session only
      icactl printtest                   printing test in "Notepad": host commands, Ctrl+P, dialog screenshot to
                                         .session/printtest-dialog.png, then Esc; ICA_PRINTTEST_CONFIRM=1: Enter only once
                                         .session/printtest-confirm-<runid> appears (120 s), job to .session/printtest.pdf
      icactl audiotest [resource]        audio test in "Notepad": CTXCAM log (INIT, credits, formats), Notepad's
                                         "cannot find" sound via keys, decoded audio to .session/audiotest.wav; never
                                         opens the microphone; ICA_AUDIOTEST_PLAY=1 also plays it aloud
                                         "Sound ABC"/"Sound XYZ": window screenshot .session/audiotest-sound-0.png; keys
                                         only from ICA_AUDIOTEST_KEYS="ctrl+tab,tab,alt+t" (1.5 s apart, screenshot each)
      icactl sessions list [--names]     store sessions (Sessions/List + ListAvailable), read-only; ids as fingerprints
      icactl sessions probe              read-only live checks of docs/90 §11 items 1, 2, 4–7 (keys, counts, states)
      icactl sessions disconnect <id>    Sessions/DisconnectSessions; only sessions whose apps are all test resources
      icactl sessions logoff <id>        Sessions/LogOffSessions; same gate
      icactl sessions reconnect <id>     launch the session's ListAvailable entry (excludeActive) and run it like `session`
      icactl sessions disconnect-device  device-wide Sessions/Disconnect (ICA_ALLOW_DEVICE_WIDE=1, every session of
      icactl sessions logoff-device        this device must be a test session); …/Logoff likewise

    ICA_TEST_RESOURCES=<name>[,<name>]   apps the sessions commands may act on: "Calculator,Notepad"; another
                                         list only together with ICA_ALLOW_ANY_RESOURCE=1
    ICA_SESSION_END=disconnect           session/droptest/reconnect: end with CGP FINISH (disconnect), never log off

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
    // docs/90 §11 item 3: key only, never the value.
    say("ICA file: ClientName key \(ica["ClientName"].map { $0.isEmpty ? "empty" : "present" } ?? "absent")")
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
    if !session.isClosed, ProcessInfo.processInfo.environment["ICA_SESSION_END"] == "disconnect" {
        say("ICA_SESSION_END=disconnect: disconnecting (CGP FINISH), no logoff")
        await session.close()
        ending = "disconnected (CGP FINISH, ICA_SESSION_END=disconnect)"
    } else if !session.isClosed, !session.isEstablished {
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
        let scratch = NotepadScratch(session: session, target: target)
        if try await scratch.open() {

            // (a) Mac → host: announce the test string, then paste with Ctrl+V.
            await onSession(session) { pasteServed = nil }
            say("(a) announcing the test string (\(testText.utf16.count) UTF-16 units), then Ctrl+V")
            session.clipboardAnnounce(ClipboardSnapshot(content: ClipboardContent(text: testText)))
            try await Task.sleep(nanoseconds: 300_000_000)
            ctrl(0x2F)
            scratch.markTyped()
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
            steps.append(try await scratch.clear())
            say(steps.last!)
        } else {
            steps.append("Ctrl+N: an unexpected window appeared; Esc, no further input")
            say(steps.last!)
        }
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

// MARK: - Sessions command (docs/90)

func storeClient() -> StoreClient { StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL) }

/// Client names our sessions report to the VDA: the WD default, and the last saved ICA file's.
func ourClientNames() -> Set<String> {
    var names: Set<String> = [SessionDirectory.defaultClientName]
    let last = sessionDir.appendingPathComponent("last.ica").path
    if let text = try? String(contentsOfFile: last, encoding: .utf8), let ica = ICAFile(text: text) {
        names.insert(WDLogon(ica: ica).clientName)
    }
    return names
}

func describe(_ s: StoreSessionInfo, list: StoreSessionList, names: Bool) -> String {
    let where_: String = switch SessionDirectory.state(of: s, deviceId: list.deviceId, clientNames: ourClientNames()) {
    case .connectedHere: "this device"
    case .connectedElsewhere(let client, let type):
        (names ? (client ?? "?") : "other device") + (type.map { " (\($0))" } ?? "")
    case .disconnected: names ? "last on \(s.clientName ?? "?")" : "-"
    case .unknown: "?"
    }
    let started = s.sessionStartTime.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
    return "\(s.shortId)  \(s.connectionState.name.padding(toLength: 12, withPad: " ", startingAt: 0))  \(where_)  "
        + "apps: \(s.appNames.joined(separator: ", "))  started \(started)  \(s.userSessionType ?? "")"
}

/// The one session whose id or fingerprint is `key`.
func findSession(_ key: String, in list: StoreSessionList) -> StoreSessionInfo {
    let matches = list.sessions.filter { $0.sessionId == key || $0.shortId == key.lowercased() }
    guard matches.count == 1 else { fail(matches.isEmpty ? "no session \(key) (see icactl sessions list)" : "\(key) is ambiguous") }
    return matches[0]
}

func sessionsCommand(_ args: [String]) async {
    var args = args
    let sub = args.isEmpty ? "list" : args.removeFirst()
    let store = storeClient()
    let api = store.sessions
    api.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    let allowed = TestSessionGate.allowedNames()
    do {
        switch sub {
        case "list":
            let names = args.contains("--names")
            // Resources/List first: it signs in to the store if needed (and learns the session paths).
            _ = try await store.resources()
            let list: StoreSessionList?
            do { list = try await api.list() } catch {
                print("Sessions/List: \(error)")
                list = nil
            }
            let all = try await api.available(excludeActive: false)
            let safe = try? await api.available(excludeActive: true)
            try http.saveCookies(to: cookiePath)
            if let list {
                print("Sessions/List: \(list.sessions.count) session(s), device \(list.deviceId.map(StoreSessionInfo.fingerprint) ?? "none")")
                for s in list.sessions { print("  " + describe(s, list: list, names: names)) }
            }
            print("ListAvailable: \(all.count) entr\(all.count == 1 ? "y" : "ies"), \(safe.map { "\($0.count)" } ?? "?") excluding active")
            for row in SessionDirectory.merge(list: list, available: all, excludingActive: safe, clientNames: ourClientNames())
            where row.reconnect != nil || row.takeOver != nil || row.joinAmbiguous {
                let entry = row.reconnect ?? row.takeOver
                print("  \(entry.map { StoreSessionInfo.fingerprint($0.launchId) } ?? "-")  \(row.initialApp ?? "?")  "
                      + (row.reconnect != nil ? "reconnect" : row.takeOver != nil ? "take over (open elsewhere)" : "")
                      + (row.joinAmbiguous ? " (join ambiguous: reconnect all only)" : "")
                      + "  → session \(row.id.map(StoreSessionInfo.fingerprint) ?? "not in Sessions/List")")
            }

        case "probe":
            try await probe(store: store, api: api)

        case "disconnect", "logoff":
            guard let key = args.first else { fail("usage: icactl sessions \(sub) <id>") }
            let resources = try await store.resources()
            let list = try await api.list()
            let target = findSession(key, in: list)
            guard TestSessionGate.allows(target, allowed: allowed, resources: resources) else {
                fail("refused: session \(target.shortId) has apps [\(TestSessionGate.resolvedNames(target, resources: resources).joined(separator: ", "))]; "
                     + "only sessions whose apps are all in ICA_TEST_RESOURCES (\(allowed.joined(separator: ","))) may be touched")
            }
            print("\(sub) \(target.shortId) (\(target.connectionState.name), apps \(target.appNames.joined(separator: ", ")))")
            let results = sub == "disconnect" ? try await api.disconnect(ids: [target.sessionId]) : try await api.logOff(ids: [target.sessionId])
            for r in results {
                print("  result \(StoreSessionInfo.fingerprint(r.sessionId)): isSuccess \(r.isSuccess)\(r.failureReason.map { ", failureReason \($0)" } ?? "")")
            }
            if results.isEmpty { print("  result: no entries") }
            let after = try await api.list()
            let now = after.sessions.first { $0.sessionId == target.sessionId }
            print("  now: \(now.map(\.connectionState.name) ?? "gone from Sessions/List")")
            try http.saveCookies(to: cookiePath)

        case "reconnect":
            guard let key = args.first else { fail("usage: icactl sessions reconnect <id>") }
            let resources = try await store.resources()
            let list = try await api.list()
            let target = findSession(key, in: list)
            guard TestSessionGate.allows(target, allowed: allowed, resources: resources) else {
                fail("refused: session \(target.shortId) is not a test session (apps \(target.appNames.joined(separator: ", ")))")
            }
            // excludeActive: never take a session away from another device (docs/90 §4.1).
            let safe = try await api.available(excludeActive: true)
            let all = try await api.available(excludeActive: false)
            let rows = SessionDirectory.merge(list: list, available: all, excludingActive: safe, clientNames: ourClientNames())
            guard let row = rows.first(where: { $0.id == target.sessionId }) else { fail("session vanished") }
            if row.joinAmbiguous { fail("refused: several sessions match its ListAvailable entry (docs/90 §7.2)") }
            guard let entry = row.reconnect else {
                fail(row.takeOver != nil ? "refused: the session is open on another device; icactl never takes over"
                                         : "no ListAvailable entry for this session (connected here, or not joinable)")
            }
            guard TestSessionGate.allows(entry, allowed: allowed) else { fail("refused: entry's initial app is not a test resource") }
            print("reconnecting \(target.shortId) via entry \(StoreSessionInfo.fingerprint(entry.launchId)) (\(entry.initialapp ?? "?"))")
            guard let ica = ICAFile(text: try await store.launchICA(entry.resource)) else { fail("not an ICA file") }
            try http.saveCookies(to: cookiePath)
            let seconds = Double(ProcessInfo.processInfo.environment["ICA_DUMP_SECONDS"] ?? "") ?? 20
            let dir = sessionDir.appendingPathComponent("reconnect")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try await runSession(ica: ica, seconds: seconds, captureDir: dir)

        case "disconnect-device", "logoff-device":
            guard ProcessInfo.processInfo.environment["ICA_ALLOW_DEVICE_WIDE"] == "1" else {
                fail("device-wide calls need ICA_ALLOW_DEVICE_WIDE=1 (docs/90 §11 item 14: only after items 7 and 8)")
            }
            let resources = try await store.resources()
            let isOurs: (StoreSessionInfo) -> Bool = { TestSessionGate.allows($0, allowed: allowed, resources: resources) }
            let status = sub == "disconnect-device"
                ? try await api.disconnectDevice(clientNames: ourClientNames(), isOurs: isOurs)
                : try await api.logOffDevice(clientNames: ourClientNames(), isOurs: isOurs)
            print("\(sub): status \(status)")
            try http.saveCookies(to: cookiePath)

        default:
            fail("usage: icactl sessions list|probe|disconnect <id>|logoff <id>|reconnect <id>|disconnect-device|logoff-device")
        }
    } catch {
        fail("\(error)")
    }
}

/// docs/90 §11 items 1, 2, 4–7: names, keys, counts, states and status codes only.
func probe(store: StoreClient, api: StoreSessions) async throws {
    // 1. Home/Configuration (through the store sign-in, which also records the session paths).
    try await store.signIn()
    let config = try await http.send("POST", URL(string: "Home/Configuration", relativeTo: store.base)!,
                                     headers: ["X-Citrix-IsUsingHTTPS": "Yes", "X-Requested-With": "XMLHttpRequest",
                                               "Accept": "*/*", "Csrf-Token": http.cookie("CsrfToken") ?? ""], form: nil)
    print("1. Home/Configuration \(config.status)")
    for element in ["sessionsProxy", "sessionControlProxy", "workspaceControl", "machinesProxy"] {
        if let range = config.text.range(of: "<\(element)[\\s/>][^>]*>", options: .regularExpression) {
            print("   " + redact(String(config.text[range])))
        } else {
            print("   <\(element)> absent")
        }
    }
    let endpoints = SessionEndpoints(configuration: config.text)
    print("   paths: list \(endpoints.list ?? "none"), available \(endpoints.listAvailable), by-id \(endpoints.disconnectSessions ?? "none")/\(endpoints.logOffSessions ?? "none")")
    // 2. Cookie names.
    let names = http.cookieNames
    print("2. cookies: \(names.joined(separator: ", ")); CtxsDeviceId \(names.contains(DeviceIdentity.cookieName) ? "present" : "absent")")
    print("3. ClientName key: see `ICA file: ClientName key` in the output of `icactl session`")
    // 4. Sessions/List.
    func listCheck(_ label: String) async throws -> StoreSessionList? {
        let (response, method, form) = try await api.probe(.list)
        print("\(label) Sessions/List \(method) → \(response.status), headers \(form?.rawValue ?? "refused")")
        guard response.status == 200 else { return nil }
        print("   keys: \(SessionsJSON.keyPaths(response.body).joined(separator: " "))")
        let list = try SessionsJSON.sessionList(response.body)
        let counts = Dictionary(grouping: list.sessions, by: \.connectionState.name).map { "\($0.key) \($0.value.count)" }.sorted()
        print("   \(list.sessions.count) session(s): \(counts.joined(separator: ", ")); device \(list.deviceId.map(StoreSessionInfo.fingerprint) ?? "none")")
        return list
    }
    let before = try await listCheck("4.")
    // 5. ListAvailable, both forms; no entry is launched.
    for exclude in [true, false] {
        let (response, _, form) = try await api.probe(.available(excludeActive: exclude))
        let count = (try? SessionsJSON.available(response.body).count).map(String.init) ?? "-"
        print("5. ListAvailable\(exclude ? " excludeActive=true" : "") → \(response.status) (\(form?.rawValue ?? "refused")), "
              + "\(response.body.count) B, \(count) entries; keys: \(SessionsJSON.keyPaths(response.body).joined(separator: " "))")
    }
    let after = try await listCheck("5. again:")
    if let before, let after {
        let changed = before.sessions.filter { b in after.sessions.first { $0.sessionId == b.sessionId }?.connectionState != b.connectionState }
        print("   state changes after listing: \(changed.count)")
    }
    // 6. App ids vs resource ids.
    let resources = try await store.resources()
    if let list = after ?? before {
        let apps = list.sessions.flatMap(\.applications)
        let joined = apps.filter { a in a.id.map { id in resources.contains { $0.id == id } } ?? false }
        print("6. applications[].id equal to a Resources/List id: \(joined.count) of \(apps.count)")
    }
    // 7. Device id across a second sign-in in the same jar.
    try await store.signIn()
    let again = try? await api.list()
    let first = (after ?? before)?.deviceId
    print("7. deviceId after a second sign-in: \(first == nil || again?.deviceId == nil ? "not comparable" : first == again?.deviceId ? "same" : "different")"
          + " (fingerprint \(again?.deviceId.map(StoreSessionInfo.fingerprint) ?? "none"); compare after `icactl login`, with ICA_NO_DEVICE_ID=1 for an empty jar)")
    try http.saveCookies(to: cookiePath)
}

// MARK: - Drive mapping test (docs/95 "To verify live")

func runCDMTest(ica: ICAFile, save: Bool) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let probeText = "CTXCDM-Test äöü \(UUID().uuidString)\r\n"
    // A fresh, empty folder: the only thing the session can reach.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ica-cdmtest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data(probeText.utf8).write(to: root.appendingPathComponent("cdmtest-probe.txt"))
    say("shared folder: \(root.path) as M:")
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let fs = try CDMPOSIXFileSystem(root: root, readOnly: false)
    fs.quarantineAgent = "icactl"
    let session = try ICASession(ica: ica, configuration: config, clipboard: nil,
                                 cdm: CDMEngine.Config(fileSystem: fs, letter: "M", label: "cdmtest"))
    guard let cdm = session.cdm else { fail("no CDM engine") }
    let seamless = session.seamless

    // Session-queue state.
    var logon = FreshLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var operations: [String] = []
    var protocolError: String?
    var terminateReason: UInt8?
    var channelBytes = 0

    cdm.onEvent = { event in
        say("cdm: \(event)")
        switch event {
        case .operation(let line): operations.append(line)
        case .protocolError(let text): protocolError = text
        case .stopped: break
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(logon.isFresh ? "fresh logon (host init after \(Int(gap)) s)" : "reconnect pattern (host init)") }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, _):
            windowsSeen.note(w)
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
        default: break
        }
    }
    session.onThinwireInit = { info in
        if let gap = logon.thinwireInit() { say(logon.isFresh ? "fresh logon (Thinwire INIT after \(Int(gap)) s)" : "reconnect pattern (Thinwire INIT)") }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(let e):
            switch e {
            case .initResponseSent(let modules, _): say("→ INIT_RESPONSE modules \(modules.joined(separator: ", "))")
            case .connected: say("WD connected")
            case .packet(let p) where p.channel == CDMWire.channelNumber: channelBytes += p.payload.count
            case .terminate(let reason):
                terminateReason = reason
                say("← TERMINATE reason \(reason)")
            case .failure(let text): say("WD failure: \(text)")
            default: break
            }
        default: break
        }
    }

    func key(_ code: UInt8, ctrl: Bool = false, shift: Bool = false) {
        session.sendInput { wd in
            if ctrl { wd.keyScancode(0x1D, up: false) }
            if shift { wd.keyScancode(0x2A, up: false) }
            wd.keyScancode(code, up: false)
            wd.keyScancode(code, up: true)
            if shift { wd.keyScancode(0x2A, up: true) }
            if ctrl { wd.keyScancode(0x1D, up: true) }
        }
    }
    func type(_ text: String) {
        session.sendInput { wd in
            for unit in text.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
        }
    }
    func sawOperation(_ prefix: String, _ name: String) -> () -> Bool {
        { operations.contains { $0.hasPrefix(prefix) && $0.contains(name) } }
    }

    try await session.start()
    let start = Date()
    // Items 1–3: CONNECT and what follows without any user action.
    let connected = await waitFor(session, 90) { operations.contains { $0.hasPrefix("CONNECT") } }
    say(connected ? "CDM CONNECT received" : "no CDM CONNECT within 90 s (module refused, or drive mapping disabled by policy)")
    if connected { try await Task.sleep(nanoseconds: 20_000_000_000) }
    let unprompted = await onSession(session) { operations }
    let notepad: () -> UInt32? = {
        appWindows.first { id in
            if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == "notepad.exe" }
            let key = windowsSeen.appKey(id)?.lowercased() ?? ""
            return key.contains("notepad") || key == "app:editor ekm"
        }
    }
    let found = await waitFor(session, max(5, 150 - Date().timeIntervalSince(start))) { logon.isFresh && notepad() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { notepad() }
    var steps: [String] = []
    if !fresh {
        say("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !connected || !found || target == nil {
        say("no Notepad window or no CDM channel: no input is sent")
    } else if let target {
        let scratch = NotepadScratch(session: session, target: target)
        if try await scratch.open() {
            // (a) Open the probe file from the mapped drive (UNC: the letter is not preserved by default, §A.6).
            say("(a) Ctrl+O, \\\\Client\\M$\\cdmtest-probe.txt, Enter")
            key(0x18, ctrl: true)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            type("\\\\Client\\M$\\cdmtest-probe.txt")
            key(0x1C)
            let read = await waitFor(session, 20) { operations.contains { $0.hasPrefix("CLOSE") && $0.contains("cdmtest-probe.txt: read") && !$0.contains("read 0 B") } }
            steps.append(read ? "open: Notepad read the probe file over CDM" : "open: no read of the probe file within 20 s")
            say(steps.last!)
            if !read { key(0x01); key(0x01) }  // Escape any error box and the dialog
            try await Task.sleep(nanoseconds: 2_000_000_000)
            // (b) Save As into the mapped drive (only with ICA_CDMTEST_SAVE=1).
            if save && read {
                say("(b) Ctrl+Shift+S, \\\\Client\\M$\\cdmtest-saved.txt, Enter")
                key(0x1F, ctrl: true, shift: true)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                type("\\\\Client\\M$\\cdmtest-saved.txt")
                key(0x1C)
                _ = await waitFor(session, 20, sawOperation("CLOSE", "cdmtest-saved.txt"))
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let saved = root.appendingPathComponent("cdmtest-saved.txt")
                let text = (try? Data(contentsOf: saved)).map { String(decoding: $0, as: UTF8.self) }
                let quarantined = getxattr(saved.path, CDMPOSIXFileSystem.quarantineName, nil, 0, 0, XATTR_NOFOLLOW) > 0
                steps.append(text == nil ? "save: no file arrived" :
                    "save: file arrived, \(text == probeText ? "content EQUALS the probe" : "content differs (\(text!.utf8.count) B)"), quarantine \(quarantined ? "set" : "MISSING")")
                say(steps.last!)
                if text == nil { key(0x01); key(0x01) }
            }
        } else {
            steps.append("Ctrl+N: an unexpected window appeared; Esc, no further input")
            say(steps.last!)
        }
    }

    // End: log off only a fresh session; otherwise disconnect (CGP FINISH).
    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            await session.close()
            ending = "logoff did not end the session in 25 s; disconnected"
        }
    }
    let summary = await onSession(session) { (operations, protocolError, channelBytes, cdm.requestsServed) }
    say("\n=== cdmtest summary ===")
    say("CONNECT: \(connected); requests served: \(summary.3); host bytes on ch 10: \(summary.2)")
    say("unprompted requests (first 20 s): \(unprompted.count)")
    for line in unprompted.prefix(40) { say("  " + line) }
    var counts: [String: Int] = [:]
    for line in summary.0 { counts[String(line.prefix { $0 != " " }), default: 0] += 1 }
    say("by command: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    say("protocol error: \(summary.1 ?? "none")")
    say("fresh logon: \(fresh)")
    for step in steps { say("  " + step) }
    say("end: \(ending)")
    try? FileManager.default.removeItem(at: root)
}

// MARK: - Printing test (docs/97 §10)

func runPrintTest(ica: ICAFile, confirm: Bool) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let dialogPNG = sessionDir.appendingPathComponent("printtest-dialog.png")
    let jobPDF = sessionDir.appendingPathComponent("printtest.pdf")
    for url in [dialogPNG, jobPDF] { try? FileManager.default.removeItem(at: url) }
    let runID = PrintTestGate.newRunID()
    say("run \(runID); confirm: \(confirm ? "possible (Enter only with \(PrintTestGate.confirmFileName(runID: runID)) created after the screenshot)" : "no (screenshot, then Esc)")")
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config, clipboard: nil, cdm: nil, printing: PrinterEngine.Config())
    guard let printer = session.printer else { fail("no printing engine") }
    let seamless = session.seamless

    // Session-queue state.
    var logon = FreshLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var windowsAdded: [(id: UInt32, kind: TWIWindowKind, title: String)] = []
    var commandLines: [String] = []
    var jobs: [PrintJob] = []
    var refused: [String] = []
    var terminateReason: UInt8?
    var channelBytes = 0
    var channelWrites = 0
    var firstHostCommand: Date?

    printer.onEvent = { event in
        say("cpm: \(event)")
        switch event {
        case .command(let line):
            if firstHostCommand == nil { firstHostCommand = Date() }
            commandLines.append(line)
        case .job(let job): jobs.append(job)
        case .jobRefused(let id, let reason): refused.append("job \(id): \(reason)")
        case .stopped: break
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(logon.isFresh ? "fresh logon (host init after \(Int(gap)) s)" : "reconnect pattern (host init)") }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            windowsAdded.append((w.id, w.kind, w.title))
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, _):
            windowsSeen.note(w)
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
        default: break
        }
    }
    session.onThinwireInit = { info in
        if let gap = logon.thinwireInit() { say(logon.isFresh ? "fresh logon (Thinwire INIT after \(Int(gap)) s)" : "reconnect pattern (Thinwire INIT)") }
    }
    let started = Date()
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(let e):
            switch e {
            case .initResponseSent(let modules, _): say("→ INIT_RESPONSE modules \(modules.joined(separator: ", "))")
            case .initConnect(let remaining, let moduleClass, let payload):
                say("← INIT_CONNECT remaining \(remaining) class \(moduleClass) (\(payload.count) B)")
            case .connected: say("WD connected")
            case .packet(let p) where p.channel == PrinterWire.channelNumber:
                if channelWrites == 0 { say(String(format: "first host write on ch 4 after %.1f s: %@", Date().timeIntervalSince(started), hexLine(p.payload, limit: 32))) }
                channelWrites += 1
                channelBytes += p.payload.count
            case .droppedChannelData(let channel, let bytes): say("dropped \(bytes) B on unregistered ch \(channel)")
            case .terminate(let reason):
                terminateReason = reason
                say("← TERMINATE reason \(reason)")
            case .failure(let text): say("WD failure: \(text)")
            default: break
            }
        default: break
        }
    }

    func key(_ code: UInt8, ctrl: Bool = false) {
        session.sendInput { wd in
            if ctrl { wd.keyScancode(0x1D, up: false) }
            wd.keyScancode(code, up: false)
            wd.keyScancode(code, up: true)
            if ctrl { wd.keyScancode(0x1D, up: true) }
        }
    }
    func type(_ text: String) {
        session.sendInput { wd in
            for unit in text.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
        }
    }
    /// Framebuffer PNG (0600) after a full redraw request.
    func screenshot(_ url: URL) async -> Bool {
        session.send { wd, _ in wd.redraw() }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return await onSession(session) {
            guard let fb = session.thinwire.framebuffer, fb.writePNG(to: url) else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        }
    }

    try await session.start()
    let notepad: () -> UInt32? = {
        appWindows.first { id in
            if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == "notepad.exe" }
            let key = windowsSeen.appKey(id)?.lowercased() ?? ""
            return key.contains("notepad") || key == "app:editor ekm"
        }
    }
    // L1/L2: what the host sends on ch 4 without any print (it should speak first, at session start).
    let found = await waitFor(session, 150) { logon.isFresh && notepad() != nil }
    try await Task.sleep(nanoseconds: 5_000_000_000)
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { notepad() }
    let atStart = await onSession(session) { commandLines }
    say("host commands before any print: \(atStart.count)")
    var steps: [String] = []
    if !fresh {
        say("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !found || target == nil {
        say("no Notepad window: no input is sent")
    } else if let target, case .refuse(let why) = await onSession(session, {
        PrintTestGate.mayOpenDialog(enumCount: printer.commandCounts["ENUM"] ?? 0, hostNames: printer.hostNames)
    }) {
        // Gate 1: without the host's PDF printer on CTXCPM, Enter in a dialog could print on paper: no Ctrl+P at all.
        steps.append("gate: \(why); no Ctrl+P, Esc only")
        say(steps.last!)
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        key(0x01)
    } else if let target {
        let scratch = NotepadScratch(session: session, target: target)
        if try await scratch.open() {
            let line = "CTXCPM printtest " + ISO8601DateFormatter().string(from: Date())
            say("(a) type a test line (\(line.count) chars), Ctrl+P")
            type(line)
            scratch.markTyped()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let before = await onSession(session) { Set(windowsAdded.map(\.id)) }
            key(0x19, ctrl: true)
            let dialog = await waitFor(session, 20) { windowsAdded.contains { !before.contains($0.id) && $0.kind == .appWindow } }
            let added = await onSession(session) { windowsAdded.filter { !before.contains($0.id) } }
            say("windows after Ctrl+P: " + added.map { "\($0.id) \($0.kind) \"\($0.title)\"" }.joined(separator: ", "))
            if !dialog {
                steps.append("dialog: no new window within 20 s after Ctrl+P; nothing pressed")
                say(steps.last!)
            } else {
                try await Task.sleep(nanoseconds: 4_000_000_000)   // let the dialog load its printer list and paint
                let shot = await screenshot(dialogPNG) ? Date() : nil
                steps.append(shot != nil ? "dialog: screenshot saved to \(dialogPNG.path)" : "dialog: screenshot FAILED (no framebuffer)")
                say(steps.last!)
                // Gate 2: a confirmation file for THIS run, created after the orchestrator viewed THIS screenshot.
                let confirmFile = sessionDir.appendingPathComponent(PrintTestGate.confirmFileName(runID: runID))
                var created: Date?
                if confirm, shot != nil {
                    say("waiting up to \(Int(PrintTestGate.confirmTimeout)) s for \(confirmFile.path) (run \(runID)); create it only after checking "
                        + "that \(dialogPNG.lastPathComponent) shows the client PDF printer selected")
                    let deadline = Date().addingTimeInterval(PrintTestGate.confirmTimeout)
                    while Date() < deadline, !session.isClosed {
                        if let date = PrintTestGate.confirmationDate(at: confirmFile) { created = date; break }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                let dialogGate = await onSession(session) {
                    PrintTestGate.mayOpenDialog(enumCount: printer.commandCounts["ENUM"] ?? 0, hostNames: printer.hostNames)
                }
                let decision = PrintTestGate.mayConfirm(confirmEnv: confirm, dialogGate: dialogGate, screenshotSaved: shot, confirmCreated: created)
                if decision == .proceed {
                    say("(b) Enter in the print dialog (confirmed for run \(runID))")
                    key(0x1C)
                    let got = await waitFor(session, 90) { !jobs.isEmpty || !refused.isEmpty }
                    if let job = await onSession(session, { jobs.first }) {
                        FileManager.default.createFile(atPath: jobPDF.path, contents: job.data, attributes: [.posixPermissions: 0o600])
                        switch PrintDocument.inspect(job.data) {
                        case .success(let info):
                            steps.append("job \(job.id): \(job.data.count) B in \(job.writes) writes, printer \"\(job.printerName)\"; PDF \(info.pageCount) page(s), "
                                         + "%%EOF \(info.hasEOF ? "yes" : "no"), title \(info.title?.count ?? 0) chars, producer \(info.producerLength) chars; saved to \(jobPDF.path)")
                        case .failure(let why):
                            steps.append("job \(job.id): \(job.data.count) B, NOT a usable PDF (\(why)); head \(hexLine([UInt8](job.data.prefix(16)), limit: 16)); saved to \(jobPDF.path)")
                        }
                    } else {
                        steps.append(got ? "job: refused (\(await onSession(session) { refused }.joined(separator: "; ")))" : "job: none within 90 s")
                        key(0x01)   // close a dialog that may still be open
                    }
                    say(steps.last!)
                } else {
                    if case .refuse(let why) = decision { say("not confirmed: \(why)") }
                    say("(b) Esc (no print)")
                    key(0x01)
                }
                try? FileManager.default.removeItem(at: confirmFile)
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            steps.append(try await scratch.clear())
            say(steps.last!)
        } else {
            steps.append("Ctrl+N: an unexpected window appeared; Esc, no further input")
            say(steps.last!)
        }
    }

    // End: log off only a fresh session (the unsaved Notepad text is discarded by the logoff); otherwise
    // disconnect with CGP FINISH.
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
            await session.close()
            ending = sent ? "logoff sent but the session did not end in 25 s (maybe a save prompt); disconnected" : "TWI not ready; disconnected"
        }
    }
    let summary = await onSession(session) {
        (commandLines, printer.commandCounts, printer.bytesAcknowledged, channelBytes, channelWrites, refused, firstHostCommand)
    }
    say("\n=== printtest summary ===")
    say("CTXCPM: host writes \(summary.4), \(summary.3) B; acknowledged \(summary.2) B; first command "
        + (summary.6.map { String(format: "after %.1f s", $0.timeIntervalSince(started)) } ?? "never"))
    say("by command: " + summary.1.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    for line in summary.0.prefix(60) { say("  " + line) }
    for line in summary.5 { say("  dropped " + line) }
    say("fresh logon: \(fresh)")
    for step in steps { say("  " + step) }
    say("end: \(ending)")
}

// MARK: - Audio test (docs/98 §14)

func runAudioTest(ica: ICAFile, play: Bool, soundApp: String? = nil, keys: [AudioTestKeyStep]? = nil) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let wavURL = sessionDir.appendingPathComponent("audiotest.wav")
    if let old = try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) {
        for url in old where url.lastPathComponent.hasPrefix("audiotest") && ["wav", "png"].contains(url.pathExtension) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    if let soundApp {
        say("resource \(soundApp): " + (keys.map { "keys \($0.map(\.description).joined(separator: ", "))" } ?? "no ICA_AUDIOTEST_KEYS: screenshot only, no input"))
    }
    let observe = env["ICA_AUDIOTEST_OBSERVE"].flatMap(Double.init) ?? 60
    var audioConfig = AudioEngine.Config()
    audioConfig.codecs = AudioSettings.load(env: env).codecs   // ICA_AUDIO_CODECS=pcm limits the CAPINFO reply
    audioConfig.capabilities = AudioWire.Caps.playback   // never the microphone bit
    say("audio: codecs \(audioConfig.codecs.map(\.rawValue).sorted().joined(separator: ",")); Opus decoder listed \(OpusSupport.systemDecoderListed), "
        + "decodable subformats [\(audioConfig.opusSubformats.sorted().map { String(format: "0x%02x", $0) }.joined(separator: " "))]; "
        + "caps 0x\(String(audioConfig.capabilities, radix: 16)) (no microphone); playback \(play ? "aloud + WAV" : "WAV only")")
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config, clipboard: nil, cdm: nil, printing: nil, audio: audioConfig)
    guard let audio = session.audio else { fail("no audio engine") }
    let writer = AudioWAVWriter(url: wavURL)
    let player: AudioPlayer? = play ? AudioPlayer() : nil
    player?.log = { say("audio out: \($0)") }
    audio.sink = player.map { AudioSinkGroup([writer, $0]) } ?? writer
    let seamless = session.seamless

    // Session-queue state.
    var logon = FreshLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var windowsAdded: [(id: UInt32, kind: TWIWindowKind, title: String)] = []
    var commandLines: [String] = []
    var terminateReason: UInt8?
    var initResponseAt: Date?
    var connectedAt: Date?
    var vcPriority: [UInt8]?
    var bindEntryInWD = false
    var modulesSent: [String] = []

    audio.onEvent = { event in
        say("cam: \(event)")
        if case .command(let line) = event { commandLines.append(line) }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(logon.isFresh ? "fresh logon (host init after \(Int(gap)) s)" : "reconnect pattern (host init)") }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            windowsAdded.append((w.id, w.kind, w.title))
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, _):
            windowsSeen.note(w)
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(logon.isFresh ? "fresh logon (Thinwire INIT after \(Int(gap)) s)" : "reconnect pattern (Thinwire INIT)") }
    }
    let started = Date()
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(let e):
            switch e {
            case .initResponseSent(let modules, _):
                initResponseAt = Date()
                modulesSent = modules
                say("→ INIT_RESPONSE modules \(modules.joined(separator: ", "))")
            case .initConnect(let remaining, let moduleClass, let payload):
                say("← INIT_CONNECT remaining \(remaining) class \(moduleClass) (\(payload.count) B)")
            case .connected(_, _, _, let caps):
                connectedAt = Date()
                vcPriority = caps.first { $0.id == WDCapability.vcPriority }?.body
                say("WD connected (host accepted the module list); cap 0x05 body: " + (vcPriority.map { hexLine($0, limit: 64) } ?? "none"))
            case .packet(let p) where p.channel == AudioWire.channelNumber:
                if audio.diagnostics.hostWrites == 0 {
                    say(String(format: "first host write on ch 19 after %.1f s: %@", Date().timeIntervalSince(started), hexLine(p.payload, limit: 32)))
                }
            case .droppedChannelData(let channel, let bytes): say("dropped \(bytes) B on unregistered ch \(channel)")
            case .terminate(let reason):
                terminateReason = reason
                say("← TERMINATE reason \(reason)")
            case .failure(let text): say("WD failure: \(text)")
            default: break
            }
        default: break
        }
    }

    func key(_ code: UInt8, ctrl: Bool = false) {
        session.sendInput { wd in
            if ctrl { wd.keyScancode(0x1D, up: false) }
            wd.keyScancode(code, up: false)
            wd.keyScancode(code, up: true)
            if ctrl { wd.keyScancode(0x1D, up: true) }
        }
    }
    func type(_ text: String) {
        session.sendInput { wd in
            for unit in text.utf16 {
                wd.keyUnicode(unit, flags: [])
                wd.keyUnicode(unit, flags: .up)
            }
        }
    }

    try await session.start()
    // §13 D7: the WD module's bind table is built from the registered channels (unit tests pin its bytes).
    bindEntryInWD = session.wd.channelNumber(AudioWire.channelName) == AudioWire.channelNumber
    let notepad: () -> UInt32? = {
        appWindows.first { id in
            if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == "notepad.exe" }
            let key = windowsSeen.appKey(id)?.lowercased() ?? ""
            return key.contains("notepad") || key == "app:editor ekm"
        }
    }
    // The Sound app's window: by published app key, executable, or title.
    let soundWindow: () -> UInt32? = {
        appWindows.first { id in
            let key = windowsSeen.appKey(id)?.lowercased() ?? ""
            if let soundApp, key == "app:" + soundApp.lowercased() { return true }
            if let exe = windowsSeen.single(id, seamless.model),
               ["rundll32.exe", "control.exe", "systemsettings.exe"].contains(GuardedLogoff.basename(exe).lowercased()) { return true }
            return seamless.model.windows[id]?.title.lowercased().contains("sound") == true
        }
    }
    let appWindow: () -> UInt32? = soundApp == nil ? notepad : soundWindow
    // L1/L2: what the host sends on ch 19 without any sound (INIT, CAPINFO at session start).
    let found = await waitFor(session, 150) { logon.isFresh && appWindow() != nil }
    try await Task.sleep(nanoseconds: 5_000_000_000)
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { appWindow() }
    let before = await onSession(session) { audio.diagnostics }
    say("before any sound: \(before.hostBytes) B on ch 19, INIT \(before.initVersion.map(String.init) ?? "none"), "
        + "CAPINFO \(before.hostCapInfo.isEmpty ? "none" : "dev \(before.hostCapInfo.keys.sorted())"), OPEN \(before.openCount)")
    var steps: [String] = []
    var soundTriggered = false
    if !fresh {
        say("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !found || target == nil {
        say("no \(soundApp ?? "Notepad") window: no input is sent")
    } else if soundApp != nil, let target {
        steps += try await soundAppSteps(session: session, target: target, keys: keys, observe: observe)
        soundTriggered = keys != nil
    } else if let target {
        // L3: Notepad's "cannot find" message plays the system sound. Keys only, into Notepad only.
        let scratch = NotepadScratch(session: session, target: target)
        if try await scratch.open() {
            let opensBefore = await onSession(session) { audio.diagnostics.openCount }
            let writesBefore = await onSession(session) { audio.diagnostics.writes }
            let windowsBefore = await onSession(session) { Set(windowsAdded.map(\.id)) }
            say("(a) Ctrl+F")
            key(0x21, ctrl: true)
            _ = await waitFor(session, 5) { windowsAdded.contains { !windowsBefore.contains($0.id) } }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let findWindows = await onSession(session) { windowsAdded.filter { !windowsBefore.contains($0.id) } }
            say("windows after Ctrl+F: " + (findWindows.isEmpty ? "none (inline find bar?)" : findWindows.map { "\($0.id) \($0.kind) \"\($0.title)\"" }.joined(separator: ", ")))
            say("(b) type \"zzqxj\", Enter (find next: not found)")
            type("zzqxj")
            scratch.markTyped()
            try await Task.sleep(nanoseconds: 500_000_000)
            key(0x1C)
            soundTriggered = true
            let heard = await waitFor(session, 10) { audio.diagnostics.writes > writesBefore || audio.diagnostics.openCount > opensBefore }
            try await Task.sleep(nanoseconds: 3_000_000_000)   // let the sound finish
            let afterSound = await onSession(session) { (audio.diagnostics.openCount - opensBefore, audio.diagnostics.writes - writesBefore) }
            steps.append(heard ? "sound: \(afterSound.0) OPEN, \(afterSound.1) WRITEs within 13 s of Enter"
                               : "sound: no OPEN/WRITE within 13 s of Enter (silent sound scheme, policy, or format mismatch: see the verdict)")
            say(steps.last!)
            let messageWindows = await onSession(session) { windowsAdded.filter { !windowsBefore.contains($0.id) && !findWindows.map(\.id).contains($0.id) } }
            say("windows after Enter: " + (messageWindows.isEmpty ? "none" : messageWindows.map { "\($0.id) \($0.kind) \"\($0.title)\"" }.joined(separator: ", ")))
            // Esc closes the message box (OK only), Esc again the find dialog/bar; Esc never types into the document.
            say("(c) Esc, Esc")
            key(0x01)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            key(0x01)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            // L4: when does the host CLOSE? Watch the channel for a while.
            say("observing ch 19 for \(Int(observe)) s (L4: CLOSE timing)")
            let deadline = Date().addingTimeInterval(observe)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 500_000_000) }
            steps.append(try await scratch.clear())
            say(steps.last!)
        } else {
            steps.append("Ctrl+N: an unexpected window appeared; Esc, no further input")
            say(steps.last!)
        }
    }

    // End: log off only a fresh session; otherwise disconnect with CGP FINISH.
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
            await session.close()
            ending = sent ? "logoff sent but the session did not end in 25 s (maybe a save prompt); disconnected" : "TWI not ready; disconnected"
        }
    }
    let d = await onSession(session) { audio.diagnostics }
    let lines = await onSession(session) { commandLines }
    let timing = await onSession(session) { (initResponseAt, connectedAt, terminateReason) }
    let sentNames = await onSession(session) { modulesSent }
    writer.finish()
    let files = writer.written

    say("\n=== audiotest summary ===")
    say("module: \(d.moduleBytes.count) B " + hexLine(d.moduleBytes, limit: 64) + "; in INIT_RESPONSE: \(sentNames.contains("CTXCAM ")); bind entry CTXCAM→19: \(bindEntryInWD)")
    if timing.0 != nil, timing.1 == nil, timing.2 == nil {
        say("D1 suspicion: no INIT_CONNECT completed after INIT_RESPONSE and no TERMINATE (module list rejected?); "
            + "compare with a control run without CTXCAM (icactl session, which announces no audio)")
    }
    say("ch 19: host writes \(d.hostWrites), \(d.hostBytes) B; first " + (d.firstHostBytes.map { String(format: "after %.1f s", $0.timeIntervalSince(started)) } ?? "never"))
    say("by command: " + d.commandCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    say("INIT: " + (d.initVersion.map { v in "version \(v), byte2 \(d.initReserved.map { String(format: "0x%02x", $0) } ?? "?"), caps "
        + (d.initCaps.map { String(format: "0x%08x", $0) } ?? "none (version < 3)") + ", RW V2 \(d.readWriteV2)" } ?? "none"))
    say("credits sent: initial \(d.initialCreditsSent ? "yes (80 01 00 80 00, 80 02 00 80 00)" : "NO"); totals command \(d.creditsSent[1] ?? 0), buffer \(d.creditsSent[2] ?? 0)")
    for (dev, list) in d.hostCapInfo.sorted(by: { $0.key < $1.key }) {
        say("CAPINFO dev \(dev): host [\(list.map(\.description).joined(separator: ", "))]")
        say("             reply [\((d.replyCapInfo[dev] ?? []).map(\.description).joined(separator: ", "))]")
    }
    say("OPEN: \(d.openCount) (\(d.decodableOpenCount) decodable)" + (d.openCount > d.recentOpens.count ? "; the last \(d.recentOpens.count):" : ""))
    for o in d.recentOpens { say("  OPEN dev \(o.device) \(o.code) → \(o.decoder ? "decoded" : "not decodable")") }
    say("WRITEs \(d.writes), \(d.writeBytes) B; decoded \(d.decodedFrames) frames; decode errors \(d.decodeErrors); V2 sequence gaps \(d.sequenceGaps)")
    if d.setControlCount > 0 {
        say("SET_CONTROL (ignored): \(d.setControlCount); last: " + d.recentSetControls.map { hexLine($0) }.joined(separator: " | "))
    }
    for f in files {
        say(String(format: "WAV %@: %@, %.2f s, peak %.3f (%@)", f.url.path, f.stream.description, f.seconds, f.peak,
                   f.codes.map(\.description).joined(separator: ", ")))
    }
    if files.isEmpty { say("WAV: none (no decodable OPEN)") }
    for line in lines.prefix(80) { say("  " + line) }
    say("verdict: " + d.verdict(soundTriggered: soundTriggered))
    say("fresh logon: \(fresh)")
    for step in steps { say("  " + step) }
    say("end: \(ending)")
}

// MARK: - Notepad scratch tab (Notepad tests)

/// Test input into Notepad goes only into a tab this run opened itself. Windows 11 Notepad restores earlier
/// tabs, possibly with unsaved text that is not ours, so nothing may be typed into, copied from or deleted in
/// them. `open` activates Notepad and presses Ctrl+N (Windows 11: a new tab; classic Notepad: a new empty
/// document, and the fresh logon's document is empty, so there is no save prompt). If any captioned window
/// appears (a save prompt, a second window, …) it presses Esc and the test sends no further input. `clear`
/// deletes only text this run typed, and only when no dialog the test opened is still open. The tab itself is
/// never saved; the logoff closes it.
final class NotepadScratch {
    let session: ICASession
    let target: UInt32
    private(set) var opened = false
    private(set) var typed = false
    private var baseline: Set<UInt32> = []

    init(session: ICASession, target: UInt32) {
        self.session = session
        self.target = target
    }

    /// Captioned windows now (id → title), from the TWI model.
    private func captioned() async -> [UInt32: String] {
        await onSession(session) { [session] in
            session.seamless.model.windows.filter { $0.value.kind == .appWindow }.mapValues(\.title)
        }
    }

    private func key(_ code: UInt8, ctrl: Bool) {
        session.sendInput { wd in
            if ctrl { wd.keyScancode(0x1D, up: false) }
            wd.keyScancode(code, up: false)
            wd.keyScancode(code, up: true)
            if ctrl { wd.keyScancode(0x1D, up: true) }
        }
    }

    /// Activates Notepad, Ctrl+N; true if the new tab is ready for test input.
    func open() async throws -> Bool {
        let target = self.target
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let before = await captioned()
        baseline = Set(before.keys)
        say("Notepad window \(target) \"\(before[target] ?? "?")\": Ctrl+N (test input goes only into this run's new tab)")
        key(0x31, ctrl: true)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let after = await captioned()
        let extra = after.filter { !baseline.contains($0.key) }
        guard extra.isEmpty, after[target] != nil else {
            say("Ctrl+N: unexpected window(s) " + extra.map { "\($0.key) \"\($0.value)\"" }.joined(separator: ", ")
                + (after[target] == nil ? " (the Notepad window is gone)" : "") + "; Esc, no further input")
            key(0x01, ctrl: false)
            return false
        }
        say("Ctrl+N: no new window; Notepad title now \"\(after[target] ?? "?")\"")
        opened = true
        return true
    }

    /// Call right after typing or pasting into the new tab.
    func markTyped() { typed = true }

    /// Ctrl+A, Delete in this run's tab, so a restored copy of it is empty. Returns the log line.
    func clear() async throws -> String {
        guard opened, typed else { return "cleanup: nothing typed by this run, no keys sent" }
        let left = await captioned().filter { !baseline.contains($0.key) }
        guard left.isEmpty else {
            return "cleanup skipped: window(s) still open (" + left.map { "\($0.key) \"\($0.value)\"" }.joined(separator: ", ")
                + "); the logoff discards the tab"
        }
        let target = self.target
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        key(0x1E, ctrl: true)
        session.sendInput { wd in
            wd.keyScancodes([0xE0, 0x53], up: false)
            wd.keyScancodes([0xE0, 0x53], up: true)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return "cleanup: Ctrl+A, Delete in this run's tab (nothing saved)"
    }
}

// MARK: - Audio test with the Sound control panel

/// Framebuffer crop (0600) of `target` (plus the foreground window if another one is in front, e.g. a dialog
/// it opened), after a full redraw request.
func audioTestScreenshot(_ session: ICASession, target: UInt32, index: Int) async -> String {
    let url = sessionDir.appendingPathComponent("audiotest-sound-\(index).png")
    session.send { wd, _ in wd.redraw() }
    try? await Task.sleep(nanoseconds: 700_000_000)
    return await onSession(session) {
        let model = session.seamless.model
        guard let fb = session.thinwire.framebuffer, let w = model.windows[target] else { return "screenshot \(index): no framebuffer or window" }
        var r = w.windowRect
        var titles = ["\"\(w.title)\""]
        if let front = model.foregroundWindow, front != target, let f = model.windows[front], f.kind == .appWindow {
            r = TWIRect(left: min(r.left, f.windowRect.left), top: min(r.top, f.windowRect.top),
                        right: max(r.right, f.windowRect.right), bottom: max(r.bottom, f.windowRect.bottom))
            titles.append("foreground \(front) \"\(f.title)\"")
        }
        let rect = CGRect(x: Int(r.left), y: Int(r.top), width: Int(r.right - r.left), height: Int(r.bottom - r.top))
        guard fb.writePNG(to: url, rect: rect) else { return "screenshot \(index): FAILED (empty crop \(rect))" }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return "screenshot \(index): \(url.path) (\(Int(rect.width))x\(Int(rect.height)), \(titles.joined(separator: ", ")))"
    }
}

/// The Sound app part of `audiotest`: window title and screenshot 0; then, only if a sequence was given, exactly
/// those keys, 1.5 s apart, a screenshot after each, and the ch 19 activity per step. Returns the step lines.
func soundAppSteps(session: ICASession, target: UInt32, keys: [AudioTestKeyStep]?, observe: Double) async throws -> [String] {
    guard let audio = session.audio else { return ["no audio engine"] }
    var steps: [String] = []
    let title = await onSession(session) { session.seamless.model.windows[target]?.title ?? "?" }
    say("sound app window \(target) \"\(title)\"")
    steps.append("window \(target) \"\(title)\"")
    session.send { _, twi in twi.activate(windowId: target) }
    try await Task.sleep(nanoseconds: 2_000_000_000)
    steps.append(await audioTestScreenshot(session, target: target, index: 0))
    say(steps.last!)
    guard let keys else {
        steps.append("ICA_AUDIOTEST_KEYS not set: no input sent")
        say(steps.last!)
        return steps
    }
    for (n, step) in keys.enumerated() {
        guard !session.isClosed else {
            steps.append("session closed before step \(n + 1)")
            break
        }
        let before = await onSession(session) { (audio.diagnostics.openCount, audio.diagnostics.writes) }
        say("key \(n + 1)/\(keys.count): \(step)")
        session.sendInput { wd in
            for m in step.modifiers { wd.keyScancode(m, up: false) }
            if step.extended {
                wd.keyScancodes([0xE0, step.scancode], up: false)
                wd.keyScancodes([0xE0, step.scancode], up: true)
            } else {
                wd.keyScancode(step.scancode, up: false)
                wd.keyScancode(step.scancode, up: true)
            }
            for m in step.modifiers.reversed() { wd.keyScancode(m, up: true) }
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let shot = await audioTestScreenshot(session, target: target, index: n + 1)
        let after = await onSession(session) { (audio.diagnostics.openCount, audio.diagnostics.writes) }
        steps.append("step \(n + 1) \(step.text): ch 19 +\(after.0 - before.0) OPEN, +\(after.1 - before.1) WRITEs; \(shot)")
        say(steps.last!)
    }
    // A test sound may start late or last a few seconds; L4: when does the host CLOSE?
    say("observing ch 19 for \(Int(observe)) s (L4: CLOSE timing)")
    let deadline = Date().addingTimeInterval(observe)
    while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 500_000_000) }
    return steps
}
