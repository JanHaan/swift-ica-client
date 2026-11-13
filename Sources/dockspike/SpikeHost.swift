import AppHostKit
import AppKit

/// The host role of docs/99 (`dockspike run`): generates two helper bundles, launches them through
/// LaunchServices, shares one IOSurface with both, animates it with dirty-rect frames, logs the input
/// the helpers forward, and hands activation between them (yield, then activate).
final class SpikeHost {
    struct Helper {
        var label: HelperLabel
        var color: CGColor
        var letter: String
        var windows: [HelperWindowSpec]
        var token = HelperLaunch.makeToken()
        var bundle: URL?
        var pid: pid_t = 0
        var port = mach_port_t(MACH_PORT_NULL)
        var exitWatch: DispatchSourceProcess?
        var gone = false
    }

    struct Options {
        var template: URL
        var appsDirectory: URL
        var fps: Double = 30
        /// Seconds between programmatic focus switches while a helper is frontmost; 0 = off.
        var switchInterval: Double = 0
        /// Quit everything after this many seconds; 0 = run until q, Ctrl-C or the last helper exits.
        var duration: Double = 0
    }

    private let options: Options
    private var helpers: [Helper]
    private let scene: Scene
    private var broker: MachReceiver?
    private let brokerName = HelperLaunch.brokerName(hostPid: getpid())
    private var frameTimer: Timer?
    private var switchTimer: Timer?
    private var switchIndex = 0
    private var droppedFrames = 0
    private var moves = 0
    private var reported = false
    private var signalSources: [DispatchSourceSignal] = []
    /// Activation waiting for the active helper's `yielded`: (helper index, window id).
    private var pendingActivation: (Int, UInt32)?
    private let started = Date()

    init?(options: Options) {
        self.options = options
        // Session pixels; the helpers show them at the screen's backing scale (2 px per point on Retina).
        guard let scene = Scene(width: 1600, height: 1100) else { return nil }
        self.scene = scene
        helpers = Self.defaultHelpers()
    }

    static func populate(_ scene: Scene, _ helpers: [Helper]) {
        for h in helpers {
            for spec in h.windows {
                // Opaque colours only: regions are repainted over themselves every frame.
                scene.add(spec, color: spec.id == 3 ? CGColor(red: 0.62, green: 0.22, blue: 0.08, alpha: 1) : h.color)
                scene.setHeader(spec.id, "\(h.label.name) · \(spec.title)")
            }
        }
    }

    /// Alpha owns one window, Beta two: AX must list them under their own pid only.
    static func defaultHelpers() -> [Helper] {
        [
            Helper(label: HelperLabel(key: "dockspike.alpha", name: "Spike Alpha"),
                   color: CGColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1), letter: "A",
                   windows: [HelperWindowSpec(id: 1, title: "Alpha — Document", rect: WireRect(x: 40, y: 80, width: 700, height: 440))]),
            Helper(label: HelperLabel(key: "dockspike.beta", name: "Spike Beta"),
                   color: CGColor(red: 0.85, green: 0.35, blue: 0.16, alpha: 1), letter: "B",
                   windows: [HelperWindowSpec(id: 2, title: "Beta — Inbox", rect: WireRect(x: 820, y: 80, width: 700, height: 440)),
                             HelperWindowSpec(id: 3, title: "Beta — Message", rect: WireRect(x: 430, y: 620, width: 700, height: 400))]),
        ]
    }

    func start() {
        guard let port = MachChannel.checkIn(brokerName) else { fail("bootstrap_check_in(\(brokerName)) failed") }
        let broker = MachReceiver(port: port)
        self.broker = broker
        broker.start(queue: .main) { [weak self] in self?.received($0) }
        say("broker \(brokerName)")

        let generator = HelperBundleGenerator(template: options.template, appsDirectory: options.appsDirectory)
        Self.populate(scene, helpers)
        for i in helpers.indices {
            let h = helpers[i]
            do {
                let (url, outcome) = try generator.generate(h.label, icon: Scene.icon(letter: h.letter, color: h.color))
                helpers[i].bundle = url
                let details = (try? HelperBundleGenerator.codesign(["-dv", url.path])) ?? ""
                let flags = details.split(separator: "\n").first { $0.hasPrefix("CodeDirectory") }.map(String.init) ?? ""
                say("\(h.label.name): \(outcome) \(url.path) [\(flags)]")
            } catch {
                fail("generating \(h.label.name): \(error)")
            }
        }
        for i in helpers.indices { launch(i) }
        installSignalHandlers()
        readCommands()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1 / options.fps, repeats: true) { [weak self] _ in self?.tick() }
        if options.switchInterval > 0 {
            switchTimer = Timer.scheduledTimer(withTimeInterval: options.switchInterval, repeats: true) { [weak self] _ in self?.autoSwitch() }
        }
        if options.duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.duration) { [weak self] in self?.quitAll() }
        }
        say("commands: 1/2/3 = hand focus to window n, ax = ownership report, q = quit (helpers quit too); kill -USR1 \(getpid()) = report")
    }

    // MARK: Launch and check-in

    private func launch(_ i: Int) {
        guard let url = helpers[i].bundle else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = HelperLaunch(broker: brokerName, token: helpers[i].token, hostPid: getpid()).arguments
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        config.promptsUserIfNeeded = false
        let name = helpers[i].label.name
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            DispatchQueue.main.async {
                if let error { self.say("\(name): launch failed: \(error.localizedDescription)") }
                else { self.say("\(name): launched pid \(app?.processIdentifier ?? 0)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.helpers[i].port == MACH_PORT_NULL, !self.helpers[i].gone else { return }
            self.say("\(name): no check-in within 5 s (an old instance still running? LaunchServices refusal?)")
        }
    }

    private func received(_ received: MachReceived) {
        switch received {
        case .deadName(let name):
            if let i = helpers.firstIndex(where: { $0.port == name }) { say("\(helpers[i].label.name): port died") }
        case .message(let data, let port):
            guard let message = try? WireCoding.decode(HelperMessage.self, from: data) else {
                MachChannel.deallocate(port)
                return say("undecodable message (\(data.count) B)")
            }
            if case .checkIn(let token, let pid) = message { return checkIn(token: token, pid: pid, port: port) }
            MachChannel.deallocate(port)
            handle(message)
        }
    }

    private func checkIn(token: String, pid: pid_t, port: mach_port_t) {
        guard let i = helpers.firstIndex(where: { $0.token == token && $0.port == MACH_PORT_NULL }), port != MACH_PORT_NULL else {
            MachChannel.deallocate(port)
            return say("check-in with an unknown token from pid \(pid): ignored")
        }
        helpers[i].port = port
        helpers[i].pid = pid
        broker?.notifyDeadName(of: port)
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in self?.helperExited(i) }
        watch.resume()
        helpers[i].exitWatch = watch
        let h = helpers[i]
        say("\(h.label.name): checked in, pid \(pid)")
        send(i, .hello(appName: h.label.name))
        let surfacePort = IOSurfaceCreateMachPort(scene.surface)
        send(i, .surface(width: IOSurfaceGetWidth(scene.surface), height: IOSurfaceGetHeight(scene.surface)), port: surfacePort)
        MachChannel.deallocate(surfacePort)
        for spec in h.windows { send(i, .windowAdded(spec)) }
        if helpers.allSatisfy({ $0.pid != 0 }), !reported {
            reported = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.report() }
        }
    }

    private func helperExited(_ i: Int) {
        helpers[i].gone = true
        helpers[i].exitWatch?.cancel()
        MachChannel.deallocate(helpers[i].port)
        helpers[i].port = mach_port_t(MACH_PORT_NULL)
        say("\(helpers[i].label.name): pid \(helpers[i].pid) exited")
        if helpers.allSatisfy(\.gone) {
            say("all helpers gone; exiting")
            exit(0)
        }
    }

    // MARK: Messages from helpers

    private func handle(_ message: HelperMessage) {
        func owner(_ id: UInt32) -> Int? { helpers.firstIndex { $0.windows.contains { $0.id == id } } }
        func latency(_ sentNs: UInt64) -> String { String(format: "%.0f µs", Double(uptimeNanoseconds() &- sentNs) / 1000) }
        switch message {
        case .checkIn:
            break
        case .key(let id, let code, let chars, let modifiers, let down, let sentNs):
            guard let i = owner(id) else { return }
            let shown = chars.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } ? chars : "\\u{\(chars.unicodeScalars.first.map { String($0.value, radix: 16) } ?? "")}"
            say("\(helpers[i].label.name) window \(id): key \(down ? "down" : "up  ") code \(code) chars \"\(shown)\" modifiers 0x\(String(modifiers, radix: 16)) (\(latency(sentNs)))")
            if down { updateInput(i, "key \"\(shown)\" (\(code))") }
        case .mouse(let id, let kind, let button, let x, let y, let clicks, let sentNs):
            guard let i = owner(id) else { return }
            if kind == .moved || kind == .dragged { moves += 1; return }
            say("\(helpers[i].label.name) window \(id): mouse \(kind.rawValue) button \(button) at (\(Int(x)), \(Int(y))) clicks \(clicks) (\(latency(sentNs)))")
            if kind == .down {
                if let dirty = scene.mark(id, at: CGPoint(x: x, y: y)) { sendFrame([id: [dirty]]) }
                updateInput(i, "click (\(Int(x)), \(Int(y)))")
            }
        case .scroll(let id, let dx, let dy, let sentNs):
            guard let i = owner(id) else { return }
            say("\(helpers[i].label.name) window \(id): scroll (\(dx), \(dy)) (\(latency(sentNs)))")
        case .focus(let id):
            guard let i = owner(id) else { return }
            say("\(helpers[i].label.name): window \(id) became key → host would send TWI focus(\(id))")
        case .appActive(let active):
            say("activation: \(frontmostName()) is frontmost (a helper reported \(active ? "didBecomeActive" : "didResignActive"))")
        case .close(let id):
            guard let i = owner(id) else { return }
            say("\(helpers[i].label.name): close window \(id) → host would send TWI close; removing it")
            helpers[i].windows.removeAll { $0.id == id }
            scene.remove(id)
            send(i, .windowRemoved(id: id))
            if helpers[i].windows.isEmpty {
                say("\(helpers[i].label.name): last window gone → quit")
                send(i, .quit)
            }
        case .frameStats(let count, let mean, let max):
            say(String(format: "frame latency host→helper over %d frames: mean %.0f µs, max %.0f µs (dropped so far: %d, mouse moves: %d)", count, mean, max, droppedFrames, moves))
        case .probeResult:
            break
        case .yielded(let pid, let wasActive):
            say("  yielded to pid \(pid) (yielding helper was active: \(wasActive))")
            if let (target, id) = pendingActivation, helpers[target].pid == pid {
                pendingActivation = nil
                send(target, .activate(windowId: id))
            }
        case .activation(let text):
            say("  helper: \(text)")
        case .appQuit:
            say("a helper was quit by the user (Cmd-Q) → host would close that app's windows")
        }
    }

    /// Shown in the header of every window of the app on the next frame: the input round trip.
    private func updateInput(_ i: Int, _ text: String) {
        for spec in helpers[i].windows {
            scene.setHeader(spec.id, "\(helpers[i].label.name) · last: \(text)")
        }
    }

    // MARK: Frames

    private func tick() {
        sendFrame(scene.step())
    }

    private func sendFrame(_ dirty: [UInt32: [WireRect]]) {
        let seed = IOSurfaceGetSeed(scene.surface)
        for i in helpers.indices where helpers[i].port != MACH_PORT_NULL {
            let rects = helpers[i].windows.flatMap { dirty[$0.id] ?? [] }
            guard !rects.isEmpty else { continue }
            // Timeout 0: a busy helper drops a frame rather than stalling the host.
            if MachChannel.send(HostMessage.frame(seed: seed, dirty: rects, sentNs: uptimeNanoseconds()), to: helpers[i].port, timeoutMs: 0) != KERN_SUCCESS {
                droppedFrames += 1
            }
        }
    }

    @discardableResult
    private func send(_ i: Int, _ message: HostMessage, port: mach_port_t = mach_port_t(MACH_PORT_NULL)) -> Bool {
        guard helpers[i].port != MACH_PORT_NULL else { return false }
        let kr = MachChannel.send(message, to: helpers[i].port, port: port)
        if kr != KERN_SUCCESS { say("\(helpers[i].label.name): send failed (\(kr))") }
        return kr == KERN_SUCCESS
    }

    // MARK: Activation handover (docs/99 §4 Focus/activation)

    /// While one of our helpers is frontmost, hand focus to the next window in turn, as a server-side
    /// focus change (TWI) would. Never while another app (Terminal) is frontmost: the host only moves
    /// focus between its own apps.
    private func autoSwitch() {
        let all = helpers.flatMap { h in h.windows.map(\.id) }
        guard !all.isEmpty, frontmostHelper() != nil else { return }
        switchIndex = (switchIndex + 1) % all.count
        handover(to: all[switchIndex], reason: "auto switch")
    }

    private func handover(to id: UInt32, reason: String) {
        guard let target = helpers.firstIndex(where: { $0.windows.contains { $0.id == id } }), helpers[target].pid != 0 else {
            return say("no window \(id)")
        }
        let from = frontmostHelper()
        say("\(reason): focus → \(helpers[target].label.name) window \(id); frontmost now \(frontmostName())")
        if let from, from != target {
            // Yield first; activate when the yield is acknowledged (or after 300 ms without an answer).
            pendingActivation = (target, id)
            send(from, .yieldActivation(toPid: helpers[target].pid))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let (t, w) = self.pendingActivation, t == target, w == id else { return }
                self.pendingActivation = nil
                self.say("  no yield acknowledgement in 300 ms; activating anyway")
                self.send(target, .activate(windowId: id))
            }
        } else {
            if from == nil { say("  (no helper is frontmost, so nobody can yield; macOS may refuse the activation)") }
            send(target, .activate(windowId: id))
        }
        let expected = helpers[target].pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let ok = NSWorkspace.shared.frontmostApplication?.processIdentifier == expected
            self.say("  handover result: frontmost = \(self.frontmostName()) → \(ok ? "OK" : "REFUSED")")
        }
    }

    private func frontmostHelper() -> Int? {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return helpers.firstIndex { $0.pid != 0 && $0.pid == pid }
    }

    private func frontmostName() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return "\(app?.localizedName ?? "?") (pid \(app?.processIdentifier ?? 0))"
    }

    // MARK: Report, commands, exit

    private func report() {
        AXReport.run(helpers.filter { $0.pid != 0 && !$0.gone }.map {
            AXReport.Expectation(pid: $0.pid, name: $0.label.name, windowTitles: $0.windows.map(\.title))
        })
    }

    private func readCommands() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            DispatchQueue.main.async {
                for line in lines { self?.command(line.trimmingCharacters(in: .whitespaces)) }
            }
        }
    }

    private func command(_ text: String) {
        switch text {
        case "ax": report()
        case "q", "quit": quitAll()
        case let n where UInt32(n) != nil: handover(to: UInt32(n)!, reason: "command")
        case "": break
        default: say("unknown command \"\(text)\" (1/2/3, ax, q)")
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGUSR1] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in sig == SIGUSR1 ? self?.report() : self?.quitAll() }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Sends quit to every helper, then exits; helpers would also exit on their own (host pid gone).
    private func quitAll() {
        say("quitting: sending quit to the helpers")
        for i in helpers.indices { send(i, .quit) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    private func say(_ text: String) {
        print(String(format: "[%7.3f] ", Date().timeIntervalSince(started)) + text)
    }

    private func fail(_ text: String) -> Never {
        say("error: " + text)
        exit(1)
    }
}
