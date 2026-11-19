import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md §10, mac-S), findings L-21 and L-22: local hosts the link filter missed,
// and the cost of many link requests behind a slow one. Offline.

@Suite struct L21URLRedirectBoundsTests {
    private func refusal(_ s: String) -> URLRedirectFilter.Refusal? {
        if case .refused(let r) = URLRedirectFilter.check(s) { return r }
        return nil
    }

    /// L-21: 0.0.0.0/8 and the IPv4-compatible ::/96 forms name the Mac or nothing routable; they were opened.
    @Test func thisNetworkAndIPv4CompatibleHostsAreLocal() {
        #expect(refusal("http://0.0.0.1/") == .localHost)
        #expect(refusal("http://0.1.2.3:8080/x") == .localHost)
        #expect(refusal("http://0x00010203/") == .localHost)
        #expect(refusal("http://[::127.0.0.1]/") == .localHost)
        #expect(refusal("http://[::7f00:1]:631/") == .localHost)
        #expect(refusal("http://[::169.254.169.254]/") == .localHost)
        #expect(refusal("http://[::ffff:0.0.0.1]/") == .localHost)
        // Still refused as before, and still opened as before.
        #expect(refusal("http://a@127.0.0.1/") == .localHost)
        #expect(refusal("http://[::1]/") == .localHost)
        #expect(refusal("http://[::]/") == .localHost)
        #expect(refusal("http://ⓛocalhost/") == .notAURL)
        #expect(refusal("http://１２７.０.０.１/") == .notAURL)
        if case .open = URLRedirectFilter.check("http://1.0.0.1/") {} else { Issue.record("1.0.0.1 refused") }
        if case .open = URLRedirectFilter.check("https://[2001:db8::1]/") {} else { Issue.record("2001:db8::1 refused") }
        if case .open = URLRedirectFilter.check("https://xn--r8jz45g.example/") {} else { Issue.record("punycode refused") }
    }

    /// L-22: answers behind a slow first one cost O(1) each, and the diagnostics keep only the latest replies.
    @Test func manyRequestsBehindASlowOneStayCheap() {
        let engine = ControlEngine()
        var sent = 0
        engine.output = { out in if case .channel = out { sent += 1 } }
        var first: ((Bool) -> Void)?
        engine.onOpenURL = { _, reply in
            if first == nil { first = reply } else { reply(false) }
        }
        let message = Data(ControlWire.message(ControlWire.Command.openURL, [4, 0, 0, 0] + Array("http://a.test/".utf8) + [0]))
        let n = 50_000
        let start = Date()
        for _ in 0..<n { engine.receive(message) }
        #expect(sent == 0)        // all wait for the first
        first?(true)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(sent == n)
        #expect(engine.diagnostics.urlRepliesSent == n)
        #expect(engine.diagnostics.urlReplies.count == ControlEngine.Diagnostics.urlRepliesKept)
        #expect(engine.diagnostics.urlReplies.first == false && engine.diagnostics.urlReplies.last == false)
        // A late or repeated answer changes nothing.
        first?(false)
        #expect(sent == n)
    }
}
