import Foundation
import Testing
@testable import ICAKit

// D110: the store attestation of FreshLogonDetector, with the timings seen live.

private let logonUI = "%systemroot%\\system32\\logonui.exe"

@Test func labFastLogonIsFreshOnlyWithTheStoreAttestation() {
    let t0 = Date()
    // Lab L10 (raw 1494): host init and first INIT at 0.9 s, logon UI at 1.9 s, post-logon INIT at 3.25 s.
    func run(_ noPrior: Bool) -> FreshLogonDetector {
        var d = FreshLogonDetector(noPriorSession: noPrior)
        _ = d.thinwireInit(at: t0.addingTimeInterval(0.94))
        _ = d.hostInit(at: t0.addingTimeInterval(0.94))
        d.windowAdded(appKey: "exe:" + logonUI, at: t0.addingTimeInterval(1.94))
        #expect(d.thinwireInit(at: t0.addingTimeInterval(3.25)).map { ($0 * 100).rounded() / 100 } == 1.31)
        return d
    }
    let timingOnly = run(false)
    #expect(!timingOnly.isFresh && timingOnly.basis == nil)
    let attested = run(true)
    #expect(attested.isFresh && attested.basis == .store && attested.noPriorSession)
}

@Test func companyReconnectAfterTheLogonUIStaysAReconnectWithoutTheAttestation() {
    let t0 = Date()
    // Company farm (dock-p3): logon UI, then the second INIT 2.1 s and host init 2.2 s later; Sessions/List
    // listed the session, so there is no attestation.
    var d = FreshLogonDetector(noPriorSession: false)
    _ = d.thinwireInit(at: t0)
    _ = d.hostInit(at: t0)
    d.windowAdded(appKey: "exe:" + logonUI, at: t0.addingTimeInterval(1))
    _ = d.thinwireInit(at: t0.addingTimeInterval(3.1))
    _ = d.hostInit(at: t0.addingTimeInterval(3.2))
    #expect(!d.isFresh && d.sawLogonUI && d.basis == nil)
}

@Test func attestationNeedsTheLogonUIAndASecondInit() {
    let t0 = Date()
    // A plain reconnect shows no logon UI: never fresh, attestation or not.
    var plain = FreshLogonDetector(noPriorSession: true)
    for i in 0..<3 { _ = plain.thinwireInit(at: t0.addingTimeInterval(Double(i) * 10)) }
    #expect(!plain.isFresh && plain.basis == nil)
    // Logon UI seen, but no post-logon INIT yet: undecided.
    var early = FreshLogonDetector(noPriorSession: true)
    _ = early.thinwireInit(at: t0)
    early.windowAdded(appKey: "C:\\Windows\\System32\\LogonUI.exe", at: t0.addingTimeInterval(1))
    #expect(!early.isFresh)
    #expect(early.hostInit(at: t0.addingTimeInterval(1.5)) == nil)  // the first host init does not decide
    #expect(early.thinwireInit(at: t0.addingTimeInterval(2)) == 1)
    #expect(early.isFresh && early.basis == .store)
}

@Test func timingRuleStillDecidesFirstAndIsReported() {
    let t0 = Date()
    // Company fresh logon (V13): logon UI, host init 5.8 s later: timing decides even with the attestation.
    var d = FreshLogonDetector(noPriorSession: true)
    _ = d.hostInit(at: t0)
    d.windowAdded(appKey: "exe:" + logonUI, at: t0.addingTimeInterval(2.7))
    _ = d.hostInit(at: t0.addingTimeInterval(8.5))
    #expect(d.isFresh && d.basis == .timing)
    // Default init keeps the old behaviour (no attestation).
    #expect(!FreshLogonDetector().noPriorSession)
}
