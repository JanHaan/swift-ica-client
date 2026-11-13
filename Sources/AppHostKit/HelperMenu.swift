import Foundation

/// An item of a helper's ICA menu; it runs in the main process (docs/99 §12 phase 2).
public enum HelperCommand: String, Codable, Equatable, Sendable, CaseIterable {
    case showLauncher, connectionCenter, settings, reportProblem
    /// Session-level, confirmed in the main process first (D44 wording).
    case disconnect, logoff
}

/// An Edit menu item chosen by mouse in a helper: the host sends Ctrl+letter, as for the Cmd shortcut.
public enum EditCommand: String, Codable, Equatable, Sendable, CaseIterable {
    case undo, cut, copy, paste, selectAll

    /// The letter of the Cmd shortcut (and of the Ctrl+key on the server).
    public var letter: String {
        switch self {
        case .undo: "z"
        case .cut: "x"
        case .copy: "c"
        case .paste: "v"
        case .selectAll: "a"
        }
    }
}

/// A menu key equivalent: the character and the modifiers besides it.
public struct HelperShortcut: Equatable, Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key; self.modifiers = modifiers
    }

    /// As macOS menus show it: ⌃⌥⇧⌘ order.
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}

public enum HelperMenuAction: Equatable, Sendable {
    case about, hide, hideOthers, showAll, quit
    case edit(EditCommand)
    case close, minimize, zoom, bringAllToFront
    case host(HelperCommand)
    case help
}

public struct HelperMenuItem: Equatable, Sendable {
    public var title: String
    /// nil = a separator.
    public var action: HelperMenuAction?
    public var shortcut: HelperShortcut?

    public init(_ title: String, _ action: HelperMenuAction, _ shortcut: HelperShortcut? = nil) {
        self.title = title; self.action = action; self.shortcut = shortcut
    }

    public static let separator = HelperMenuItem(separator: ())
    private init(separator: Void) { title = ""; action = nil; shortcut = nil }

    public var isSeparator: Bool { action == nil }
}

public struct HelperMenuSection: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case app, edit, window, ica, help }
    public var role: Role
    public var title: String
    public var items: [HelperMenuItem]
}

/// The menu bar of every helper app (docs/99 §12 phase 2, the user's option A): the app menu named after the
/// remote app, Edit (forwarded to the remote app as Ctrl+key), Window (its windows), ICA (the main app's
/// windows and the session, run in the main process) and Help. English or German like the main app.
///
/// Key equivalents never take keys the remote app needs beyond the macOS conventions: a keystroke that
/// matches no item goes to the remote app as Ctrl+key, as in phase 1. The Cmd-Z/X/C/V/A of the Edit menu are
/// taken by the window before the menu sees them (the same Ctrl+key either way). `takenShortcuts` lists what
/// the menu takes from the remote app (docs/99 §12.22).
public enum HelperMenu {
    public static let readmeURL = URL(string: "https://github.com/JanHaan/swift-ica-client#readme")!
    public static let launcherShortcut = HelperShortcut("l", [.control, .option, .command])

    /// German when the first preferred language is German, as `loc` in the main app.
    public static func isGerman(_ languages: [String] = Locale.preferredLanguages) -> Bool {
        languages.first?.lowercased().hasPrefix("de") == true
    }

    /// `launcher`: the Open Launcher item's key equivalent, the global shortcut chosen in Settings (nil = off).
    public static func sections(appName name: String, german: Bool, launcher: HelperShortcut? = launcherShortcut) -> [HelperMenuSection] {
        func t(_ en: String, _ de: String) -> String { german ? de : en }
        let app = HelperMenuSection(role: .app, title: name, items: [
            HelperMenuItem(String(format: t("About %@", "Über %@"), name), .about),
            .separator,
            HelperMenuItem(String(format: t("Hide %@", "%@ ausblenden"), name), .hide, HelperShortcut("h")),
            HelperMenuItem(t("Hide Others", "Andere ausblenden"), .hideOthers, HelperShortcut("h", [.option, .command])),
            HelperMenuItem(t("Show All", "Alle einblenden"), .showAll),
            .separator,
            HelperMenuItem(String(format: t("Quit %@", "%@ beenden"), name), .quit, HelperShortcut("q")),
        ])
        let edit = HelperMenuSection(role: .edit, title: t("Edit", "Bearbeiten"), items: [
            HelperMenuItem(t("Undo", "Widerrufen"), .edit(.undo), HelperShortcut("z")),
            .separator,
            HelperMenuItem(t("Cut", "Ausschneiden"), .edit(.cut), HelperShortcut("x")),
            HelperMenuItem(t("Copy", "Kopieren"), .edit(.copy), HelperShortcut("c")),
            HelperMenuItem(t("Paste", "Einsetzen"), .edit(.paste), HelperShortcut("v")),
            HelperMenuItem(t("Select All", "Alles auswählen"), .edit(.selectAll), HelperShortcut("a")),
        ])
        // AppKit appends the app's windows after the last item (NSApp.windowsMenu).
        let window = HelperMenuSection(role: .window, title: t("Window", "Fenster"), items: [
            HelperMenuItem(t("Close", "Schließen"), .close, HelperShortcut("w")),
            HelperMenuItem(t("Minimize", "Im Dock ablegen"), .minimize, HelperShortcut("m")),
            HelperMenuItem(t("Zoom", "Zoomen"), .zoom),
            .separator,
            HelperMenuItem(t("Bring All to Front", "Alle nach vorne bringen"), .bringAllToFront),
        ])
        // No ⌘, for Settings and no ⇧⌘C for the Connection Center here: those are Ctrl+, and Ctrl+Shift+C
        // for the remote app (Word: copy formatting).
        let ica = HelperMenuSection(role: .ica, title: "ICA", items: [
            HelperMenuItem(t("Open Launcher", "Launcher öffnen"), .host(.showLauncher), launcher),
            HelperMenuItem(t("Connection Center", "Verbindungscenter"), .host(.connectionCenter)),
            HelperMenuItem(t("Settings…", "Einstellungen…"), .host(.settings)),
            .separator,
            HelperMenuItem(t("Report a Problem…", "Problem melden…"), .host(.reportProblem)),
            .separator,
            HelperMenuItem(t("Disconnect Session…", "Sitzung trennen…"), .host(.disconnect)),
            HelperMenuItem(t("Log Off Session…", "Sitzung abmelden…"), .host(.logoff)),
        ])
        let help = HelperMenuSection(role: .help, title: t("Help", "Hilfe"), items: [
            HelperMenuItem(t("ICA Viewer Help", "ICA Viewer-Hilfe"), .help),
        ])
        return [app, edit, window, ica, help]
    }

    /// Whether a key-down is one of this menu's own key equivalents (exact key and modifiers, as AppKit
    /// matches them). The window sends every other Cmd or Ctrl key-down to the remote app before the menu
    /// bar sees it, so items AppKit inserts by itself (macOS 15 window tiling ⌃fn-arrows, Help search ⇧⌘/)
    /// never swallow keys the remote app needs (§12.22).
    public static func isOwnShortcut(key: String, modifiers: HelperShortcut.Modifiers, in sections: [HelperMenuSection]) -> Bool {
        let shortcut = HelperShortcut(key.lowercased(), modifiers)
        return sections.contains { $0.items.contains { $0.shortcut == shortcut } }
    }

    /// The About panel's line under the remote app's name.
    public static func aboutCredits(german: Bool) -> String {
        german ? "Remote-App über ICA Viewer" : "Remote app via ICA Viewer"
    }

    /// Shortcuts the menu takes from the remote app (they would otherwise reach it as Ctrl+key): the Edit
    /// letters are not among them, they reach the remote app either way.
    public static func takenShortcuts(_ sections: [HelperMenuSection]) -> [HelperShortcut] {
        sections.flatMap(\.items).compactMap { item in
            guard let shortcut = item.shortcut, case let action? = item.action else { return nil }
            if case .edit = action { return nil }
            return shortcut
        }
    }
}
