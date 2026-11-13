import AppHostKit
import AppKit
import ICAKit
import ImageIO

/// Per-app Dock identity, phase 1 (docs/99 §12): with ICA_HELPER_APPS=1 each remote app (TWI app key) gets
/// its own generated helper app (AppHostKit) with its own Dock tile, Cmd-Tab entry, name and icon, and the
/// helper owns that app's windows, so switchers, Mission Control and AX see them under the right process.
///
/// Split of work: this process keeps the session, the window model and every `RemoteWindow` with its
/// logic (geometry, scaling maps, D20 commits, TWI requests); a helper-shown RemoteWindow keeps a hidden
/// NSWindow that is never ordered in, and this class mirrors its state into the helper as a
/// `HelperWindowSpec`. The helper renders the shared IOSurface with the same crop and sends raw input
/// back; the mapping to session pixels and scancodes stays here (`KeyboardTranslator`, `ScalingLayout`).
///
/// Phase 2 (§12.4): popups, menus and tooltips of an app go to its helper once it runs; the helper runs D20
/// caption drags and edge resizes locally and reports one `gestureEnded`, committed here through the same
/// `TWILocalGesture` path; pointer shapes go to every helper of the session; each helper has a menu bar
/// whose Edit, Zoom and ICA items act here (`onCommand`).
///
/// Limits: one session per helper (another session's windows of the same app stay here); a helper that
/// fails or crashes hands its windows back to this process for the rest of the run; name and icon are fixed
/// at launch; this process keeps its own Dock tile. Main thread only, like the session controller.
final class HelperManager: NSObject, RemotePresenter {
    static let shared = HelperManager()
    /// Off by default until GA: the single-process model stays unchanged (docs/99 §12.2).
    static let enabled = ProcessInfo.processInfo.environment["ICA_HELPER_APPS"] == "1"
    /// From the first window to the helper's check-in: bundle generation (copy, re-sign) + LaunchServices.
    static let checkInTimeout: TimeInterval = 5
    /// After an app's last window: splash-then-main-window apps would make the Dock tile flicker.
    static let quitGrace: TimeInterval = 3
    static let yieldTimeout: TimeInterval = 0.3
    /// A helper that leaves this many control messages unread (200 ms each), or this many frames in a row
    /// (its queue full, ~3 s at 30 fps), is taken for hung: its windows come back here.
    static let maxTimeouts = 2
    static let maxFrameDrops = 90
    /// ICA_HELPER_VERIFY=0: skip the code identity check at check-in (diagnosis only).
    static let verifyCode = ProcessInfo.processInfo.environment["ICA_HELPER_VERIFY"] != "0"

    private final class Helper {
        enum State { case preparing, launching, ready, failed }
        let key: String
        let label: HelperLabel
        let token = HelperLaunch.makeToken()
        /// The session whose surface the helper shows (phase 1: one per helper).
        weak var controller: SessionController?
        var state = State.preparing
        var pid: pid_t = 0
        /// Send right to the helper's receive port.
        var port = mach_port_t(MACH_PORT_NULL)
        /// Our receive port for this helper only: the sender of a message is known by its port.
        var receiver: MachReceiver?
        var exitWatch: DispatchSourceProcess?
        var quitWork: DispatchWorkItem?
        var quitting = false
        /// Window to activate as soon as the helper has checked in.
        var pendingActivation: UInt32?
        var lastStatsLog = Date.distantPast
        /// The generated bundle and its cdhash, recorded at generation (docs/99 §12.17).
        var bundleURL: URL?
        var cdhash: String?
        /// The pid LaunchServices reported for our launch (nil until its completion handler ran).
        var launchedPid: pid_t?
        /// Control messages that timed out in a row, and frames dropped in a row (the helper's queue is full).
        var timeouts = 0
        var frameDrops = 0
        /// The window that last became key in the helper (activated again after a cancelled ICA menu prompt).
        var lastFocus: UInt32?

        init(key: String, label: HelperLabel, controller: SessionController) {
            self.key = key
            self.label = label
            self.controller = controller
        }

        var logLabel: String { logName(label.name) }
    }

    private struct Binding {
        weak var remote: RemoteWindow?
        let helperKey: String
        /// Last spec sent (changes only go out when it differs).
        var sent: HelperWindowSpec?
        /// `show` was called: the helper knows the window.
        var presented = false
        var isKey = false
        var scroll: CGFloat = 0
    }

    private var broker: MachReceiver?
    private let brokerName = HelperLaunch.brokerName(hostPid: getpid())
    private var helpers: [String: Helper] = [:]
    /// Helpers told to quit, until their process is gone (LaunchServices would hand a new launch of the
    /// same bundle to the old instance).
    private var exiting: [String: Helper] = [:]
    private var waitingLaunch: [String: (Helper, URL)] = [:]
    private var handles = HelperHandles<ObjectIdentifier>()
    private var bindings: [UInt32: Binding] = [:]
    private var pendingHandover: (serial: Int, target: pid_t, work: () -> Void)?
    private var handoverSerial = 0
    /// The helper window that last became key (its keys are released when another window takes focus:
    /// `focus` and `resignedKey` of two helpers arrive on two ports, in no fixed order).
    private var keyHandle: UInt32?
    private var loggedNoTemplate = false
    private var loggedOtherSession: Set<String> = []
    /// Bundle generation (copy, codesign) off the main thread, one at a time.
    private let bundleQueue = DispatchQueue(label: "ica.viewer.helper-bundles", qos: .userInitiated)
    /// The last pointer shape of each session, encoded for the helpers (sent again at a check-in).
    private var cursors: [ObjectIdentifier: HelperCursor] = [:]
    private var loggedLargeCursor = false
    /// An ICA menu item of a helper (the helper has yielded activation to this process): the app delegate
    /// shows the window or asks; `cancelled` gives activation back to the helper (a prompt was cancelled).
    var onCommand: ((_ command: HelperCommand, _ controller: SessionController?, _ cancelled: @escaping () -> Void) -> Void)?

    // MARK: Routing (SessionController)

    /// A new RemoteWindow: if a helper is to show it, `presenter` is set before its first `show`.
    func claim(_ remote: RemoteWindow) {
        guard let controller = remote.controller else { return }
        guard remote.isApp else { return claimPopup(remote, controller) }
        guard let key = HelperRouting.helperKey(appKey: remote.info.appKey, isAppWindow: true) else { return }
        let helper: Helper
        if let existing = helpers[key] {
            guard existing.state != .failed else { return }
            guard existing.controller === controller else {
                if loggedOtherSession.insert(key).inserted {
                    vlog("helper apps: \(existing.logLabel) already runs for another session; this session's windows stay here")
                }
                return
            }
            helper = existing
        } else {
            guard let created = start(key: key, remote: remote, controller: controller) else { return }
            helper = created
        }
        helper.quitWork?.cancel()
        helper.quitWork = nil
        let handle = handles.handle(for: ObjectIdentifier(remote))
        bindings[handle] = Binding(remote: remote, helperKey: key)
        remote.window.isExcludedFromWindowsMenu = true
        remote.presenter = self
    }

    /// Phase 2: a popup, menu or tooltip is shown by its app's helper when that runs for this session and has
    /// checked in; otherwise here, as before (a popup never starts a helper).
    private func claimPopup(_ remote: RemoteWindow, _ controller: SessionController) {
        guard let key = popupKey(remote, controller) else { return }
        let handle = handles.handle(for: ObjectIdentifier(remote))
        bindings[handle] = Binding(remote: remote, helperKey: key)
        remote.window.isExcludedFromWindowsMenu = true
        remote.presenter = self
    }

    private func popupKey(_ remote: RemoteWindow, _ controller: SessionController?) -> String? {
        let helper = helpers[remote.info.appKey]
        let running = helper.map { $0.state == .ready && $0.controller === controller && !$0.quitting && hasWindows($0) } ?? false
        return HelperRouting.popupHelperKey(appKey: remote.info.appKey, helperRunning: running)
    }

    /// The window's app key changed after it was created (process info arrived later, e.g. `exe:` →
    /// `app:`): it moves into the helper of its new key; one whose new key has no helper (or whose helper
    /// cannot take it) is shown here.
    func appKeyChanged(_ w: RemoteWindow) {
        let wanted = w.isApp ? HelperRouting.helperKey(appKey: w.info.appKey, isAppWindow: true) : popupKey(w, w.controller)
        let handle = handles.existing(for: ObjectIdentifier(w))
        let current = handle.flatMap { bindings[$0]?.helperKey }
        guard wanted != current else { return }
        if let current {
            let wasKey = handle.flatMap { bindings[$0]?.isKey } ?? false
            vlog("helper apps: window \(String(w.info.id, radix: 16)) changed app \(logName(current)) → \(wanted.map(logName) ?? "none")")
            dismiss(w)                  // presenter stays set until the window has a new home
            if wanted != nil {
                w.presenter = nil
                claim(w)
                if w.presenter != nil { return present(w, activate: wasKey) }
                w.presenter = self
            }
            w.adoptLocally(activate: wasKey)
        } else if wanted != nil, w.presenter == nil, !w.window.isMiniaturized {
            let wasKey = w.window.isKeyWindow
            claim(w)
            guard w.presenter != nil else { return }
            w.window.orderOut(nil)
            present(w, activate: wasKey)
        }
    }

    /// A window of this process became key: keys a helper window held are released now (its
    /// `resignedKey` may come later, after keys typed here).
    func localWindowBecameKey() {
        guard let old = keyHandle else { return }
        keyHandle = nil
        bindings[old]?.remote?.controller?.keyboard.releaseAll()
    }

    var helperIsFrontmost: Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return helpers.values.contains { $0.state == .ready && $0.pid == pid }
    }

    // MARK: RemotePresenter

    func present(_ w: RemoteWindow, activate: Bool) {
        guard let (handle, helper) = lookup(w) else { return }
        bindings[handle]?.presented = true
        if helper.state == .ready { sendSpec(handle, w, added: true) }
        if activate { requestActivation(handle) }
    }

    func update(_ w: RemoteWindow) {
        guard let (handle, helper) = lookup(w), helper.state == .ready, bindings[handle]?.presented == true else { return }
        sendSpec(handle, w, added: false)
    }

    func gestureDone(_ w: RemoteWindow) {
        guard let (handle, helper) = lookup(w), helper.state == .ready else { return }
        send(helper, .gestureDone(windowId: handle))
    }

    func dismiss(_ w: RemoteWindow) {
        guard let handle = handles.remove(ObjectIdentifier(w)), let binding = bindings.removeValue(forKey: handle),
              let helper = helpers[binding.helperKey] else { return }
        if helper.pendingActivation == handle { helper.pendingActivation = nil }
        if helper.state == .ready { send(helper, .windowRemoved(id: handle)) }
        if !hasWindows(helper) { scheduleQuit(helper, immediately: helper.controller?.ended ?? true) }
    }

    // MARK: Frames and surface (SessionController)

    /// A Thinwire frame was presented; `windows` are the helper-shown ones it touches.
    func framePresented(_ windows: [RemoteWindow], rects: [CGRect]) {
        var crops: [String: [WireRect]] = [:]
        for w in windows {
            guard let handle = handles.existing(for: ObjectIdentifier(w)), let b = bindings[handle], let sent = b.sent else { continue }
            crops[b.helperKey, default: []].append(sent.rect)
        }
        let dirty = rects.map(HelperRouting.wireRect)
        for (key, windowCrops) in crops {
            guard let helper = helpers[key], helper.state == .ready, let surface = helper.controller?.surface else { continue }
            var rects = HelperRouting.dirtyRects(dirty, crops: windowCrops)
            if rects.count > 64 { rects = windowCrops }       // the crops cover it; keeps the message small
            guard !rects.isEmpty else { continue }
            // Timeout 0: a busy or hung helper drops a frame rather than stalling the session's main thread.
            let kr = MachChannel.send(HostMessage.frame(seed: IOSurfaceGetSeed(surface), dirty: rects, sentNs: uptimeNanoseconds()),
                                      to: helper.port, timeoutMs: 0)
            noteSend(helper, kr, frame: true)
        }
    }

    /// The session's pointer shape changed (docs/99 §12 phase 2): to every ready helper of the session, as
    /// PNG; each helper window shows it at its own k (as `SessionController.buildCursor`). Encoded only when
    /// a helper is ready (a check-in encodes the current shape itself).
    func pointerChanged(_ controller: SessionController) {
        cursors[ObjectIdentifier(controller)] = nil
        let ready = helpers.values.filter { $0.controller === controller && $0.state == .ready }
        guard !ready.isEmpty, let cursor = cursor(for: controller) else { return }
        for helper in ready { send(helper, .cursor(cursor)) }
    }

    /// The encoded current shape (cached until the next change): downscaled by halves until the message fits
    /// the channel (drawn at the same point size, only less sharp), else the arrow, never a stale shape.
    private func cursor(for controller: SessionController) -> HelperCursor? {
        if let cached = cursors[ObjectIdentifier(controller)] { return cached }
        guard let shape = controller.pointerShape else { return nil }
        var cursor = HelperCursor.hidden
        if let image = shape.image {
            cursor = .systemArrow
            var bitmap: CGImage? = image
            var halvings = 0
            for _ in 0..<4 {
                guard let current = bitmap, let png = Self.png(current) else { break }
                let candidate = HelperCursor(png: png, pixelWidth: image.width, pixelHeight: image.height,
                                             hotX: Double(shape.hotspot.x), hotY: Double(shape.hotspot.y))
                if let size = try? WireCoding.encode(HostMessage.cursor(candidate)).count, size <= MachChannel.maxPayload {
                    cursor = candidate
                    break
                }
                bitmap = Self.halved(current)
                halvings += 1
            }
            if cursor.arrow == true || halvings > 0, !loggedLargeCursor {
                loggedLargeCursor = true
                vlog("helper apps: pointer shape \(image.width)x\(image.height) too large for the channel: \(cursor.arrow == true ? "arrow" : "downscaled")")
            }
        }
        cursors[ObjectIdentifier(controller)] = cursor
        return cursor
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func halved(_ image: CGImage) -> CGImage? {
        let w = max(1, image.width / 2), h = max(1, image.height / 2)
        guard w < image.width || h < image.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Thinwire INIT: a new front surface (also after a resize).
    func surfaceChanged(_ controller: SessionController) {
        for helper in helpers.values where helper.controller === controller && helper.state == .ready { sendSurface(helper) }
    }

    // MARK: Activation (docs/99 §4, §12.5)

    /// The host put `w` in the foreground. A helper-shown window: its helper becomes the active app, if
    /// one of our processes is in front. A window of this process while a helper is in front: back here.
    func hostActivated(_ w: RemoteWindow) {
        if w.presenter != nil, let (handle, helper) = lookup(w) {
            guard !w.info.isMinimized else { return }
            if helper.state == .ready, bindings[handle]?.isKey == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.pid { return }
            requestActivation(handle)
        } else if w.presenter == nil, !w.window.isMiniaturized, !w.window.isKeyWindow {
            handOver(to: getpid()) { w.window.makeKeyAndOrderFront(nil) }
        }
    }

    private func requestActivation(_ handle: UInt32) {
        guard let b = bindings[handle], let helper = helpers[b.helperKey] else { return }
        guard helper.state == .ready else { helper.pendingActivation = handle; return }
        handOver(to: helper.pid) { [weak self, weak helper] in
            guard let self, let helper, helper.state == .ready else { return }
            self.send(helper, .activate(windowId: handle))
        }
    }

    /// Cooperative activation: whoever of ours is in front yields to `target`, then `work` activates it.
    private func handOver(to target: pid_t, work: @escaping () -> Void) {
        let host = getpid()
        let ready = Set(helpers.values.filter { $0.state == .ready }.map(\.pid))
        guard let steps = ActivationHandover.plan(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                  host: host, helpers: ready, target: target) else {
            return vlog("helper apps: another app is in front; activation left alone")
        }
        for step in steps {
            switch step {
            case .hostYields(let pid):
                if let app = NSRunningApplication(processIdentifier: pid) { NSApp.yieldActivation(to: app) }
            case .helperYields(let from, let to):
                guard let yielding = helpers.values.first(where: { $0.pid == from && $0.state == .ready }) else { continue }
                handoverSerial += 1
                let serial = handoverSerial
                pendingHandover = (serial, to, { if to == host { NSApp.activate() }; work() })
                send(yielding, .yieldActivation(toPid: to))
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.yieldTimeout) { [weak self] in
                    guard let self, let pending = self.pendingHandover, pending.serial == serial else { return }
                    self.pendingHandover = nil
                    vlog("helper apps: no yield acknowledgement in \(Int(Self.yieldTimeout * 1000)) ms; activating anyway")
                    pending.work()
                }
                return      // the rest runs on `yielded`
            case .activate(let pid):
                if pid == host { NSApp.activate() }
                work()
            }
        }
    }

    // MARK: Lifecycle

    /// The session ended: helpers without windows go now (the last windows were just removed).
    func sessionEnded(_ controller: SessionController) {
        cursors[ObjectIdentifier(controller)] = nil
        for helper in Array(helpers.values) where helper.controller === controller && !hasWindows(helper) {
            helper.quitWork?.cancel()
            quit(helper)
        }
    }

    /// The main process quits.
    func quitAll() {
        for helper in Array(helpers.values) { quit(helper) }
    }

    private func start(key: String, remote: RemoteWindow, controller: SessionController) -> Helper? {
        guard let template = Self.templateURL() else {
            if !loggedNoTemplate {
                loggedNoTemplate = true
                vlog("helper apps: no template ICAViewerHelper.app (ICA_HELPER_TEMPLATE, Contents/Helpers, .build); windows stay here")
            }
            return nil
        }
        guard startBroker() else { return nil }
        let source = controller.dockSource(for: remote)
        let identity = source.map { DockIcon.shared.identity(for: $0) }
        let name = displayName(identity?.name ?? source?.names.first ?? "Remote App")
        let label = HelperLabel(key: key, name: name)
        let helper = Helper(key: key, label: label, controller: controller)
        helpers[key] = helper
        loggedOtherSession.remove(key)
        let icon = identity?.icon.flatMap { IconCanvas.render($0) }
        let env = ProcessInfo.processInfo.environment
        let generator = HelperBundleGenerator(template: template, appsDirectory: HelperBundleGenerator.defaultAppsDirectory,
                                              signIdentity: env["ICA_HELPER_SIGN_IDENTITY"] ?? "-")
        vlog("helper apps: preparing \(helper.logLabel) (\(icon == nil ? "generic" : "app") icon)")
        bundleQueue.async { [weak self] in
            let result = Result { () throws -> Generated in
                let (url, outcome) = try generator.generate(label, icon: icon)
                guard let cdhash = CodeIdentity.cdhash(bundle: url) else { throw HelperBundleError.codesign("no cdhash") }
                return Generated(url: url, outcome: outcome, cdhash: cdhash)
            }
            DispatchQueue.main.async { [weak self] in self?.generated(helper, result) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkInTimeout) { [weak self, weak helper] in
            guard let self, let helper, helper.state == .preparing || helper.state == .launching else { return }
            self.fail(helper, "no check-in within \(Int(Self.checkInTimeout)) s")
        }
        return helper
    }

    /// Template helper: ICA_HELPER_TEMPLATE, else inside this app (release, phase 3), else the
    /// development build of scripts/bundle-helper.sh.
    static func templateURL() -> URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["ICA_HELPER_TEMPLATE"] { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ICAViewerHelper.app"))
        candidates.append(Paths.root.appendingPathComponent(".build/ICAViewerHelper.app"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }
    }

    private struct Generated { var url: URL; var outcome: HelperBundleGenerator.Outcome; var cdhash: String }

    private func generated(_ helper: Helper, _ result: Result<Generated, Error>) {
        guard helper.state == .preparing else { return }
        switch result {
        case .failure(let error):
            // Paths and codesign output name the app: keep the name scrubbable.
            fail(helper, "bundle: " + String(describing: error).replacingOccurrences(of: helper.label.name, with: helper.logLabel))
        case .success(let generated):
            vlog("helper apps: \(helper.logLabel) bundle \(generated.outcome), cdhash \(generated.cdhash.prefix(12))…")
            helper.bundleURL = generated.url
            helper.cdhash = generated.cdhash
            launch(helper, generated.url)
        }
    }

    private func launch(_ helper: Helper, _ url: URL) {
        helper.state = .launching
        if exiting[helper.key] != nil {
            waitingLaunch[helper.key] = (helper, url)      // launched once the old instance is gone
            return
        }
        // The bundle must still be the code we generated (nothing swapped or edited it since).
        guard let cdhash = CodeIdentity.cdhash(bundle: url), cdhash == helper.cdhash else {
            return fail(helper, "bundle changed since it was generated")
        }
        let launch = HelperLaunch(broker: brokerName, token: helper.token, hostPid: getpid())
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = launch.arguments
        config.environment = launch.environment         // the token never goes into argv
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            let pid = app?.processIdentifier
            let text = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let text, helper.state == .launching {
                    return self.fail(helper, "launch failed: " + text.replacingOccurrences(of: helper.label.name, with: helper.logLabel))
                }
                helper.launchedPid = pid
                if helper.state == .ready, let pid, pid != helper.pid {
                    self.fail(helper, "checked in as pid \(helper.pid), but LaunchServices started pid \(pid)")
                }
            }
        }
    }

    private func startBroker() -> Bool {
        if broker != nil { return true }
        guard let port = MachChannel.checkIn(brokerName) else {
            vlog("helper apps: bootstrap_check_in failed; windows stay here")
            return false
        }
        let receiver = MachReceiver(port: port)
        receiver.start(queue: .main) { [weak self] in self?.brokerReceived($0) }
        broker = receiver
        return true
    }

    /// The broker port only takes check-ins; everything else comes on the helper's own port.
    private func brokerReceived(_ received: MachReceived) {
        guard case .message(let data, let port) = received else { return }
        guard let message = try? WireCoding.decode(HelperMessage.self, from: data), case .checkIn(let token, let pid) = message else {
            MachChannel.deallocate(port)
            return
        }
        checkIn(token: token, pid: pid, port: port, sender: broker?.sender)
    }

    private func checkIn(token: String, pid: pid_t, port: mach_port_t, sender: audit_token_t?) {
        guard port != MACH_PORT_NULL else { return }
        guard let helper = helpers.values.first(where: { $0.token == token }),
              helper.state == .preparing || helper.state == .launching else {
            // Unknown, or too late (its windows went back to this process): it must not linger. Timeout 0:
            // never wait on a port we do not know.
            vlog("helper apps: check-in from pid \(pid) not expected; sending quit")
            MachChannel.send(HostMessage.quit, to: port, timeoutMs: 0)
            MachChannel.deallocate(port)
            return
        }
        if let refusal = verify(helper, pid: pid, sender: sender) {
            // Not the process we launched (or not its code): ignore it; the real helper may still come.
            vlog("helper apps: \(helper.logLabel): check-in from pid \(pid) refused (\(refusal))")
            MachChannel.send(HostMessage.quit, to: port, timeoutMs: 0)
            MachChannel.deallocate(port)
            return
        }
        guard let own = MachChannel.allocateReceivePort() else {
            MachChannel.deallocate(port)
            return fail(helper, "cannot allocate a port")
        }
        helper.port = port
        helper.pid = pid
        helper.state = .ready
        let receiver = MachReceiver(port: own)
        receiver.start(queue: .main) { [weak self, weak helper] received in
            guard let self, let helper else { return }
            self.received(received, from: helper)
        }
        let deadNameArmed = receiver.notifyDeadName(of: port) == KERN_SUCCESS
        helper.receiver = receiver
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self, weak helper] in
            guard let self, let helper else { return }
            self.helperGone(helper, "process exited")
        }
        watch.resume()
        helper.exitWatch = watch
        // Died before both watches were armed: neither would ever fire.
        if !deadNameArmed || (kill(pid, 0) != 0 && errno == ESRCH) { return helperGone(helper, "gone during check-in") }
        vlog("helper apps: \(helper.logLabel) checked in (pid \(pid))")
        // hello carries a send right to our per-helper port: the helper sends everything else there.
        let kr = MachChannel.send(HostMessage.hello(appName: helper.label.name), to: port, port: own,
                                  disposition: mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        noteSend(helper, kr, frame: false)
        guard helper.state == .ready else { return }
        sendSurface(helper)
        if let controller = helper.controller, let cursor = cursor(for: controller) { send(helper, .cursor(cursor)) }
        for (handle, binding) in bindings.sorted(by: { $0.key < $1.key })
        where binding.helperKey == helper.key && binding.presented {
            if let remote = binding.remote { sendSpec(handle, remote, added: true) }
        }
        if let pending = helper.pendingActivation {
            helper.pendingActivation = nil
            requestActivation(pending)
        }
        if !hasWindows(helper) { scheduleQuit(helper, immediately: helper.controller?.ended ?? true) }
    }

    /// The check-in must come from the process LaunchServices started for this helper, running the code
    /// we generated (docs/99 §12.17). nil = accepted, else why not.
    private func verify(_ helper: Helper, pid: pid_t, sender: audit_token_t?) -> String? {
        guard let sender else { return "no audit token" }
        let senderPid = pid_t(bitPattern: sender.val.5)
        guard senderPid == pid else { return "claims pid \(pid), sent by pid \(senderPid)" }
        if let launched = helper.launchedPid {
            guard launched == pid else { return "LaunchServices started pid \(launched)" }
        } else {
            // LaunchServices has not answered yet: the process must at least run our bundle.
            let running = NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
            guard let expected = helper.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path, running == expected else {
                return "not our bundle"
            }
        }
        guard Self.verifyCode else { return nil }
        guard let cdhash = helper.cdhash else { return "no recorded cdhash" }
        let status = CodeIdentity.check(auditToken: sender, cdhash: cdhash)
        return status == errSecSuccess ? nil : "code identity check failed (OSStatus \(status))"
    }

    private func received(_ received: MachReceived, from helper: Helper) {
        switch received {
        case .deadName(let name):
            helperGone(helper, "port died")
            MachChannel.deallocate(name)        // the notification's own reference to the dead name
        case .message(let data, let port):
            MachChannel.deallocate(port)
            guard let message = try? WireCoding.decode(HelperMessage.self, from: data) else { return }
            handle(message, from: helper)
        }
    }

    private func handle(_ message: HelperMessage, from helper: Helper) {
        func remote(_ handle: UInt32) -> (RemoteWindow, SessionController)? {
            guard let b = bindings[handle], b.helperKey == helper.key, let w = b.remote, let c = w.controller, !c.ended else { return nil }
            return (w, c)
        }
        switch message {
        case .key(let id, let phase, let code, let chars, let plain, let modifiers, let isRepeat, _):
            guard let (_, c) = remote(id), !c.inputBlocked else { return }
            let input = KeyInput(keyCode: code, modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers),
                                 characters: phase == .flags || chars.isEmpty ? nil : chars,
                                 charactersIgnoringModifiers: phase == .flags || plain.isEmpty ? nil : plain, isARepeat: isRepeat)
            switch phase {
            case .down: c.keyboard.keyDown(input)
            case .up: c.keyboard.keyUp(input)
            case .flags: c.keyboard.flagsChanged(input)
            }
        case .mouse(let id, let kind, let button, let x, let y, let sx, let sy, _, let modifiers, _):
            guard let (w, _) = remote(id), let (view, screen) = Self.validPoints(x, y, sx, sy) else { return }
            w.helperMouse(kind, button: button, view: view, screen: screen, modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
        case .scroll(let id, _, let dy, let precise, let x, let y, let sx, let sy, _):
            guard let (w, c) = remote(id), var b = bindings[id], dy.isFinite, let (view, screen) = Self.validPoints(x, y, sx, sy) else { return }
            // As SessionView.scrollWheel: Windows wants 120 per notch, positive = away from the user.
            b.scroll = min(max(b.scroll + (precise ? CGFloat(dy) * 4 : CGFloat(dy) * 120), -12_000), 12_000)
            defer { bindings[id] = b }
            guard abs(b.scroll) >= 1 else { return }
            let amount = Int16(clamping: Int(b.scroll))
            b.scroll -= CGFloat(amount)
            let s = w.helperSessionPoint(view: view, screen: screen)
            c.wheel(x: s.x, y: s.y, delta: amount)
        case .focus(let id):
            for (handle, b) in bindings where b.helperKey == helper.key { bindings[handle]?.isKey = handle == id }
            // Another helper's window had the keys and its resignedKey may still be on its way: release
            // now, before this window's keys (they follow on this port) arrive.
            if let old = keyHandle, old != id { bindings[old]?.remote?.controller?.keyboard.releaseAll() }
            keyHandle = id
            helper.lastFocus = id
            guard let (w, c) = remote(id) else { return }
            c.windowBecameKey(w)
        case .resignedKey(let id):
            bindings[id]?.isKey = false
            // Late (another window took the keys since): its keys were released then.
            guard keyHandle == id else { return }
            keyHandle = nil
            remote(id)?.1.keyboard.releaseAll()
        case .appActive(let active):
            if active, let c = helper.controller, !c.ended { c.clipboardCheck("helper active") }
        case .close(let id):
            if let c = bindings[id]?.remote?.controller, c.ended { return c.closeAfterGiveUp() }
            guard let (w, c) = remote(id) else { return }
            c.requestClose(id: w.info.id)
        case .minimized(let id, let minimized):
            guard let (w, c) = remote(id) else { return }
            if minimized { c.minimize(id: w.info.id) } else { c.restore(id: w.info.id) }
        case .moved(let id, let frame):
            guard let content = HelperRouting.validFrame(frame, limit: Self.screensUnion()) else { return }
            remote(id)?.0.helperMoved(content: content)
        case .frameStats(let count, let mean, let p95, let max):
            // The latency budget (§12.18): logged every 30 s at most.
            guard Date().timeIntervalSince(helper.lastStatsLog) >= 30 else { return }
            helper.lastStatsLog = Date()
            vlog(String(format: "helper apps: %@ frame latency over %d frames: mean %.0f µs, p95 %.0f µs, max %.0f µs",
                        helper.logLabel, count, mean, p95, max))
        case .yielded(let pid, _):
            if let pending = pendingHandover, pending.target == pid {
                pendingHandover = nil
                pending.work()
            }
        case .activation(let text):
            vlog("helper apps: \(helper.logLabel): \(text)")
        case .appQuit:
            // Cmd-Q in a helper quits that remote app: TWI close for each of its windows (D63, §12.12).
            if let c = helper.controller, c.ended { return c.closeAfterGiveUp() }
            vlog("helper apps: \(helper.logLabel) quit by the user: closing its windows")
            for (handle, b) in bindings where b.helperKey == helper.key {
                if let (w, c) = remote(handle) { c.requestClose(id: w.info.id) }
            }
        case .gestureEnded(let id, let frame):
            // One TWI move/resize through the D20 path; the helper stays frozen until gestureDone.
            guard let (w, _) = remote(id), let content = HelperRouting.validFrame(frame, limit: Self.screensUnion()) else {
                return send(helper, .gestureDone(windowId: id))
            }
            w.helperGestureEnded(content: content)
        case .edit(let id, let command):
            guard let (_, c) = remote(id), !c.inputBlocked else { return }
            vlog("helper apps: \(helper.logLabel): Edit menu \(command.rawValue) → remote Ctrl-\(command.letter.uppercased())")
            c.keyboard.menuShortcut(command.letter)
        case .zoom(let id):
            guard let (w, c) = remote(id) else { return }
            c.toggleMaximize(id: w.info.id)
        case .command(let command):
            vlog("helper apps: \(helper.logLabel): ICA menu \(command.rawValue)")
            guard let onCommand else { return reactivate(helper) }
            onCommand(command, helper.controller) { [weak self, weak helper] in
                guard let self, let helper else { return }
                self.reactivate(helper)
            }
        case .checkIn, .probeResult:
            break
        }
    }

    /// Every screen in global points: frames and points from helpers are clamped to it before the integer
    /// session maths (a helper is our code, but a bug there must not trap this process).
    static func screensUnion() -> CGRect {
        NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    private static func validPoints(_ x: Double, _ y: Double, _ sx: Double, _ sy: Double) -> (CGPoint, CGPoint)? {
        let screens = screensUnion()
        guard let view = HelperRouting.validPoint(x: x, y: y, limit: CGRect(origin: .zero, size: screens.size)),
              let screen = HelperRouting.validPoint(x: sx, y: sy, limit: screens) else { return nil }
        return (view, screen)
    }

    /// Gives activation back to a helper after its ICA menu item was cancelled here: its last key window.
    private func reactivate(_ helper: Helper) {
        guard helper.state == .ready else { return }
        let mine = bindings.filter { $0.value.helperKey == helper.key && $0.value.remote?.isApp == true }
        guard let handle = helper.lastFocus.flatMap({ mine[$0] != nil ? $0 : nil }) ?? mine.keys.sorted().first else { return }
        requestActivation(handle)
    }

    private func helperGone(_ helper: Helper, _ reason: String) {
        helper.exitWatch?.cancel()
        helper.exitWatch = nil
        helper.receiver?.cancel()
        helper.receiver = nil
        MachChannel.deallocate(helper.port)
        helper.port = mach_port_t(MACH_PORT_NULL)
        if helper.quitting {
            if exiting[helper.key] === helper { exiting[helper.key] = nil }
            helper.quitting = false
            helper.state = .failed      // done; never used again
            if let (next, url) = waitingLaunch.removeValue(forKey: helper.key), next.state == .launching { launch(next, url) }
            return
        }
        guard helper.state == .ready else { return }
        fail(helper, reason)
    }

    /// The helper is unusable (no bundle, no launch, no check-in, crash): its windows come back here for
    /// the rest of the run (relaunching once is phase 3).
    private func fail(_ helper: Helper, _ reason: String) {
        guard helper.state != .failed else { return }
        vlog("helper apps: \(helper.logLabel): \(reason); its windows stay in this process")
        if helper.state == .ready, helper.port != MACH_PORT_NULL { MachChannel.send(HostMessage.quit, to: helper.port, timeoutMs: 0) }
        helper.state = .failed
        helper.exitWatch?.cancel()
        helper.exitWatch = nil
        helper.receiver?.cancel()
        helper.receiver = nil
        MachChannel.deallocate(helper.port)
        helper.port = mach_port_t(MACH_PORT_NULL)
        if waitingLaunch[helper.key]?.0 === helper { waitingLaunch[helper.key] = nil }
        let pending = helper.pendingActivation
        helper.pendingActivation = nil
        for (handle, binding) in bindings.sorted(by: { $0.key < $1.key }) where binding.helperKey == helper.key {
            bindings[handle] = nil
            guard let remote = binding.remote else { continue }
            handles.remove(ObjectIdentifier(remote))
            remote.adoptLocally(activate: pending == handle || binding.isKey)
        }
    }

    private func scheduleQuit(_ helper: Helper, immediately: Bool) {
        helper.quitWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak helper] in
            guard let self, let helper, !self.hasWindows(helper) else { return }
            self.quit(helper)
        }
        helper.quitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : Self.quitGrace), execute: work)
    }

    private func quit(_ helper: Helper) {
        guard !helper.quitting else { return }
        if helpers[helper.key] === helper { helpers[helper.key] = nil }
        switch helper.state {
        case .ready:
            vlog("helper apps: \(helper.logLabel): no windows left; quitting it")
            handBackPopups(helper)
            helper.quitting = true
            exiting[helper.key] = helper
            send(helper, .quit)
        case .preparing, .launching:
            helper.state = .failed      // a late check-in gets quit
        case .failed:
            break
        }
    }

    // MARK: Messages

    private func lookup(_ w: RemoteWindow) -> (UInt32, Helper)? {
        guard let handle = handles.existing(for: ObjectIdentifier(w)), let b = bindings[handle], let helper = helpers[b.helperKey] else { return nil }
        return (handle, helper)
    }

    /// App windows only: popups never keep a helper (its own windowless rule counts only app windows).
    private func hasWindows(_ helper: Helper) -> Bool {
        HelperRouting.popupsToHandBack(windowsOf(helper)) == nil
    }

    private func windowsOf(_ helper: Helper) -> [(id: UInt32, isApp: Bool)] {
        bindings.compactMap { handle, b in
            guard b.helperKey == helper.key, let remote = b.remote else { return nil }
            return (handle, remote.isApp)
        }
    }

    /// The helper quits: popups it still shows come back to this process (the host closes them soon).
    private func handBackPopups(_ helper: Helper) {
        guard let popups = HelperRouting.popupsToHandBack(windowsOf(helper)) else { return }
        for handle in popups.sorted() {
            guard let binding = bindings.removeValue(forKey: handle), let remote = binding.remote else { continue }
            handles.remove(ObjectIdentifier(remote))
            remote.adoptLocally(activate: false)
        }
    }

    private func spec(_ handle: UInt32, _ w: RemoteWindow) -> HelperWindowSpec {
        let content = w.window.contentRect(forFrameRect: w.window.frame)
        var spec = HelperWindowSpec(id: handle, title: String(displayName(w.info.title).prefix(512)),
                                    rect: HelperRouting.wireRect(w.contentPixelRect), frame: WirePointRect(content),
                                    scale: Double(w.displayScale), seamless: true, minimized: w.info.isMinimized,
                                    topmost: w.info.isTopmost, dim: w.controller?.dimAlpha.map(Double.init))
        if w.isApp {
            let controls = TWIWindowControls(style: w.info.style)
            spec.resizable = controls.resizable
            spec.zoomable = controls.zoomable
            let bands = Self.points(w.hitBands, scale: w.displayScale)
            spec.bands = bands.isEmpty ? nil : bands
        } else {
            spec.popup = true
            spec.menu = w.info.isMenu
            spec.minimized = nil
        }
        return spec
    }

    /// The hit bands in view points for the helper (it compares view points; the bands are session pixels).
    static func points(_ bands: TWIHitBands, scale k: CGFloat) -> HelperHitBands {
        let k = max(k, 1)
        func p(_ v: CGFloat) -> Double { Double(v / k) }
        return HelperHitBands(resizeEdge: bands.resizeEdge.map(p),
                              caption: bands.caption.map { .init(top: p($0.top), bottom: p($0.bottom), left: p($0.left), right: p($0.right)) })
    }

    private func sendSpec(_ handle: UInt32, _ w: RemoteWindow, added: Bool) {
        guard var binding = bindings[handle], let helper = helpers[binding.helperKey], helper.state == .ready else { return }
        let new = spec(handle, w)
        if !added, binding.sent == new { return }
        binding.sent = new
        bindings[handle] = binding
        send(helper, added ? .windowAdded(new) : .windowChanged(new))
    }

    private func sendSurface(_ helper: Helper) {
        guard let surface = helper.controller?.surface else { return }
        let port = IOSurfaceCreateMachPort(surface)
        send(helper, .surface(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface)), port: port)
        MachChannel.deallocate(port)
    }

    private func send(_ helper: Helper, _ message: HostMessage, port: mach_port_t = mach_port_t(MACH_PORT_NULL)) {
        guard helper.port != MACH_PORT_NULL else { return }
        // Frames were just dropped (its queue is full): do not wait 200 ms per message on a helper that
        // is not reading.
        let kr = MachChannel.send(message, to: helper.port, port: port, timeoutMs: helper.frameDrops > 0 ? 0 : 200)
        noteSend(helper, kr, frame: false)
    }

    /// A dead port ends the helper; a helper that stops reading (control messages time out, or frames
    /// keep finding its queue full) is hung: its windows come back here and it is told to go.
    private func noteSend(_ helper: Helper, _ kr: kern_return_t, frame: Bool) {
        switch kr {
        case KERN_SUCCESS:
            if frame { helper.frameDrops = 0 } else { helper.timeouts = 0 }
        case MACH_SEND_INVALID_DEST:
            helperGone(helper, "port invalid")
        case MACH_SEND_TIMED_OUT:
            if frame { helper.frameDrops += 1 } else { helper.timeouts += 1 }
            guard helper.timeouts >= Self.maxTimeouts || helper.frameDrops >= Self.maxFrameDrops, helper.state == .ready else { return }
            let pid = helper.pid, quitting = helper.quitting
            if quitting { helperGone(helper, "hung while quitting") } else { fail(helper, "not reading its messages (hung)") }
            // Our own helper (checked at check-in): a hung main thread would never see the dead port.
            if pid > 0 { kill(pid, SIGTERM) }
        default:
            vlog("helper apps: \(helper.logLabel): send failed (\(kr))")
        }
    }
}

// MARK: Input from helpers (the same mapping as SessionView, on the hidden window's state; popups too)

extension RemoteWindow {
    /// Session pixel for a helper's event: the helper's window has this window's frame (mirrored), so the
    /// map is the one `SessionView.sessionPoint` uses (docs/80 §2.3).
    func helperSessionPoint(view p: CGPoint, screen: CGPoint) -> (x: Int, y: Int) {
        guard let layout = controller?.layout else { return ScalingLayout.sessionPoint(viewPoint: p, origin: inputOrigin, scale: displayScale) }
        return layout.eventPoint(viewPoint: p, origin: inputOrigin, scale: displayScale, screenPoint: screen,
                                 windowFrame: window.frame, windowMonitor: monitorIndex)
    }

    /// As SessionView's mouse handlers: Ctrl-click is a right click; only the middle "other" button counts.
    func helperMouse(_ kind: MouseKind, button: Int, view p: CGPoint, screen: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let controller, !controller.inputBlocked else { return }
        let control = modifiers.contains(.control)
        let state: WDBuild.MouseState
        switch (kind, button) {
        case (.moved, _), (.dragged, _): state = .moved
        case (.down, 0): state = control ? .rightDown : .leftDown
        case (.up, 0): state = control ? .rightUp : .leftUp
        case (.down, 1): state = .rightDown
        case (.up, 1): state = .rightUp
        case (.down, 2): state = .middleDown
        case (.up, 2): state = .middleUp
        default: return
        }
        if kind == .down { controller.noteActivity() }
        let s = helperSessionPoint(view: p, screen: screen)
        controller.mouse(x: s.x, y: s.y, state: state)
    }
}
