import AppKit
import ICAKit

// File copy through the clipboard, both ways (docs/75 §6–§7, D90). The bytes travel over CTXGDT (docs/76 §7.17);
// CTXCLIP (version 4) carries only the format lists.
//
// - Mac → session: `SystemPasteboard` turns Finder's file URLs into a `ClipboardFileSnapshot` (folders walked, names
//   made Windows-safe, files read later by path); CTXCLIP announces FileGroupDescriptorW + FileContents and the GDT
//   engine serves the host's GetData / OpenStream / Seek / Read / Release from the snapshot.
// - Session → Mac: a host list with FileGroupDescriptorW fetches only the descriptor (as the stock client does); the
//   pasteboard gets one item per top-level file or folder whose `public.file-url` is promised (`HostFileOffer`). The
//   first time a consumer (Finder's Paste) asks for one, the whole group is fetched over CTXGDT into a staging folder
//   while the main thread waits, bounded, with a progress panel (`ClipboardFilesHUD`).

/// Settings › Clipboard › "Copy files through the clipboard" (D90): on by default, applies at the next connect.
/// `ICA_GDT` overrides it for one run (1 = on, anything else = off); the other `ICA_GDT_*` switches apply either way.
enum ClipboardFilesSetting {
    static let defaultsKey = "clipboardFiles"
    static let defaultOn = true

    static var stored: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultOn }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func enabled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let v = env["ICA_GDT"] { return v == "1" }
        return stored
    }

    /// The CTXGDT module for a new session (nil: none, the channel is not offered).
    static func gdtConfig(_ env: [String: String] = ProcessInfo.processInfo.environment) -> GDTEngine.Config? {
        guard enabled(env) else { return nil }
        var e = env
        e["ICA_GDT"] = "1"
        var config = GDTEngine.Config.fromEnvironment(e)
        config?.historyLimit = 0
        return config
    }

    /// Caps for one paste from the session (docs/75 §6.4): entries, total bytes, the longest main-thread wait.
    static let maxEntries = 1000
    static let maxTotal: UInt64 = 200 << 20
    static func maxWait(total: UInt64) -> TimeInterval { min(180, 30 + Double(total) / Double(1 << 20)) }
}

/// The shared staging area of this process and the quit flag.
enum ClipboardFilesBridge {
    static let staging = ClipboardStagingArea()
    /// Set once the app is quitting: promised files are not fetched any more.
    static var quitting = false

    /// Launch: folders of earlier runs that are gone.
    static func launchCleanup() { staging.removeStale() }

    /// Quit: our promised files leave the pasteboard (their folders go now), then the folders.
    static func quitCleanup() {
        quitting = true
        HostFileOffer.withdraw()
        staging.removeOwn()
    }

    /// One log line per file event, without names or bytes (Read/Seek are left out: one per request).
    static func logLine(_ e: GDTFileEvent) -> String? {
        switch e {
        case .hostGetData(_, _, let served): return "host asks for the file list → " + (served.map { "\($0) B" } ?? "refused (nothing offered)")
        case .hostOpenStream(_, let index, _, let stream, _): return "host opens file \(index.map(String.init) ?? "?") → " + (stream == nil ? "refused" : "ok")
        case .servedFile(let i, _, let n): return "file \(i) served (\(n) B)"
        case .serveFailed(let i, let why): return "serving file \(i) failed: \(why)"
        case .hostSeek, .hostRead, .hostRelease: return nil
        case .fetchStarted: return "→ asking the host for its file list"
        case .fileGroup(let e): return "host file list: \(e.count) entries, \(e.reduce(0) { $0 + $1.size }) B"
        case .receivedFile(let i, _, _, let n): return "received file \(i) (\(n) B)"
        case .fileFailed(let i, let why): return "file \(i) failed: \(why)"
        case .fetchFailed(let why): return "fetch failed: \(why)"
        case .fetchDone(let n): return "fetch done: \(n) files"
        case .unexpected(let m, let why): return String(format: "unexpected cmd 0x%02x (%@)", m.command, why)
        }
    }
}

/// The host's file group on the Mac pasteboard: one item per top-level file or folder, each promising
/// `public.file-url`. Nothing moves until a consumer asks; then the group is fetched once into a new staging folder
/// and every item's URL points into it. The current offer is kept alive here while the pasteboard may call it.
final class HostFileOffer: NSObject, NSPasteboardItemDataProvider {
    /// Marks our promised items: never read back as Mac files (that would fetch them just to offer them back).
    static let markerType = NSPasteboard.PasteboardType("local.alttab.ICAViewer.session-files")
    private(set) static var current: HostFileOffer?

    let plan: ClipboardStagingPlan
    let entries: [ClipboardFileEntry]
    /// Starts the fetch into the wait's folder on the session queue; false when the session cannot.
    private let start: (ClipboardFileWait) -> Bool
    private let usable: () -> Bool
    private let id = UUID().uuidString
    private var items: [NSPasteboardItem] = []
    private(set) var wait: ClipboardFileWait?
    private var invalid = false
    private var changeCount: Int?

    init(plan: ClipboardStagingPlan, entries: [ClipboardFileEntry], usable: @escaping () -> Bool, start: @escaping (ClipboardFileWait) -> Bool) {
        self.plan = plan
        self.entries = entries
        self.usable = usable
        self.start = start
    }

    /// Replaces the general pasteboard's contents with this offer; returns the change count.
    func write(to board: NSPasteboard = .general) -> Int {
        Self.current?.invalidate()
        board.clearContents()
        items = plan.items.map { _ in
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: [.fileURL])
            item.setString(id, forType: Self.markerType)
            return item
        }
        board.writeObjects(items)
        Self.current = self
        changeCount = board.changeCount
        return board.changeCount
    }

    func invalidate() {
        invalid = true
        wait?.update(.failed("replaced"))
    }

    /// The session ended: a transfer in progress stops at once; nothing can be fetched any more.
    func sessionEnded() {
        invalid = true
        if let wait, !wait.isFinished { wait.update(.failed("the session ended")) }
    }

    /// At quit: if the pasteboard still holds our items, they go (their files are removed with the folders).
    static func withdraw() {
        guard let offer = current else { return }
        offer.invalid = true
        if NSPasteboard.general.changeCount == offer.changeCount { NSPasteboard.general.clearContents() }
        offer.items = []
        current = nil
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        invalid = true
        // The items may hold their provider: let both go.
        items = []
        if Self.current === self { Self.current = nil }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL, let k = items.firstIndex(where: { $0 === item }) else { return }
        guard !invalid, !ClipboardFilesBridge.quitting, usable() else {
            return vlog("clipboard files: item \(k) asked for, but the session's files are gone (session ended or replaced)")
        }
        let w: ClipboardFileWait
        if let existing = wait {
            w = existing
        } else {
            if let free = (try? ClipboardFilesBridge.staging.base.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
               free < Int64(plan.totalBytes) + (1 << 30) {
                vlog("clipboard files: not enough free disk space (\(free >> 20) MB free, \(plan.totalBytes >> 20) MB + 1 GB needed)")
                return ClipboardFilesHUD.shared.notice(loc("Not enough free disk space for the files from the session.",
                                                           "Nicht genug freier Speicher für die Dateien aus der Sitzung."))
            }
            let folder: URL
            do { folder = try ClipboardFilesBridge.staging.newFolder(for: plan) } catch {
                vlog("clipboard files: staging folder: \(error)")
                return ClipboardFilesHUD.shared.notice(loc("The files from the session could not be stored.",
                                                           "Die Dateien aus der Sitzung konnten nicht gespeichert werden."))
            }
            w = ClipboardFileWait(plan: plan, folder: folder, deadline: Date().addingTimeInterval(ClipboardFilesSetting.maxWait(total: plan.totalBytes)))
            wait = w
            guard start(w) else {
                w.update(.failed("the session cannot fetch files now"))
                vlog("clipboard files: the session cannot fetch files now")
                return ClipboardFilesHUD.shared.notice(loc("The files are no longer available in the session.",
                                                           "Die Dateien sind in der Sitzung nicht mehr verfügbar."))
            }
            vlog("clipboard files: paste asked for item \(k): fetching \(plan.files.count) files (\(plan.totalBytes) B) from the session")
        }
        let hud = ClipboardFilesHUD.shared
        let started = Date()
        let outcome = w.wait(item: k) {
            // Shown only for a wait that lasts; the main thread is blocked, so the panel is drawn by hand.
            guard Date().timeIntervalSince(started) > 0.3 else { return }
            let p = w.progress
            hud.showProgress(bytes: p.bytes, total: p.total)
        }
        switch outcome {
        case .ready(let url):
            item.setString(url.absoluteString, forType: .fileURL)
        case .partial(let url, let failed):
            item.setString(url.absoluteString, forType: .fileURL)
            vlog("clipboard files: item \(k) delivered with \(failed) missing files")
            hud.notice(loc("\(failed) files could not be copied from the session.", "\(failed) Dateien konnten nicht aus der Sitzung kopiert werden."))
        case .failed(let why):
            vlog("clipboard files: item \(k) not delivered: \(why)")
            hud.notice(loc("Copying files from the session failed.", "Das Kopieren der Dateien aus der Sitzung ist fehlgeschlagen."))
        case .timedOut:
            vlog("clipboard files: item \(k) not delivered: no complete transfer within \(Int(w.deadline.timeIntervalSince(started))) s")
            hud.notice(loc("Copying files from the session took too long.", "Das Kopieren der Dateien aus der Sitzung hat zu lange gedauert."))
        }
        if w.isFinished || outcome == .timedOut { hud.hideProgress() }
    }
}

/// The session's side of the file bridge (main thread): the host's file groups become `HostFileOffer`s; the Mac's
/// snapshot is remembered so an echo of it from the host is not offered back.
final class HostFilesBridge {
    private let session: ICASession
    private let gdt: GDTEngine
    private weak var sync: ClipboardSync?
    private let isEnded: () -> Bool
    private var offer: HostFileOffer?
    /// The files the Mac last offered to the host, and the pasteboard change they came from.
    private var lastOffered: (entries: [ClipboardFileEntry], changeCount: Int)?

    init(session: ICASession, gdt: GDTEngine, sync: ClipboardSync, isEnded: @escaping () -> Bool) {
        self.session = session
        self.gdt = gdt
        self.sync = sync
        self.isEnded = isEnded
    }

    /// From `SystemPasteboard` when it read Mac files (main thread).
    func macSnapshot(_ snapshot: ClipboardFileSnapshot, changeCount: Int) {
        lastOffered = snapshot.refused == nil && !snapshot.files.isEmpty ? (snapshot.entries, changeCount) : nil
        if let refused = snapshot.refused {
            vlog("clipboard files: Mac files not offered: \(refused)")
            ClipboardFilesHUD.shared.notice(loc("Too many files to copy through the clipboard (\(refused)).",
                                                "Zu viele Dateien für die Zwischenablage (\(Self.german(refused)))."))
        } else if !snapshot.skipped.isEmpty {
            vlog("clipboard files: \(snapshot.skipped.count) Mac items left out: " +
                 Dictionary(grouping: snapshot.skipped, by: \.why).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", "))
            ClipboardFilesHUD.shared.notice(loc("\(snapshot.skipped.count) items are not copied to the session (links or unreadable).",
                                                "\(snapshot.skipped.count) Objekte werden nicht in die Sitzung kopiert (Verweise oder nicht lesbar)."))
        }
        if !snapshot.files.isEmpty {
            vlog("clipboard files: Mac files offered: \(snapshot.files.count) entries, \(snapshot.totalBytes) B")
        }
    }

    private static func german(_ r: ClipboardFileSnapshot.Refusal) -> String {
        switch r {
        case .tooMany(let n): return "mehr als \(n) Dateien und Ordner"
        case .tooLarge(let n): return "mehr als \(n >> 20) MB"
        }
    }

    /// Session queue: the host list has a file group; only its descriptor is fetched now.
    static func hostListed(format: UInt16, gdt: GDTEngine, deliver: @escaping ([ClipboardFileEntry]) -> Void) {
        gdt.files.fetch(.descriptor, systemFormat: UInt32(format)) { update in
            switch update {
            case .group(let entries): DispatchQueue.main.async { deliver(entries) }
            case .failed(let why): vlog("clipboard files: host file list not read: \(why)")
            default: break
            }
        }
    }

    /// Main thread: the host's descriptor for the list with registered id `format`.
    func hostGroup(_ entries: [ClipboardFileEntry], format: UInt16) {
        guard !isEnded(), let sync else { return }
        if let last = lastOffered, NSPasteboard.general.changeCount == last.changeCount,
           last.entries.count == entries.count, zip(last.entries, entries).allSatisfy({ $0.name == $1.name && $0.size == $1.size }) {
            return vlog("clipboard files: the host's file list is the Mac's own (echo); pasteboard left as it is")
        }
        let plan: ClipboardStagingPlan
        do {
            plan = try ClipboardStagingPlan.make(entries, maxEntries: ClipboardFilesSetting.maxEntries, maxTotal: ClipboardFilesSetting.maxTotal)
        } catch let failure as ClipboardStagingPlan.Failure {
            vlog("clipboard files: host files not offered on the Mac: \(failure)")
            switch failure {
            case .tooLarge, .tooMany:
                ClipboardFilesHUD.shared.notice(loc("The files copied in the session are too large for the clipboard (limit \(ClipboardFilesSetting.maxTotal >> 20) MB, \(ClipboardFilesSetting.maxEntries) items).",
                                                    "Die in der Sitzung kopierten Dateien sind zu groß für die Zwischenablage (Grenze \(ClipboardFilesSetting.maxTotal >> 20) MB, \(ClipboardFilesSetting.maxEntries) Objekte)."))
            default:
                ClipboardFilesHUD.shared.notice(loc("The files copied in the session cannot be offered on the Mac.",
                                                    "Die in der Sitzung kopierten Dateien können auf dem Mac nicht angeboten werden."))
            }
            return
        } catch {
            return vlog("clipboard files: host files not offered on the Mac: \(error)")
        }
        // The next copy: earlier transfer folders of this process go.
        ClipboardFilesBridge.staging.removeOwn()
        let session = self.session, gdt = self.gdt
        let next = HostFileOffer(plan: plan, entries: entries, usable: { [weak self] in self.map { !$0.isEnded() } ?? false }) { wait in
            let targets = wait.targets
            session.perform {
                gdt.files.fetch(.files(targets: targets, expect: entries), systemFormat: UInt32(format)) { update in
                    wait.update(update)
                    switch update {
                    case .done, .failed: DispatchQueue.main.async { if wait.isFinished { ClipboardFilesHUD.shared.hideProgress() } }
                    default: break
                    }
                }
            }
            return true
        }
        let folders = plan.items.filter(\.isDirectory).count
        if sync.hostWrite(summary: "files: \(plan.items.count) items (\(folders) folders), \(plan.files.count) files, \(plan.totalBytes) B, fetched on paste",
                          { next.write() }) {
            offer = next
        }
    }

    /// The session ended (main thread).
    func sessionEnded() {
        offer?.sessionEnded()
        let gdt = self.gdt
        session.perform { gdt.files.offer(nil) }
    }
}

/// A small floating panel for file transfers through the clipboard: progress while a paste waits, and short notices.
/// Borderless, non-activating and outside the window cycle (like ReconnectHUD).
final class ClipboardFilesHUD {
    static let shared = ClipboardFilesHUD()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var hideWork: DispatchWorkItem?
    private var lastNotice: (text: String, at: Date)?
    private var showingProgress = false

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 328
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 328),
        ])
        panel.contentView = effect
    }

    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24, width: size.width, height: size.height), display: true)
    }

    /// While the main thread waits for a paste: drawn and flushed by hand (no run loop turns meanwhile).
    func showProgress(bytes: UInt64, total: UInt64) {
        hideWork?.cancel()
        let mb = { (n: UInt64) in String(format: "%.1f", Double(n) / 1_048_576) }
        label.stringValue = loc("Copying files from the session… \(mb(bytes)) of \(mb(total)) MB",
                                "Dateien werden aus der Sitzung kopiert … \(mb(bytes)) von \(mb(total)) MB")
        bar.isHidden = false
        bar.doubleValue = total > 0 ? Double(bytes) / Double(total) : 0
        if !showingProgress {
            showingProgress = true
            place()
            panel.orderFrontRegardless()
        }
        panel.contentView?.displayIfNeeded()
        panel.display()
        CATransaction.flush()
    }

    func hideProgress() {
        guard showingProgress else { return }
        showingProgress = false
        panel.orderOut(nil)
    }

    /// A short message for a few seconds; the same text again within 3 s (several sessions) is shown once.
    func notice(_ text: String, seconds: TimeInterval = 5) {
        if let last = lastNotice, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
        lastNotice = (text, Date())
        showingProgress = false
        label.stringValue = text
        bar.isHidden = true
        place()
        panel.orderFrontRegardless()
        panel.display()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.showingProgress else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
