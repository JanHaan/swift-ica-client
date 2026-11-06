import AppKit

/// "Help → Report a Problem…" ("Hilfe → Problem melden…"). Installed after launch into the main
/// menu the app delegate builds: the existing Help menu (NSApp.helpMenu or a menu titled Help/Hilfe)
/// gets the item, otherwise a Help menu is added at the end. `observeLaunch()` runs before `app.run()`.
@MainActor
final class FeedbackMenu: NSObject {
    static let shared = FeedbackMenu()
    private var observer: NSObjectProtocol?

    /// Called on the main thread from main.swift's top-level code.
    nonisolated static func observeLaunch() {
        MainActor.assumeIsolated {
            guard shared.observer == nil else { return }
            shared.observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
                // After the delegate's applicationDidFinishLaunching, which sets NSApp.mainMenu.
                DispatchQueue.main.async { MainActor.assumeIsolated { shared.install() } }
            }
        }
    }

    func install() {
        guard let main = NSApp.mainMenu else { return }
        let helpTitles = ["Help", "Hilfe"]
        let help: NSMenu
        if let existing = NSApp.helpMenu ?? main.items.first(where: { helpTitles.contains($0.submenu?.title ?? $0.title) })?.submenu {
            help = existing
        } else {
            help = NSMenu(title: loc("Help", "Hilfe"))
            let item = NSMenuItem(title: help.title, action: nil, keyEquivalent: "")
            item.submenu = help
            main.addItem(item)
        }
        NSApp.helpMenu = help
        guard !help.items.contains(where: { $0.action == #selector(reportProblem(_:)) }) else { return }
        let item = NSMenuItem(title: loc("Report a Problem…", "Problem melden…"), action: #selector(reportProblem(_:)), keyEquivalent: "")
        item.target = self
        help.addItem(item)
    }

    @objc func reportProblem(_ sender: Any?) {
        FeedbackWindowController.show()
    }
}
