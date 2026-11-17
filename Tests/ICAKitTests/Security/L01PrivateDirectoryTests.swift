import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-01: the viewer's `.session` folder (cookie jar,
// TOTP state) is 0700 even when it existed with another mode. Offline, in a temporary folder.

@Suite struct L01PrivateDirectoryTests {
    @Test func ensureDirectoryCreatesAndResetsTo0700() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macf-l01-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent(".session", isDirectory: true)
        #expect(PrivateFile.ensureDirectory(dir))
        func mode() throws -> Int { (try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try mode() == 0o700)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(PrivateFile.ensureDirectory(dir))
        #expect(try mode() == 0o700)
    }
}
