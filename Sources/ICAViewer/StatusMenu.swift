import AppHostKit
import AppKit
import ICAKit

/// The main app as a menu-bar host (docs/99 §12.13, D63, phase 3). While helper apps show the remote apps and
/// this process shows no window itself (no remote app window, no launcher, Settings or other window of its
/// own), it has no Dock tile and no Cmd-Tab entry (activation policy
/// `.accessory`); otherwise it is a regular Dock app, as before (launcher-only use, fallback windows, helpers
/// off). Either way the launcher stays a few clicks away: this menu-bar item (template icon), the global
/// shortcut (`GlobalHotKey`, ⌃⌥⌘L), every helper's ICA menu and Dock menu.
///
/// Menu: Open Launcher, Connection Center, Settings…, one submenu per session (its apps: choosing one brings
/// it to the front; Disconnect Session…, Log Off Session…, confirmed first), Report a Problem…, Quit ICA
/// Viewer (the whole client: the Cmd-Q prompt, docs/90 §9.4). Built when it opens, so it is never stale.
/// Only with helpers enabled; main thread only.
@MainActor
final class MenuBarHost: NSObject, NSMenuDelegate {
    struct Actions {
        var sessions: () -> [SessionController]
        var showLauncher: () -> Void
        var connectionCenter: () -> Void
        var settings: () -> Void
        var reportProblem: () -> Void
        /// Disconnect or Log Off, confirmed by the app delegate.
        var endSession: (HelperCommand, SessionController) -> Void
    }

    private let actions: Actions
    private var item: NSStatusItem?
    private var menuBarOnly = false
    private var pending: DispatchWorkItem?

    init(actions: Actions) {
        self.actions = actions
        super.init()
        // The main app's own windows keep it a Dock app while they are on screen: decide again when one
        // appears, hides, closes or becomes key.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard !(note.object is SeamlessWindow || note.object is SeamlessPanel) else { return }
                MainActor.assumeIsolated { self?.update() }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }   // after it is gone
        }
    }

    /// A window of the main app itself on screen (launcher, Settings, Connection Center, Report a Problem,
    /// sign-in, a prompt, a print job): it needs the menu bar and a Cmd-Tab entry. Remote windows count through
    /// `localAppWindows`; popups and the hidden windows of helper-shown windows never.
    private var ownWindowsShown: Bool {
        NSApp.windows.contains { w in
            w.isVisible && w.styleMask.contains(.titled) && !(w is SeamlessWindow) && !(w is SeamlessPanel)
        }
    }

    // MARK: Presence

    /// Something changed (a helper checked in or quit, a window moved between processes, a session ended):
    /// decide again, debounced (`MenuBarPolicy.delay`).
    func update() {
        let open = actions.sessions().filter { !$0.ended }
        let helperWindows = HelperManager.shared.hasReadyHelpers
        let local = open.contains { c in c.windows.values.contains { $0.isApp && $0.presenter == nil } }
        setStatusItem(MenuBarPolicy.showsStatusItem(helpersEnabled: HelperManager.enabled && HelperManager.hasTemplate, helperWindows: helperWindows,
                                                    openSessions: open.count))
        let wanted = MenuBarPolicy.menuBarOnly(helpersEnabled: HelperManager.enabled, helperWindows: helperWindows, localAppWindows: local,
                                               ownWindows: ownWindowsShown)
        guard wanted != menuBarOnly else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                self.apply()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarPolicy.delay(toMenuBarOnly: wanted), execute: work)
    }

    /// After the delay: the state again (it may have changed back meanwhile).
    private func apply() {
        let open = actions.sessions().filter { !$0.ended }
        let local = open.contains { c in c.windows.values.contains { $0.isApp && $0.presenter == nil } }
        let wanted = MenuBarPolicy.menuBarOnly(helpersEnabled: HelperManager.enabled, helperWindows: HelperManager.shared.hasReadyHelpers,
                                               localAppWindows: local, ownWindows: ownWindowsShown)
        guard wanted != menuBarOnly else { return }
        menuBarOnly = wanted
        if wanted { setStatusItem(true) }       // the way back to the launcher, before the Dock tile goes
        NSApp.setActivationPolicy(wanted ? .accessory : .regular)
        vlog(wanted ? "menu-bar host: remote apps in their own Dock entries; ICA Viewer is menu-bar only"
                    : "menu-bar host: ICA Viewer has its Dock tile again")
    }

    private func setStatusItem(_ shown: Bool) {
        guard shown != (item != nil) else { return }
        guard shown else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "ICA Viewer")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "ICA Viewer"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
    }

    // MARK: Menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let launcher = add(menu, loc("Open Launcher", "Launcher öffnen"), #selector(openLauncher))
        if GlobalHotKey.shared.state == .registered, let shortcut = GlobalHotKey.shared.current.shortcut {
            launcher.keyEquivalent = shortcut.key
            launcher.keyEquivalentModifierMask = Self.mask(shortcut.modifiers)
        }
        add(menu, loc("Connection Center", "Verbindungscenter"), #selector(openConnectionCenter))
        add(menu, loc("Settings…", "Einstellungen…"), #selector(openSettings))
        menu.addItem(.separator())
        let open = actions.sessions().filter { !$0.ended }
        if open.isEmpty {
            add(menu, loc("No Session", "Keine Sitzung"), nil).isEnabled = false
        }
        for c in open {
            let title = c.appNames.map(displayName).joined(separator: ", ")
            let session = NSMenuItem(title: title.isEmpty ? loc("Session", "Sitzung") : title, action: nil, keyEquivalent: "")
            session.submenu = sessionMenu(c)
            menu.addItem(session)
        }
        menu.addItem(.separator())
        add(menu, loc("Report a Problem…", "Problem melden…"), #selector(openReport))
        menu.addItem(.separator())
        add(menu, loc("Quit ICA Viewer", "ICA Viewer beenden"), #selector(quit))
    }

    /// The session's apps (one item per app: its first window comes to the front), then Disconnect and Log Off.
    private func sessionMenu(_ c: SessionController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var seen: Set<String> = []
        let apps = c.windows.values.filter(\.isApp).sorted { $0.info.id < $1.info.id }.filter { seen.insert($0.info.appKey).inserted }
        for w in apps {
            let source = c.dockSource(for: w)
            let name = source.flatMap { DockIcon.shared.identity(for: $0).name ?? $0.names.first } ?? w.info.title
            let item = add(menu, displayName(name.isEmpty ? loc("App", "App") : name), #selector(bringApp(_:)))
            item.representedObject = WindowRef(w)
        }
        if apps.isEmpty {
            for name in c.appNames { add(menu, displayName(name), nil).isEnabled = false }
        }
        menu.addItem(.separator())
        let disconnect = add(menu, loc("Disconnect Session…", "Sitzung trennen…"), #selector(endSession(_:)))
        disconnect.representedObject = SessionRef(c, .disconnect)
        let logoff = add(menu, loc("Log Off Session…", "Sitzung abmelden…"), #selector(endSession(_:)))
        logoff.representedObject = SessionRef(c, .logoff)
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private static func mask(_ m: HelperShortcut.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if m.contains(.command) { mask.insert(.command) }
        if m.contains(.shift) { mask.insert(.shift) }
        if m.contains(.option) { mask.insert(.option) }
        if m.contains(.control) { mask.insert(.control) }
        return mask
    }

    /// Weak references: the menu may outlive a window or a session.
    private final class WindowRef: NSObject {
        weak var window: RemoteWindow?
        init(_ window: RemoteWindow) { self.window = window }
    }

    private final class SessionRef: NSObject {
        weak var controller: SessionController?
        let command: HelperCommand
        init(_ controller: SessionController, _ command: HelperCommand) { self.controller = controller; self.command = command }
    }

    // MARK: Actions (a menu-bar click is the user's: this process may come to the front)

    @objc private func openLauncher() { NSApp.activate(); actions.showLauncher() }
    @objc private func openConnectionCenter() { NSApp.activate(); actions.connectionCenter() }
    @objc private func openSettings() { NSApp.activate(); actions.settings() }
    @objc private func openReport() { NSApp.activate(); actions.reportProblem() }

    @objc private func bringApp(_ sender: NSMenuItem) {
        guard let w = (sender.representedObject as? WindowRef)?.window, let c = w.controller, !c.ended else { return }
        HelperManager.shared.activate(w)
    }

    @objc private func endSession(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? SessionRef, let c = ref.controller, !c.ended else { return }
        NSApp.activate()
        actions.endSession(ref.command, c)
    }

    /// The whole client: the existing Cmd-Q prompt (Disconnect / Log Off all sessions, or the remembered choice).
    @objc private func quit() {
        NSApp.activate()
        NSApp.terminate(nil)
    }
}
