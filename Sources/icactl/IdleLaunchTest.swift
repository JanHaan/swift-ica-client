import Foundation
import ICAKit

// docs/10 D.6: icactl renews an expired sign-in with the `.env` login, one renewal at a time. A direct store always (as
// before: icactl logged on again by itself when the store session had expired); through the gateway only in
// `launch-after-idle` or with ICA_RENEW_SIGNIN=1, so the live suite's "logs in at most once" stays true.

nonisolated(unsafe) var renewGatewaySignIn = ProcessInfo.processInfo.environment["ICA_RENEW_SIGNIN"] == "1"
/// Credential logons the renewal ran (the gateway's nFactor or the store's explicit logon), not the store sign-in.
nonisolated(unsafe) var renewalLogons = 0
/// Where the renewal's lines go: stderr, or `say` in `launch-after-idle`.
nonisolated(unsafe) var renewalLog: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

/// Live rule: at least 35 s between TOTP uses, across icactl's state and the installed app's.
let totpGap: TimeInterval = 35

let signInRenewal: SignInRenewal = {
    let renewal = SignInRenewal { expiry in try await renewSignIn(expiry) }
    renewal.log = { renewalLog($0) }
    return renewal
}()

func renewSignIn(_ expiry: SignInExpiry) async throws {
    let client = http.signInClient()
    if let storeFront {
        try await StoreFrontLogon(http: client, base: storeFront).logon(envCredentials())
        http.adoptSignIn(from: client, host: storeFront.host ?? "")
    } else {
        if expiry == .store {
            // The store sign-in needs no credentials; the gateway logon only if its session has expired too.
            do {
                try await storeClient().signIn()
                return
            } catch StoreClient.Failure.signedOut {
                renewalLog("sign-in: the gateway session has expired too")
            }
        }
        try await envGatewayLogon(on: client)
        http.adoptSignIn(from: client, host: gateway.host ?? "")
        try await storeClient().signInAfterGatewayLogon()
    }
    renewalLogons += 1
    try? http.saveCookies(to: cookiePath)
}

/// The installed app's TOTP state (it signs in to the same gateway with its own state file).
let appTOTPState = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("ICAViewer/.session/totp-last").path

/// The `.env` nFactor logon on `client`, at least `totpGap` after the last TOTP use (icactl's or the app's).
func envGatewayLogon(on client: HTTPClient) async throws {
    guard let user = env["CITRIX_USERNAME"], let password = env["CITRIX_PASSWORD"] else {
        fail("CITRIX_USERNAME and CITRIX_PASSWORD must be set in .env")
    }
    let username = env["CITRIX_DOMAIN"].map { "\($0)\\\(user)" } ?? user
    guard let secret = env["CITRIX_TOTP_SECRET"],
          let totp = TOTP(base32Secret: secret, digits: Int(env["CITRIX_TOTP_DIGITS"] ?? "") ?? 6,
                          period: Int(env["CITRIX_TOTP_PERIOD"] ?? "") ?? 30,
                          algorithm: TOTP.Algorithm(rawValue: (env["CITRIX_TOTP_ALGORITHM"] ?? "SHA1").uppercased()) ?? .sha1) else {
        throw GatewayLogon.Failure.needsInput("passcode (no CITRIX_TOTP_SECRET)")
    }
    let state = sessionDir.appendingPathComponent("totp-last").path
    var wait = totp.secondsUntilFresh(statePath: state, minimumGap: totpGap)
    if let written = (try? FileManager.default.attributesOfItem(atPath: appTOTPState))?[.modificationDate] as? Date {
        wait = max(wait, totpGap - Date().timeIntervalSince(written))
    }
    if wait > 0 {
        renewalLog(String(format: "sign-in: waiting %.0f s (at least %.0f s between TOTP uses)", wait, totpGap))
        try await Task.sleep(for: .seconds(wait))
    }
    try await GatewayLogon(http: client, base: gateway).logon(.init(username: username, password: password, passcode: {
        totp.freshCode(statePath: state)
    }))
}

/// A session that may be the user's (live-suite.sh's rule): through the gateway any session in the test app's
/// delivery group (ABC) or with apps the store does not name; in the lab (direct store) any session of the user.
func sessionBlocker(_ list: StoreSessionList) -> String? {
    let blocking = list.sessions.filter { s in
        if storeFront != nil { return true }
        let names = s.appNames.joined(separator: ", ")
        return names.isEmpty || names.contains("ABC") || !(names.contains("XYZ"))
    }
    guard !blocking.isEmpty else { return nil }
    return blocking.map { "session \($0.shortId) (\($0.connectionState.name), apps: \($0.appNames.isEmpty ? "none named" : $0.appNames.joined(separator: ", ")))" }
        .joined(separator: "; ")
}

/// `icactl launch-after-idle <minutes> [resource] [--first list|launch] [--polls N] [--hold S]` (docs/10 D.6.8):
/// signs in once, checks Sessions/List, makes no request for <minutes>, then sends the first requests after the idle
/// at once: `--first list` (default) the Sessions/List check and ListAvailable, `--first launch` the launch itself
/// (the ICA file is only fetched; nothing connects before the check), plus N background polls (default 2) that must
/// not start a sign-in of their own. An expired sign-in must be renewed silently, exactly once. Then the Sessions/List
/// check again: a session that may be the user's SKIPS the connection; else the app connects headless, the run waits
/// for a fresh logon, holds S s (default 45) and logs the session off. Prints the time from the sign-in to the expiry.
func runLaunchAfterIdle(_ args: [String]) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    var rest = args
    guard let minutes = rest.first.flatMap(Double.init), minutes >= 0 else {
        fail("usage: icactl launch-after-idle <minutes> [resource] [--first list|launch] [--polls N] [--hold S]")
    }
    rest.removeFirst()
    var name = "Notepad"
    var first = "list"
    var polls = 2
    var hold = 45.0
    var iterator = rest.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--first": first = iterator.next() ?? ""
        case "--polls": polls = iterator.next().flatMap(Int.init) ?? -1
        case "--hold": hold = iterator.next().flatMap(Double.init) ?? -1
        default: name = arg
        }
    }
    guard first == "list" || first == "launch", polls >= 0, hold >= 0 else { fail("bad --first, --polls or --hold") }
    guard name == "Notepad" || ProcessInfo.processInfo.environment["ICA_ALLOW_ANY_RESOURCE"] == "1" else {
        fail("launch-after-idle is limited to \"Notepad\" (ICA_ALLOW_ANY_RESOURCE=1: a lab app)")
    }
    renewGatewaySignIn = true
    renewalLog = { say($0) }
    let store = storeClient()

    // 1. One sign-in, fresh.
    say("signing in once (\(storeFront == nil ? "gateway nFactor, .env" : "store explicit logon, .env"))")
    do {
        if let storeFront {
            try await StoreFrontLogon(http: http, base: storeFront).logon(envCredentials())
        } else {
            try await envGatewayLogon(on: http)
            try await store.signInAfterGatewayLogon()
        }
    } catch {
        fail("sign-in failed: \(error)")
    }
    signInRenewal.noteSignedIn()
    let signedIn = Date()
    try? http.saveCookies(to: cookiePath)
    say("signed in at \(ISO8601DateFormatter().string(from: signedIn))")

    // 2. The resource and the Sessions/List check before the idle (no point waiting if the run would skip).
    let resource: StoreClient.Resource
    do {
        let resources = try await store.resources()
        guard let r = resources.first(where: { $0.name == name }) else { fail("no resource named \(name)") }
        resource = r
        if let blocker = sessionBlocker(try await store.sessions.list()) {
            say("SKIP: \(blocker) may be the user's; not touched")
            return
        }
        say("Sessions/List before the idle: no session in the way")
    } catch {
        fail("store before the idle: \(error)")
    }

    // 3. The idle: no request at all.
    say(String(format: "idle %.1f min: no requests until %@", minutes,
               ISO8601DateFormatter().string(from: Date().addingTimeInterval(minutes * 60))))
    // Against a deadline: a background process's sleeps run late (timer coalescing; 95 min took 101 on 2026-11-20).
    let idleEnd = Date().addingTimeInterval(minutes * 60)
    while case let left = idleEnd.timeIntervalSinceNow, left > 0 {
        try? await Task.sleep(for: .seconds(min(left, 600)))
        let rest = idleEnd.timeIntervalSinceNow
        if rest > 1 { say(String(format: "idle: %.1f min left", rest / 60)) }
    }

    // 4. The first requests after the idle, at the same moment.
    let renewalsBefore = signInRenewal.renewals
    let logonsBefore = renewalLogons
    let startedAt = Date()
    say("after the idle (\(String(format: "%.1f", startedAt.timeIntervalSince(signedIn) / 60)) min after the sign-in): "
        + (first == "launch" ? "launch" : "Sessions/List + ListAvailable") + " and \(polls) background poll(s) at once")
    var ica: String?
    var firstList: StoreSessionList?
    var outcomes: [String] = []
    await withTaskGroup(of: (String, Result<Any, Error>).self) { group in
        if first == "launch" {
            group.addTask { ("launch", await outcome { try await testLaunchICA(store, resource) }) }
        } else {
            group.addTask { ("Sessions/List", await outcome { try await store.sessions.list() }) }
            group.addTask { ("ListAvailable", await outcome { try await store.sessions.available(excludeActive: false) }) }
        }
        for i in 0..<polls {
            var poller = store
            poller.background = true
            group.addTask { ("background poll \(i + 1)", await outcome { try await poller.sessions.list() }) }
        }
        for await (what, result) in group {
            switch result {
            case .success(let value):
                if let text = value as? String { ica = text }
                if let list = value as? StoreSessionList, what == "Sessions/List" { firstList = list }
                outcomes.append("\(what): ok")
            case .failure(let error):
                outcomes.append("\(what): \(error)")
            }
        }
    }
    for line in outcomes.sorted() { say("  " + line) }
    let renewed = signInRenewal.renewals - renewalsBefore
    let logons = renewalLogons - logonsBefore
    if let expiry = signInRenewal.lastExpiry {
        say(String(format: "EXPIRY: first expired answer %.1f min after the sign-in (%@); the gateway's timeout is at most that",
                   expiry.at.timeIntervalSince(signedIn) / 60, expiry.kind.rawValue))
    } else {
        say(String(format: "no expiry: the sign-in was still valid %.1f min after it", startedAt.timeIntervalSince(signedIn) / 60))
    }
    say("renewals started: \(renewed), credential logons: \(logons)" + (renewed <= 1 && logons <= 1 ? " (one at most: OK)" : " (MORE THAN ONE: FAIL)"))

    // 5. The Sessions/List check right before connecting.
    do {
        let list: StoreSessionList
        if let firstList { list = firstList } else { list = try await store.sessions.list() }
        if let blocker = sessionBlocker(list) {
            say("SKIP: \(blocker) may be the user's; not touched" + (ica != nil ? " (the fetched ICA file is dropped unused)" : ""))
            exit(renewed <= 1 && logons <= 1 ? 0 : 1)
        }
        say("Sessions/List after the idle: \(list.sessions.count) session(s), none in the way")
        if ica == nil { ica = try await testLaunchICA(store, resource) }
        try? http.saveCookies(to: cookiePath)
    } catch {
        say("FAIL: launch after the idle: \(error)")
        exit(1)
    }
    guard let text = ica, let file = ICAFile(text: text) else { say("FAIL: not an ICA file"); exit(1) }
    say("ICA file for \(resource.name) after the renewal; connecting headless (hold \(Int(hold)) s, then logoff)")
    let dir = sessionDir.appendingPathComponent("idle-launch")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
        try await runSession(ica: file, seconds: hold, captureDir: dir)
    } catch {
        say("FAIL: session: \(error)")
        exit(1)
    }
    exit(renewed <= 1 && logons <= 1 ? 0 : 1)
}

func outcome(_ body: () async throws -> Any) async -> Result<Any, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
