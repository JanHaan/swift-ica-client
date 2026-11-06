import AppKit
import ICAKit

/// Settings (Cmd-,): gateway, username, password, passcode mode with TOTP secret, forget all, and
/// display scaling (Windows scaling, client scaling; D29, docs/80 §4). Secrets are written to the
/// Keychain only; the fields never show stored values. Scaling applies at connect; saving a change
/// while sessions run offers to reconnect them. The shared folder (client drive M, docs/95 §A, D32)
/// applies at the next connect, as does printing (docs/97 §6, PDF mode: receive jobs from the host's Citrix PDF
/// Printer; which action the job window offers first) and session audio (docs/98 §10.4: play session sounds,
/// default on; the volume follows macOS; the microphone, default off per §10.4, opens only while the host records).
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let service: StoreService
    /// Demo mode (ICAVIEWER_DEMO=1): example data, nothing is read from or written to settings or Keychain.
    private let demo: Bool
    private var credentials: LoginCredentials { service.credentials }

    private let gatewayField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let protectBox = NSButton(checkboxWithTitle: loc("Require Touch ID or the Mac password to use it",
                                                             "Nur mit Touch ID oder Mac-Kennwort verwenden"),
                                      target: nil, action: nil)
    private let promptRadio = NSButton(radioButtonWithTitle: loc("Enter the passcode at each sign-in",
                                                                 "Passcode bei jeder Anmeldung eingeben"),
                                       target: nil, action: nil)
    private let totpRadio = NSButton(radioButtonWithTitle: loc("Save the TOTP secret (codes are generated)",
                                                               "TOTP-Geheimnis speichern (Codes werden erzeugt)"),
                                     target: nil, action: nil)
    private let secretField = NSSecureTextField()
    private let digitsPopup = NSPopUpButton()
    private let periodField = NSTextField()
    private let algorithmPopup = NSPopUpButton()
    private let preview = NSTextField(labelWithString: "")
    private let showCodeButton = NSButton(title: loc("Show Current Code", "Aktuellen Code zeigen"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let windowsScalingPopup = NSPopUpButton()
    private let clientScalingPopup = NSPopUpButton()
    /// Up to two lines: why the current (or last) session uses 1x, and what this Mac's screens get with
    /// the chosen scaling (or why that falls back).
    private let scalingNote = NSTextField(wrappingLabelWithString: " ")
    private var contentStack: NSStackView?
    private let shareBox = NSButton(checkboxWithTitle: loc("Share a folder with sessions as drive M",
                                                           "Einen Ordner als Laufwerk M für Sitzungen freigeben"),
                                    target: nil, action: nil)
    private let folderPath = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: loc("Choose…", "Auswählen …"), target: nil, action: nil)
    private let revealFolderButton = NSButton(title: loc("Show in Finder", "Im Finder zeigen"), target: nil, action: nil)
    private let readOnlyBox = NSButton(checkboxWithTitle: loc("Read-only (the session cannot change files)",
                                                              "Nur lesen (die Sitzung kann nichts ändern)"),
                                       target: nil, action: nil)
    private var sharedFolder = CDMSettings.defaultFolder
    private let printBox = NSButton(checkboxWithTitle: loc("Receive print jobs (Citrix PDF Printer in the session)",
                                                           "Druckaufträge empfangen (Citrix PDF Printer in der Sitzung)"),
                                    target: nil, action: nil)
    private let printActionPopup = NSPopUpButton()
    private let audioBox = NSButton(checkboxWithTitle: loc("Play session sounds (volume follows the Mac)",
                                                           "Sitzungstöne abspielen (Lautstärke wie am Mac)"),
                                    target: nil, action: nil)
    private let micBox = NSButton(checkboxWithTitle: loc("Microphone: pass it when a session app records",
                                                         "Mikrofon: weitergeben, wenn eine Sitzungs-App aufnimmt"),
                                  target: nil, action: nil)
    private var timer: Timer?
    /// Secret read from the Keychain for the preview only; dropped after one period.
    private var previewTOTP: TOTP?
    private var previewUntil = Date.distantPast

    init(service: StoreService, demo: Bool = false) {
        self.service = service
        self.demo = demo
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = loc("Settings", "Einstellungen")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if demo {
            loadDemo()
            showWindow(nil)
            window?.center()
            return
        }
        load()
        showWindow(nil)
        window?.center()
        NSApp.activate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreview() }
        }
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        clearSecrets()
        super.close()
    }

    private func clearSecrets() {
        passwordField.stringValue = ""
        secretField.stringValue = ""
        previewTOTP = nil
    }

    private func build() {
        for f in [gatewayField, usernameField, passwordField, secretField, periodField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        gatewayField.placeholderString = "gateway.example.com"
        usernameField.contentType = .username
        passwordField.contentType = .password
        secretField.placeholderString = loc("Base32 secret", "Base32-Geheimnis")
        periodField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        digitsPopup.addItems(withTitles: ["6", "7", "8"])
        algorithmPopup.addItems(withTitles: ["SHA1", "SHA256", "SHA512"])
        for c in [promptRadio, totpRadio] as [NSButton] {
            c.target = self
            c.action = #selector(modeChanged(_:))
        }
        digitsPopup.target = self
        digitsPopup.action = #selector(paramsChanged)
        algorithmPopup.target = self
        algorithmPopup.action = #selector(paramsChanged)
        showCodeButton.target = self
        showCodeButton.action = #selector(showStoredCode)
        showCodeButton.controlSize = .small
        showCodeButton.bezelStyle = .inline
        preview.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        windowsScalingPopup.addItem(withTitle: loc("Auto (matches client scaling)", "Automatisch (wie Client-Skalierung)"))
        for p in ScalingSettings.windowsChoices { windowsScalingPopup.addItem(withTitle: "\(p) %") }
        clientScalingPopup.addItem(withTitle: loc("Auto (2x on Retina screens)", "Automatisch (2x auf Retina-Bildschirmen)"))
        for k in ScalingSettings.clientChoices { clientScalingPopup.addItem(withTitle: "\(k)x") }
        for popup in [windowsScalingPopup, clientScalingPopup] {
            popup.target = self
            popup.action = #selector(scalingChanged)
        }
        scalingNote.textColor = .secondaryLabelColor
        scalingNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scalingNote.preferredMaxLayoutWidth = 360
        scalingNote.maximumNumberOfLines = 4
        scalingNote.setContentCompressionResistancePriority(.required, for: .vertical)
        scalingNote.widthAnchor.constraint(equalToConstant: 360).isActive = true
        shareBox.target = self
        shareBox.action = #selector(shareChanged)
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder)
        revealFolderButton.target = self
        revealFolderButton.action = #selector(revealFolder)
        for b in [chooseFolderButton, revealFolderButton] {
            b.controlSize = .small
            b.bezelStyle = .inline
        }
        printBox.target = self
        printBox.action = #selector(printChanged)
        audioBox.target = self
        audioBox.action = #selector(audioChanged)
        printActionPopup.addItems(withTitles: [loc("Show the print dialog first", "Zuerst den Druckdialog zeigen"),
                                               loc("Open in Preview first", "Zuerst in Vorschau öffnen")])
        folderPath.lineBreakMode = .byTruncatingMiddle
        folderPath.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            return l
        }
        let params = NSStackView(views: [digitsPopup, NSTextField(labelWithString: loc("digits", "Stellen")),
                                         periodField, NSTextField(labelWithString: loc("s", "s")), algorithmPopup])
        params.spacing = 6
        let previewRow = NSStackView(views: [preview, showCodeButton])
        previewRow.spacing = 8
        let folderRow = NSStackView(views: [folderPath, chooseFolderButton, revealFolderButton])
        folderRow.spacing = 6
        let grid = NSGridView(views: [
            [label("Gateway:"), gatewayField],
            [label(loc("User name:", "Benutzername:")), usernameField],
            [label(loc("Password:", "Kennwort:")), passwordField],
            [NSGridCell.emptyContentView, protectBox],
            [label(loc("Passcode:", "Passcode:")), promptRadio],
            [NSGridCell.emptyContentView, totpRadio],
            [label(loc("TOTP secret:", "TOTP-Geheimnis:")), secretField],
            [label(loc("Code:", "Code:")), params],
            [NSGridCell.emptyContentView, previewRow],
            [label(loc("Windows scaling:", "Windows-Skalierung:")), windowsScalingPopup],
            [label(loc("Client scaling:", "Client-Skalierung:")), clientScalingPopup],
            [NSGridCell.emptyContentView, scalingNote],
            [label(loc("Shared folder:", "Freigabe:")), shareBox],
            [NSGridCell.emptyContentView, folderRow],
            [NSGridCell.emptyContentView, readOnlyBox],
            [label(loc("Printing:", "Drucken:")), printBox],
            [NSGridCell.emptyContentView, printActionPopup],
            [label(loc("Audio:", "Audio:")), audioBox],
            [NSGridCell.emptyContentView, micBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        // Fixed column widths and window width: the longest checkbox/radio label (about 310 pt in English or
        // German) fits with the same 20 pt margin on the right as on the left.
        grid.column(at: 0).width = 120
        grid.column(at: 1).width = 360
        grid.row(at: 4).topPadding = 8
        grid.row(at: 9).topPadding = 12
        grid.row(at: 12).topPadding = 12
        grid.row(at: 15).topPadding = 12
        grid.row(at: 17).topPadding = 12

        let forget = NSButton(title: loc("Forget All Saved Credentials", "Alle gespeicherten Anmeldedaten vergessen"),
                              target: self, action: #selector(forgetAll))
        let cancel = NSButton(title: loc("Cancel", "Abbrechen"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: loc("Save", "Sichern"), target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [forget, spacer, cancel, save])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.widthAnchor.constraint(equalToConstant: 540).isActive = true
        for v in [status, buttons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window?.contentView = stack
        contentStack = stack
        updateScalingNote()
        window?.setContentSize(stack.fittingSize)
    }

    /// Fits the window to its content (the scaling note changes height), keeping the top edge.
    private func fitWindow() {
        guard let window, let stack = contentStack else { return }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 else { return }
        let frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height, width: size.width, height: size.height))
        window.setFrame(frame, display: window.isVisible)
    }

    private func loadDemo() {
        gatewayField.stringValue = Demo.gateway
        usernameField.stringValue = Demo.username
        passwordField.stringValue = Demo.password
        secretField.stringValue = Demo.totpSecret
        protectBox.state = .on
        promptRadio.state = .off
        totpRadio.state = .on
        digitsPopup.selectItem(withTitle: "6")
        periodField.stringValue = "30"
        algorithmPopup.selectItem(withTitle: "SHA1")
        status.stringValue = loc("Secrets are stored only in the Keychain (this Mac, no iCloud). ",
                                 "Geheimnisse liegen nur im Schlüsselbund (dieser Mac, kein iCloud). ")
        selectScaling(ScalingSettings())
        selectDriveMapping(CDMSettings())
        selectPrinting(PrintSettings())
        audioBox.state = AudioSettings.defaultEnabled ? .on : .off
        micBox.state = AudioSettings.defaultMicrophone ? .on : .off
        audioChanged()
        modeChanged()
    }

    // MARK: Shared folder (client drive mapping)

    private func selectDriveMapping(_ settings: CDMSettings) {
        shareBox.state = settings.enabled ? .on : .off
        readOnlyBox.state = settings.readOnly ? .on : .off
        sharedFolder = settings.folder
        shareChanged()
    }

    @objc private func shareChanged() {
        let on = shareBox.state == .on
        for c in [chooseFolderButton, readOnlyBox] as [NSControl] { c.isEnabled = on }
        revealFolderButton.isEnabled = on && FileManager.default.fileExists(atPath: sharedFolder.path)
        folderPath.stringValue = (sharedFolder.path as NSString).abbreviatingWithTildeInPath
        folderPath.toolTip = sharedFolder.path
        folderPath.textColor = on ? .labelColor : .disabledControlTextColor
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = sharedFolder.deletingLastPathComponent()
        panel.message = loc("Everything in this folder can be read and changed from the session. Choose a dedicated folder.",
                            "Alles in diesem Ordner kann in der Sitzung gelesen und geändert werden. Bitte einen eigenen Ordner wählen.")
        guard let window, demo == false else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if let why = CDMSettings.refusal(url) {
                self.status.stringValue = loc("This folder cannot be shared (\(why)). Choose a dedicated folder.",
                                              "Dieser Ordner kann nicht freigegeben werden (\(why)). Bitte einen eigenen Ordner wählen.")
                return
            }
            self.sharedFolder = url
            self.shareChanged()
        }
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([sharedFolder])
    }

    private func saveDriveMapping() {
        var settings = CDMSettings.load(env: [:])
        settings.enabled = shareBox.state == .on
        settings.readOnly = readOnlyBox.state == .on
        settings.folder = sharedFolder
        guard settings != CDMSettings.load(env: [:]) else { return }
        settings.save()
        vlog("drive mapping: saved (\(settings.enabled ? "on" : "off"), \(settings.readOnly ? "read-only" : "read-write")); applies at the next connect")
    }

    // MARK: Printing

    private func selectPrinting(_ settings: PrintSettings) {
        printBox.state = settings.enabled ? .on : .off
        printActionPopup.selectItem(at: settings.action == .preview ? 1 : 0)
        printChanged()
    }

    @objc private func printChanged() { printActionPopup.isEnabled = printBox.state == .on }

    private func savePrinting() {
        var settings = PrintSettings.load(env: [:])
        settings.enabled = printBox.state == .on
        settings.action = printActionPopup.indexOfSelectedItem == 1 ? .preview : .printDialog
        guard settings != PrintSettings.load(env: [:]) else { return }
        settings.save()
        vlog("printing: saved (\(settings.enabled ? "on" : "off"), \(settings.action.rawValue) first); on/off applies at the next connect")
    }

    // MARK: Audio

    private func saveAudio() {
        var settings = AudioSettings.load(env: [:])
        settings.enabled = audioBox.state == .on
        settings.microphone = micBox.state == .on
        guard settings != AudioSettings.load(env: [:]) else { return }
        settings.save()
        vlog("audio: saved (\(settings.enabled ? "on" : "off"), microphone \(settings.microphone ? "on" : "off")); applies at the next connect")
    }

    /// The microphone goes through the same channel: without session audio there is none.
    @objc private func audioChanged() { micBox.isEnabled = audioBox.state == .on
    }

    // MARK: Scaling

    private func selectScaling(_ settings: ScalingSettings) {
        switch settings.windows {
        case .auto: windowsScalingPopup.selectItem(at: 0)
        case .percent(let p): windowsScalingPopup.selectItem(at: 1 + (ScalingSettings.windowsChoices.firstIndex(of: p) ?? -1))
        }
        switch settings.client {
        case .auto: clientScalingPopup.selectItem(at: 0)
        case .fixed(let k): clientScalingPopup.selectItem(at: 1 + (ScalingSettings.clientChoices.firstIndex(of: k) ?? -1))
        }
        updateScalingNote()
    }

    private var selectedScaling: ScalingSettings {
        let w = windowsScalingPopup.indexOfSelectedItem, c = clientScalingPopup.indexOfSelectedItem
        return ScalingSettings(windows: w > 0 ? .percent(ScalingSettings.windowsChoices[w - 1]) : .auto,
                               client: c > 0 ? .fixed(ScalingSettings.clientChoices[c - 1]) : .auto)
    }

    @objc private func scalingChanged() { updateScalingNote() }

    /// The scaling note: first why the running (else the last) session uses 1x, if it fell back; then
    /// what the current screens get with the chosen settings, also when no session is connected.
    private func updateScalingNote() {
        var lines: [String] = []
        if let running = SessionController.running.last {
            if let note = running.layout.note { lines.append(scalingNoteText(note, context: .current)) }
        } else if let last = SessionController.lastLayout, let note = last.note {
            lines.append(scalingNoteText(note, context: .last))
        }
        let layout = ScalingLayout.resolve(screens: SessionController.currentScreens(), settings: selectedScaling,
                                           limit: ScalingLimits.sessionLimit())
        let screens = layout.note.map { scalingNoteText($0, context: .screens) } ?? scalingSummary(layout)
        if !lines.contains(where: { $0 == screens }) { lines.append(screens) }
        let text = lines.joined(separator: "\n")
        scalingNote.stringValue = text
        scalingNote.toolTip = text
        fitWindow()
    }

    /// Saves the scaling choice; if running sessions connected with other settings, offers to reconnect
    /// them now (disconnect and relaunch; never a logoff).
    private func saveScaling() {
        let settings = selectedScaling
        settings.save()
        let stale = SessionController.running.filter { $0.differs(from: settings) }
        guard !stale.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = loc("Reconnect now to apply?", "Jetzt neu verbinden, um die Änderung anzuwenden?")
        alert.informativeText = loc("Scaling applies when a session connects. Reconnecting disconnects \(stale.map { displayName($0.name) }.joined(separator: ", ")) and connects again with the new scaling; the session is not logged off and your apps keep running.",
                                    "Die Skalierung gilt beim Verbinden. Beim Neuverbinden wird \(stale.map { displayName($0.name) }.joined(separator: ", ")) getrennt und mit der neuen Skalierung wieder verbunden; die Sitzung wird nicht abgemeldet, die Apps laufen weiter.")
        alert.addButton(withTitle: loc("Reconnect Now", "Jetzt neu verbinden"))
        alert.addButton(withTitle: loc("Later", "Später"))
        if alert.runModal() == .alertFirstButtonReturn {
            stale.forEach { $0.reconnectToApplySettings() }
        } else {
            vlog("scaling: saved \(settings); applies at the next connect")
        }
    }

    private func load() {
        let s = credentials.settings.load()
        gatewayField.stringValue = s.gateway?.host ?? (service.gateway?.host ?? "")
        usernameField.stringValue = s.username
        clearSecrets()
        let host = s.gatewayHost ?? service.gateway?.host
        let hasPassword = host.map { credentials.secrets.contains(.password, host: $0) } ?? false
        let hasSecret = host.map { credentials.secrets.contains(.totpSecret, host: $0) } ?? false
        passwordField.placeholderString = hasPassword ? loc("saved (type to replace)", "gespeichert (zum Ersetzen eingeben)")
            : loc("not saved", "nicht gespeichert")
        secretField.placeholderString = hasSecret ? loc("saved (type to replace)", "gespeichert (zum Ersetzen eingeben)")
            : loc("Base32 secret", "Base32-Geheimnis")
        protectBox.state = s.protectPassword ? .on : .off
        let totpMode = s.passcodeMode == .totp && hasSecret
        promptRadio.state = totpMode ? .off : .on
        totpRadio.state = totpMode ? .on : .off
        digitsPopup.selectItem(withTitle: String(s.totpDigits))
        periodField.stringValue = String(s.totpPeriod)
        algorithmPopup.selectItem(withTitle: s.totpAlgorithm.rawValue)
        selectScaling(ScalingSettings.load(env: [:]))
        selectDriveMapping(CDMSettings.load(env: [:]))
        selectPrinting(PrintSettings.load(env: [:]))
        let audio = AudioSettings.load(env: [:])
        audioBox.state = audio.enabled ? .on : .off
        micBox.state = audio.microphone ? .on : .off
        audioChanged()
        status.stringValue = loc("Secrets are stored only in the Keychain (this Mac, no iCloud). ",
                                 "Geheimnisse liegen nur im Schlüsselbund (dieser Mac, kein iCloud). ")
            + (service.usesEnvCredentials ? loc("Note: .env credentials override these settings.",
                                                "Hinweis: Die Zugangsdaten aus .env haben Vorrang.") : "")
        modeChanged()
    }

    private var currentSettings: LoginSettings {
        var s = credentials.settings.load()
        s.totpDigits = Int(digitsPopup.titleOfSelectedItem ?? "6") ?? 6
        s.totpPeriod = max(1, Int(periodField.stringValue) ?? 30)
        s.totpAlgorithm = TOTP.Algorithm(rawValue: algorithmPopup.titleOfSelectedItem ?? "SHA1") ?? .sha1
        return s
    }

    @objc private func modeChanged(_ sender: NSButton? = nil) {
        if sender === totpRadio { promptRadio.state = .off }
        if sender === promptRadio { totpRadio.state = .off }
        let totp = totpRadio.state == .on
        for c in [secretField, digitsPopup, periodField, algorithmPopup] as [NSControl] { c.isEnabled = totp }
        // Default: protect the password when the TOTP secret is stored next to it.
        if sender === totpRadio { protectBox.state = .on }
        updatePreview()
    }

    @objc private func paramsChanged() {
        previewTOTP = nil
        updatePreview()
    }

    private var lengths: [ObjectIdentifier: Int] = [:]

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            // No line breaks in single-line fields; the password keeps its spaces (see `FieldText`).
            let text = field.stringValue
            let pasted = text.count - (lengths[ObjectIdentifier(field)] ?? 0) > 1
                || text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
            let clean = FieldText.clean(text, password: field === passwordField, final: pasted)
            if clean != text {
                if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView { editor.string = clean } else { field.stringValue = clean }
            }
            lengths[ObjectIdentifier(field)] = clean.count
        }
        if (obj.object as? NSTextField) === secretField || (obj.object as? NSTextField) === periodField { previewTOTP = nil }
        updatePreview()
    }

    private func updatePreview() {
        if demo {
            preview.stringValue = loc("Current code: ", "Aktueller Code: ") + Demo.totpPreview
            showCodeButton.isHidden = true
            return
        }
        guard totpRadio.state == .on else {
            preview.stringValue = ""
            showCodeButton.isHidden = true
            return
        }
        let s = currentSettings
        let typed = secretField.stringValue
        let totp: TOTP?
        if !typed.isEmpty {
            totp = s.totp(secret: typed)
            if totp == nil { preview.stringValue = loc("Not a valid base32 secret", "Kein gültiges Base32-Geheimnis") }
        } else if let stored = previewTOTP, Date() < previewUntil {
            totp = stored
        } else {
            previewTOTP = nil
            totp = nil
            preview.stringValue = ""
        }
        if let totp {
            preview.stringValue = loc("Current code: ", "Aktueller Code: ") + "\(totp.code()) (\(totp.secondsRemaining()) s)"
        }
        let host = LoginSettings.gatewayURL(from: gatewayField.stringValue)?.host
        showCodeButton.isHidden = !typed.isEmpty || totp != nil
            || !(host.map { credentials.secrets.contains(.totpSecret, host: $0) } ?? false)
    }

    /// Reads the stored secret (Touch ID / password) to show its current code for comparison.
    @objc private func showStoredCode() {
        guard let host = LoginSettings.gatewayURL(from: gatewayField.stringValue)?.host else { return }
        Task {
            do {
                var values = try await credentials.secrets.read(
                    [.totpSecret], host: host, reason: loc("show the current code", "den aktuellen Code anzuzeigen"))
                previewTOTP = values[.totpSecret].flatMap { currentSettings.totp(secret: $0) }
                values = [:]
                previewUntil = Date().addingTimeInterval(TimeInterval(currentSettings.totpPeriod))
            } catch {
                vlog("settings: secret not read: \(error)")
            }
            updatePreview()
        }
    }

    @objc private func forgetAll() {
        guard !demo else { return }
        guard let host = LoginSettings.gatewayURL(from: gatewayField.stringValue)?.host ?? service.gateway?.host else { return }
        credentials.forgetAll(host: host)
        load()
        status.stringValue = loc("Saved credentials for \(host) were deleted.", "Gespeicherte Anmeldedaten für \(host) wurden gelöscht.")
    }

    @objc private func cancelClicked() { close() }

    @objc private func saveClicked() {
        if demo { close(); return }
        let s = currentSettings
        let password = FieldText.clean(passwordField.stringValue, password: true, final: true)
        let secret = FieldText.clean(secretField.stringValue, password: false, final: true)
        let update = LoginCredentials.Update(
            gatewayURL: FieldText.clean(gatewayField.stringValue, password: false, final: true),
            username: FieldText.clean(usernameField.stringValue, password: false, final: true),
            newPassword: password.isEmpty ? nil : password, protectPassword: protectBox.state == .on,
            passcodeMode: totpRadio.state == .on ? .totp : .prompt, newTOTPSecret: secret.isEmpty ? nil : secret,
            totpDigits: s.totpDigits, totpPeriod: s.totpPeriod, totpAlgorithm: s.totpAlgorithm)
        Task {
            do {
                try await credentials.apply(update, reason: loc("change the protection of the saved password",
                                                                "den Schutz des gespeicherten Kennworts zu ändern"))
                if let url = LoginSettings.gatewayURL(from: update.gatewayURL), url.host != service.gateway?.host {
                    service.setGateway(url)
                }
                close()
                saveDriveMapping()
                savePrinting()
                saveAudio()
                saveScaling()
            } catch CredentialError.invalidTOTPSecret {
                status.stringValue = loc("Enter a valid TOTP secret (base32), or choose to enter the passcode at each sign-in.",
                                         "Bitte ein gültiges TOTP-Geheimnis (Base32) eingeben oder „Passcode bei jeder Anmeldung eingeben“ wählen.")
            } catch CredentialError.noGateway {
                status.stringValue = loc("Enter the gateway address first.", "Bitte zuerst die Gateway-Adresse eingeben.")
            } catch {
                status.stringValue = "\(error)"
            }
        }
    }
}

/// Whose scaling a note explains.
enum ScalingNoteContext { case screens, current, last }

/// The explanation when a session does not get the scaling asked for. Settings shows it in the UI
/// language like its other labels (`loc`); the log passes `english` (log lines are English).
func scalingNoteText(_ note: ScalingLayout.Note, context: ScalingNoteContext, english: Bool = false) -> String {
    func tr(_ en: String, _ de: String) -> String { english ? en : loc(en, de) }
    func head(manual: Bool) -> String {
        switch context {
        case .screens: return manual ? tr("With these screens, 2x is refused and 1x is used because ",
                                          "Mit diesen Bildschirmen wird 2x abgelehnt und 1x genutzt, weil ")
                                     : tr("With these screens, Auto uses 1x because ", "Mit diesen Bildschirmen nutzt Automatisch 1x, weil ")
        case .current: return tr("This session uses 1x because ", "Diese Sitzung nutzt 1x, weil ")
        case .last: return tr("The last session used 1x because ", "Die letzte Sitzung nutzte 1x, weil ")
        }
    }
    switch note {
    case let .tooLarge(w, h, lw, lh, manual):
        return head(manual: manual) + tr("2x would need \(w)×\(h) px (limit \(lw)×\(lh)).",
                                         "2x \(w)×\(h) px bräuchte (Grenze \(lw)×\(lh)).")
    case let .overlapping(manual):
        return head(manual: manual) + tr("2x per screen does not fit this screen arrangement.",
                                         "2x pro Bildschirm nicht zu dieser Anordnung passt.")
    case let .exceedsAtOneX(w, h, lw, lh):
        switch context {
        case .screens: return tr("With these screens, the session (\(w)×\(h) px) is above the \(lw)×\(lh) limit even at 1x.",
                                 "Mit diesen Bildschirmen liegt die Sitzung (\(w)×\(h) px) selbst bei 1x über der Grenze \(lw)×\(lh).")
        case .current: return tr("This session (\(w)×\(h) px) is above the \(lw)×\(lh) limit even at 1x.",
                                 "Diese Sitzung (\(w)×\(h) px) liegt selbst bei 1x über der Grenze \(lw)×\(lh).")
        case .last: return tr("The last session (\(w)×\(h) px) was above the \(lw)×\(lh) limit even at 1x.",
                              "Die letzte Sitzung (\(w)×\(h) px) lag selbst bei 1x über der Grenze \(lw)×\(lh).")
        }
    }
}

/// One line describing a layout that got what was asked: session size, scale and Windows scaling.
func scalingSummary(_ layout: ScalingLayout) -> String {
    let scales = layout.monitors.map { "\($0.scale)x" }.joined(separator: " / ")
    let percents = layout.monitors.map { "\($0.windowsPercent) %" }.joined(separator: " / ")
    return loc("Session \(layout.width)×\(layout.height) px, client \(scales), Windows \(percents).",
               "Sitzung \(layout.width)×\(layout.height) px, Client \(scales), Windows \(percents).")
}
