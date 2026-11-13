import AppHostKit
import AppKit
import ICAKit

/// One running ICA session: wires the session's engines to NSWindows. Engine callbacks arrive on the
/// session queue and are hopped to the main thread here; everything in this class runs on main.
final class SessionController: NSObject {
    let name: String
    let session: ICASession
    /// Session pixels ↔ screen points, per monitor (docs/80 §2). Fixed session size; the screen list may
    /// change (see `screensChanged`).
    private(set) var layout: ScalingLayout
    /// The scaling settings this session connected with (a later change needs a reconnect, docs/80 §3.3).
    let scalingSettings: ScalingSettings
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
    /// The user chose "Reconnect" after session reliability gave up: relaunch the same resource through
    /// the store, which reconnects to the now-disconnected session (docs/20 §3.12.11, D18). Without
    /// it a give-up ends the session like any other close.
    var onRelaunch: ((SessionController) -> Void)?
    /// The CGP link is down and a resume is pending (docs/20 §3.12.3): user input is dropped, windows
    /// stay as they are under a dark overlay.
    private(set) var inputBlocked = false
    /// Overlay alpha while suspended (nil = none), from the server's cap 9 dimming (§3.12.9).
    private(set) var dimAlpha: CGFloat?
    private var gaveUp: CGPTransport.GiveUp?
    private lazy var hud = ReconnectHUD()
    /// Evidence that this run logged the session on itself: the logon UI (logonui.exe) appeared and the
    /// post-logon TWI host init came ≥ 5 s later (live fresh logons: 10–16 s; a reconnect after the
    /// logon UI: 1.7 s; a plain reconnect shows no logon UI at all). Anything else counts as a
    /// reconnect to an existing, possibly the user's own, session.
    private var logon = FreshLogonDetector()
    var sawLogonUI: Bool { logon.sawLogonUI }
    var freshLogon: Bool { logon.isFresh }

    private(set) var surface: IOSurfaceRef?
    private(set) var surfaceSize = CGSize.zero
    private(set) var cursor: NSCursor = .arrow
    private(set) var windows: [UInt32: RemoteWindow] = [:]
    /// Latest host state of every window (including hidden ones), mirrored on main.
    private var infos: [UInt32: TWIWindow] = [:]
    private var foreground: UInt32?
    /// Remote apps by key, for the Dock icon (names match store resources).
    private var apps: [String: TWIApp] = [:]
    private(set) var ended = false
    private(set) var endReason = ""
    private var pendingLogoff: DispatchWorkItem?
    /// App windows removed while the session had no other app window: id → last info.
    private var lastAppWindows: [UInt32: TWIWindow] = [:]
    private var endedProcesses: Set<UInt32> = []
    /// Windows the user asked to close (close button / Cmd-W).
    private var userClosed: Set<UInt32> = []
    private var screenObserver: NSObjectProtocol?
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

    /// The INIT_RESPONSE carried the CTXCAM module (main thread; logged with an early drop).
    private(set) var announcedAudio = false
    /// Reached the first Thinwire INIT or the seamless channel. Main thread.
    var wasEstablished: Bool { reachedSeamless || session.isEstablished }

    // MARK: Session sharing (docs/55)

    /// What decides whether a later launch belongs into this session (§2).
    let shareKey: SessionShareKey
    /// The resources running in this session, the launched one first, then those started over CTXCTL (status 0).
    private(set) var appNames: [String]
    /// The session announced CTXCTL (it can take further apps once the channel is ready).
    var hasControl: Bool { session.control != nil }
    /// CTXCTL capability commit seen (main thread).
    private(set) var controlReady = false
    /// Shared launches sent or queued and not yet answered, and those answered with status 0 whose app has not shown
    /// a window yet: the session must not be logged off meanwhile (main thread).
    private var sharedLaunchesBusy = 0
    /// TWI app keys present when a shared launch went out; the first new key after the host reported it started is that
    /// resource (Dock icon and menu title, docs/99 Phase 0), unless it is a logon or system process, names itself as
    /// another app, or is not the executable the launch names (`AppNaming.mayBeLaunchedApp`, docs/99 §12.15).
    /// The session's own launch is awaited too (`AwaitedLaunch.ownLaunch`): its first real app after the logon phase
    /// (File Explorer for "Explorer Citrix ABC", rundll32 for "Sound ABC") is that resource.
    private var awaitingApps: [AwaitedLaunch] = []
    /// The own launch's entry is dropped this long after the logon phase if no app matched it.
    static let ownLaunchWindow: TimeInterval = 60
    private var logonPhaseOver = false
    /// A mapping is remembered across runs only after its app kept an app window this long (docs/99 §12.15).
    static let mappingConfirmDelay: TimeInterval = 5
    /// Resource name per TWI app key, for apps whose TWI data carries no published name.
    private var appResources: [String: String] = [:]
    /// A last-window logoff deferred while a shared launch was busy.
    private var logoffDeferred = false
    /// Processes of the app windows open at the first shared launch and of every app window after it (the logon's
    /// windows are over by then); with several apps all must have ended before a last-window logoff. nil before.
    private var appWindowProcesses: Set<UInt32>?

    init(name: String, ica: ICAFile) throws {
        self.name = name
        appNames = [name]
        shareKey = SessionShareKey(ica: ica)
        awaitingApps = [AwaitedLaunch(resource: name, hint: AppNaming.launchHint(initialProgram: ica["InitialProgram"] ?? ""), ownLaunch: true)]
        scalingSettings = ScalingSettings.load()
        layout = ScalingLayout.resolve(screens: Self.currentScreens(), settings: scalingSettings, limit: ScalingLimits.sessionLimit())
        var config = WinstationDriver.Configuration()
        config.logon = WDLogon(ica: ica)
        // German client keyboard layout (the user's); scancodes are interpreted with it.
        config.logon.keyboardLayout = UInt32(ProcessInfo.processInfo.environment["ICA_KBD_LAYOUT"].flatMap { UInt32($0, radix: 16) } ?? 0x407)
        // Match macOS text rendering: greyscale anti-aliasing (1 = standard) instead of ClearType's
        // colour fringes. ICA_FONT_SMOOTHING: 0 none, 1 standard, 2 ClearType.
        config.logon.fontSmoothing = UInt16(ProcessInfo.processInfo.environment["ICA_FONT_SMOOTHING"] ?? "") ?? 1
        // The session desktop covers all screens, each at its client scale (docs/80 §1.6, §2.3); every
        // size is even (the server rounds odd sizes down, live: 1169 → 1168), so the mouse normalisation
        // uses the server's size. Block A size, cap 0x20 and (several monitors) cap 0x11 come from it.
        var display = WDDisplay()
        layout.apply(to: &display)
        // ICA_TW_H264=0: advertise only the compatible-mode Thinwire caps (idle-repaint experiment).
        display.advertiseH264 = ProcessInfo.processInfo.environment["ICA_TW_H264"] != "0"
        config.display = display
        session = try ICASession(ica: ica, configuration: config, clipboard: Self.clipboardConfig(), cdm: Self.driveMappingConfig(),
                                 printing: Self.printingConfig(), audio: Self.audioConfig(),
                                 webcam: Self.webcamConfig(), control: Self.controlConfig(ica: ica, seamless: config.logon.seamless))
        super.init()
        keyboard.controller = self
        setUpClipboard()
        setUpDriveMapping()
        setUpPrinting()
        setUpAudio()
        setUpWebcam()
        setUpControl()
        session.seamless.setMonitors(layout.twiMonitors)
        session.pauseResumeOnThinwireInit = ProcessInfo.processInfo.environment["ICA_TWI_PAUSE_RESUME"] != "0"
        wireCallbacks()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        Self.registry.append(Weak(self))
        Self.lastLayout = layout
    }

    deinit { screenObserver.map(NotificationCenter.default.removeObserver) }

    /// The screens for a session layout, main screen first. ICAVIEWER_SINGLE_SCREEN=1: main screen only
    /// (test: create a session with another layout).
    static func currentScreens() -> [ScalingScreen] {
        let screens = ProcessInfo.processInfo.environment["ICAVIEWER_SINGLE_SCREEN"] == "1" ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        return screens.map { ScalingScreen(frame: $0.frame, visible: $0.visibleFrame, backingScale: $0.backingScaleFactor) }
    }

    // MARK: Running sessions (Settings offers a reconnect when scaling changed)

    private final class Weak {
        weak var value: SessionController?
        init(_ value: SessionController) { self.value = value }
    }
    private static var registry: [Weak] = []
    /// The layout of the most recent session (Settings explains a fallback after it ended).
    private(set) static var lastLayout: ScalingLayout?

    /// Sessions that have not ended (main thread).
    static var running: [SessionController] {
        registry.removeAll { $0.value == nil || $0.value!.ended }
        return registry.compactMap(\.value)
    }

    /// Whether a reconnect with `settings` would give a different session (size, per-monitor scale or
    /// Windows scaling); other settings that resolve to the same layout (e.g. a fallback) need none.
    func differs(from settings: ScalingSettings) -> Bool {
        guard settings != scalingSettings else { return false }
        let next = ScalingLayout.resolve(screens: Self.currentScreens(), settings: settings, limit: ScalingLimits.sessionLimit())
        return !next.sameSession(as: layout)
    }

    /// Monitor whose map places a remote window: the one holding most of it; for a popup that overlaps
    /// an app window (its owner first), that window's monitor, so menus of a window straddling two
    /// screens line up with it.
    func placementMonitor(for info: TWIWindow) -> Int {
        if info.kind != .appWindow,
           let m = ScalingLayout.popupMonitor(info.windowRect, ownerId: info.ownerId,
                                              windows: windows.values.filter { $0.isApp && $0.info.id != info.id }
                                                  .map { ($0.info.id, $0.info.windowRect, $0.monitorIndex) }),
           m < layout.monitors.count {
            return m
        }
        return layout.monitorIndex(forSession: info.windowRect)
    }

    private var relaunchAfterClose = false

    /// Settings changed mid-session (docs/80 §3.3): disconnect cleanly (CGP FINISH, never a logoff) and
    /// relaunch the resource, which reconnects to the session with the new values (D18 path).
    func reconnectToApplySettings() {
        guard !ended, !relaunchAfterClose, onRelaunch != nil else { return }
        vlog("scaling: reconnecting \(logName(name)) to apply \(ScalingSettings.load()) (disconnect, no logoff)")
        relaunchAfterClose = true
        keyboard.releaseAll()
        let session = self.session
        Task { await session.close() }
    }

    /// Screen configuration changed. With the same session size, the new layout goes to the host (TWI
    /// 0x3b, Thinwire 0x1D) and windows are re-placed. A different size would need a Thinwire resize
    /// (C2H 0x1E, enhanced mode change; the server echoed cap 0x19) followed by TWI PAUSE/RESUME and a
    /// window replay; that is not implemented. Instead the session keeps its size: screens still in
    /// place keep their monitor, others map through the primary's scale, clipped to the session, so
    /// Windows moves windows off monitors that are gone (`ScalingLayout.keepingSession`).
    private func screensChanged() {
        let next = layout.keepingSession(screens: Self.currentScreens())
        guard next != layout else { return }
        let previous = layout
        layout = next
        vlog("screens changed: \(next.monitors.count) monitor(s) \(next.monitors.map { "\($0.bounds.left),\($0.bounds.top) \($0.bounds.width)x\($0.bounds.height) @\($0.scale)x" })")
        let wd = next.wdMonitors, twiMonitors = next.twiMonitors
        session.send { driver, twi in
            twi.setMonitors(twiMonitors)
            if wd.count > 1 || driver.configuration.display.monitors.count > 1 { driver.send(WDModules.thinwireMonitorUpdate(wd)) }
        }
        if previous.monitors.map(\.scale) != next.monitors.map(\.scale) || previous.monitors.map(\.frame) != next.monitors.map(\.frame) {
            lastCursorScale = nil
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
            case .suspended(let info): DispatchQueue.main.async { self?.linkSuspended(info) }
            case .resumed: DispatchQueue.main.async { self?.linkResumed() }
            case .gaveUp(let info): DispatchQueue.main.async { self?.gaveUp = info }
            case .wd(let e):
                switch e {
                case .connected:
                    DispatchQueue.main.async { self?.connected = true }
                    vlog("WD connected")
                    // NumLock on, so the Mac keypad (always numeric) types digits, but only after the
                    // host's first framed packet: never right behind INIT_CONNECT_RESPONSE
                    // (notes/early-drop-analysis.md H1).
                    self?.ledGate.connectResponseSent()
                case .packet(let p) where self?.ledGate.hostPacket(type: p.type) == true:
                    self?.sendNumLock(after: self?.ledGate.sentAfter)
                    if p.channel == 9 { self?.repeats.record(p.payload) }
                    if p.channel == 12 { self?.twiCapture?.record(p.payload) }
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

    /// SET_LED gate (session queue).
    private var ledGate = LEDGate()

    /// Queued behind the packet being handled (the credential reply goes first), on the session queue.
    private func sendNumLock(after trigger: LEDGate.Trigger?) {
        let session = self.session
        Self.timerQueue.async {
            session.send { wd, _ in
                wd.setLED(0x20)
                vlog("led: sent after \(trigger?.description ?? "?")")
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
        layout.logLines.forEach(vlog)
        if let note = layout.note { vlog("scaling: \(scalingNoteText(note, context: .current, english: true))") }
        vlog("session \(logName(name)): \(layout.monitors.count) screen(s), display \(display.width)x\(display.height), cap 0x20 \(display.monitors.isEmpty ? [display.scalePercent] : display.monitors.map(\.scalePercent)) %, monitors \(session.seamless.monitors.map { "\($0.bounds.left),\($0.bounds.top) \($0.bounds.width)x\($0.bounds.height)" }), h264 caps \(display.advertiseH264)")
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

    private func surfaceChanged(_ surface: IOSurfaceRef?, info: ThinwireSessionInfo) {
        // The post-logon Thinwire INIT is the most reliable logon marker: our PAUSE/RESUME after it
        // makes the host answer with CLOSE/OPEN instead of a second TWI host init.
        if let gap = logon.thinwireInit() {
            vlog(freshLogon ? "fresh logon (logon UI, then Thinwire INIT after \(Int(gap)) s)"
                            : String(format: "reconnect pattern (Thinwire INIT %.1f s after the logon UI)", gap))
            endLogonPhase()
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
        if HelperManager.enabled { HelperManager.shared.surfaceChanged(self) }
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
        var shownByHelpers: [RemoteWindow] = []
        for w in windows.values {
            let wr = w.contentPixelRect
            if rects.contains(where: { $0.intersects(wr) }) {
                if w.presenter != nil { shownByHelpers.append(w); continue }
                w.view.refresh()
                counters.add("refresh")
            }
        }
        if !shownByHelpers.isEmpty { HelperManager.shared.framePresented(shownByHelpers, rects: rects) }
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
        if HelperManager.enabled { HelperManager.shared.pointerChanged(self) }
        if pointerCount <= 3 { vlog("pointer shape \(pointerCount): \(image.map { "\($0.width)x\($0.height)" } ?? "hidden") hotspot \(hotspot)") }
        // The screen of the last position sent to the host (as in `mouse`), so a cursor over a window
        // that straddles two screens does not flip between the two scales.
        buildCursor(scale: layout.monitors[layout.monitorIndex(forSessionX: lastMouse.x, y: lastMouse.y)].scale)
    }

    /// The host's pointer shape for helper apps (docs/99 §12 phase 2): nil before the first shape; `image` nil =
    /// hidden. Session pixels; each helper window scales it by its own k.
    var pointerShape: (image: CGImage?, hotspot: CGPoint)? {
        guard pointerCount > 0 else { return nil }
        return (lastPointer?.image, lastPointer?.hotspot ?? .zero)
    }

    /// k the cursor was built for; the host sends pointer bitmaps in session pixels.
    private var lastCursorScale: Int?

    /// The pointer image is session pixels: on a screen with k px per point it is px / k points
    /// (half size at 2x, so a 64 px host cursor at 200 % is a 32 pt Retina-sharp cursor).
    private func buildCursor(scale: Int) {
        lastCursorScale = scale
        if let p = lastPointer {
            let g = ScalingLayout.cursor(pixelWidth: p.image.width, pixelHeight: p.image.height, hotspot: p.hotspot, scale: scale)
            cursor = NSCursor(image: NSImage(cgImage: p.image, size: g.size), hotSpot: g.hotspot)
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
            if let gap = logon.hostInit() {
                vlog(freshLogon ? "fresh logon (logon UI, then host init after \(Int(gap)) s)"
                                : "reconnect pattern (host init \(String(format: "%.1f", gap)) s after the logon UI)")
                endLogonPhase()
            } else if !logon.sawLogonUI {
                // No logon UI within 3 s of the host init: a plain reconnect, no logon phase to wait for.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.logon.sawLogonUI else { return }
                    self.endLogonPhase()
                }
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
            logon.windowAdded(appKey: w.appKey)
            vlog("TWI window \(String(w.id, radix: 16)) added: \(w.kind) \(safeTitle(w)) rect \(w.windowRect.left),\(w.windowRect.top) \(w.windowRect.width)x\(w.windowRect.height) app \(logName(w.appKey))")
            materialise(w)
        case .windowChanged(let w, let changes):
            infos[w.id] = w
            noteActivity()
            if w.kind == .appWindow, let pid = w.processId { appWindowProcesses?.insert(pid) }
            if changes.contains(.icon) || changes.contains(.app) { DockIcon.shared.scheduleRefresh() }
            if changes.contains(.windowRect) || changes.contains(.kind) || changes.contains(.style) || changes.contains(.title) {
                vlog("TWI window \(String(w.id, radix: 16)) changed \(changes.rawValue): \(w.kind) rect \(w.windowRect.left),\(w.windowRect.top) \(w.windowRect.width)x\(w.windowRect.height) min \(w.isMinimized)")
            }
            if let existing = windows[w.id] {
                if w.kind == .hidden || (existing.isApp != (w.kind == .appWindow)) {
                    remove(w.id)
                    materialise(w)
                } else {
                    existing.update(w, changes)
                    // The app key can settle after the window exists (process info arrives later).
                    if changes.contains(.app), HelperManager.enabled { HelperManager.shared.appKeyChanged(existing) }
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
                self.windowsChanged()
                if r.isApp, self.appWindowCount == 0, !self.ended {
                    self.lastAppWindows[w.id] = r.info
                    self.lastAppWindowGone()
                }
            }
        case .windowRemoved(let w):
            infos[w.id] = nil
            vlog("TWI window \(String(w.id, radix: 16)) removed")
            remove(w.id)
            DockIcon.shared.scheduleRefresh()
        case .windowActivated(let id):
            vlog("TWI host foreground: \(id.map { String($0, radix: 16) } ?? "none")")
            foreground = id
            if let id, let w = windows[id], w.isApp, HelperManager.enabled, w.presenter != nil || HelperManager.shared.helperIsFrontmost {
                // A window in a helper app, or ours while a helper is in front: hand activation over (docs/99 §12.5).
                HelperManager.shared.hostActivated(w)
            } else if let id, let w = windows[id], w.isApp, NSApp.isActive, !w.window.isKeyWindow, !w.window.isMiniaturized {
                w.window.makeKeyAndOrderFront(nil)
            }
        case .appAdded(let app):
            vlog("TWI app added: \(logName(app.key)) \(logName(app.name))")
            apps[app.key] = app
            if let published = app.publishedName, !published.isEmpty {
                RememberedAppResources.shared.confirm(app.key, publishedName: published)
            }
            // The first new app after a shared launch is that resource, unless it names itself as another one.
            let exe = AppNaming.executableName(key: app.key, executablePath: app.executablePath)
            if appResources[app.key] == nil,
               let i = AppNaming.firstMatch(awaitingApps, key: app.key, executable: exe, publishedName: app.publishedName, at: Date()) {
                let entry = awaitingApps.remove(at: i)
                appResources[app.key] = entry.resource
                vlog("\(entry.ownLaunch ? "launch" : "session sharing"): TWI app \(logName(app.key)) is \(logName(entry.resource))")
                if app.publishedName?.isEmpty ?? true { confirmMappingLater(app.key, entry.resource, executable: exe) }
                if HelperManager.enabled { HelperManager.shared.identityChanged(self, appKey: app.key) }
            } else if awaitingApps.contains(where: { !$0.known.contains(app.key) }) {
                vlog("session sharing: TWI app \(logName(app.key)) is not taken for the pending launch"
                     + (AppNaming.isSystemProcess(exe) ? " (logon or system process)" : " (launch not started yet, or another app)"))
            }
            DockIcon.shared.scheduleRefresh()
        case .appChanged(let app):
            apps[app.key] = app
            DockIcon.shared.scheduleRefresh()
        case .appRemoved(let app):
            apps[app.key] = nil
        case .processEnded(let pid):
            endedProcesses.insert(pid)
            vlog("TWI process \(String(pid, radix: 16)) ended")
            if appWindowCount == 0, !lastAppWindows.isEmpty, !ended { lastAppWindowGone() }
        default:
            break
        }
    }

    /// Window titles are the user's documents: only their length is logged.
    private func safeTitle(_ w: TWIWindow) -> String {
        "(\(w.title.count) chars)"
    }

    private var limbo: [UInt32: RemoteWindow] = [:]
    private var resetGraceUntil = Date.distantPast

    private func materialise(_ w: TWIWindow) {
        if let kept = limbo.removeValue(forKey: w.id) {
            if w.kind != .hidden, kept.isApp == (w.kind == .appWindow) {
                vlog("TWI window \(String(w.id, radix: 16)) re-announced after reset: reusing its window")
                windows[w.id] = kept
                kept.update(w, [.title, .style, .windowRect, .clientRect, .kind])
                windowsChanged()
                return
            }
            kept.closeFromRemote()
        }
        guard w.kind != .hidden, windows[w.id] == nil else { return }
        let remote = RemoteWindow(info: w, controller: self)
        windows[w.id] = remote
        if HelperManager.enabled { HelperManager.shared.claim(remote) }
        if let dimAlpha { remote.setDimmed(dimAlpha) }
        remote.show(activate: w.kind == .appWindow && (foreground == w.id || appWindowCount == 1))
        if w.kind == .appWindow {
            sawAppWindow = true
            if let pid = w.processId { appWindowProcesses?.insert(pid) }
            onAppWindowShown?(self)
            pendingLogoff?.cancel()
            lastAppWindows.removeAll()
            logoffDeferred = false
            setParked(false)
            if appWindowCount == 1, remote.presenter == nil { NSApp.activate() }
        }
        windowsChanged()
    }

    /// The set of windows changed: the callback, and the helper manager (phase 3: whether this process keeps its
    /// Dock tile depends on which app windows it shows itself).
    private func windowsChanged() {
        onWindowsChanged?(self)
        if HelperManager.enabled { HelperManager.shared.onChange?() }
    }

    private func remove(_ id: UInt32) {
        guard let w = windows.removeValue(forKey: id) else { return }
        w.closeFromRemote()
        windowsChanged()
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
        var pids = Set(lastAppWindows.values.compactMap(\.processId))
        // Several apps in this session (docs/55): the last window of one app is not the end of the others.
        if appNames.count > 1, let all = appWindowProcesses { pids.formUnion(all) }
        let allKnown = lastAppWindows.values.allSatisfy { $0.processId != nil }
        let allEnded = allKnown && !pids.isEmpty && pids.isSubset(of: endedProcesses)
        let closedByUser = lastAppWindows.keys.contains { userClosed.contains($0) }
        if allEnded, !closedByUser {
            vlog("no app window; the host closed it and its processes ended: waiting for the app")
            setParked(false)
        } else if allEnded, sharedLaunchesBusy > 0 {
            // Another app is being started in this session (docs/55): its window will come; decide again after.
            vlog("no app window and the processes ended, but \(sharedLaunchesBusy) shared launch(es) are busy: no logoff yet")
            logoffDeferred = true
            setParked(false)
        } else if allEnded {
            pendingLogoff?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.session.isClosed else { return }
                // A new window or a shared launch (main) cancels this item.
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
            let rect = layout.onMainScreen(info.windowRect)
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

    /// The app behind an app window, for the Dock icon (docs/99 Phase 0): its largest TWI icon over all
    /// its windows and the names to match against store resources.
    func dockSource(for w: RemoteWindow) -> DockIcon.Source? {
        guard w.isApp else { return nil }
        let key = w.info.appKey
        var best: TWIIcon?
        for info in infos.values where info.appKey == key && info.kind == .appWindow {
            for icon in info.icons.values where icon.image != nil && icon.width > (best?.width ?? 0) { best = icon }
        }
        let app = apps[key]
        // docs/99 §12.15: published name, this session's sharing mapping, a remembered one, the launched resource
        // only for its own app, then the TWI app's own name; never the launch resource for another app.
        let names = AppNaming.candidates(key: key, publishedName: app?.publishedName, sessionResource: appResources[key],
                                         rememberedResource: RememberedAppResources.shared.resource(for: key),
                                         twiName: app?.name ?? AppNaming.keyName(key), launchResource: name)
        return DockIcon.Source(key: key, names: names, twi: best?.image)
    }

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

    /// Mouse buttons down on the host (button-down state → its up state) and the last position, so a
    /// suspend can release them like `keyboard.releaseAll()`.
    private var buttonsDown: [UInt8: WDBuild.MouseState] = [:]
    private var lastMouse = (x: 0, y: 0)
    private static let buttonUps: [(down: WDBuild.MouseState, up: WDBuild.MouseState)] =
        [(.leftDown, .leftUp), (.rightDown, .rightUp), (.middleDown, .middleUp)]

    func mouse(x: Int, y: Int, state: WDBuild.MouseState) {
        guard !inputBlocked else { return }
        noteActivity()
        let display = session.wd.configuration.display
        let x = min(max(x, 0), display.width - 1), y = min(max(y, 0), display.height - 1)
        lastMouse = (x, y)
        // Moved onto a screen with another client scale: the same pointer bitmap at that screen's size.
        let k = layout.monitors[layout.monitorIndex(forSessionX: x, y: y)].scale
        if lastPointer != nil, k != lastCursorScale {
            buildCursor(scale: k)
            cursor.set()
        }
        for pair in Self.buttonUps {
            if state.contains(pair.down) { buttonsDown[pair.down.rawValue] = pair.up }
            if state.contains(pair.up) { buttonsDown[pair.down.rawValue] = nil }
        }
        sendInput(dropWhileSuspended: true) { wd in
            if state == .moved { wd.mouse(x: x, y: y, state: .moved) }
            else { wd.mouse([(x, y, .moved), (x, y, state)]) }
        }
    }

    func wheel(x: Int, y: Int, delta: Int16) {
        guard !inputBlocked else { return }
        noteActivity()
        sendInput(dropWhileSuspended: true) { wd in wd.wheel(x: x, y: y, delta: delta) }
    }

    func moveResize(id: UInt32, rect: TWIRect) {
        noteActivity()
        session.send { _, twi in
            twi.moveResize(windowId: id, rect: rect)
            twi.activate(windowId: id)
        }
    }

    func windowBecameKey(_ w: RemoteWindow) {
        if HelperManager.enabled, w.presenter == nil { HelperManager.shared.localWindowBecameKey() }
        clipboardCheck("window key")
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

    /// Window → Zoom in a helper app (docs/99 §12 phase 2): maximise on the host, or restore a maximised
    /// window; only for windows with a maximise box (D20).
    func toggleMaximize(id: UInt32) {
        guard let info = infos[id], TWIWindowControls(style: info.style).zoomable else { return }
        let maximized = info.isMaximized
        vlog("\(maximized ? "restore" : "maximise") \(String(id, radix: 16)) (Zoom)")
        session.send { _, twi in
            if maximized { twi.restore(windowId: id) } else { twi.maximize(windowId: id) }
            twi.activate(windowId: id)
        }
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
        if !session.isEstablished {
            // Never past the handshake: there is no session to log off or to call a reconnect.
            vlog("session never got past the handshake: closing")
            let session = self.session
            Task { await session.close() }
        } else if freshLogon {
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
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        clipboardSync?.channelClosed()
        setParked(false)
        vlog("session \(logName(name)) closed: \(reason)")
        if relaunchAfterClose, onRelaunch != nil {
            vlog("scaling: relaunching \(logName(name)) with the new settings")
            tearDown()
            onRelaunch?(self)
            return
        }
        if let gaveUp, gaveUp.offerRelaunch, onRelaunch != nil {
            // Keep the dimmed windows until the user picks Reconnect or Close; never relaunch silently.
            inputBlocked = true
            setDim(dimAlpha ?? Self.dimAlpha(nil))
            hud.onReconnect = { [weak self] in
                guard let self else { return }
                vlog("reconnect chosen after give-up: relaunching \(logName(self.name))")
                self.tearDown()
                self.onRelaunch?(self)
            }
            hud.onClose = { [weak self] in
                guard let self else { return }
                vlog("close chosen after give-up")
                self.tearDown()
                self.onEnded?(self)
            }
            hud.showGaveUp(name: name, message: gaveUp.message, notBefore: gaveUp.relaunchNotBefore)
            return
        }
        tearDown()
        onEnded?(self)
    }

    /// A helper app's close button or Cmd-Q while the give-up prompt shows (the session has ended, its
    /// windows are kept dimmed): the same as the prompt's Close (docs/99 §12.14).
    func closeAfterGiveUp() {
        guard ended, !windows.isEmpty, let close = hud.onClose else { return }
        hud.hide()
        close()
    }

    /// Indicator and "Disable Microphone" while this session records (docs/98 §10.3). Main thread.
    private func microphoneRecording(_ on: Bool) {
        let session = self.session, title = displayName(name), recording = on && !ended
        MainActor.assumeIsolated {
            DevicesIndicator.shared.update(self, device: .microphone, name: title, inUse: recording) {
                vlog("audio: microphone disabled by the user for this session")
                session.disableMicrophone()
            }
        }
    }

    /// Indicator and "Disable Camera" while this session uses the camera (docs/98b §10.4). Main thread.
    private func cameraInUse(_ on: Bool) {
        let session = self.session, title = displayName(name), inUse = on && !ended
        MainActor.assumeIsolated {
            DevicesIndicator.shared.update(self, device: .camera, name: title, inUse: inUse) {
                vlog("webcam: camera disabled by the user for this session")
                session.disableCamera()
            }
        }
    }

    private func tearDown() {
        hud.hide()
        microphoneRecording(false)
        cameraInUse(false)
        for id in Array(windows.keys) { remove(id) }
        if HelperManager.enabled { HelperManager.shared.sessionEnded(self) }
    }

    // MARK: Client drive mapping (docs/95 §A, D32)

    /// The shared folder (Settings; ICA_CDM=0 turns it off) as client drive M, or nil: no CTXCDM module.
    /// The default folder ~/Citrix Shared is created on first use.
    static func driveMappingConfig() -> CDMEngine.Config? {
        let settings = CDMSettings.load()
        guard settings.enabled else {
            vlog("drive mapping: off")
            return nil
        }
        do {
            let fs = try settings.makeFileSystem()
            // The folder is the user's: only whether it is the default one, and the path length.
            let folder = settings.folder.standardizedFileURL == CDMSettings.defaultFolder.standardizedFileURL ? "default folder" : "custom folder"
            vlog("drive mapping: \(settings.letter): = \(folder) (\(fs.rootPath.count) chars)\(settings.readOnly ? " (read-only)" : "")")
            return CDMEngine.Config(fileSystem: fs, letter: settings.letter, label: settings.label)
        } catch {
            vlog("drive mapping: off (\(error))")
            return nil
        }
    }

    private func setUpDriveMapping() {
        // Session queue. Names, sizes, statuses and paths relative to the shared folder only.
        session.cdm?.onEvent = { event in vlog("cdm: \(event)") }
    }

    // MARK: Printing (docs/97, PDF mode)

    /// Printing on (Settings; ICA_PRINTING overrides): announce CTXCPM so the host can create its Citrix PDF
    /// Printer for this client; nil: no module.
    static func printingConfig() -> PrinterEngine.Config? {
        let settings = PrintSettings.load()
        guard settings.enabled else {
            vlog("printing: off")
            return nil
        }
        vlog("printing: on (PDF mode; \(settings.action == .preview ? "Open in Preview" : "Print…") first)")
        return PrinterEngine.Config()
    }

    private func setUpPrinting() {
        guard let engine = session.printer else { return }
        PrintJobsController.shared.prepare()
        let source = displayName(name)
        // Session queue. Commands, tags and sizes only; the job's data goes to the main thread untouched.
        engine.onEvent = { event in
            vlog("print: \(event)")
            if case .job(let job) = event {
                DispatchQueue.main.async { PrintJobsController.shared.add(job, source: source) }
            }
        }
    }

    // MARK: Audio (docs/98, playback)

    /// Session audio on (Settings; ICA_AUDIO / ICA_AUDIO_CODECS override): announce CTXCAM; nil: no module.
    static func audioConfig() -> AudioEngine.Config? {
        let settings = AudioSettings.load()
        guard let config = settings.engineConfig else {
            vlog("audio: off")
            return nil
        }
        let opus = config.codecs.contains(.opus) ? "\(config.opusSubformats.count) Opus subformat(s) decodable" : "Opus not offered"
        let mic = config.microphone ? "microphone on request (\(config.opusEncodeSubformats.count) Opus subformat(s) encodable)" : "no microphone"
        vlog("audio: on (\(config.codecs.map(\.rawValue).sorted().joined(separator: ", ")); \(opus); \(mic))")
        return config
    }

    /// The player owns its own queue and starts the output only when the host plays something; the engine
    /// drops it at the session end (`audioStop`).
    private func setUpAudio() {
        guard let engine = session.audio else { return }
        let player = AudioPlayer()
        player.log = { vlog("audio out: \($0)") }
        engine.sink = player
        // The Mac microphone, opened only while the host records; permission is asked at the first capture OPEN.
        if engine.config.microphone { engine.captureSource = Microphone() }
        // Session queue. Commands, formats, counts and the module bytes (no audio data).
        engine.onEvent = { [weak self] event in
            vlog("audio: \(event)")
            switch event {
            case .module: DispatchQueue.main.async { self?.announcedAudio = true }
            case .microphoneDenied: DispatchQueue.main.async { DevicePermissionNote.show(.microphone) }
            case .recording(let on): DispatchQueue.main.async { self?.microphoneRecording(on) }
            default: break
            }
        }
    }

    // MARK: Webcam (docs/98b)

    /// Camera on (Settings, default off; ICA_WEBCAM overrides): announce CTXMM; nil: no module, no HDX camera.
    static func webcamConfig() -> WebcamEngine.Config? {
        let settings = WebcamSettings.load()
        guard let config = settings.engineConfig else {
            vlog("webcam: off")
            return nil
        }
        vlog("webcam: on (\(config.format); \(settings.source == .synthetic ? "synthetic test pattern" : "Mac camera, opened only between PLAY and STOP"))")
        return config
    }

    /// The camera (or, with ICA_WEBCAM_SOURCE=synthetic, the test pattern) opens only while the host plays; the
    /// permission is asked for at the first PLAY. Nothing is written to disk (no sample tap in the app).
    private func setUpWebcam() {
        guard let engine = session.webcam else { return }
        let settings = WebcamSettings.load()
        engine.source = settings.source == .synthetic ? WebcamTestPattern(format: engine.config.format)
            : Camera(deviceID: settings.deviceID, deviceName: settings.deviceName) { vlog("webcam: \($0)") }
        // Session queue. Commands, handles, sizes, counts and the module bytes (no picture data).
        engine.onEvent = { [weak self] event in
            vlog("webcam: \(event)")
            switch event {
            case .cameraDenied: DispatchQueue.main.async { DevicePermissionNote.show(.camera) }
            case .capturing(let on): DispatchQueue.main.async { self?.cameraInUse(on) }
            default: break
            }
        }
    }

    // MARK: Session sharing over CTXCTL (docs/55)

    /// CTXCTL in every seamless session (docs/55 §10 step 1); ICA_CTXCTL=0 leaves it out (diagnostics only: such a
    /// session cannot take a second app). Our own app goes along for the §5.3 commit request.
    static func controlConfig(ica: ICAFile, seamless: Bool, env: [String: String] = ProcessInfo.processInfo.environment) -> ControlEngine.Config? {
        guard seamless else { return nil }
        if env["ICA_CTXCTL"] == "0" {
            vlog("ctxctl: off (ICA_CTXCTL=0); this session cannot take further apps")
            return nil
        }
        var config = ControlEngine.Config()
        config.own = ControlLaunch(ica: ica)
        return config
    }

    private func setUpControl() {
        guard let engine = session.control else { return }
        // Session queue. Capabilities, statuses and the request bytes (app names only; a command line is shown as bytes).
        engine.onEvent = { [weak self] event in
            vlog("ctxctl: \(event)")
            if case .ready = event { DispatchQueue.main.async { self?.controlReady = true } }
        }
    }

    /// Starts `resource` inside this session over CTXCTL (docs/55 §6). Queued in the engine until the channel is ready
    /// (bounded there); `completion` runs on main. Main thread.
    func launchInSession(_ resource: String, launch: ControlLaunch, completion: @escaping (ControlEngine.LaunchResult) -> Void) {
        sharedLaunchesBusy += 1
        pendingLogoff?.cancel()
        if appWindowProcesses == nil {
            appWindowProcesses = Set(windows.values.filter(\.isApp).compactMap(\.info.processId)).union(lastAppWindows.values.compactMap(\.processId))
        }
        let entry = AwaitedLaunch(resource: resource, known: Set(apps.keys), hint: AppNaming.launchHint(initialProgram: launch.initialProgram))
        // A single-app session's one app is the launched resource only if it is that resource's own app (an
        // Explorer window may be the only app so far, docs/99 §12.15).
        if apps.count == 1, let only = apps.keys.first, appResources[only] == nil, AppNaming.isOwnApp(key: only, resource: name) {
            appResources[only] = name
        }
        awaitingApps.append(entry)
        vlog("session sharing: starting \(logName(resource)) in the session of \(appNames.map(logName).joined(separator: ", ")) over CTXCTL"
             + (controlReady ? "" : " (queued until the channel is ready)"))
        session.launchInSession(launch) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                vlog("session sharing: \(logName(resource)): \(result)")
                if result == .started {
                    // Only apps that appear from now on can be this resource (the logon console came before, live).
                    if let i = self.awaitingApps.firstIndex(where: { $0.resource == resource && !$0.ownLaunch && $0.startedAt == nil }) {
                        self.awaitingApps[i].startedAt = Date()
                    }
                    if !self.appNames.contains(resource) { self.appNames.append(resource) }
                    // The app's window follows over TWI; hold off a logoff a little longer for it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.sharedLaunchDone(resource, started: true) }
                } else {
                    self.sharedLaunchDone(resource, started: false)
                }
                completion(result)
            }
        }
    }

    /// The logon phase is over (the logon UI's judgement, or a plain reconnect): the session's own launch may now
    /// match its first real app (docs/99 §12.15); unmatched, it is dropped after `ownLaunchWindow`.
    private func endLogonPhase() {
        guard !logonPhaseOver else { return }
        logonPhaseOver = true
        guard let i = awaitingApps.firstIndex(where: \.ownLaunch) else { return }
        awaitingApps[i].startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ownLaunchWindow) { [weak self] in
            self?.awaitingApps.removeAll(where: \.ownLaunch)
        }
    }

    /// Remembers `key` → `resource` across runs once the app still has an app window after `mappingConfirmDelay`
    /// and still carries the mapping (never for a logon or system process: `AppResourceMap.remember`).
    private func confirmMappingLater(_ key: String, _ resource: String, executable: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mappingConfirmDelay) { [weak self] in
            guard let self, !self.ended, self.appResources[key] == resource, self.apps[key] != nil,
                  self.windows.values.contains(where: { $0.isApp && $0.info.appKey == key }) else { return }
            RememberedAppResources.shared.remember(key, is: resource, executable: executable)
        }
    }

    private func sharedLaunchDone(_ resource: String, started: Bool) {
        sharedLaunchesBusy = max(0, sharedLaunchesBusy - 1)
        // Failed: its app will not come. Started: its time for the first TWI app is over (an app found removed it).
        if let i = awaitingApps.firstIndex(where: { $0.resource == resource && !$0.ownLaunch }) { awaitingApps.remove(at: i) }
        guard sharedLaunchesBusy == 0, logoffDeferred, !ended else { return }
        logoffDeferred = false
        if appWindowCount == 0, !lastAppWindows.isEmpty {
            vlog("session sharing: no window of the new app arrived; deciding about the session again")
            lastAppWindowGone()
        }
    }

    // MARK: Clipboard (docs/70 §5.4, §5.6)

    private var clipboardSync: ClipboardSync?
    private var clipboardTimer: Timer?

    /// ICA_CLIPBOARD: unset/on = both ways; 0/off = no CTXCLIP module at all; to-mac / to-host = one
    /// direction only (§5.7). ICA_CLIP_IMAGES=0: text and HTML/RTF only.
    static func clipboardConfig(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ClipboardEngine.Config? {
        var config = ClipboardEngine.Config()
        switch env["ICA_CLIPBOARD"]?.lowercased() {
        case "0", "off", "no": return nil
        case "to-mac": config.macToHost = false
        case "to-host": config.hostToMac = false
        default: break
        }
        if env["ICA_CLIP_IMAGES"] == "0" { config.images = false }
        return config
    }

    private func setUpClipboard() {
        guard let engine = session.clipboard else { return vlog("clipboard: off (ICA_CLIPBOARD)") }
        // Read no image (main thread work) unless it can go to the host; read nothing if Mac → host is off.
        let sync = ClipboardSync(pasteboard: SystemPasteboard(readImages: engine.config.images && engine.config.macToHost))
        sync.readsContent = engine.config.macToHost
        let session = self.session
        sync.announce = { session.clipboardAnnounce($0) }
        sync.log = { vlog("clipboard: " + $0) }
        clipboardSync = sync
        // Session queue. Descriptions carry ids and sizes only, never contents.
        engine.onEvent = { [weak self] event in
            vlog("clipboard: \(event)")
            switch event {
            case .ready:
                DispatchQueue.main.async { self?.clipboardReady() }
            case .hostClipboard(let content, _, let echo):
                DispatchQueue.main.async { self?.clipboardSync?.hostContent(content, echo: echo) }
            default:
                break
            }
        }
    }

    /// READY: announce what the Mac holds, then poll every 500 ms while the app is active.
    private func clipboardReady() {
        guard !ended, let sync = clipboardSync else { return }
        sync.channelReady()
        guard clipboardTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard NSApp.isActive || (HelperManager.enabled && HelperManager.shared.helperIsFrontmost) else { return }
            self?.clipboardCheck("poll")
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    /// A trigger point (app active, window key, poll). Reads only `changeCount` unless it changed.
    func clipboardCheck(_ reason: String) {
        guard !ended else { return }
        clipboardSync?.check(reason)
    }

    /// Right before Cmd-V/Ctrl-V goes to the host. If a new announce was just queued, all input (keys,
    /// mouse, wheel) is held briefly so the host has the list before the paste (§5.4).
    func clipboardBeforePaste() {
        guard !ended, let sync = clipboardSync, sync.check("paste key") else { return }
        holdInput(for: pasteDelay)
    }

    // MARK: Input path

    /// ICA_CLIP_PASTE_DELAY_MS (default 50; the reference waits 5 ms, 400 ms in one Mac mode).
    private let pasteDelay = (Double(ProcessInfo.processInfo.environment["ICA_CLIP_PASTE_DELAY_MS"] ?? "") ?? 50) / 1000
    /// Input held back while a clipboard announce gets ahead of a paste; nil when nothing is held. Order
    /// is kept: everything queues behind the held input. `dropWhileSuspended`: mouse and wheel (dropped
    /// while suspended, §3.12.3) versus keys (queued, so key-ups are not lost).
    private var heldInput: [(dropWhileSuspended: Bool, body: (WinstationDriver) -> Void)]?

    /// The one way user input goes to the session.
    func sendInput(dropWhileSuspended: Bool, _ body: @escaping (WinstationDriver) -> Void) {
        if heldInput != nil { heldInput!.append((dropWhileSuspended, body)); return }
        if dropWhileSuspended { session.sendInput(body) } else { session.send { wd, _ in body(wd) } }
    }

    private func holdInput(for delay: TimeInterval) {
        guard heldInput == nil, delay > 0 else { return }
        heldInput = []
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let held = self.heldInput else { return }
            self.heldInput = nil
            // Both paths run on the session queue in call order.
            for item in held {
                if item.dropWhileSuspended { self.session.sendInput(item.body) } else { self.session.send { wd, _ in item.body(wd) } }
            }
        }
    }

    // MARK: Session reliability (docs/20 §3.12.9)

    /// Overlay alpha = (100 − dimming %) / 100; without a server cap 9 the Citrix default 80 %.
    static func dimAlpha(_ dimming: Int?) -> CGFloat { CGFloat(100 - min(100, max(0, dimming ?? 80))) / 100 }

    private func setDim(_ alpha: CGFloat?) {
        dimAlpha = alpha
        for w in windows.values { w.setDimmed(alpha) }
        for w in limbo.values { w.setDimmed(alpha) }
    }

    private func linkSuspended(_ info: CGPTransport.Suspension) {
        guard !ended else { return }
        vlog("session \(logName(name)) suspended (\(info.reason)): input off, windows kept")
        // Keys and mouse buttons held right now: their ups are queued by CGP and reach the host after
        // the resume (input that follows is dropped).
        keyboard.releaseAll()
        let ups = Array(buttonsDown.values)
        buttonsDown.removeAll()
        let (x, y) = lastMouse
        if !ups.isEmpty { session.send { wd, _ in ups.forEach { wd.mouse(x: x, y: y, state: $0) } } }
        inputBlocked = true
        setDim(Self.dimAlpha(info.dimming))
        hud.showSuspended(name: name, deadline: info.deadline)
    }

    private func linkResumed() {
        guard !ended else { return }
        vlog("session \(logName(name)) resumed: input on")
        inputBlocked = false
        setDim(nil)
        hud.hide()
        noteActivity()
    }
}

/// Small status panel for a suspended session ("Connection interrupted — reconnecting… (2:45)") and,
/// after a give-up, the message with Reconnect / Close. Borderless, non-activating and outside the
/// window cycle, so switchers keep seeing only the remote windows.
final class ReconnectHUD: NSObject {
    var onReconnect: (() -> Void)?
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let reconnectButton = NSButton(title: loc("Reconnect", "Neu verbinden"), target: nil, action: nil)
    private let closeButton = NSButton(title: loc("Close", "Schließen"), target: nil, action: nil)
    private var timer: Timer?
    private var update: (() -> Void)?
    /// Demo mode: show this many seconds instead of counting down.
    var fixedClock: TimeInterval?
    var windowNumber: Int { panel.windowNumber }
    var frame: NSRect { panel.frame }
    func setOrigin(_ origin: NSPoint) { panel.setFrameOrigin(origin) }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        label.font = .boldSystemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectPressed)
        reconnectButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(closeButton)
        buttons.addArrangedSubview(reconnectButton)
        let stack = NSStackView(views: [label, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int((fixedClock ?? seconds).rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func showSuspended(name: String, deadline: Date) {
        buttons.isHidden = true
        label.stringValue = displayName(name)
        run { [weak self] in
            guard let self else { return }
            let left = clock(deadline.timeIntervalSinceNow)
            self.detail.stringValue = loc("Connection interrupted — reconnecting… (\(left))",
                                          "Verbindung unterbrochen – neuer Verbindungsversuch… (\(left))")
        }
    }

    func showGaveUp(name: String, message: String, notBefore: Date?) {
        buttons.isHidden = false
        closeButton.isHidden = false
        reconnectButton.isHidden = false
        label.stringValue = displayName(name)
        detail.stringValue = message
        run { [weak self] in
            guard let self else { return }
            // Until the server's SR hold ends, a relaunch would not reconnect yet (docs/20 §3.12.11).
            if let notBefore, notBefore.timeIntervalSinceNow > 0 {
                self.reconnectButton.isEnabled = false
                self.reconnectButton.title = loc("Reconnect", "Neu verbinden") + " (\(clock(notBefore.timeIntervalSinceNow)))"
            } else {
                self.reconnectButton.isEnabled = true
                self.reconnectButton.title = loc("Reconnect", "Neu verbinden")
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        update = nil
        panel.orderOut(nil)
    }

    /// Applies `refresh` now and once a second, then sizes and places the panel (top centre of the
    /// main screen).
    private func run(_ refresh: @escaping () -> Void) {
        update = refresh
        refresh()
        layoutPanel()
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update?() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        panel.orderFrontRegardless()
    }

    private func layoutPanel() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        size.width = max(size.width, 360)
        panel.setContentSize(size)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12))
    }

    @objc private func reconnectPressed() {
        let action = onReconnect
        hide()
        action?()
    }

    @objc private func closePressed() {
        let action = onClose
        hide()
        action?()
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

/// NSPasteboard for the clipboard sync (main thread). Reads text, HTML, RTF and PNG/TIFF images;
/// items marked concealed or transient (password managers) read as nothing (docs/70 §5.4 [P]).
final class SystemPasteboard: ClipboardPasteboard {
    private let board = NSPasteboard.general
    private let readImages: Bool

    init(readImages: Bool) { self.readImages = readImages }
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var changeCount: Int { board.changeCount }

    func readContent() -> ClipboardContent? {
        let types = board.types ?? []
        if types.contains(Self.concealed) || types.contains(Self.transient) { return nil }
        var content = ClipboardContent()
        content.text = board.string(forType: .string)
        content.html = board.string(forType: .html)
        content.rtf = board.data(forType: .rtf)
        if readImages, let data = board.data(forType: .png) ?? board.data(forType: .tiff),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            // Pixels are rendered only if the host asks (on the session queue); CGImage is immutable.
            content.image = ClipboardImage(width: image.width, height: image.height) { Self.rgba(image) }
        }
        return content.isEmpty ? nil : content
    }

    func writeContent(_ content: ClipboardContent) -> Int {
        board.clearContents()
        let item = NSPasteboardItem()
        if let text = content.text { item.setString(text, forType: .string) }
        if let html = content.html { item.setString(html, forType: .html) }
        if let rtf = content.rtf { item.setData(rtf, forType: .rtf) }
        if let image = content.image, let cg = Self.cgImage(image) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        board.writeObjects([item])
        return board.changeCount
    }

    /// RGBA8, not premultiplied, top-down (what ClipboardDIB expects).
    static func rgba(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }
        return Data(pixels)
    }

    static func cgImage(_ image: ClipboardImage) -> CGImage? {
        guard let rgba = image.rgba(), let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
