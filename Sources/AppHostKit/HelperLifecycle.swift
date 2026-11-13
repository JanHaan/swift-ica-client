import Foundation

/// Phase 3 decisions of the helper integration (docs/99 §12.4): whether helpers run at all, when a crashed
/// helper is launched again, how the same app in two sessions gets two Dock entries, the launcher's global
/// shortcut and the helper's Dock menu. Pure, so the main app and the tests share them.

/// The Settings switch "One Dock entry per app" (D63: on by default at release) and the support override
/// `ICA_HELPER_APPS=0/1`, which wins both ways. Read once at launch: a change applies at the next start.
public enum HelperAppsSwitch {
    public static let defaultsKey = "oneDockEntryPerApp"
    public static let environmentVariable = "ICA_HELPER_APPS"
    public static let defaultOn = true

    public enum Source: String, Sendable { case environment, settings, defaultValue = "default", automated }

    /// `environment`: the value of ICA_HELPER_APPS (nil = unset); `stored`: the saved Settings value (nil = never
    /// saved); `automated`: a test, screenshot or demo run (`isAutomated`): helpers off and the saved setting
    /// ignored, unless ICA_HELPER_APPS=1 asks for them (the test tools expect one process and its activation).
    public static func resolve(environment: String?, stored: Bool?, automated: Bool = false) -> (enabled: Bool, source: Source) {
        switch environment?.trimmingCharacters(in: .whitespaces) {
        case "0": return (false, .environment)
        case "1": return (true, .environment)
        default: break
        }
        if automated { return (false, .automated) }
        if let stored { return (stored, .settings) }
        return (defaultOn, .defaultValue)
    }

    /// The automated modes of ICAViewer: a launch without the launcher, the self test, hold, the activation
    /// probe, screenshot and demo modes, TWI capture. They also get no global shortcut.
    public static func isAutomated(_ env: [String: String]) -> Bool {
        env["ICAVIEWER_LAUNCH"] != nil || env["ICAVIEWER_HOLD_SECONDS"] != nil || env["ICAVIEWER_LOGIN_SCREENSHOT"] != nil
            || ["ICAVIEWER_SELFTEST", "ICAVIEWER_PROBE_CLICK", "ICAVIEWER_SCREENSHOT", "ICAVIEWER_CAPTURE_TWI", "ICAVIEWER_DEMO",
                "ICAVIEWER_LOGIN_AUTOFILL"].contains { env[$0] == "1" }
    }
}

/// A helper that died on its own (crash, kill) is launched again once; a second death within `window` seconds
/// of that relaunch hands its windows back to the main process for the rest of the run (docs/99 §12.14).
public struct HelperRelaunchPolicy: Sendable {
    public var window: TimeInterval
    private var last: [String: Date] = [:]

    public init(window: TimeInterval = 60) { self.window = window }

    /// true = relaunch now (and remember it); false = fall back to the main process.
    public mutating func shouldRelaunch(_ key: String, at now: Date) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < window { return false }
        last[key] = now
        return true
    }
}

/// One helper per app and session (docs/99 §12.4 phase 3): the first session that shows an app has slot 1
/// (key = the TWI app key, name = the app's name, as in phases 1–2); the same app in another session at the
/// same time gets the smallest free slot n ≥ 2, its own bundle (bundle id and LaunchServices instance) and the
/// name "App (n)". Slots, not session ids: the same slot reuses its bundle and a pinned Dock entry next run.
public enum HelperSessionSlots {
    static let separator = "#session"

    public static func key(appKey: String, slot: Int) -> String {
        slot <= 1 ? appKey : appKey + separator + String(slot)
    }

    /// The smallest slot ≥ 1 not in `taken`.
    public static func freeSlot(taken: Set<Int>) -> Int {
        var slot = 1
        while taken.contains(slot) { slot += 1 }
        return slot
    }

    /// The Dock and Cmd-Tab name: "Editor (2)" for the second session's instance.
    public static func name(_ base: String, slot: Int) -> String {
        slot <= 1 ? base : "\(base) (\(slot))"
    }
}

/// The launcher's global shortcut (docs/99 §12.13; ⌃⌥⌘L approved by the user, D64): a small fixed list in
/// Settings, or off. Stored as `raw` (e.g. "ctrl-opt-cmd-l", "off").
public struct LauncherHotKey: Equatable, Hashable, Sendable {
    public static let defaultsKey = "launcherHotKey"
    /// nil = off.
    public var shortcut: HelperShortcut?

    public init(_ shortcut: HelperShortcut?) { self.shortcut = shortcut }

    public static let off = LauncherHotKey(nil)
    public static let standard = LauncherHotKey(HelperMenu.launcherShortcut)
    /// Settings offers these: three letters with ⌃⌥⌘ (rarely used by apps, never by the remote app's own
    /// Ctrl+Alt combinations on the Mac side) and off.
    public static let choices: [LauncherHotKey] = [
        standard,
        LauncherHotKey(HelperShortcut("k", [.control, .option, .command])),
        LauncherHotKey(HelperShortcut("j", [.control, .option, .command])),
        off,
    ]

    public var raw: String {
        guard let shortcut else { return "off" }
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) { parts.append("ctrl") }
        if shortcut.modifiers.contains(.option) { parts.append("opt") }
        if shortcut.modifiers.contains(.shift) { parts.append("shift") }
        if shortcut.modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [shortcut.key.lowercased()]).joined(separator: "-")
    }

    /// nil when `raw` is not one of `choices` (then the default applies).
    public init?(raw: String) {
        guard let match = Self.choices.first(where: { $0.raw == raw }) else { return nil }
        self = match
    }

    /// Unset or unknown → ⌃⌥⌘L.
    public static func stored(_ raw: String?) -> LauncherHotKey {
        raw.flatMap(LauncherHotKey.init(raw:)) ?? standard
    }

    /// Carbon modifier bits for `RegisterEventHotKey` (cmdKey 0x100, shiftKey 0x200, optionKey 0x800,
    /// controlKey 0x1000; Carbon.HIToolbox Events.h).
    public var carbonModifiers: UInt32 {
        guard let m = shortcut?.modifiers else { return 0 }
        var bits: UInt32 = 0
        if m.contains(.command) { bits |= 0x100 }
        if m.contains(.shift) { bits |= 0x200 }
        if m.contains(.option) { bits |= 0x800 }
        if m.contains(.control) { bits |= 0x1000 }
        return bits
    }

    public var title: String { shortcut?.description ?? "" }
}

/// The helper's Dock menu (docs/99 §12.11): the app's windows (the key one checked; choosing one brings it to
/// the front, which activates it on the host), then Show Launcher and Connection Center (run in the main
/// process). macOS adds Options, Show All Windows, Hide and Quit itself (Quit = quit only this remote app, D63).
public enum HelperDockMenu {
    public enum Action: Equatable, Sendable {
        case window(UInt32)
        case host(HelperCommand)
    }

    public struct Item: Equatable, Sendable {
        public var title: String
        /// nil = a separator.
        public var action: Action?
        public var checked: Bool

        public init(_ title: String, _ action: Action?, checked: Bool = false) {
            self.title = title; self.action = action; self.checked = checked
        }

        public static let separator = Item("", nil)
        public var isSeparator: Bool { action == nil }
    }

    public struct Window: Equatable, Sendable {
        public var id: UInt32, title: String, isKey: Bool
        public init(id: UInt32, title: String, isKey: Bool) { self.id = id; self.title = title; self.isKey = isKey }
    }

    /// `untitled`: the title for a window without one (the app's name).
    public static func items(windows: [Window], untitled: String, german: Bool) -> [Item] {
        func t(_ en: String, _ de: String) -> String { german ? de : en }
        var items = windows.sorted { $0.id < $1.id }.map { w in
            let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Item(title.isEmpty ? untitled : String(title.prefix(80)), .window(w.id), checked: w.isKey)
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(Item(t("Show Launcher", "Launcher zeigen"), .host(.showLauncher)))
        items.append(Item(t("Connection Center", "Verbindungscenter"), .host(.connectionCenter)))
        return items
    }
}

/// The main app's own presence (docs/99 §12.13, D63): menu-bar only (no "ICA Viewer" Dock tile, no Cmd-Tab
/// entry) while helpers show the remote apps and this process shows no app window itself; a Dock app again
/// otherwise (launcher-only use, a fallback window, helpers off). The menu-bar item is there while it is the
/// way back to the launcher: helpers show windows, or a session is open.
public enum MenuBarPolicy {
    /// `ownWindows`: a window of the main app itself is on screen (launcher, Settings, Connection Center, Report a
    /// Problem, sign-in, a prompt): it needs the menu bar and a Cmd-Tab entry, so the Dock tile stays meanwhile.
    public static func menuBarOnly(helpersEnabled: Bool, helperWindows: Bool, localAppWindows: Bool, ownWindows: Bool = false) -> Bool {
        helpersEnabled && helperWindows && !localAppWindows && !ownWindows
    }

    /// Whether a helper counts as showing its app's windows: checked in and not quitting, or being relaunched
    /// after a crash (its windows come back in a moment; the Dock tile must not flash meanwhile).
    public static func helperShowsWindows(ready: Bool, quitting: Bool, relaunching: Bool, hasWindows: Bool) -> Bool {
        hasWindows && !quitting && (ready || relaunching)
    }

    public static func showsStatusItem(helpersEnabled: Bool, helperWindows: Bool, openSessions: Int) -> Bool {
        helpersEnabled && (helperWindows || openSessions > 0)
    }

    /// Going menu-bar only waits a moment (the first helper's window is just coming); getting the Dock tile
    /// back waits longer (an app's helper quits 3 s after its last window, another may be starting).
    public static func delay(toMenuBarOnly: Bool) -> TimeInterval { toMenuBarOnly ? 0.3 : 1.0 }
}
