import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-03: forgetting the saved login also deletes
// the persisted cookie jar (gateway/store session cookies). Offline, in a temporary folder.

@Suite struct L03ForgetCookiesTests {
    @Test func clearCookiesDeletingFileEmptiesJarAndFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macf-l03-\(UUID().uuidString).plist").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        let client = HTTPClient()
        client.setCookie(HTTPCookie(properties: [.name: "NSC_AAAC", .value: "x", .domain: "gw.example", .path: "/", .secure: "TRUE"])!)
        try client.saveCookies(to: file)
        #expect(FileManager.default.fileExists(atPath: file))
        let mode = (try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        client.clearCookies(deletingFile: file)
        #expect(client.cookieNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file))
        let fresh = HTTPClient()
        try fresh.loadCookies(from: file)
        #expect(fresh.cookieNames.isEmpty)
    }
}
