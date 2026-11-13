import CoreGraphics
import CoreServices
import Foundation

/// Generates one helper bundle from the template (docs/99 §6): copy, relabel Info.plist, write the
/// icon, strip quarantine, re-sign, verify, register with LaunchServices. Idempotent: a bundle that is
/// already current (`HelperBundle.isCurrent`) and verifies is left alone, so its cdhash, Dock tile and
/// LaunchServices record stay put.
///
/// The new bundle is built in a staging directory next to its final place and moved in when signed, so
/// a crash never leaves a half-written or unsigned app where LaunchServices could find it.
public struct HelperBundleGenerator {
    public enum Outcome: Equatable, Sendable { case created, updated, unchanged }

    public var template: URL
    public var appsDirectory: URL
    /// "-" = ad-hoc. A keychain identity name gives a stable designated requirement instead.
    public var signIdentity: String
    public var hardenedRuntime: Bool
    /// Register with LaunchServices after a change (off in unit tests: temp bundles must not linger in
    /// the LS database).
    public var registerWithLaunchServices: Bool

    public init(template: URL, appsDirectory: URL, signIdentity: String = "-", hardenedRuntime: Bool = true,
                registerWithLaunchServices: Bool = true) {
        self.template = template
        self.appsDirectory = appsDirectory
        self.signIdentity = signIdentity
        self.hardenedRuntime = hardenedRuntime
        self.registerWithLaunchServices = registerWithLaunchServices
    }

    /// `~/Library/Application Support/ICAViewer/Apps`.
    public static var defaultAppsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ICAViewer/Apps", isDirectory: true)
    }

    @discardableResult
    public func generate(_ label: HelperLabel, icon: CGImage?) throws -> (url: URL, outcome: Outcome) {
        let fm = FileManager.default
        let templateHash = try HelperBundle.templateHash(templateURL: template)
        let icns = try icon.map { image -> Data in
            guard let data = HelperIcon.icnsData(image) else { throw HelperBundleError.icon("cannot encode icns") }
            return data
        }
        let iconHash = icns.map(HelperBundle.hash)
        let dir = appsDirectory.appendingPathComponent(HelperBundle.keyHash(label.key), isDirectory: true)
        let target = dir.appendingPathComponent(HelperBundle.fileName(for: label.name), isDirectory: true)

        let existed = fm.fileExists(atPath: target.path)
        if existed, HelperBundle.isCurrent(existing: Self.readInfo(target), label: label, templateHash: templateHash, iconHash: iconHash),
           (try? Self.verify(target)) != nil {
            return (target, .unchanged)
        }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let built = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: template, to: built)

        guard let templateInfo = Self.readInfo(built) else { throw HelperBundleError.badTemplate("unreadable Info.plist") }
        let info = HelperBundle.relabel(templateInfo, label: label, templateHash: templateHash, iconHash: iconHash)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: built.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let resources = built.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let iconURL = resources.appendingPathComponent(HelperBundle.iconFile + ".icns")
        if let icns { try icns.write(to: iconURL, options: .atomic) } else { try? fm.removeItem(at: iconURL) }

        // A copy keeps extended attributes: a template inside a downloaded (quarantined) app would
        // hand its quarantine flag to the copy, and Gatekeeper would then assess an ad-hoc bundle.
        try Self.stripQuarantine(built)
        try Self.sign(built, identity: signIdentity, hardenedRuntime: hardenedRuntime)
        try Self.verify(built)

        // Exactly one bundle per key: an old name of the same app goes.
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "app" {
            try fm.removeItem(at: item)
        }
        try fm.moveItem(at: built, to: target)
        if registerWithLaunchServices { _ = LSRegisterURL(target as CFURL, true) }
        return (target, existed ? .updated : .created)
    }

    public static func readInfo(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: Quarantine

    public static let quarantineAttribute = "com.apple.quarantine"

    public static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the quarantine attribute from the bundle and everything inside it.
    public static func stripQuarantine(_ bundle: URL) throws {
        var paths = [bundle.path]
        if let walker = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in walker { paths.append(bundle.path + "/" + relative) }
        }
        for path in paths where removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw HelperBundleError.codesign("cannot remove quarantine from \(path): errno \(errno)")
        }
    }

    // MARK: codesign

    /// `/usr/bin/codesign --force --sign <identity> [--options runtime] <bundle>`. codesign ships with
    /// macOS itself (not only with the developer tools).
    public static func sign(_ bundle: URL, identity: String, hardenedRuntime: Bool) throws {
        var args = ["--force", "--sign", identity]
        if hardenedRuntime { args += ["--options", "runtime"] }
        if identity != "-" { args.append("--timestamp=none") }
        try codesign(args + [bundle.path])
    }

    public static func verify(_ bundle: URL) throws {
        try codesign(["--verify", "--strict", bundle.path])
    }

    /// Runs codesign; returns its stderr (where `-d` writes), throws with it on failure.
    @discardableResult
    public static func codesign(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperBundleError.codesign("\(args.joined(separator: " ")): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
