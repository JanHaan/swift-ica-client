import AppKit
import ICAKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StoreService?
    private var login: LoginWindowController?
    private var settings: SettingsWindowController?
    private var launcher: LauncherWindowController?
    private var sessions: [SessionController] = []
    private var terminating = false
    private var launching = false
    private var selfTest: SelfTest?
    private var probe: ActivationProbe?
    private var demo: DemoController?
    /// ICAVIEWER_LAUNCH=<name>: launch this resource right after the list loads, without the launcher.
    private let autoLaunch = ProcessInfo.processInfo.environment["ICAVIEWER_LAUNCH"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if Demo.enabled {
            // ICAVIEWER_DEMO=1: example windows for README screenshots; no network, no Keychain, no session.
            demo = DemoController(service: StoreService())
            demo?.start()
            return
        }
        startSystemHooks()
        let launcher = LauncherWindowController()
        launcher.onLaunch = { [weak self] in self?.launch($0, interactive: true) }
        self.launcher = launcher
        if autoLaunch == nil {
            launcher.showWindow(nil)
            NSApp.activate()
        }
        let store = StoreService()
        self.store = store
        let login = LoginWindowController(service: store)
        self.login = login
        store.interactiveLogon = { [weak login] in try await login?.run() }
        // ICAVIEWER_FORGET_LOGIN=1: delete the saved login for the gateway and quit.
        if ProcessInfo.processInfo.environment["ICAVIEWER_FORGET_LOGIN"] == "1" {
            if let host = store.gateway?.host { store.credentials.forgetAll(host: host) }
            NSApp.terminate(nil)
            return
        }
        // The login test mode always signs in; ICAVIEWER_SIGNIN=1 too (ignores a saved gateway session).
        loadResources(forceLogon: StoreService.autofill || ProcessInfo.processInfo.environment["ICAVIEWER_SIGNIN"] == "1")
    }

    private var loading = false

    /// Signs in if needed (window or `.env`) and fills the launcher.
    private func loadResources(forceLogon: Bool = false) {
        guard let store, let launcher, !loading else { return }
        loading = true
        launcher.setStatus(loc("Signing in…", "Anmeldung…"))
        Task { @MainActor in
            defer { loading = false }
            do {
                let list = try await store.resources(forceLogon: forceLogon)
                launcher.setResources(list)
                launcher.setStatus("\(list.count) resources")
                vlog("resource list: \(list.count) resources")
                if let name = autoLaunch {
                    guard let r = list.first(where: { $0.name == name }) else {
                        vlog("no resource named \(name)")
                        NSApp.terminate(nil)
                        return
                    }
                    launch(r, interactive: false)
                } else if StoreService.autofill {
                    vlog("autofill: resource list loaded; quitting (no session)")
                    NSApp.terminate(nil)
                }
            } catch is LoginCancelled {
                vlog("sign-in cancelled")
                launcher.setStatus(loc("Not signed in. Choose Sign In… from the menu.", "Nicht angemeldet. Menü „Anmelden…“ wählen."))
                launcher.showWindow(nil)
            } catch {
                vlog("sign-in failed: \(error)")
                launcher.setStatus("Sign-in failed: \(error)")
                launcher.showWindow(nil)
                if StoreService.autofill { NSApp.terminate(nil) }
            }
        }
    }

    @MainActor @objc private func signIn() { loadResources(forceLogon: true) }

    @MainActor @objc private func showSettings() {
        guard let store else { return }
        if settings == nil { settings = SettingsWindowController(service: store) }
        settings?.show()
    }

    /// Resources already relaunched once after an early server drop.
    private var retried: Set<String> = []

    /// `interactive`: the user chose the resource in the launcher. Automated launches (see `LaunchPolicy`)
    /// are limited to the test resources.
    private func launch(_ resource: StoreClient.Resource, interactive: Bool) {
        guard let store, !launching else { return }
        let automated = !interactive || LaunchPolicy.envAutomated()
        if !LaunchPolicy.allows(resource.name, automated: automated) {
            launcher?.setStatus("Automated runs may only launch the test resources (ICA_TEST_RESOURCES; ICA_ALLOW_ANY_RESOURCE=1 lifts this)")
            vlog("automated launch of \"\(resource.name)\" refused (not in ICA_TEST_RESOURCES)")
            if autoLaunch != nil { NSApp.terminate(nil) }
            return
        }
        launching = true
        launcher?.setStatus("Launching \(displayName(resource.name))…")
        Task { @MainActor in
            defer { launching = false }
            do {
                let ica: ICAFile
                do {
                    ica = try await store.launch(resource)
                } catch let error where !(error is LoginCancelled) && !Self.isLaunchStatusError(error) {
                    // An expired gateway session fails before any ICA file exists, so signing in
                    // again and repeating the launch once cannot start a second session.
                    vlog("launch failed (\(error)); signing in again")
                    try await store.logon()
                    ica = try await store.launch(resource)
                }
                let controller = try SessionController(name: resource.name, ica: ica)
                controller.onEnded = { [weak self] c in
                    guard let self else { return }
                    // Live: the VDA once closed the connection ~20 ms after INIT_CONNECT_RESPONSE, before
                    // logon. A fresh launch (new ICA file and ticket) worked. Retry that case once.
                    if !c.reachedSeamless, !self.terminating, !self.retried.contains(resource.name) {
                        self.retried.insert(resource.name)
                        self.sessions.removeAll { $0 === c }
                        vlog("session dropped before the seamless channel came up (\(c.endReason)); relaunching once")
                        self.launch(resource, interactive: interactive)
                        return
                    }
                    self.sessionEnded(c)
                }
                controller.onRelaunch = { [weak self] c in
                    // Session reliability gave up and the user chose Reconnect (docs/20 §3.12.11).
                    self?.sessions.removeAll { $0 === c }
                    self?.refreshSessionRows()
                    self?.launcher?.showWindow(nil)
                    self?.launch(resource, interactive: true)   // the user pressed Reconnect
                }
                controller.onParkedChanged = { [weak self] c in
                    self?.refreshSessionRows()
                    if c.isParked { self?.launcher?.showWindow(nil) }
                }
                sessions.append(controller)
                refreshSessionRows()
                if ProcessInfo.processInfo.environment["ICAVIEWER_SELFTEST"] == "1" {
                    selfTest = SelfTest(controller: controller)
                }
                if ProcessInfo.processInfo.environment["ICAVIEWER_PROBE_CLICK"] == "1" {
                    probe = ActivationProbe(controller: controller)
                }
                try await controller.start()
                // ICAVIEWER_HOLD_SECONDS=N: no automated input; log the session off N seconds after the
                // last app window appeared (logon shows a console window before the app's own).
                if let hold = ProcessInfo.processInfo.environment["ICAVIEWER_HOLD_SECONDS"].flatMap(Double.init) {
                    // Overall deadline, also when no app window ever appears (e.g. a reconnect to a
                    // session without windows): end the hold the same way.
                    SessionController.timerQueue.asyncAfter(deadline: .now() + hold + 60) { [weak controller] in
                        guard let c = controller, !c.session.isClosed else { return }
                        vlog("hold deadline reached")
                        c.endHold()
                    }
                    var pending: DispatchWorkItem?
                    controller.onAppWindowShown = { c in
                        vlog("hold mode: logging off in \(Int(hold)) s")
                        pending?.cancel()
                        let work = DispatchWorkItem { [weak c] in
                            vlog("hold time over")
                            c?.endHold()
                        }
                        pending = work
                        // Not on main: the logoff must happen even if the main thread stalls.
                        SessionController.timerQueue.asyncAfter(deadline: .now() + hold, execute: work)
                    }
                }
                launcher?.setStatus("\(displayName(resource.name)): connecting…")
                if autoLaunch == nil { launcher?.window?.orderOut(nil) }
            } catch {
                vlog("launch failed: \(error)")
                launcher?.setStatus("Launch failed: \(error)")
                if autoLaunch != nil { NSApp.terminate(nil) }
            }
        }
    }

    private static func isLaunchStatusError(_ error: Error) -> Bool {
        if case StoreClient.Failure.launch = error { return true }
        return false
    }

    private func refreshSessionRows() {
        launcher?.setSessions(sessions.filter { !$0.ended }.map { c in
            LauncherWindowController.SessionRow(
                title: displayName(c.name), detail: c.isParked ? "no visible windows" : "running", canShow: c.isParked,
                show: { [weak c] in c?.showParkedWindows() },
                logoff: { [weak c] in vlog("launcher: log off \(c?.name ?? "")"); c?.logoff() })
        })
    }

    private func sessionEnded(_ controller: SessionController) {
        sessions.removeAll { $0 === controller }
        refreshSessionRows()
        launcher?.setStatus("\(displayName(controller.name)): session ended")
        guard sessions.isEmpty else { return }
        if terminating {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            // The last session is over and its windows are gone: quit cleanly.
            vlog("last session ended; quitting")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let open = sessions.filter { !$0.ended }
        guard !open.isEmpty else { return .terminateNow }
        terminating = true
        vlog("quit: logging off \(open.count) session(s)")
        open.forEach { $0.logoff() }
        // Hard stop if the server never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Clipboard trigger: the user may have copied in another app (docs/70 §5.4).
    func applicationDidBecomeActive(_ notification: Notification) {
        sessions.filter { !$0.ended }.forEach { $0.clipboardCheck("app active") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { launcher?.showWindow(nil) }
        return true
    }

    @objc private func showLauncher() { launcher?.showWindow(nil) }

    // MARK: Sleep, wake and network path (docs/20 §3.12.2)

    private var pathMonitor: NWPathMonitor?
    private var lastPath: (satisfied: Bool, interface: String?)?

    private func startSystemHooks() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            vlog("system will sleep")
            self?.sessions.filter { !$0.ended }.forEach { $0.session.systemWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            vlog("system woke")
            self?.sessions.filter { !$0.ended }.forEach { $0.session.systemDidWake() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interface = path.availableInterfaces.first.map { "\($0.name) \($0.type)" }
            DispatchQueue.main.async { self?.pathChanged(satisfied: satisfied, interface: interface) }
        }
        monitor.start(queue: DispatchQueue(label: "ica.viewer.path", qos: .utility))
        pathMonitor = monitor
    }

    /// Offline = status not satisfied; online = satisfied again, or a different interface in use
    /// while satisfied (Wi-Fi switch, VPN). The first update is the current state, not an event.
    private func pathChanged(satisfied: Bool, interface: String?) {
        defer { lastPath = (satisfied, interface) }
        guard let last = lastPath, satisfied != last.satisfied || (satisfied && interface != last.interface) else { return }
        vlog("network path: \(satisfied ? "satisfied" : "unsatisfied") via \(interface ?? "none")")
        sessions.filter { !$0.ended }.forEach { $0.session.networkChanged(online: satisfied) }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: loc("Settings…", "Einstellungen…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: loc("Sign In…", "Anmelden…"), action: #selector(signIn), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show Launcher", action: #selector(showLauncher), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ICA Viewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ICA Viewer (log off)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // Standard Edit menu, so text fields (login, settings, search) get Cut/Copy/Paste/Undo shortcuts.
        // Remote windows take Cmd-Z/X/C/V/A before the menu does (SessionView.performKeyEquivalent).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: loc("Edit", "Bearbeiten"))
        editMenu.addItem(withTitle: loc("Undo", "Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: loc("Redo", "Wiederholen"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: loc("Cut", "Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: loc("Copy", "Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: loc("Paste", "Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: loc("Select All", "Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
