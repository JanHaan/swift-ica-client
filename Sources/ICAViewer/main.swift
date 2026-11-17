import AppKit
import ICAKit

// Before anything reads the environment: a Developer ID build drops test and diagnostic switches (security review L-07).
let ignoredSwitches = TestSwitches.scrubProcessEnvironment()
setvbuf(stderr, nil, _IOLBF, 0)
if !ignoredSwitches.isEmpty { vlog("release build: ignored test switches: \(ignoredSwitches.joined(separator: ", "))") }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
FeedbackMenu.observeLaunch()   // Help → Report a Problem… (FeedbackMenu.swift)
app.run()
