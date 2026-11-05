import AppKit
import ICAKit

/// One running ICA session: wires the session's engines to NSWindows. Engine callbacks arrive on the
/// session queue and are hopped to the main thread here; everything in this class runs on main.
final class SessionController: NSObject {
    let name: String
    let session: ICASession
    /// Session ↔ screen coordinates. Fixed session size; the screen list may change (see `screensChanged`).
    private(set) var mapping: ScreenMapping
    let keyboard = KeyboardTranslator()
    var onEnded: ((SessionController) -> Void)?
    /// Called on main whenever the set of app windows changes (count of app windows).
    var onWindowsChanged: ((SessionController) -> Void)?
    /// Called each time an app window is shown.
    var onAppWindowShown: ((SessionController) -> Void)?
    /// True once the TWI host init arrived (the session got past the WD handshake and logon start).
    private(set) var reachedSeamless = false
    /// The session has no visible app window but its apps still run (e.g. a window left the desktop).
    /// The app delegate shows it in the launcher with Show / Log off.
    var onParkedChanged: ((SessionController) -> Void)?
    private(set) var isParked = false
    /// Evidence that this run logged the session on itself: the logon UI (logonui.exe) appeared and the
    /// post-logon TWI host init came ≥ 5 s later (live fresh logons: 10–16 s; a reconnect after the
    /// logon UI: 1.7 s; a plain reconnect shows no logon UI at all). Anything else counts as a
    /// reconnect to an existing, possibly the user's own, session.
    private(set) var sawLogonUI = false
    private var logonUIAt: Date?
    private var hostInits = 0
    private(set) var freshLogon = false

    private(set) var surface: IOSurfaceRef?
    private(set) var surfaceSize = CGSize.zero
    private(set) var cursor: NSCursor = .arrow
    private(set) var windows: [UInt32: RemoteWindow] = [:]
    /// Latest host state of every window (including hidden ones), mirrored on main.
    private var infos: [UInt32: TWIWindow] = [:]
    private var foreground: UInt32?
    private(set) var ended = false
    private(set) var endReason = ""
    private var pendingLogoff: DispatchWorkItem?
    /// App windows removed while the session had no other app window: id → last info.
    private var lastAppWindows: [UInt32: TWIWindow] = [:]
    private var endedProcesses: Set<UInt32> = []
    /// Windows the user asked to close (close button / Cmd-W).
    private var userClosed: Set<UInt32> = []
    private var screenObserver: NSObjectProtocol?
    /// Windows show no macOS title bar any more, so the work area needs no room for one.
    private let titleBar: CGFloat = 0
    /// Host caption/frame metrics (TWI SYSTEM_METRICS), for local caption drags.
    private(set) var systemMetrics: TWISystemMetrics?

    // Adaptive Thinwire FPS limit (C2H 0x1F): the host repaints idle windows at the limit, so drop it
    // when nothing happens and raise it on any input or window change.
    private let activeFPS = UInt16(ProcessInfo.processInfo.environment["ICA_FPS_ACTIVE"] ?? "") ?? 30
    private let idleFPS = UInt16(ProcessInfo.processInfo.environment["ICA_FPS_IDLE"] ?? "") ?? 5
    private var currentFPS: UInt16?
    private var lastActivity = Date()
    private var fpsTimer: Timer?
    private var sawAppWindow = false
    private var connected = false

    var appWindowCount: Int { windows.values.filter(\.isApp).count }

    init(name: String, ica: ICAFile) throws {
        self.name = name
        mapping = .current
        var config = WinstationDriver.Configuration()
        config.logon = WDLogon(ica: ica)
        // German client keyboard layout (the user's); scancodes are interpreted with it.
        config.logon.keyboardLayout = UInt32(ProcessInfo.processInfo.environment["ICA_KBD_LAYOUT"].flatMap { UInt32($0, radix: 16) } ?? 0x407)
        // Match macOS text rendering: greyscale anti-aliasing (1 = standard) instead of ClearType's
        // colour fringes. ICA_FONT_SMOOTHING: 0 none, 1 standard, 2 ClearType.
        config.logon.fontSmoothing = UInt16(ProcessInfo.processInfo.environment["ICA_FONT_SMOOTHING"] ?? "") ?? 1
        // The server rounds odd sizes down to even (live: 1169 → 1168); ask for the even size so the
        // mouse normalisation uses the same size as the server.
        // The session desktop is the union of all screens (docs/40 §2.3 cap 0x11, docs/50 §2.4.2).
        var display = WDDisplay(width: mapping.sessionWidth, height: mapping.sessionHeight)
        let monitors = mapping.monitors(titleBar: 0)
        if monitors.count > 1 { display.monitors = monitors.map(\.wd) }
        // ICA_TW_H264=0: advertise only the compatible-mode Thinwire caps (idle-repaint experiment).
        display.advertiseH264 = ProcessInfo.processInfo.environment["ICA_TW_H264"] != "0"
        config.display = display
        session = try ICASession(ica: ica, configuration: config)
        super.init()
        keyboard.controller = self
        session.seamless.setMonitors(monitors.map(\.twi))
        session.pauseResumeOnThinwireInit = ProcessInfo.processInfo.environment["ICA_TWI_PAUSE_RESUME"] != "0"
        wireCallbacks()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    deinit { screenObserver.map(NotificationCenter.default.removeObserver) }

    /// Screen configuration changed. With the same union size, the new layout goes to the host (TWI
    /// 0x3b, Thinwire 0x1D) and windows are re-placed. A different union size would need a Thinwire
    /// resize (C2H 0x1E, enhanced mode change; the server echoed cap 0x19) followed by TWI PAUSE/RESUME
    /// and a window replay; that is not implemented. Instead the session keeps its size and coordinate
    /// origin, and only the screens that still exist (clipped to it) are reported, so Windows moves
    /// windows off monitors that are gone.
    private func screensChanged() {
        let now = ScreenMapping.current
        guard now != mapping else { return }
        let next: ScreenMapping
        if now.sessionWidth == mapping.sessionWidth, now.sessionHeight == mapping.sessionHeight {
            next = now
        } else {
            vlog("screens changed: union \(now.sessionWidth)x\(now.sessionHeight) differs from the session \(mapping.sessionWidth)x\(mapping.sessionHeight); keeping the session size")
            next = ScreenMapping(screens: now.screens, union: mapping.union)
        }
        mapping = next
        let monitors = next.monitors(titleBar: titleBar)
        vlog("screens changed: \(monitors.count) monitor(s) \(monitors.map { "\($0.twi.bounds.left),\($0.twi.bounds.top) \($0.twi.bounds.width)x\($0.twi.bounds.height)" })")
        let wd = monitors.map(\.wd)
        session.send { driver, twi in
            twi.setMonitors(monitors.map(\.twi))
            if wd.count > 1 || driver.configuration.display.monitors.count > 1 { driver.send(WDModules.thinwireMonitorUpdate(wd)) }
        }
        windows.values.forEach { $0.mappingChanged() }
    }

    private func wireCallbacks() {
        let thinwire = session.thinwire
        thinwire.log = { vlog($0) }
        session.onThinwireInit = { [weak self, weak thinwire] info in
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
                case .packet(let p) where p.channel == 9:
                    self?.repeats.record(p.payload)
                case .packet(let p) where p.channel == 12:
                    self?.twiCapture?.record(p.payload)
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
    /// Thinwire payload repeat analysis (session queue only).
    private let repeats = RepeatTracker()
    /// ICAVIEWER_CAPTURE_TWI=1: raw TWI payloads to .session/viewer-ch12-<n>.bin (0600). Test app only:
    /// TWI carries window titles.
    private let twiCapture: TWICapture? = ProcessInfo.processInfo.environment["ICAVIEWER_CAPTURE_TWI"] == "1" ? TWICapture() : nil
    private var lastTWICounts: [UInt8: Int] = [:]
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
            let repeats = self.repeats
            session.perform {
                let sent = session.wd.takeSentCounts()
                let bytes = session.thinwire.stats.bytes
                let tw = repeats.take(stats: session.thinwire.stats)
                let counts = session.seamless.messageCounts
                let twi = counts.compactMap { t, n -> String? in
                    let d = n - (self.lastTWICounts[t] ?? 0)
                    return d > 0 ? String(format: "%02x×%d", t, d) : nil
                }.sorted().joined(separator: " ")
                self.lastTWICounts = counts
                let dropped = session.seamless.droppedWhileInactive
                Self.timerQueue.async {
                    let delta = bytes - lastBytes
                    lastBytes = bytes
                    let ui = counters.take()
                    guard !sent.isEmpty || delta > 0 || !ui.isEmpty || !twi.isEmpty else { return }
                    let list = sent.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                    let uiList = ui.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                    vlog(String(format: "traffic/s: thinwire in %d B (%@); twi in: %@ (dropped inactive %d); out: %@; ui: %@; main lag %.0f ms",
                                delta, tw, twi.isEmpty ? "-" : twi, dropped,
                                list.isEmpty ? "-" : list, uiList.isEmpty ? "-" : uiList, mainLag * 1000))
                }
            }
        }
        timer.resume()
        statsTimer = timer
    }

    func start() async throws {
        startTrafficStats()
        if let after = ProcessInfo.processInfo.environment["ICAVIEWER_TEST_RESUME_AFTER"].flatMap(Double.init) {
            let session = self.session
            Self.timerQueue.asyncAfter(deadline: .now() + after) {
                session.send { _, twi in vlog("test: PAUSE/RESUME now: \(twi.pauseResume() ? "sent" : "not possible")") }
            }
        }
        let display = session.wd.configuration.display
        vlog("session \(name): \(mapping.screens.count) screen(s), union \(Int(mapping.union.width))x\(Int(mapping.union.height)), display \(display.width)x\(display.height), monitors \(session.seamless.monitors.map { "\($0.bounds.left),\($0.bounds.top) \($0.bounds.width)x\($0.bounds.height)" }), h264 caps \(display.advertiseH264)")
        try await session.start()
    }

    // MARK: Thinwire → layers

    private var reconnectNudged = false
    private var windowCheck: DispatchWorkItem?

    /// Live: reconnecting to a session another client had used gave no window at all (host init, OPEN,
    /// metrics, then nothing). The host re-enumerates after PAUSE/RESUME (it answers with CLOSE + OPEN),
    /// so if a reconnect (no logon UI) shows no window 8 s after OPEN, send PAUSE/RESUME once more.
    private func scheduleReconnectWindowCheck() {
        windowCheck?.cancel()
        guard !reconnectNudged else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended, !self.reconnectNudged, self.infos.isEmpty, !self.sawLogonUI else { return }
            self.reconnectNudged = true
            vlog("reconnect without any window after 8 s: TWI PAUSE/RESUME to make the host re-enumerate")
            self.session.send { _, twi in twi.pauseResume() }
        }
        windowCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: Adaptive FPS

    /// Any user input or remote window change.
    func noteActivity() {
        lastActivity = Date()
        if currentFPS != nil, currentFPS != activeFPS { setFPS(activeFPS) }
    }

    private func setFPS(_ fps: UInt16) {
        guard idleFPS > 0, fps != currentFPS else { return }
        currentFPS = fps
        vlog("FPS limit → \(fps)")
        let thinwire = session.thinwire
        session.send { _, _ in
            if thinwire.sessionInfo?.has(0x1C) ?? false { thinwire.sendFPSLimit(fps) }
        }
    }

    private func startFPSGovernor(initial: UInt16?) {
        currentFPS = initial
        guard idleFPS > 0, fpsTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.ended, self.currentFPS != nil else { return }
            if Date().timeIntervalSince(self.lastActivity) > 2 { self.setFPS(self.idleFPS) }
        }
        RunLoop.main.add(timer, forMode: .common)
        fpsTimer = timer
    }

    private var thinwireInits = 0

    private func surfaceChanged(_ surface: IOSurfaceRef?, info: ThinwireSessionInfo) {
        // The post-logon Thinwire INIT is the most reliable logon marker: our PAUSE/RESUME after it
        // makes the host answer with CLOSE/OPEN instead of a second TWI host init.
        thinwireInits += 1
        if thinwireInits >= 2, !freshLogon, let t = logonUIAt {
            let gap = Date().timeIntervalSince(t)
            freshLogon = gap >= 5
            vlog(freshLogon ? "fresh logon (logon UI, then Thinwire INIT after \(Int(gap)) s)"
                            : String(format: "reconnect pattern (Thinwire INIT %.1f s after the logon UI)", gap))
        }
        // The engine sent its configured limit right after INIT.
        startFPSGovernor(initial: info.has(0x1C) ? (session.thinwire.config.fpsLimit ?? 0) : nil)
        lastActivity = Date()
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
        for w in windows.values { w.framePresented(rects) }
        if let surface {
            let seed = IOSurfaceGetSeed(surface)
            if seed == lastSeed { return }
            lastSeed = seed
        }
        for w in windows.values {
            let r = w.contentOrigin
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
            hostInits += 1
            if hostInits >= 2, !freshLogon, let t = logonUIAt {
                freshLogon = Date().timeIntervalSince(t) >= 5
                vlog(freshLogon ? "fresh logon (logon UI, then host init after \(Int(Date().timeIntervalSince(t))) s)"
                                : "reconnect pattern (host init \(String(format: "%.1f", Date().timeIntervalSince(t))) s after the logon UI)")
            }
            vlog(String(format: "TWI host init: flags 0x%08x, version %d, desktop %dx%d", host.flags.rawValue, host.hostVersion,
                        host.desktopWidth, host.desktopHeight))
        case .systemMetricsChanged(let m):
            systemMetrics = m
            vlog("TWI metrics: frame \(m.frameThickness.x),\(m.frameThickness.y) dialog \(m.dialogFrameThickness.x),\(m.dialogFrameThickness.y) caption \(m.captionHeight) button \(m.captionButtonWidth)")
        case .seamlessStateChanged(let active):
            vlog("TWI seamless active: \(active)")
            if active { scheduleReconnectWindowCheck() }
        case .windowAdded(let w):
            infos[w.id] = w
            noteActivity()
            if w.appKey.lowercased().hasSuffix("\\logonui.exe"), logonUIAt == nil { sawLogonUI = true; logonUIAt = Date() }
            vlog("TWI window \(String(w.id, radix: 16)) added: \(w.kind) \(safeTitle(w)) rect \(w.windowRect.left),\(w.windowRect.top) \(w.windowRect.width)x\(w.windowRect.height) app \(w.appKey)")
            materialise(w)
        case .windowChanged(let w, let changes):
            infos[w.id] = w
            noteActivity()
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
        case .windowsReset:
            resetGraceUntil = Date().addingTimeInterval(0.2)
        case .windowRemoved(let w) where Date() < resetGraceUntil && windows[w.id] != nil:
            // Removed by a list reset: keep the NSWindow (same window for switchers) for up to 2 s in
            // case the host re-announces it.
            infos[w.id] = nil
            limbo[w.id] = windows.removeValue(forKey: w.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let r = self.limbo.removeValue(forKey: w.id) else { return }
                vlog("TWI window \(String(w.id, radix: 16)) not re-announced after reset: closing")
                r.closeFromRemote()
                self.onWindowsChanged?(self)
                if r.isApp, self.appWindowCount == 0, !self.ended {
                    self.lastAppWindows[w.id] = r.info
                    self.lastAppWindowGone()
                }
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
        case .processEnded(let pid):
            endedProcesses.insert(pid)
            vlog("TWI process \(String(pid, radix: 16)) ended")
            if appWindowCount == 0, !lastAppWindows.isEmpty, !ended { lastAppWindowGone() }
        default:
            break
        }
    }

    /// Only the test app's title is logged verbatim.
    private func safeTitle(_ w: TWIWindow) -> String {
        w.title.hasPrefix("Rechner") ? "\"\(w.title)\"" : "(\(w.title.count) chars)"
    }

    private var limbo: [UInt32: RemoteWindow] = [:]
    private var resetGraceUntil = Date.distantPast

    private func materialise(_ w: TWIWindow) {
        if let kept = limbo.removeValue(forKey: w.id) {
            if w.kind != .hidden, kept.isApp == (w.kind == .appWindow) {
                vlog("TWI window \(String(w.id, radix: 16)) re-announced after reset: reusing its window")
                windows[w.id] = kept
                kept.update(w, [.title, .style, .windowRect, .clientRect, .kind])
                onWindowsChanged?(self)
                return
            }
            kept.closeFromRemote()
        }
        guard w.kind != .hidden, windows[w.id] == nil else { return }
        let remote = RemoteWindow(info: w, controller: self)
        windows[w.id] = remote
        remote.show(activate: w.kind == .appWindow && (foreground == w.id || appWindowCount == 1))
        if w.kind == .appWindow {
            sawAppWindow = true
            onAppWindowShown?(self)
            pendingLogoff?.cancel()
            lastAppWindows.removeAll()
            setParked(false)
            if appWindowCount == 1 { NSApp.activate() }
        }
        onWindowsChanged?(self)
    }

    private func remove(_ id: UInt32) {
        guard let w = windows.removeValue(forKey: id) else { return }
        w.closeFromRemote()
        onWindowsChanged?(self)
        if w.isApp, appWindowCount == 0, !ended {
            lastAppWindows[id] = w.info
            lastAppWindowGone()
        }
    }

    /// The session has no visible app window. Never log off just for that (a real app may only have
    /// moved a window away, and logon shows short-lived console windows). Log off only when the user
    /// closed the last app window and every process of those windows has ended per TWI PROCESS_ENDED.
    /// If a process still runs, park the session (launcher: Show / Log off); if the host closed the
    /// windows itself and their processes ended (logon scripts), just wait.
    private func lastAppWindowGone() {
        let pids = Set(lastAppWindows.values.compactMap(\.processId))
        let allKnown = lastAppWindows.values.allSatisfy { $0.processId != nil }
        let allEnded = allKnown && !pids.isEmpty && pids.isSubset(of: endedProcesses)
        let closedByUser = lastAppWindows.keys.contains { userClosed.contains($0) }
        if allEnded, !closedByUser {
            vlog("no app window; the host closed it and its processes ended: waiting for the app")
            setParked(false)
        } else if allEnded {
            pendingLogoff?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.session.isClosed else { return }
                vlog("the app's processes have ended and no app window is left: TWI logoff")
                self.logoff()
            }
            pendingLogoff = work
            // Short grace: the host may end the session itself, or the app may open a new window.
            Self.timerQueue.asyncAfter(deadline: .now() + 3, execute: work)
            setParked(false)
        } else {
            vlog("no visible app window, but the app still runs (processes \(pids.subtracting(endedProcesses).map { String($0, radix: 16) })): keeping the session")
            setParked(true)
        }
    }

    private func setParked(_ parked: Bool) {
        guard parked != isParked else { return }
        isParked = parked
        onParkedChanged?(self)
    }

    /// Launcher "Show": ask the host to bring the last app windows back onto the main screen.
    func showParkedWindows() {
        for (id, info) in lastAppWindows {
            let rect = mapping.onMainScreen(info.windowRect)
            vlog("show: moving \(String(id, radix: 16)) to \(rect.left),\(rect.top)")
            session.send { _, twi in
                twi.moveResize(windowId: id, rect: rect)
                twi.restore(windowId: id)
                twi.activate(windowId: id)
                twi.resendWindow(windowId: id)
            }
        }
    }

    func currentInfo(_ id: UInt32) -> TWIWindow? { infos[id] }

    // MARK: Local gestures

    private var hiddenForGesture: [RemoteWindow] = []

    /// A local move/resize started: popups (menus, tooltips) would stay behind, so hide them until the
    /// window is live again; the host closes or moves them meanwhile.
    func localGestureStarted(_ w: RemoteWindow) {
        noteActivity()
        let popups = windows.values.filter { !$0.isApp && $0.window.isVisible }
        popups.forEach { $0.window.orderOut(nil) }
        hiddenForGesture += popups
    }

    func localGestureEnded(_ w: RemoteWindow) {
        noteActivity()
        let back = hiddenForGesture.filter { p in windows.values.contains { $0 === p } }
        hiddenForGesture.removeAll()
        back.forEach { $0.window.orderFront(nil) }
    }

    /// Copy of the presented framebuffer pixels of a remote rect (session queue → main).
    func snapshot(_ r: TWIRect, completion: @escaping (CGImage?) -> Void) {
        let thinwire = session.thinwire
        session.perform {
            let image = thinwire.framebuffer?.makeImage(rect: CGRect(x: Int(r.left), y: Int(r.top), width: Int(r.width), height: Int(r.height)))
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: Requests (main → session queue)

    func mouse(x: Int, y: Int, state: WDBuild.MouseState) {
        noteActivity()
        let display = session.wd.configuration.display
        let x = min(max(x, 0), display.width - 1), y = min(max(y, 0), display.height - 1)
        session.send { wd, _ in
            if state == .moved { wd.mouse(x: x, y: y, state: .moved) }
            else { wd.mouse([(x, y, .moved), (x, y, state)]) }
        }
    }

    func wheel(x: Int, y: Int, delta: Int16) {
        noteActivity()
        session.send { wd, _ in wd.wheel(x: x, y: y, delta: delta) }
    }

    func moveResize(id: UInt32, rect: TWIRect) {
        noteActivity()
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
        userClosed.insert(id)
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

    /// End of an automated hold run: log off only a session this run freshly logged on; a reconnected
    /// session (maybe the user's own) is only disconnected, so it stays available to them.
    func endHold() {
        // ICAVIEWER_HOLD_END=disconnect|logoff forces the ending (only for sessions known to be ours).
        switch ProcessInfo.processInfo.environment["ICAVIEWER_HOLD_END"] {
        case "disconnect":
            vlog("hold end: disconnecting (forced)")
            let session = self.session
            if ProcessInfo.processInfo.environment["ICAVIEWER_TEST_PAUSE_AT_END"] == "1" {
                // Test: leave the host paused, as another client may (C2H PAUSE without RESUME).
                session.send { _, twi in
                    if twi.canSend { twi.output?(.channel(TWIRequest.pause())) }
                    vlog("test: sent TWI PAUSE before disconnecting")
                }
            }
            Task { try? await Task.sleep(for: .milliseconds(300)); await session.close() }
            return
        case "logoff":
            vlog("hold end: logoff (forced)")
            logoff()
            return
        default: break
        }
        if freshLogon {
            logoff()
        } else {
            vlog("not a fresh logon by this run (reconnect to an existing session): disconnecting without logoff")
            let session = self.session
            Task { await session.close() }
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
        pendingLogoff?.cancel()
        statsTimer?.cancel()
        fpsTimer?.invalidate()
        setParked(false)
        vlog("session \(name) closed: \(reason)")
        for id in Array(windows.keys) { remove(id) }
        onEnded?(self)
    }
}

/// Counts Thinwire payloads per second and how many were byte-identical repeats (session queue only).
/// ICAVIEWER_CAPTURE_REPEATS=1 saves up to 10 distinct payloads seen at least 3 times to
/// `.session/repeat-ch9-<n>.bin` (0600): these are drawing commands against the cache, not new bitmaps.
final class RepeatTracker: @unchecked Sendable {
    private var seen: [Int: Int] = [:]
    private var payloads = 0
    private var repeated = 0
    private var lastFrames = 0
    private var lastOps: [UInt8: Int] = [:]
    private var saved: Set<Int> = []
    private let capture = ProcessInfo.processInfo.environment["ICAVIEWER_CAPTURE_REPEATS"] == "1"

    func record(_ payload: [UInt8]) {
        var h = Hasher()
        h.combine(payload)
        let key = h.finalize()
        payloads += 1
        let n = (seen[key] ?? 0) + 1
        seen[key] = n
        if n > 1 { repeated += 1 }
        if seen.count > 4096 { seen.removeAll() }
        if capture, n == 3, saved.count < 10, payload.count > 8 {
            saved.insert(key)
            let url = Paths.sessionDir.appendingPathComponent(String(format: "repeat-ch9-%02d.bin", saved.count))
            FileManager.default.createFile(atPath: url.path, contents: Data(payload), attributes: [.posixPermissions: 0o600])
            vlog("captured repeated Thinwire payload \(url.lastPathComponent) (\(payload.count) B, starts \(payload.prefix(6).map { String(format: "%02x", $0) }.joined()))")
        }
    }

    /// Per-interval summary: payloads, repeats, frames, top opcodes.
    func take(stats: ThinwireEngine.Stats) -> String {
        defer { payloads = 0; repeated = 0; lastFrames = stats.frames; lastOps = stats.opcodes }
        let ops = stats.opcodes.compactMap { op, n -> (UInt8, Int)? in
            let d = n - (lastOps[op] ?? 0)
            return d > 0 ? (op, d) : nil
        }.sorted { $0.1 > $1.1 }.prefix(4).map { String(format: "%02X:%d", $0.0, $0.1) }.joined(separator: " ")
        return "\(payloads) payloads, \(repeated) repeats, \(stats.frames - lastFrames) frames, ops \(ops.isEmpty ? "-" : ops)"
    }
}

/// Raw TWI payload capture (session queue), max 400 files.
final class TWICapture: @unchecked Sendable {
    private var n = 0
    init() {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: Paths.sessionDir.path)) ?? [] where f.hasPrefix("viewer-ch12-") {
            try? FileManager.default.removeItem(at: Paths.sessionDir.appendingPathComponent(f))
        }
    }
    func record(_ payload: [UInt8]) {
        guard n < 400 else { return }
        n += 1
        let url = Paths.sessionDir.appendingPathComponent(String(format: "viewer-ch12-%04d.bin", n))
        FileManager.default.createFile(atPath: url.path, contents: Data(payload), attributes: [.posixPermissions: 0o600])
    }
}
