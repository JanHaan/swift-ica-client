import AppKit
import CoreGraphics
import Foundation
import ICAKit
import ImageIO

// MARK: - Rich clipboard test (docs/70 §10): HTML and RTF with Word, images with Paint

/// What `icactl cliptest-rich` carries.
enum RichClipKind: String {
    case html, rtf, image

    /// The only app each kind may use (approved test apps, D55).
    var resource: String { self == .image ? "Paint ABC" : "Word 2016 - TEST" }
    var executable: String { self == .image ? "mspaint.exe" : "winword.exe" }
}

/// Test image for Mac → session: four quadrants (red, green, a blue/red ramp, a two-axis ramp) inside a 1-px black
/// frame, opaque, RGBA8 top-down. Every pixel is known, so a round trip can be compared exactly.
enum RichClipImage {
    static let width = 64, height = 48

    static func pixels() -> Data {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var p: (UInt8, UInt8, UInt8)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                    p = (0, 0, 0)
                } else if y < height / 2 {
                    p = x < width / 2 ? (230, 20, 20) : (20, 200, 40)
                } else if x < width / 2 {
                    p = (UInt8(x * 8), 0, 220)
                } else {
                    p = (UInt8((x - width / 2) * 8), UInt8(y * 5), 128)
                }
                let i = (y * width + x) * 4
                out[i] = p.0; out[i + 1] = p.1; out[i + 2] = p.2; out[i + 3] = 255
            }
        }
        return Data(out)
    }

    static func cgImage(width: Int, height: Int, rgba: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// PNG bytes → RGBA8 not premultiplied, top-down: the path the viewer's pasteboard reader takes (SystemPasteboard).
    static func decodePNG(_ data: Data) -> (width: Int, height: Int, rgba: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = image.width, h = image.height
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
        return (w, h, Data(pixels))
    }

    /// Per-channel comparison (RGB only; alpha is reported separately).
    struct Diff { var maxDelta = 0; var mismatched = 0; var total = 0; var alphaNot255 = 0 }

    static func compare(_ a: Data, _ b: Data, count: Int, tolerance: Int = 2) -> Diff {
        var d = Diff()
        d.total = count
        let x = [UInt8](a), y = [UInt8](b)
        for i in 0..<count {
            var worst = 0
            for c in 0..<3 { worst = max(worst, abs(Int(x[i * 4 + c]) - Int(y[i * 4 + c]))) }
            d.maxDelta = max(d.maxDelta, worst)
            if worst > tolerance { d.mismatched += 1 }
            if y[i * 4 + 3] != 255 { d.alphaNot255 += 1 }
        }
        return d
    }
}

/// `icactl cliptest-rich html|rtf|image`. Fresh logon only; input only into the app window this run's own logon opened.
/// - html / rtf ("Word 2016 - TEST"): announce only that format, Ctrl+V into the blank document, screenshot; then
///   Ctrl+A, Ctrl+C and check the host's formats for the marker. Word's start screen is left with Esc (blank document);
///   any other window (first-run or sign-in dialogs) stops the input.
/// - image ("Paint ABC"): announce a 64×48 test image (PNG → RGBA → CF_BITMAP DIB), Ctrl+V into the canvas, screenshot;
///   then Ctrl+C of the still selected pasted image, and compare size and pixels.
/// Nothing is saved: the session is logged off with the document or canvas unsaved (the logoff discards it).
func runClipRichTest(ica: ICAFile, kind: RichClipKind) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let runID = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    let marker = "ICA\(kind.rawValue.uppercased())\(runID)"
    var clipConfig = clipTestConfig()
    clipConfig.traceWire = env["ICA_CLIP_TRACE"] != "0"
    let trace = ClipTrace(enabled: clipConfig.traceWire, name: "cliptest-rich-\(kind.rawValue)", runID: runID)
    let outDir = sessionDir.appendingPathComponent("clipfiles")
    say("run \(runID): cliptest-rich \(kind.rawValue) in \"\(kind.resource)\", marker \(marker)")

    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let layout = config.logon.keyboardLayout
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipConfig)
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless

    // What goes to the session.
    let html = "<p><b>\(marker)</b> <i>kursiv</i> <span style=\"color:#C00000\">rot</span></p>"
        + "<table border=\"1\"><tr><td>A1</td><td>B1</td></tr></table>"
    let rtf = Data(("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}{\\colortbl;\\red192\\green0\\blue0;}"
        + "\\f0\\fs28 \\b \(marker)\\b0  \\i kursiv\\i0  \\cf1 rot\\cf0\\par}").utf8)
    var original: (width: Int, height: Int, rgba: Data)?
    var content: ClipboardContent
    switch kind {
    case .html: content = ClipboardContent(html: html)
    case .rtf: content = ClipboardContent(rtf: rtf)
    case .image:
        let pixels = RichClipImage.pixels()
        guard let cg = RichClipImage.cgImage(width: RichClipImage.width, height: RichClipImage.height, rgba: pixels),
              let png = RichClipImage.png(cg), let decoded = RichClipImage.decodePNG(png) else { fail("cannot build the test PNG") }
        let same = RichClipImage.compare(pixels, decoded.rgba, count: RichClipImage.width * RichClipImage.height, tolerance: 0)
        say("Mac test image: PNG \(png.count) B, decoded \(decoded.width)x\(decoded.height), \(same.mismatched) pixels differ from the pattern")
        try? png.write(to: outDir.appendingPathComponent("cliptest-rich-\(runID)-sent.png"))
        original = decoded
        content = ClipboardContent(image: ClipboardImage(width: decoded.width, height: decoded.height, rgba: decoded.rgba))
    }
    let sentFormat: () -> UInt16? = {
        switch kind {
        case .html: return clip.registeredId(ClipboardFormat.htmlName)
        case .rtf: return clip.registeredId(ClipboardFormat.rtfName)
        case .image: return ClipboardFormat.bitmap
        }
    }

    // Session-queue state.
    var logon = FreshLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var lastWindowChange = Date()
    var ready = false
    var requests: [(format: UInt16, served: Bool, bytes: Int, at: Double)] = []
    var hostContent: ClipboardContent?
    var hostFormatList: [UInt16] = []
    var fetchFailures: [String] = []
    var protocolErrors = 0
    var terminateReason: UInt8?

    clip.onEvent = { event in
        if case .trace(let line) = event { return trace.write(line) }
        trace.write(event.description)
        switch event {
        case .hostClipboard(let c, let formats, let echo):
            hostContent = c
            say("clip: host clipboard ready (\(formats.map { clip.label($0) }.joined(separator: ", "))): \(c.summary)\(echo ? " [echo]" : "")")
            return
        case .formatNames(let entries):
            say("clip: FORMAT_NAMES: " + entries.map { String(format: "0x%04X \"%@\"", $0.id, $0.name) }.joined(separator: ", "))
            return
        default: break
        }
        say("clip: \(event)")
        switch event {
        case .ready: ready = true
        case .hostRequest(let format, let served, let bytes):
            requests.append((format, served, bytes, Date().timeIntervalSince(Clock.start)))
        case .hostFormats(let ids): hostFormatList = ids
        case .fetchFailed(let format, let why): fetchFailures.append("\(clip.label(format)): \(why)")
        case .protocolError: protocolErrors += 1
        default: break
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(logon.isFresh ? "fresh logon (host init after \(Int(gap)) s)" : "reconnect pattern (host init)") }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            lastWindowChange = Date()
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, let changes):
            windowsSeen.note(w)
            if changes.contains(.title) {
                lastWindowChange = Date()
                say("TWI window \(w.id) title \"\(w.title)\"")
            }
        case .windowRemoved(let w):
            appWindows.removeAll { $0 == w.id }
            lastWindowChange = Date()
            say("TWI window \(w.id) removed")
        default: break
        }
    }
    session.onThinwireInit = { info in
        say("Thinwire INIT \(info.width)x\(info.height)")
        if let gap = logon.thinwireInit() { say(logon.isFresh ? "fresh logon (Thinwire INIT after \(Int(gap)) s)" : "reconnect pattern (Thinwire INIT)") }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        case .wd(.failure(let text)): say("WD failure: \(text)")
        default: break
        }
    }

    try await session.start()
    let start = Date()
    let gotReady = await waitFor(session, 90) { ready }
    say(gotReady ? "clipboard channel ready" : "clipboard channel NOT ready after 90 s")
    let isApp: (UInt32) -> Bool = { id in
        if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == kind.executable }
        let key = windowsSeen.appKey(id)?.lowercased() ?? ""
        return key.contains(kind.executable.replacingOccurrences(of: ".exe", with: "")) || key == "app:" + kind.resource.lowercased()
    }
    let mainWindow: () -> UInt32? = { appWindows.first { isApp($0) && !(seamless.model.windows[$0]?.title.isEmpty ?? true) } }
    _ = await waitFor(session, max(5, 180 - Date().timeIntervalSince(start))) { logon.isFresh && mainWindow() != nil }
    // Word shows a splash first: wait until windows and titles have been quiet for 6 s (at most 60 s more).
    _ = await waitFor(session, 60) { Date().timeIntervalSince(lastWindowChange) >= 6 }
    let fresh = await onSession(session) { logon.isFresh }
    var target = await onSession(session) { mainWindow() }

    var shot = 0
    var steps: [String] = []
    func note(_ line: String) { steps.append(line); say(line) }
    func captioned() async -> [UInt32: String] {
        await onSession(session) { seamless.model.windows.filter { $0.value.kind == .appWindow }.mapValues(\.title) }
    }
    func title() async -> String { await onSession(session) { target.flatMap { seamless.model.windows[$0]?.title } ?? "" } }
    func screenshot(_ label: String, window: UInt32? = nil) async {
        guard let id = window ?? target else { return }
        shot += 1
        say("[\(label)] " + (await audioTestScreenshot(session, target: id, index: shot, file: "cliptest-rich-\(runID)", dir: outDir)))
    }
    func keys(_ sequence: String, wait: Double = 1.5) async throws {
        let parsed = try AudioTestKeys.parse(sequence, keyboardLayout: layout)
        say("keys: \(sequence)")
        for step in parsed {
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
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        await screenshot(sequence)
    }
    /// Only the app's main window may be open; anything else stops the input (with a screenshot of it).
    func onlyMainWindow(_ when: String) async -> Bool {
        let windows = await captioned()
        let extra = windows.filter { $0.key != target }
        guard extra.isEmpty, let target, windows[target] != nil else {
            note("STOP (\(when)): windows " + windows.map { "\($0.key) \"\($0.value)\"" }.sorted().joined(separator: ", ")
                 + (target.map { windows[$0] == nil ? " (window \($0) is gone)" : "" } ?? " (no main window)") + "; no further input")
            for id in extra.keys.sorted() { await screenshot("extra window \(id)", window: id) }
            return false
        }
        return true
    }
    func isDocumentTitle(_ t: String) -> Bool {
        switch kind {
        case .image: return t.lowercased().contains("paint")
        case .html, .rtf:
            let l = t.lowercased()
            return l.hasSuffix(" - word") && (l.contains("dokument") || l.contains("document"))
        }
    }

    var pasteOK = false, copyOK = false
    if !fresh {
        note("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !gotReady || target == nil {
        note("no \(kind.resource) window or no clipboard channel: no input is sent")
    } else if let main = target {
        session.send { _, twi in twi.activate(windowId: main) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let first = await title()
        await screenshot("start, title \"\(first)\"")
        var atDocument = false
        if await onlyMainWindow("start") {
            // Optional keys chosen after looking at an earlier run's screenshot (e.g. a known first-run screen).
            if let extra = env["ICA_CLIPRICH_START_KEYS"], !extra.isEmpty {
                note("start keys from ICA_CLIPRICH_START_KEYS: \(extra)")
                try await keys(extra, wait: 3)
            }
            var t = await title()
            if !isDocumentTitle(t), kind != .image, t.lowercased() == "word" {
                note("title \"Word\" (start screen): Esc for a blank document")
                try await keys("esc", wait: 4)
                t = await title()
            }
            if !isDocumentTitle(t) {
                note("STOP: title \"\(t)\" is not a blank \(kind == .image ? "Paint canvas" : "Word document"); no further input")
            } else if await onlyMainWindow("document") {
                atDocument = true
                note("document window \(main) \"\(t)\"")
            }
        }
        if atDocument {
            // 1. Mac → session.
            await onSession(session) { requests = [] }
            say("(a) announcing \(content.summary), then Ctrl+V")
            session.clipboardAnnounce(ClipboardSnapshot(content: content))
            try await Task.sleep(nanoseconds: 500_000_000)
            let format = await onSession(session) { sentFormat() }
            try await keys("ctrl+v", wait: 0.5)
            _ = await waitFor(session, 12) { requests.contains { $0.format == format && $0.served } }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            await screenshot("after paste")
            let reqs = await onSession(session) { requests }
            let lines = reqs.map { String(format: "%@ %@ %d B at %.1f s", clip.label($0.format), $0.served ? "served" : "failed", $0.bytes, $0.at) }
            note("paste: host requests [\(lines.joined(separator: "; "))]")
            pasteOK = reqs.contains { $0.format == format && $0.served }
            note("paste: host fetched the announced \(format.map { clip.label($0) } ?? "?"): \(pasteOK)")

            // 2. Session → Mac.
            if await onlyMainWindow("after paste") {
                await onSession(session) { hostContent = nil; fetchFailures = [] }
                if kind == .image {
                    // The pasted image is still the selection: Ctrl+C copies exactly it.
                    try await keys("ctrl+c", wait: 0.5)
                } else {
                    try await keys("ctrl+a", wait: 0.5)
                    try await keys("ctrl+c", wait: 0.5)
                }
                _ = await waitFor(session, 20) { hostContent != nil }
                let (got, list, failures) = await onSession(session) { (hostContent, hostFormatList, fetchFailures) }
                note("copy: host list [\(list.map { clip.label($0) }.joined(separator: ", "))]")
                if !failures.isEmpty { note("copy: fetch failures: \(failures.joined(separator: "; "))") }
                if let got {
                    note("copy: received \(got.summary)")
                    let textHas = got.text?.contains(marker) ?? false
                    switch kind {
                    case .html:
                        let h = got.html ?? ""
                        try? Data(h.utf8).write(to: outDir.appendingPathComponent("cliptest-rich-\(runID)-received.html"))
                        let bold = h.range(of: "<b>", options: .caseInsensitive) != nil || h.range(of: "font-weight:bold", options: .caseInsensitive) != nil
                            || h.range(of: "<strong", options: .caseInsensitive) != nil
                        note("copy: HTML \(got.html == nil ? "MISSING" : "\(h.utf8.count) B"), marker in HTML: \(h.contains(marker)), bold markup: \(bold), "
                             + "table: \(h.range(of: "<table", options: .caseInsensitive) != nil); marker in text: \(textHas)")
                        copyOK = h.contains(marker)
                    case .rtf:
                        let r = got.rtf ?? Data()
                        try? r.write(to: outDir.appendingPathComponent("cliptest-rich-\(runID)-received.rtf"))
                        let s = String(decoding: r, as: UTF8.self)
                        note("copy: RTF \(got.rtf == nil ? "MISSING" : "\(r.count) B"), starts {\\rtf: \(s.hasPrefix("{\\rtf")), marker in RTF: \(s.contains(marker)), "
                             + "\\b: \(s.contains("\\b")); marker in text: \(textHas)")
                        // The Mac side reads it back as an attributed string (what Mac apps do with public.rtf).
                        if let a = try? NSAttributedString(data: r, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                            note("copy: RTF parses on the Mac (\(a.length) characters), marker in its text: \(a.string.contains(marker))")
                        } else {
                            note("copy: RTF does NOT parse on the Mac")
                        }
                        copyOK = s.contains(marker)
                    case .image:
                        if let image = got.image, let rgba = image.rgba(), let original {
                            if let cg = RichClipImage.cgImage(width: image.width, height: image.height, rgba: rgba), let png = RichClipImage.png(cg) {
                                try? png.write(to: outDir.appendingPathComponent("cliptest-rich-\(runID)-received.png"))
                            }
                            let sameSize = image.width == original.width && image.height == original.height
                            note("copy: image \(image.width)x\(image.height) (sent \(original.width)x\(original.height))")
                            if sameSize {
                                let d = RichClipImage.compare(original.rgba, rgba, count: image.width * image.height)
                                note("copy: pixels: max channel delta \(d.maxDelta), \(d.mismatched)/\(d.total) differ by more than 2, alpha≠255: \(d.alphaNot255)")
                                copyOK = d.mismatched == 0
                            }
                        } else {
                            note("copy: no image in the host data")
                        }
                    }
                } else {
                    note("copy: no host clipboard data within 20 s")
                }
            }
        }
    }

    // End: log off only this run's fresh session (the unsaved document or canvas is discarded); else disconnect.
    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            say("→ TWI LOGOFF")
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            target = await onSession(session) { mainWindow() }
            await screenshot("logoff did not finish")
            let windows = await captioned()
            say("logoff did not end the session in 40 s; windows " + windows.map { "\($0.key) \"\($0.value)\"" }.sorted().joined(separator: ", "))
            await session.close()
            ending = sent ? "logoff sent but the session did not end; disconnected (log it off with icactl sessions logoff)" : "TWI not ready; disconnected"
        }
    }
    let version = await onSession(session) { clip.version }
    say("\n=== cliptest-rich \(kind.rawValue) summary (run \(runID)) ===")
    say("clipboard ready: \(gotReady), version \(version), fresh logon: \(fresh), protocol errors: \(protocolErrors)")
    for step in steps { say("  " + step) }
    say("Mac → session: \(pasteOK), session → Mac: \(copyOK)")
    if let url = trace.url { say("trace: \(url.path)") }
    say("end: \(ending)")
    let pass = fresh && pasteOK && copyOK && ending.hasPrefix("logged off")
    say("RESULT: \(pass ? "PASS" : "FAIL") cliptest-rich \(kind.rawValue) run \(runID): fresh \(fresh), Mac → session \(pasteOK), "
        + "session → Mac \(copyOK), end: \(ending)")
}
