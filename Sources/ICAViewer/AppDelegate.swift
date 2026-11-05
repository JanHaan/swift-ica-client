import AppKit
import ICAKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StoreService?
    private var launcher: LauncherWindowController?
    private var sessions: [SessionController] = []
    private var terminating = false
    private var launching = false
    private var selfTest: SelfTest?
    private var probe: ActivationProbe?
    /// ICAVIEWER_LAUNCH=<name>: launch this resource right after the list loads, without the launcher.
    private let autoLaunch = ProcessInfo.processInfo.environment["ICAVIEWER_LAUNCH"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let launcher = LauncherWindowController()
        launcher.onLaunch = { [weak self] in self?.launch($0) }
        self.launcher = launcher
        if autoLaunch == nil {
            launcher.showWindow(nil)
            NSApp.activate()
        }
        do { store = try StoreService() } catch {
            launcher.setStatus("\(error)")
            launcher.showWindow(nil)
            return
        }
        launcher.setStatus("Signing in…")
        Task { @MainActor in
            do {
                let list = try await store!.resources()
                launcher.setResources(list)
                launcher.setStatus("\(list.count) resources")
                if let name = autoLaunch {
                    guard let r = list.first(where: { $0.name == name }) else {
                        vlog("no resource named \(name)")
                        NSApp.terminate(nil)
                        return
                    }
                    launch(r)
                }
            } catch {
                vlog("sign-in failed: \(error)")
                launcher.setStatus("Sign-in failed: \(error)")
                launcher.showWindow(nil)
            }
        }
    }

    /// Resources already relaunched once after an early server drop.
    private var retried: Set<String> = []

    private func launch(_ resource: StoreClient.Resource) {
        guard let store, !launching else { return }
        // Live tests are limited to the test app unless explicitly allowed.
        if resource.name != "Calculator", ProcessInfo.processInfo.environment["ICA_ALLOW_ANY_RESOURCE"] != "1" {
            launcher?.setStatus("Only \"Calculator\" may be launched (set ICA_ALLOW_ANY_RESOURCE=1)")
            return
        }
        launching = true
        launcher?.setStatus("Launching \(resource.name)…")
        Task { @MainActor in
            defer { launching = false }
            do {
                let ica = try await store.launch(resource)
                let controller = try SessionController(name: resource.name, ica: ica)
                controller.onEnded = { [weak self] c in
                    guard let self else { return }
                    // Live: the VDA once closed the connection ~20 ms after INIT_CONNECT_RESPONSE, before
                    // logon. A fresh launch (new ICA file and ticket) worked. Retry that case once.
                    if !c.reachedSeamless, !self.terminating, !self.retried.contains(resource.name) {
                        self.retried.insert(resource.name)
                        self.sessions.removeAll { $0 === c }
                        vlog("session dropped before the seamless channel came up (\(c.endReason)); relaunching once")
                        self.launch(resource)
                        return
                    }
                    self.sessionEnded(c)
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
                launcher?.setStatus("\(resource.name): connecting…")
                if autoLaunch == nil { launcher?.window?.orderOut(nil) }
            } catch {
                vlog("launch failed: \(error)")
                launcher?.setStatus("Launch failed: \(error)")
                if autoLaunch != nil { NSApp.terminate(nil) }
            }
        }
    }

    private func refreshSessionRows() {
        launcher?.setSessions(sessions.filter { !$0.ended }.map { c in
            LauncherWindowController.SessionRow(
                title: c.name, detail: c.isParked ? "no visible windows" : "running", canShow: c.isParked,
                show: { [weak c] in c?.showParkedWindows() },
                logoff: { [weak c] in vlog("launcher: log off \(c?.name ?? "")"); c?.logoff() })
        })
    }

    private func sessionEnded(_ controller: SessionController) {
        sessions.removeAll { $0 === controller }
        refreshSessionRows()
        launcher?.setStatus("\(controller.name): session ended")
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { launcher?.showWindow(nil) }
        return true
    }

    @objc private func showLauncher() { launcher?.showWindow(nil) }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Launcher", action: #selector(showLauncher), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ICA Viewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ICA Viewer (log off)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
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
