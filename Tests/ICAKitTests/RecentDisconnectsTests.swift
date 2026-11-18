import Foundation
import Testing
@testable import ICAKit

// Connection Center placeholders after a disconnect (mac-C's nightly: a stale "Disconnected — Notepad" row after a
// logoff while the server listed no sessions).

@Suite struct RecentDisconnectsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func bridgesTheGapUntilTheStoreHasCaughtUp() {
        var r = RecentDisconnects()
        r.disconnected(["Notepad"], at: t0)
        r.listed(requestedAt: t0.addingTimeInterval(1))                 // too early to reflect the disconnect
        #expect(r.visible(at: t0.addingTimeInterval(2), connectedApps: []).map(\.apps) == [["Notepad"]])
        r.listed(requestedAt: t0.addingTimeInterval(6))                 // now the store's answer counts
        #expect(r.visible(at: t0.addingTimeInterval(7), connectedApps: []).isEmpty)
    }

    @Test func aLogoffOrAReconnectEndsThePlaceholderAtOnce() {
        var r = RecentDisconnects()
        r.disconnected(["Notepad"], at: t0)
        r.disconnected(["Paint"], at: t0)
        r.loggedOff(["Notepad", "WordPad"])
        #expect(r.visible(at: t0.addingTimeInterval(1), connectedApps: []).map(\.apps) == [["Paint"]])
        #expect(r.visible(at: t0.addingTimeInterval(2), connectedApps: ["Paint"]).isEmpty)
    }

    @Test func neverLongerThanThirtySeconds() {
        var r = RecentDisconnects()
        r.disconnected(["Notepad"], at: t0)
        #expect(r.visible(at: t0.addingTimeInterval(30), connectedApps: []).count == 1)
        #expect(r.visible(at: t0.addingTimeInterval(31), connectedApps: []).isEmpty)
    }
}
