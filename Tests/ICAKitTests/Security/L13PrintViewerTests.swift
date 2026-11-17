import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-13: a host's PDF opens in Preview or nowhere.

@Suite struct L13PrintViewerTests {
    @Test func onlyPreviewIsAsked() {
        var asked: [String] = []
        let found = PrintDocument.viewer { asked.append($0); return URL(fileURLWithPath: "/System/Applications/Preview.app") }
        #expect(asked == ["com.apple.Preview"] && found != nil)
        #expect(PrintDocument.viewer { _ in nil } == nil)               // no fallback to the default PDF app
    }
}
