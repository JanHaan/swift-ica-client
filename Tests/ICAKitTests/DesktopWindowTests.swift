import Foundation
import Testing
@testable import ICAKit

// D139: the stand-in window of a full desktop session.

@Test func desktopStandInCoversTheSessionAndIsAnAppWindow() {
    let w = TWIWindow.desktop(width: 3456, height: 1964, title: "Lab Desktop")
    #expect(w.isDesktop && w.id == TWIWindow.desktopID)
    #expect(w.kind == .appWindow && w.isVisible && !w.isMinimized && !w.isMenu)
    #expect(w.windowRect == TWIRect(left: 0, top: 0, right: 3456, bottom: 1964))
    #expect(w.clientRect == w.windowRect)
    #expect(w.appKey == "desktop:Lab Desktop" && w.title == "Lab Desktop")
    // Not resizable on the host side (the session size is fixed at connect).
    #expect(!TWIWindowControls(style: w.style).resizable)
}
