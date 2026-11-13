import AppHostKit
import AppKit
import os

/// The helper app (docs/99 §3): a `.regular` process with its own bundle id, name and icon that owns
/// the windows of one remote app. It draws nothing itself: every pixel comes from the host's IOSurface,
/// every input event goes back to the host. It never outlives the host and never lingers windowless.
final class HelperApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let link: HostLink
    private let logger = Logger(subsystem: "local.alttab.ICAViewer.helper", category: "spike")
    private var surface: IOSurfaceRef?
    private var windows: [UInt32: SurfaceWindow] = [:]
    private var appName = ProcessInfo.processInfo.processName
    private var hostQuit = false
    private var greeted = false
    private var windowlessCheck: DispatchWorkItem?
    private var latencies: [Double] = []
    /// Session pixels per point, fixed at launch (the spike does not follow screen changes).
    private let scale = NSScreen.main?.backingScaleFactor ?? 2

    init(launch: HelperLaunch) { link = HostLink(launch: launch) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: HelperBundle.iconFile, withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon       // docs/99 §6.4: independent of the Dock/LS icon cache
        }
        link.onMessage = { [weak self] message, port in self?.handle(message, port: port) }
        link.onLost = { [weak self] reason in
            self?.note("host gone (\(reason)); exiting")
            exit(0)                                 // docs/99 §5: never linger after the host
        }
        if let error = link.connect(queue: .main) {
            note("cannot reach the host: \(error); exiting")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.greeted else { return }
            self.note("no hello from the host in 5 s; exiting")
            exit(1)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.link.send(.appActive(true))
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.link.send(.appActive(false))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !hostQuit { link.send(.appQuit) }        // Cmd-Q: the host closes this app's windows (docs/99 §5)
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func handle(_ message: HostMessage, port: mach_port_t) {
        switch message {
        case .hello(let name):
            greeted = true
            appName = name
            NSApp.mainMenu = Self.menu(appName: name)
        case .surface:
            if port != MACH_PORT_NULL {
                surface = IOSurfaceLookupFromMachPort(port)
                MachChannel.deallocate(port)
            }
            if surface == nil { note("IOSurfaceLookupFromMachPort failed") }
            for window in windows.values { window.surfaceView.refresh(surface) }
        case .windowAdded(let spec):
            let window = SurfaceWindow(spec: spec, scale: scale) { [weak self] in self?.link.send($0) }
            window.delegate = self
            windows[spec.id] = window
            window.surfaceView.refresh(surface)
            window.orderFrontRegardless()           // visible without taking activation
            windowlessCheck?.cancel()
        case .windowRemoved(let id):
            windows.removeValue(forKey: id)?.close()
            if windows.isEmpty { scheduleWindowlessQuit() }
        case .frame(_, let dirty, let sentNs):
            for window in windows.values where dirty.contains(where: { $0.intersects(window.spec.rect) }) {
                window.surfaceView.refresh(surface)
            }
            record(latencyUs: Double(uptimeNanoseconds() &- sentNs) / 1000)
        case .activate(let id):
            NSApp.activate()
            windows[id]?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                let key = NSApp.keyWindow.map { "\(($0 as? SurfaceWindow)?.spec.id ?? 0)" } ?? "none"
                self?.link.send(.activation("activate(\(id)): isActive=\(NSApp.isActive) key=\(key)"))
            }
        case .yieldActivation(let pid):
            guard let target = NSRunningApplication(processIdentifier: pid) else {
                link.send(.activation("yield: no running app with pid \(pid)"))
                return
            }
            let wasActive = NSApp.isActive
            NSApp.yieldActivation(to: target)
            link.send(.yielded(toPid: pid, wasActive: wasActive))
        case .probe:
            MachChannel.deallocate(port)
        case .quit:
            hostQuit = true
            NSApp.terminate(nil)
        }
    }

    /// No windows for 3 s (the host removed the last one and did not send quit): leave anyway, a
    /// windowless helper would be a Husk (docs/99 §1).
    private func scheduleWindowlessQuit() {
        windowlessCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.windows.isEmpty else { return }
            self.note("windowless for 3 s; exiting")
            self.hostQuit = true
            NSApp.terminate(nil)
        }
        windowlessCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func record(latencyUs: Double) {
        latencies.append(latencyUs)
        guard latencies.count >= 120 else { return }
        link.send(.frameStats(count: latencies.count, meanUs: latencies.reduce(0, +) / Double(latencies.count),
                              maxUs: latencies.max() ?? 0))
        latencies.removeAll(keepingCapacity: true)
    }

    private func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        helperLog(text)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? SurfaceWindow { link.send(.focus(windowId: window.spec.id)) }
    }

    /// The host decides (TWI close) and answers with windowRemoved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let window = sender as? SurfaceWindow { link.send(.close(windowId: window.spec.id)) }
        return false
    }

    // MARK: Menu

    /// App menu (the bold title is CFBundleName) and a Window menu, so Cmd-M, Cmd-H and Cmd-Q work.
    static func menu(appName: String) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
