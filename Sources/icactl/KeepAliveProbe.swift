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
