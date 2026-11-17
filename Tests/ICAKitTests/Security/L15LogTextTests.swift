import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-15: a name with a line break cannot forge a log
// line. Offline.

@Suite struct L15LogTextTests {
    @Test func lineBreaksAndControlsBecomeVisibleEscapes() {
        let forged = "Notepad\n2026-11-17T10:00:00.000Z keychain: stored password for <gateway>"
        let line = LogText.oneLine(forged)
        #expect(!line.contains("\n"))
        #expect(line == "Notepad\\n2026-11-17T10:00:00.000Z keychain: stored password for <gateway>")
        #expect(LogText.oneLine("a\r\nb") == "a\\r\\nb")
        #expect(LogText.oneLine("a\u{2028}b\u{85}c\u{1B}[31m") == "a\\u{2028}b\\u{85}c\\u{1B}[31m")
    }

    @Test func ordinaryTextIsUnchanged() {
        for text in ["session «Rechner»: 1 screen(s), display 1920x1080", "tab\tstays", "Zwischenablage: gesperrt ✓", ""] {
            #expect(LogText.oneLine(text) == text)
        }
    }
}
