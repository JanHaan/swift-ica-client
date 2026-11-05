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

case "connect":
    // icactl connect [resource name] — fresh ICA file, TLS to the gateway, CGP bind, ICA detect, dump
    let name = args.first ?? env["CITRIX_RESOURCE"] ?? "Calculator"
    let store = StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL)
    do {
        let resources = try await store.resources()
        guard let resource = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        guard let ica = ICAFile(text: try await store.launchICA(resource)) else { fail("not an ICA file") }
        try http.saveCookies(to: cookiePath)
        guard let proxy = ica["SSLProxyHost"], let ticket = ica["Address"], ica.bool("CGPSecurityTicket") else {
            fail("ICA file lacks SSLProxyHost/Address/CGPSecurityTicket")
        }
        let colon = proxy.lastIndex(of: ":")
        let host = colon.map { String(proxy[..<$0]) } ?? proxy
        let port = colon.flatMap { UInt16(proxy[proxy.index(after: $0)...]) } ?? 443
        let stream = TLSStream(host: host, port: port)
        try await stream.connect()
        print("TLS connected to \(host):\(port)")
        let cgp = CGPSession()
        try await stream.send(cgp.bindRequest(ticket: ticket))
        print("→ CGP bind request (ticket \(ticket.count) chars)")

        let deadline = Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["ICA_DUMP_SECONDS"] ?? "") ?? 15)
        let watchdog = Task { try await Task.sleep(until: .now + .seconds(deadline.timeIntervalSinceNow)); stream.close() }
        var sawDetect = false
        var captureIndex = 0
        receive: while true {
            let chunk: Data
            do { chunk = try await stream.receive() } catch { print("receive ended: \(error)"); break }
            for event in try cgp.feed(chunk) {
                switch event {
                case .signature:
                    print("← CGP signature")
                case .bindResponse(let caps):
                    print("← bind response: \(caps.map(\.description).joined(separator: ", "))")
                    // Cap 6 carries the reconnect ticket and cap 5 the reconnect cookie: never dump them.
                    for cap in caps where cap.capId != 6 && cap.capId != 5 {
                        print("   \(cap)\n" + cap.body.hexDump(limit: 64).split(separator: "\n").map { "     " + $0 }.joined(separator: "\n"))
                    }
                    try await stream.send(cgp.channelOpenRequest())
                    print("→ channel open (service \(cgp.tcpProxyServiceId))")
                case .channelOpenResponse(let channel, let status):
                    print("← channel open response: channel \(channel) status \(status)")
                case .data(let payload):
                    if !sawDetect, payload.starts(with: CGPSession.icaDetect) {
                        sawDetect = true
                        print("← ICA detect\(payload.count > 6 ? " + \(payload.count - 6) bytes" : "")")
                        try await stream.send(cgp.detectReply())
                        print("→ ICA detect reply")
                        if payload.count > 6 { print(payload.dropFirst(6).hexDump()) }
                    } else {
                        captureIndex += 1
                        let path = sessionDir.appendingPathComponent("capture-\(captureIndex).bin").path
                        FileManager.default.createFile(atPath: path, contents: payload, attributes: [.posixPermissions: 0o600])
                        print("← ICA data \(payload.count)B → \(path)\n" + payload.hexDump(limit: 64))
                    }
                case .finishRequest(let type, let reason):
                    print("← finish request type \(type) reason 0x\(String(reason, radix: 16))")
                    try? await stream.send(cgp.finishResponse(closeType: type))
                    break receive
                case .finishResponse:
                    print("← finish response")
                case .other(let command, let body):
                    print("← CGP cmd 0x\(String(command, radix: 16)) \(body.count)B\n" + body.hexDump(limit: 64))
                }
            }
            if let ack = cgp.pendingAck() { try await stream.send(ack) }
        }
        watchdog.cancel()
        try? await stream.send(cgp.finishRequest())
        stream.close()
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
    """)
}
