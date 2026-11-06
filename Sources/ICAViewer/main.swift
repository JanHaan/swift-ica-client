import AppKit

setvbuf(stderr, nil, _IOLBF, 0)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
FeedbackMenu.observeLaunch()   // Help → Report a Problem… (FeedbackMenu.swift)
app.run()
