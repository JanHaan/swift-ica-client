import AppHostKit
import AppKit
import ICAKit

/// Settings (Cmd-,) in the Mac settings-window style (HIG, Settings; docs/ux/audit.md U5): four toolbar panes
/// (General, Account, Devices, Display) with SF Symbols, the window titled by the pane, the last pane restored,
/// and every change applied at once, with no Save or Cancel (text fields when editing ends). Contents:
/// gateway, username, password, passcode mode with TOTP secret, forget all, and
/// display scaling (Windows scaling, client scaling; D29, docs/80 §4). Secrets are written to the
/// Keychain only; the fields never show stored values. Scaling applies at connect; saving a change
/// while sessions run offers to reconnect them. The shared folder (client drive M, docs/95 §A, D32)
/// applies at the next connect, as does printing (docs/97 §6, PDF mode: receive jobs from the host's Citrix PDF
/// Printer; which action the job window offers first) and session audio (docs/98 §10.4: play session sounds,
/// default on; the volume follows macOS; the microphone, default off per §10.4, opens only while the host records) and
/// the camera (docs/98b §10.5: default off; opens only between the host's PLAY and STOP; which camera, by unique id,
/// "Automatic" = the system default; listing the devices never opens one or asks for permission).
/// Dock apps (docs/99 §12.2, D63): "One Dock entry per app" (default on; applies at the next start of ICA Viewer;
/// ICA_HELPER_APPS=0/1 overrides it) and the launcher's global shortcut (⌃⌥⌘L, two other letters, or off;
/// applies at once). After a connection drop (docs/90 §9.6, D86): reconnect automatically (default) or ask; applies at
/// the next drop. "Copy files through the clipboard" (D90, docs/75): default on; applies at the next connect.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let service: StoreService
    /// Demo mode (ICAVIEWER_DEMO=1): example data, nothing is read from or written to settings or Keychain.
    private let demo: Bool
    private var credentials: LoginCredentials { service.credentials }

    private let gatewayField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    /// A UI text in both languages: shown with `loc`, measured in both so no language truncates.
    struct Text {
        let en: String, de: String
        var shown: String { loc(en, de) }
        var both: [String] { [en, de] }
    }
    typealias T = SettingsWindowController
    static let protectTitle = Text(en: "Require Touch ID or the Mac password to use it", de: "Nur mit Touch ID oder Mac-Kennwort verwenden")
    static let promptTitle = Text(en: "Enter the passcode at each sign-in", de: "Passcode bei jeder Anmeldung eingeben")
    static let totpTitle = Text(en: "Save the TOTP secret (codes are generated)", de: "TOTP-Geheimnis speichern (Codes werden erzeugt)")
    static let shareTitle = Text(en: "Share a folder with sessions as drive M", de: "Einen Ordner als Laufwerk M für Sitzungen freigeben")
    static let readOnlyTitle = Text(en: "Read-only (the session cannot change files)", de: "Nur lesen (die Sitzung kann nichts ändern)")
    static let printTitle = Text(en: "Receive print jobs", de: "Druckaufträge empfangen")
    static let printHint = Text(en: "From the Citrix PDF Printer in the session.", de: "Vom Citrix PDF Printer in der Sitzung.")
    static let audioTitle = Text(en: "Play session sounds", de: "Sitzungstöne abspielen")
    static let audioHint = Text(en: "The volume follows the Mac.", de: "Die Lautstärke folgt dem Mac.")
    static let micTitle = Text(en: "Pass the microphone to the session", de: "Mikrofon an die Sitzung weitergeben")
    static let micHint = Text(en: "Only while a session app records.", de: "Nur während eine Sitzungs-App aufnimmt.")
    static let cameraTitle = Text(en: "Pass the camera to the session", de: "Kamera an die Sitzung weitergeben")
    static let cameraAutomatic = Text(en: "Automatic (system default)", de: "Automatisch (Systemstandard)")
    static let cameraHint = Text(en: "Only while a session app uses it; 32-bit apps only.",
                                 de: "Nur während eine Sitzungs-App sie nutzt; nur 32-Bit-Apps.")
    static let compressTitle = Text(en: "Compress screen data", de: "Bildschirmdaten komprimieren")
    static let compressHint = Text(en: "The server sends about a quarter of the data; useful on slow connections. Applies at the next connect.",
                                   de: "Der Server sendet etwa ein Viertel der Daten; hilfreich bei langsamen Verbindungen. Gilt ab der nächsten Verbindung.")
    static let clipFilesTitle = Text(en: "Copy files through the clipboard", de: "Dateien über die Zwischenablage kopieren")
    static let clipFilesHint = Text(en: "Copy in Finder and paste in the session, or the other way round. Applies at the next connect.",
                                    de: "Im Finder kopieren und in der Sitzung einsetzen, oder umgekehrt. Gilt ab der nächsten Verbindung.")
    static let clipLimitHint = Text(en: "Above this size ICA Viewer asks before copying from the session, and copies to the session stop.",
                                    de: "Ab dieser Größe fragt ICA Viewer vor Kopien aus der Sitzung, und Kopien in die Sitzung enden.")
    static let dropAutomatic = Text(en: "Reconnect automatically", de: "Automatisch erneut verbinden")
    static let dropAsk = Text(en: "Ask", de: "Fragen")
    static let dropHint = Text(en: "For drops longer than a few seconds; short ones always resume by themselves.",
                               de: "Für Ausfälle über einige Sekunden; kurze werden immer von selbst überbrückt.")
    static let dockTitle = Text(en: "One Dock entry per app", de: "Ein Dock-Eintrag pro App")
    static let dockHint = Text(en: "Each remote app gets its own Dock icon and ⌘-Tab entry. Applies when ICA Viewer starts next.",
                               de: "Jede Remote-App erhält ein eigenes Dock-Symbol und einen eigenen ⌘-Tab-Eintrag. Gilt ab dem nächsten Start von ICA Viewer.")
    static let dockOverride = Text(en: "ICA_HELPER_APPS overrides this setting in this run.",
                                   de: "ICA_HELPER_APPS hat in diesem Lauf Vorrang vor dieser Einstellung.")
    static let shortcutOff = Text(en: "Off", de: "Aus")
    static let shortcutHint = Text(en: "Global shortcut: opens the launcher from any app.",
                                   de: "Globaler Kurzbefehl: öffnet den Launcher aus jeder App.")
    static let shortcutTaken = Text(en: "Another app already uses this shortcut; choose another one.",
                                    de: "Eine andere App nutzt diesen Kurzbefehl bereits; bitte einen anderen wählen.")
    static let offerTitle = Text(en: "Offer to reconnect disconnected sessions", de: "Erneutes Verbinden getrennter Sitzungen anbieten")
    static let staleHint = Text(en: "Open sessions keep their scaling until they reconnect; your apps keep running.",
                                de: "Offene Sitzungen behalten ihre Skalierung bis zum erneuten Verbinden; die Apps laufen weiter.")

    /// The panes, in toolbar order.
    enum Pane: Int, CaseIterable {
        case general, account, devices, display
        var title: Text {
            switch self {
            case .general: Text(en: "General", de: "Allgemein")
            case .account: Text(en: "Account", de: "Account")
            case .devices: Text(en: "Devices", de: "Geräte")
            case .display: Text(en: "Display", de: "Anzeige")
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .account: "person.crop.circle"
            case .devices: "externaldrive.connected.to.line.below"
            case .display: "display"
            }
        }
        static let defaultsKey = "settingsPane"
    }
    /// Row labels (column 0), in grid order.
    static let rowLabels: [String: Text] = [
        "gateway": Text(en: "Gateway or store:", de: "Gateway oder Store:"), "user": Text(en: "User name:", de: "Benutzername:"),
        "password": Text(en: "Password:", de: "Kennwort:"), "passcode": Text(en: "Passcode:", de: "Passcode:"),
        "secret": Text(en: "TOTP secret:", de: "TOTP-Geheimnis:"), "code": Text(en: "Code:", de: "Code:"),
        "windows": Text(en: "Windows scaling:", de: "Windows-Skalierung:"), "client": Text(en: "Client scaling:", de: "Client-Skalierung:"),
        "share": Text(en: "Shared folder:", de: "Freigabe:"), "print": Text(en: "Printing:", de: "Drucken:"),
        "audio": Text(en: "Audio:", de: "Audio:"), "camera": Text(en: "Camera:", de: "Kamera:"),
        "dock": Text(en: "Dock:", de: "Dock:"), "shortcut": Text(en: "Launcher:", de: "Launcher:"),
        "network": Text(en: "Network:", de: "Netzwerk:"),
        "clipboard": Text(en: "Clipboard:", de: "Zwischenablage:"),
        "drop": Text(en: "Connection drop:", de: "Verbindungsabbruch:"),
        "quit": Text(en: "When quitting:", de: "Beim Beenden:"), "start": Text(en: "At sign-in:", de: "Bei Anmeldung:"),
    ]

    private let protectBox = NSButton(checkboxWithTitle: T.protectTitle.shown, target: nil, action: nil)
    private let promptRadio = NSButton(radioButtonWithTitle: T.promptTitle.shown, target: nil, action: nil)
    private let totpRadio = NSButton(radioButtonWithTitle: T.totpTitle.shown, target: nil, action: nil)
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
    /// While `load()` fills the controls: no saving.
    private var loading = false
    private let shareBox = NSButton(checkboxWithTitle: T.shareTitle.shown, target: nil, action: nil)
    private let folderPath = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: loc("Choose…", "Auswählen …"), target: nil, action: nil)
    private let revealFolderButton = NSButton(title: loc("Show in Finder", "Im Finder zeigen"), target: nil, action: nil)
    private let readOnlyBox = NSButton(checkboxWithTitle: T.readOnlyTitle.shown, target: nil, action: nil)
    private var sharedFolder = CDMSettings.defaultFolder
    private let printBox = NSButton(checkboxWithTitle: T.printTitle.shown, target: nil, action: nil)
    private let printActionPopup = NSPopUpButton()
    private let audioBox = NSButton(checkboxWithTitle: T.audioTitle.shown, target: nil, action: nil)
    private let micBox = NSButton(checkboxWithTitle: T.micTitle.shown, target: nil, action: nil)
    private let cameraBox = NSButton(checkboxWithTitle: T.cameraTitle.shown, target: nil, action: nil)
    private let cameraPopup = NSPopUpButton()
    private let compressBox = NSButton(checkboxWithTitle: T.compressTitle.shown, target: nil, action: nil)
    private let clipFilesBox = NSButton(checkboxWithTitle: T.clipFilesTitle.shown, target: nil, action: nil)
    private let dropPopup = NSPopUpButton()
    private let clipLimitPopup = NSPopUpButton()
    private let dockBox = NSButton(checkboxWithTitle: T.dockTitle.shown, target: nil, action: nil)
    private let dockHint = NSTextField(wrappingLabelWithString: "")
    private let shortcutPopup = NSPopUpButton()
    private let shortcutHint = NSTextField(wrappingLabelWithString: "")
    private let quitPopup = NSPopUpButton()
    private let offerBox = NSButton(checkboxWithTitle: T.offerTitle.shown, target: nil, action: nil)
    private let reconnectNowButton = NSButton(title: loc("Reconnect Now", "Jetzt erneut verbinden"), target: nil, action: nil)
    private let staleNote = NSTextField(wrappingLabelWithString: T.staleHint.shown)
    private var reconnectRow: NSGridRow?
    private let tabs = SettingsTabs()
    /// One per popup item: nil = automatic, else the device (possibly a stored one that is not connected).
    private var cameraChoices: [CameraDevices.Device?] = [nil]
    private let cameraAccessNote = NSTextField(wrappingLabelWithString: "")
    private var cameraObservers: [NSObjectProtocol] = []
    private var cameraNoteRow: NSGridRow?
    private var timer: Timer?
    /// Secret read from the Keychain for the preview only; dropped after one period.
    private var previewTOTP: TOTP?
    private var previewUntil = Date.distantPast

    init(service: StoreService, demo: Bool = false) {
        self.service = service
        self.demo = demo
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Pane.general.title.shown
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
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
        observeCameras()
        let first = window?.isVisible != true
        showWindow(nil)
        if first { window?.center() }
        NSApp.activate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreview() }
        }
    }

    /// A field still being edited is applied first (its editing ends), then the secrets are dropped.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        clearSecrets()
        cameraObservers.forEach(NotificationCenter.default.removeObserver)
        cameraObservers = []
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
        gatewayField.placeholderString = loc("gateway.example.com or storefront.example.com/Citrix/StoreWeb",
                                         "gateway.example.com oder storefront.example.com/Citrix/StoreWeb")
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
        scalingNote.textColor = .secondaryText
        scalingNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scalingNote.maximumNumberOfLines = 4
        scalingNote.setContentCompressionResistancePriority(.required, for: .vertical)
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
        cameraBox.target = self
        cameraBox.action = #selector(cameraChanged)
        cameraPopup.addItem(withTitle: T.cameraAutomatic.shown)
        // Device names are not ours to shorten, but a long one must not widen the window.
        (cameraPopup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        printActionPopup.addItems(withTitles: [loc("Show the print dialog first", "Zuerst den Druckdialog zeigen"),
                                               loc("Open in Preview first", "Zuerst in Vorschau öffnen")])
        // Same order as `AutoReconnect.Mode.allCases`.
        dropPopup.addItems(withTitles: [T.dropAutomatic.shown, T.dropAsk.shown])
        clipLimitPopup.addItems(withTitles: ClipboardFilesSetting.softLimitChoices.map { gb in
            gb > 0 ? loc("Ask above \(gb) GB", "Ab \(gb) GB fragen") : loc("Never ask", "Nie fragen")
        })
        for choice in LauncherHotKey.choices { shortcutPopup.addItem(withTitle: choice.shortcut == nil ? T.shortcutOff.shown : choice.title) }
        folderPath.lineBreakMode = .byTruncatingMiddle
        folderPath.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        status.textColor = .secondaryText
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        func label(_ key: String) -> NSTextField {
            let l = NSTextField(labelWithString: T.rowLabels[key]!.shown)
            l.alignment = .right
            return l
        }
        let widths = Self.columnWidths(popups: [windowsScalingPopup, clientScalingPopup, printActionPopup, shortcutPopup, dropPopup, clipLimitPopup])
        func hint(_ text: Text) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text.shown)
            l.textColor = .secondaryText
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.preferredMaxLayoutWidth = widths.column1
            return l
        }
        cameraAccessNote.textColor = .secondaryText
        cameraAccessNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cameraAccessNote.preferredMaxLayoutWidth = widths.column1
        for note in [dockHint, shortcutHint] {
            note.textColor = .secondaryText
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.preferredMaxLayoutWidth = widths.column1
            note.maximumNumberOfLines = 0
            note.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        cameraPopup.widthAnchor.constraint(lessThanOrEqualToConstant: widths.column1).isActive = true
        scalingNote.preferredMaxLayoutWidth = widths.column1
        scalingNote.widthAnchor.constraint(equalToConstant: widths.column1).isActive = true
        let params = NSStackView(views: [digitsPopup, NSTextField(labelWithString: loc("digits", "Stellen")),
                                         periodField, NSTextField(labelWithString: loc("s", "s")), algorithmPopup])
        params.spacing = 6
        let previewRow = NSStackView(views: [preview, showCodeButton])
        previewRow.spacing = 8
        let folderRow = NSStackView(views: [folderPath, chooseFolderButton, revealFolderButton])
        folderRow.spacing = 6
        quitPopup.addItems(withTitles: QuitAction.allCases.map(\.title))
        staleNote.textColor = .secondaryText
        staleNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        staleNote.preferredMaxLayoutWidth = widths.column1
        reconnectNowButton.target = self
        reconnectNowButton.action = #selector(reconnectNow)
        let staleRow = NSStackView(views: [staleNote, reconnectNowButton])
        staleRow.orientation = .vertical
        staleRow.alignment = .leading
        staleRow.spacing = 6
        let empty = NSGridCell.emptyContentView
        let forget = NSButton(title: loc("Forget All Saved Credentials", "Alle gespeicherten Anmeldedaten vergessen"),
                              target: self, action: #selector(forgetAll))

        let general = grid(widths, [
            [label("shortcut"), shortcutPopup], [empty, shortcutHint],
            [label("dock"), dockBox], [empty, dockHint],
            [label("quit"), quitPopup],
            [label("start"), offerBox],
            [label("drop"), dropPopup], [empty, hint(T.dropHint)],
        ])
        let account = grid(widths, [
            [label("gateway"), gatewayField],
            [label("user"), usernameField],
            [label("password"), passwordField],
            [empty, protectBox],
            [label("passcode"), promptRadio],
            [empty, totpRadio],
            [label("secret"), secretField],
            [label("code"), params],
            [empty, previewRow],
        ])
        let devices = grid(widths, [
            [label("clipboard"), clipFilesBox], [empty, hint(T.clipFilesHint)],
            [empty, clipLimitPopup], [empty, hint(T.clipLimitHint)],
            [label("share"), shareBox], [empty, folderRow], [empty, readOnlyBox],
            [label("print"), printBox], [empty, hint(T.printHint)], [empty, printActionPopup],
            [label("audio"), audioBox], [empty, hint(T.audioHint)], [empty, micBox], [empty, hint(T.micHint)],
            [label("camera"), cameraBox], [empty, cameraPopup], [empty, hint(T.cameraHint)], [empty, cameraAccessNote],
        ])
        cameraNoteRow = devices.row(at: devices.numberOfRows - 1)
        cameraNoteRow?.isHidden = true   // shown only when the camera list needs an access hint
        let display = grid(widths, [
            [label("windows"), windowsScalingPopup],
            [label("client"), clientScalingPopup],
            [empty, scalingNote],
            [empty, staleRow],
            [label("network"), compressBox], [empty, hint(T.compressHint)],
        ])
        reconnectRow = display.row(at: 3)
        reconnectRow?.isHidden = true
        digitsPopup.setAccessibilityLabel(loc("Passcode digits", "Passcode-Stellen"))
        periodField.setAccessibilityLabel(loc("Passcode period in seconds", "Passcode-Gültigkeit in Sekunden"))
        algorithmPopup.setAccessibilityLabel(loc("Passcode algorithm", "Passcode-Algorithmus"))
        for g in [general, account, devices, display] { Access.labelControls(in: g) }

        // Every control applies its change at once.
        for c in [shortcutPopup, dockBox, quitPopup, offerBox, dropPopup, compressBox, clipFilesBox, clipLimitPopup] as [NSControl] {
            c.target = self
            c.action = #selector(generalChanged)
        }
        readOnlyBox.target = self
        readOnlyBox.action = #selector(shareChanged)
        printActionPopup.target = self
        printActionPopup.action = #selector(printChanged)
        micBox.target = self
        micBox.action = #selector(audioChanged)
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraChanged)
        protectBox.target = self
        protectBox.action = #selector(accountChanged)

        let status = self.status
        status.preferredMaxLayoutWidth = widths.column0 + 8 + widths.column1
        let accountFooter = NSStackView(views: [status, forget])
        accountFooter.orientation = .vertical
        accountFooter.alignment = .leading
        accountFooter.spacing = 10
        let panes: [(Pane, [NSView])] = [(.general, [general]), (.account, [account, accountFooter]),
                                         (.devices, [devices]), (.display, [display])]
        for (pane, views) in panes {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            stack.widthAnchor.constraint(equalToConstant: 20 + widths.column0 + 8 + widths.column1 + 20).isActive = true
            let vc = NSViewController()
            vc.view = stack
            let item = NSTabViewItem(viewController: vc)
            item.label = pane.title.shown
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        tabs.tabStyle = .toolbar
        tabs.onSelect = { [weak self] in self?.paneSelected() }
        let stored = UserDefaults.standard.integer(forKey: Pane.defaultsKey)
        tabs.selectedTabViewItemIndex = Pane(rawValue: stored) == nil ? 0 : stored
        window?.contentViewController = tabs
        updateScalingNote()
        paneSelected()
    }

    /// A two-column grid (label, control) with the spacing rule used in every pane: 14 pt above a labelled row,
    /// 2 pt above a hint, 6 pt above a further control of the same row group.
    private func grid(_ widths: (column0: CGFloat, column1: CGFloat), _ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 0
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        // Column widths from the widest text in either language (`columnWidths`), so nothing is clipped
        // or truncated in English or German, and every pane has the same width.
        grid.column(at: 0).width = widths.column0
        grid.column(at: 1).width = widths.column1
        for r in 1..<grid.numberOfRows {
            let labelled = (grid.cell(atColumnIndex: 0, rowIndex: r).contentView as? NSTextField)?.stringValue.isEmpty == false
            let isHint = (grid.cell(atColumnIndex: 1, rowIndex: r).contentView as? NSTextField).map { !$0.isEditable && $0.font?.pointSize == NSFont.smallSystemFontSize } ?? false
            grid.row(at: r).topPadding = labelled ? 14 : isHint ? 2 : 6
        }
        return grid
    }

    /// The pane changed: window title, size, the stored choice.
    private func paneSelected() {
        let index = max(tabs.selectedTabViewItemIndex, 0)
        if let pane = Pane(rawValue: index) {
            window?.title = pane.title.shown
            if !demo { UserDefaults.standard.set(index, forKey: Pane.defaultsKey) }
        }
        fitWindow(animate: window?.isVisible == true)
    }

    /// Column widths: column 0 fits the widest row label, column 1 the widest checkbox, radio button or
    /// popup (at least 360 pt), each measured in English and German. Logged in demo mode.
    static func columnWidths(popups: [NSPopUpButton]) -> (column0: CGFloat, column1: CGFloat) {
        let labels = rowLabels.values.flatMap(\.both).map { ($0, NSTextField(labelWithString: $0).fittingSize.width) }
        let boxes = [protectTitle, shareTitle, readOnlyTitle, printTitle, audioTitle, micTitle, cameraTitle, compressTitle, clipFilesTitle, dockTitle].flatMap(\.both)
            .map { ($0, NSButton(checkboxWithTitle: $0, target: nil, action: nil).fittingSize.width) }
        let radios = [promptTitle, totpTitle].flatMap(\.both)
            .map { ($0, NSButton(radioButtonWithTitle: $0, target: nil, action: nil).fittingSize.width) }
        let menus = popups.map { ($0.titleOfSelectedItem ?? "popup", $0.fittingSize.width) }
            + (cameraAutomatic.both + dropAutomatic.both).map { title -> (String, CGFloat) in
                let p = NSPopUpButton()
                p.addItem(withTitle: title)
                return (title, p.fittingSize.width)
            }
        let column0 = labels.max { $0.1 < $1.1 }!, column1 = (boxes + radios + menus).max { $0.1 < $1.1 }!
        let widths = (ceil(max(column0.1, 60)), ceil(max(column1.1, 360)))
        if Demo.enabled {
            vlog("settings layout: column 0 \(Int(widths.0)) pt (widest \"\(column0.0)\" \(Int(column0.1))), column 1 \(Int(widths.1)) pt (widest \"\(column1.0)\" \(Int(column1.1)))")
        }
        return widths
    }

    /// Fits the window to the current pane (panes differ in height; the scaling note and the camera hint change
    /// it), keeping the top edge. Animated only when visible and Reduce Motion is off.
    private func fitWindow(animate: Bool = false) {
        let index = tabs.selectedTabViewItemIndex
        guard let window, index >= 0, let view = tabs.tabViewItems[index].viewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 else { return }
        let frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height, width: size.width, height: size.height))
        let motion = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: window.isVisible, animate: motion)
    }

    private func loadDemo() {
        loading = true
        defer { loading = false }
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
        selectDockApps()
        status.stringValue = loc("Secrets are stored only in the Keychain (this Mac, no iCloud). ",
                                 "Geheimnisse liegen nur im Schlüsselbund (dieser Mac, kein iCloud). ")
        selectScaling(ScalingSettings())
        selectDriveMapping(CDMSettings())
        selectPrinting(PrintSettings())
        audioBox.state = AudioSettings.defaultEnabled ? .on : .off
        micBox.state = AudioSettings.defaultMicrophone ? .on : .off
        audioChanged()
        cameraBox.state = WebcamSettings.defaultEnabled ? .on : .off
        selectCamera(WebcamSettings(), devices: [])
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
        if !loading { saveDriveMapping() }
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
        guard !demo else { return }
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

    @objc private func printChanged() {
        printActionPopup.isEnabled = printBox.state == .on
        if !loading { savePrinting() }
    }

    private func savePrinting() {
        guard !demo else { return }
        var settings = PrintSettings.load(env: [:])
        settings.enabled = printBox.state == .on
        settings.action = printActionPopup.indexOfSelectedItem == 1 ? .preview : .printDialog
        guard settings != PrintSettings.load(env: [:]) else { return }
        settings.save()
        vlog("printing: saved (\(settings.enabled ? "on" : "off"), \(settings.action.rawValue) first); on/off applies at the next connect")
    }

    // MARK: Audio

    private func saveAudio() {
        guard !demo else { return }
        var settings = AudioSettings.load(env: [:])
        settings.enabled = audioBox.state == .on
        settings.microphone = micBox.state == .on
        guard settings != AudioSettings.load(env: [:]) else { return }
        settings.save()
        vlog("audio: saved (\(settings.enabled ? "on" : "off"), microphone \(settings.microphone ? "on" : "off")); applies at the next connect")
    }

    private func saveCamera() {
        guard !demo else { return }
        var settings = WebcamSettings.load(env: [:])
        settings.enabled = cameraBox.state == .on
        let index = cameraPopup.indexOfSelectedItem
        let choice = index >= 0 && index < cameraChoices.count ? cameraChoices[index] : nil
        settings.deviceID = choice?.id
        settings.deviceName = choice?.name
        guard settings != WebcamSettings.load(env: [:]) else { return }
        settings.save()
        vlog("webcam: saved (\(settings.enabled ? "on" : "off"), \(choice.map { "camera \"\($0.name)\"" } ?? "automatic camera")); applies at the next connect")
    }

    // MARK: Dock apps (docs/99 §12.2, §12.13)

    private func selectDockApps() {
        let stored = demo ? nil : UserDefaults.standard.object(forKey: HelperAppsSwitch.defaultsKey) as? Bool
        dockBox.state = (stored ?? HelperAppsSwitch.defaultOn) ? .on : .off
        compressBox.state = (demo ? CompressionSetting.defaultOn : CompressionSetting.stored) ? .on : .off
        clipFilesBox.state = (demo ? ClipboardFilesSetting.defaultOn : ClipboardFilesSetting.stored) ? .on : .off
        let limit = demo ? ClipboardFilesSetting.defaultSoftLimitGB : ClipboardFilesSetting.softLimitGB
        clipLimitPopup.selectItem(at: ClipboardFilesSetting.softLimitChoices.firstIndex(of: limit) ?? 2)
        let drop = demo ? AutoReconnect.Mode.defaultMode : AutoReconnectSetting.stored
        dropPopup.selectItem(at: AutoReconnect.Mode.allCases.firstIndex(of: drop) ?? 0)
        let overridden = !demo && HelperManager.setting.source == .environment
        dockHint.stringValue = T.dockHint.shown + (overridden ? " " + T.dockOverride.shown : "")
        quitPopup.selectItem(at: QuitAction.allCases.firstIndex(of: demo ? .ask : QuitAction.stored) ?? 0)
        offerBox.state = (demo || ReconnectAtStart.stored == .ask) ? .on : .off
        let hotKey = demo ? LauncherHotKey.standard : GlobalHotKey.stored
        shortcutPopup.selectItem(at: LauncherHotKey.choices.firstIndex(of: hotKey) ?? 0)
        let taken = !demo && GlobalHotKey.shared.state == .taken
        shortcutHint.stringValue = T.shortcutHint.shown + (taken ? " " + T.shortcutTaken.shown : "")
    }

    @objc private func generalChanged() { if !loading { saveDockApps() } }

    /// General and the on/off settings of Devices and Display that live in UserDefaults; only what changed is written.
    private func saveDockApps() {
        guard !demo else { return }
        let quit = QuitAction.allCases.indices.contains(quitPopup.indexOfSelectedItem) ? QuitAction.allCases[quitPopup.indexOfSelectedItem] : .ask
        if QuitAction.stored != quit {
            QuitAction.stored = quit
            vlog("quit action: \(quit.rawValue)")
        }
        let offer: ReconnectAtStart = offerBox.state == .on ? .ask : .never
        if ReconnectAtStart.stored != offer {
            ReconnectAtStart.stored = offer
            vlog("reconnect at start: \(offer.rawValue)")
        }
        let compress = compressBox.state == .on
        if CompressionSetting.stored != compress {
            CompressionSetting.stored = compress
            vlog("compression: saved \(compress ? "on" : "off"); applies at the next connect")
        }
        let clipFiles = clipFilesBox.state == .on
        if ClipboardFilesSetting.stored != clipFiles {
            ClipboardFilesSetting.stored = clipFiles
            vlog("clipboard files: saved \(clipFiles ? "on" : "off"); applies at the next connect")
        }
        let choices = ClipboardFilesSetting.softLimitChoices
        if choices.indices.contains(clipLimitPopup.indexOfSelectedItem), ClipboardFilesSetting.softLimitGB != choices[clipLimitPopup.indexOfSelectedItem] {
            ClipboardFilesSetting.softLimitGB = choices[clipLimitPopup.indexOfSelectedItem]
            vlog("clipboard files: soft limit saved: \(ClipboardFilesSetting.softLimitGB) GB (0 = never ask)")
        }
        let modes = AutoReconnect.Mode.allCases
        if modes.indices.contains(dropPopup.indexOfSelectedItem), AutoReconnectSetting.stored != modes[dropPopup.indexOfSelectedItem] {
            AutoReconnectSetting.stored = modes[dropPopup.indexOfSelectedItem]
            vlog("after a connection drop: saved \(AutoReconnectSetting.stored.rawValue)")
        }
        let on = dockBox.state == .on
        let stored = UserDefaults.standard.object(forKey: HelperAppsSwitch.defaultsKey) as? Bool
        if (stored ?? HelperAppsSwitch.defaultOn) != on {
            UserDefaults.standard.set(on, forKey: HelperAppsSwitch.defaultsKey)
            vlog("helper apps: saved \(on ? "on" : "off"); applies at the next start of ICA Viewer")
        }
        let index = shortcutPopup.indexOfSelectedItem
        guard LauncherHotKey.choices.indices.contains(index), LauncherHotKey.choices[index] != GlobalHotKey.stored else { return }
        GlobalHotKey.shared.change(to: LauncherHotKey.choices[index])
        let taken = GlobalHotKey.shared.state == .taken
        shortcutHint.stringValue = T.shortcutHint.shown + (taken ? " " + T.shortcutTaken.shown : "")
        fitWindow()
    }

    // MARK: Camera choice (docs/98b §10.5)

    @objc private func cameraChanged() {
        cameraPopup.isEnabled = cameraBox.state == .on
        if !loading { saveCamera() }
    }

    /// Fills the popup: "Automatic" first, then the connected devices; a stored device that is not connected stays
    /// listed (marked) so the choice is not lost. Discovery only: no device is opened, no permission is asked.
    private func selectCamera(_ settings: WebcamSettings, devices: [CameraDevices.Device]) {
        var choices: [CameraDevices.Device?] = [nil]
        choices += devices.map { Optional($0) }
        var missing: CameraDevices.Device?
        if let id = settings.deviceID, !devices.contains(where: { $0.id == id }) {
            missing = CameraDevices.Device(id: id, name: settings.deviceName ?? id)
            choices.append(missing)
        }
        cameraPopup.removeAllItems()
        for choice in choices {
            guard let device = choice else { cameraPopup.addItem(withTitle: T.cameraAutomatic.shown); continue }
            let title = device == missing ? loc("\(device.name) (not connected)", "\(device.name) (nicht verbunden)") : device.name
            // Titles must be unique for NSPopUpButton; two cameras with the same name get their id appended.
            cameraPopup.addItem(withTitle: cameraPopup.itemTitles.contains(title) ? "\(title) (\(device.id))" : title)
        }
        cameraChoices = choices
        cameraPopup.selectItem(at: choices.firstIndex { $0?.id == settings.deviceID && settings.deviceID != nil } ?? 0)
        cameraChanged()
        let note = demo ? nil : CameraDevices.accessHint(listEmpty: devices.isEmpty)
        cameraAccessNote.stringValue = note ?? ""
        if let row = cameraNoteRow, row.isHidden != (note == nil) {
            row.isHidden = note == nil
            fitWindow()
        }
    }

    /// Refreshes the list while Settings is open when a camera is connected or disconnected (keeps the selection).
    private func observeCameras() {
        guard cameraObservers.isEmpty else { return }
        for name in CameraDevices.changeNotifications {
            cameraObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCameras() }
            })
        }
    }

    private func refreshCameras() {
        var current = WebcamSettings.load(env: [:])
        let index = cameraPopup.indexOfSelectedItem
        let choice = index >= 0 && index < cameraChoices.count ? cameraChoices[index] : nil
        current.deviceID = choice?.id
        current.deviceName = choice?.name
        selectCamera(current, devices: CameraDevices.list())
    }

    /// The microphone goes through the same channel: without session audio there is none.
    @objc private func audioChanged() {
        micBox.isEnabled = audioBox.state == .on
        if !loading { saveAudio() }
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

    @objc private func scalingChanged() {
        updateScalingNote()
        if !loading { saveScaling() }
    }

    /// The scaling note: first why the running (else the last) session uses 1x, if it fell back; then
    /// what the current screens get with the chosen settings, also when no session is connected.
    private func updateScalingNote() {
        // (text, is a fallback): fallbacks get ⓘ and the normal label colour, a plain summary stays grey.
        var lines: [(String, Bool)] = []
        if let running = SessionController.running.last {
            if let note = running.layout.note { lines.append((scalingNoteText(note, context: .current), true)) }
        } else if let last = SessionController.lastLayout, let note = last.note {
            lines.append((scalingNoteText(note, context: .last), true))
        }
        let layout = ScalingLayout.resolve(screens: SessionController.currentScreens(), settings: selectedScaling,
                                           limit: ScalingLimits.sessionLimit())
        lines.append(layout.note.map { (scalingNoteText($0, context: .screens), true) } ?? (scalingSummary(layout), false))
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString()
        for (i, (line, fallback)) in lines.enumerated() {
            text.append(NSAttributedString(string: (i > 0 ? "\n" : "") + (fallback ? "ⓘ " : "") + line,
                                           attributes: [.font: font, .foregroundColor: fallback ? NSColor.labelColor : NSColor.secondaryText]))
        }
        scalingNote.attributedStringValue = text
        scalingNote.toolTip = text.string
        fitWindow()
    }

    /// Saves the scaling choice. Running sessions that connected with other settings keep them; the pane then
    /// shows a note and Reconnect Now (disconnect and relaunch; never a logoff) instead of an alert.
    private func saveScaling() {
        guard !demo else { return }
        let settings = selectedScaling
        settings.save()
        vlog("scaling: saved \(settings); applies at the next connect")
        updateStale()
    }

    private func updateStale() {
        let settings = selectedScaling
        let stale = demo ? [] : SessionController.running.filter { $0.differs(from: settings) }
        guard reconnectRow?.isHidden != stale.isEmpty else { return }
        reconnectRow?.isHidden = stale.isEmpty
        fitWindow()
    }

    @objc private func reconnectNow() {
        let stale = SessionController.running.filter { $0.differs(from: selectedScaling) }
        vlog("scaling: reconnecting \(stale.count) session(s) to apply")
        stale.forEach { $0.reconnectToApplySettings() }
        reconnectRow?.isHidden = true
        fitWindow()
    }

    private func load() {
        loading = true
        defer { loading = false; updateStale() }
        let s = credentials.settings.load()
        gatewayField.stringValue = s.account != nil ? LoginWindowController.shown(s.account, kind: s.accountKind)
            : LoginWindowController.shown(service.gateway, kind: service.accountKind)
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
        let webcam = WebcamSettings.load(env: [:])
        cameraBox.state = webcam.enabled ? .on : .off
        selectCamera(webcam, devices: CameraDevices.list())
        selectDockApps()
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
        if sender === promptRadio, !loading, !demo, storedSecretHost != nil {
            // Applied at once, this deletes the stored secret: ask first (ISO 9241-110 5.6.2.6).
            confirmForgetSecret()
            return
        }
        if sender === totpRadio { promptRadio.state = .off }
        if sender === promptRadio { totpRadio.state = .off }
        let totp = totpRadio.state == .on
        for c in [secretField, digitsPopup, periodField, algorithmPopup] as [NSControl] { c.isEnabled = totp }
        // Default: protect the password when the TOTP secret is stored next to it.
        if sender === totpRadio { protectBox.state = .on }
        updatePreview()
        // The TOTP choice is applied once a valid secret is there (typed now or stored); the prompt choice at once.
        if sender != nil, !loading, totpRadio.state == .off || !secretField.stringValue.isEmpty || storedSecretHost != nil { saveAccount() }
    }

    /// The host whose TOTP secret is in the Keychain, if any.
    private var storedSecretHost: String? {
        guard let host = LoginSettings.accountURL(from: gatewayField.stringValue)?.host ?? service.gateway?.host,
              credentials.secrets.contains(.totpSecret, host: host) else { return nil }
        return host
    }

    private func confirmForgetSecret() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Delete the saved TOTP secret?", "Gespeichertes TOTP-Geheimnis löschen?")
        alert.informativeText = loc("You then enter the passcode at each sign-in. To generate codes again, you need the secret from your IT department.",
                                    "Danach geben Sie den Passcode bei jeder Anmeldung ein. Um wieder Codes zu erzeugen, brauchen Sie das Geheimnis von Ihrer IT-Abteilung.")
        alert.addButton(withTitle: loc("Delete", "Löschen"))
        alert.addButton(withTitle: loc("Cancel", "Abbrechen"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.totpRadio.state = .off
                self.promptRadio.state = .on
                self.modeChanged()
                self.saveAccount()
            } else {
                self.promptRadio.state = .off
                self.totpRadio.state = .on
            }
        }
    }

    @objc private func accountChanged() { if !loading { saveAccount() } }

    @objc private func paramsChanged() {
        previewTOTP = nil
        updatePreview()
        if !loading, totpRadio.state == .on, storedSecretHost != nil || !secretField.stringValue.isEmpty { saveAccount() }
    }

    /// Text fields apply when editing ends (Return, Tab, another control, closing the window).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !loading, let field = obj.object as? NSTextField else { return }
        if field === secretField, secretField.stringValue.isEmpty { return }
        if field === passwordField, passwordField.stringValue.isEmpty { return }
        if field === periodField, totpRadio.state == .off { return }
        saveAccount()
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
        let host = LoginSettings.accountURL(from: gatewayField.stringValue)?.host
        showCodeButton.isHidden = !typed.isEmpty || totp != nil
            || !(host.map { credentials.secrets.contains(.totpSecret, host: $0) } ?? false)
    }

    /// Reads the stored secret (Touch ID / password) to show its current code for comparison.
    @objc private func showStoredCode() {
        guard let host = LoginSettings.accountURL(from: gatewayField.stringValue)?.host else { return }
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
        guard let host = LoginSettings.accountURL(from: gatewayField.stringValue)?.host ?? service.gateway?.host else { return }
        credentials.forgetAll(host: host)
        service.forgetSession()
        load()
        status.stringValue = loc("Saved credentials for \(host) were deleted.", "Gespeicherte Anmeldedaten für \(host) wurden gelöscht.")
    }

    /// Address, user name, password and passcode settings: one `apply` (it may ask for Touch ID when the
    /// password's protection changes). A typed password or secret goes to the Keychain and leaves the field.
    private func saveAccount() {
        guard !demo else { return }
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
                let saved = credentials.settings.load()
                if let url = saved.account, url.absoluteString != service.gateway?.absoluteString {
                    // A new address keeps the kind `apply` derived (a store path), else it is probed at sign-in.
                    service.setGateway(url, kind: saved.accountKind)
                }
                if !password.isEmpty || !secret.isEmpty {
                    clearSecrets()
                    let host = saved.gatewayHost
                    let saved = loc("saved (type to replace)", "gespeichert (zum Ersetzen eingeben)")
                    if !password.isEmpty { passwordField.placeholderString = saved }
                    if !secret.isEmpty, host != nil { secretField.placeholderString = saved }
                }
                status.stringValue = Self.keychainNote
            } catch {
                vlog("settings: not saved: \(error)")
                status.stringValue = UserMessage.text(for: error)
            }
            fitWindow()
        }
    }

    static var keychainNote: String {
        loc("Secrets are stored only in the Keychain (this Mac, no iCloud).", "Geheimnisse liegen nur im Schlüsselbund (dieser Mac, kein iCloud).")
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

/// Settings panes as a toolbar (NSTabViewController, `.toolbar` style); tells the window controller when the pane
/// changes, so it can set the title and the size.
final class SettingsTabs: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}
