import CryptoKit
import Foundation

/// Which name (and so which store icon) a remote app gets: its helper's Dock and Cmd-Tab name, the phase-0 Dock
/// icon and the menu title (docs/99 §12.15). Live bug of the phase-3 check: an Explorer window that came first in a
/// "Calculator" session was named and iconed after the launched resource, so two tiles read "Calculator".
///
/// Precedence, best first: (1) the TWI published name; (2) the resource a shared launch mapped to this app key in
/// this session; (3) the same mapping remembered from an earlier run (`AppResourceMap`); (4) the launched resource
/// only when the key is that resource's own app (`app:<resource>`); (5) the TWI app's own name, readable
/// (`Microsoft.Windows.Explorer` → "Explorer"), then as sent. Never the session's launch resource otherwise.
public enum AppNaming {
    public static func candidates(key: String, publishedName: String?, sessionResource: String?, rememberedResource: String?,
                                  twiName: String?, launchResource: String?) -> [String] {
        var out: [String] = []
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  !out.contains(where: { normalized($0) == normalized(s) }) else { return }
            out.append(s)
        }
        add(publishedName)
        add(sessionResource)
        add(rememberedResource)
        if let launch = launchResource, isOwnApp(key: key, resource: launch) { add(launch) }
        if let twiName { add(readable(twiName)) }
        add(twiName)
        return out
    }

    /// The name part of a TWI app key (`app:Name`, `aumid:Id`, `exe:Path`), for an app whose TWI data has not arrived.
    public static func keyName(_ key: String) -> String? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let rest = key[key.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Windows logon and shell-support processes that are never a published app of their own: the logon UI, the
    /// logon-script console (UsrLogon.cmd runs in cmd.exe; live it ran after the logon was judged over), its console
    /// host, userinit, winlogon, dwm, ctfmon, sihost, taskhostw. Their windows stay in the main process, and they are
    /// never taken for a launched resource (unless its `InitialProgram` names them) or remembered as one (live check
    /// 2026-11-13: the logon console was mapped to "Explorer Citrix ABC"). Not here: explorer.exe (File Explorer is a
    /// published app, "Explorer Citrix ABC") and rundll32.exe (control-panel apps such as "Sound ABC" run in it).
    public static let systemExecutables: Set<String> = [
        "cmd.exe", "conhost.exe", "logonui.exe", "userinit.exe", "winlogon.exe", "dwm.exe", "ctfmon.exe", "sihost.exe",
        "taskhostw.exe",
    ]

    /// The lower-case executable file name of an app: from `exe:<path>` keys, else from the TWI executable path.
    public static func executableName(key: String, executablePath: String?) -> String? {
        let path = key.hasPrefix("exe:") ? String(key.dropFirst(4)) : executablePath
        guard let path, !path.isEmpty else { return nil }
        let file = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
        let name = file.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        return name.isEmpty ? nil : name
    }

    public static func isSystemProcess(_ executable: String?) -> Bool {
        executable.map { systemExecutables.contains($0.lowercased()) } ?? false
    }

    /// The executable a launch names itself (`InitialProgram` as a path, not `#<published name>`); nil = no hint.
    public static func launchHint(initialProgram: String) -> String? {
        let p = initialProgram.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !p.hasPrefix("#") else { return nil }
        return executableName(key: "exe:" + p, executablePath: nil).flatMap { $0.hasSuffix(".exe") ? $0 : nil }
    }

    /// Whether an app that appeared while a launch of `resource` was pending may be taken for it: only once the launch
    /// counts as started (a shared launch: the host reported status 0; the session's own launch: the logon phase is
    /// over); an app with a published name only if it is that resource; with an executable hint only that
    /// executable; never a logon or system process (unless the hint names it).
    public static func mayBeLaunchedApp(executable: String?, publishedName: String?, resource: String, hint: String?,
                                        launchStarted: Bool) -> Bool {
        guard launchStarted else { return false }
        if let published = publishedName, !published.isEmpty { return normalized(published) == normalized(resource) }
        if let hint { return executable == hint }
        return !isSystemProcess(executable)
    }

    /// The first pending launch that a newly added TWI app (`key`) is, if any (docs/99 §12.15).
    public static func firstMatch(_ pending: [AwaitedLaunch], key: String, executable: String?, publishedName: String?,
                                  at now: Date) -> Int? {
        pending.firstIndex { entry in
            !entry.known.contains(key)
                && mayBeLaunchedApp(executable: executable, publishedName: publishedName, resource: entry.resource,
                                    hint: entry.hint, launchStarted: entry.eligible(at: now))
        }
    }

    /// The key is the app of `resource`: `app:<resource>` (the TWI published name), compared as store names are.
    public static func isOwnApp(key: String, resource: String) -> Bool {
        key.hasPrefix("app:") && normalized(String(key.dropFirst(4))) == normalized(resource) && !normalized(resource).isEmpty
    }

    /// A TWI app name that is an identifier made readable: an AUMID (`Microsoft.Windows.Explorer`,
    /// `Microsoft.WindowsCalculator_8wekyb3d8bbwe!App`) → its last meaningful part, an executable path → its file
    /// name without `.exe`. Names with spaces are already readable and stay.
    public static func readable(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return s }
        if s.contains("\\") || s.contains("/") {
            s = String(s.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(s))
        }
        if let bang = s.firstIndex(of: "!") { s = String(s[..<bang]) }
        if let underscore = s.firstIndex(of: "_") { s = String(s[..<underscore]) }      // package publisher hash
        if s.lowercased().hasSuffix(".exe") { s.removeLast(4) }
        let parts = s.split(separator: ".").map(String.init).filter { part in
            !part.isEmpty && !part.allSatisfy(\.isNumber) && part.lowercased() != "exe"
        }
        return parts.last ?? s
    }

    /// `name`, or "name (n)" with the smallest n ≥ 2 that no other app uses: two different app keys never share a
    /// Dock name (compared case-insensitively, as the Dock reads them).
    public static func unique(_ name: String, taken: Set<String>) -> String {
        let used = Set(taken.map(normalized))
        guard used.contains(normalized(name)) else { return name }
        var n = 2
        while used.contains(normalized("\(name) (\(n))")) { n += 1 }
        return "\(name) (\(n))"
    }

    /// As `StoreIconIndex.normalize` (ICAKit): case, spacing and a trailing `.exe` ignored.
    public static func normalized(_ name: String) -> String {
        var s = name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.hasSuffix(".exe") { s.removeLast(4) }
        return s
    }
}

/// A launch whose app has not been identified yet: a shared launch (CTXCTL, docs/55) or the session's own launch.
/// Windows the host re-announces right after a (re)connect belong to apps that ran before, so the own launch only
/// takes apps added `ownLaunchGrace` after the logon phase ended (live: the Explorer of an earlier launch came
/// 0.05 s after a reconnect's host init; the launched File Explorer 1.8 s after a fresh logon was judged over).
public struct AwaitedLaunch: Equatable, Sendable {
    public static let ownLaunchGrace: TimeInterval = 0.5
    public var resource: String
    /// App keys present when the launch went out (not it).
    public var known: Set<String>
    /// The executable `InitialProgram` names, if any (`AppNaming.launchHint`).
    public var hint: String?
    /// Shared launch: when the host reported status 0; own launch: when the logon phase ended. nil = not yet.
    public var startedAt: Date?
    public var ownLaunch: Bool

    public init(resource: String, known: Set<String> = [], hint: String? = nil, startedAt: Date? = nil, ownLaunch: Bool = false) {
        self.resource = resource; self.known = known; self.hint = hint; self.startedAt = startedAt; self.ownLaunch = ownLaunch
    }

    public func eligible(at now: Date) -> Bool {
        guard let startedAt else { return false }
        return !ownLaunch || now.timeIntervalSince(startedAt) >= Self.ownLaunchGrace
    }
}

/// TWI app key → published resource, learnt from session sharing (`session sharing: TWI app «…» is «…»`) and
/// remembered per store across runs (docs/99 §12.15). Keys and stores are stored only as hashes; the resource
/// name is stored as the Dock shows it (it already is a bundle name). File mode 0600 in the app's support folder.
/// An app that announces a published name confirms itself: any other key remembered for that resource goes (a
/// wrong mapping cannot outlive the real app's first appearance).
public struct AppResourceMap: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var resource: String
        /// The app's executable file name (e.g. "explorer.exe"; no path), so system processes can be dropped.
        public var executable: String?
    }

    /// store id → key hash → entry. (A file of the first, string-valued format does not decode and is dropped.)
    public private(set) var stores: [String: [String: Entry]] = [:]

    public init() {}

    public static func storeID(_ base: URL) -> String { hash(base.absoluteString) }
    public static func keyID(_ key: String) -> String { HelperBundle.keyHash(key) }

    public func resource(store: String, key: String) -> String? { stores[store]?[Self.keyID(key)]?.resource }

    /// Records `key` → `resource` (a confirmed mapping); another key remembered for the same resource in this store
    /// is dropped (one app per resource). A system or logon process is never recorded. Returns whether anything
    /// changed.
    @discardableResult
    public mutating func remember(store: String, key: String, resource: String, executable: String?) -> Bool {
        guard !AppNaming.isSystemProcess(executable) else { return false }
        let id = Self.keyID(key)
        var map = stores[store] ?? [:]
        let before = map
        map = map.filter { $0.key == id || AppNaming.normalized($0.value.resource) != AppNaming.normalized(resource) }
        map[id] = Entry(resource: resource, executable: executable?.lowercased())
        stores[store] = map
        return map != before
    }

    /// Entries that point at a system or logon process (an older build, or a file edited by hand) go.
    public mutating func dropSystemProcesses() -> Bool {
        let before = stores
        for (store, map) in stores {
            let kept = map.filter { !AppNaming.isSystemProcess($0.value.executable) }
            stores[store] = kept.isEmpty ? nil : kept
        }
        return stores != before
    }

    /// `key` announced `publishedName` itself: no other key may stand for that resource, and its own entry is not
    /// needed. Returns whether anything changed.
    @discardableResult
    public mutating func confirm(store: String, key: String, publishedName: String) -> Bool {
        guard var map = stores[store] else { return false }
        let id = Self.keyID(key)
        let before = map
        map = map.filter { $0.key != id && AppNaming.normalized($0.value.resource) != AppNaming.normalized(publishedName) }
        stores[store] = map.isEmpty ? nil : map
        return map != before
    }

    /// The saved map without system-process entries (`dropSystemProcesses`); empty when missing or unreadable.
    public static func load(from url: URL) -> AppResourceMap {
        guard let data = try? Data(contentsOf: url), var map = try? JSONDecoder().decode(AppResourceMap.self, from: data) else {
            return AppResourceMap()
        }
        _ = map.dropSystemProcesses()
        return map
    }

    /// Written to a 0600 temporary file next to `url`, then renamed over it (never readable by others, never
    /// half-written). The folder is created 0700.
    public func save(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// `~/Library/Application Support/ICAViewer/app-resources.json`.
    public static var defaultURL: URL {
        HelperBundleGenerator.defaultAppsDirectory.deletingLastPathComponent().appendingPathComponent("app-resources.json")
    }

    private static func hash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
