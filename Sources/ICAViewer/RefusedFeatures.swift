import AppKit
import ICAKit

extension Notification.Name {
    /// A session's refused redirections changed (Connection Center redraws).
    static let refusedFeaturesChanged = Notification.Name("ICAViewerRefusedFeaturesChanged")
}

extension RedirectionFeature {
    /// Connection Center line (D118, the user's "Subtle indicator").
    var blockedLine: String {
        switch self {
        case .clipboard: loc("Clipboard: blocked by server policy", "Zwischenablage: durch Serverrichtlinie gesperrt")
        case .fileCopy: loc("File copy: blocked by server policy", "Dateien kopieren: durch Serverrichtlinie gesperrt")
        case .drives: loc("Client drives: blocked by server policy", "Clientlaufwerke: durch Serverrichtlinie gesperrt")
        case .printing: loc("Printing: blocked by server policy", "Drucken: durch Serverrichtlinie gesperrt")
        case .audio: loc("Audio: blocked by server policy", "Audio: durch Serverrichtlinie gesperrt")
        }
    }

    /// The one-time notice after the first blocked attempt in a session.
    func noticeText(app: String) -> String {
        switch self {
        case .clipboard: loc("The server's policy blocks the clipboard for \(app).",
                             "Die Serverrichtlinie sperrt die Zwischenablage für \(app).")
        case .fileCopy: loc("The server's policy blocks copying files to and from \(app).",
                            "Die Serverrichtlinie sperrt das Kopieren von Dateien für \(app).")
        case .drives: loc("The server's policy blocks access to your Mac's files from \(app).",
                          "Die Serverrichtlinie sperrt den Zugriff von \(app) auf die Dateien dieses Mac.")
        case .printing: loc("The server's policy blocks printing to this Mac from \(app).",
                            "Die Serverrichtlinie sperrt das Drucken von \(app) auf diesen Mac.")
        case .audio: loc("The server's policy blocks sound from \(app).",
                         "Die Serverrichtlinie sperrt den Ton von \(app).")
        }
    }
}

/// Per session: which announced redirections the server refused (ICAKit `RedirectionStatus`, D118), for the
/// Connection Center lines and the one-time notice. Host data arrives on the session queue (`hostPacket`, lock-free
/// after each feature's first byte); everything else runs on main.
final class RefusedFeatureMonitor: @unchecked Sendable {
    /// Open sessions by their controller (the Connection Center's `LocalConnection.key`). Main thread only.
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: RefusedFeatureMonitor] = [:]

    private let app: String
    /// Main thread only.
    private var status: RedirectionStatus
    private var key: ObjectIdentifier?
    private var settleTimer: Timer?
    /// Session queue: channels still waiting for their first host byte (read under the lock, emptied as they speak).
    private let lock = NSLock()
    private var pendingChannels: Set<UInt8>

    init(app: String, requested: Set<RedirectionFeature>) {
        self.app = app
        status = RedirectionStatus(requested: requested)
        pendingChannels = Set(requested.map(\.channel))
        vlog("redirections announced: " + RedirectionFeature.allCases.filter(requested.contains).map(\.rawValue).joined(separator: ", "))
    }

    /// The features a session announced (its engines exist): file copy only with clipboard files over CTXGDT.
    static func requested(_ session: ICASession) -> Set<RedirectionFeature> {
        var set: Set<RedirectionFeature> = []
        if session.clipboard != nil { set.insert(.clipboard) }
        if let clip = session.clipboard, clip.config.files, let gdt = session.gdt, gdt.config.fileTransfer { set.insert(.fileCopy) }
        if session.cdm != nil { set.insert(.drives) }
        if session.printer != nil { set.insert(.printing) }
        if session.audio != nil { set.insert(.audio) }
        return set
    }

    /// Main thread: Connection Center lines of an open session (empty when nothing is refused).
    static func lines(for key: ObjectIdentifier) -> [String] {
        guard let m = registry[key] else { return [] }
        return m.status.refused(at: ProcessInfo.processInfo.systemUptime).map(\.blockedLine)
    }

    func register(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        self.key = key
        DispatchQueue.main.async { Self.registry[key] = self }
    }

    func unregister() {
        settleTimer?.invalidate()
        guard let key else { return }
        DispatchQueue.main.async {
            Self.registry[key] = nil
            NotificationCenter.default.post(name: .refusedFeaturesChanged, object: nil)
        }
    }

    /// Any thread (the session queue): a host packet on `channel`.
    func hostPacket(channel: UInt8) {
        lock.lock()
        let first = pendingChannels.remove(channel) != nil
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.async {
            if let f = self.status.hostData(channel: channel) { vlog("redirection \(f.rawValue): in use (host data)") }
            NotificationCenter.default.post(name: .refusedFeaturesChanged, object: nil)
        }
    }

    /// Main: the session's first app window starts the settle clock; when it ends, the verdict is logged and shown.
    func appWindowShown() {
        guard status.appWindowAt == nil else { return }
        status.appWindowShown(at: ProcessInfo.processInfo.systemUptime)
        settleTimer = Timer.scheduledTimer(withTimeInterval: status.settleSeconds + 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            let refused = self.status.refused(at: ProcessInfo.processInfo.systemUptime)
            vlog("redirections refused by the server: " + (refused.isEmpty ? "none" : refused.map(\.rawValue).joined(separator: ", ")))
            NotificationCenter.default.post(name: .refusedFeaturesChanged, object: nil)
        }
    }

    /// Main: the user tried `feature` (paste, copy, print). The first time per session while it is refused, a small
    /// non-modal notice near `window`.
    func attempt(_ feature: RedirectionFeature, near window: NSWindow?) {
        guard status.attempt(feature, at: ProcessInfo.processInfo.systemUptime) else { return }
        vlog("redirection \(feature.rawValue): blocked attempt, notice shown")
        let text = feature.noticeText(app: displayName(app))
        MainActor.assumeIsolated { FeatureNotice.show(text, near: window) }
    }

    /// Main: Cmd/Ctrl-V into a remote window. With files on the pasteboard the file copy counts (if the clipboard
    /// itself is allowed), else the clipboard.
    func pasteAttempt(near window: NSWindow?) {
        let now = ProcessInfo.processInfo.systemUptime
        let files = NSPasteboard.general.types?.contains(.fileURL) == true
        if files, status.state(.clipboard, at: now) != .refused, status.state(.fileCopy, at: now) == .refused {
            attempt(.fileCopy, near: window)
        } else {
            attempt(.clipboard, near: window)
        }
    }
}

/// A small non-modal notice (one line, no buttons) at the bottom of a window or the main screen; it does not take
/// focus, closes on a click and fades after a few seconds.
@MainActor
enum FeatureNotice {
    private static var panel: NSPanel?

    static func show(_ text: String, near window: NSWindow?, seconds: Double = 6) {
        panel?.close()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.preferredMaxLayoutWidth = 360
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])
        let p = ClickClosePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = effect
        p.setContentSize(effect.fittingSize)
        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: area.midX - p.frame.width / 2, y: area.minY + 24))
        p.orderFrontRegardless()
        panel = p
        Access.announce(text)   // it never takes focus, so VoiceOver would not read it otherwise
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak p] in
            guard let p, p.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }, completionHandler: { p.close() })
        }
    }

    private final class ClickClosePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override func mouseDown(with event: NSEvent) { close() }
    }
}
