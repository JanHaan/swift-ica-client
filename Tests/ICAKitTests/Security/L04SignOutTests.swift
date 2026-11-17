import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-04: Sign Out and Forget end the gateway and
// store sessions at the servers, then drop the jar. Offline (mocked transport).

@Suite struct L04SignOutTests {
    private final class Recorder: @unchecked Sendable {
        var calls: [(method: String, url: String, headers: [String: String])] = []
    }

    private func client(cookies: [(String, String, String)]) -> HTTPClient {
        let http = HTTPClient()
        http.trace = { _ in }
        for (name, value, domain) in cookies {
            http.setCookie(HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!)
        }
        return http
    }

    @Test func gatewayAccountLogsOffTheStoreThenTheGatewayThenDropsTheJar() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macf-l04-\(UUID().uuidString).plist").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        let http = client(cookies: [("NSC_AAAC", "gw-session", "gw.example"), ("CsrfToken", "csrf-1", "gw.example")])
        try http.saveCookies(to: file)
        let rec = Recorder()
        let steps = await AccountSignOut.run(http: http, storeBase: URL(string: "https://gw.example/welcome/")!,
                                             gateway: URL(string: "https://gw.example/")!, cookieFile: file) { method, url, headers, _ in
            rec.calls.append((method, url.absoluteString, headers))
            return HTTPClient.Response(status: 200, headers: [:], body: Data(), url: url)
        }
        #expect(rec.calls.map(\.method) == ["POST", "GET"])
        #expect(rec.calls.map(\.url) == ["https://gw.example/welcome/Authentication/Logoff", "https://gw.example/cgi/logout"])
        #expect(rec.calls[0].headers["Csrf-Token"] == "csrf-1" && rec.calls[0].headers["X-Citrix-IsUsingHTTPS"] == "Yes")
        #expect(steps.map(\.status) == [200, 200])
        #expect(http.cookieNames.isEmpty && !FileManager.default.fileExists(atPath: file))
    }

    @Test func eachStepRunsEvenIfThePreviousFailed() async {
        struct Down: Error {}
        let http = client(cookies: [("NSC_AAAC", "x", "gw.example")])
        let rec = Recorder()
        let steps = await AccountSignOut.run(http: http, storeBase: URL(string: "https://gw.example/welcome/")!,
                                             gateway: URL(string: "https://gw.example/")!, cookieFile: nil) { method, url, headers, _ in
            rec.calls.append((method, url.absoluteString, headers))
            if url.path.hasSuffix("Logoff") { throw Down() }
            return HTTPClient.Response(status: 302, headers: [:], body: Data(), url: url)
        }
        #expect(rec.calls.count == 2)
        #expect(steps[0].status == nil && steps[1].status == 302)
        #expect(http.cookieNames.isEmpty)
    }

    @Test func directStoreHasNoGatewayStep() async {
        let http = client(cookies: [("CsrfToken", "c", "sf.example")])
        let rec = Recorder()
        _ = await AccountSignOut.run(http: http, storeBase: URL(string: "http://sf.example/Citrix/StoreWeb/")!,
                                     gateway: nil, cookieFile: nil) { method, url, headers, _ in
            rec.calls.append((method, url.absoluteString, headers))
            return HTTPClient.Response(status: 200, headers: [:], body: Data(), url: url)
        }
        #expect(rec.calls.map(\.url) == ["http://sf.example/Citrix/StoreWeb/Authentication/Logoff"])
        #expect(rec.calls[0].headers["X-Citrix-IsUsingHTTPS"] == "No")
    }
}
