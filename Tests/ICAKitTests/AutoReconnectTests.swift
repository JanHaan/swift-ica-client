import Foundation
import Testing
@testable import ICAKit

/// docs/90 §9.6 (D86): when an automatic reconnect starts, its schedule, and one per session.
@Suite struct AutoReconnectTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    typealias Plan = AutoReconnect.Plan

    private func info(_ cause: CGPTransport.GiveUp.Cause) -> CGPTransport.GiveUp {
        CGPTransport.giveUpInfo(cause, notBefore: t0.addingTimeInterval(180))
    }

    private func skip(_ cause: CGPTransport.GiveUp.Cause, mode: AutoReconnect.Mode = .automatic,
                      automated: Bool = false, userEnded: Bool = false) -> AutoReconnect.Skip? {
        AutoReconnect.skipReason(info(cause), mode: mode, automated: automated, userEnded: userEnded)
    }

    // MARK: Triggers

    @Test func defaultIsAutomatic() {
        #expect(AutoReconnect.Mode.defaultMode == .automatic)
    }

    @Test func srGiveUpsStartAnAutomaticReconnect() {
        #expect(skip(.deadline) == nil)
        #expect(skip(.offline) == nil)
        #expect(skip(.refused(.refused)) == nil)
        #expect(skip(.refused(.beyondQueue(serverNextSeq: 9, firstUnacked: 3, queued: 5))) == nil)
        #expect(skip(.queueOverflow) == nil)
        #expect(skip(.channelRefused(2)) == nil)
        #expect(skip(.serverFinish(reason: 0x01)) == nil)   // SR ticket expired
        #expect(skip(.serverFinish(reason: 0x11)) == nil)   // gateway rejected the reconnect ticket
    }

    @Test func endedSessionsAreNotReconnected() {
        #expect(skip(.serverFinish(reason: 0x00)) == .sessionEnded)
        #expect(skip(.serverFinish(reason: 0x02)) == .serverShutdown)
        #expect(skip(.serverFinish(reason: 0x03)) == .adminDisconnected)
    }

    @Test func userEndAutomationAndSettingWin() {
        #expect(skip(.deadline, userEnded: true) == .userEnded)
        #expect(skip(.serverFinish(reason: 0x00), userEnded: true) == .userEnded)
        #expect(skip(.deadline, automated: true) == .automatedRun)
        #expect(skip(.deadline, mode: .ask) == .settingAsk)
        // A session that ended stays ended whatever the setting says.
        #expect(skip(.serverFinish(reason: 0x00), mode: .ask) == .sessionEnded)
    }

    // MARK: Schedule

    @Test func firstAttemptGoesAtOnceWhenOnline() {
        var p = Plan(start: t0, notBefore: nil)
        #expect(p.step(now: t0, online: true, alreadyOpen: false) == .attempt(1, of: 5))
        #expect(p.step(now: t0.addingTimeInterval(1), online: true, alreadyOpen: false) == .inProgress(1))
    }

    @Test func waitsForTheServersHoldFirst() {
        let hold = t0.addingTimeInterval(120)
        var p = Plan(start: t0, notBefore: hold)
        #expect(p.step(now: t0, online: true, alreadyOpen: false) == .wait(until: hold, .serverHold))
        #expect(p.step(now: hold, online: true, alreadyOpen: false) == .attempt(1, of: 5))
    }

    @Test func failedAttemptsBackOffThenGiveUp() {
        var p = Plan(start: t0, notBefore: nil)
        var now = t0
        #expect(p.step(now: now, online: true, alreadyOpen: false) == .attempt(1, of: 5))
        for (n, pause) in [(2, 10.0), (3, 30.0), (4, 60.0), (5, 120.0)] {
            p.attemptFailed(now: now, online: true)
            #expect(p.step(now: now.addingTimeInterval(1), online: true, alreadyOpen: false)
                    == .wait(until: now.addingTimeInterval(pause), .backoff))
            now = now.addingTimeInterval(pause)
            #expect(p.step(now: now, online: true, alreadyOpen: false) == .attempt(n, of: 5))
        }
        p.attemptFailed(now: now, online: true)
        #expect(p.step(now: now, online: true, alreadyOpen: false) == .giveUp(.attempts))
        #expect(now.timeIntervalSince(t0) < Plan.budget)
    }

    @Test func offlineWaitsForTheNetworkThenSettles() {
        var p = Plan(start: t0, notBefore: nil)
        #expect(p.step(now: t0, online: false, alreadyOpen: false) == .waitForNetwork(until: t0.addingTimeInterval(600)))
        let back = t0.addingTimeInterval(240)
        #expect(p.step(now: back, online: true, alreadyOpen: false) == .wait(until: back.addingTimeInterval(3), .networkSettle))
        #expect(p.step(now: back.addingTimeInterval(3), online: true, alreadyOpen: false) == .attempt(1, of: 5))
    }

    @Test func offlineBeyondTheBudgetGivesUp() {
        var p = Plan(start: t0, notBefore: nil)
        _ = p.step(now: t0, online: false, alreadyOpen: false)
        #expect(p.step(now: t0.addingTimeInterval(599), online: false, alreadyOpen: false) == .waitForNetwork(until: t0.addingTimeInterval(600)))
        #expect(p.step(now: t0.addingTimeInterval(600), online: false, alreadyOpen: false) == .giveUp(.budget(offline: true)))
    }

    @Test func anAttemptThatFailsOfflineIsNotCounted() {
        var p = Plan(start: t0, notBefore: nil)
        #expect(p.step(now: t0, online: true, alreadyOpen: false) == .attempt(1, of: 5))
        p.attemptFailed(now: t0.addingTimeInterval(5), online: false)
        #expect(p.attempts == 0)
        #expect(p.step(now: t0.addingTimeInterval(5), online: false, alreadyOpen: false) == .waitForNetwork(until: t0.addingTimeInterval(600)))
        #expect(p.step(now: t0.addingTimeInterval(60), online: true, alreadyOpen: false) == .wait(until: t0.addingTimeInterval(63), .networkSettle))
        #expect(p.step(now: t0.addingTimeInterval(63), online: true, alreadyOpen: false) == .attempt(1, of: 5))
    }

    @Test func backoffPastTheBudgetEndsAtTheDeadline() {
        var p = Plan(start: t0, notBefore: nil)
        let late = t0.addingTimeInterval(595)
        _ = p.step(now: t0, online: false, alreadyOpen: false)
        _ = p.step(now: late, online: true, alreadyOpen: false)
        #expect(p.step(now: late.addingTimeInterval(3), online: true, alreadyOpen: false) == .attempt(1, of: 5))
        p.attemptFailed(now: late.addingTimeInterval(4), online: true)
        #expect(p.step(now: late.addingTimeInterval(4), online: true, alreadyOpen: false) == .wait(until: p.deadline, .backoff))
        #expect(p.step(now: p.deadline, online: true, alreadyOpen: false) == .giveUp(.budget(offline: false)))
    }

    @Test func reconnectNowSkipsThePauseButNotTheHold() {
        var p = Plan(start: t0, notBefore: nil)
        _ = p.step(now: t0, online: true, alreadyOpen: false)
        p.attemptFailed(now: t0, online: true)
        p.skipPause(now: t0.addingTimeInterval(2))
        #expect(p.step(now: t0.addingTimeInterval(2), online: true, alreadyOpen: false) == .attempt(2, of: 5))

        let hold = t0.addingTimeInterval(100)
        var q = Plan(start: t0, notBefore: hold)
        q.skipPause(now: t0)
        #expect(q.step(now: t0, online: true, alreadyOpen: false) == .wait(until: hold, .serverHold))
    }

    @Test func aSessionOpenAgainEndsThePlan() {
        var p = Plan(start: t0, notBefore: t0.addingTimeInterval(100))
        #expect(p.step(now: t0, online: true, alreadyOpen: true) == .alreadyOpen)
        #expect(p.attempts == 0)
    }

    @Test func failureWithoutAnAttemptIsIgnored() {
        var p = Plan(start: t0, notBefore: nil)
        p.attemptFailed(now: t0, online: true)
        #expect(p.attempts == 0)
        #expect(p.step(now: t0, online: true, alreadyOpen: false) == .attempt(1, of: 5))
    }

    // MARK: One per session

    @Test func oneReconnectPerSession() {
        var r = AutoReconnect.Registry()
        let shared = AutoReconnect.sessionKey(sharingKey: "key-a", connection: "c1")
        // A second connection with the same SessionsharingKey is the same session (docs/55).
        #expect(AutoReconnect.sessionKey(sharingKey: "key-a", connection: "c2") == shared)
        let first = r.claim(shared), second = r.claim(shared)
        #expect(first && !second)
        let other = AutoReconnect.sessionKey(sharingKey: "key-b", connection: "c3")
        let third = r.claim(other)
        #expect(third && r.count == 2)
        r.release(shared)
        #expect(!r.contains(shared))
        let again = r.claim(shared)
        #expect(again)
    }

    @Test func withoutASharingKeyTheConnectionIsTheSession() {
        let a = AutoReconnect.sessionKey(sharingKey: nil, connection: "c1")
        let b = AutoReconnect.sessionKey(sharingKey: "", connection: "c2")
        #expect(a != b)
        #expect(a != AutoReconnect.sessionKey(sharingKey: "c1", connection: "c1"))
    }
}
