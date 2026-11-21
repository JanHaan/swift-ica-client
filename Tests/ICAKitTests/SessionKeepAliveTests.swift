import Foundation
import Testing
@testable import ICAKit

// docs/10 D.6.9: the keep-alive runs only while a session is connected, and never renews a sign-in.

private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var n = 0
    var outcome: SessionKeepAlive.Outcome = .alive
    func hit() -> SessionKeepAlive.Outcome { lock.withLock { n += 1; return outcome } }
    var count: Int { lock.withLock { n } }
}

private final class ListTransport: StoreTransport, @unchecked Sendable {
    let lock = NSLock()
    var paths: [String] = []
    var expired = false
    func send(_ method: String, _ url: URL, headers: [String: String], body: Data?, contentType: String?) async throws
        -> HTTPClient.Response {
        lock.withLock { paths.append(url.path) }
        if expired {
            return HTTPClient.Response(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>logon</html>".utf8),
                                       url: URL(string: "https://gw.example.test/logon/LogonPoint/tmindex.html")!)
        }
        return HTTPClient.Response(status: 200, headers: ["Content-Type": "application/json"],
                                   body: Data(#"{"deviceId":"D","sessions":[]}"#.utf8), url: url)
    }
    func cookie(_ name: String) -> String? { nil }
}

@Suite struct SessionKeepAliveTests {
    @Test func noSessionNoRequest() async throws {
        let c = Counter()
        let k = SessionKeepAlive(interval: 0.05) { c.hit() }
        k.update(connected: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.count == 0 && !k.isRunning)
    }

    @Test func startsWithTheFirstSessionAndStopsWithTheLast() async throws {
        let c = Counter()
        let k = SessionKeepAlive(interval: 0.05) { c.hit() }
        k.update(connected: 1)
        k.update(connected: 2)   // a second session does not start a second timer
        #expect(k.isRunning)
        for _ in 0..<100 where c.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        let during = c.count
        #expect(during >= 2)
        k.update(connected: 0)
        #expect(!k.isRunning)
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.count <= during + 1)   // at most one request that was already in flight
        let after = c.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(c.count == after)
    }

    @Test func signOutStopsItAndSignInAllowsItAgain() async throws {
        let c = Counter()
        let k = SessionKeepAlive(interval: 0.05) { c.hit() }
        k.update(connected: 1)
        k.signedOut()
        #expect(!k.isRunning)
        k.update(connected: 1)   // a session still open after the sign-out: no requests without a sign-in
        #expect(!k.isRunning)
        k.signedIn()
        k.update(connected: 1)
        #expect(k.isRunning)
        k.stop()
        #expect(!k.isRunning)
    }

    @Test func theIntervalIsThirtyMinutesUnlessADevelopmentBuildOverridesIt() {
        #expect(SessionKeepAlive.interval(override: nil, development: true) == 1800)
        #expect(SessionKeepAlive.interval(override: "20", development: true) == 20)
        #expect(SessionKeepAlive.interval(override: "20", development: false) == 1800)   // release builds ignore it
        #expect(SessionKeepAlive.interval(override: "0", development: true) == 1800)
    }

    @Test func expiryIsLoggedNotRepeatedEveryRequest() async throws {
        let c = Counter()
        c.outcome = .expired
        let k = SessionKeepAlive(interval: 0.03) { c.hit() }
        let lines = Counter()
        let box = NSLock()
        nonisolated(unsafe) var text: [String] = []
        k.log = { line in box.withLock { text.append(line) }; _ = lines.hit() }
        k.update(connected: 1)
        for _ in 0..<100 where c.count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        k.update(connected: 0)
        let expiredLines = box.withLock { text.filter { $0.contains("expired") } }
        #expect(c.count >= 3 && expiredLines.count == 1)
    }

    @Test func aPingNeverRenewsAnExpiredSignIn() async throws {
        let transport = ListTransport()
        transport.expired = true
        let renewed = Counter()
        let renewal = SignInRenewal { _ in _ = renewed.hit() }
        var store = StoreClient(transport: transport, base: URL(string: "https://gw.example.test/welcome/")!, direct: false)
        store.renewal = renewal
        for _ in 0..<3 { #expect(await SessionKeepAlive.ping(store) == .expired) }
        #expect(renewed.count == 0 && renewal.renewals == 0)
        transport.expired = false
        #expect(await SessionKeepAlive.ping(store) == .alive)
        #expect(transport.lock.withLock { transport.paths.allSatisfy { $0.hasSuffix("Sessions/List") } })
    }
}
