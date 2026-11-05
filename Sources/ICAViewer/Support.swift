import AppKit
import Foundation
import ICAKit

/// Project paths. The viewer is a personal tool built from this checkout, so the source location
/// finds `.env` and `.session/` (override with ICA_ROOT / ICA_ENV).
enum Paths {
    static let root: URL = {
        if let r = ProcessInfo.processInfo.environment["ICA_ROOT"] { return URL(fileURLWithPath: r) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()
    static var envFile: String { ProcessInfo.processInfo.environment["ICA_ENV"] ?? root.appendingPathComponent(".env").path }
    static var sessionDir: URL { root.appendingPathComponent(".session") }
    static var cookieFile: String { sessionDir.appendingPathComponent("cookies.plist").path }
}

private let logStart = Date()

/// Diagnostic log on stderr. Never pass credentials, tickets, cookies or ICA file contents.
func vlog(_ text: String) {
    let line = String(format: "%7.2f ", Date().timeIntervalSince(logStart)) + text + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

/// Login, resource list and launch through the gateway, using the `.env` flow of `icactl`.
final class StoreService: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case config(String)
        var description: String { if case .config(let s) = self { return s }; return "" }
    }

    let http = HTTPClient()
    let env: Env
    let gateway: URL
    var store: StoreClient { StoreClient(http: http, base: URL(string: "welcome/", relativeTo: gateway)!.absoluteURL) }

    init() throws {
        do { env = try Env(path: Paths.envFile) } catch { throw Failure.config("cannot read .env") }
        guard let url = URL(string: (env["CITRIX_GATEWAY_URL"] ?? "https://gateway.example.com") + "/") else {
            throw Failure.config("bad CITRIX_GATEWAY_URL")
        }
        gateway = url
        try? FileManager.default.createDirectory(at: Paths.sessionDir, withIntermediateDirectories: true)
        http.trace = { vlog("http " + $0) }   // paths and cookie names only (HTTPClient redacts query values)
        try? http.loadCookies(from: Paths.cookieFile)
    }

    /// nFactor logon at the gateway (username, password, TOTP passcode from `.env`).
    func logon() async throws {
        guard let user = env["CITRIX_USERNAME"], let password = env["CITRIX_PASSWORD"] else {
            throw Failure.config("CITRIX_USERNAME and CITRIX_PASSWORD must be set in .env")
        }
        let username = env["CITRIX_DOMAIN"].map { "\($0)\\\(user)" } ?? user
        let totp = env["CITRIX_TOTP_SECRET"].flatMap {
            TOTP(base32Secret: $0, digits: Int(env["CITRIX_TOTP_DIGITS"] ?? "") ?? 6,
                 period: Int(env["CITRIX_TOTP_PERIOD"] ?? "") ?? 30,
                 algorithm: TOTP.Algorithm(rawValue: (env["CITRIX_TOTP_ALGORITHM"] ?? "SHA1").uppercased()) ?? .sha1)
        }
        guard let totp else { throw Failure.config("CITRIX_TOTP_SECRET must be set in .env") }
        try await GatewayLogon(http: http, base: gateway).logon(.init(username: username, password: password, passcode: {
            return totp.freshCode(statePath: Paths.sessionDir.appendingPathComponent("totp-last").path)
        }))
        try? http.saveCookies(to: Paths.cookieFile)
    }

    /// Resource list; logs on first when the saved gateway session is missing or expired.
    func resources() async throws -> [StoreClient.Resource] {
        let list: [StoreClient.Resource]
        do {
            list = try await store.resources()
        } catch {
            vlog("resource list failed (\(error)); logging on")
            try await logon()
            list = try await store.resources()
        }
        try? http.saveCookies(to: Paths.cookieFile)
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func launch(_ resource: StoreClient.Resource) async throws -> ICAFile {
        let text = try await store.launchICA(resource)
        try? http.saveCookies(to: Paths.cookieFile)
        guard let ica = ICAFile(text: text) else { throw Failure.config("launch did not return an ICA file") }
        return ica
    }
}

/// Session coordinates ↔ macOS global screen coordinates. The session desktop is the bounding box
/// of all screens (1 session pixel = 1 point); session (0,0) is the box's top-left, so screens left
/// of or above the main screen get positive session coordinates too. macOS y grows upwards.
struct ScreenMapping: Equatable {
    struct Screen: Equatable {
        var frame: CGRect
        var visible: CGRect
        var scale: CGFloat
    }
    /// Main screen first (it becomes the primary monitor).
    let screens: [Screen]
    /// Union of all screen frames, macOS global coordinates.
    let union: CGRect

    init(screens: [Screen]) {
        let list = screens.isEmpty ? [Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                             visible: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)] : screens
        self.screens = list
        union = list.dropFirst().reduce(list[0].frame) { $0.union($1.frame) }
    }

    /// Keeps an earlier union (session origin and size) with a new screen list.
    init(screens: [Screen], union: CGRect) {
        self.screens = screens.isEmpty ? [Screen(frame: union, visible: union, scale: 1)] : screens
        self.union = union
    }

    /// True if some screen shows the top strip (title area) of this remote rect.
    func isOnScreen(_ r: TWIRect) -> Bool {
        let top = screenRect(TWIRect(x: r.left, y: r.top, width: r.width, height: min(r.height, 40)))
        return screens.contains { $0.frame.intersection(top).width >= 40 }
    }

    static var current: ScreenMapping {
        // ICAVIEWER_SINGLE_SCREEN=1: main screen only (test: create a session with another layout).
        let screens = ProcessInfo.processInfo.environment["ICAVIEWER_SINGLE_SCREEN"] == "1" ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        return ScreenMapping(screens: screens.map { Screen(frame: $0.frame, visible: $0.visibleFrame, scale: $0.backingScaleFactor) })
    }

    /// Session size: the union, rounded down to even (the server rounds odd sizes down).
    var sessionWidth: Int { Int(union.width) & ~1 }
    var sessionHeight: Int { Int(union.height) & ~1 }

    func screenRect(_ r: TWIRect) -> NSRect {
        NSRect(x: union.minX + CGFloat(r.left), y: union.maxY - CGFloat(r.bottom), width: CGFloat(r.width), height: CGFloat(r.height))
    }

    func remoteRect(_ r: NSRect) -> TWIRect {
        let left = Int32((r.minX - union.minX).rounded()), top = Int32((union.maxY - r.maxY).rounded())
        return TWIRect(x: left, y: top, width: Int32(r.width.rounded()), height: Int32(r.height.rounded()))
    }

    /// Monitors for TWI (0x35/0x3b) and Thinwire (cap 0x11 / 0x1D), primary first. Work area = visible
    /// frame minus room for our title bar on top, so a window the host maximises keeps its macOS title
    /// bar below the menu bar.
    func monitors(titleBar: CGFloat) -> [(twi: TWIMonitor, wd: WDMonitor)] {
        screens.map { s in
            let b = remoteRect(s.frame)
            var work = remoteRect(s.visible)
            work.top += Int32(titleBar.rounded())
            let wd = WDMonitor(left: Int(b.left), top: Int(b.top), right: Int(b.right), bottom: Int(b.bottom),
                               workLeft: Int(work.left), workTop: Int(work.top), workRight: Int(work.right), workBottom: Int(work.bottom),
                               // 1 session pixel = 1 point, so the host must render at 100 % (live: 200 %
                               // per-monitor DPI doubled every window).
                               scalePercent: 100)
            return (TWIMonitor(bounds: b, workArea: work), wd)
        }
    }

    /// Clamps a remote rect so that its top-left part lies on the main screen (used to bring back a
    /// window that ended up outside every screen).
    func onMainScreen(_ r: TWIRect) -> TWIRect {
        let main = remoteRect(screens[0].visible)
        let x = min(max(r.left, main.left), max(main.left, main.right - r.width))
        let y = min(max(r.top, main.top + 30), max(main.top, main.bottom - r.height))
        return TWIRect(x: x, y: y, width: r.width, height: r.height)
    }
}
