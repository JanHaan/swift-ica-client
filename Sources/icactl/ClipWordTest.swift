import AppKit
import CoreGraphics
import Foundation
import ICAKit

// MARK: - Rich text with an image into Word and back (D96, docs/70 §4.9, §10.4)

/// `icactl cliptest-word [case,…]`: "Microsoft Word ABC" only (approved D96). One fresh logon, one new blank document,
/// input limited to the keys that leave the start screen (Esc, else Ctrl+N), Ctrl+A, Ctrl+V and Ctrl+C. For each case:
/// Ctrl+A (so the paste replaces what is there), announce the case's Mac clipboard, Ctrl+V, Ctrl+A, Ctrl+C, compare what
/// Word puts on the clipboard. Nothing is saved: the session is logged off with the document unsaved (the logoff
/// discards it). The headless engine plays the Mac side; the pasteboard mapping is covered by unit tests.
enum WordClipCase: String, CaseIterable {
    /// Plain text (sanity).
    case text
    /// RTF with bold and a colour.
    case rtf
    /// RTFD with a 64×64 PNG and a line of text, as TextEdit puts it on the pasteboard (text + RTF without the picture +
    /// RTFD); the engine serves RTF with `\pict\pngblip`.
    case image
    /// Informational: CF_HTML with the image as a data URI `<img>` (does Word take it?). Never fails the run.
    case htmlImage = "html-image"

    static let resource = "Microsoft Word ABC"
    static let executable = "winword.exe"
    /// Counts for pass/fail (html-image is informational).
    var required: Bool { self != .htmlImage }
}

/// The synthetic picture: 64×64, one colour.
enum WordClipImage {
    static let side = 64
    static let colour: (UInt8, UInt8, UInt8) = (20, 110, 200)

    static func png() -> Data? {
        var px = [UInt8]()
        px.reserveCapacity(side * side * 4)
        for _ in 0..<(side * side) { px += [colour.0, colour.1, colour.2, 255] }
        return ClipboardRichText.png(width: side, height: side, rgba: Data(px))
    }

    /// Size and colour check of returned image bytes (PNG/JPEG; Word may re-encode, so a small tolerance).
    static func check(_ data: Data) -> (ok: Bool, detail: String) {
        guard let image = ClipboardRichText.decodeImage(data), let rgba = image.rgba() else { return (false, "not decodable") }
        let bytes = [UInt8](rgba)
        let centre = ((image.height / 2) * image.width + image.width / 2) * 4
        guard centre + 2 < bytes.count else { return (false, "empty") }
        let c = (Int(bytes[centre]), Int(bytes[centre + 1]), Int(bytes[centre + 2]))
        let delta = max(abs(c.0 - Int(colour.0)), abs(c.1 - Int(colour.1)), abs(c.2 - Int(colour.2)))
        let sizeOK = image.width == side && image.height == side
        return (sizeOK && delta <= 12, "\(image.width)x\(image.height), centre rgb(\(c.0),\(c.1),\(c.2)) Δ\(delta)")
    }
}

func runClipWordTest(ica: ICAFile, cases: [WordClipCase]) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let runID = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    var clipConfig = clipTestConfig()
    clipConfig.traceWire = env["ICA_CLIP_TRACE"] != "0"
    let trace = ClipTrace(enabled: clipConfig.traceWire, name: "cliptest-word", runID: runID)
    let outDir = sessionDir.appendingPathComponent("clipfiles")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    say("run \(runID): cliptest-word in \"\(WordClipCase.resource)\", cases \(cases.map(\.rawValue).joined(separator: ","))")

    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let layout = config.logon.keyboardLayout
    let session = try ICASession(ica: ica, configuration: config, clipboard: clipConfig)
    guard let clip = session.clipboard else { fail("no clipboard engine") }
    let seamless = session.seamless

    // Session-queue state.
    var logon = FreshLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var lastWindowChange = Date()
    var ready = false
    var requests: [(format: UInt16, served: Bool, bytes: Int)] = []
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
            say("clip: FORMAT_NAMES \(entries.count) entries")
            return
        default: break
        }
        say("clip: \(event)")
        switch event {
        case .ready: ready = true
        case .hostRequest(let format, let served, let bytes): requests.append((format, served, bytes))
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
    let isWord: (UInt32) -> Bool = { id in
        if let exe = windowsSeen.single(id, seamless.model) { return GuardedLogoff.basename(exe) == WordClipCase.executable }
        let key = windowsSeen.appKey(id)?.lowercased() ?? ""
        return key.contains("winword") || key == "app:" + WordClipCase.resource.lowercased()
    }
    let mainWindow: () -> UInt32? = { appWindows.first { isWord($0) && !(seamless.model.windows[$0]?.title.isEmpty ?? true) } }
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
        say("[\(label)] " + (await audioTestScreenshot(session, target: id, index: shot, file: "cliptest-word-\(runID)", dir: outDir)))
    }
    func keys(_ sequence: String, wait: Double = 1.0, shoot: Bool = false) async throws {
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
        if shoot { await screenshot(sequence) }
    }
    /// Only Word's main window may be open; anything else stops the input (with a screenshot of it).
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
        let l = t.lowercased()
        return l.contains("word") && (l.contains("dokument") || l.contains("document"))
    }

    // Per-case results.
    var results: [(name: String, required: Bool, pass: Bool, detail: String)] = []
    func record(_ c: WordClipCase, _ pass: Bool, _ detail: String) {
        results.append((c.rawValue, c.required, pass, detail))
        note("CASE \(c.rawValue): \(c.required ? (pass ? "PASS" : "FAIL") : (pass ? "YES" : "NO")) — \(detail)")
    }

    var atDocument = false
    if !fresh {
        note("not a fresh logon by this run: no input is sent (this may be an existing session)")
    } else if !gotReady || target == nil {
        note("no \(WordClipCase.resource) window or no clipboard channel: no input is sent")
    } else if let main = target {
        session.send { _, twi in twi.activate(windowId: main) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await screenshot("start, title \"\(await title())\"")
        if await onlyMainWindow("start") {
            // The start screen (title "Word"): Esc opens the blank document; if not, Ctrl+N.
            var t = await title()
            note("start: title \"\(t)\"")
            if !isDocumentTitle(t) {
                note("not a document yet: Esc")
                try await keys("esc", wait: 4, shoot: true)
                t = await title()
                note("after Esc: title \"\(t)\"")
            }
            if !isDocumentTitle(t), await onlyMainWindow("after esc") {
                note("still not a document: Ctrl+N")
                try await keys("ctrl+n", wait: 6, shoot: true)
                // Ctrl+N may open the document in a new window: take the Word window with a document title.
                let windows = await captioned()
                if let doc = windows.first(where: { isDocumentTitle($0.value) })?.key, await onSession(session, { isWord(doc) }) {
                    target = doc
                    session.send { _, twi in twi.activate(windowId: doc) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                t = await title()
                note("after Ctrl+N: title \"\(t)\"")
            }
            if !isDocumentTitle(t) {
                note("STOP: title \"\(t)\" is not a blank Word document; no further input")
            } else if await onlyMainWindow("document") {
                atDocument = true
                note("document window \(target ?? 0) \"\(t)\"")
            }
        }
    }

    let png = WordClipImage.png()
    if let png { try? png.write(to: outDir.appendingPathComponent("cliptest-word-\(runID)-sent.png")) }
    caseLoop: for c in cases where atDocument {
        let marker = "ICAW\(c.rawValue.prefix(1).uppercased())\(runID)"
        let red = "ICARED\(runID)"
        var content: ClipboardContent
        var format: UInt16?
        switch c {
        case .text:
            content = ClipboardContent(text: "\(marker) plain text")
            format = ClipboardFormat.unicodeText
        case .rtf:
            let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}{\\colortbl;\\red192\\green0\\blue0;}"
                + "\\f0\\fs28 \\b \(marker)\\b0  normal \\cf1 \(red)\\cf0\\par}"
            content = ClipboardContent(rtf: Data(rtf.utf8))
            format = await onSession(session) { clip.registeredId(ClipboardFormat.rtfName) }
        case .image:
            guard let png else { record(c, false, "cannot build the test PNG"); continue caseLoop }
            // As TextEdit: text, AppKit's RTF (no picture) and the RTFD with the attachment.
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "image.png"
            let s = NSMutableAttributedString(string: "\(marker) image line ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            s.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            s.append(NSAttributedString(string: " after\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            let range = NSRange(location: 0, length: s.length)
            guard let rtfd = s.rtfd(from: range, documentAttributes: [:]), let rtf = s.rtf(from: range, documentAttributes: [:]) else {
                record(c, false, "cannot build the test RTFD"); continue caseLoop
            }
            try? rtfd.write(to: outDir.appendingPathComponent("cliptest-word-\(runID)-sent.rtfd.flat"))
            content = ClipboardContent(text: s.string, rtf: rtf, rtfd: rtfd)
            format = await onSession(session) { clip.registeredId(ClipboardFormat.rtfName) }
        case .htmlImage:
            guard let png else { record(c, false, "cannot build the test PNG"); continue caseLoop }
            let html = "<p><b>\(marker)</b> html image</p><p><img width=\"64\" height=\"64\" src=\"data:image/png;base64,\(png.base64EncodedString())\"></p>"
            content = ClipboardContent(html: html)
            format = await onSession(session) { clip.registeredId(ClipboardFormat.htmlName) }
        }
        guard await onlyMainWindow("before \(c.rawValue)") else { break caseLoop }

        // Mac → Word.
        try await keys("ctrl+a", wait: 0.5)
        await onSession(session) { requests = [] }
        say("(\(c.rawValue)) announcing \(content.summary), then Ctrl+V")
        session.clipboardAnnounce(ClipboardSnapshot(content: content))
        try await Task.sleep(nanoseconds: 700_000_000)
        try await keys("ctrl+v", wait: 0.5)
        _ = await waitFor(session, 15) { requests.contains { $0.format == format && $0.served } }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        await screenshot("\(c.rawValue) after paste")
        let reqs = await onSession(session) { requests }
        note("\(c.rawValue) paste: host requests [" + reqs.map { "\(clip.label($0.format)) \($0.served ? "served" : "failed") \($0.bytes) B" }.joined(separator: "; ") + "]")
        let pasted = reqs.contains { $0.format == format && $0.served }
        guard await onlyMainWindow("after \(c.rawValue) paste") else {
            record(c, false, "a window appeared after the paste")
            break caseLoop
        }

        // Word → Mac.
        await onSession(session) { hostContent = nil; fetchFailures = [] }
        try await keys("ctrl+a", wait: 0.5)
        try await keys("ctrl+c", wait: 0.5)
        _ = await waitFor(session, 25) { hostContent != nil }
        let (got, list, failures) = await onSession(session) { (hostContent, hostFormatList, fetchFailures) }
        note("\(c.rawValue) copy: host list [\(list.map { clip.label($0) }.joined(separator: ", "))]")
        if !failures.isEmpty { note("\(c.rawValue) copy: fetch failures: \(failures.joined(separator: "; "))") }
        guard let got else {
            record(c, false, "pasted: \(pasted); no host clipboard data within 25 s")
            continue caseLoop
        }
        note("\(c.rawValue) copy: received \(got.summary)")
        let base = outDir.appendingPathComponent("cliptest-word-\(runID)-\(c.rawValue)-received")
        if let r = got.rtf { try? r.write(to: base.appendingPathExtension("rtf")) }
        if let h = got.html { try? Data(h.utf8).write(to: base.appendingPathExtension("html")) }
        if let d = got.rtfd { try? d.write(to: base.appendingPathExtension("rtfd.flat")) }
        let textHas = got.text?.contains(marker) ?? false
        let rtfString = got.rtf.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let attributed = got.rtf.flatMap {
            try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        let pictures = got.rtf.map(ClipboardRichText.pictures(in:)) ?? []
        if !pictures.isEmpty {
            note("\(c.rawValue) copy: RTF pictures " + pictures.map { p in
                "\(p.kind.rawValue) \(p.data.count) B" + (p.pixelSize.map { " \($0.width)x\($0.height) px" } ?? "")
                    + " picw \(p.picw.map(String.init) ?? "-") goal \(p.widthTwips.map(String.init) ?? "-")x\(p.heightTwips.map(String.init) ?? "-") tw"
            }.joined(separator: "; "))
        }
        /// The returned RTF picture (PNG/JPEG/DIB) that matches the sent one, and the RTFD attachment check.
        func imageChecks() -> (rtf: Bool, rtfd: Bool, detail: String) {
            var parts: [String] = []
            var rtfOK = false
            for p in pictures {
                guard let image = p.macImage else { continue }
                let check = WordClipImage.check(image.data)
                parts.append("RTF \(p.kind.rawValue) \(check.detail)")
                if check.ok { rtfOK = true }
            }
            var rtfdOK = false
            if let flat = got.rtfd,
               let a = try? NSAttributedString(data: flat, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
                var images: [Data] = []
                a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length)) { v, _, _ in
                    if let d = (v as? NSTextAttachment)?.fileWrapper?.regularFileContents { images.append(d) }
                }
                let checks = images.map(WordClipImage.check)
                rtfdOK = checks.contains { $0.ok } && a.string.contains(marker)
                parts.append("RTFD (Mac side) \(images.count) attachment(s) [\(checks.map(\.detail).joined(separator: "; "))], marker in its text: \(a.string.contains(marker))")
            } else {
                parts.append(got.rtfd == nil ? "no RTFD made" : "RTFD does not parse")
            }
            let html = got.html ?? ""
            parts.append("HTML <img>: \(html.range(of: "<img", options: .caseInsensitive) != nil)")
            return (rtfOK, rtfdOK, parts.joined(separator: ", "))
        }

        switch c {
        case .text:
            record(c, pasted && textHas, "pasted \(pasted), marker in returned text \(textHas)")
        case .rtf:
            var bold = false, colour = false
            if let a = attributed, let b = a.string.range(of: marker), let r = a.string.range(of: red) {
                let bi = NSRange(b, in: a.string).location, ri = NSRange(r, in: a.string).location
                if let font = a.attribute(.font, at: bi, effectiveRange: nil) as? NSFont {
                    bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
                }
                if let col = (a.attribute(.foregroundColor, at: ri, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB) {
                    colour = col.redComponent > 0.6 && col.greenComponent < 0.2 && col.blueComponent < 0.2
                }
            }
            let html = got.html ?? ""
            let htmlBold = html.range(of: "<b>", options: .caseInsensitive) != nil || html.range(of: "font-weight:bold", options: .caseInsensitive) != nil
                || html.range(of: "<strong", options: .caseInsensitive) != nil
            let htmlColour = html.range(of: "C00000", options: .caseInsensitive) != nil
            let markers = rtfString.contains(marker) && rtfString.contains(red)
            record(c, pasted && markers && bold && colour,
                   "pasted \(pasted), markers in RTF \(markers), RTF bold \(bold), RTF red \(colour), colour table red: \(rtfString.contains("\\red192\\green0\\blue0")); "
                   + "HTML bold \(htmlBold), HTML #C00000 \(htmlColour); marker in text \(textHas)")
        case .image:
            let served = reqs.first { $0.format == format && $0.served }
            let sentPict = served != nil
            let (rtfOK, rtfdOK, detail) = imageChecks()
            record(c, pasted && sentPict && rtfOK && rtfdOK && rtfString.contains(marker),
                   "pasted \(pasted) (RTF \(served?.bytes ?? 0) B with \\pict), marker in RTF \(rtfString.contains(marker)); image back in RTF \(rtfOK), as RTFD \(rtfdOK); \(detail)")
        case .htmlImage:
            // Counts only if this paste happened: the document otherwise still holds the previous case's image.
            let (rtfOK, _, detail) = imageChecks()
            let took = pasted && rtfOK && rtfString.contains(marker)
            record(c, took, "host fetched \"HTML Format\": \(pasted); data-URI image in Word: \(took)"
                   + (pasted ? "; \(detail)" : " (nothing pasted; the document keeps the previous case)"))
        }
    }
    if atDocument { await screenshot("end") }

    // End: log off this run's fresh session (the unsaved document is discarded); else disconnect.
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
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            target = await onSession(session) { mainWindow() }
            await screenshot("logoff did not finish")
            let windows = await captioned()
            say("logoff did not end the session in 45 s; windows " + windows.map { "\($0.key) \"\($0.value)\"" }.sorted().joined(separator: ", "))
            await session.close()
            ending = sent ? "logoff sent but the session did not end; disconnected (log it off with icactl sessions logoff)" : "TWI not ready; disconnected"
        }
    }
    let version = await onSession(session) { clip.version }
    say("\n=== cliptest-word summary (run \(runID)) ===")
    say("clipboard ready: \(gotReady), version \(version), fresh logon: \(fresh), protocol errors: \(protocolErrors)")
    for step in steps { say("  " + step) }
    if let url = trace.url { say("trace: \(url.path)") }
    say("end: \(ending)")
    let loggedOff = ending.hasPrefix("logged off")
    let required = cases.filter(\.required)
    let missing = required.filter { c in !results.contains { $0.name == c.rawValue } }
    let failed = results.filter { $0.required && !$0.pass }.map(\.name) + missing.map(\.rawValue)
    let pass = fresh && loggedOff && failed.isEmpty && protocolErrors == 0
    say("RESULT: \(pass ? "PASS" : "FAIL") cliptest-word run \(runID): fresh \(fresh), "
        + results.map { "\($0.name)=\($0.required ? ($0.pass ? "pass" : "fail") : ($0.pass ? "yes" : "no"))" }.joined(separator: " ")
        + (missing.isEmpty ? "" : " not run: \(missing.map(\.rawValue).joined(separator: ","))")
        + ", end: \(ending)")
}
