import Foundation
import Testing
@testable import ICAKit

// docs/10 D.6: an expired sign-in is detected by where a store request ends, renewed once for all concurrent
// requests, and each request is sent once more. Canned answers reproduce the gateway's redirect chain
// (`302 /vpn/index.html` → `302 /logon/LogonPoint/tmindex.html` → `200` HTML) as HTTPClient reports it: the
// final URL and the logon page body. Neutral host names only.

private let gatewayHost = "gateway.example.test"
private let storeBase = URL(string: "https://\(gatewayHost)/welcome/")!
private let directBase = URL(string: "https://storefront.example.test/Citrix/StoreWeb/")!
private let logonPage = URL(string: "https://\(gatewayHost)/logon/LogonPoint/tmindex.html")!

/// The shape of the gateway's logon page: an HTML document of the RfWebUI logon point, not JSON or XML.
private let logonPageHTML = """
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Gateway</title>
<link rel="stylesheet" href="/logon/LogonPoint/receiver/css/ctxs.large-ui.min.css">
<script src="/logon/LogonPoint/receiver/js/ctxs.core.min.js"></script></head>
<body class="logon"><div id="logonbox-container"></div>
<script>CTXS.ExtensionAPI.init("/logon/LogonPoint/");</script>
""" + String(repeating: "<!-- padding -->\n", count: 200) + "</body></html>"

private let sessionListJSON = #"{"deviceId":"DEV-1","sessions":[]}"#
private let launchReady = #"{"status":"success"}"#
private let icaText = "[Encoding]\nInputEncoding=UTF8\n\n[WFClient]\nVersion=2\n\n[ApplicationServers]\nEditor=\n\n[Editor]\nAddress=;40;STA;0\n"

private func resource(session: Bool = false) throws -> StoreClient.Resource {
    let json = session
        ? #"{"id":"s1","name":"Editor","launchurl":"Sessions/LaunchIca/QzE-.ica","launchstatusurl":"Sessions/GetLaunchStatus/QzE-"}"#
        : #"{"id":"r1","name":"Editor","launchurl":"Resources/LaunchIca/UjE-.ica","launchstatusurl":"Resources/GetLaunchStatus/UjE-"}"#
    return try JSONDecoder().decode(StoreClient.Resource.self, from: Data(json.utf8))
}

/// A store behind the gateway (or a direct store) whose sign-in can expire. While expired every store request ends at
/// the gateway's logon page (gateway) or carries the store's challenge (direct).
private final class ExpiringStore: StoreTransport, @unchecked Sendable {
    struct Sent { var method: String; var path: String; var csrf: String?; var duringRenewal: Bool }
    let lock = NSLock()
    var expired = true
    var direct = false
    var renewing = false
    var csrf = "csrf-old"
    var sent: [Sent] = []
    /// Status answer for the launch status path (404: the session is gone).
    var launchStatus = 200
    /// Answer redirects unfollowed (a 302 with Location) instead of the followed chain.
    var unfollowed = false
    /// Stay expired even after a renewal.
    var stuck = false

    func send(_ method: String, _ url: URL, headers: [String: String], body: Data?, contentType: String?) async throws
        -> HTTPClient.Response {
        let (isExpired, isDirect) = lock.withLock {
            sent.append(Sent(method: method, path: url.path, csrf: headers["Csrf-Token"] ?? headers["CsrfToken"], duringRenewal: renewing))
            return (expired, direct)
        }
        await Task.yield()
        if isExpired {
            if isDirect {
                return HTTPClient.Response(status: 200, headers: ["CitrixWebReceiver-Authenticate": #"reason="Expired", location="Authentication/GetAuthMethods""#,
                                                                  "Content-Type": "application/json"],
                                           body: Data(#"{"unauthorized": true}"#.utf8), url: url)
            }
            if unfollowed {
                return HTTPClient.Response(status: 302, headers: ["Location": "/vpn/index.html"], body: Data(), url: url)
            }
            return HTTPClient.Response(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
                                       body: Data(logonPageHTML.utf8), url: logonPage)
        }
        let path = url.path
        func json(_ text: String, _ status: Int = 200) -> HTTPClient.Response {
            HTTPClient.Response(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8), url: url)
        }
        if path.contains("GetLaunchStatus") {
            return launchStatus == 200 ? json(launchReady)
                : HTTPClient.Response(status: launchStatus, headers: ["Content-Type": "text/html"], body: Data("<html>Not found</html>".utf8), url: url)
        }
        if path.contains("LaunchIca") { return HTTPClient.Response(status: 200, headers: [:], body: Data(icaText.utf8), url: url) }
        if path.hasSuffix("Sessions/List") { return json(sessionListJSON) }
        if path.hasSuffix("Sessions/ListAvailable") { return json("[]") }
        if path.hasSuffix("Resources/List") { return json(#"{"resources":[]}"#) }
        return json("{}", 404)
    }

    func cookie(_ name: String) -> String? { name == "CsrfToken" ? lock.withLock { csrf } : nil }

    /// What a sign-in does to this store: a new session and CSRF token.
    func signIn() {
        lock.withLock {
            if !stuck { expired = false }
            csrf = "csrf-new"
        }
    }

    var paths: [String] { lock.withLock { sent.map(\.path) } }
    var sentDuringRenewal: Int { lock.withLock { sent.filter(\.duringRenewal).count } }
}

private final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var lines: [String] = []
    var renewals: [SignInExpiry] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    func renewed(_ kind: SignInExpiry) { lock.withLock { renewals.append(kind) } }
}

/// A renewal that signs `store` in after `delay` (so concurrent requests overlap it).
private func renewal(_ store: ExpiringStore, _ rec: Recorder, delay: Duration = .milliseconds(50),
                     error: Error? = nil) -> SignInRenewal {
    let renewal = SignInRenewal { kind in
        rec.renewed(kind)
        store.lock.withLock { store.renewing = true }
        try await Task.sleep(for: delay)
        store.lock.withLock { store.renewing = false }
        if let error { throw error }
        store.signIn()
    }
    renewal.log = { rec.add($0) }
    return renewal
}

private func client(_ store: ExpiringStore, _ renewal: SignInRenewal?) -> StoreClient {
    var client = StoreClient(transport: store, base: store.direct ? directBase : storeBase, direct: store.direct)
    client.renewal = renewal
    return client
}

@Suite struct SignInExpiryDetectionTests {
    let requested = URL(string: "Resources/GetLaunchStatus/UjE-", relativeTo: storeBase)!.absoluteURL

    @Test func theLogonPageAtTheEndOfTheRedirectChainIsAnExpiry() {
        let page = HTTPClient.Response(status: 200, headers: ["Content-Type": "text/html"], body: Data(logonPageHTML.utf8), url: logonPage)
        #expect(SignInExpiry.detect(page, requested: requested) == .gateway)
        let vpn = HTTPClient.Response(status: 200, headers: [:], body: Data(), url: URL(string: "https://\(gatewayHost)/vpn/index.html")!)
        #expect(SignInExpiry.detect(vpn, requested: requested) == .gateway)
        // Case does not matter (the gateway's own spelling is LogonPoint).
        let lower = HTTPClient.Response(status: 200, headers: [:], body: Data(), url: URL(string: "https://\(gatewayHost)/logon/logonpoint/index.html")!)
        #expect(SignInExpiry.detect(lower, requested: requested) == .gateway)
    }

    @Test func anUnfollowedRedirectToTheLogonPageIsAnExpiry() {
        let redirect = HTTPClient.Response(status: 302, headers: ["Location": "/vpn/index.html"], body: Data(), url: requested)
        #expect(SignInExpiry.detect(redirect, requested: requested) == .gateway)
        let elsewhere = HTTPClient.Response(status: 302, headers: ["Location": "/welcome/Other"], body: Data(), url: requested)
        #expect(SignInExpiry.detect(elsewhere, requested: requested) == nil)
    }

    @Test func htmlFromTheStoreItselfIsNoExpiry() {
        // The store's own error page is HTML too (e.g. its 404 for an unknown session): no sign-in would help.
        let notFound = HTTPClient.Response(status: 404, headers: ["Content-Type": "text/html"], body: Data("<html>404</html>".utf8), url: requested)
        #expect(SignInExpiry.detect(notFound, requested: requested) == nil)
        let ok = HTTPClient.Response(status: 200, headers: ["Content-Type": "application/json"], body: Data(launchReady.utf8), url: requested)
        #expect(SignInExpiry.detect(ok, requested: requested) == nil)
    }

    @Test func theStoreChallengeAnd401AreStoreExpiries() {
        let challenge = HTTPClient.Response(status: 200, headers: ["CitrixWebReceiver-Authenticate": "reason=x"], body: Data(), url: requested)
        #expect(SignInExpiry.detect(challenge, requested: requested) == .store)
        let unauthorized = HTTPClient.Response(status: 401, headers: [:], body: Data(), url: requested)
        #expect(SignInExpiry.detect(unauthorized, requested: requested) == .store)
    }

    @Test func aRequestForTheLogonPageItselfIsNoExpiry() {
        let page = HTTPClient.Response(status: 200, headers: [:], body: Data(logonPageHTML.utf8), url: logonPage)
        #expect(SignInExpiry.detect(page, requested: logonPage) == nil)
    }
}

@Suite struct SignInRenewalTests {
    @Test func aLaunchAfterTheGatewayExpiryRenewsOnceAndRetries() async throws {
        let store = ExpiringStore()
        let rec = Recorder()
        let ica = try await client(store, renewal(store, rec)).launchICA(try resource())
        #expect(ica.hasPrefix("[Encoding]"))
        #expect(rec.renewals == [.gateway])
        // GetLaunchStatus twice (expired, then again), then the ICA file; the repeat carries the new CSRF token.
        #expect(store.paths == ["/welcome/Resources/GetLaunchStatus/UjE-", "/welcome/Resources/GetLaunchStatus/UjE-",
                                "/welcome/Resources/LaunchIca/UjE-.ica"])
        #expect(store.sent.map(\.csrf) == ["csrf-old", "csrf-new", nil])
        // One line for the expiry, one for the renewal; paths and times only.
        #expect(rec.lines.count == 2)
        #expect(rec.lines[0].contains("gateway sign-in expired") && rec.lines[0].contains("Resources/GetLaunchStatus"))
        #expect(rec.lines[1].hasPrefix("sign-in: renewed after"))
        #expect(!rec.lines.joined().contains("csrf"))
    }

    @Test func anUnfollowedRedirectRenewsToo() async throws {
        let store = ExpiringStore()
        store.unfollowed = true
        let rec = Recorder()
        _ = try await client(store, renewal(store, rec)).launchICA(try resource())
        #expect(rec.renewals == [.gateway])
    }

    @Test func withoutARenewalTheLogonPageIsSignedOutNotAStatusError() async throws {
        // The bug: the logon page was parsed as launch status JSON ("status ? errorId ?") and the launch gave up.
        let store = ExpiringStore()
        await #expect(throws: StoreClient.Failure.self) { _ = try await client(store, nil).launchICA(try resource()) }
        do {
            _ = try await client(store, nil).launchICA(try resource())
        } catch StoreClient.Failure.signedOut(let what) {
            #expect(what == "GetLaunchStatus")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func concurrentRequestsShareOneRenewal() async throws {
        let store = ExpiringStore()
        let rec = Recorder()
        let shared = renewal(store, rec, delay: .milliseconds(150))
        let c = client(store, shared)
        let r = try resource()
        async let launch = c.launchICA(r)
        async let list1 = c.sessions.list()
        // These start while the renewal runs: they wait for it instead of reaching the gateway.
        try await Task.sleep(for: .milliseconds(40))
        async let list2 = c.sessions.list()
        async let available = c.sessions.available(excludeActive: false)
        let (ica, a, b, d) = try await (launch, list1, list2, available)
        #expect(ica.hasPrefix("[") && a.sessions.isEmpty && b.sessions.isEmpty && d.isEmpty)
        #expect(rec.renewals.count == 1)
        #expect(shared.renewals == 1)
        // While the renewal ran, no store request reached the gateway (a poll there resets the logon conversation).
        #expect(store.sentDuringRenewal == 0)
        #expect(rec.lines.filter { $0.contains("renewing") }.count == 1)
    }

    @Test func aBackgroundPollNeverStartsARenewal() async throws {
        let store = ExpiringStore()
        let rec = Recorder()
        let shared = renewal(store, rec)
        var poller = client(store, shared)
        poller.background = true
        for _ in 0..<3 {
            do {
                _ = try await poller.sessions.list()
                Issue.record("a background poll succeeded while expired")
            } catch let error as SignInRenewal.Failure {
                #expect(error == .expired(.gateway))
            }
        }
        #expect(rec.renewals.isEmpty)
        // One log line for the expiry, not one per poll.
        #expect(rec.lines.count == 1 && rec.lines[0].contains("a background request does not renew it"))
        // A request the user made renews it.
        _ = try await client(store, shared).sessions.list()
        #expect(rec.renewals == [.gateway])
    }

    @Test func aBackgroundPollJoinsARunningRenewal() async throws {
        let store = ExpiringStore()
        let rec = Recorder()
        let shared = renewal(store, rec, delay: .milliseconds(200))
        let c = client(store, shared)
        var poller = c
        poller.background = true
        let r = try resource()
        async let launch = c.launchICA(r)
        try await Task.sleep(for: .milliseconds(60))   // the launch has found the expiry and started the renewal
        let list = try await poller.sessions.list()
        _ = try await launch
        #expect(list.sessions.isEmpty)
        #expect(rec.renewals.count == 1)
    }

    @Test func aStaleAnswerAfterARenewalIsOnlySentAgain() async throws {
        // B was sent before A's renewal and comes back expired after it: B is repeated, no second renewal.
        let rec = Recorder()
        let gate = AsyncGate()
        let shared = SignInRenewal { kind in rec.renewed(kind) }
        let url = URL(string: "Sessions/List", relativeTo: storeBase)!.absoluteURL
        let expired = HTTPClient.Response(status: 200, headers: [:], body: Data(logonPageHTML.utf8), url: logonPage)
        let fine = HTTPClient.Response(status: 200, headers: [:], body: Data(sessionListJSON.utf8), url: url)
        let calls = Counter()
        async let b: HTTPClient.Response = shared.send(url) {
            if calls.next("b") == 1 {
                await gate.wait()
                return expired
            }
            return fine
        }
        try await Task.sleep(for: .milliseconds(30))
        let a = try await shared.send(url) { calls.next("a") == 1 ? expired : fine }
        await gate.open()
        let answer = try await b
        #expect(a.url == url && answer.url == url)
        #expect(rec.renewals.count == 1)
        #expect(calls.count("b") == 2 && calls.count("a") == 2)
    }

    @Test func a403SentBeforeARenewalIsSentAgainAfterIt() async throws {
        // Live (lab, D184): requests in flight with the expired session's CSRF token got 403, not the challenge.
        let rec = Recorder()
        let gate = AsyncGate()
        let shared = SignInRenewal { kind in rec.renewed(kind) }
        let url = URL(string: "Resources/GetLaunchStatus/UjE-", relativeTo: directBase)!.absoluteURL
        let challenge = HTTPClient.Response(status: 200, headers: ["CitrixWebReceiver-Authenticate": "reason=x"], body: Data(), url: url)
        let forbidden = HTTPClient.Response(status: 403, headers: [:], body: Data(), url: url)
        let fine = HTTPClient.Response(status: 200, headers: [:], body: Data(launchReady.utf8), url: url)
        let calls = Counter()
        async let b: HTTPClient.Response = shared.send(url) {
            if calls.next("b") == 1 {
                await gate.wait()
                return forbidden
            }
            return fine
        }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await shared.send(url) { calls.next("a") == 1 ? challenge : fine }
        await gate.open()
        #expect(try await b.status == 200)
        #expect(rec.renewals == [.store] && calls.count("b") == 2)
        // A 403 with no renewal around is the caller's to handle (StoreSessions' header fallback).
        #expect(try await shared.send(url) { forbidden }.status == 403)
    }

    @Test func aFailedRenewalFailsItsRequestsAndAStuckStoreIsNoLoop() async throws {
        struct Cancelled: Error {}
        let store = ExpiringStore()
        let rec = Recorder()
        let failing = renewal(store, rec, error: Cancelled())
        await #expect(throws: Cancelled.self) { _ = try await client(store, failing).sessions.list() }
        #expect(rec.renewals.count == 1)
        #expect(rec.lines.last?.contains("not renewed") == true)

        let stuck = ExpiringStore()
        stuck.stuck = true
        let rec2 = Recorder()
        await #expect(throws: SignInRenewal.Failure.stillExpired("Sessions/List")) {
            _ = try await client(stuck, renewal(stuck, rec2)).sessions.list()
        }
        #expect(rec2.renewals.count == 1)
        #expect(stuck.paths.count == 2)
    }

    @Test func a404ForASessionIsNoExpiry() async throws {
        // The takeover bug: Sessions/GetLaunchStatus 404 led to a new sign-in. The session is gone; nothing signs in.
        let store = ExpiringStore()
        store.expired = false
        store.launchStatus = 404
        let rec = Recorder()
        do {
            _ = try await client(store, renewal(store, rec)).launchICA(try resource(session: true))
            Issue.record("a launch of a gone session succeeded")
        } catch StoreClient.Failure.sessionGone {
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(rec.renewals.isEmpty)
        #expect(store.paths == ["/welcome/Sessions/GetLaunchStatus/QzE-"])
        // A 404 for an app stays an HTTP failure (the resource is not published), not a gone session.
        await #expect(throws: StoreClient.Failure.http("GetLaunchStatus", 404)) {
            _ = try await client(store, renewal(store, rec)).launchICA(try resource())
        }
    }

    @Test func aDirectStoreChallengeRenewsTheSameWay() async throws {
        let store = ExpiringStore()
        store.direct = true
        let rec = Recorder()
        let c = client(store, renewal(store, rec))
        async let launch = c.launchICA(try resource())
        async let list = c.sessions.list()
        let (ica, sessions) = try await (launch, list)
        #expect(ica.hasPrefix("[") && sessions.sessions.isEmpty)
        #expect(rec.renewals == [.store])
        #expect(rec.lines.first?.contains("store sign-in expired") == true)
    }

    @Test func requestsInsideARenewalAreNotHeld() async throws {
        // The renewal's own store sign-in goes through the same store client; it must not wait for itself.
        final class Box: @unchecked Sendable { var client: StoreClient? }
        let store = ExpiringStore()
        let rec = Recorder()
        let box = Box()
        let shared = SignInRenewal { kind in
            rec.renewed(kind)
            store.signIn()
            _ = try await box.client?.sessions.list()   // exempt: no deadlock, no second renewal
        }
        box.client = client(store, shared)
        _ = try await box.client!.sessions.list()
        #expect(rec.renewals.count == 1)
        #expect(store.paths.count == 3)
    }
}

@Suite struct SignInClientTests {
    private func cookie(_ name: String, _ value: String, _ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
    }

    @Test func aSignInRunsBesideTheSessionAndIsAdoptedOnSuccess() {
        let main = HTTPClient()
        main.setCookie(cookie("NSC_AAAC", "old", gatewayHost))
        main.setCookie(cookie("NSC_STALE", "x", gatewayHost))
        main.setCookie(cookie(DeviceIdentity.cookieName, "device-1", gatewayHost))
        main.setCookie(cookie("Other", "keep", "other.example.test"))
        let login = main.signInClient()
        #expect(login.cookieNames.isEmpty)          // its own empty jar: the running session is untouched
        #expect(main.cookie("NSC_AAAC") == "old")
        login.setCookie(cookie("NSC_AAAC", "new", gatewayHost))
        login.setCookie(cookie("NSC_TMAS", "t", gatewayHost))
        main.adoptSignIn(from: login, host: gatewayHost)
        #expect(main.cookie("NSC_AAAC") == "new")
        #expect(main.cookie("NSC_TMAS") == "t")
        #expect(main.cookie("NSC_STALE") == nil)
        #expect(main.cookie(DeviceIdentity.cookieName) == "device-1")
        #expect(main.cookie("Other") == "keep")
    }
}

@Suite struct TOTPWaitTests {
    @Test func secondsUntilFreshWaitsForTheNextStep() throws {
        let totp = try #require(TOTP(base32Secret: "JBSWY3DPEHPK3PXP"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("totp-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_800_000_010)   // 10 s into a 30 s step
        #expect(totp.secondsUntilFresh(statePath: path, at: now) == 0)
        let window = Int(now.timeIntervalSince1970) / 30
        try String(window).write(toFile: path, atomically: true, encoding: .utf8)
        #expect(abs(totp.secondsUntilFresh(statePath: path, at: now) - 20.5) < 0.01)
        try String(window - 1).write(toFile: path, atomically: true, encoding: .utf8)
        #expect(totp.secondsUntilFresh(statePath: path, at: now) == 0)
        // The live rule: at least 35 s since the state was written.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: path)
        #expect(abs(totp.secondsUntilFresh(statePath: path, minimumGap: 35, at: now) - 30) < 0.01)
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ key: String) -> Int { lock.withLock { counts[key, default: 0] += 1; return counts[key]! } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
}
