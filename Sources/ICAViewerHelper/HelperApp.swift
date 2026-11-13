import AppHostKit
import AppKit
import ImageIO
import os

/// The helper app (docs/99 §3): a `.regular` process with its own bundle id, name and icon that owns
/// the windows of one remote app. It draws nothing itself: every pixel comes from the host's IOSurface,
/// every input event goes back to the host. It never outlives the host and never lingers windowless.
///
/// Phase 2 (docs/99 §12): also the app's popups, menus and tooltips (`SurfacePanel`), local caption drags and
/// edge resizes (D20), the remote pointer shape, and a menu bar of its own (`HelperMenu`) whose Edit, Zoom
/// and ICA items act in the host. Phase 3: a Dock menu (windows, Show Launcher, Connection Center), the Dock
/// tile restoring a minimised window, and icon updates without a relaunch.
final class HelperApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let link: HostLink
    private let logger = Logger(subsystem: "local.alttab.ICAViewer.helper", category: "helper")
    private var surface: IOSurfaceRef?
    private var windows: [UInt32: SurfaceWindow] = [:]
    private var popups: [UInt32: SurfacePanel] = [:]
    /// Popups ordered out while a local gesture runs (they would stay behind), shown again after it.
    private var hiddenForGesture: Set<UInt32> = []
    private var appName = ProcessInfo.processInfo.processName
    private var hostQuit = false
    private var greeted = false
    private var windowlessCheck: DispatchWorkItem?
    /// The window that was key last (the Dock tile brings it back when all are minimised).
    private var lastKeyWindow: UInt32?
    /// Open Launcher's key equivalent: the host's global shortcut (`launcherShortcut` message), nil = none.
    private var launcherShortcut: HelperShortcut? = HelperMenu.launcherShortcut
    private var latencies: [Double] = []
    /// Session pixels per point for specs without a scale (the spike does not follow screen changes).
    private let defaultScale = NSScreen.main?.backingScaleFactor ?? 2
    /// The remote pointer shape (nil until the host sent one: the arrow) and its cursors by k.
    private var pointer: (shape: HelperCursor, image: CGImage?)?
    private var cursors: [CGFloat: NSCursor] = [:]
    private let german = HelperMenu.isGerman()
    /// The menu bar model (from `hello`): key equivalents not in it go to the remote app.
    private var menuSections: [HelperMenuSection] = [] {
        didSet { for window in allWindows { window.surfaceView.ownMenu = menuSections } }
    }

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

    // MARK: Dock tile (phase 3, docs/99 §12.11, §12.5)

    /// The app's windows (choosing one brings it to the front and so activates it on the host), then Show
    /// Launcher and Connection Center in the main process. macOS adds Hide and Quit (= quit this remote app).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let key = keySurfaceWindow?.spec.id
        let list = windows.values.filter(\.isSeamless).map { HelperDockMenu.Window(id: $0.spec.id, title: $0.spec.title, isKey: $0.spec.id == key) }
        let menu = NSMenu()
        for model in HelperDockMenu.items(windows: list, untitled: appName, german: german) {
            guard let action = model.action else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.target = self
            item.state = model.checked ? .on : .off
            switch action {
            case .window(let id):
                item.action = #selector(dockWindow(_:))
                item.tag = Int(id)
            case .host(let command):
                item.action = #selector(hostCommand(_:))
                item.representedObject = command.rawValue
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockWindow(_ sender: NSMenuItem) {
        guard let window = windows[UInt32(truncatingIfNeeded: sender.tag)] else { return }
        bringForward(window)
    }

    /// A click on the Dock tile with no window on screen (all minimised): the last key window, else the first,
    /// comes back; the host hears the restore (`minimized false`) and the focus as for any other restore.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        let candidates = windows.values.filter(\.isSeamless).sorted { $0.spec.id < $1.spec.id }
        guard let window = candidates.first(where: { $0.spec.id == lastKeyWindow }) ?? candidates.first else { return false }
        bringForward(window)
        return false
    }

    private func bringForward(_ window: SurfaceWindow) {
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func send(_ message: HelperMessage) {
        link.send(message, timeoutMs: message.mayDrop ? 0 : 200)
    }

    private var allWindows: [SurfaceShowing] { Array(popups.values) + Array(windows.values) }

    private func shown(_ id: UInt32) -> SurfaceShowing? {
        if let window = windows[id] { return window }
        return popups[id]
    }

    private func handle(_ message: HostMessage, port: mach_port_t) {
        switch message {
        case .hello(let name):
            greeted = true
            appName = name
            NSApp.mainMenu = menu(appName: name)
        case .surface:
            if port != MACH_PORT_NULL {
                surface = IOSurfaceLookupFromMachPort(port)
                MachChannel.deallocate(port)
            }
            if surface == nil { note("IOSurfaceLookupFromMachPort failed") }
            for window in allWindows { window.surfaceView.refresh(surface, crop: window.spec.rect) }
        case .windowAdded(let spec):
            if let existing = shown(spec.id) { return existing.apply(spec, surface: surface) }
            if spec.popup == true { return addPopup(spec) }
            let window = SurfaceWindow(spec: spec, defaultScale: defaultScale) { [weak self] in self?.send($0) }
            window.delegate = self
            window.onGesture = { [weak self] _, active in self?.gesture(active: active) }
            attachCursor(window.surfaceView)
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
            shown(spec.id)?.apply(spec, surface: surface)
        case .windowRemoved(let id):
            if let window = windows.removeValue(forKey: id) {
                window.delegate = nil
                window.onGesture = nil
                if window.isFrozen { gesture(active: false) }
                window.orderOut(nil)
                window.close()
            }
            if let popup = popups.removeValue(forKey: id) {
                hiddenForGesture.remove(id)
                popup.orderOut(nil)
                popup.close()
            }
            if windows.isEmpty { scheduleWindowlessQuit() }
        case .frame(_, let dirty, let sentNs):
            for window in allWindows where dirty.contains(where: { $0.intersects(window.spec.rect) }) {
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
        case .cursor(let shape):
            pointerChanged(shape)
        case .gestureDone(let id):
            windows[id]?.gestureDone(surface: surface)
        case .icon(let png):
            // Phase 3: the store icon arrived after the bundle was generated (docs/99 §12.15).
            guard let image = NSImage(data: png), image.isValid else { return note("app icon not readable; keeping the current one") }
            NSApp.applicationIconImage = image
        case .launcherShortcut(let raw):
            // The global shortcut chosen in Settings (or none): the ICA menu shows and takes that one.
            let shortcut = LauncherHotKey.stored(raw).shortcut
            guard shortcut != launcherShortcut else { return }
            launcherShortcut = shortcut
            if greeted { NSApp.mainMenu = menu(appName: appName) }
        }
    }

    /// A popup, menu or tooltip (phase 2): above this app's windows, without activating it, as in the main
    /// process (`SeamlessPanel`, ordered front without becoming key).
    private func addPopup(_ spec: HelperWindowSpec) {
        let popup = SurfacePanel(spec: spec, defaultScale: defaultScale) { [weak self] in self?.send($0) }
        attachCursor(popup.surfaceView)
        popups[spec.id] = popup
        popup.surfaceView.refresh(surface, crop: spec.rect)
        popup.orderFront(nil)
    }

    /// A local move/resize started or ended (D20): popups are hidden meanwhile, as in the main process.
    private func gesture(active: Bool) {
        if active {
            for (id, popup) in popups where popup.isVisible {
                popup.orderOut(nil)
                hiddenForGesture.insert(id)
            }
        } else {
            for id in hiddenForGesture { popups[id]?.orderFront(nil) }
            hiddenForGesture.removeAll()
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

    // MARK: Pointer shape (phase 2)

    private func attachCursor(_ view: SurfaceView) {
        view.cursorProvider = { [weak self] scale in self?.cursor(scale: scale) }
        view.ownMenu = menuSections
    }

    /// The remote pointer at k session pixels per point: px / k points, as in the main process.
    private func cursor(scale: CGFloat) -> NSCursor? {
        guard let pointer else { return nil }
        if let cached = cursors[scale] { return cached }
        let cursor: NSCursor
        if let image = pointer.image {
            let g = pointer.shape.geometry(scale: Double(scale))
            cursor = NSCursor(image: NSImage(cgImage: image, size: g.size), hotSpot: g.hotspot)
        } else {
            cursor = Self.hiddenCursor
        }
        cursors[scale] = cursor
        return cursor
    }

    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    private func pointerChanged(_ shape: HelperCursor) {
        if shape.arrow == true {
            pointer = nil                           // cursorProvider gives nil: the arrow
            cursors.removeAll()
            for window in allWindows { window.invalidateCursorRects(for: window.surfaceView) }
            let mouse = NSEvent.mouseLocation
            if allWindows.contains(where: { $0.isVisible && $0.frame.contains(mouse) }) { NSCursor.arrow.set() }
            return
        }
        var image: CGImage?
        if let png = shape.png {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return note("pointer shape not readable; keeping the previous one")
            }
            image = decoded
        }
        pointer = (shape, image)
        cursors.removeAll()
        let all = allWindows
        for window in all { window.invalidateCursorRects(for: window.surfaceView) }
        // Apply now if the pointer is over one of this app's windows (popups first: they are above).
        let mouse = NSEvent.mouseLocation
        if let over = all.first(where: { $0.isVisible && $0.frame.contains(mouse) }) { cursor(scale: over.surfaceView.scale)?.set() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? SurfaceWindow else { return }
        lastKeyWindow = window.spec.id
        link.send(.focus(windowId: window.spec.id))
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

    /// Moved or resized here, not by the host and not by a local gesture (AX, Mission Control, a window
    /// manager): the host turns it into one TWI move once it settles, as for its own windows (D20).
    func windowDidMove(_ notification: Notification) { reportGeometry(notification) }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? SurfaceWindow)?.resized()
        reportGeometry(notification)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        (notification.object as? SurfaceWindow)?.liveResizeStarted()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        (notification.object as? SurfaceWindow)?.liveResizeEnded()
    }

    private func reportGeometry(_ notification: Notification) {
        guard let window = notification.object as? SurfaceWindow, window.isSeamless, !window.applyingHost,
              !window.isMiniaturized, !window.inGesture, !window.inLiveResize else { return }
        link.send(.moved(windowId: window.spec.id, frame: WirePointRect(window.contentRect(forFrameRect: window.frame))))
    }

    // MARK: Menu bar (phase 2, `HelperMenu`)

    /// App menu (the bold title is CFBundleName), Edit, Window (AppKit lists the windows), ICA and Help.
    private func menu(appName: String) -> NSMenu {
        let main = NSMenu()
        menuSections = HelperMenu.sections(appName: appName, german: german, launcher: launcherShortcut)
        for section in menuSections {
            let menu = NSMenu(title: section.title)
            for item in section.items { menu.addItem(menuItem(item)) }
            let top = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
            switch section.role {
            case .window: NSApp.windowsMenu = menu
            case .help: NSApp.helpMenu = menu
            case .app, .edit, .ica: break
            }
        }
        return main
    }

    private func menuItem(_ model: HelperMenuItem) -> NSMenuItem {
        guard let action = model.action else { return .separator() }
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: model.shortcut?.key ?? "")
        if let shortcut = model.shortcut {
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { mask.insert(.command) }
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            if shortcut.modifiers.contains(.control) { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
        switch action {
        case .about: (item.action, item.target) = (#selector(about(_:)), self)
        case .hide: item.action = #selector(NSApplication.hide(_:))
        case .hideOthers: item.action = #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: item.action = #selector(NSApplication.unhideAllApplications(_:))
        case .quit: item.action = #selector(NSApplication.terminate(_:))
        case .edit(let command):
            (item.action, item.target) = (#selector(editCommand(_:)), self)
            item.representedObject = command.rawValue
        case .close: item.action = #selector(NSWindow.performClose(_:))
        case .minimize: item.action = #selector(NSWindow.performMiniaturize(_:))
        case .zoom: (item.action, item.target) = (#selector(zoomWindow(_:)), self)
        case .bringAllToFront: item.action = #selector(NSApplication.arrangeInFront(_:))
        case .host(let command):
            (item.action, item.target) = (#selector(hostCommand(_:)), self)
            item.representedObject = command.rawValue
        case .help: (item.action, item.target) = (#selector(openHelp(_:)), self)
        }
        return item
    }

    /// The key app window (the menu acts on it), not the About panel or a popup.
    private var keySurfaceWindow: SurfaceWindow? {
        (NSApp.keyWindow as? SurfaceWindow).flatMap { $0.isSeamless && windows[$0.spec.id] === $0 ? $0 : nil }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(editCommand(_:)): return keySurfaceWindow != nil
        case #selector(zoomWindow(_:)):
            guard let window = keySurfaceWindow else { return false }
            return window.spec.zoomable == true && !window.isMiniaturized
        default: return true
        }
    }

    /// The remote app's name and where it comes from (the version is the helper template's).
    @objc private func about(_ sender: Any?) {
        let credits = NSAttributedString(string: HelperMenu.aboutCredits(german: german), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: appName, .credits: credits])
    }

    /// Chosen by mouse: the host sends Ctrl+letter to the remote app (and syncs the clipboard before Paste),
    /// exactly as for the shortcut, which the window itself forwards before the menu sees it.
    @objc private func editCommand(_ sender: NSMenuItem) {
        guard let window = keySurfaceWindow, let raw = sender.representedObject as? String, let command = EditCommand(rawValue: raw) else { return }
        send(.edit(windowId: window.spec.id, command))
    }

    /// TWI maximise or restore on the host (the window follows the host's rect); no local AppKit zoom.
    @objc private func zoomWindow(_ sender: Any?) {
        guard let window = keySurfaceWindow, window.spec.zoomable == true else { return }
        send(.zoom(windowId: window.spec.id))
    }

    /// Runs in the main process, which shows a window or a prompt: under cooperative activation it may come
    /// to the front only if this app yields to it first.
    @objc private func hostCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = HelperCommand(rawValue: raw) else { return }
        if let host = NSRunningApplication(processIdentifier: link.launch.hostPid) { NSApp.yieldActivation(to: host) }
        send(.command(command))
    }

    @objc private func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(HelperMenu.readmeURL)
    }
}
