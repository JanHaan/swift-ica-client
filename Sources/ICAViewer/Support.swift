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
/// Each line also goes to `LogStore` (memory and log file) for "Report a Problem".
func vlog(_ text: String) {
    let now = Date()
    let line = String(format: "%7.2f ", now.timeIntervalSince(logStart)) + text
    FileHandle.standardError.write(Data((line + "\n").utf8))
    LogStore.shared.append(line, at: now)
}

/// A resource or app name in the log, always as «name»: a problem report hides every such name
/// (ReportScrubber rule 16), also in logs of earlier runs whose store list it never saw.
func logName(_ name: String) -> String { "«\(name)»" }

/// The diagnostic log kept for "Report a Problem" (FeedbackWindow), which scrubs it before showing it.
/// Memory: the last 5,000 lines or 2 MB of this run. File: `~/Library/Logs/ICAViewer/ICAViewer.log`
/// (directory 0700, files 0600), each line prefixed with its UTC time; at 2 MB it becomes
/// `ICAViewer.1.log` and `.1` becomes `.2` (3 files at most), so a report after a relaunch still has
/// the previous run. No file in demo mode, with ICA_LOG_FILE=0 or with the setting `log.file` = NO;
/// then (outside demo mode) the names list and the key that belong to the files are deleted too.
/// `log-key` (0600) is the per-install secret for CDM path labels (CDMPath.logLabel).
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    struct Entry {
        let date: Date
        /// The stderr line without its newline.
        let line: String
    }

    static let maxLines = 5_000
    static let maxBytes = 2 << 20
    static let fileLimit: UInt64 = 2 << 20
    static let fileCount = 3

    static var fileEnabled: Bool {
        !Demo.enabled && ProcessInfo.processInfo.environment["ICA_LOG_FILE"] != "0"
            && (UserDefaults.standard.object(forKey: "log.file") as? Bool ?? true)
    }

    static var directory: URL {
        (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .appendingPathComponent("Logs/ICAViewer")
    }

    static var keyFile: URL { directory.appendingPathComponent("log-key") }

    /// Creates the log directory or resets it to 0700; false if that fails.
    @discardableResult
    static func ensureDirectory() -> Bool { PrivateFile.ensureDirectory(directory) }

    /// Atomic and never readable by others (PrivateFile).
    static func writePrivate(_ data: Data, to url: URL) throws { try PrivateFile.write(data, to: url) }

    /// The per-install CDM label key: read, or created once (32 random bytes).
    private static func loadOrCreateKey() -> Data? {
        if let data = try? Data(contentsOf: keyFile), data.count == 32 { return data }
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        return (try? writePrivate(key, to: keyFile)) != nil ? key : nil
    }

    /// Current file first.
    static var files: [URL] {
        (0..<fileCount).map { directory.appendingPathComponent($0 == 0 ? "ICAViewer.log" : "ICAViewer.\($0).log") }
    }

    private let lock = NSLock()
    private var ring: [Entry] = []
    private var ringBytes = 0
    private var handle: FileHandle?
    private var fileSize: UInt64 = 0
    private var fileOpened = false
    private let stampFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func append(_ line: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        ring.append(Entry(date: date, line: line))
        ringBytes += line.utf8.count + 1
        if ring.count > Self.maxLines + 500 || ringBytes > Self.maxBytes {
            var drop = max(0, ring.count - Self.maxLines)
            var bytes = ringBytes
            for e in ring[..<drop] { bytes -= e.line.utf8.count + 1 }
            while bytes > Self.maxBytes, drop < ring.count { bytes -= ring[drop].line.utf8.count + 1; drop += 1 }
            ring.removeFirst(drop)
            ringBytes = bytes
        }
        writeToFile(stampFormat.string(from: date) + " " + line + "\n")
    }

    private func writeToFile(_ text: String) {
        if !fileOpened {
            fileOpened = true
            guard Self.fileEnabled else {
                if !Demo.enabled {   // turned off: the names and the key go with the files' purpose
                    try? FileManager.default.removeItem(at: ReportNames.file)
                    try? FileManager.default.removeItem(at: Self.keyFile)
                }
                return
            }
            guard Self.ensureDirectory() else { return }
            if let key = Self.loadOrCreateKey() { CDMPath.setLogKey(key) }
            openFile()
            if handle != nil {
                let start = "\(stampFormat.string(from: Date())) ---- ICAViewer started (pid \(ProcessInfo.processInfo.processIdentifier)) ----\n"
                write(Data(start.utf8))
            }
        }
        guard handle != nil else { return }
        let data = Data(text.utf8)
        if fileSize + UInt64(data.count) > Self.fileLimit { rotate() }
        write(data)
    }

    private func write(_ data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            fileSize += UInt64(data.count)
        } catch {
            try? handle.close()
            self.handle = nil   // disk full or removed: memory only from now on
        }
    }

    private func openFile() {
        let fm = FileManager.default
        let url = Self.files[0]
        do {
            guard Self.ensureDirectory() else { throw CocoaError(.fileWriteNoPermission) }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let h = try FileHandle(forWritingTo: url)
            fileSize = try h.seekToEnd()
            handle = h
        } catch {
            handle = nil
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let files = Self.files
        try? fm.removeItem(at: files[files.count - 1])
        for i in stride(from: files.count - 2, through: 0, by: -1) where fm.fileExists(atPath: files[i].path) {
            try? fm.moveItem(at: files[i], to: files[i + 1])
        }
        openFile()
    }

    /// This run's lines since `date` (memory).
    func memoryEntries(since date: Date) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return ring.filter { $0.date >= date }
    }

    /// Lines since `date` from the log files, oldest first (earlier runs included); nil without a file.
    func fileEntries(since date: Date) -> [Entry]? {
        lock.lock()
        let enabled = handle != nil
        lock.unlock()
        guard enabled else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [Entry] = []
        for url in Self.files.reversed() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                guard let space = raw.firstIndex(of: " "), let stamp = parser.date(from: String(raw[..<space])),
                      stamp >= date else { continue }
                out.append(Entry(date: stamp, line: String(raw[raw.index(after: space)...])))
            }
        }
        return out
    }

    /// The report's lines: the files if they are written (they also hold earlier runs), else memory;
    /// at most the newest 5,000 lines or 2 MB.
    func recent(since date: Date) -> [Entry] {
        var list = fileEntries(since: date) ?? memoryEntries(since: date)
        if list.count > Self.maxLines { list.removeFirst(list.count - Self.maxLines) }
        var bytes = list.reduce(0) { $0 + $1.line.utf8.count + 1 }
        var drop = 0
        while bytes > Self.maxBytes, drop < list.count { bytes -= list[drop].line.utf8.count + 1; drop += 1 }
        return Array(list.dropFirst(drop))
    }
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

/// Organisation words to replace in screenshot mode: `word=replacement` rules from ICA_SHOT_CENSOR
/// (separated by `;`) or from the git-ignored file `.shotcheck-censor` in the package root. None by default.
private let censorRules: [(word: String, with: String)] = {
    if let text = ProcessInfo.processInfo.environment["ICA_SHOT_CENSOR"] { return DisplayName.parseReplacements(text) }
    let file = Paths.root.appendingPathComponent(".shotcheck-censor")
    return (try? String(contentsOf: file, encoding: .utf8)).map(DisplayName.parseReplacements) ?? []
}()

/// Resource and app names as shown in the UI. With ICAVIEWER_SCREENSHOT=1 they are censored for
/// screenshots (`DisplayName.censored`); never used for matching or for the protocol.
func displayName(_ name: String) -> String {
    Demo.screenshotMode ? DisplayName.censored(name, replacing: censorRules) : name
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
        ReportNames.shared.record(list.map(\.name))   // hidden in problem reports (FeedbackReport)
        if let store {   // icons and menu title (docs/99 Phase 0)
            DispatchQueue.main.async {
                StoreIconCache.shared.register(store: store)
                DockIcon.shared.register(resources: list)
            }
        }
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
