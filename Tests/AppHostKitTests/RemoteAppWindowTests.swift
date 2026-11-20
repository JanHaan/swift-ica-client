import AppKit
import Testing
@testable import AppHostKit

/// D189: remote app windows are borderless (square corners) and add the AX and Window-menu facts a titled window
/// has for free. No window is created here (no window server in tests); the window class is checked in the VM (S31).
@Suite struct RemoteAppWindowTests {
    @Test func styleIsBorderlessClosableMiniaturizable() {
        let fixed = RemoteAppWindow.styleMask(resizable: false)
        #expect(!fixed.contains(.titled))
        #expect(!fixed.contains(.fullSizeContentView))
        #expect(fixed.contains(.closable) && fixed.contains(.miniaturizable))
        #expect(!fixed.contains(.resizable))
        #expect(RemoteAppWindow.styleMask(resizable: true).contains(.resizable))
        #expect(RemoteAppWindow.styleMask(resizable: true).subtracting(.resizable) == fixed)
    }

    @Test func windowsMenuListsFromFirstShowUntilExcludedOrClosed() {
        var m = WindowsMenuMembership()
        #expect(m.update(square: true, shown: false, excluded: false) == .none)     // created, not shown yet
        #expect(m.update(square: true, shown: true, excluded: false) == .add)
        #expect(m.update(square: true, shown: true, excluded: false) == .none)      // ordered again: no second item
        #expect(m.update(square: true, shown: false, excluded: false) == .none)     // minimised or briefly out: stays
        #expect(m.isListed)
        m.closed = true
        #expect(m.update(square: true, shown: false, excluded: false) == .remove)
        #expect(m.update(square: true, shown: true, excluded: false) == .none)      // never back after close
    }

    @Test func windowsMenuFollowsExclusion() {
        // A helper app shows the window: the main process excludes its (never shown) window.
        var helper = WindowsMenuMembership()
        #expect(helper.update(square: true, shown: false, excluded: true) == .none)
        #expect(helper.update(square: true, shown: true, excluded: true) == .none)
        // The helper died: the window comes back here (adoptLocally) and is listed.
        #expect(helper.update(square: true, shown: true, excluded: false) == .add)
        #expect(helper.update(square: true, shown: true, excluded: true) == .remove)
    }

    @Test func titledWindowsAreAppKitsBusiness() {
        var m = WindowsMenuMembership()
        #expect(m.update(square: false, shown: true, excluded: false) == .none)
        #expect(!m.isListed)
    }

    @Test func standardButtonElementPressesOnlyWhenEnabled() {
        var enabled = false
        var presses = 0
        let close = StandardButtonElement(.closeButton, window: nil, enabled: { enabled }, press: { presses += 1 })
        #expect(close.accessibilityRole() == .button)
        #expect(close.accessibilitySubrole() == .closeButton)
        #expect(!close.isAccessibilityEnabled())
        #expect(!close.accessibilityPerformPress())
        #expect(presses == 0)
        enabled = true
        #expect(close.isAccessibilityEnabled())
        #expect(close.accessibilityPerformPress())
        #expect(presses == 1)
        #expect(close.accessibilityFrame() == .zero)      // no window
        let zoom = StandardButtonElement(.zoomButton, window: nil, enabled: { true }, press: {})
        #expect(zoom.accessibilitySubrole() == .zoomButton)
    }
}
