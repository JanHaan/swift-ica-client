import AppKit
import ICAKit

/// One running ICA session: wires the session's engines to NSWindows. Engine callbacks arrive on the
/// session queue and are hopped to the main thread here; everything in this class runs on main.
final class SessionController: NSObject {
    let name: String
    let session: ICASession
    let mapping: ScreenMapping
    let keyboard = KeyboardTranslator()
    var onEnded: ((SessionController) -> Void)?
    /// Called on main whenever the set of app windows changes (count of app windows).
    var onWindowsChanged: ((SessionController) -> Void)?
    /// Called each time an app window is shown.
    var onAppWindowShown: ((SessionController) -> Void)?
    /// True once the TWI host init arrived (the session got past the WD handshake and logon start).
    private(set) var reachedSeamless = false

    private(set) var surface: IOSurfaceRef?
    private(set) var surfaceSize = CGSize.zero
    private(set) var cursor: NSCursor = .arrow
    private(set) var windows: [UInt32: RemoteWindow] = [:]
    /// Latest host state of every window (including hidden ones), mirrored on main.
    private var infos: [UInt32: TWIWindow] = [:]
    private var foreground: UInt32?
    private(set) var ended = false
    private(set) var endReason = ""
    private var idleLogoff: DispatchWorkItem?
    private var sawAppWindow = false
    private var connected = false

    var appWindowCount: Int { windows.values.filter(\.isApp).count }

    init(name: String, ica: ICAFile) throws {
        self.name = name
        mapping = .primary
        var config = WinstationDriver.Configuration()
        config.logon = WDLogon(ica: ica)
        // German client keyboard layout (the user's); scancodes are interpreted with it.
        config.logon.keyboardLayout = UInt32(ProcessInfo.processInfo.environment["ICA_KBD_LAYOUT"].flatMap { UInt32($0, radix: 16) } ?? 0x407)
        // The server rounds odd sizes down to even (live: 1169 → 1168); ask for the even size so the
        // mouse normalisation uses the same size as the server.
        config.display = WDDisplay(width: Int(mapping.width) & ~1, height: Int(mapping.height) & ~1)
        session = try ICASession(ica: ica, configuration: config)
        super.init()
        keyboard.controller = self
        let titleBar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
        session.seamless.setMonitors([mapping.monitor(titleBar: titleBar)])
        wireCallbacks()
    }

    private func wireCallbacks() {
        let thinwire = session.thinwire
        thinwire.log = { vlog($0) }
        thinwire.onInit = { [weak self, weak thinwire] info in
            // Session queue: grab the (possibly new) surface here, apply on main.
            let surface = thinwire?.framebuffer?.ioSurface
            DispatchQueue.main.async { self?.surfaceChanged(surface, info: info) }
        }
        thinwire.onUpdate = { [weak self] rects in
            DispatchQueue.main.async { self?.framebufferUpdated(rects) }
        }
        thinwire.onPointer = { [weak self] image, hotspot in
            DispatchQueue.main.async { self?.pointerChanged(image, hotspot) }
        }
        session.seamless.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        session.onEvent = { [weak self] event in
            switch event {
            case .closed(let reason): DispatchQueue.main.async { self?.sessionClosed(reason) }
            case .log(let text): vlog(text)
            case .wd(let e):
                switch e {
                case .connected:
                    DispatchQueue.main.async { self?.connected = true }
                    vlog("WD connected")
                    // NumLock on, so the Mac keypad (always numeric) types digits.
                    self?.session.send { wd, _ in wd.setLED(0x20) }
                case .terminate(let reason): vlog("WD TERMINATE reason \(reason)")
                case .failure(let text): vlog("WD failure: \(text)")
                case .initRequest(let r): vlog("INIT_REQUEST level \(r.level), \(r.capabilities.count) caps")
                default: break
                }
            default: break
            }
        }
    }

    /// Counters shared between main and the stats queue.
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func add(_ key: String, _ n: Int = 1) { lock.lock(); values[key, default: 0] += n; lock.unlock() }
        func take() -> [String: Int] { lock.lock(); defer { values = [:]; lock.unlock() }; return values }
    }
    private let counters = Counters()
    private var statsTimer: DispatchSourceTimer?
    /// Timers that must fire even if the main thread is busy (stats, logoff fallbacks, hold mode).
    static let timerQueue = DispatchQueue(label: "ica.viewer.timers", qos: .utility)

    /// Once a second, independent of the main thread: client → server packet counts, Thinwire bytes
    /// received, main-thread refresh/pointer work, and how long the main queue took to answer last time.
    private func startTrafficStats() {
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        var lastBytes = 0
        var mainLag: Double = 0
        var probeOutstanding = false
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let session = self.session
            let counters = self.counters
            if !probeOutstanding {
                probeOutstanding = true
                let t0 = Date()
                DispatchQueue.main.async { Self.timerQueue.async { mainLag = Date().timeIntervalSince(t0); probeOutstanding = false } }
            } else {
                vlog("warning: main thread has not answered for over 1 s")
            }
            session.perform {
                let sent = session.wd.takeSentCounts()
                let bytes = session.thinwire.stats.bytes
                Self.timerQueue.async {
                    let delta = bytes - lastBytes
                    lastBytes = bytes
                    let ui = counters.take()
                    guard !sent.isEmpty || delta > 0 || !ui.isEmpty else { return }
                    let list = sent.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                    let uiList = ui.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                    vlog(String(format: "traffic/s: thinwire in %d B; out: %@; ui: %@; main lag %.0f ms", delta,
                                list.isEmpty ? "-" : list, uiList.isEmpty ? "-" : uiList, mainLag * 1000))
                }
            }
        }
        timer.resume()
        statsTimer = timer
    }

    func start() async throws {
        startTrafficStats()
        let display = session.wd.configuration.display
        vlog("session \(name): screen \(Int(mapping.width))x\(Int(mapping.height)), display \(display.width)x\(display.height)")
        try await session.start()
    }

    // MARK: Thinwire → layers

    private func surfaceChanged(_ surface: IOSurfaceRef?, info: ThinwireSessionInfo) {
        self.surface = surface
        lastSeed = nil
        surfaceSize = CGSize(width: info.width, height: info.height)
        vlog("Thinwire INIT \(info.width)x\(info.height) depth \(info.colorDepth) profile \(info.profile)")
        let display = session.wd.configuration.display
        if info.width != display.width || info.height != display.height {
            vlog("warning: server session size differs from the screen; coordinates will be off")
        }
        windows.values.forEach { $0.view.refresh() }
    }

    private var pendingRects: [CGRect] = []
    private var refreshScheduled = false
    private var lastSeed: UInt32?

    /// Coalesces Thinwire updates: at most one layer refresh pass per main-loop turn, and none when
    /// the front surface did not change (IOSurface seed).
    private func framebufferUpdated(_ rects: [CGRect]) {
        pendingRects += rects
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushRefresh() }
    }

    private func flushRefresh() {
        refreshScheduled = false
        let rects = pendingRects
        pendingRects.removeAll()
        if let surface {
            let seed = IOSurfaceGetSeed(surface)
            if seed == lastSeed { return }
            lastSeed = seed
        }
        for w in windows.values {
            let r = w.info.windowRect
            let wr = CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: w.view.bounds.width, height: w.view.bounds.height)
            if rects.contains(where: { $0.intersects(wr) }) {
                w.view.refresh()
                counters.add("refresh")
            }
        }
    }

    private var pointerCount = 0
    private var lastPointer: (image: CGImage, hotspot: CGPoint)?

    private func pointerChanged(_ image: CGImage?, _ hotspot: CGPoint) {
        counters.add("pointer")
        if let image, let last = lastPointer, last.hotspot == hotspot, last.image.width == image.width,
           last.image.height == image.height, last.image.dataProvider?.data == image.dataProvider?.data {
            return   // same shape again: nothing to do
        }
        lastPointer = image.map { ($0, hotspot) }
        pointerCount += 1
        if pointerCount <= 3 { vlog("pointer shape \(pointerCount): \(image.map { "\($0.width)x\($0.height)" } ?? "hidden") hotspot \(hotspot)") }
        if let image {
            let size = NSSize(width: image.width, height: image.height)   // 1 session pixel = 1 point
            cursor = NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: hotspot)
        } else {
            cursor = Self.hiddenCursor
        }
        for w in windows.values { w.window.invalidateCursorRects(for: w.view) }
        // Apply now if the pointer is over one of our windows.
        let mouse = NSEvent.mouseLocation
        if windows.values.contains(where: { $0.window.isVisible && $0.window.frame.contains(mouse) }) { cursor.set() }
    }

    private static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    // MARK: TWI → windows

    private func handle(_ event: SeamlessEvent) {
        switch event {
        case .channelReady(let host):
            reachedSeamless = true
            vlog(String(format: "TWI host init: flags 0x%08x, version %d, desktop %dx%d", host.flags.rawValue, host.hostVersion,
                        host.desktopWidth, host.desktopHeight))
        case .seamlessStateChanged(let active):
            vlog("TWI seamless active: \(active)")
        case .windowAdded(let w):
            infos[w.id] = w
            vlog("TWI window \(String(w.id, radix: 16)) added: \(w.kind) \(safeTitle(w)) rect \(w.windowRect.left),\(w.windowRect.top) \(w.windowRect.width)x\(w.windowRect.height) app \(w.appKey)")
            materialise(w)
        case .windowChanged(let w, let changes):
            infos[w.id] = w
            if changes.contains(.windowRect) || changes.contains(.kind) || changes.contains(.style) || changes.contains(.title) {
                vlog("TWI window \(String(w.id, radix: 16)) changed \(changes.rawValue): \(w.kind) rect \(w.windowRect.left),\(w.windowRect.top) \(w.windowRect.width)x\(w.windowRect.height) min \(w.isMinimized)")
            }
            if let existing = windows[w.id] {
                if w.kind == .hidden || (existing.isApp != (w.kind == .appWindow)) {
                    remove(w.id)
                    materialise(w)
                } else {
                    existing.update(w, changes)
                }
            } else {
                materialise(w)
            }
        case .windowRemoved(let w):
            infos[w.id] = nil
            vlog("TWI window \(String(w.id, radix: 16)) removed")
            remove(w.id)
        case .windowActivated(let id):
            vlog("TWI host foreground: \(id.map { String($0, radix: 16) } ?? "none")")
            foreground = id
            if let id, let w = windows[id], w.isApp, NSApp.isActive, !w.window.isKeyWindow, !w.window.isMiniaturized {
                w.window.makeKeyAndOrderFront(nil)
            }
        case .appAdded(let app):
            vlog("TWI app added: \(app.key) \"\(app.name)\"")
        default:
            break
        }
    }

    /// Only the test app's title is logged verbatim.
    private func safeTitle(_ w: TWIWindow) -> String {
        w.title.hasPrefix("Rechner") ? "\"\(w.title)\"" : "(\(w.title.count) chars)"
    }

    private func materialise(_ w: TWIWindow) {
        guard w.kind != .hidden, windows[w.id] == nil else { return }
        let remote = RemoteWindow(info: w, controller: self)
        windows[w.id] = remote
        remote.show(activate: w.kind == .appWindow && (foreground == w.id || appWindowCount == 1))
        if w.kind == .appWindow {
            sawAppWindow = true
            onAppWindowShown?(self)
            idleLogoff?.cancel()
            if appWindowCount == 1 { NSApp.activate() }
        }
        onWindowsChanged?(self)
    }

    private func remove(_ id: UInt32) {
        guard let w = windows.removeValue(forKey: id) else { return }
        w.closeFromRemote()
        onWindowsChanged?(self)
        if sawAppWindow, appWindowCount == 0, !ended { scheduleIdleLogoff() }
    }

    /// The published app is gone but the session lingers: log it off after a grace period.
    private func scheduleIdleLogoff() {
        idleLogoff?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.session.isClosed else { return }
            vlog("no app windows for 10 s: TWI logoff")
            self.logoff()
        }
        idleLogoff = work
        Self.timerQueue.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func currentInfo(_ id: UInt32) -> TWIWindow? { infos[id] }

    // MARK: Requests (main → session queue)

    func mouse(x: Int, y: Int, state: WDBuild.MouseState) {
        let display = session.wd.configuration.display
        let x = min(max(x, 0), display.width - 1), y = min(max(y, 0), display.height - 1)
        session.send { wd, _ in
            if state == .moved { wd.mouse(x: x, y: y, state: .moved) }
            else { wd.mouse([(x, y, .moved), (x, y, state)]) }
        }
    }

    func wheel(x: Int, y: Int, delta: Int16) {
        session.send { wd, _ in wd.wheel(x: x, y: y, delta: delta) }
    }

    func moveResize(id: UInt32, rect: TWIRect) {
        session.send { _, twi in
            twi.moveResize(windowId: id, rect: rect)
            twi.activate(windowId: id)
        }
    }

    func windowBecameKey(_ w: RemoteWindow) {
        guard w.isApp, foreground != w.info.id else { return }
        let id = w.info.id
        vlog("→ ACTIVATE \(String(id, radix: 16)) (window became key)")
        session.send { _, twi in twi.activate(windowId: id) }
    }

    func requestClose(id: UInt32) {
        vlog("close requested for \(String(id, radix: 16))")
        session.send { _, twi in twi.requestClose(windowId: id) }
    }

    func minimize(id: UInt32) {
        vlog("minimise \(String(id, radix: 16))")
        keyboard.releaseAll()
        session.send { _, twi in twi.minimize(windowId: id) }
    }

    func restore(id: UInt32) {
        vlog("restore \(String(id, radix: 16))")
        session.send { _, twi in
            twi.restore(windowId: id)
            twi.activate(windowId: id)
        }
    }

    /// TWI logoff; falls back to closing the transport if the channel is not up. Callable from any
    /// thread: it only touches the session (its own queue) and the timer queue, never main.
    func logoff() {
        let session = self.session
        session.logoff { ok in
            vlog(ok ? "→ TWI LOGOFF" : "TWI not ready; closing the connection")
            if !ok { Task { await session.close() } }
        }
        // If the server does not end the session, close the transport after a while.
        Self.timerQueue.asyncAfter(deadline: .now() + 15) {
            guard !session.isClosed else { return }
            vlog("server did not end the session after logoff; closing")
            Task { await session.close() }
        }
    }

    private func sessionClosed(_ reason: String) {
        guard !ended else { return }
        ended = true
        endReason = reason
        idleLogoff?.cancel()
        statsTimer?.cancel()
        vlog("session \(name) closed: \(reason)")
        for id in Array(windows.keys) { remove(id) }
        onEnded?(self)
    }
}
