import CoreGraphics
import Foundation
import ICAKit

// MARK: - Chroma probe: H.264 4:4:4 vs 4:2:0 on moving content (backlog 1.4, D155)

/// `icactl chromaprobe [seconds]` (lab, "Command Prompt"): starts mac-D's noise window (C:\Users\Public\edt-noise.ps1,
/// 1024×640 of random RGB redrawn every 50 ms) so the VDA streams video, and every 2 s measures our decoded framebuffer
/// inside the window: the chroma (BT.601 Cb/Cr) difference between horizontal neighbours **inside** a 2×2 block vs
/// **across** block borders (session coordinates). 4:2:0 shares one chroma sample per 2×2 block, so the inside
/// difference collapses (ratio ≪ 1); 4:4:4 keeps independent chroma per pixel (ratio ≈ 1). Also reports H.264 pictures
/// and decoder errors. No input besides the one command line; logoff at the end.
/// `pattern` scroll (backlog 2.2): the window shows scripts/vda/edt-noise.ps1's deterministic scrolling texture
/// instead; every sampled window crop is matched against it (`ChromaMetric.matchScroll`) for a PSNR, after the window
/// closed. Bytes received and this process's CPU time over the window are reported too (the VideoToolbox decoder
/// service's CPU is not included).
func runChromaProbe(ica: ICAFile, seconds: Int, pattern: String = "noise") async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config)
    let seamless = session.seamless

    var logon = newLogonDetector()
    var consoleUp = false
    var noiseWindow: UInt32?
    var decoderLines: [String] = []
    var terminateReason: UInt8?
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            if w.kind == .appWindow, w.appKey.lowercased().contains("command prompt") || w.title.lowercased().contains("cmd") { consoleUp = true }
            if w.title == "edt-noise" { noiseWindow = w.id; say("noise window \(w.id) up") }
        case .windowChanged(let w, _):
            if noiseWindow == nil, w.title == "edt-noise" { noiseWindow = w.id; say("noise window \(w.id) up") }
        default: break
        }
    }
    session.onThinwireInit = { info in
        say("Thinwire INIT \(info.width)x\(info.height) profile \(info.profile)")
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.thinwire.log = { line in
        if line.contains("H.264") || line.lowercased().contains("decod") {
            decoderLines.append(line)
            if decoderLines.count <= 8 { say(line) }
        }
    }
    session.onEvent = { event in
        switch event {
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        default: break
        }
    }

    try await session.start()
    let found = await waitFor(session, 150) { logon.isFresh && consoleUp }
    let fresh = await onSession(session) { logon.isFresh }
    var ratios: [Double] = []
    var crops: [(rgba: [UInt8], width: Int, height: Int)] = []
    var window: (bytes: Int, cpu: Double, wall: Double)?
    func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    if found {
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let command = "powershell -nop -ep bypass -file C:\\Users\\Public\\edt-noise.ps1 -Seconds \(seconds) -Pattern \(pattern)"
        say("type: \(command)")
        session.sendInput { wd in
            for unit in command.utf16 { wd.keyUnicode(unit, flags: []); wd.keyUnicode(unit, flags: .up) }
            wd.keyScancode(0x1C, up: false)
            wd.keyScancode(0x1C, up: true)
        }
        if await waitFor(session, 30, { noiseWindow != nil }) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let start = Date()
            let (b0, c0) = (await onSession(session) { session.transport.status.bytesReceived }, cpuSeconds())
            while Date().timeIntervalSince(start) < Double(seconds) - 4, !session.isClosed {
                let sample = await onSession(session) { () -> (Double, Double)? in
                    guard let id = noiseWindow, let w = seamless.model.windows[id], let fb = session.thinwire.framebuffer else { return nil }
                    // 256×256 px from the middle of the window (well inside the picture box; the title bar is above).
                    let r = w.windowRect
                    let x0 = Int(r.left + r.right) / 2 - 128, y0 = Int(r.top + r.bottom) / 2 - 128
                    let rect = CGRect(x: x0, y: y0, width: 256, height: 256)
                    guard rect.width > 16, rect.height > 16, let image = fb.makeImage(rect: rect), let rgba = rgbaBytes(image) else { return nil }
                    return ChromaMetric.insideAcross(rgba: rgba, width: image.width, height: image.height, originX: x0, originY: y0)
                }
                if ratios.isEmpty, let png = await onSession(session, { () -> Data? in
                    guard let id = noiseWindow, let w = seamless.model.windows[id], let fb = session.thinwire.framebuffer else { return nil }
                    let r = w.windowRect
                    return fb.makeImage(rect: CGRect(x: Int(r.left + r.right) / 2 - 128, y: Int(r.top + r.bottom) / 2 - 128, width: 256, height: 256))
                        .flatMap(RichClipImage.png)
                }) {
                    let url = sessionDir.appendingPathComponent("chromaprobe-sample.png")
                    try? png.write(to: url)
                    say("sample crop: \(url.path)")
                }
                if pattern == "scroll", crops.count < 12, let crop = await onSession(session, { () -> (rgba: [UInt8], width: Int, height: Int)? in
                    guard let id = noiseWindow, let w = seamless.model.windows[id], let fb = session.thinwire.framebuffer else { return nil }
                    let r = w.windowRect
                    let c = fb.rgba(rect: TWRect(Int(r.left), Int(r.top), Int(r.right - r.left), Int(r.bottom - r.top)))
                    return c.pixels.isEmpty ? nil : (c.pixels, c.rect.width, c.rect.height)
                }) { crops.append(crop) }
                if let (inside, across) = sample, across > 0 {
                    ratios.append(inside / across)
                    say(String(format: "chroma neighbour difference: inside 2×2 %.2f, across %.2f, ratio %.2f", inside, across, inside / across))
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let (b1, c1) = (await onSession(session) { session.transport.status.bytesReceived }, cpuSeconds())
            window = (b1 - b0, c1 - c0, Date().timeIntervalSince(start))
        } else {
            say("no noise window within 30 s")
        }
    } else {
        say("no Command Prompt window (fresh \(fresh))")
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
        ending = session.isClosed ? "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "") : "logoff did not end the session; disconnected"
        if !session.isClosed { await session.close() }
    }
    let st = await onSession(session) { session.thinwire.stats }
    let median = ratios.sorted().dropFirst(ratios.count / 2).first ?? .nan
    var psnrs: [Double] = [], stripes: [Double] = []
    if let c = crops.first {
        let url = sessionDir.appendingPathComponent("chromaprobe-crop-\(c.width)x\(c.height).rgba")
        try? Data(c.rgba).write(to: url)
        say("first window crop (raw RGBA): \(url.path)")
    }
    for (i, c) in crops.enumerated() {
        if let m = ChromaMetric.matchScroll(rgba: c.rgba, width: c.width, height: c.height) {
            psnrs.append(m.psnr); stripes.append(m.psnrStripes)
            say(String(format: "scroll crop %d: texture at row %d, phase %d: PSNR %.1f dB (hash rows %.1f, stripe rows %.1f), %d px",
                       i, m.top, m.phase, m.psnr, m.psnrNoise, m.psnrStripes, m.pixels))
        } else {
            say("scroll crop \(i): pattern not found")
        }
    }
    let verdict = ratios.isEmpty ? "no samples" : median < 0.5 ? "4:2:0-like (chroma shared per 2×2 block)" : "4:4:4-like (chroma per pixel)"
    say("\n=== chromaprobe summary ===")
    say("Thinwire: \(st.frames) frames, \(st.pictures) H.264 pictures, errors \(st.errors), resyncs \(st.resyncs); decoder log lines \(decoderLines.count)")
    say(String(format: "chroma ratio median %.2f over %d samples: %@", median, ratios.count, verdict))
    if let window {
        say(String(format: "noise window: %.1f s, received %d B (%.2f Mbit/s), process CPU %.2f s (%.0f %% of one core)",
                   window.wall, window.bytes, Double(window.bytes) * 8 / window.wall / 1e6, window.cpu, window.cpu / window.wall * 100))
    }
    if !psnrs.isEmpty {
        let mid = psnrs.sorted()[psnrs.count / 2], midS = stripes.sorted()[stripes.count / 2]
        say(String(format: "scroll PSNR median %.1f dB (stripe rows %.1f dB) over %d of %d crops", mid, midS, psnrs.count, crops.count))
    }
    say("end: \(ending)")
    let pass = fresh && !ratios.isEmpty && st.errors == 0 && ending.hasPrefix("logged off")
    say(String(format: "RESULT: %@ chromaprobe: %d H.264 pictures, errors %d, chroma ratio %.2f (%@), end: %@",
               pass ? "PASS" : "FAIL", st.pictures, st.errors, median, verdict, ending))
}
