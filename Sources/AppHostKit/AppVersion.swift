import Foundation

/// Version, build and commit of an app bundle, read from its Info.plist dictionary (CFBundleShortVersionString,
/// CFBundleVersion, ICAGitCommit; written by scripts/bundle.sh). Used by the About panels and problem reports.
public struct AppVersion: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var commit: String?

    public init(info: [String: Any]?) {
        func value(_ key: String) -> String? {
            guard let s = (info?[key] as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return s
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
        commit = value("ICAGitCommit")
    }

    public static var current: AppVersion { AppVersion(info: Bundle.main.infoDictionary) }

    /// No Info.plist version: `swift run` or another unbundled build.
    public var isDevelopment: Bool { version == nil }

    /// "Build 123, abc1234", "Build 123", "abc1234" or nil.
    public var buildLine: String? {
        var parts: [String] = []
        if let build { parts.append("Build \(build)") }
        if let commit { parts.append(commit) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "Version 0.6.0 (Build 123, abc1234)", or "Development build".
    public func displayString(german: Bool = false) -> String {
        guard let version else { return german ? "Entwicklungs-Build" : "Development build" }
        let label = german ? "Version" : "Version"
        return buildLine.map { "\(label) \(version) (\($0))" } ?? "\(label) \(version)"
    }

    /// "0.6.0" or "development build", for "Shown by ICA Viewer …".
    public func shortString(german: Bool = false) -> String {
        version ?? (german ? "Entwicklungs-Build" : "development build")
    }

    /// One line for problem reports: "ICAViewer 0.6.0 (Build 123, abc1234)" or "ICAViewer development build (...)".
    public func reportString(name: String = "ICAViewer") -> String {
        guard let version else { return "\(name) development build" + (buildLine.map { " (\($0))" } ?? "") }
        return "\(name) \(version)" + (buildLine.map { " (\($0))" } ?? "")
    }
}
