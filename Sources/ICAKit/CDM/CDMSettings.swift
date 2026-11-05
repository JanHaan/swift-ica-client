import Foundation

/// The shared folder setting (docs/95 §A.8 step 7, D32): one dedicated Mac folder, default
/// `~/Citrix Shared` (created on first use), read-write with a read-only switch, shown in the session as
/// client drive `M` ("M on <client name>", §A.6). Applies at connect.
public struct CDMSettings: Equatable, Sendable {
    public var enabled = true
    public var folder: URL = CDMSettings.defaultFolder
    public var readOnly = false
    public var letter: Character = "M"

    public init() {}

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Citrix Shared", isDirectory: true)
    }

    public static let enabledKey = "cdm.enabled"
    public static let folderKey = "cdm.folder"
    public static let readOnlyKey = "cdm.readOnly"
    public static let letterKey = "cdm.letter"

    /// From UserDefaults; ICA_CDM=0/off, ICA_CDM_FOLDER, ICA_CDM_READONLY=1 and ICA_CDM_LETTER override
    /// (automated runs).
    public static func load(defaults: UserDefaults = .standard,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> CDMSettings {
        var s = CDMSettings()
        if defaults.object(forKey: enabledKey) != nil { s.enabled = defaults.bool(forKey: enabledKey) }
        if let path = defaults.string(forKey: folderKey), !path.isEmpty { s.folder = URL(fileURLWithPath: path, isDirectory: true) }
        s.readOnly = defaults.bool(forKey: readOnlyKey)
        if let l = defaults.string(forKey: letterKey).flatMap(parseLetter) { s.letter = l }
        if let v = env["ICA_CDM"]?.lowercased() { s.enabled = !["0", "off", "no"].contains(v) }
        if let path = env["ICA_CDM_FOLDER"], !path.isEmpty { s.folder = URL(fileURLWithPath: path, isDirectory: true) }
        if let v = env["ICA_CDM_READONLY"] { s.readOnly = ["1", "on", "yes"].contains(v.lowercased()) }
        if let l = env["ICA_CDM_LETTER"].flatMap(parseLetter) { s.letter = l }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(folder.path, forKey: Self.folderKey)
        defaults.set(readOnly, forKey: Self.readOnlyKey)
        defaults.set(String(letter), forKey: Self.letterKey)
    }

    static func parseLetter(_ text: String) -> Character? {
        guard text.count == 1, let c = text.uppercased().first, c.isASCII, c.isLetter else { return nil }
        return c
    }

    /// Label for VOLUME_INFO: the folder's name.
    public var label: String { folder.lastPathComponent }

    /// Why `folder` must not be shared, or nil. Never `/`, the home folder or anything above it, ~/Library,
    /// a dot-folder in the home folder (~/.ssh, ~/.config, …) or inside one, a whole volume (/Volumes/X),
    /// or a system folder (§A.7 item 1): the session is untrusted and gets everything below the root.
    public static func refusal(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        func norm(_ url: URL) -> String {
            let p = url.standardizedFileURL.resolvingSymlinksInPath().path
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
        let path = norm(folder), homePath = norm(home)
        if path == "/" { return "the whole disk" }
        if homePath == path || homePath.hasPrefix(path + "/") { return "the home folder or a folder that contains it" }
        let library = homePath + "/Library"
        if path == library || path.hasPrefix(library + "/") { return "the Library folder" }
        if path.hasPrefix(homePath + "/"), path.dropFirst(homePath.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return "a hidden folder in the home folder"
        }
        let parts = path.split(separator: "/")
        if parts.count == 2, parts[0] == "Volumes" { return "a whole volume" }
        for system in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private", "/var", "/tmp",
                       "/opt", "/cores", "/dev", "/Volumes"] where path == system || (system != "/Volumes" && path.hasPrefix(system + "/")) {
            return "a system folder"
        }
        return nil
    }

    public enum Failure: Error, CustomStringConvertible {
        case refused(String, String)
        case missing(String)
        public var description: String {
            switch self {
            case .refused(let path, let why): return "\(path) cannot be shared (\(why))"
            case .missing(let path): return "\(path) does not exist"
            }
        }
    }

    /// The file system for the folder. The default folder is created (mode 0700) on first use; another
    /// folder must exist.
    public func makeFileSystem() throws -> CDMPOSIXFileSystem {
        if let why = Self.refusal(folder) { throw Failure.refused(folder.path, why) }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard folder.standardizedFileURL == Self.defaultFolder.standardizedFileURL else { throw Failure.missing(folder.path) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        return try CDMPOSIXFileSystem(root: folder, readOnly: readOnly)
    }
}
