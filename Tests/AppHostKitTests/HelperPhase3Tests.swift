import CoreGraphics
import Foundation
import Testing
@testable import AppHostKit

/// docs/99 §12 phase 3: the Settings switch, crash relaunch, session slots, the launcher shortcut, the Dock
/// menu, the menu-bar host and the icon message.
@Suite struct HelperAppsSwitchTests {
    @Test func defaultIsOnAndTheEnvironmentWinsBothWays() {
        #expect(HelperAppsSwitch.resolve(environment: nil, stored: nil) == (true, .defaultValue))
        #expect(HelperAppsSwitch.resolve(environment: nil, stored: false) == (false, .settings))
        #expect(HelperAppsSwitch.resolve(environment: nil, stored: true) == (true, .settings))
        #expect(HelperAppsSwitch.resolve(environment: "0", stored: true) == (false, .environment))
        #expect(HelperAppsSwitch.resolve(environment: "1", stored: false) == (true, .environment))
        #expect(HelperAppsSwitch.resolve(environment: " 0 ", stored: nil) == (false, .environment))
        // Anything else is not an override.
        #expect(HelperAppsSwitch.resolve(environment: "", stored: false) == (false, .settings))
        #expect(HelperAppsSwitch.resolve(environment: "yes", stored: nil) == (true, .defaultValue))
        #expect(HelperAppsSwitch.environmentVariable == "ICA_HELPER_APPS")
    }
}

@Suite struct HelperRelaunchPolicyTests {
    @Test func oncePerMinutePerKey() {
        var policy = HelperRelaunchPolicy()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let r1 = policy.shouldRelaunch("app:Editor", at: t0)
        #expect(r1)
        // Died again within the minute after the relaunch: fall back.
        let r2 = policy.shouldRelaunch("app:Editor", at: t0.addingTimeInterval(20))
        #expect(!r2)
        let r3 = policy.shouldRelaunch("app:Editor", at: t0.addingTimeInterval(59.9))
        #expect(!r3)
        // Another app is independent.
        let r4 = policy.shouldRelaunch("app:Rechner", at: t0.addingTimeInterval(30))
        #expect(r4)
        // A minute after the last relaunch it may come back once more.
        let r5 = policy.shouldRelaunch("app:Editor", at: t0.addingTimeInterval(60))
        #expect(r5)
        let r6 = policy.shouldRelaunch("app:Editor", at: t0.addingTimeInterval(61))
        #expect(!r6)
    }

    @Test func refusedAttemptsDoNotExtendTheWindow() {
        var policy = HelperRelaunchPolicy(window: 10)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let r7 = policy.shouldRelaunch("k", at: t0)
        #expect(r7)
        let r8 = policy.shouldRelaunch("k", at: t0.addingTimeInterval(9))
        #expect(!r8)
        let r9 = policy.shouldRelaunch("k", at: t0.addingTimeInterval(10))
        #expect(r9)
    }
}

@Suite struct HelperSessionSlotTests {
    @Test func firstSessionKeepsThePhaseOneKeyAndName() {
        #expect(HelperSessionSlots.key(appKey: "app:Text App", slot: 1) == "app:Text App")
        #expect(HelperSessionSlots.name("Text App", slot: 1) == "Text App")
    }

    @Test func furtherSessionsGetTheirOwnKeyAndName() {
        let k2 = HelperSessionSlots.key(appKey: "app:Text App", slot: 2)
        #expect(k2 != "app:Text App" && k2.hasPrefix("app:Text App"))
        #expect(HelperSessionSlots.key(appKey: "app:Text App", slot: 3) != k2)
        #expect(HelperSessionSlots.name("Text App", slot: 2) == "Text App (2)")
        // Own bundle id and directory, so LaunchServices starts a second instance.
        let l1 = HelperLabel(key: "app:Text App", name: "Text App"), l2 = HelperLabel(key: k2, name: "Text App (2)")
        #expect(HelperBundle.bundleIdentifier(for: l1) != HelperBundle.bundleIdentifier(for: l2))
        #expect(HelperBundle.relativePath(for: l2).hasSuffix("/Text App (2).app"))
    }

    @Test func smallestFreeSlot() {
        #expect(HelperSessionSlots.freeSlot(taken: []) == 1)
        #expect(HelperSessionSlots.freeSlot(taken: [1]) == 2)
        #expect(HelperSessionSlots.freeSlot(taken: [1, 2, 4]) == 3)
        #expect(HelperSessionSlots.freeSlot(taken: [2]) == 1)      // the first session's app quit: slot 1 is free again
    }
}

@Suite struct LauncherHotKeyTests {
    @Test func defaultIsTheApprovedShortcut() {
        #expect(LauncherHotKey.stored(nil) == .standard)
        #expect(LauncherHotKey.stored("nonsense") == .standard)
        #expect(LauncherHotKey.standard.title == "⌃⌥⌘L")
        #expect(LauncherHotKey.standard.shortcut == HelperMenu.launcherShortcut)
        #expect(LauncherHotKey.standard.raw == "ctrl-opt-cmd-l")
    }

    @Test func choicesRoundTripAndOff() {
        for choice in LauncherHotKey.choices { #expect(LauncherHotKey(raw: choice.raw) == choice) }
        #expect(LauncherHotKey.stored("off") == .off)
        #expect(LauncherHotKey.off.shortcut == nil && LauncherHotKey.off.carbonModifiers == 0)
        #expect(LauncherHotKey.choices.last == .off)
        #expect(Set(LauncherHotKey.choices).count == LauncherHotKey.choices.count)
    }

    /// Carbon's cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000 (Events.h).
    @Test func carbonModifierBits() {
        #expect(LauncherHotKey.standard.carbonModifiers == 0x100 | 0x800 | 0x1000)
        #expect(LauncherHotKey(HelperShortcut("l", [.command, .shift])).carbonModifiers == 0x300)
    }
}

@Suite struct HelperDockMenuTests {
    @Test func windowsThenLauncherItems() {
        let items = HelperDockMenu.items(windows: [.init(id: 7, title: "Notes.txt - Editor", isKey: false),
                                                   .init(id: 3, title: "  ", isKey: true)],
                                         untitled: "Text App", german: false)
        #expect(items.map(\.title) == ["Text App", "Notes.txt - Editor", "", "Show Launcher", "Connection Center"])
        #expect(items.map(\.action) == [.window(3), .window(7), nil, .host(.showLauncher), .host(.connectionCenter)])
        #expect(items.map(\.checked) == [true, false, false, false, false])
        #expect(items[2].isSeparator)
    }

    @Test func germanAndNoWindows() {
        let items = HelperDockMenu.items(windows: [], untitled: "Rechner", german: true)
        #expect(items.map(\.title) == ["Launcher zeigen", "Verbindungscenter"])
        let long = HelperDockMenu.items(windows: [.init(id: 1, title: String(repeating: "x", count: 300), isKey: false)],
                                        untitled: "A", german: false)
        #expect(long[0].title.count == 80)
    }
}

@Suite struct MenuBarPolicyTests {
    @Test func menuBarOnlyWhileHelpersShowEverything() {
        #expect(MenuBarPolicy.menuBarOnly(helpersEnabled: true, helperWindows: true, localAppWindows: false))
        // A fallback window (or the logon console) lives in this process: keep the Dock tile for it.
        #expect(!MenuBarPolicy.menuBarOnly(helpersEnabled: true, helperWindows: true, localAppWindows: true))
        // Launcher-only use, or no helper yet.
        #expect(!MenuBarPolicy.menuBarOnly(helpersEnabled: true, helperWindows: false, localAppWindows: false))
        // Helpers off: as before.
        #expect(!MenuBarPolicy.menuBarOnly(helpersEnabled: false, helperWindows: true, localAppWindows: false))
    }

    @Test func statusItemWhileItIsTheWayBack() {
        #expect(MenuBarPolicy.showsStatusItem(helpersEnabled: true, helperWindows: true, openSessions: 0))
        #expect(MenuBarPolicy.showsStatusItem(helpersEnabled: true, helperWindows: false, openSessions: 1))
        #expect(!MenuBarPolicy.showsStatusItem(helpersEnabled: true, helperWindows: false, openSessions: 0))
        #expect(!MenuBarPolicy.showsStatusItem(helpersEnabled: false, helperWindows: true, openSessions: 2))
        #expect(MenuBarPolicy.delay(toMenuBarOnly: true) < MenuBarPolicy.delay(toMenuBarOnly: false))
    }
}

@Suite struct HelperIconMessageTests {
    @Test func iconRoundTripsAndFitsTheChannelAtDockSizes() throws {
        let png = Data(repeating: 0xAB, count: 20_000)
        let encoded = try WireCoding.encode(HostMessage.icon(png: png))
        #expect(try WireCoding.decode(HostMessage.self, from: encoded) == .icon(png: png))
        // JSON carries Data as base64 (4/3): the host halves the icon until the message fits.
        #expect(encoded.count > png.count && encoded.count <= MachChannel.maxPayload)
        let tooLarge = try WireCoding.encode(HostMessage.icon(png: Data(repeating: 0, count: 30_000)))
        #expect(tooLarge.count > MachChannel.maxPayload)
    }
}

/// Review fixes before the phase-3 live check.
@Suite struct HelperPhase3ReviewTests {
    @Test func automatedRunsKeepOneProcessUnlessAsked() {
        #expect(HelperAppsSwitch.resolve(environment: nil, stored: nil, automated: true) == (false, .automated))
        #expect(HelperAppsSwitch.resolve(environment: nil, stored: true, automated: true) == (false, .automated))
        #expect(HelperAppsSwitch.resolve(environment: "1", stored: false, automated: true) == (true, .environment))
        #expect(HelperAppsSwitch.resolve(environment: "0", stored: true, automated: true) == (false, .environment))
        for env in [["ICAVIEWER_SELFTEST": "1"], ["ICAVIEWER_HOLD_SECONDS": "30"], ["ICAVIEWER_LAUNCH": "Calc App"],
                    ["ICAVIEWER_PROBE_CLICK": "1"], ["ICAVIEWER_SCREENSHOT": "1"], ["ICAVIEWER_CAPTURE_TWI": "1"],
                    ["ICAVIEWER_DEMO": "1"], ["ICAVIEWER_LOGIN_AUTOFILL": "1"], ["ICAVIEWER_LOGIN_SCREENSHOT": "/tmp/x.png"]] {
            #expect(HelperAppsSwitch.isAutomated(env), "\(env)")
        }
        #expect(!HelperAppsSwitch.isAutomated([:]))
        #expect(!HelperAppsSwitch.isAutomated(["ICAVIEWER_SELFTEST": "0", "ICA_HELPER_APPS": "1", "HOME": "/Users/someone"]))
    }

    @Test func ownWindowsKeepTheDockTile() {
        // Launcher, Settings, Connection Center, a prompt …: they need the menu bar and Cmd-Tab.
        #expect(!MenuBarPolicy.menuBarOnly(helpersEnabled: true, helperWindows: true, localAppWindows: false, ownWindows: true))
        #expect(MenuBarPolicy.menuBarOnly(helpersEnabled: true, helperWindows: true, localAppWindows: false, ownWindows: false))
    }

    @Test func aRelaunchingHelperStillShowsItsWindows() {
        #expect(MenuBarPolicy.helperShowsWindows(ready: true, quitting: false, relaunching: false, hasWindows: true))
        #expect(MenuBarPolicy.helperShowsWindows(ready: false, quitting: false, relaunching: true, hasWindows: true))
        // A first launch that has not checked in yet, a quitting helper, or one without windows: no.
        #expect(!MenuBarPolicy.helperShowsWindows(ready: false, quitting: false, relaunching: false, hasWindows: true))
        #expect(!MenuBarPolicy.helperShowsWindows(ready: true, quitting: true, relaunching: false, hasWindows: true))
        #expect(!MenuBarPolicy.helperShowsWindows(ready: false, quitting: false, relaunching: true, hasWindows: false))
    }

    @Test func helperMenuShowsTheConfiguredLauncherShortcut() throws {
        func launcherItem(_ shortcut: HelperShortcut?) -> HelperMenuItem? {
            HelperMenu.sections(appName: "A", german: false, launcher: shortcut)[3].items.first
        }
        #expect(launcherItem(HelperMenu.launcherShortcut)?.shortcut?.description == "⌃⌥⌘L")
        let k = LauncherHotKey.choices[1].shortcut
        #expect(launcherItem(k)?.shortcut == k)
        #expect(launcherItem(nil)?.shortcut == nil && launcherItem(nil)?.action == .host(.showLauncher))
        // Off: the menu takes no launcher key from the remote app.
        let taken = HelperMenu.takenShortcuts(HelperMenu.sections(appName: "A", german: false, launcher: nil))
        #expect(!taken.contains(HelperMenu.launcherShortcut))
        let message = HostMessage.launcherShortcut(raw: LauncherHotKey.off.raw)
        #expect(try WireCoding.decode(HostMessage.self, from: WireCoding.encode(message)) == message)
        #expect(LauncherHotKey.stored(LauncherHotKey.off.raw).shortcut == nil)
    }
}
