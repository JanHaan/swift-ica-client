import AppKit
import ICAKit

/// Settings (Cmd-,): gateway, username, password, passcode mode with TOTP secret, forget all.
/// Secrets are written to the Keychain only; the fields never show stored values.
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
        window?.setContentSize(stack.fittingSize)
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
        modeChanged()
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
