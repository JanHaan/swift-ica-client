import AppKit
import Foundation
import ICAKit

/// Project paths. The viewer is a personal tool built from this checkout: `.env` and `.session/` live
/// in the checkout (override with ICA_ROOT / ICA_ENV). Without ICA_ROOT the checkout is the nearest
/// directory above the executable, else above the current directory, that holds `Package.swift`;
/// failing that (an installed app) `~/Library/Application Support/ICAViewer`.
enum Paths {
    static let root: URL = {
        if let r = ProcessInfo.processInfo.environment["ICA_ROOT"] { return URL(fileURLWithPath: r) }
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL { starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        #if DEBUG
        starts.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())   // debug builds only: embeds the build path
        #endif
        for start in starts {
            if let found = packageRoot(above: start) { return found }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ICAViewer")
    }()

    /// The nearest directory at or above `start` with a `Package.swift`.
    static func packageRoot(above start: URL) -> URL? {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    static var envFile: String { ProcessInfo.processInfo.environment["ICA_ENV"] ?? root.appendingPathComponent(".env").path }
    static var sessionDir: URL { root.appendingPathComponent(".session") }
    static var cookieFile: String { sessionDir.appendingPathComponent("cookies.plist").path }
    /// Last TOTP window used (gateways accept each code once).
    static var totpState: String { sessionDir.appendingPathComponent("totp-last").path }
}

private let logStart = Date()

/// Diagnostic log on stderr. Never pass credentials, tickets, cookies or ICA file contents.
func vlog(_ text: String) {
    let line = String(format: "%7.2f ", Date().timeIntervalSince(logStart)) + text + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

/// Which resources this process may launch. Launches the user starts in the launcher are not
/// restricted. Automated ones (ICAVIEWER_LAUNCH, self-test, hold and probe runs) only start the test
/// resources: the names in ICA_TEST_RESOURCES (comma separated), unless ICA_ALLOW_ANY_RESOURCE=1.
enum LaunchPolicy {
    static let defaultTestResource = "Calculator"

    static func allows(_ name: String, automated: Bool, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if !automated || env["ICA_ALLOW_ANY_RESOURCE"] == "1" { return true }
        let allowed = env["ICA_TEST_RESOURCES"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            ?? [defaultTestResource]
        return allowed.contains(name)
    }

    /// True if the environment asks for an unattended run.
    static func envAutomated(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["ICAVIEWER_LAUNCH"] != nil || env["ICAVIEWER_SELFTEST"] == "1" || env["ICAVIEWER_HOLD_SECONDS"] != nil
            || env["ICAVIEWER_PROBE_CLICK"] == "1"
    }
}

/// Resource and app names as shown in the UI. With ICAVIEWER_SCREENSHOT=1 they are censored for
/// screenshots (`DisplayName.censored`); never used for matching or for the protocol.
func displayName(_ name: String) -> String {
    Demo.screenshotMode ? DisplayName.censored(name) : name
}

/// Login, resource list and launch through the gateway.
/// Logon: with CITRIX_USERNAME and CITRIX_PASSWORD in `.env`, non-interactively as `icactl` does
/// (automated tests); otherwise through the login window, with the settings and Keychain as source.
final class StoreService: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case config(String)
        var description: String { if case .config(let s) = self { return s }; return "" }
    }

    let http = HTTPClient()
    let env: Env?
    let credentials: LoginCredentials
    /// Gateway root URL (`https://host/`); nil until the user enters one.
    private(set) var gateway: URL?
    /// The login window; set by the app delegate. Throws if the user cancels.
    var interactiveLogon: (@MainActor () async throws -> Void)?
    var store: StoreClient? { gateway.map { StoreClient(http: http, base: URL(string: "welcome/", relativeTo: $0)!.absoluteURL) } }

    /// ICAVIEWER_LOGIN_AUTOFILL=1: always use the login window (test mode, see LoginWindowController).
    static let autofill = ProcessInfo.processInfo.environment["ICAVIEWER_LOGIN_AUTOFILL"] == "1"

    /// True if `.env` supplies the credentials (non-interactive logon).
    var usesEnvCredentials: Bool {
        !Self.autofill && env?["CITRIX_USERNAME"] != nil && env?["CITRIX_PASSWORD"] != nil
    }

    init() {
        env = Demo.enabled ? nil : try? Env(path: Paths.envFile)
        let keychain = KeychainSecretStore()
        keychain.log = { vlog($0) }
        credentials = LoginCredentials(settings: UserDefaultsSettingsStore(), secrets: keychain)
        credentials.log = { vlog($0) }
        let settings = Demo.enabled ? LoginSettings() : credentials.settings.load()
        let envGateway = env?["CITRIX_GATEWAY_URL"].flatMap(LoginSettings.gatewayURL(from:))
        if env?["CITRIX_USERNAME"] != nil && env?["CITRIX_PASSWORD"] != nil && !Self.autofill {
            gateway = envGateway ?? settings.gateway
        } else {
            gateway = settings.gateway ?? envGateway
        }
        vlog("gateway: \(gateway?.host ?? "none"); logon: \(usesEnvCredentials ? ".env" : "login window")")
        http.trace = { vlog("http " + $0) }   // paths and cookie names only (HTTPClient redacts query values)
        if Demo.enabled { return }   // demo mode touches neither the disk nor the network
        try? FileManager.default.createDirectory(at: Paths.sessionDir, withIntermediateDirectories: true)
        try? http.loadCookies(from: Paths.cookieFile)
    }

    /// Changes the gateway and stores it in the settings.
    func setGateway(_ url: URL) {
        if url.host != gateway?.host { http.clearCookies() }
        gateway = url
        var settings = credentials.settings.load()
        settings.gatewayURL = url.absoluteString
        credentials.settings.save(settings)
    }

    /// Logs on at the gateway (`.env` or the login window).
    func logon() async throws {
        if usesEnvCredentials {
            try await envLogon()
        } else {
            guard let interactiveLogon else { throw Failure.config("no login window") }
            try await interactiveLogon()
        }
        try? http.saveCookies(to: Paths.cookieFile)
    }

    /// nFactor logon with username, password and TOTP passcode from `.env`.
    private func envLogon() async throws {
        guard let env, let gateway, let user = env["CITRIX_USERNAME"], let password = env["CITRIX_PASSWORD"] else {
            throw Failure.config("CITRIX_USERNAME and CITRIX_PASSWORD must be set in .env")
        }
        let totp = Self.envTOTP(env)
        guard let totp else { throw Failure.config("CITRIX_TOTP_SECRET must be set in .env") }
        try await GatewayLogon(http: http, base: gateway).logon(.init(username: Self.envUsername(env, user), password: password, passcode: {
            return totp.freshCode(statePath: Paths.totpState)
        }))
    }

    static func envUsername(_ env: Env, _ user: String) -> String {
        env["CITRIX_DOMAIN"].map { "\($0)\\\(user)" } ?? user
    }

    static func envTOTP(_ env: Env) -> TOTP? {
        env["CITRIX_TOTP_SECRET"].flatMap {
            TOTP(base32Secret: $0, digits: Int(env["CITRIX_TOTP_DIGITS"] ?? "") ?? 6,
                 period: Int(env["CITRIX_TOTP_PERIOD"] ?? "") ?? 30,
                 algorithm: TOTP.Algorithm(rawValue: (env["CITRIX_TOTP_ALGORITHM"] ?? "SHA1").uppercased()) ?? .sha1)
        }
    }

    /// Resource list; logs on first when there is no gateway session or it has expired.
    func resources(forceLogon: Bool = false) async throws -> [StoreClient.Resource] {
        let list: [StoreClient.Resource]
        if forceLogon || gateway == nil || http.cookieNames.isEmpty {
            try await logon()
            guard let store else { throw Failure.config("no gateway") }
            list = try await store.resources()
        } else {
            do {
                list = try await store!.resources()
            } catch {
                vlog("resource list failed (\(error)); logging on")
                try await logon()
                list = try await store!.resources()
            }
        }
        try? http.saveCookies(to: Paths.cookieFile)
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func launch(_ resource: StoreClient.Resource) async throws -> ICAFile {
        guard let store else { throw Failure.config("no gateway") }
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
