import Foundation
import Testing
@testable import ICAKit

@Suite struct SignInTitleTests {
    private func title(_ s: String?, german: Bool = false) -> String {
        LoginSettings.signInTitle(for: s.flatMap { URL(string: $0) }, german: german)
    }

    @Test func hostOnly() {
        #expect(title("https://gw.example.com/") == "Sign In to gw.example.com — ICA Viewer")
    }

    @Test func portOnlyWhenNotDefault() {
        #expect(title("https://gw.example.com:8443/") == "Sign In to gw.example.com:8443 — ICA Viewer")
        #expect(title("https://gw.example.com:443/") == "Sign In to gw.example.com — ICA Viewer")
        #expect(title("http://10.77.0.11:80/") == "Sign In to 10.77.0.11 — ICA Viewer")
    }

    @Test func pathAndSchemeAreDropped() {
        #expect(title("http://store.example.com/Citrix/StoreWeb/") == "Sign In to store.example.com — ICA Viewer")
    }

    @Test func noAddress() {
        #expect(title(nil) == "Sign In — ICA Viewer")
        #expect(title(nil, german: true) == "Anmelden — ICA Viewer")
    }

    @Test func german() {
        #expect(title("https://gw.example.com:8443/x", german: true) == "Bei gw.example.com:8443 anmelden — ICA Viewer")
    }
}
