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
//   while the main thread waits, bounded, with a progress panel (`ClipboardFilesHUD`). Groups over 50 MB are fetched
//   in the background at copy time instead (`HostFileDownload`, a progress window with Cancel; above the soft limit
//   the user confirms first) and reach the pasteboard as plain file URLs once complete (docs/75 §11.5).

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

    /// Caps for one paste from the session (docs/75 §6.4, §11.5): entries and the longest main-thread wait. There is
    /// no fixed byte cap: the free space decides, and above the soft limit the user is asked.
    static let maxEntries = 1000
    static func maxWait(total: UInt64) -> TimeInterval { min(180, 30 + Double(total) / Double(1 << 20)) }

    /// Settings › Clipboard › "Ask before copying more than": the soft limit in GB (0 = never ask), default 10.
    static let softLimitKey = "clipboardFilesSoftLimitGB"
    static let softLimitChoices = [1, 5, 10, 50, 0]
    static let defaultSoftLimitGB = 10
    static var softLimitGB: Int {
        get { UserDefaults.standard.object(forKey: softLimitKey) as? Int ?? defaultSoftLimitGB }
        set { UserDefaults.standard.set(newValue, forKey: softLimitKey) }
    }

    /// Lazy up to 50 MB (the paste waits), background above, confirm above the soft limit.
    static var policy: ClipboardTransferPolicy {
        let gb = softLimitGB
        return ClipboardTransferPolicy(lazyMax: 50 << 20, softLimit: gb > 0 ? UInt64(gb) * 1_000_000_000 : nil)
    }

    /// Mac → session: the snapshot's total follows the soft limit (no limit: 1 TB); Reads are served from the files in
    /// slices, never whole.
    static var snapshotLimits: ClipboardFileSnapshot.Limits {
        var limits = ClipboardFileSnapshot.Limits()
        let gb = softLimitGB
        limits.maxTotal = gb > 0 ? UInt64(gb) * 1_000_000_000 : 1_000_000_000_000
        return limits
    }

    /// Session → Mac read tuning (session queue): no per-file cap; 1 MiB Reads (1 MiB was read live from a host with
    /// icactl fetch-file, the stock client asks the whole file [B]); 2 Reads in flight (offline-measured, docs/76
    /// §7.17; [H] live). `ICA_GDT_READSIZE` / `ICA_GDT_READAHEAD` override.
    static func tune(_ files: GDTFileTransfer, env: [String: String] = ProcessInfo.processInfo.environment) {
        files.maxFileSize = .max
        files.readSize = env["ICA_GDT_READSIZE"].flatMap(Int.init).flatMap { (1...(16 << 20)).contains($0) ? $0 : nil } ?? 1 << 20
        files.readAhead = env["ICA_GDT_READAHEAD"].flatMap(Int.init).flatMap { (1...8).contains($0) ? $0 : nil } ?? 2
    }
}

/// The shared staging area of this process and the quit flag.
enum ClipboardFilesBridge {
    static let staging = ClipboardStagingArea()
    /// Set once the app is quitting: promised files are not fetched any more.
    static var quitting = false

    /// Free bytes on the staging volume (nil: unknown).
    static func freeSpace() -> Int64? {
        let url = staging.base.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// A background download is running (read on the session queue: host lists then do not cancel it).
    private static let activeLock = NSLock()
    private static var activeFlag = false
    static var downloadActive: Bool {
        get { activeLock.lock(); defer { activeLock.unlock() }; return activeFlag }
        set { activeLock.lock(); activeFlag = newValue; activeLock.unlock() }
    }

    /// Launch: folders of earlier runs that are gone.
    static func launchCleanup() { staging.removeStale() }

    /// Quit: our promised files leave the pasteboard (their folders go now), then the folders.
    static func quitCleanup() {
        quitting = true
        HostFileDownload.current?.cancel(reason: "quit")
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
            let free = ClipboardFilesBridge.freeSpace()
            if !ClipboardTransferPolicy.enoughSpace(free: free, total: plan.totalBytes) {
                vlog("clipboard files: not enough free disk space (\((free ?? 0) >> 20) MB free, \(plan.totalBytes >> 20) MB + 10 % needed)")
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
            plan = try ClipboardStagingPlan.make(entries, maxEntries: ClipboardFilesSetting.maxEntries)
        } catch let failure as ClipboardStagingPlan.Failure {
            vlog("clipboard files: host files not offered on the Mac: \(failure)")
            switch failure {
            case .tooLarge, .tooMany:
                ClipboardFilesHUD.shared.notice(loc("Too many files copied in the session for the clipboard (limit \(ClipboardFilesSetting.maxEntries) items).",
                                                    "Zu viele in der Sitzung kopierte Dateien für die Zwischenablage (Grenze \(ClipboardFilesSetting.maxEntries) Objekte)."))
            default:
                ClipboardFilesHUD.shared.notice(loc("The files copied in the session cannot be offered on the Mac.",
                                                    "Die in der Sitzung kopierten Dateien können auf dem Mac nicht angeboten werden."))
            }
            return
        } catch {
            return vlog("clipboard files: host files not offered on the Mac: \(error)")
        }
        // The same group as the download just published (the host re-sent its list): nothing new.
        if let done = published, done.entries == entries, NSPasteboard.general.changeCount == done.changeCount {
            return vlog("clipboard files: the host's file list is the one already on the pasteboard")
        }
        let decision = ClipboardFilesSetting.policy.decide(total: plan.totalBytes)
        if decision != .lazy {
            return startDownload(plan: plan, entries: entries, format: format, confirm: decision == .confirm)
        }
        // The next copy: earlier transfer folders of this process go.
        HostFileDownload.current?.cancel(reason: "a new copy in the session")
        ClipboardFilesBridge.staging.removeOwn()
        published = nil
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

    /// The last background download that reached the pasteboard (its files stay until the next copy).
    private var published: (entries: [ClipboardFileEntry], changeCount: Int)?
    /// A host list with a file group that came during a download (session queue → main); read after it ends.
    private var deferredFormat: UInt16?

    /// Main thread: a host list with a file group arrived while a download runs; its descriptor is read afterwards.
    func deferHostList(format: UInt16) {
        deferredFormat = format
        vlog("clipboard files: a host file list came during the download; read after it")
    }

    /// A group over the lazy limit: fetched now, in the background, with the progress window.
    private func startDownload(plan: ClipboardStagingPlan, entries: [ClipboardFileEntry], format: UInt16, confirm: Bool) {
        HostFileDownload.current?.cancel(reason: "a new copy in the session")
        // An older lazy offer leaves the pasteboard (a paste of it would replace this fetch); its files go.
        offer?.invalidate()
        offer = nil
        HostFileOffer.withdraw()
        ClipboardFilesBridge.staging.removeOwn()
        published = nil
        let session = self.session, gdt = self.gdt
        let download = HostFileDownload(plan: plan, entries: entries, startCount: NSPasteboard.general.changeCount) { wait in
            ClipboardFilesBridge.downloadActive = true
            let targets = wait.targets
            session.perform {
                gdt.files.fetch(.files(targets: targets, expect: entries), systemFormat: UInt32(format)) { update in
                    wait.update(update)
                }
            }
        } cancelFetch: {
            session.perform { if gdt.files.isFetching { gdt.files.cancelFetch("cancelled on the Mac") } }
        } publish: { [weak self] urls, startCount in
            self?.publish(urls, entries: entries, startCount: startCount) ?? false
        } ended: { [weak self] in
            ClipboardFilesBridge.downloadActive = false
            self?.downloadEnded()
        }
        vlog("clipboard files: \(plan.files.count) files (\(plan.totalBytes) B) over the lazy limit: background download" +
             (confirm ? ", asking first (over the soft limit)" : ""))
        download.begin(confirm: confirm)
    }

    /// The finished download's URLs on the pasteboard, unless the Mac pasteboard changed since the copy began.
    private func publish(_ urls: [URL], entries: [ClipboardFileEntry], startCount: Int) -> Bool {
        guard !isEnded(), let sync else { return false }
        let board = NSPasteboard.general
        guard board.changeCount == startCount || board.changeCount == published?.changeCount else {
            vlog("clipboard files: the Mac clipboard changed during the download: files kept, not put on the clipboard")
            return false
        }
        var after = 0
        let ok = sync.hostWrite(summary: "files: \(urls.count) items, downloaded in the background") {
            board.clearContents()
            let items = urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString("download", forType: HostFileOffer.markerType)
                return item
            }
            board.writeObjects(items)
            after = board.changeCount
            return after
        }
        if ok { published = (entries, after); offer = nil }
        return ok
    }

    private func downloadEnded() {
        guard let format = deferredFormat, !isEnded() else { return }
        deferredFormat = nil
        let gdt = self.gdt
        session.perform {
            HostFilesBridge.hostListed(format: format, gdt: gdt) { [weak self] entries in self?.hostGroup(entries, format: format) }
        }
    }

    /// The session ended (main thread).
    func sessionEnded() {
        HostFileDownload.current?.sessionEnded()
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

/// One session → Mac group over the lazy limit (docs/75 §11.5), fetched in the background into a staging folder while
/// the main thread stays free (remote windows keep drawing). Progress window with Cancel; above the soft limit it asks
/// first. Complete: plain file URLs go on the pasteboard (unless the Mac clipboard changed since the copy; then the
/// window offers the folder). Cancel, failure, session end or a new copy: the fetch stops (stream released), the
/// staging folder goes, the pasteboard is left as it was. Main thread.
final class HostFileDownload {
    private(set) static var current: HostFileDownload?

    let plan: ClipboardStagingPlan
    let entries: [ClipboardFileEntry]
    let startCount: Int
    private let startFetch: (ClipboardFileWait) -> Void
    private let cancelFetch: () -> Void
    private let publish: ([URL], Int) -> Bool
    private let ended: () -> Void
    private var wait: ClipboardFileWait?
    private var timer: Timer?
    private var finished = false
    private var started = Date()
    private var window: ClipboardDownloadWindow?

    init(plan: ClipboardStagingPlan, entries: [ClipboardFileEntry], startCount: Int, start: @escaping (ClipboardFileWait) -> Void,
         cancelFetch: @escaping () -> Void, publish: @escaping ([URL], Int) -> Bool, ended: @escaping () -> Void) {
        self.plan = plan
        self.entries = entries
        self.startCount = startCount
        self.startFetch = start
        self.cancelFetch = cancelFetch
        self.publish = publish
        self.ended = ended
    }

    func begin(confirm: Bool) {
        Self.current = self
        let free = ClipboardFilesBridge.freeSpace()
        guard ClipboardTransferPolicy.enoughSpace(free: free, total: plan.totalBytes) else {
            vlog("clipboard files: not enough free disk space (\((free ?? 0) >> 20) MB free, \(plan.totalBytes >> 20) MB + 10 % needed)")
            ClipboardFilesHUD.shared.notice(loc("Not enough free disk space for the files from the session (\(Self.size(plan.totalBytes)) + 10 %).",
                                                "Nicht genug freier Speicher für die Dateien aus der Sitzung (\(Self.size(plan.totalBytes)) + 10 %)."))
            return end()
        }
        let w = ClipboardDownloadWindow()
        window = w
        w.onCancel = { [weak self] in self?.cancel(reason: "cancelled on the Mac") }
        if confirm {
            vlog("clipboard files: asking before copying \(plan.totalBytes) B")
            w.ask(loc("Copy \(Self.size(plan.totalBytes)) (\(plan.files.count) files) from the session to this Mac?",
                      "\(Self.size(plan.totalBytes)) (\(plan.files.count) Dateien) aus der Sitzung auf diesen Mac kopieren?")) { [weak self] in self?.start() }
        } else {
            start()
        }
    }

    private func start() {
        guard !finished else { return }
        let folder: URL
        do { folder = try ClipboardFilesBridge.staging.newFolder(for: plan) } catch {
            vlog("clipboard files: staging folder: \(error)")
            window?.finish(loc("The files from the session could not be stored.", "Die Dateien aus der Sitzung konnten nicht gespeichert werden."))
            return end()
        }
        let w = ClipboardFileWait(plan: plan, folder: folder, deadline: .distantFuture)
        wait = w
        started = Date()
        startFetch(w)
        window?.progress(bytes: 0, total: plan.totalBytes, detail: "")
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        vlog("clipboard files: background download of \(plan.files.count) files (\(plan.totalBytes) B) started")
    }

    private func tick() {
        guard let wait, !finished else { return }
        if let outcomes = wait.outcomes { return complete(outcomes) }
        let p = wait.progress
        let elapsed = Date().timeIntervalSince(started)
        let rate = elapsed > 1 ? Double(p.bytes) / elapsed : 0
        var detail = rate > 0 ? String(format: "%.1f MB/s", rate / 1_000_000) : ""
        if rate > 0, p.total > p.bytes {
            let left = Double(p.total - p.bytes) / rate
            detail += " · " + loc("about \(Self.duration(left)) left", "noch etwa \(Self.duration(left))")
        }
        window?.progress(bytes: p.bytes, total: p.total, detail: detail)
    }

    private func complete(_ outcomes: [ClipboardFileWait.Outcome]) {
        finished = true
        timer?.invalidate()
        var urls: [URL] = []
        var missing = 0
        for o in outcomes {
            switch o {
            case .ready(let url): urls.append(url)
            case .partial(let url, let failed): urls.append(url); missing += failed
            case .failed, .timedOut: missing += 1
            }
        }
        let seconds = Date().timeIntervalSince(started)
        guard !urls.isEmpty, let folder = wait?.folder else {
            vlog("clipboard files: background download failed: \(wait?.failureReason ?? "no file received")")
            if let folder = wait?.folder { try? FileManager.default.removeItem(at: folder) }
            window?.finish(loc("Copying files from the session failed.", "Das Kopieren der Dateien aus der Sitzung ist fehlgeschlagen."))
            return end()
        }
        vlog(String(format: "clipboard files: background download done in %.0f s, %d items, %d missing", seconds, urls.count, missing))
        let missingNote = missing > 0 ? " " + loc("\(missing) files could not be copied.", "\(missing) Dateien konnten nicht kopiert werden.") : ""
        if publish(urls, startCount) {
            window?.finish(loc("The files are ready: paste them in Finder.", "Die Dateien sind bereit: im Finder einsetzen.") + missingNote, closeAfter: missing > 0 ? nil : 4)
        } else {
            window?.finish(loc("The files are ready, but the Mac clipboard changed meanwhile.", "Die Dateien sind bereit, aber die Mac-Zwischenablage hat sich inzwischen geändert.") + missingNote,
                           reveal: folder)
        }
        end()
    }

    /// Stops a download that has not completed: fetch cancelled, staging folder removed, pasteboard untouched.
    func cancel(reason: String) {
        guard !finished else { window?.close(); return }
        finished = true
        timer?.invalidate()
        cancelFetch()
        wait?.update(.failed(reason))
        if let folder = wait?.folder { try? FileManager.default.removeItem(at: folder) }
        vlog("clipboard files: background download stopped: \(reason)")
        window?.close()
        end()
    }

    func sessionEnded() {
        guard !finished else { return }
        let w = window
        cancel(reason: "the session ended")
        w?.finish(loc("The session ended before the files were copied.", "Die Sitzung wurde beendet, bevor die Dateien kopiert waren."))
    }

    private func end() {
        if Self.current === self { Self.current = nil }
        ended()
    }

    static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        f.unitsStyle = .short
        return f.string(from: max(1, seconds)) ?? "\(Int(seconds)) s"
    }
}

/// The background download's window: a question (Copy / Cancel), then progress with Cancel, then a result with OK
/// (and "Show in Finder" when the files could not go on the clipboard). A floating utility panel outside the window
/// cycle; closing it while the copy runs cancels it.
final class ClipboardDownloadWindow: NSObject, NSWindowDelegate {
    var onCancel: () -> Void = {}
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private var primaryAction: () -> Void = {}
    private var secondaryAction: () -> Void = {}
    private var running = false

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.title = loc("Files from the session", "Dateien aus der Sitzung")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        label.preferredMaxLayoutWidth = 388
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        for b in [primary, secondary] { b.bezelStyle = .rounded; b.target = self }
        primary.action = #selector(primaryClicked)
        secondary.action = #selector(secondaryClicked)
        primary.keyEquivalent = "\r"
        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [label, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 388),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
        panel.contentView = content
    }

    private func show() {
        if !panel.isVisible {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 420, height: 130))
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    private func buttons(primary p: String?, _ pa: @escaping () -> Void = {}, secondary s: String?, _ sa: @escaping () -> Void = {}) {
        primary.isHidden = p == nil
        primary.title = p ?? ""
        primaryAction = pa
        secondary.isHidden = s == nil
        secondary.title = s ?? ""
        secondaryAction = sa
    }

    func ask(_ question: String, onCopy: @escaping () -> Void) {
        label.stringValue = question
        bar.isHidden = true
        detail.isHidden = true
        buttons(primary: loc("Copy", "Kopieren"), onCopy, secondary: loc("Cancel", "Abbrechen"), { [weak self] in self?.onCancel() })
        show()
    }

    func progress(bytes: UInt64, total: UInt64, detail text: String) {
        running = true
        label.stringValue = loc("Copying files from the session… \(HostFileDownload.size(bytes)) of \(HostFileDownload.size(total))",
                                "Dateien werden aus der Sitzung kopiert … \(HostFileDownload.size(bytes)) von \(HostFileDownload.size(total))")
        bar.isHidden = false
        bar.doubleValue = total > 0 ? Double(bytes) / Double(total) : 0
        detail.isHidden = false
        detail.stringValue = text
        if primary.title != loc("Cancel", "Abbrechen") || !secondary.isHidden {
            buttons(primary: loc("Cancel", "Abbrechen"), { [weak self] in self?.onCancel() }, secondary: nil)
            primary.keyEquivalent = "\u{1b}"
        }
        show()
    }

    func finish(_ text: String, reveal: URL? = nil, closeAfter: TimeInterval? = nil) {
        running = false
        label.stringValue = text
        bar.isHidden = true
        detail.isHidden = true
        primary.keyEquivalent = "\r"
        buttons(primary: "OK", { [weak self] in self?.close() },
                secondary: reveal == nil ? nil : loc("Show in Finder", "Im Finder zeigen"), {
                    if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                })
        show()
        if let closeAfter { DispatchQueue.main.asyncAfter(deadline: .now() + closeAfter) { [weak self] in if self?.running == false { self?.close() } } }
    }

    func close() {
        running = false
        panel.orderOut(nil)
    }

    @objc private func primaryClicked() { primaryAction() }
    @objc private func secondaryClicked() { secondaryAction() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if running || !secondary.isHidden && primary.title == loc("Copy", "Kopieren") { onCancel() }
        panel.orderOut(nil)
        return false
    }
}
