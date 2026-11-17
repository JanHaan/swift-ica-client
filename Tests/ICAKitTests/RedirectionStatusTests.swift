import Testing
@testable import ICAKit

// Refused-redirection rule (D118): host data on the feature's channel = in use; none 20 s after the first app window
// = refused by server policy.

@Test func channelsMapToFeatures() {
    #expect(RedirectionFeature.forChannel(17) == .clipboard)
    #expect(RedirectionFeature.forChannel(29) == .fileCopy)
    #expect(RedirectionFeature.forChannel(10) == .drives)
    #expect(RedirectionFeature.forChannel(4) == .printing)
    #expect(RedirectionFeature.forChannel(19) == .audio)
    #expect(RedirectionFeature.forChannel(9) == nil)
}

@Test func waitingUntilSettledThenRefused() {
    var s = RedirectionStatus(requested: [.clipboard, .printing], settleSeconds: 20)
    #expect(s.state(.clipboard, at: 100) == .waiting)           // no app window yet: never refused
    s.appWindowShown(at: 10)
    s.appWindowShown(at: 50)                                     // only the first window starts the clock
    #expect(s.settlesAt == 30)
    #expect(s.state(.clipboard, at: 29.9) == .waiting)
    #expect(s.state(.clipboard, at: 30) == .refused)
    #expect(s.refused(at: 30) == [.clipboard, .printing])
}

@Test func hostDataMeansInUseEvenLate() {
    var s = RedirectionStatus(requested: [.clipboard, .audio], settleSeconds: 20)
    let r1 = s.hostData(channel: 17)
    #expect(r1 == .clipboard)
    let r2 = s.hostData(channel: 17)
    #expect(r2 == nil)                      // reported once
    let r3 = s.hostData(channel: 9)
    #expect(r3 == nil)                       // Thinwire: not a redirection
    s.appWindowShown(at: 0)
    #expect(s.state(.clipboard, at: 60) == .inUse)
    #expect(s.state(.audio, at: 60) == .refused)
    s.hostData(channel: 19)                                      // audio starts late: no longer refused
    #expect(s.state(.audio, at: 61) == .inUse)
    #expect(s.refused(at: 61).isEmpty)
}

@Test func notRequestedFeaturesAreNeverReported() {
    var s = RedirectionStatus(requested: [.clipboard], settleSeconds: 20)
    let r4 = s.hostData(channel: 10)
    #expect(r4 == nil)                      // drives not announced
    s.appWindowShown(at: 0)
    #expect(s.state(.drives, at: 100) == .notRequested)
    #expect(s.refused(at: 100) == [.clipboard])
    let r5 = s.attempt(.drives, at: 100)
    #expect(!r5)
}

@Test func noticeOncePerFeatureAndOnlyWhenRefused() {
    var s = RedirectionStatus(requested: [.clipboard, .printing, .audio], settleSeconds: 20)
    s.hostData(channel: 19)
    s.appWindowShown(at: 0)
    let r6 = s.attempt(.clipboard, at: 5)
    #expect(!r6)                       // still waiting: no notice
    let r7 = s.attempt(.clipboard, at: 25)
    #expect(r7)                       // first blocked paste
    let r8 = s.attempt(.clipboard, at: 26)
    #expect(!r8)                      // never again this session
    let r9 = s.attempt(.printing, at: 27)
    #expect(r9)                        // another feature has its own notice
    let r10 = s.attempt(.audio, at: 28)
    #expect(!r10)                       // in use: nothing to say
}

@Test func fileCopyFollowsARefusedClipboard() {
    // labuser2 (D118): no clipboard bytes, but the host's CTXGDT opening exchange arrives anyway.
    var s = RedirectionStatus(requested: [.clipboard, .fileCopy], settleSeconds: 20)
    s.hostData(channel: 29)
    s.appWindowShown(at: 0)
    #expect(s.state(.fileCopy, at: 10) == .inUse)
    #expect(s.refused(at: 30) == [.clipboard, .fileCopy])
    // With the clipboard in use, CTXGDT traffic decides.
    var t = RedirectionStatus(requested: [.clipboard, .fileCopy], settleSeconds: 20)
    t.hostData(channel: 17)
    t.hostData(channel: 29)
    t.appWindowShown(at: 0)
    #expect(t.refused(at: 30).isEmpty)
}
