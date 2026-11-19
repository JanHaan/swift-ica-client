import Testing
import Foundation
@testable import ICAKit

/// docs/56 §5: the security rule for links from the session.
struct URLRedirectFilterTests {
    private func opens(_ s: String) -> Bool {
        if case .open = URLRedirectFilter.check(s) { return true }
        return false
    }
    private func refusal(_ s: String) -> URLRedirectFilter.Refusal? {
        if case .refused(let r) = URLRedirectFilter.check(s) { return r }
        return nil
    }

    @Test func allowedSchemesOpen() {
        #expect(opens("http://example.test/page?q=1&r=%41"))
        #expect(opens("https://example.test:8443/a/b#frag"))
        #expect(opens("HTTP://EXAMPLE.TEST/upper"))
        #expect(opens("  https://example.test/trimmed  "))
        #expect(opens("https://user@example.test/"))
        #expect(opens("https://[2001:db8::1]/v6"))
        #expect(opens("http://10.1.2.3/intranet"))
        #expect(opens("http://192.168.64.5:8123/lab"))
        #expect(opens("https://intranet.example.test./"))
    }

    @Test func otherSchemesAndPathsRefused() {
        #expect(refusal("mailto:someone@example.test") == .scheme("mailto"))
        #expect(refusal("file:///C:/Windows/win.ini") == .scheme("file"))
        #expect(refusal("FILE:///etc/passwd") == .scheme("file"))
        #expect(refusal("javascript:alert(1)") == .scheme("javascript"))
        #expect(refusal("ftp://example.test/x") == .scheme("ftp"))
        #expect(refusal("rtsp://example.test/x") == .scheme("rtsp"))
        #expect(refusal("labscheme:anything") == .scheme("labscheme"))
        #expect(refusal("x-apple-systempreferences:com.apple.preference.security") == .scheme("x-apple-systempreferences"))
        #expect(refusal("smb://server/share") == .scheme("smb"))
        #expect(refusal("data:text/html,<b>x</b>") == .scheme("data"))
        #expect(refusal("C:\\Windows\\win.ini") == .scheme(""))
        #expect(refusal("\\\\server\\share\\x.txt") == .scheme(""))
        #expect(refusal("/etc/passwd") == .scheme(""))
        #expect(refusal("example.test/no-scheme") == .scheme(""))
        #expect(refusal("1http://example.test") == .scheme(""))
    }

    @Test func malformedRefused() {
        #expect(refusal("") == .empty)
        #expect(refusal("   ") == .empty)
        #expect(refusal("http://") == .notAURL || refusal("http://") == .noHost)
        #expect(refusal("http:///path-only") == .noHost)
        #expect(refusal("https:no-slashes") == .noHost)
        #expect(refusal("http://exa mple.test/") == .notAURL)
        #expect(refusal("http://example.test/a b") == .notAURL)
        #expect(refusal("http://example.test/%zz") == .notAURL)
        #expect(refusal("http://example.test/\u{0}x") == .controlCharacter)
        #expect(refusal("http://example.test/\r\nx") == .controlCharacter)
        #expect(refusal("http://example.test/\u{85}") == .controlCharacter)
        #expect(refusal("https://example.test/\u{202E}gpj.exe") == .controlCharacter)
        #expect(refusal("https://exa\u{200B}mple.test/") == .controlCharacter)
        #expect(refusal("\u{FEFF}https://example.test/") == .controlCharacter)
    }

    /// A local address in a link from the session names the server's side, never this Mac.
    @Test func localHostsRefused() {
        for s in ["http://localhost/", "http://LOCALHOST:8080/x", "http://app.localhost/", "http://localhost./",
                  "http://127.0.0.1:8123/x", "http://127.1/", "http://2130706433/", "http://0x7f.1/", "http://0177.0.0.1/",
                  "http://0.0.0.0/", "http://0/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/",
                  "http://[::]/", "http://[fe80::1]/", "http://[::ffff:127.0.0.1]/", "https://127.255.255.254/"] {
            #expect(refusal(s) == .localHost, "\(s)")
        }
        // A host that ends in a number but is no IPv4 address is no valid host for a browser either.
        #expect(refusal("http://1.2.3.4.5/") == .notAURL)
        #expect(refusal("http://example.0x/") == .notAURL)
        #expect(refusal("http://example.123/") == .notAURL)
        // Percent-encoded hosts are not decoded here (a browser would: %6c%6f = "lo").
        #expect(refusal("http://%6c%6fcalhost/") == .notAURL)
        #expect(refusal("http://ｌｏｃａｌｈｏｓｔ/") == .notAURL)
    }

    @Test func whatwgIPv4Forms() {
        #expect(URLRedirectFilter.whatwgIPv4("127.0.0.1") == [127, 0, 0, 1])
        #expect(URLRedirectFilter.whatwgIPv4("127.1") == [127, 0, 0, 1])
        #expect(URLRedirectFilter.whatwgIPv4("2130706433") == [127, 0, 0, 1])
        #expect(URLRedirectFilter.whatwgIPv4("0x7F.0.0.1") == [127, 0, 0, 1])
        #expect(URLRedirectFilter.whatwgIPv4("0177.1") == [127, 0, 0, 1])
        #expect(URLRedirectFilter.whatwgIPv4("10.0.0.1.") == [10, 0, 0, 1])
        #expect(URLRedirectFilter.whatwgIPv4("256.0.0.1") == nil)
        #expect(URLRedirectFilter.whatwgIPv4("1.2.3.4.5") == nil)
        #expect(URLRedirectFilter.whatwgIPv4("1.2.65536") == nil)
        #expect(URLRedirectFilter.whatwgIPv4("example.test") == nil)
    }

    @Test func lengthLimit() {
        let base = "https://example.test/"
        let atLimit = base + String(repeating: "a", count: URLRedirectFilter.maxLength - base.count)
        #expect(opens(atLimit))
        #expect(refusal(atLimit + "a") == .tooLong(URLRedirectFilter.maxLength + 1))
        #expect(refusal(base + String(repeating: "b", count: 100_000)) == .tooLong(100_000 + base.count))
    }

    @Test func logSummaryHidesPathAndAddress() throws {
        let url = try #require(URL(string: "https://sso.example.test/cb?ticket=SECRETVALUE"))
        let line = URLRedirectFilter.logSummary(url)
        #expect(line == "https://sso.example.test (46 characters)")
        #expect(!line.contains("SECRET"))
        #expect(URLRedirectFilter.logSummary(raw: "file:///Users/someone/secret") == "file: (28 characters)")
        #expect(URLRedirectFilter.logSummary(raw: "C:\\x") == "no scheme (4 characters)")
    }
}

/// docs/56 §5.3: at most `limit` opens in any `window` seconds.
struct URLRedirectLimiterTests {
    /// The verdicts for opens at `times`, in order.
    private func run(_ l: inout URLRedirectLimiter, _ times: [Double]) -> [Bool] { times.map { l.allow(at: $0) } }

    @Test func burstIsCut() {
        var l = URLRedirectLimiter(limit: 5, window: 30)
        let results = run(&l, (0..<8).map { 100 + Double($0) * 0.1 })
        #expect(results == [true, true, true, true, true, false, false, false])
        let first = l.takeDropped(), second = l.takeDropped()
        #expect(first == 3 && second == 0)
    }

    @Test func windowSlides() {
        var l = URLRedirectLimiter(limit: 2, window: 10)
        // the open at 0 leaves the window at 10, the one at 5 at 15
        #expect(run(&l, [0, 5, 9.9, 10, 14.9, 15]) == [true, true, false, true, false, true])
    }

    @Test func refusedOpensDoNotExtendTheWindow() {
        var l = URLRedirectLimiter(limit: 1, window: 10)
        #expect(run(&l, [0, 1, 2, 5, 9.9, 10]) == [true, false, false, false, false, true])
    }

    @Test func defaults() {
        let l = URLRedirectLimiter()
        #expect(l.limit == 5 && l.window == 30)
    }
}

/// docs/56 §3: the 0x0E request and 0x0A reply on CTXCTL, as the lab VDA and the stock client exchanged them.
struct URLRedirectWireTests {
    private func hex(_ text: String) -> [UInt8] { text.split(separator: " ").map { UInt8($0, radix: 16)! } }

    /// ref-url2: `2d00 0e00 04000000 "http://127.0.0.1:8123/h2c-http?q=1&r=%41" 00` (neutral host here).
    static let request = ControlWire.message(ControlWire.Command.openURL,
                                             [4, 0, 0, 0] + Array("http://example.test/page?q=1&r=%41".utf8) + [0])

    @Test func parsesTheCapturedLayout() {
        #expect(Array(Self.request.prefix(4)) == [UInt8(Self.request.count - 4), 0, 0x0E, 0])
        #expect(URLRedirectWire.url(fromPayload: Array(Self.request.dropFirst(4))) == "http://example.test/page?q=1&r=%41")
        // No NUL: the string runs to the end. Another offset is honoured.
        #expect(URLRedirectWire.url(fromPayload: [4, 0, 0, 0] + Array("https://a.test".utf8)) == "https://a.test")
        #expect(URLRedirectWire.url(fromPayload: [6, 0, 0, 0, 0xAA, 0xBB] + Array("http://b.test".utf8) + [0, 0x41]) == "http://b.test")
    }

    @Test func malformedPayloads() {
        #expect(URLRedirectWire.url(fromPayload: []) == nil)
        #expect(URLRedirectWire.url(fromPayload: [4, 0, 0]) == nil)
        #expect(URLRedirectWire.url(fromPayload: [3, 0, 0, 0, 0x41]) == nil)          // offset inside the header
        #expect(URLRedirectWire.url(fromPayload: [9, 0, 0, 0, 0x41]) == nil)          // offset past the end
        #expect(URLRedirectWire.url(fromPayload: [0xFF, 0xFF, 0xFF, 0xFF, 0x41]) == nil)
        #expect(URLRedirectWire.url(fromPayload: [4, 0, 0, 0, 0xC3, 0x28]) == nil)    // not UTF-8
        #expect(URLRedirectWire.url(fromPayload: [4, 0, 0, 0]) == "")
        #expect(URLRedirectWire.url(fromPayload: [4, 0, 0, 0] + [UInt8](repeating: 0x61, count: URLRedirectWire.maxPayload + 1)) == nil)
    }

    @Test func replyBytes() {
        #expect(URLRedirectWire.reply(opened: true) == hex("04 00 0A 00 00 00 00 00"))
        #expect(URLRedirectWire.reply(opened: false) == hex("04 00 0A 00 01 00 00 00"))
    }
}

/// ControlEngine's side of docs/56: every 0x0E gets exactly one 0x0A, in arrival order.
struct ControlEngineURLTests {
    final class Harness {
        let engine = ControlEngine()
        var sent: [[UInt8]] = []
        var asked: [String] = []
        var pending: [(Bool) -> Void] = []
        init(handler: Bool = true) {
            engine.output = { [unowned self] out in if case .channel(let d) = out { sent.append([UInt8](d)) } }
            if handler {
                engine.onOpenURL = { [unowned self] url, reply in asked.append(url); pending.append(reply) }
            }
        }
        func request(_ url: String) {
            engine.receive(Data(ControlWire.message(ControlWire.Command.openURL, [4, 0, 0, 0] + Array(url.utf8) + [0])))
        }
    }
    private let yes = URLRedirectWire.reply(opened: true), no = URLRedirectWire.reply(opened: false)

    @Test func withoutHandlerTheSessionOpensIt() {
        let h = Harness(handler: false)
        h.request("http://a.test/")
        #expect(h.sent == [no])
        #expect(h.engine.diagnostics.urlRequests == 1 && h.engine.diagnostics.urlReplies == [false])
    }

    @Test func repliesKeepArrivalOrder() {
        let h = Harness()
        h.request("http://a.test/1")
        h.request("http://a.test/2")
        h.request("http://a.test/3")
        #expect(h.asked == ["http://a.test/1", "http://a.test/2", "http://a.test/3"])
        h.pending[2](false)
        h.pending[1](true)
        #expect(h.sent.isEmpty)                 // #1 is still being decided
        h.pending[0](true)
        #expect(h.sent == [yes, yes, no])
        h.pending[0](false)                     // a second answer is ignored
        #expect(h.sent.count == 3)
    }

    @Test func unreadablePayloadIsAnsweredInTurn() {
        let h = Harness()
        h.request("http://a.test/1")
        h.engine.receive(Data(ControlWire.message(ControlWire.Command.openURL, [1, 0])))
        #expect(h.asked.count == 1 && h.sent.isEmpty)
        h.pending[0](true)
        #expect(h.sent == [yes, no])
        #expect(h.engine.diagnostics.malformed == 1)
    }

    @Test func splitAndMergedWrites() {
        let h = Harness()
        let one = ControlWire.message(ControlWire.Command.openURL, [4, 0, 0, 0] + Array("http://a.test/x".utf8) + [0])
        let two = ControlWire.message(ControlWire.Command.openURL, [4, 0, 0, 0] + Array("http://b.test/y".utf8) + [0])
        let stream = one + two
        h.engine.receive(Data(stream.prefix(7)))
        h.engine.receive(Data(stream.dropFirst(7)))
        #expect(h.asked == ["http://a.test/x", "http://b.test/y"])
    }

    @Test func noReplyAfterTheSessionEnded() {
        let h = Harness()
        h.request("http://a.test/1")
        h.engine.shutdown()
        h.pending[0](true)
        #expect(h.sent.isEmpty)
    }
}

/// docs/56 §4: the reachability check.
struct URLRedirectProbeTests {
    @Test func endpoints() throws {
        func ep(_ s: String) -> String? {
            URLRedirectProbe.endpoint(URL(string: s)!).map { "\($0.host) \($0.port)" }
        }
        #expect(ep("http://example.test/a") == "example.test 80")
        #expect(ep("https://example.test/a") == "example.test 443")
        #expect(ep("HTTPS://example.test:8443/") == "example.test 8443")
        #expect(ep("http://[2001:db8::1]:81/") == "2001:db8::1 81")
        #expect(ep("ftp://example.test/") == nil)
    }

    /// Loopback is prohibited for the check: a name that resolves to 127.0.0.1 (DNS rebinding) never counts as
    /// reachable, even with a listener there.
    @Test func loopbackNeverReachable() async throws {
        let listener = try NWListenerHelper()
        defer { listener.stop() }
        let port = try await listener.ready()
        let ok: Bool = await withCheckedContinuation { c in
            URLRedirectProbe.check(URL(string: "http://127.0.0.1:\(port)/")!, timeout: 2, queue: DispatchQueue(label: "probe")) { c.resume(returning: $0) }
        }
        #expect(!ok)
    }
}

import Network

/// A TCP listener on 127.0.0.1 with a system-assigned port.
final class NWListenerHelper: @unchecked Sendable {
    let listener: NWListener
    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
        listener.newConnectionHandler = { $0.start(queue: .global()); $0.cancel() }
    }
    func ready() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; c.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e): resumed = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "listener"))
        }
    }
    func stop() { listener.cancel() }
}
