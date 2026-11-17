import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-04: no HTTPS → HTTP downgrade (redirects, later
// requests) and logon forms post only to the account's own origin. Offline: every refusal happens before the network.

@Suite struct F04TransportDowngradeTests {
    private func u(_ s: String) -> URL { URL(string: s)! }

    @Test func redirectsNeverLeaveHTTPSForPlainHTTP() {
        #expect(!HTTPClient.redirectAllowed(from: u("https://gw.example/a"), to: u("http://gw.example/a/")))
        #expect(!HTTPClient.redirectAllowed(from: u("https://gw.example/a"), to: u("http://other.example/")))
        #expect(HTTPClient.redirectAllowed(from: u("https://gw.example/a"), to: u("https://gw.example/b")))
        #expect(HTTPClient.redirectAllowed(from: u("https://gw.example/a"), to: u("https://idp.example/saml")))
        #expect(HTTPClient.redirectAllowed(from: u("http://10.0.0.5/Citrix/StoreWeb"), to: u("http://10.0.0.5/Citrix/StoreWeb/")))
        #expect(!HTTPClient.redirectAllowed(from: u("https://gw.example/a"), to: nil))
    }

    @Test func sameOriginComparesSchemeHostAndDefaultPort() {
        #expect(HTTPClient.sameOrigin(u("https://GW.example/x"), u("https://gw.example:443/")))
        #expect(HTTPClient.sameOrigin(URL(string: "nf/auth/doAuthentication.do", relativeTo: u("https://gw.example/"))!, u("https://gw.example/")))
        #expect(!HTTPClient.sameOrigin(u("http://gw.example/x"), u("https://gw.example/")))
        #expect(!HTTPClient.sameOrigin(u("https://gw.example:8443/x"), u("https://gw.example/")))
        #expect(!HTTPClient.sameOrigin(u("https://evil.example/x"), u("https://gw.example/")))
    }

    @Test func plainHTTPToAHostReachedOverHTTPSIsRefusedBeforeTheNetwork() async {
        let client = HTTPClient()
        client.trace = { _ in }
        client.noteSecure(u("https://store.example/Citrix/StoreWeb/"))
        await #expect(throws: HTTPClient.Failure.downgrade("store.example")) {
            _ = try await client.send("GET", self.u("http://STORE.example/Citrix/StoreWeb/Resources/List"))
        }
        #expect(client.downgradedHost(u("http://10.0.0.5/Citrix/StoreWeb/")) == nil)   // plain-HTTP lab stores stay usable
        #expect(client.downgradedHost(u("https://store.example/")) == nil)
    }

    @Test func gatewayFormsPostOnlyToTheGatewayOrigin() async throws {
        var logon = GatewayLogon(http: HTTPClient(), base: u("https://gw.example/"), languages: ["en-US"])
        var sent: [URL] = []
        logon.transport = { _, url, _, _ in
            sent.append(url.absoluteURL)
            return HTTPClient.Response(status: 200, headers: [:], body: Data(), url: url)
        }
        for target in ["https://evil.example/nf/auth/doAuthentication.do", "http://gw.example/nf/auth/doAuthentication.do",
                       "//evil.example/steal"] {
            await #expect(throws: GatewayLogon.Failure.self) { _ = try await logon.send("POST", target, form: [("passwd", "x")]) }
        }
        #expect(sent.isEmpty)
        _ = try await logon.send("POST", "/nf/auth/doAuthentication.do", form: [])
        #expect(sent == [u("https://gw.example/nf/auth/doAuthentication.do")])
    }

    @Test func storeFrontFormsPostOnlyToTheStoreOrigin() async throws {
        var logon = StoreFrontLogon(http: HTTPClient(), base: u("https://sf.example/Citrix/StoreWeb/"), languages: ["en-US"])
        logon.http.trace = { _ in }
        var sent: [URL] = []
        logon.transport = { _, url, _, _ in
            sent.append(url)
            return HTTPClient.Response(status: 200, headers: [:], body: Data(), url: url)
        }
        await #expect(throws: GatewayLogon.Failure.self) { _ = try await logon.send("https://evil.example/ExplicitAuth/LoginAttempt") }
        await #expect(throws: GatewayLogon.Failure.self) { _ = try await logon.send("http://sf.example/Citrix/StoreWeb/ExplicitAuth/LoginAttempt") }
        #expect(sent.isEmpty)
        _ = try await logon.send("ExplicitAuth/LoginAttempt")
        #expect(sent.map(\.absoluteString) == ["https://sf.example/Citrix/StoreWeb/ExplicitAuth/LoginAttempt"])
    }
}
