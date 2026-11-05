import AppKit
import ICAKit

/// What Cmd-Q does with open connections (docs/90 §9.4): the setting `quitAction`, default `ask`.
enum QuitAction: String, CaseIterable {
    case ask, disconnect, logoff

    static let key = "quitAction"

    static var stored: QuitAction {
        get { UserDefaults.standard.string(forKey: key).flatMap(QuitAction.init(rawValue:)) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .ask: loc("Ask", "Fragen")
        case .disconnect: loc("Disconnect", "Trennen")
        case .logoff: loc("Log Off", "Abmelden")
        }
    }
}

/// One of our own open connections, as the app delegate reports it.
struct LocalConnection {
    var key: ObjectIdentifier
    /// Resource name the connection was launched for.
    var name: String
    /// The ICA ClientName the WD reports (WDLogon), to match `Sessions/List` (docs/90 §8.1).
    var clientName: String
    var parked: Bool
    var running: Bool
    var show: () -> Void
    var disconnect: () -> Void
    var logoff: () -> Void
}

/// Connection Center (docs/90 §8): the user's store sessions joined with our own connections, grouped
/// "On this Mac", "Disconnected", "On other devices", with Reconnect / Take over / Show, Disconnect and
/// Log off. Every store action is one the user picked; log off and take-over ask first (§8.5).
final class ConnectionCenterController: NSWindowController, NSWindowDelegate {
    /// One row as shown.
    struct Row {
        enum Group: Int, CaseIterable { case here, disconnected, elsewhere }
        var group: Group
        var title: String
        var detail: String
        var store: StoreSession?
        var local: LocalConnection?
    }

    private let service: StoreService?
    var localConnections: () -> [LocalConnection] = { [] }
    var resources: () -> [StoreClient.Resource] = { [] }
    /// Launches these one after another (each opens its own connection, §8.3).
    var launch: ([StoreClient.Resource]) -> Void = { _ in }

    private var storeRows: [StoreSession] = []
    private var byIdAvailable = true
    private var listFailed: String?
    private var busy = false
    private var timer: Timer?
    /// Our connections the user just disconnected, kept 30 s so they do not flicker away (§9.3).
    private var recentlyDisconnected: [(name: String, at: Date)] = []

    private let stack = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let quitPopup = NSPopUpButton()
    private var actions: [Int: () -> Void] = [:]
    private var demoRows: [Row]?

    init(service: StoreService?, demo: [Row]? = nil) {
        self.service = service
        self.demoRows = demo
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = loc("Connection Center", "Verbindungscenter")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 260)
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let reconnectAll = NSButton(title: loc("Reconnect All", "Alle wiederverbinden"), target: self, action: #selector(reconnectAll))
        let refresh = NSButton(title: loc("Refresh", "Aktualisieren"), target: self, action: #selector(refreshClicked))
        for b in [reconnectAll, refresh] { b.bezelStyle = .rounded }
        let quitLabel = NSTextField(labelWithString: loc("When quitting:", "Beim Beenden:"))
        quitPopup.addItems(withTitles: QuitAction.allCases.map(\.title))
        quitPopup.selectItem(at: QuitAction.allCases.firstIndex(of: QuitAction.stored) ?? 0)
        quitPopup.target = self
        quitPopup.action = #selector(quitActionChanged)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [reconnectAll, refresh, status, NSView(), quitLabel, quitPopup])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(bar)
        window.contentView = content
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    // MARK: Showing and refreshing (§8.2)

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let demoRows {
            render(demoRows)
            setStatus(loc("Example sessions", "Beispielsitzungen"))
            return
        }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh(keepAlive: true) }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Our connections changed (launch, end, parked): redraw without a store round trip.
    func localChanged() {
        guard isVisible, demoRows == nil else { return }
        render(rows())
    }

    @objc private func refreshClicked() { refresh() }

    func refresh(keepAlive: Bool = false) {
        guard demoRows == nil, let store = service?.store, !busy else { return }
        busy = true
        setStatus(loc("Refreshing…", "Aktualisiere…"))
        Task { @MainActor in
            defer { busy = false }
            if keepAlive { await store.keepAlive() }
            let api = store.sessions
            api.log = { vlog($0) }
            var list: StoreSessionList?
            listFailed = nil
            do {
                list = try await api.list()
                byIdAvailable = true
            } catch SessionsError.unsupported {
                byIdAvailable = false   // §8.2: no per-session disconnect / log off
            } catch {
                vlog("connection center: Sessions/List failed: \(error)")
                listFailed = "\(error)"
            }
            var available: [AvailableSession] = []
            var safe: [AvailableSession]?
            do {
                available = try await api.available(excludeActive: false)
                safe = try? await api.available(excludeActive: true)
            } catch {
                vlog("connection center: ListAvailable failed: \(error)")
                listFailed = listFailed ?? "\(error)"
            }
            let names = Set(localConnections().map(\.clientName) + [SessionDirectory.defaultClientName])
            storeRows = SessionDirectory.merge(list: list, available: available, excludingActive: safe, clientNames: names)
            let counts = Dictionary(grouping: storeRows, by: { "\($0.state)".split(separator: "(").first.map(String.init) ?? "" })
                .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
            vlog("connection center: \(storeRows.count) store session(s) (\(counts)), \(storeRows.filter { $0.reconnect != nil }.count) reconnectable")
            render(rows())
            setStatus(listFailed == nil ? String(format: loc("Updated %@", "Aktualisiert %@"),
                                                 DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))
                      : loc("Could not get your sessions. Try again later.",
                            "Die Sitzungen konnten nicht abgerufen werden. Später erneut versuchen."))
        }
    }

    private func setStatus(_ text: String) { status.stringValue = text }

    // MARK: Rows (§8.4)

    /// Store rows joined with our connections: a `.connectedHere` session belongs to a local connection
    /// whose resource is one of its apps; local connections not (yet) in the list show on their own.
    private func rows() -> [Row] {
        var locals = localConnections()
        let resources = resources()
        func names(_ s: StoreSession) -> [String] {
            s.apps.map { app in app.id.flatMap { id in resources.first { $0.id == id }?.name } ?? app.name }
        }
        var result: [Row] = []
        recentlyDisconnected.removeAll { Date().timeIntervalSince($0.at) > 30 }
        for s in storeRows {
            switch s.state {
            case .connectedHere:
                let appNames = names(s)
                let i = locals.firstIndex { appNames.contains($0.name) }
                let local = i.map { locals.remove(at: $0) }
                result.append(Row(group: .here, title: title(appNames.isEmpty ? s.appNames : appNames),
                                  detail: detail(s, state: local.map { stateText($0) } ?? loc("Connected (not in this app)",
                                                                                            "Verbunden (nicht in dieser App)")),
                                  store: s, local: local))
            case .disconnected, .unknown:
                result.append(Row(group: .disconnected, title: title(names(s).isEmpty ? s.appNames : names(s)),
                                  detail: detail(s, state: s.state == .unknown ? loc("Disconnected or open elsewhere",
                                                                                     "Getrennt oder anderswo geöffnet")
                                                                              : loc("Disconnected", "Getrennt")), store: s))
            case .connectedElsewhere(let client, let type):
                let device = Demo.screenshotMode || client == nil ? loc("another device", "einem anderen Gerät") : client!
                let text = loc("Connected on ", "Verbunden auf ") + device + (type.map { " (\($0))" } ?? "")
                result.append(Row(group: .elsewhere, title: title(names(s).isEmpty ? s.appNames : names(s)),
                                  detail: detail(s, state: text), store: s))
            }
        }
        for local in locals {
            result.append(Row(group: .here, title: title([local.name]), detail: stateText(local), local: local))
        }
        for gone in recentlyDisconnected where !result.contains(where: { $0.group == .disconnected && $0.title == title([gone.name]) }) {
            result.append(Row(group: .disconnected, title: title([gone.name]), detail: loc("Disconnected", "Getrennt")))
        }
        return result
    }

    private func title(_ apps: [String]) -> String {
        apps.isEmpty ? loc("Session", "Sitzung") : apps.map(displayName).joined(separator: ", ")
    }

    private func stateText(_ local: LocalConnection) -> String {
        !local.running ? loc("Connecting…", "Verbinde…")
            : local.parked ? loc("Connected – no visible windows", "Verbunden – keine sichtbaren Fenster")
            : loc("Connected", "Verbunden")
    }

    private func detail(_ s: StoreSession, state: String) -> String {
        var parts = [state]
        if let started = s.started {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            parts.append(loc("started ", "gestartet ") + f.localizedString(for: started, relativeTo: Date()))
        }
        if let host = s.machine, !Demo.screenshotMode { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    private static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    private func render(_ rows: [Row]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.removeAll()
        var tag = 0
        func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
            tag += 1
            actions[tag] = action
            let b = NSButton(title: title, target: self, action: #selector(rowButton(_:)))
            b.tag = tag
            b.bezelStyle = .rounded
            b.controlSize = .small
            return b
        }
        let headers: [Row.Group: String] = [
            .here: loc("On this Mac", "Auf diesem Mac"),
            .disconnected: loc("Disconnected", "Getrennt"),
            .elsewhere: loc("On other devices", "Auf anderen Geräten"),
        ]
        if rows.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: listFailed == nil ? loc("No sessions.", "Keine Sitzungen.")
                                                 : loc("Could not get your sessions.", "Sitzungen nicht verfügbar.")))
        }
        for group in Row.Group.allCases {
            let members = rows.filter { $0.group == group }
            guard !members.isEmpty else { continue }
            let header = NSTextField(labelWithString: headers[group] ?? "")
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(header)
            for row in members {
                let icon = NSImageView(image: Self.genericIcon)
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
                let name = NSTextField(labelWithString: row.title)
                name.lineBreakMode = .byTruncatingTail
                let info = NSTextField(labelWithString: row.detail)
                info.textColor = .secondaryLabelColor
                info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                info.lineBreakMode = .byTruncatingTail
                for t in [name, info] { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
                let labels = NSStackView(views: [name, info])
                labels.orientation = .vertical
                labels.alignment = .leading
                labels.spacing = 1
                var views: [NSView] = [icon, labels, NSView()]
                views += rowButtons(row).map { button($0.0, $0.1) }
                let line = NSStackView(views: views)
                line.orientation = .horizontal
                line.spacing = 6
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
        }
    }

    @objc private func rowButton(_ sender: NSButton) { actions[sender.tag]?() }

    /// §8.3 actions for one row.
    private func rowButtons(_ row: Row) -> [(String, () -> Void)] {
        var list: [(String, () -> Void)] = []
        let isDemo = demoRows != nil
        if let local = row.local {
            if local.parked { list.append((loc("Show", "Zeigen"), local.show)) }
            list.append((loc("Disconnect", "Trennen"), { [weak self] in
                guard !isDemo else { return }
                vlog("connection center: disconnect our connection \(local.name)")
                self?.recentlyDisconnected.append((local.name, Date()))
                local.disconnect()
            }))
            list.append((loc("Log Off", "Abmelden"), { [weak self] in
                guard !isDemo else { return }
                self?.confirmLogoff(row.title) {
                    vlog("connection center: log off our connection \(local.name)")
                    local.logoff()
                }
            }))
            return list
        }
        guard let s = row.store else { return list }
        // An ambiguous join (§7.2) gets neither Reconnect nor Take Over: it could launch another session.
        switch s.joinAmbiguous ? .connectedHere : s.state {
        case .disconnected, .unknown:
            if let entry = s.reconnect, s.state == .disconnected {
                list.append((loc("Reconnect", "Verbinden"), { [weak self] in
                    guard !isDemo else { return }
                    vlog("connection center: reconnect a disconnected session (\(entry.initialapp ?? "?"))")
                    self?.launch([entry.resource])
                    self?.refreshSoon()
                }))
            } else if let entry = s.takeOver {
                // Not known to be disconnected: it may be open on another device.
                list.append((loc("Reconnect…", "Verbinden…"), { [weak self] in
                    guard !isDemo else { return }
                    self?.confirmTakeOver(row.title, device: nil) {
                        self?.launch([entry.resource])
                        self?.refreshSoon()
                    }
                }))
            } else if s.state == .disconnected, !s.joinAmbiguous, let resource = resourceForApps(s) {
                // §7.3 way 2: launching one of its apps reconnects the disconnected session.
                list.append((loc("Reconnect", "Verbinden"), { [weak self] in
                    guard !isDemo else { return }
                    vlog("connection center: reconnect via resource \(resource.name)")
                    self?.launch([resource])
                    self?.refreshSoon()
                }))
            }
        case .connectedElsewhere(let client, _):
            if let entry = s.takeOver {
                list.append((loc("Take Over…", "Übernehmen…"), { [weak self] in
                    guard !isDemo else { return }
                    self?.confirmTakeOver(row.title, device: client) {
                        vlog("connection center: take over a session from another device (user confirmed)")
                        self?.launch([entry.resource])
                        self?.refreshSoon()
                    }
                }))
            }
        case .connectedHere:
            break
        }
        guard let id = s.id, byIdAvailable || isDemo else { return list }
        if s.state != .disconnected {
            // Not one of our connections (those return above): always confirm.
            list.append((loc("Disconnect", "Trennen"), { [weak self] in
                guard !isDemo else { return }
                var device: String?
                if case .connectedElsewhere(let client, _) = s.state { device = client ?? "" }
                self?.confirmDisconnect(row.title, device: device) { self?.byId(.disconnect, id, row.title) }
            }))
        }
        list.append((loc("Log Off", "Abmelden"), { [weak self] in
            guard !isDemo else { return }
            self?.confirmLogoff(row.title) { self?.byId(.logoff, id, row.title) }
        }))
        return list
    }

    /// §7.3 way 2, only if no other listed session (or unjoined entry) has that app: the broker might
    /// otherwise pick that one, maybe open on another device.
    private func resourceForApps(_ s: StoreSession) -> StoreClient.Resource? {
        let resources = resources()
        for app in s.apps {
            guard let r = resources.first(where: { $0.id == app.id || $0.name == app.name }), r.launchurl != nil else { continue }
            func matches(_ a: StoreSessionInfo.App) -> Bool { a.id == r.id || a.name == r.name || a.name == app.name }
            let shared = storeRows.contains { other in
                other.id != s.id && (other.apps.contains(where: matches)
                    || other.initialApp.map { $0 == r.name || $0 == app.name || $0 == r.id } == true)
            }
            if !shared { return r }
        }
        return nil
    }

    @objc private func reconnectAll() {
        guard demoRows == nil else { return }
        // Only rows the List shows as disconnected, joined one-to-one (§8.5): never a session open elsewhere.
        let entries = storeRows.filter { $0.state == .disconnected && !$0.joinAmbiguous }.compactMap(\.reconnect)
        guard !entries.isEmpty else { return setStatus(loc("No disconnected sessions.", "Keine getrennten Sitzungen.")) }
        vlog("connection center: reconnect all (\(entries.count) disconnected)")
        launch(entries.map(\.resource))
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refresh() }
    }

    @objc private func quitActionChanged() {
        let index = quitPopup.indexOfSelectedItem
        guard QuitAction.allCases.indices.contains(index), demoRows == nil else { return }
        QuitAction.stored = QuitAction.allCases[index]
        vlog("quit action: \(QuitAction.stored.rawValue)")
    }

    // MARK: Store actions by id (§5.2, §5.3)

    private enum ByIdAction { case disconnect, logoff }

    private func byId(_ action: ByIdAction, _ id: String, _ title: String) {
        guard let store = service?.store else { return }
        let fingerprint = StoreSessionInfo.fingerprint(id)
        vlog("connection center: \(action == .disconnect ? "DisconnectSessions" : "LogOffSessions") \(fingerprint)")
        setStatus(action == .disconnect ? loc("Disconnecting…", "Trenne…") : loc("Logging off…", "Melde ab…"))
        Task { @MainActor in
            let api = store.sessions
            api.log = { vlog($0) }
            do {
                let results = action == .disconnect ? try await api.disconnect(ids: [id]) : try await api.logOff(ids: [id])
                if let failed = results.first(where: { !$0.isSuccess }) {
                    setStatus(failed.failureReason ?? loc("The store could not do that.", "Der Store konnte das nicht ausführen."))
                } else {
                    setStatus(action == .disconnect ? loc("Disconnected ", "Getrennt: ") + title : loc("Logged off ", "Abgemeldet: ") + title)
                }
            } catch {
                vlog("connection center: action failed: \(error)")
                setStatus("\(error)")
            }
            refresh()
        }
    }

    // MARK: Confirmations (§8.5): Cancel is the default button

    private func confirm(_ message: String, _ info: String, _ action: String, destructive: Bool, then: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: loc("Cancel", "Abbrechen"))
        let ok = alert.addButton(withTitle: action)
        ok.hasDestructiveAction = destructive
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { then() }
        }
    }

    private func confirmLogoff(_ apps: String, then: @escaping () -> Void) {
        confirm(String(format: loc("Log off %@?", "%@ abmelden?"), apps),
                loc("The apps in this session are closed. Unsaved work in them is lost.",
                    "Die Apps dieser Sitzung werden beendet. Nicht gesicherte Arbeit geht verloren."),
                loc("Log Off", "Abmelden"), destructive: true, then: then)
    }

    private func confirmTakeOver(_ apps: String, device: String?, then: @escaping () -> Void) {
        let name = Demo.screenshotMode || device == nil ? loc("another device", "einem anderen Gerät") : device!
        confirm(String(format: loc("%@ is open on %@. Move it to this Mac?", "%@ ist auf %@ geöffnet. Auf diesen Mac holen?"), apps, name),
                loc("It will close there.", "Dort wird die Sitzung geschlossen."),
                loc("Move to This Mac", "Auf diesen Mac holen"), destructive: false, then: then)
    }

    /// `device`: nil for a session on this device that is not in this app; "" for an unnamed other device.
    private func confirmDisconnect(_ apps: String, device: String?, then: @escaping () -> Void) {
        let name = device == nil ? loc("this Mac (not in this app)", "diesem Mac (nicht in dieser App)")
            : Demo.screenshotMode || device!.isEmpty ? loc("another device", "einem anderen Gerät") : device!
        confirm(String(format: loc("Disconnect %@ on %@?", "%@ auf %@ trennen?"), apps, name),
                loc("The apps keep running; the session can be reconnected later.",
                    "Die Apps laufen weiter; die Sitzung kann später wieder verbunden werden."),
                loc("Disconnect", "Trennen"), destructive: false, then: then)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Cmd-Q (docs/90 §9.4)

enum QuitPrompt {
    /// Asks what to do with `count` open connections. nil: cancelled. "Remember my choice" stores it.
    static func ask(count: Int, apps: [String]) -> QuitAction? {
        let alert = NSAlert()
        alert.messageText = loc("Quit ICA Viewer?", "ICA Viewer beenden?")
        let list = apps.map(displayName).joined(separator: ", ")
        alert.informativeText = String(format: loc("%d session(s) with %@ are open. Disconnect keeps the apps running so you can reconnect later; Log Off ends them.",
                                                   "%d Sitzung(en) mit %@ sind offen. Trennen lässt die Apps weiterlaufen; Abmelden beendet sie."),
                                       count, list)
        alert.addButton(withTitle: loc("Disconnect", "Trennen"))
        let logoff = alert.addButton(withTitle: loc("Log Off", "Abmelden"))
        logoff.hasDestructiveAction = true
        alert.addButton(withTitle: loc("Cancel", "Abbrechen"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = loc("Remember my choice", "Auswahl merken")
        NSApp.activate()
        let choice: QuitAction? = switch alert.runModal() {
        case .alertFirstButtonReturn: .disconnect
        case .alertSecondButtonReturn: .logoff
        default: nil
        }
        if let choice, alert.suppressionButton?.state == .on {
            QuitAction.stored = choice
            vlog("quit action remembered: \(choice.rawValue)")
        }
        return choice
    }
}

// MARK: - Demo rows

extension ConnectionCenterController {
    static var demoRows: [Row] {
        let now = Date()
        func s(_ state: StoreSession.State, _ apps: [String], _ minutes: Double, reconnect: Bool = false, takeOver: Bool = false) -> StoreSession {
            let entry = AvailableSession(launchurl: "Sessions/LaunchIca/demo", launchstatusurl: "Sessions/GetLaunchStatus/demo",
                                         initialapp: apps.first)
            return StoreSession(id: "demo-\(apps.joined())", state: state, started: now.addingTimeInterval(-minutes * 60),
                                machine: "VDA-01", apps: apps.map { .init(id: nil, name: $0) }, initialApp: apps.first,
                                reconnect: reconnect ? entry : nil, takeOver: takeOver ? entry : nil)
        }
        let local = LocalConnection(key: ObjectIdentifier(NSObject.self), name: "Calculator", clientName: "MAC-ICA",
                                    parked: false, running: true, show: {}, disconnect: {}, logoff: {})
        let parked = LocalConnection(key: ObjectIdentifier(NSView.self), name: "Notepad", clientName: "MAC-ICA",
                                     parked: true, running: true, show: {}, disconnect: {}, logoff: {})
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        func started(_ m: Double) -> String { "started " + f.localizedString(for: now.addingTimeInterval(-m * 60), relativeTo: now) }
        return [
            Row(group: .here, title: "Calculator", detail: "Connected · \(started(12)) · VDA-01", store: s(.connectedHere, ["Calculator"], 12), local: local),
            Row(group: .here, title: "Notepad", detail: "Connected – no visible windows · \(started(40)) · VDA-01",
                store: s(.connectedHere, ["Notepad"], 40), local: parked),
            Row(group: .disconnected, title: "Word, Excel", detail: "Disconnected · \(started(180)) · VDA-02",
                store: s(.disconnected, ["Word", "Excel"], 180, reconnect: true)),
            Row(group: .elsewhere, title: "Outlook", detail: "Connected on another device (Windows) · \(started(300)) · VDA-02",
                store: s(.connectedElsewhere(clientName: nil, deviceType: "Windows"), ["Outlook"], 300, takeOver: true)),
        ]
    }
}
