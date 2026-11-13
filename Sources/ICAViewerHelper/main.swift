import AppHostKit
import AppKit

// Template helper for per-app Dock identity (docs/99 phase 1 spike). Copied, relabelled and re-signed
// per remote app by the host; launched with the host's broker name, a token and the host pid.
setvbuf(stderr, nil, _IOLBF, 0)
guard let launch = HelperLaunch.parse(CommandLine.arguments, environment: ProcessInfo.processInfo.environment) else {
    helperLog("usage: ICAViewerHelper --broker <name> --host-pid <pid> [--headless], token in $\(HelperLaunch.tokenVariable) (started by the host only)")
    exit(2)
}
unsetenv(HelperLaunch.tokenVariable)      // not inherited by anything this process starts
if launch.headless { runHeadless(launch) }
let app = NSApplication.shared
let delegate = HelperApp(launch: launch)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
