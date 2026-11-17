import Testing
@testable import ICAKit

// The viewer stays after its last connection ends while the user works in Settings or the Connection Center, and
// after a failed launch (mac-C's VM scenario: the app quit with Settings open); it quits after the last app closed.

@Suite struct LastSessionPolicyTests {
    @Test func quitsWhenTheLastAppClosedNormally() {
        #expect(LastSessionPolicy.decide(.init()) == .quit)
        #expect(LastSessionPolicy.decide(.init(appeared: false, automated: true)) == .quit)   // test scripts wait for it
    }

    @Test func staysWithSettingsOrConnectionCenterOpen() {
        #expect(LastSessionPolicy.decide(.init(userWindowOpen: true)) == .stay(reason: "Settings or the Connection Center is open", showLauncher: false))
        #expect(LastSessionPolicy.decide(.init(userWindowOpen: true, appeared: false))
                == .stay(reason: "Settings or the Connection Center is open", showLauncher: false))
    }

    @Test func staysAfterAFailedInteractiveLaunchAndShowsTheLauncher() {
        #expect(LastSessionPolicy.decide(.init(appeared: false)) == .stay(reason: "the launch failed before an app window appeared", showLauncher: true))
    }

    @Test func userDisconnectAndPendingLaunchesStayAsBefore() {
        #expect(LastSessionPolicy.decide(.init(byUser: true)) == .stay(reason: "disconnected by the user", showLauncher: true))
        #expect(LastSessionPolicy.decide(.init(byUser: true, userWindowOpen: true)) == .stay(reason: "disconnected by the user", showLauncher: false))
        #expect(LastSessionPolicy.decide(.init(launchPending: true)) == .stay(reason: "another launch is pending", showLauncher: false))
    }
}
