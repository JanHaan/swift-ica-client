import Foundation
import ICAKit

/// `icactl gateway-keepalive-probe <interval-min> <max-min>` (docs/10 D.6.9): signs in once (the `.env` nFactor
/// logon), then sends one `GET Sessions/List` every <interval> minutes on a fixed deadline, with no silent renewal,
/// and logs for each the time since the sign-in and whether the answer was the real JSON or the gateway's logon
/// page. Stops at the first redirect or after <max> minutes, then signs out unless the sign-in has expired.
/// Answers whether the gateway's timeout counts from the sign-in (absolute) or from the last request (idle).
/// Only Sessions/List; never prints tokens, cookies or the session details.
func runGatewayKeepAliveProbe(_ args: [String]) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard args.count == 2, let interval = Double(args[0]), let maxMinutes = Double(args[1]), interval > 0, maxMinutes >= 0,
          storeFront == nil else {
        fail("usage: icactl gateway-keepalive-probe <interval-min> <max-min> (through the gateway)")
    }
    renewGatewaySignIn = false
    let store = storeClient()
    let stamp = ISO8601DateFormatter()

    var signedIn: Date?
    for attempt in 1...2 {
        do {
            try await envGatewayLogon(on: http)
            try await store.signInAfterGatewayLogon()
            signedIn = Date()
            break
        } catch {
            say("sign-in attempt \(attempt) failed: \(error)")
            if attempt == 1 {
                say("waiting 60 s, then one more try")
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    guard let start = signedIn else { fail("sign-in failed twice; stopping") }
    try? http.saveCookies(to: cookiePath)
    say("signed in at \(stamp.string(from: start)); interval \(interval) min, max \(maxMinutes) min, no renewal")

    guard let path = SessionEndpoints().list, let url = URL(string: path, relativeTo: store.base)?.absoluteURL else {
        fail("no Sessions/List URL")
    }
    var expired = false
    var k = 0
    while true {
        let due = start.addingTimeInterval(Double(k) * interval * 60)
        if k > 0 {
            while case let left = due.timeIntervalSinceNow, left > 0 { try? await Task.sleep(for: .seconds(min(left, 60))) }
        }
        let age = Date().timeIntervalSince(start) / 60
        if age > maxMinutes + 0.5 { break }
        var headers = ["X-Citrix-IsUsingHTTPS": "Yes", "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
        if let csrf = http.cookie("CsrfToken", for: store.base) { headers["Csrf-Token"] = csrf }
        let verdict: String
        do {
            let response = try await http.send("GET", url, headers: headers)
            if let kind = SignInExpiry.detect(response, requested: url) {
                verdict = "EXPIRED (\(kind.rawValue); HTTP \(response.status), ended at \(response.url.path))"
                expired = true
            } else if response.status == 200, let first = response.body.first(where: { $0 > 32 }), first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
                verdict = "real JSON (HTTP 200, \(response.body.count) bytes)"
            } else {
                verdict = "OTHER (HTTP \(response.status), ended at \(response.url.path), \(response.body.count) bytes)"
            }
        } catch {
            verdict = "request failed: \(error)"
        }
        say(String(format: "request %d at %.1f min after the sign-in (%@): %@", k, age, stamp.string(from: Date()), verdict))
        if expired { break }
        k += 1
        if Double(k) * interval > maxMinutes + 0.01 { break }
    }

    if expired {
        say("RESULT: expired \(String(format: "%.1f", Date().timeIntervalSince(start) / 60)) min after the sign-in; last real answer before it is the line above; no sign-out (already expired)")
    } else {
        say("RESULT: no expiry up to \(String(format: "%.1f", Date().timeIntervalSince(start) / 60)) min; signing out")
        let steps = await AccountSignOut.run(http: http, storeBase: store.base, gateway: gateway, cookieFile: cookiePath)
        for step in steps { say("sign-out: \(step)") }
    }
}

/// `icactl keepalive-check <interval-s> <wait-s> session|none [resource]` (docs/10 D.6.9, lab only: a direct
/// StoreFront whose web timeout is shortened with `icalab.sh sf-timeout`). Signs in once. `session`: connects a
/// headless session and tells `SessionKeepAlive` (the app's own class, with its rules and `ping`) it is connected;
/// `none`: nothing is connected, so it sends nothing. After <wait-s> one background Sessions/List shows whether the
/// sign-in survived (`ping` never renews). Prints the number of keep-alive requests and the verdict.
func runKeepAliveCheck(_ args: [String]) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    guard args.count >= 3, let interval = Double(args[0]), let wait = Double(args[1]), args[2] == "session" || args[2] == "none",
          storeFront != nil else {
        fail("usage: icactl keepalive-check <interval-s> <wait-s> session|none [resource] (direct StoreFront, lab)")
    }
    let withSession = args[2] == "session"
    let name = args.count > 3 ? args[3] : "Notepad"
    guard ProcessInfo.processInfo.environment["ICA_ALLOW_ANY_RESOURCE"] == "1" else { fail("lab only: ICA_ALLOW_ANY_RESOURCE=1") }
    let store = storeClient()
    do { try await StoreFrontLogon(http: http, base: storeFront!).logon(envCredentials()) } catch { fail("sign-in failed: \(error)") }
    signInRenewal.noteSignedIn()
    let signedIn = Date()
    say("signed in; keep-alive interval \(interval) s, check after \(wait) s, \(withSession ? "with a connected session" : "no session")")
    let keepAlive = SessionKeepAlive(interval: interval) { await SessionKeepAlive.ping(store) }
    keepAlive.log = { say($0) }
    var sessionTask: Task<Void, Never>?
    if withSession {
        do {
            let resources = try await store.resources()
            guard let r = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
            guard let ica = ICAFile(text: try await testLaunchICA(store, r)) else { fail("not an ICA file") }
            let dir = sessionDir.appendingPathComponent("keepalive-check")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            keepAlive.update(connected: 1)
            sessionTask = Task {
                do { try await runSession(ica: ica, seconds: wait + 20, captureDir: dir) } catch { say("session: \(error)") }
                keepAlive.update(connected: 0)
            }
        } catch { fail("launch: \(error)") }
    } else {
        keepAlive.update(connected: 0)
    }
    let end = Date().addingTimeInterval(wait)
    while case let left = end.timeIntervalSinceNow, left > 0 { try? await Task.sleep(for: .seconds(min(left, 5))) }
    let outcome = await SessionKeepAlive.ping(store)
    let renewalsBefore = signInRenewal.renewals
    say(String(format: "check %.0f s after the sign-in: %@; keep-alive requests so far: %d; renewals: %d",
               Date().timeIntervalSince(signedIn), "\(outcome)", keepAlive.pings, renewalsBefore))
    say(outcome == .alive ? "RESULT: sign-in alive" : "RESULT: sign-in expired (not renewed)")
    await sessionTask?.value
    keepAlive.stop()
}
