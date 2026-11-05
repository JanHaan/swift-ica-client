import Testing
@testable import ICAKit

@Suite struct LaunchRetryTests {
    let early = "early drop: link closed before the session was established (EOF)"

    @Test func earlyDropsGetThreeRelaunchesWithGrowingPauses() {
        var r = LaunchRetry()
        #expect(r.next(reachedSeamless: false, endReason: early, terminating: false) == .relaunch(attempt: 1, of: 3, delay: 1))
        #expect(r.next(reachedSeamless: false, endReason: early, terminating: false) == .relaunch(attempt: 2, of: 3, delay: 3))
        #expect(r.next(reachedSeamless: false, endReason: early, terminating: false) == .relaunch(attempt: 3, of: 3, delay: 6))
        #expect(r.next(reachedSeamless: false, endReason: early, terminating: false) == .giveUp)
    }

    @Test func otherFailuresRelaunchOnce() {
        var r = LaunchRetry()
        #expect(r.next(reachedSeamless: false, endReason: "server closed", terminating: false) == .relaunch(attempt: 1, of: 1, delay: 0))
        #expect(r.next(reachedSeamless: false, endReason: "server closed", terminating: false) == .giveUp)
    }

    @Test func establishedSessionResetsCounters() {
        var r = LaunchRetry()
        _ = r.next(reachedSeamless: false, endReason: early, terminating: false)
        _ = r.next(reachedSeamless: false, endReason: early, terminating: false)
        #expect(r.next(reachedSeamless: true, endReason: "logoff", terminating: false) == .giveUp)
        #expect(r == LaunchRetry())
        #expect(r.next(reachedSeamless: false, endReason: early, terminating: false) == .relaunch(attempt: 1, of: 3, delay: 1))
    }

    @Test func noRelaunchWhileTerminating() {
        var r = LaunchRetry()
        #expect(r.next(reachedSeamless: false, endReason: early, terminating: true) == .giveUp)
        #expect(r == LaunchRetry())
    }
}
