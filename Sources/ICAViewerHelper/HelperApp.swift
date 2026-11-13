import AppHostKit
import AppKit
import os

/// The helper app (docs/99 §3): a `.regular` process with its own bundle id, name and icon that owns
/// the windows of one remote app. It draws nothing itself: every pixel comes from the host's IOSurface,
/// every input event goes back to the host. It never outlives the host and never lingers windowless.
final class HelperApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let link: HostLink
    private let logger = Logger(subsystem: "local.alttab.ICAViewer.helper", category: "helper")
    private var surface: IOSurfaceRef?
    private var windows: [UInt32: SurfaceWindow] = [:]
    private var appName = ProcessInfo.processInfo.processName
    private var hostQuit = false
    private var greeted = false
    private var windowlessCheck: DispatchWorkItem?
    private var latencies: [Double] = []
    /// Session pixels per point for specs without a scale (the spike does not follow screen changes).
    private let defaultScale = NSScreen.main?.backingScaleFactor ?? 2

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

    /// Cmd-Q quits the remote app, not this process: the host closes the app's windows (TWI close each)
    /// and sends `quit` after the last one is gone (docs/99 §5, §12.12). A save prompt the remote app shows
    /// arrives as a new window of this helper. Logout, restart and shutdown are never held up: then this
    /// process goes (the main app decides about the session itself).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hostQuit || Self.systemIsQuitting() { return .terminateNow }
        link.send(.appQuit)
        return .terminateCancel
    }

    /// The quit Apple event carries `kAEQuitReason` when the system logs out, restarts or shuts down.
    static func systemIsQuitting() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return Self.systemQuitReasons.contains(reason)
    }

    static let systemQuitReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
        OSType(kAERestart), OSType(kAEShutDown),
    ]

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func send(_ message: HelperMessage) {
        link.send(message, timeoutMs: message.mayDrop ? 0 : 200)
    }

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
            for window in windows.values { window.surfaceView.refresh(surface, crop: window.spec.rect) }
        case .windowAdded(let spec):
            if let existing = windows[spec.id] { return existing.apply(spec, surface: surface) }
            let window = SurfaceWindow(spec: spec, defaultScale: defaultScale) { [weak self] in self?.send($0) }
            window.delegate = self
            windows[spec.id] = window
            window.surfaceView.refresh(surface, crop: spec.rect)
            windowlessCheck?.cancel()
            if !window.isSeamless {
                window.orderFrontRegardless()       // spike: visible without taking activation
            } else if spec.minimized == true {
                window.orderFront(nil)
                window.expectMiniaturize = true
                window.miniaturize(nil)
            } else {
                window.orderFront(nil)              // the host's activate (after a yield) brings it forward
            }
        case .windowChanged(let spec):
            windows[spec.id]?.apply(spec, surface: surface)
        case .windowRemoved(let id):
            if let window = windows.removeValue(forKey: id) {
                window.delegate = nil
                window.orderOut(nil)
                window.close()
            }
            if windows.isEmpty { scheduleWindowlessQuit() }
        case .frame(_, let dirty, let sentNs):
            for window in windows.values where dirty.contains(where: { $0.intersects(window.spec.rect) }) {
                window.surfaceView.refresh(surface, crop: window.spec.rect)
            }
            record(latencyUs: Double(uptimeNanoseconds() &- sentNs) / 1000)
        case .activate(let id):
            NSApp.activate()
            if let window = windows[id], !window.isMiniaturized { window.makeKeyAndOrderFront(nil) }
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

    /// No windows for 5 s (the host removed the last one and did not send quit): leave anyway, a
    /// windowless helper would be a Husk (docs/99 §1). The host's own grace is 3 s.
    private func scheduleWindowlessQuit() {
        windowlessCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.windows.isEmpty else { return }
            self.note("windowless for 5 s; exiting")
            self.hostQuit = true
            NSApp.terminate(nil)
        }
        windowlessCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func record(latencyUs: Double) {
        latencies.append(latencyUs)
        guard latencies.count >= 120 else { return }
        let sorted = latencies.sorted()
        send(.frameStats(count: sorted.count, meanUs: sorted.reduce(0, +) / Double(sorted.count),
                         p95Us: sorted[min(sorted.count - 1, sorted.count * 95 / 100)], maxUs: sorted.last ?? 0))
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

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? SurfaceWindow { link.send(.resignedKey(windowId: window.spec.id)) }
    }

    /// The host decides (TWI close) and answers with windowRemoved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let window = sender as? SurfaceWindow { link.send(.close(windowId: window.spec.id)) }
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? SurfaceWindow, window.isSeamless else { return }
        if window.expectMiniaturize { window.expectMiniaturize = false; return }
        link.send(.minimized(windowId: window.spec.id, true))
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? SurfaceWindow, window.isSeamless else { return }
        if window.expectDeminiaturize { window.expectDeminiaturize = false; return }
        window.localRestoreSince = Date()
        link.send(.minimized(windowId: window.spec.id, false))
    }

    /// Moved or resized here, not by the host (AX, Mission Control, a window manager): the host turns it
    /// into one TWI move once it settles, as for its own windows (D20).
    func windowDidMove(_ notification: Notification) { reportGeometry(notification) }
    func windowDidResize(_ notification: Notification) { reportGeometry(notification) }

    private func reportGeometry(_ notification: Notification) {
        guard let window = notification.object as? SurfaceWindow, window.isSeamless, !window.applyingHost,
              !window.isMiniaturized else { return }
        link.send(.moved(windowId: window.spec.id, frame: WirePointRect(window.contentRect(forFrameRect: window.frame))))
    }

    // MARK: Menu

    /// App menu (the bold title is CFBundleName) and a Window menu, so Cmd-W, Cmd-M, Cmd-H and Cmd-Q work.
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
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
