import AppKit
import ICAKit

/// Demo mode for README screenshots: ICAVIEWER_DEMO=1 shows the app's own windows with example data.
/// No network, Keychain, settings or session are touched. ICAVIEWER_DEMO_SHOW=login|launcher|settings|hud|gaveup
/// shows only that window, centred on the main screen, and logs `demo window <name> id <n>`
/// (the CGWindowID for `screencapture -l`). Without it all demo windows are shown side by side.
/// ICAVIEWER_SCREENSHOT=1 (also outside demo mode) censors the resource names the UI shows.
enum Demo {
    static let enabled = ProcessInfo.processInfo.environment["ICAVIEWER_DEMO"] == "1"
    static let screenshotMode = ProcessInfo.processInfo.environment["ICAVIEWER_SCREENSHOT"] == "1"
    static let names = ["login", "launcher", "settings", "hud", "gaveup"]

    static let gateway = "gateway.example.com"
    static let username = "demo"
    /// Only its length shows (dots).
    static let password = "example-password"
    /// A made-up TOTP secret and its preview; the code does not count down.
    static let totpSecret = "JBSWY3DPEHPK3PXP"
    static let totpPreview = "492 817 (21 s)"
    static let appName = "Calculator"
    static let countdown: TimeInterval = 174   // 2:54

    static let resourceNames = [
        "Calculator", "Command Prompt", "Excel", "Notepad", "Outlook", "Paint", "PowerPoint",
        "Remote Desktop Connection", "Snipping Tool", "Task Manager", "Word", "WordPad",
    ]

    static var resources: [StoreClient.Resource] {
        let json = "[" + resourceNames.enumerated().map { i, name in
            #"{"id":"demo\#(i)","name":"\#(name)","path":"/Demo/\#(name)","clienttypes":["ica30"]}"#
        }.joined(separator: ",") + "]"
        return (try? JSONDecoder().decode([StoreClient.Resource].self, from: Data(json.utf8))) ?? []
    }
}

@MainActor
final class DemoController {
    private let service: StoreService
    private let only: String?
    private var login: LoginWindowController?
    private var launcher: LauncherWindowController?
    private var settings: SettingsWindowController?
    private var hud: ReconnectHUD?
    private var gaveUp: ReconnectHUD?

    init(service: StoreService) {
        self.service = service
        let only = ProcessInfo.processInfo.environment["ICAVIEWER_DEMO_SHOW"]
        self.only = only
        if let only, !Demo.names.contains(only) {
            vlog("demo: unknown ICAVIEWER_DEMO_SHOW=\(only) (use \(Demo.names.joined(separator: "|")))")
        }
    }

    func start() {
        vlog("demo mode: example data only, no network")
        func wanted(_ name: String) -> Bool { only == nil || only == name }
        var placed: [(String, NSWindow?)] = []   // name, window, panel window number
        if wanted("login") {
            let c = LoginWindowController(service: service)
            c.showDemo()
            login = c
            placed.append(("login", c.window))
        }
        if wanted("launcher") {
            let c = LauncherWindowController()
            c.setResources(Demo.resources)
            c.setStatus("\(Demo.resources.count) resources")
            c.showWindow(nil)
            launcher = c
            placed.append(("launcher", c.window))
        }
        if wanted("settings") {
            let c = SettingsWindowController(service: service, demo: true)
            c.show()
            settings = c
            placed.append(("settings", c.window))
        }
        if wanted("hud") {
            let h = ReconnectHUD()
            h.fixedClock = Demo.countdown
            h.showSuspended(name: Demo.appName, deadline: Date().addingTimeInterval(Demo.countdown))
            hud = h
            placed.append(("hud", nil))
        }
        if wanted("gaveup") {
            let h = ReconnectHUD()
            h.fixedClock = Demo.countdown
            h.showGaveUp(name: Demo.appName, message: loc("The connection could not be restored in time.",
                                                          "Die Verbindung konnte nicht rechtzeitig wiederhergestellt werden."),
                         notBefore: nil)
            gaveUp = h
            placed.append(("gaveup", nil))
        }
        layout(placed)
        NSApp.activate()
        // Let the windows finish drawing, then log the ids.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            for (name, window) in placed {
                let number = window?.windowNumber ?? (name == "hud" ? hud?.windowNumber : gaveUp?.windowNumber) ?? 0
                vlog("demo window \(name) id \(number)")
            }
            vlog("demo ready")
        }
    }

    /// One window: centred on the main screen. Several: side by side, centred as a group.
    private func layout(_ items: [(String, NSWindow?)]) {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        func frame(_ name: String, _ window: NSWindow?) -> NSRect {
            if let window { return window.frame }
            return (name == "hud" ? hud : gaveUp)?.frame ?? .zero
        }
        func move(_ name: String, _ window: NSWindow?, to origin: NSPoint) {
            if let window { window.setFrameOrigin(origin) } else { (name == "hud" ? hud : gaveUp)?.setOrigin(origin) }
        }
        let gap: CGFloat = 24
        let total = items.reduce(CGFloat(0)) { $0 + frame($1.0, $1.1).width } + gap * CGFloat(max(0, items.count - 1))
        var x = area.midX - total / 2
        for (name, window) in items {
            let f = frame(name, window)
            move(name, window, to: NSPoint(x: x, y: area.midY - f.height / 2))
            x += f.width + gap
        }
    }
}
