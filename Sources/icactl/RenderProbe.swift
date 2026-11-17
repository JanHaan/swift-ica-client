import CoreGraphics
import Darwin
import Foundation
import ICAKit

// MARK: - Rendering probe: H.264 vs Thinwire (backlog 1.4, D134)

/// `icactl renderprobe [resource]` (lab, Paint): pastes the 64×48 test pattern of `cliptest-rich image` into Paint's canvas,
/// waits until the screen is quiet, finds the pattern in the framebuffer and compares its interior (6 px inset, so the
/// selection frame and handles do not count) with the original: max channel delta, mean, PSNR, pixels off by more than 2. Then
/// `ICA_RENDERPROBE_REDRAWS` (default 5) full-screen redraws, measuring the bytes received and this process's CPU time per
/// redraw. Reports the Thinwire profile (2/3 = H.264) and logs off. Run it under `icalab.sh policy set codec=…`.
func runRenderProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let redraws = max(0, min(20, Int(env["ICA_RENDERPROBE_REDRAWS"] ?? "") ?? 5))
    let runID = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    let outDir = sessionDir.appendingPathComponent("render")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let layout = config.logon.keyboardLayout
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipTestConfig())
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless

    // Session-queue state.
    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var clipReady = false
    var lastUpdate = Date()
    var updates = 0
    var profile: Int?
    var terminateReason: UInt8?
    clip.onEvent = { event in if case .ready = event { clipReady = true } }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
        case .windowChanged(let w, _): windowsSeen.note(w)
        case .windowRemoved(let w): appWindows.removeAll { $0 == w.id }
        default: break
        }
    }
    session.onThinwireInit = { info in
        profile = Int(info.profile)
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.thinwire.onUpdate = { _ in updates += 1; lastUpdate = Date() }
    var h264Frames = 0
    session.thinwire.log = { line in
        if line.contains("H.264") { h264Frames += 1; if h264Frames <= 3 { say(line) } }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): if text.contains("H.264") || text.contains("profile") { say(text) }
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        default: break
        }
    }
    func keys(_ sequence: String) throws {
        for step in try AudioTestKeys.parse(sequence, keyboardLayout: layout) {
            session.sendInput { wd in
                for m in step.modifiers { wd.keyScancode(m, up: false) }
                if step.extended {
                    wd.keyScancodes([0xE0, step.scancode], up: false)
                    wd.keyScancodes([0xE0, step.scancode], up: true)
                } else {
                    wd.keyScancode(step.scancode, up: false)
                    wd.keyScancode(step.scancode, up: true)
                }
                for m in step.modifiers.reversed() { wd.keyScancode(m, up: true) }
            }
        }
    }
    func quiet(_ seconds: Double, max: Double) async { _ = await waitFor(session, max) { Date().timeIntervalSince(lastUpdate) >= seconds } }
    func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    try await session.start()
    let paint: () -> UInt32? = {
        appWindows.first { app.matches(executable: windowsSeen.single($0, seamless.model), appKey: windowsSeen.appKey($0)) }
    }
    let found = await waitFor(session, 150) { logon.isFresh && paint() != nil && clipReady }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { paint() }
    var compared = false
    var lines: [String] = []
    func note(_ line: String) { lines.append(line); say(line) }
    if !fresh {
        note("not a fresh logon by this run: no input is sent")
    } else if !found || target == nil {
        note("no \(app.resource) window or no clipboard: no input is sent")
    } else if let target {
        session.send { _, twi in twi.activate(windowId: target) }
        await quiet(3, max: 20)
        let others = await onSession(session) { seamless.model.windows.values.filter { $0.kind == .appWindow && $0.id != target }.map(\.title) }
        if !others.isEmpty {
            note("other windows \(others): no input")
        } else {
            // The pattern, as cliptest-rich image sends it.
            let pixels = RichClipImage.pixels()
            session.clipboardAnnounce(ClipboardSnapshot(content: ClipboardContent(image: ClipboardImage(width: RichClipImage.width,
                height: RichClipImage.height, rgba: pixels))))
            try await Task.sleep(nanoseconds: 500_000_000)
            try keys("ctrl+v")
            await quiet(4, max: 30)
            let rect = await onSession(session) { () -> CGRect in
                guard let w = seamless.model.windows[target] else { return .zero }
                let r = w.windowRect
                return CGRect(x: Int(r.left), y: Int(r.top), width: Int(r.right - r.left), height: Int(r.bottom - r.top))
            }
            let image = await onSession(session) { session.thinwire.framebuffer?.makeImage(rect: rect) }
            if let image, let rgba = rgbaBytes(image) {
                let w = image.width, h = image.height
                func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                    let i = (y * w + x) * 4
                    return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
                }
                func near(_ p: (Int, Int, Int), _ q: (UInt8, UInt8, UInt8), _ tol: Int) -> Bool {
                    abs(p.0 - Int(q.0)) <= tol && abs(p.1 - Int(q.1)) <= tol && abs(p.2 - Int(q.2)) <= tol
                }
                // The red quadrant's top-left (x 1..31, y 1..23 of the pattern), confirmed by green and blue samples.
                var origin: (Int, Int)?
                search: for y in 0..<(h - 48) {
                    for x in 0..<(w - 64) where near(px(x + 1, y + 1), (230, 20, 20), 40) && near(px(x + 5, y + 5), (230, 20, 20), 40) {
                        if near(px(x + 40, y + 10), (20, 200, 40), 50), near(px(x + 10, y + 36), (80, 0, 220), 60) {
                            origin = (x, y)
                            break search
                        }
                    }
                }
                // Refine: the selection frame hides the pattern's first columns and rows, so the first red pixel is only
                // near the origin; take the offset within ±6 px that fits the interior best.
                if let (rx, ry) = origin {
                    let src0 = [UInt8](pixels)
                    var best: (x: Int, y: Int, err: Int)?
                    for dy in -6...6 {
                        for dx in -6...6 {
                            let x0 = rx + dx, y0 = ry + dy
                            guard x0 >= 0, y0 >= 0, x0 + 64 <= w, y0 + 48 <= h else { continue }
                            var e = 0
                            for y in stride(from: 8, to: 40, by: 2) {
                                for x in stride(from: 8, to: 56, by: 2) {
                                    let p = px(x0 + x, y0 + y), i = (y * RichClipImage.width + x) * 4
                                    e += abs(p.0 - Int(src0[i])) + abs(p.1 - Int(src0[i + 1])) + abs(p.2 - Int(src0[i + 2]))
                                }
                            }
                            if best == nil || e < best!.err { best = (x0, y0, e) }
                        }
                    }
                    if let best { origin = (best.x, best.y) }
                }
                if let (ox, oy) = origin {
                    // 6 px inset: Paint's selection frame and its resize handles (about 5 px) cover the pattern's edges.
                    let inset = 6
                    var maxDelta = 0, sum = 0, n = 0, off = 0
                    var sq = 0.0
                    let src = [UInt8](pixels)
                    for y in inset..<(RichClipImage.height - inset) {
                        for x in inset..<(RichClipImage.width - inset) {
                            let p = px(ox + x, oy + y)
                            let i = (y * RichClipImage.width + x) * 4
                            let d = [abs(p.0 - Int(src[i])), abs(p.1 - Int(src[i + 1])), abs(p.2 - Int(src[i + 2]))]
                            maxDelta = max(maxDelta, d.max()!)
                            sum += d.reduce(0, +)
                            sq += d.reduce(0.0) { $0 + Double($1 * $1) }
                            if d.max()! > 2 { off += 1 }
                            n += 1
                        }
                    }
                    // Raw framebuffer samples (0xAARRGGBB, no colour conversion) against the pattern.
                    let raw = await onSession(session) { () -> [String] in
                        guard let fb = session.thinwire.framebuffer else { return [] }
                        return [(10, 10), (40, 10), (10, 36), (40, 36), (56, 40)].map { (x, y) in
                            let v = fb.pixel(x: Int(rect.minX) + ox + x, y: Int(rect.minY) + oy + y)
                            let i = (y * RichClipImage.width + x) * 4
                            return String(format: "(%d,%d) raw %d,%d,%d want %d,%d,%d", x, y, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF,
                                          src[i], src[i + 1], src[i + 2])
                        }
                    }
                    note("samples: " + raw.joined(separator: "; "))
                    let mse = sq / Double(n * 3)
                    let psnr = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
                    compared = true
                    note(String(format: "pattern at (%d, %d) in the window: interior %d px, max delta %d, mean %.2f, PSNR %@, off by > 2: %d",
                                ox, oy, n, maxDelta, Double(sum) / Double(n * 3), psnr.isInfinite ? "inf" : String(format: "%.1f dB", psnr), off))
                    let crop = outDir.appendingPathComponent("renderprobe-\(runID).png")
                    if let cg = image.cropping(to: CGRect(x: ox - 4, y: oy - 4, width: 72, height: 56)), let png = RichClipImage.png(cg) {
                        try? png.write(to: crop)
                        note("crop: \(crop.path)")
                    }
                } else {
                    note("pattern not found in the window's framebuffer (paste failed?)")
                    if let png = RichClipImage.png(image) { try? png.write(to: outDir.appendingPathComponent("renderprobe-\(runID)-window.png")) }
                }
            } else {
                note("no framebuffer image of the window")
            }
            // Full redraws: bytes and CPU per redraw.
            for i in 0..<redraws {
                let (b0, c0, t0) = (await onSession(session) { session.transport.status.bytesReceived }, cpuSeconds(), Date())
                session.send { wd, _ in wd.redraw() }
                try await Task.sleep(nanoseconds: 300_000_000)
                await quiet(1.5, max: 20)
                let (b1, c1) = (await onSession(session) { session.transport.status.bytesReceived }, cpuSeconds())
                note(String(format: "redraw %d: %d B, CPU %.0f ms, %.1f s until quiet", i + 1, b1 - b0, (c1 - c0) * 1000,
                            Date().timeIntervalSince(t0) - 1.5))
            }
        }
    }
    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            await session.close()
            ending = "logoff did not end the session in 40 s; disconnected"
        }
    }
    let (p, total, cpu) = await onSession(session) { (profile, session.transport.status.bytesReceived, cpuSeconds()) }
    say("\n=== renderprobe summary (run \(runID)) ===")
    let st = await onSession(session) { session.thinwire.stats }
    say("Thinwire: \(st.commands) commands, \(st.frames) frames, \(st.pictures) H.264 pictures, errors \(st.errors), opcodes "
        + st.opcodes.sorted { $0.value > $1.value }.prefix(8).map { String(format: "%02X×%d", $0.key, $0.value) }.joined(separator: " "))
    say("Thinwire profile \(p.map(String.init) ?? "?") (2/3 = H.264); received \(total) B in all; process CPU \(String(format: "%.1f", cpu)) s")
    for line in lines { say("  " + line) }
    say("end: \(ending)")
    let pass = fresh && compared && ending.hasPrefix("logged off")
    say("RESULT: \(pass ? "PASS" : "FAIL") renderprobe: profile \(p.map(String.init) ?? "?"), compared \(compared), end: \(ending)")
}

/// RGBA8 bytes of an image (sRGB, not premultiplied for opaque content).
func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let ok: Bool = out.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? out : nil
}
