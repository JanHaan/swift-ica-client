import AppKit
import PDFKit
import ICAKit

/// Print jobs from sessions (docs/97 §6.3, PDF mode): each finished job is checked with PDFKit off the
/// main thread, written to a 0600 file in the print spool, and offered in a small panel "Print job from
/// <app>" with Print… (macOS print panel as a sheet), Open in Preview and Discard. Nothing is printed
/// without the user's click: the panel never takes key focus by itself (non-activating, ordered front
/// without becoming key) and Print… has no key equivalent. The session queue never waits for the UI. Jobs
/// queue up, one panel at a time, at most `maxJobs`; the spool holds at most 1 GiB.
/// Files go when the job is printed or discarded, and at quit (Preview keeps its copy open until then);
/// folders of earlier runs older than a day are removed on first use. Logs carry job numbers, sizes and
/// page counts, never contents or titles. Main thread.
final class PrintJobsController: NSObject, NSWindowDelegate {
    static let shared = PrintJobsController()

    private enum Item {
        case document(url: URL, info: PrintDocument.Info, thumbnail: NSImage?)
        case failed(String)
    }

    /// Jobs waiting or shown at once; more are refused (logged and reported in the panel).
    static let maxJobs = 20

    private struct Pending {
        let number: Int
        let source: String
        let item: Item
    }

    private let spool = PrintSpool()
    private let work = DispatchQueue(label: "ica.print", qos: .userInitiated)
    private var queue: [Pending] = []
    private var current: Pending?
    private var printing = false
    private var counter = 0
    private var prepared = false
    private var terminateObserver: NSObjectProtocol?

    private var panel: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let queueLabel = NSTextField(labelWithString: "")
    private let thumbnail = NSImageView()
    private lazy var printButton = NSButton(title: loc("Print…", "Drucken …"), target: self, action: #selector(printPressed))
    private lazy var previewButton = NSButton(title: loc("Open in Preview", "In Vorschau öffnen"), target: self, action: #selector(previewPressed))
    private var buttonRow: NSStackView?
    private lazy var discardButton = NSButton(title: loc("Discard", "Verwerfen"), target: self, action: #selector(discardPressed))

    /// Once per process, when a session with printing starts: stale spool folders go, and this run's
    /// folder is removed at quit.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        let spool = self.spool
        work.async { spool.removeStale() }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                   queue: .main) { _ in spool.removeAll() }
    }

    /// A finished job from a session (`source` = its display name). Returns at once.
    func add(_ job: PrintJob, source: String) {
        prepare()
        counter += 1
        let number = counter
        guard inFlight + queue.count + (current == nil ? 0 : 1) < Self.maxJobs else {
            vlog("print: job \(number) (\(logName(source)), session job \(job.id), \(job.data.count) B) refused: \(Self.maxJobs) jobs already waiting")
            return
        }
        inFlight += 1
        let spool = self.spool
        work.async { [weak self] in
            let item: Item
            switch PrintDocument.inspect(job.data) {
            case .failure(let why):
                vlog("print: job \(number) (\(logName(source)), session job \(job.id), \(job.data.count) B) refused: \(why)")
                item = .failed(why.description)
            case .success(let info):
                let fallback = loc("Print job \(number)", "Druckauftrag \(number)")
                do {
                    let url: URL
                    do { url = try spool.write(job.data, name: PrintDocument.fileName(title: info.title, fallback: fallback)) } catch PrintSpool.Failure.full(let limit) {
                        throw PrintSpool.Failure.full(limit)
                    } catch {
                        // An odd title the file system refuses: the plain name.
                        url = try spool.write(job.data, name: PrintDocument.fileName(title: nil, fallback: fallback))
                    }
                    vlog("print: job \(number) from \(logName(source)) (session job \(job.id)): \(info.byteCount) B, \(info.pageCount) page(s), "
                         + "title \(info.title?.count ?? 0) chars, %%EOF \(info.hasEOF ? "yes" : "no")")
                    // Thumbnail here, off the main thread, from its own document.
                    let thumbnail = PDFDocument(data: job.data)?.page(at: 0)?.thumbnail(of: NSSize(width: 128, height: 176), for: .mediaBox)
                    item = .document(url: url, info: info, thumbnail: thumbnail)
                } catch {
                    vlog("print: job \(number) not saved: \(error)")
                    item = .failed("\(error)")
                }
            }
            DispatchQueue.main.async {
                self?.inFlight -= 1
                self?.enqueue(Pending(number: number, source: source, item: item))
            }
        }
    }

    /// Jobs being checked and saved on `work`.
    private var inFlight = 0

    private func enqueue(_ pending: Pending) {
        queue.append(pending)
        if current == nil { showNext() } else { updateQueueLabel() }
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 140), styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = loc("Print from Windows", "Drucken aus Windows")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor
        queueLabel.textColor = .secondaryLabelColor
        queueLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.widthAnchor.constraint(equalToConstant: 64).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 88).isActive = true
        for label in [titleLabel, detailLabel] { label.widthAnchor.constraint(equalToConstant: 330).isActive = true }
        let text = NSStackView(views: [titleLabel, detailLabel, queueLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let top = NSStackView(views: [thumbnail, text])
        top.alignment = .top
        top.spacing = 14
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [discardButton, spacer, previewButton, printButton])
        buttons.spacing = 8
        buttonRow = buttons
        let stack = NSStackView(views: [top, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        return panel
    }

    private func showNext() {
        guard !queue.isEmpty else {
            current = nil
            panel?.orderOut(nil)
            return
        }
        let next = queue.removeFirst()
        current = next
        let panel = self.panel ?? makePanel()
        let isNew = self.panel == nil
        self.panel = panel
        titleLabel.stringValue = loc("Print job from \(next.source)", "Druckauftrag von \(next.source)")
        switch next.item {
        case let .document(_, info, image):
            let pages = info.pageCount == 1 ? loc("1 page", "1 Seite") : loc("\(info.pageCount) pages", "\(info.pageCount) Seiten")
            let size = ByteCountFormatter.string(fromByteCount: Int64(info.byteCount), countStyle: .file)
            detailLabel.stringValue = [info.title, "\(pages), \(size)"].compactMap { $0 }.joined(separator: "\n")
            thumbnail.image = image
            thumbnail.isHidden = image == nil
            printButton.isHidden = false
            previewButton.isHidden = false
            discardButton.title = loc("Discard", "Verwerfen")
            // The preferred action sits on the right. Print… never gets a key equivalent: printing needs a click
            // (or the user's own keyboard focus on the button). Return may open Preview, which prints nothing.
            let preview = PrintSettings.load().action == .preview
            printButton.keyEquivalent = ""
            previewButton.keyEquivalent = preview ? "\r" : ""
            if let row = buttonRow {
                row.removeView(printButton)
                row.removeView(previewButton)
                for b in preview ? [printButton, previewButton] : [previewButton, printButton] { row.addArrangedSubview(b) }
            }
        case .failed(let why):
            detailLabel.stringValue = loc("The document from Windows cannot be shown (\(why)).",
                                          "Das Dokument aus Windows kann nicht angezeigt werden (\(why)).")
            thumbnail.image = nil
            thumbnail.isHidden = true
            printButton.isHidden = true
            previewButton.isHidden = true
            discardButton.title = "OK"
            discardButton.keyEquivalent = "\r"
        }
        if case .document = next.item { discardButton.keyEquivalent = "" }
        setButtonsEnabled(true)
        updateQueueLabel()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        if isNew { panel.center() }
        // Shown without becoming key or activating the app: keystrokes keep going to the session window.
        panel.orderFrontRegardless()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func updateQueueLabel() {
        queueLabel.stringValue = queue.isEmpty ? "" : loc("\(queue.count) more waiting", "\(queue.count) weitere warten")
        queueLabel.isHidden = queue.isEmpty
    }

    private func setButtonsEnabled(_ on: Bool) {
        for b in [printButton, previewButton, discardButton] { b.isEnabled = on }
    }

    /// The current job is done: its file goes unless Preview still needs it.
    private func finishCurrent(deleteFile: Bool) {
        if deleteFile, case .document(let url, _, _)? = current?.item { spool.remove(url) }
        showNext()
    }

    // MARK: Actions

    @objc private func printPressed() {
        guard let current, case let .document(url, info, _) = current.item, let panel, !printing else { return }
        // Loaded at the click: PDFKit parses lazily, and the print operation needs it on the main thread.
        guard let document = PDFDocument(url: url) else { return previewPressed() }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let quarter = page.rotation % 180 != 0
            printInfo.orientation = (box.width > box.height) != quarter ? .landscape : .portrait
        }
        guard let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            vlog("print: job \(current.number): no print operation; opening in Preview")
            return previewPressed()
        }
        operation.jobTitle = info.title ?? loc("Print job \(current.number)", "Druckauftrag \(current.number)")
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        printing = true
        setButtonsEnabled(false)
        // The user clicked Print…: now the app may come forward for the print sheet.
        NSApp.activate()
        vlog("print: job \(current.number): print panel")
        operation.runModal(for: panel, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printing = false
        guard let current else { return }
        if success {
            vlog("print: job \(current.number): sent to the printer")
            finishCurrent(deleteFile: true)
        } else {
            // Cancelled in the panel: the job stays, so it can still be opened in Preview or discarded.
            vlog("print: job \(current.number): print panel cancelled")
            setButtonsEnabled(true)
        }
    }

    @objc private func previewPressed() {
        guard let current, case .document(let url, _, _) = current.item, !printing else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let number = current.number
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration) { _, error in
                if let error { vlog("print: job \(number): Preview did not open: \(error.localizedDescription)") }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        vlog("print: job \(number): opened in Preview (file kept until quit)")
        finishCurrent(deleteFile: false)
    }

    @objc private func discardPressed() {
        guard let current, !printing else { return }
        vlog("print: job \(current.number): discarded")
        finishCurrent(deleteFile: true)
    }

    // MARK: NSWindowDelegate

    /// The close button discards the job shown (never while the print sheet is up).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !printing else { return false }
        if current != nil { discardPressed() }
        return queue.isEmpty && current == nil
    }
}
