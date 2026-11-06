import AppKit
import ICAKit

/// "Report a Problem": the user's text, optional environment, settings summary and session log,
/// scrubbed by `ReportScrubber` (rules in ReportScrubber.swift) and shown in a read-only preview that
/// is exactly what is copied, saved or put into the GitHub link. Nothing is sent: "Create GitHub
/// Issue…" saves the report file, shows it in Finder and opens the prefilled "new issue" page in the
/// browser, where the user attaches the file and submits.
@MainActor
final class FeedbackWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static var current: FeedbackWindowController?

    static func show() {
        let controller = current ?? FeedbackWindowController()
        current = controller
        controller.reloadSources()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.descriptionView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let minuteChoices = [10, 30, 60]

    private var descriptionView: NSTextView!
    private var previewView: NSTextView!
    private let environmentBox = NSButton(checkboxWithTitle: loc("App and macOS version, Mac model and displays",
                                                                  "App- und macOS-Version, Mac-Modell und Bildschirme"), target: nil, action: nil)
    private let settingsBox = NSButton(checkboxWithTitle: loc("Summary of the settings (no passwords, secrets or host names)",
                                                               "Übersicht der Einstellungen (ohne Passwörter, Geheimnisse und Hostnamen)"), target: nil, action: nil)
    private let logBox = NSButton(checkboxWithTitle: loc("Session log of the last", "Sitzungsprotokoll der letzten"), target: nil, action: nil)
    private let minutesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let namesBox = NSButton(checkboxWithTitle: loc("Show app names in the log (otherwise “App 1”, “App 2”, …)",
                                                            "App-Namen im Protokoll zeigen (sonst „App 1“, „App 2“ …)"), target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: loc("Copy Report", "Bericht kopieren"), target: nil, action: nil)
    private let saveButton = NSButton(title: loc("Save Report…", "Bericht sichern…"), target: nil, action: nil)
    private let issueButton = NSButton(title: loc("Create GitHub Issue…", "GitHub-Issue anlegen…"), target: nil, action: nil)

    // Sources, read when the window is shown.
    private var created = Date()
    private var environment: [String] = []
    private var settings: [String] = []
    private var rawLog: [LogStore.Entry] = []
    private var logLoaded = false
    /// Index 0: names hidden, 1: names shown. Both learn names from the same log, so numbering is stable.
    private var scrubbers: [ReportScrubber] = []
    /// Scrubbed log lines per "minutes-names".
    private var scrubbedLogs: [String: [String]] = [:]
    private var pendingLogKey: String?
    private var loadGeneration = 0
    private var debounce: DispatchWorkItem?
    /// What the preview shows (and the buttons share); nil while the log is still being prepared.
    private var report: ProblemReport?
    private var markdown = ""

    private let previewAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.textColor,
    ]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = loc("Report a Problem", "Problem melden")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: 640)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        window.setFrameAutosaveName("FeedbackWindow")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        // Public-issue warning, prominent and wrapping (never truncated).
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let warning = wrapping(loc("Reports go to a public GitHub issue. Review the preview before sending.",
                                   "Meldungen landen in einem öffentlichen GitHub-Issue. Prüfen Sie die Vorschau vor dem Senden."),
                               font: .boldSystemFont(ofSize: 13))
        let warningRow = NSStackView(views: [icon, warning])
        warningRow.alignment = .top
        warningRow.spacing = 8
        fullWidth(warningRow)
        stack.setCustomSpacing(14, after: warningRow)

        fullWidth(wrapping(loc("What happened, and what did you expect? (required)",
                               "Was ist passiert, und was haben Sie erwartet? (Pflichtfeld)"), font: .systemFont(ofSize: 13, weight: .semibold)))
        let descriptionScroll = NSTextView.scrollableTextView()
        descriptionView = (descriptionScroll.documentView as! NSTextView)
        descriptionView.isRichText = false
        descriptionView.allowsUndo = true
        descriptionView.font = .systemFont(ofSize: 13)
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.isAutomaticDashSubstitutionEnabled = false
        descriptionView.delegate = self
        descriptionView.setAccessibilityLabel(loc("Problem description", "Problembeschreibung"))
        descriptionScroll.borderType = .bezelBorder
        fullWidth(descriptionScroll)
        descriptionScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        stack.setCustomSpacing(12, after: descriptionScroll)

        fullWidth(wrapping(loc("Include:", "Mitsenden:"), font: .systemFont(ofSize: 13, weight: .semibold)))
        for box in [environmentBox, settingsBox, logBox, namesBox] {
            box.state = box === namesBox ? .off : .on
            box.target = self
            box.action = #selector(optionsChanged(_:))
        }
        stack.addArrangedSubview(environmentBox)
        stack.addArrangedSubview(settingsBox)
        minutesPopup.addItems(withTitles: Self.minuteChoices.map(String.init))
        minutesPopup.selectItem(withTitle: "30")
        minutesPopup.target = self
        minutesPopup.action = #selector(optionsChanged(_:))
        let minutesLabel = NSTextField(labelWithString: loc("minutes", "Minuten"))
        let logRow = NSStackView(views: [logBox, minutesPopup, minutesLabel])
        logRow.spacing = 6
        stack.addArrangedSubview(logRow)
        let namesRow = NSStackView(views: [namesBox])
        namesRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        stack.addArrangedSubview(namesRow)
        stack.setCustomSpacing(12, after: namesRow)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let previewTitle = NSTextField(labelWithString: loc("Preview: exactly what will be shared",
                                                            "Vorschau: genau das wird geteilt"))
        previewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let previewRow = NSStackView(views: [previewTitle, spinner])
        previewRow.spacing = 6
        stack.addArrangedSubview(previewRow)
        let previewScroll = NSTextView.scrollableTextView()
        previewView = (previewScroll.documentView as! NSTextView)
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.isRichText = false
        previewView.textContainerInset = NSSize(width: 4, height: 4)
        previewView.backgroundColor = .textBackgroundColor
        previewView.setAccessibilityLabel(loc("Report preview", "Vorschau des Berichts"))
        previewScroll.borderType = .bezelBorder
        fullWidth(previewScroll)
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        previewScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        fullWidth(wrapping(loc("Nothing is sent automatically. “Create GitHub Issue…” saves the full report (with the log) as a file, "
                               + "shows it in Finder and opens GitHub in your browser with title, description and environment filled in. "
                               + "Drag the file into the issue, check it, then submit it there.",
                               "Es wird nichts automatisch gesendet. „GitHub-Issue anlegen…“ sichert den vollständigen Bericht (mit Protokoll) "
                               + "als Datei, zeigt sie im Finder und öffnet GitHub im Browser mit Titel, Beschreibung und Umgebung. "
                               + "Ziehen Sie die Datei in das Issue, prüfen Sie es und senden Sie es dort ab."),
                           font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .systemGreen
        statusLabel.isSelectable = true
        fullWidth(statusLabel)

        copyButton.target = self
        copyButton.action = #selector(copyReport(_:))
        saveButton.target = self
        saveButton.action = #selector(saveReport(_:))
        issueButton.target = self
        issueButton.action = #selector(createIssue(_:))
        issueButton.bezelColor = .controlAccentColor
        issueButton.keyEquivalent = "\r"
        issueButton.keyEquivalentModifierMask = [.command]   // Return alone types a new line
        issueButton.toolTip = loc("Cmd-Return", "Cmd-Zeilenschalter")
        let close = NSButton(title: loc("Close", "Schließen"), target: window, action: #selector(NSWindow.performClose(_:)))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [copyButton, saveButton, spacer, close, issueButton])
        buttons.spacing = 8
        fullWidth(buttons)
    }

    private func wrapping(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    // MARK: - Sources

    /// Reads environment, settings and the last 60 minutes of log; the description is kept.
    private func reloadSources() {
        created = Date()
        environment = FeedbackSources.environment()
        settings = FeedbackSources.settings()
        let context = FeedbackSources.scrubberContext()
        scrubbers = Self.scrubbers(context, learningFrom: [])
        scrubbedLogs = [:]
        pendingLogKey = nil
        logLoaded = false
        statusLabel.stringValue = ""
        loadGeneration += 1
        let generation = loadGeneration
        let since = created.addingTimeInterval(-Double(Self.minuteChoices.max()! * 60))
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = LogStore.shared.recent(since: since)
            let text = entries.map(\.line).joined(separator: "\n")
            let learned = Self.scrubbers(context, learningFrom: [text])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.loadGeneration else { return }
                    self.rawLog = entries
                    self.scrubbers = learned
                    self.logLoaded = true
                    self.render()
                }
            }
        }
    }

    private nonisolated static func scrubbers(_ context: ReportScrubber.Context, learningFrom texts: [String]) -> [ReportScrubber] {
        var shown = context
        shown.includeResourceNames = true
        var hidden = context
        hidden.includeResourceNames = false
        return [ReportScrubber(hidden, learningFrom: texts), ReportScrubber(shown, learningFrom: texts)]
    }

    private var minutes: Int { Int(minutesPopup.titleOfSelectedItem ?? "") ?? 30 }
    private var namesShown: Bool { namesBox.state == .on }
    private var scrubber: ReportScrubber { scrubbers[namesShown ? 1 : 0] }

    // MARK: - Rendering

    func textDidChange(_ notification: Notification) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @objc private func optionsChanged(_ sender: Any?) {
        render()
    }

    /// Builds the report from the current options. The log is scrubbed in the background once per
    /// minutes/names choice; until it is ready the buttons stay off, so nothing unfinished is shared.
    private func render() {
        debounce?.cancel()
        minutesPopup.isEnabled = logBox.state == .on
        namesBox.isEnabled = logBox.state == .on
        let scrubber = self.scrubber
        var log: [String]?
        var waiting = false
        if logBox.state == .on {
            let key = "\(minutes)-\(namesShown)"
            if let cached = scrubbedLogs[key] {
                log = cached
            } else {
                waiting = true
                if logLoaded { scrubLog(key: key, minutes: minutes, scrubber: scrubber) }
            }
        }
        let next = ProblemReport(created: created, description: scrubber.scrub(descriptionView.string),
                                 environment: environmentBox.state == .on ? environment.map(scrubber.scrub) : [],
                                 settings: settingsBox.state == .on ? settings.map(scrubber.scrub) : [],
                                 log: log, logMinutes: minutes, appNamesIncluded: namesShown)
        if waiting {
            report = nil
            spinner.startAnimation(nil)
            var shown = next
            shown.log = [loc("(preparing the log …)", "(Protokoll wird vorbereitet …)")]
            markdown = shown.markdown
        } else {
            report = next
            spinner.stopAnimation(nil)
            markdown = next.markdown
        }
        setPreview(markdown)
        let ready = report != nil
        let hasText = !descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyButton.isEnabled = ready
        saveButton.isEnabled = ready
        issueButton.isEnabled = ready && hasText
    }

    private func scrubLog(key: String, minutes: Int, scrubber: ReportScrubber) {
        guard pendingLogKey != key else { return }
        pendingLogKey = key
        let since = created.addingTimeInterval(-Double(minutes * 60))
        let lines = rawLog.filter { $0.date >= since }.map { Self.timeOfDay($0.date) + " " + $0.line }
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let scrubbed = lines.isEmpty ? [] : scrubber.scrubLines(lines.joined(separator: "\n"))
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.loadGeneration else { return }
                    self.scrubbedLogs[key] = scrubbed
                    if self.pendingLogKey == key { self.pendingLogKey = nil }
                    self.render()
                }
            }
        }
    }

    private nonisolated static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Replaces only the changed middle of the preview, so typing stays fast with a long log.
    private func setPreview(_ text: String) {
        guard let storage = previewView.textStorage else { return }
        let old = Array(storage.string.utf16)
        let new = Array(text.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        guard prefix != old.count || prefix != new.count else { return }
        let inserted = String(utf16CodeUnits: Array(new[prefix..<(new.count - suffix)]), count: new.count - suffix - prefix)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: prefix, length: old.count - suffix - prefix),
                                  with: NSAttributedString(string: inserted, attributes: previewAttributes))
        storage.endEditing()
    }

    // MARK: - Actions

    @objc private func copyReport(_ sender: Any?) {
        guard report != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        showStatus(loc("The report is on the clipboard.", "Der Bericht ist in der Zwischenablage."))
    }

    @objc private func saveReport(_ sender: Any?) {
        guard let report, let window else { return }
        let text = markdown
        let panel = NSSavePanel()
        panel.nameFieldStringValue = report.fileName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(text, fileName: url.lastPathComponent, to: url.deletingLastPathComponent()) { saved in
                NSWorkspace.shared.activateFileViewerSelecting([saved])
                self?.showStatus(loc("Saved “\(saved.lastPathComponent)” and showed it in Finder.",
                                     "„\(saved.lastPathComponent)“ gesichert und im Finder gezeigt."))
            }
        }
    }

    @objc private func createIssue(_ sender: Any?) {
        guard let report, let window else { return }
        guard !descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            window.makeFirstResponder(descriptionView)
            return
        }
        let text = markdown
        let link = report.issueURL()
        let alert = NSAlert()
        alert.messageText = loc("Create the GitHub issue", "GitHub-Issue anlegen")
        alert.informativeText = loc(
            "The full report is saved as “\(report.fileName)” on the Desktop and shown in Finder. "
                + "Then GitHub opens in your browser with the title, description and environment filled in.\n\n"
                + "Drag the file into the issue's “Report file” field, check everything (the issue is public), "
                + "then submit it on GitHub. Nothing is sent before you submit.",
            "Der vollständige Bericht wird als „\(report.fileName)“ auf dem Schreibtisch gesichert und im Finder gezeigt. "
                + "Dann öffnet sich GitHub im Browser mit Titel, Beschreibung und Umgebung.\n\n"
                + "Ziehen Sie die Datei in das Feld „Report file“ des Issues, prüfen Sie alles (das Issue ist öffentlich) "
                + "und senden Sie es auf GitHub ab. Vorher wird nichts gesendet.")
        alert.addButton(withTitle: loc("Save and Open GitHub", "Sichern und GitHub öffnen"))
        alert.addButton(withTitle: loc("Cancel", "Abbrechen"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
            self.write(text, fileName: report.fileName, to: desktop) { saved in
                NSWorkspace.shared.activateFileViewerSelecting([saved])
                NSWorkspace.shared.open(link)
                self.showStatus(loc("Saved “\(saved.lastPathComponent)” on the Desktop. Drag this file into the issue.",
                                    "„\(saved.lastPathComponent)“ auf dem Schreibtisch gesichert. Ziehen Sie diese Datei in das Issue."))
            }
        }
    }

    /// Writes in the background; on failure offers the save panel.
    private func write(_ text: String, fileName: String, to folder: URL, then done: @escaping @MainActor (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FeedbackSources.write(markdown: text, fileName: fileName, to: folder) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let url):
                        vlog("feedback: report saved (\(url.pathExtension), \(text.utf8.count) B)")
                        done(url)
                    case .failure(let error):
                        vlog("feedback: report not saved: \(error.localizedDescription)")
                        let alert = NSAlert()
                        alert.messageText = loc("The report could not be saved", "Der Bericht konnte nicht gesichert werden")
                        alert.informativeText = error.localizedDescription + "\n\n"
                            + loc("Use “Save Report…” to choose another folder.", "Mit „Bericht sichern…“ einen anderen Ordner wählen.")
                        if let window = self.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                    }
                }
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func windowWillClose(_ notification: Notification) {
        debounce?.cancel()
    }
}
