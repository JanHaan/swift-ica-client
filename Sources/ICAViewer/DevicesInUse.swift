import AppKit

/// A Mac device a session can use: the microphone (docs/98 §10.3) or the camera (docs/98b §10.4).
enum SessionDevice: Hashable {
    case microphone, camera

    var noteTitle: String { self == .camera ? loc("Camera", "Kamera") : loc("Microphone", "Mikrofon") }

    var deniedText: String {
        self == .camera
            ? loc("The session asked for the camera, but ICA Viewer has no permission to use it.",
                  "Die Sitzung wollte die Kamera nutzen, aber ICA Viewer hat keine Berechtigung dafür.")
            : loc("The session asked for the microphone, but ICA Viewer has no permission to use it.",
                  "Die Sitzung wollte das Mikrofon nutzen, aber ICA Viewer hat keine Berechtigung dafür.")
    }

    var privacyURL: String {
        "x-apple.systempreferences:com.apple.preference.security?" + (self == .camera ? "Privacy_Camera" : "Privacy_Microphone")
    }

    func inUseTitle(_ name: String) -> String {
        self == .camera ? loc("Camera: in use — \(name)", "Kamera: aktiv — \(name)")
                        : loc("Microphone: recording — \(name)", "Mikrofon: Aufnahme — \(name)")
    }

    var disableTitle: String {
        self == .camera ? loc("Disable Camera for This Session", "Kamera für diese Sitzung deaktivieren")
                        : loc("Disable Microphone for This Session", "Mikrofon für diese Sitzung deaktivieren")
    }
}

/// The one-time note after a denied permission (docs/98 §10.3, docs/98b §10.2), once per device: one line, a button
/// to the privacy settings, non-modal so the session keeps running.
@MainActor
enum DevicePermissionNote {
    private static var shown: Set<SessionDevice> = []
    private static var panels: [SessionDevice: NSPanel] = [:]

    static func show(_ device: SessionDevice) {
        guard !shown.contains(device) else { return }
        shown.insert(device)
        let text = NSTextField(labelWithString: device.deniedText)
        let settings = NSButton(title: loc("Open Privacy Settings", "Datenschutz-Einstellungen öffnen"), target: nil, action: nil)
        let close = NSButton(title: "OK", target: nil, action: nil)
        close.keyEquivalent = "\r"
        let target = NoteTarget(device)
        settings.target = target
        settings.action = #selector(NoteTarget.openSettings)
        close.target = target
        close.action = #selector(NoteTarget.close)
        let buttons = NSStackView(views: [settings, close])
        let stack = NSStackView(views: [text, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = device.noteTitle
        p.isReleasedWhenClosed = false
        p.contentView = stack
        p.setContentSize(stack.fittingSize)
        p.center()
        objc_setAssociatedObject(p, &NoteTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        panels[device] = p
        p.orderFrontRegardless()
    }

    fileprivate static func dismiss(_ device: SessionDevice) { panels[device]?.close() }

    private final class NoteTarget: NSObject {
        nonisolated(unsafe) static var key = 0
        let device: SessionDevice
        init(_ device: SessionDevice) { self.device = device }
        @objc func openSettings() {
            if let url = URL(string: device.privacyURL) { NSWorkspace.shared.open(url) }
            let device = self.device
            MainActor.assumeIsolated { DevicePermissionNote.dismiss(device) }
        }
        @objc func close() {
            let device = self.device
            MainActor.assumeIsolated { DevicePermissionNote.dismiss(device) }
        }
    }
}

/// The in-app "devices in use" indicator (docs/98 §10.3, docs/98b §10.4): a menu-bar item exists only while a session
/// records from the microphone or uses the camera. Its menu names each session and device and offers "Disable
/// Microphone/Camera for This Session", which stops that device at once and refuses it for the rest of the session.
/// (macOS shows its own orange/green dot as well.)
@MainActor
final class DevicesIndicator: NSObject {
    static let shared = DevicesIndicator()

    private struct Key: Hashable {
        let session: ObjectIdentifier
        let device: SessionDevice
    }

    private var active: [Key: (name: String, disable: () -> Void)] = [:]
    private var order: [Key] = []
    private var item: NSStatusItem?
    private var shownSymbol = ""

    /// `disable` stops that device for that session (called on main).
    func update(_ session: AnyObject, device: SessionDevice, name: String, inUse on: Bool, disable: @escaping () -> Void) {
        let key = Key(session: ObjectIdentifier(session), device: device)
        if on {
            if active[key] == nil { order.append(key) }
            active[key] = (name, disable)
        } else {
            active[key] = nil
            order.removeAll { $0 == key }
        }
        refresh()
    }

    private func refresh() {
        guard !order.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownSymbol = ""
            return
        }
        let camera = order.contains { $0.device == .camera }, mic = order.contains { $0.device == .microphone }
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        let symbol = camera ? "video.fill" : "mic.fill"
        if symbol != shownSymbol {
            item?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: camera
                ? loc("Camera in use", "Kamera aktiv") : loc("Microphone in use", "Mikrofon aktiv"))
            shownSymbol = symbol
        }
        let menu = NSMenu()
        for key in order {
            guard let entry = active[key] else { continue }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let title = NSMenuItem(title: key.device.inUseTitle(entry.name), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let disable = NSMenuItem(title: key.device.disableTitle, action: #selector(disableClicked(_:)), keyEquivalent: "")
            disable.target = self
            // The key, not an index: the list can change while the menu is open.
            disable.representedObject = key
            menu.addItem(disable)
        }
        item?.menu = menu
        item?.button?.toolTip = camera && mic
            ? loc("ICA Viewer: a session is using the camera and the microphone", "ICA Viewer: Eine Sitzung nutzt Kamera und Mikrofon")
            : camera ? loc("ICA Viewer: a session is using the camera", "ICA Viewer: Eine Sitzung nutzt die Kamera")
                     : loc("ICA Viewer: a session is recording from the microphone", "ICA Viewer: Eine Sitzung nimmt über das Mikrofon auf")
    }

    @objc private func disableClicked(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Key, let entry = active[key] else { return }
        entry.disable()
    }
}
