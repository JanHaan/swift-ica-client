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
            if totp.secondsRemaining() < 3 { Thread.sleep(forTimeInterval: Double(totp.secondsRemaining()) + 0.5) }
            return totp.code()
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

/// Session coordinates (top-left origin, 1 session pixel = 1 point) ↔ the primary screen's
/// coordinate space (bottom-left origin).
struct ScreenMapping {
    let height: CGFloat
    let width: CGFloat

    static var primary: ScreenMapping {
        let frame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return ScreenMapping(height: frame.height, width: frame.width)
    }

    func screenRect(_ r: TWIRect) -> NSRect {
        NSRect(x: CGFloat(r.left), y: height - CGFloat(r.bottom), width: CGFloat(r.width), height: CGFloat(r.height))
    }

    func remoteRect(_ r: NSRect) -> TWIRect {
        let left = Int32(r.minX.rounded()), top = Int32((height - r.maxY).rounded())
        return TWIRect(x: left, y: top, width: Int32(r.width.rounded()), height: Int32(r.height.rounded()))
    }

    /// Monitor for TWI: whole screen, work area = visible frame minus room for our title bar on top,
    /// so a window the host maximises still has its macOS title bar below the menu bar.
    func monitor(titleBar: CGFloat) -> TWIMonitor {
        let screen = NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: width, height: height)
        let bounds = TWIRect(x: 0, y: 0, width: Int32(width), height: Int32(height))
        let top = Int32((height - visible.maxY + titleBar).rounded())
        let work = TWIRect(left: Int32(visible.minX), top: top, right: Int32(visible.maxX), bottom: Int32((height - visible.minY).rounded()))
        return TWIMonitor(bounds: bounds, workArea: work)
    }
}
