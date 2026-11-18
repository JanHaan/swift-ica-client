import Foundation

/// What the viewer does when its last connection ends (docs/90 §9.4). Quitting is right when the user's last app
/// closed; it is wrong when the user is still working in a window of the viewer itself, and when the launch failed
/// before any app window appeared: the app would vanish with the error message (VM scenario, mac-C).
public enum LastSessionPolicy {
    public struct Context: Equatable, Sendable {
        /// The user disconnected it (Connection Center, menu).
        public var byUser = false
        /// A window the user works in is open: Settings or the Connection Center.
        public var userWindowOpen = false
        /// Another launch is running or queued.
        public var launchPending = false
        /// The connection showed at least one app window (`SessionController.reachedSeamless`).
        public var appeared = true
        /// An unattended run (ICAVIEWER_LAUNCH, hold, self-test): its scripts wait for the quit.
        public var automated = false
        public init(byUser: Bool = false, userWindowOpen: Bool = false, launchPending: Bool = false, appeared: Bool = true,
                    automated: Bool = false) {
            self.byUser = byUser; self.userWindowOpen = userWindowOpen; self.launchPending = launchPending
            self.appeared = appeared; self.automated = automated
        }
    }

    public enum Decision: Equatable, Sendable {
        case quit
        /// Stay; `showLauncher`: bring the launcher back (it carries the status line, e.g. why a launch failed).
        case stay(reason: String, showLauncher: Bool)
    }

    public static func decide(_ c: Context) -> Decision {
        if c.byUser { return .stay(reason: "disconnected by the user", showLauncher: !c.userWindowOpen) }
        if c.launchPending { return .stay(reason: "another launch is pending", showLauncher: false) }
        // Unattended (hold, self-test, ICAVIEWER_LAUNCH): nobody works in the windows, the script waits for the quit
        // (mac-C's nightly: an open Connection Center kept a hold run alive for 7 minutes).
        if c.automated { return .quit }
        if c.userWindowOpen { return .stay(reason: "Settings or the Connection Center is open", showLauncher: false) }
        if !c.appeared { return .stay(reason: "the launch failed before an app window appeared", showLauncher: true) }
        return .quit
    }
}
