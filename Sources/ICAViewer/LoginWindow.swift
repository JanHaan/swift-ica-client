import AppKit
import ICAKit

/// Our own UI texts in the system language (German or English).
func loc(_ en: String, _ de: String) -> String {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("de") == true ? de : en
}

struct LoginCancelled: Error, CustomStringConvertible {
    var description: String { "sign-in cancelled" }
}

/// Native login window generated from the gateway's nFactor form (`LogonForm`), one factor at a time.
///
/// Test mode ICAVIEWER_LOGIN_AUTOFILL=1 fills empty fields from `.env` by setting the controls'
/// values (as typing does), then presses the default button. It never fills a re-prompt.
/// ICAVIEWER_LOGIN_REMEMBER=1 additionally ticks "Remember" (password only, no TOTP secret).
/// ICAVIEWER_LOGIN_SCREENSHOT=<path> captures the window before it is filled.
@MainActor
final class LoginWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let service: StoreService
    private var credentials: LoginCredentials { service.credentials }
    private var waiting: [CheckedContinuation<Void, Error>] = []

    // Logon state
    private var logon: GatewayLogon?
    private var form: LogonForm?
    private var message: String?
    private var busy = false
    private var task: Task<Void, Never>?
    private var formsShown = 0
    /// A TOTP generator from the stored secret, kept only until this logon ends.
    private var storedTOTP: TOTP?
    private var prefilledFromStore: Set<String> = []
    private var secretsLoaded = false
    /// Username and password as posted, kept until success when "Remember" is on.
    private var postedUsername: String?
    private var postedPassword: String?
    private var postedSecret: String?

    // UI state
    private var remember = false
    /// "Remember" with a passcode field: ask for the TOTP secret instead of a code.
    private var askSecret = false
    private var draft: [String: String] = [:]
    private var controls: [String: NSControl] = [:]
    private var submitButton: NSButton?
    private let gatewayField = NSTextField()
    private let spinner = NSProgressIndicator()

    private let autofill = StoreService.autofill
    private let autofillRemember = ProcessInfo.processInfo.environment["ICAVIEWER_LOGIN_REMEMBER"] == "1"
    private var autofillDone: Set<Int> = []
    /// Field kinds of every form shown (for the test log).
    private(set) var renderedKinds: [[String]] = []

    static let secretFieldID = "#totp-secret"

    init(service: StoreService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = loc("Sign In", "Anmelden")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        gatewayField.controlSize = .small
        gatewayField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gatewayField.placeholderString = "gateway.example.com"
        gatewayField.target = self
        gatewayField.action = #selector(gatewayEdited)
        gatewayField.delegate = self
        gatewayField.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Flow

    /// Shows the window and returns once the gateway logon succeeded. Throws `LoginCancelled` on cancel.
    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { start() }
        }
    }

    private func start() {
        task?.cancel()
        form = nil
        message = nil
        storedTOTP = nil
        secretsLoaded = false
        prefilledFromStore = []
        postedUsername = nil
        postedPassword = nil
        postedSecret = nil
        draft = [:]
        let host = service.gateway?.host
        gatewayField.stringValue = host ?? ""
        remember = host.map { credentials.saved(host: $0).hasPassword } ?? false
        askSecret = false
        showWindow(nil)
        window?.center()
        NSApp.activate()
        guard let gateway = service.gateway else {
            render()
            window?.makeFirstResponder(gatewayField)
            return
        }
        let logon = GatewayLogon(http: service.http, base: gateway)
        self.logon = logon
        busy = true
        render()
        task = Task { [weak self] in
            do {
                let form = try await logon.begin()
                guard let self, !Task.isCancelled else { return }
                await self.show(form)
            } catch {
                guard let self, !Task.isCancelled else { return }
                vlog("login: cannot start: \(error)")
                self.busy = false
                self.message = loc("Cannot reach the gateway: ", "Gateway nicht erreichbar: ") + error.localizedDescription
                self.render()
            }
        }
    }

    private func show(_ form: LogonForm) async {
        self.form = form
        formsShown += 1
        busy = false
        message = form.isRePrompt && form.errors.isEmpty
            ? loc("The gateway did not accept the sign-in. Check your entries.",
                  "Das Gateway hat die Anmeldung nicht angenommen. Bitte Eingaben prüfen.") : nil
        renderedKinds.append(form.fields.map(\.kind.rawValue))
        vlog("login: form \(formsShown): \(form.summary)\(form.isRePrompt ? " (re-prompt)" : "")")
        draft = [:]
        if form.isRePrompt {
            // Keep what the user typed as username; never refill a password or code automatically.
            for f in form.fields where f.kind == .username { draft[f.id] = postedUsername }
            prefilledFromStore = []
        } else {
            await prefill(form)
        }
        render()
        if let path = ProcessInfo.processInfo.environment["ICAVIEWER_LOGIN_SCREENSHOT"], formsShown == 1 {
            try? await Task.sleep(for: .milliseconds(700))
            captureWindow(to: path)
        }
        if autofill { await runAutofill(form) } else { autoSubmitIfComplete(form) }
    }

    /// Fills username, password and passcode from the settings and the Keychain (read now, at login time).
    private func prefill(_ form: LogonForm) async {
        guard let host = service.gateway?.host else { return }
        let saved = credentials.saved(host: host)
        vlog("login: saved username: \(saved.username.isEmpty ? "no" : "yes"), password present: \(saved.hasPassword ? "yes" : "no"), "
             + "secret present: \(saved.hasTOTPSecret ? "yes" : "no")")
        let wantsPassword = form.fields.contains { $0.kind == .password }
        let wantsPasscode = form.fields.contains { $0.kind == .passcode }
        var password: String?
        if !secretsLoaded, (wantsPassword && saved.hasPassword) || (wantsPasscode && saved.hasTOTPSecret) {
            secretsLoaded = true
            do {
                let secrets = try await credentials.loadForLogin(
                    host: host, reason: loc("sign in to \(host)", "sich bei \(host) anzumelden"))
                password = secrets.password
                storedTOTP = secrets.totp
            } catch {
                vlog("login: stored credentials not read: \(error)")
            }
        }
        for f in form.fields where !f.readOnly {
            switch f.kind {
            case .username where !saved.username.isEmpty:
                draft[f.id] = saved.username
                prefilledFromStore.insert(f.id)
            case .password:
                if let password { draft[f.id] = password; prefilledFromStore.insert(f.id) }
                password = nil   // one password field gets it; drop our copy
            case .passcode:
                if let totp = storedTOTP {
                    busy = true
                    render()
                    draft[f.id] = await Task.detached { totp.freshCode(statePath: Paths.totpState) }.value
                    busy = false
                    prefilledFromStore.insert(f.id)
                }
            default: break
            }
        }
        if saved.hasTOTPSecret { remember = true }
    }

    /// With everything stored (username, password, TOTP secret) a login needs no typing.
    private func autoSubmitIfComplete(_ form: LogonForm) {
        guard !form.isRePrompt, !form.fields.contains(where: { $0.kind == .error }) else { return }
        let inputs = form.fields.filter { $0.isInput && $0.kind != .checkbox && !$0.readOnly }
        guard !inputs.isEmpty, inputs.allSatisfy({ prefilledFromStore.contains($0.id) }), isValid() else { return }
        vlog("login: all fields prefilled from the Keychain; submitting")
        submit(nil)
    }

    @objc private func submit(_ sender: Any?) {
        guard let form, let logon, !busy, isValid() else { return }
        captureDraft()
        let button = (sender as? NSButton)?.identifier?.rawValue
        var values: [String: String] = [:]
        var secret: String?
        for f in form.fields where f.isInput && !f.readOnly {
            if f.kind == .checkbox {
                if !f.isSaveCredentials { values[f.id] = draft[f.id] == "true" ? "true" : "false" }
                continue
            }
            if f.kind == .passcode, askSecret {
                secret = draft[Self.secretFieldID]
                continue
            }
            values[f.id] = draft[f.id] ?? ""
        }
        if let f = form.fields.first(where: { $0.kind == .username }) { postedUsername = values[f.id] }
        if let f = form.fields.first(where: { $0.kind == .password }) { postedPassword = values[f.id] }
        busy = true
        render()
        let passcodeField = form.fields.first { $0.kind == .passcode && !$0.readOnly }
        let posted = values
        values = [:]
        task = Task { [weak self] in
            var values = posted
            if let secret, let passcodeField, let self {
                guard let totp = self.credentials.settings.load().totp(secret: secret) else { return }
                self.postedSecret = secret
                values[passcodeField.id] = await Task.detached { totp.freshCode(statePath: Paths.totpState) }.value
            }
            do {
                let step = try await logon.submit(form, values: values, button: button)
                values = [:]
                guard let self, !Task.isCancelled else { return }
                switch step {
                case .success: self.succeeded()
                case .form(let next): await self.show(next)
                case .failed(let text): self.failed(text)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failed(error.localizedDescription)
            }
        }
    }

    private func failed(_ text: String) {
        vlog("login: failed")
        busy = false
        form = nil
        message = text
        render()
    }

    private func succeeded() {
        vlog("login: success after \(formsShown) form(s); rendered kinds: \(renderedKinds.map { $0.joined(separator: ",") }.joined(separator: " | "))")
        if let host = service.gateway?.host {
            let username = postedUsername ?? credentials.settings.load().username
            if remember, !username.isEmpty {
                do {
                    try credentials.remember(host: host, username: username, password: postedPassword, totpSecret: postedSecret)
                } catch {
                    vlog("login: not remembered: \(error)")
                }
            } else if !remember, credentials.saved(host: host).hasPassword {
                credentials.forgetAll(host: host)
            }
        }
        clearSecrets()
        busy = false
        window?.orderOut(nil)
        let list = waiting
        waiting = []
        list.forEach { $0.resume() }
    }

    private func clearSecrets() {
        postedPassword = nil
        postedSecret = nil
        storedTOTP = nil
        draft = [:]
        for control in controls.values { (control as? NSTextField)?.stringValue = "" }
    }

    @objc private func cancel(_ sender: Any?) {
        task?.cancel()
        if let form, let logon { Task { await logon.cancel(form) } }
        form = nil
        clearSecrets()
        busy = false
        window?.orderOut(nil)
        let list = waiting
        waiting = []
        list.forEach { $0.resume(throwing: LoginCancelled()) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(nil)
        return false
    }

    @objc private func gatewayEdited() {
        gatewayField.stringValue = FieldText.clean(gatewayField.stringValue, password: false, final: true)
        let text = gatewayField.stringValue
        guard let url = LoginSettings.gatewayURL(from: text) else {
            if !text.isEmpty {
                message = loc("Enter the gateway address, e.g. gateway.example.com.",
                              "Bitte die Gateway-Adresse eingeben, z. B. gateway.example.com.")
                render()
            }
            return
        }
        guard url.host != service.gateway?.host || form == nil else { return }
        vlog("login: gateway set to \(url.host ?? "?")")
        service.setGateway(url)
        start()
    }

    @objc private func retry() { start() }

    @objc private func rememberToggled(_ sender: NSButton) {
        captureDraft()
        remember = sender.state == .on
        askSecret = remember && storedTOTP == nil && form?.fields.contains { $0.kind == .passcode && !$0.readOnly } == true
        render()
    }

    @objc private func enterCodeInstead() {
        captureDraft()
        askSecret = false
        render()
    }

    @objc private func forgetSaved() {
        guard let host = service.gateway?.host else { return }
        credentials.forgetAll(host: host)
        for id in prefilledFromStore { draft[id] = nil }
        prefilledFromStore = []
        storedTOTP = nil
        remember = false
        askSecret = false
        render()
    }

    // MARK: Values and validation

    private func captureDraft() {
        for (id, control) in controls {
            if let button = control as? NSButton {
                draft[id] = button.state == .on ? "true" : "false"
            } else if let field = control as? NSTextField {
                draft[id] = FieldText.clean(field.stringValue, password: isPasswordField(field), final: true)
            }
        }
    }

    private func isValid() -> Bool {
        guard let form else { return false }
        for f in form.fields where f.isInput && !f.readOnly && f.kind != .checkbox {
            if f.kind == .passcode, askSecret {
                let secret = (controls[Self.secretFieldID] as? NSTextField)?.stringValue ?? draft[Self.secretFieldID] ?? ""
                if credentials.settings.load().totp(secret: secret) == nil { return false }
                continue
            }
            let value = (controls[f.id] as? NSTextField)?.stringValue ?? draft[f.id] ?? ""
            if !f.accepts(value) { return false }
        }
        return true
    }

    private func updateSubmitState() {
        submitButton?.isEnabled = !busy && isValid()
    }

    /// Field lengths before the last edit, to tell a paste (several characters at once) from typing.
    private var lengths: [ObjectIdentifier: Int] = [:]

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            sanitise(field, editor: obj.userInfo?["NSFieldEditor"] as? NSTextView)
        }
        updateSubmitState()
    }

    /// No line breaks in single-line fields (pasted text often ends with one); see `FieldText`.
    private func sanitise(_ field: NSTextField, editor: NSTextView?) {
        let text = field.stringValue
        let pasted = text.count - (lengths[ObjectIdentifier(field)] ?? 0) > 1
            || text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
        let clean = FieldText.clean(text, password: isPasswordField(field), final: pasted)
        if clean != text {
            if let editor { editor.string = clean } else { field.stringValue = clean }
        }
        lengths[ObjectIdentifier(field)] = clean.count
    }

    private func isPasswordField(_ field: NSTextField) -> Bool {
        guard let id = field.identifier?.rawValue, let f = form?.fields.first(where: { $0.id == id }) else { return false }
        return f.kind == .password || f.kind == .newPassword || (f.kind == .text && f.secret)
    }

    // MARK: Rendering

    private func render() {
        guard let window else { return }
        controls = [:]
        submitButton = nil
        var rows: [NSView] = []

        if let message { rows.append(wrapping(message, style: .error)) }

        var buttons: [LogonForm.Field] = []
        var grid: NSGridView?
        func gridRow(_ label: String, _ view: NSView) {
            if grid == nil {
                let g = NSGridView(numberOfColumns: 2, rows: 0)
                g.rowSpacing = 8
                g.columnSpacing = 8
                g.rowAlignment = .firstBaseline
                grid = g
                rows.append(g)
            }
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            grid!.addRow(with: [label.isEmpty ? NSGridCell.emptyContentView : text, view])
        }
        func endGrid() {
            if let g = grid, g.numberOfColumns == 2 {
                g.column(at: 0).xPlacement = .trailing
                g.column(at: 1).width = 240
            }
            grid = nil
        }

        if let form {
            var rememberShown = false
            for f in form.fields {
                switch f.kind {
                case .heading:
                    endGrid()
                    rows.append(wrapping(f.label, style: .heading))
                case .label:
                    endGrid()
                    rows.append(wrapping(f.label, style: .plain))
                case .error:
                    endGrid()
                    rows.append(wrapping(f.label, style: .error))
                case .button:
                    buttons.append(f)
                case .checkbox where f.isSaveCredentials:
                    rememberShown = true
                    gridRow("", rememberCheckbox())
                case .checkbox:
                    let box = NSButton(checkboxWithTitle: f.label, target: self, action: #selector(checkboxChanged))
                    box.state = (draft[f.id] ?? f.initialValue) == "true" ? .on : .off
                    box.isEnabled = !f.readOnly && !busy
                    controls[f.id] = box
                    gridRow("", box)
                case .passcode where askSecret && !f.readOnly:
                    let field = textField(id: Self.secretFieldID, secure: true, content: nil, field: nil)
                    field.placeholderString = loc("Base32 secret", "Base32-Geheimnis")
                    gridRow(loc("TOTP secret:", "TOTP-Geheimnis:"), field)
                    let note = wrapping(loc("Future sign-ins generate the passcode from this secret automatically. "
                                            + "It is stored in the Keychain and needs Touch ID or your Mac password.",
                                            "Künftige Anmeldungen erzeugen den Passcode aus diesem Geheimnis automatisch. "
                                            + "Es liegt im Schlüsselbund und braucht Touch ID oder das Mac-Kennwort."),
                                        style: .small)
                    note.preferredMaxLayoutWidth = 240
                    gridRow("", note)
                    let instead = NSButton(title: loc("Enter the code instead", "Stattdessen Code eingeben"),
                                           target: self, action: #selector(enterCodeInstead))
                    instead.bezelStyle = .inline
                    instead.controlSize = .small
                    gridRow("", instead)
                default:
                    let secure = f.kind == .password || f.kind == .newPassword || (f.kind == .text && f.secret)
                    let content: NSTextContentType? = switch f.kind {
                    case .username: .username
                    case .password: .password
                    case .newPassword: .newPassword
                    case .passcode: .oneTimeCode
                    default: nil
                    }
                    gridRow(f.label, textField(id: f.id, secure: secure, content: content, field: f))
                }
            }
            // Our Keychain option also where the gateway offers no "remember" checkbox.
            if !rememberShown, form.fields.contains(where: { $0.kind == .password }) {
                gridRow("", rememberCheckbox())
            }
            endGrid()
        } else if service.gateway == nil {
            rows.append(wrapping(loc("Enter the address of your Citrix Gateway.",
                                     "Bitte die Adresse Ihres Citrix Gateways eingeben."), style: .plain))
        }

        // Buttons: forget (left), spinner, cancel, submit (default)
        var bar: [NSView] = []
        if let host = service.gateway?.host, form != nil {
            let saved = credentials.saved(host: host)
            if saved.hasPassword || saved.hasTOTPSecret {
                let forget = NSButton(title: loc("Forget Saved Login", "Gespeicherte Anmeldung vergessen"),
                                      target: self, action: #selector(forgetSaved))
                forget.controlSize = .small
                forget.bezelStyle = .inline
                forget.isEnabled = !busy
                bar.append(forget)
            }
        }
        bar.append(NSView())   // flexible space
        bar.append(spinner)
        let cancelButton = NSButton(title: loc("Cancel", "Abbrechen"), target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        bar.append(cancelButton)
        if form != nil {
            for (index, b) in buttons.enumerated() {
                let button = NSButton(title: b.label, target: self, action: #selector(submit(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(b.id)
                if index == 0 {
                    button.keyEquivalent = "\r"
                    submitButton = button
                }
                bar.append(button)
            }
            if buttons.isEmpty {
                let button = NSButton(title: loc("Sign In", "Anmelden"), target: self, action: #selector(submit(_:)))
                button.keyEquivalent = "\r"
                submitButton = button
                bar.append(button)
            }
        } else if !busy {
            let title = service.gateway == nil || message == nil ? loc("Continue", "Weiter") : loc("Try Again", "Erneut versuchen")
            let button = NSButton(title: title, target: self,
                                  action: service.gateway == nil ? #selector(gatewayEdited) : #selector(retry))
            button.keyEquivalent = "\r"
            bar.append(button)
        }
        let buttonRow = NSStackView(views: bar)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        bar[bar.firstIndex { type(of: $0) == NSView.self }!].setContentHuggingPriority(.init(1), for: .horizontal)

        // Gateway address: small and editable.
        let gatewayLabel = NSTextField(labelWithString: "Gateway:")
        gatewayLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gatewayLabel.textColor = .secondaryLabelColor
        gatewayField.isEnabled = !busy
        let gatewayRow = NSStackView(views: [gatewayLabel, gatewayField])
        gatewayRow.orientation = .horizontal
        gatewayRow.spacing = 4

        rows.append(buttonRow)
        rows.append(gatewayRow)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        for view in rows where view !== gatewayRow {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateSubmitState()
        focusFirstEmpty()
    }

    private func rememberCheckbox() -> NSButton {
        let box = NSButton(checkboxWithTitle: loc("Remember in Keychain", "Im Schlüsselbund merken"),
                           target: self, action: #selector(rememberToggled(_:)))
        box.state = remember ? .on : .off
        box.isEnabled = !busy
        return box
    }

    @objc private func checkboxChanged(_ sender: NSButton) { captureDraft() }

    private func textField(id: String, secure: Bool, content: NSTextContentType?, field: LogonForm.Field?) -> NSTextField {
        let control = secure ? NSSecureTextField() : NSTextField()
        control.identifier = NSUserInterfaceItemIdentifier(id)
        control.contentType = content
        control.stringValue = draft[id] ?? field?.initialValue ?? ""
        control.isEditable = !(field?.readOnly ?? false) && !busy
        control.isSelectable = true
        control.delegate = self
        control.target = self
        control.action = #selector(fieldReturn)
        controls[id] = control
        return control
    }

    /// Return in a field: next empty field, else submit.
    @objc private func fieldReturn(_ sender: NSTextField) {
        if !focusFirstEmpty() { submitButton?.performClick(nil) }
    }

    @discardableResult
    private func focusFirstEmpty() -> Bool {
        guard let form, !busy else { return false }
        let order = form.fields.map { $0.kind == .passcode && askSecret ? Self.secretFieldID : $0.id }
        for id in order {
            if let field = controls[id] as? NSTextField, field.isEditable, field.stringValue.isEmpty {
                window?.makeFirstResponder(field)
                return true
            }
        }
        return false
    }

    private enum TextStyle { case heading, plain, error, small }

    private func wrapping(_ text: String, style: TextStyle) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        switch style {
        case .heading: label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        case .plain: break
        case .error: label.textColor = .systemRed
        case .small:
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        return label
    }

    // MARK: Test mode

    private func runAutofill(_ form: LogonForm) async {
        guard !autofillDone.contains(formsShown) else { return }
        autofillDone.insert(formsShown)
        if form.isRePrompt || !form.errors.isEmpty {
            vlog("autofill: the gateway re-prompted or reported an error; stopping (no retry)")
            NSApp.terminate(nil)
            return
        }
        try? await Task.sleep(for: .seconds(1))
        guard let env = service.env else { vlog("autofill: no .env"); return }
        if autofillRemember, !remember, let box = window?.contentView.flatMap(findRememberBox) {
            box.performClick(nil)
            if askSecret { enterCodeInstead() }
        }
        var filled: [String] = []
        for f in form.fields where !f.readOnly {
            guard let field = controls[f.id] as? NSTextField, field.stringValue.isEmpty else { continue }
            filled.append(f.id)
            switch f.kind {
            case .username: field.stringValue = env["CITRIX_USERNAME"].map { StoreService.envUsername(env, $0) } ?? ""
            case .password: field.stringValue = env["CITRIX_PASSWORD"] ?? ""
            case .passcode:
                guard let totp = StoreService.envTOTP(env) else { continue }
                field.stringValue = await Task.detached { totp.freshCode(statePath: Paths.totpState) }.value
            default: continue
            }
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        vlog("autofill: filled \(filled.joined(separator: ",")) (others prefilled or empty); pressing the default button")
        submitButton?.performClick(nil)
    }

    private func findRememberBox(_ view: NSView) -> NSButton? {
        if let b = view as? NSButton, b.action == #selector(rememberToggled(_:)) { return b }
        for sub in view.subviews { if let b = findRememberBox(sub) { return b } }
        return nil
    }

    /// Screenshot of only this window (screencapture -l), 0600.
    private func captureWindow(to path: String) {
        guard let number = window?.windowNumber else { return }
        vlog("login window number \(number)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(number)", path]
        try? process.run()
        process.waitUntilExit()
        chmod(path, 0o600)
        vlog("screenshot: \(FileManager.default.fileExists(atPath: path) ? "saved" : "failed")")
    }
}
