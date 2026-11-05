import AppKit
import Carbon.HIToolbox
import ICAKit

/// Live self-test for "Calculator" (ICAVIEWER_SELFTEST=1). Drives the first app window through the
/// normal NSWindow event path (synthetic NSEvents via `sendEvent`), dumps the framebuffer crop of the
/// window to `.session/viewer-<n>.png` (0600), pauses for an external Accessibility check
/// (`.session/selftest-hold` appears; touch `.session/selftest-continue` to go on), moves the window,
/// then closes it. Button positions are window-relative pixels of win32calc in the German UI.
final class SelfTest {
    private weak var controller: SessionController?
    private var started = false
    private let hold = Paths.sessionDir.appendingPathComponent("selftest-hold")
    private let resume = Paths.sessionDir.appendingPathComponent("selftest-continue")

    init(controller: SessionController) {
        self.controller = controller
        try? FileManager.default.removeItem(at: hold)
        try? FileManager.default.removeItem(at: resume)
        controller.onWindowsChanged = { [weak self] c in self?.windowsChanged(c) }
        // Never leave a test session running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { vlog("selftest: overall timeout"); NSApp.terminate(nil) }
    }

    private func windowsChanged(_ c: SessionController) {
        guard !started, let w = c.windows.values.first(where: { $0.isApp && $0.info.title.hasPrefix("Rechner") }) else { return }
        started = true
        Task { @MainActor in await run(w) }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    @MainActor private func run(_ w: RemoteWindow) async {
        guard let c = controller else { return }
        vlog("selftest: window \(String(w.info.id, radix: 16)) windowNumber \(w.window.windowNumber)")
        await pause(3)
        dump(w, "viewer-0")
        NSApp.activate()
        w.window.makeKeyAndOrderFront(nil)
        w.window.makeFirstResponder(w.view)
        await pause(0.5)

        // C, 1, +, 2, =  (window-relative remote pixels)
        let buttons: [(String, CGFloat, CGFloat)] = [("C", 106, 162), ("1", 28, 258), ("+", 145, 290), ("2", 67, 258), ("=", 184, 273)]
        for (name, x, y) in buttons {
            click(w, x, y)
            vlog("selftest: clicked \(name)")
            await pause(0.4)
        }
        await pause(1.5)
        dump(w, "viewer-1")   // expect 3

        // Type 4, 2 via key events (scancodes); after "=" this starts a new number: 42.
        for (ch, code) in [("4", kVK_ANSI_4), ("2", kVK_ANSI_2)] { key(w, ch, code) ; await pause(0.3) }
        await pause(1.5)
        dump(w, "viewer-2")   // expect 42

        // External AX check window.
        FileManager.default.createFile(atPath: hold.path, contents: Data("\(w.window.windowNumber)\n".utf8), attributes: [.posixPermissions: 0o600])
        vlog("selftest: holding for the AX check")
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: resume.path) { await pause(0.5) }
        try? FileManager.default.removeItem(at: hold)
        try? FileManager.default.removeItem(at: resume)

        // Move the macOS window: +120 right, 60 down (screen y is bottom-up).
        let before = w.info.windowRect
        w.window.setFrameOrigin(NSPoint(x: w.window.frame.minX + 120, y: w.window.frame.minY - 60))
        await pause(3)
        let after = c.currentInfo(w.info.id)?.windowRect
        vlog("selftest: remote rect before \(before.left),\(before.top) after \(after.map { "\($0.left),\($0.top)" } ?? "?") local \(w.localRemoteRect.left),\(w.localRemoteRect.top)")
        dump(w, "viewer-3")

        // Menu popup: click "Ansicht", expect a popup panel, close it with Escape.
        click(w, 28, 40)
        await pause(1.5)
        let popups = c.windows.values.filter { !$0.isApp }
        vlog("selftest: after menu click: \(popups.count) popup panel(s) \(popups.map { "\(type(of: $0.window)) \($0.info.windowRect.width)x\($0.info.windowRect.height) visible \($0.window.isVisible)" })")
        dump(w, "viewer-4")
        key(w, "\u{1b}", kVK_Escape)
        await pause(1)

        // Minimise and restore through the macOS buttons.
        w.window.performMiniaturize(nil)
        await pause(2.5)
        vlog("selftest: after miniaturize: local \(w.window.isMiniaturized) remote minimised \(c.currentInfo(w.info.id)?.isMinimized ?? false)")
        w.window.deminiaturize(nil)
        await pause(2.5)
        vlog("selftest: after deminiaturize: local \(w.window.isMiniaturized) remote minimised \(c.currentInfo(w.info.id)?.isMinimized ?? false) rect \(c.currentInfo(w.info.id).map { "\($0.windowRect.left),\($0.windowRect.top)" } ?? "?")")
        dump(w, "viewer-5")

        if ProcessInfo.processInfo.environment["ICAVIEWER_SELFTEST_END"] == "quit" {
            // App quit path: applicationShouldTerminate logs the session off first.
            vlog("selftest: quitting the app")
            NSApp.terminate(nil)
            return
        }
        // Close via the close button path: TWI close → host destroys → session ends → app quits.
        vlog("selftest: closing the window")
        w.window.performClose(nil)
    }

    private func click(_ w: RemoteWindow, _ x: CGFloat, _ y: CGFloat) {
        let p = w.view.convert(NSPoint(x: x, y: y), to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            w.window.sendEvent(e)
        }
    }

    private func key(_ w: RemoteWindow, _ ch: String, _ code: Int) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.window.windowNumber, context: nil, characters: ch,
                                           charactersIgnoringModifiers: ch, isARepeat: false, keyCode: UInt16(code)) else { continue }
            w.window.sendEvent(e)
        }
    }

    /// Framebuffer crop of the window's remote rect (read on the session queue).
    private func dump(_ w: RemoteWindow, _ name: String) {
        guard let c = controller else { return }
        let r = c.currentInfo(w.info.id)?.windowRect ?? w.info.windowRect
        let url = Paths.sessionDir.appendingPathComponent(name + ".png")
        let thinwire = c.session.thinwire
        c.session.perform {
            let rect = CGRect(x: Int(r.left), y: Int(r.top), width: Int(r.width), height: Int(r.height))
            if thinwire.framebuffer?.writePNG(to: url, rect: rect) == true {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                vlog("selftest: wrote \(url.lastPathComponent)")
            }
        }
    }
}

/// ICAVIEWER_PROBE_CLICK=1 (hold mode): the first time the app becomes active after a "Rechner" window
/// exists, click its C button 2 s later through the normal NSWindow path, to prove that input still
/// reaches the host after a Dock-style activation.
final class ActivationProbe {
    private weak var controller: SessionController?
    private var token: NSObjectProtocol?

    init(controller: SessionController) {
        self.controller = controller
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activated()
        }
    }

    private func activated() {
        guard let c = controller, let w = c.windows.values.first(where: { $0.isApp && $0.info.title.hasPrefix("Rechner") }) else { return }
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        vlog("probe: app became active; clicking C in 2 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let p = w.view.convert(NSPoint(x: 106, y: 162), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                w.window.sendEvent(e)
            }
            vlog("probe: clicked C")
        }
    }
}
