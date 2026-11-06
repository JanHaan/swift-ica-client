import AppKit
import ICAKit
import SystemConfiguration

/// Resource names the store listed, kept across runs so a report hides them also in the log files
/// of earlier runs (ReportScrubber rule 16): `~/Library/Logs/ICAViewer/resource-names.json` (0600),
/// next to the logs it serves and only while they are written (LogStore deletes it when they are
/// turned off); written atomically through a 0600 temp file; at most 2,000 names.
final class ReportNames: @unchecked Sendable {
    static let shared = ReportNames()
    static let maxNames = 2_000
    private let lock = NSLock()
    private var names: [String] = []
    private var loaded = false

    static var file: URL { LogStore.directory.appendingPathComponent("resource-names.json") }

    func record(_ list: [String]) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let known = Set(names)
        let added = Array(Set(list.filter { !$0.isEmpty && !known.contains($0) })).sorted()
        guard !added.isEmpty else { return }
        names = Array((names + added).suffix(Self.maxNames))
        guard LogStore.fileEnabled, let data = try? JSONEncoder().encode(names), LogStore.ensureDirectory() else { return }
        try? LogStore.writePrivate(data, to: Self.file)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return names
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard LogStore.fileEnabled, let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode([String].self, from: data) else { return }
        names = Array(stored.suffix(Self.maxNames))
    }
}

/// What a problem report contains besides the user's text: environment, settings summary (never a
/// secret, a host or a name: the scrubber would catch them, but they are not collected at all), the
/// scrubber's context, and writing the report file. Nothing here touches the network or the Keychain.
@MainActor
enum FeedbackSources {
    // MARK: Environment

    static func environment() -> [String] {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #else
        arch = sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        if let version = info["CFBundleShortVersionString"] as? String {
            lines.append("ICAViewer \(version) (\(info["CFBundleVersion"] as? String ?? "?")), \(arch)")
        } else {
            lines.append("ICAViewer development build (no app bundle), \(arch)")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                     + (sysctlString("kern.osversion").map { " (\($0))" } ?? ""))
        var mac = [sysctlString("hw.model") ?? "unknown model"]
        if let cpu = sysctlString("machdep.cpu.brand_string") { mac.append(cpu) }
        if let memory = sysctlInt("hw.memsize"), memory > 0 { mac.append("\(memory >> 30) GB") }
        lines.append("Mac: " + mac.joined(separator: ", "))
        let screens = NSScreen.screens
        let shown = screens.enumerated().map { index, screen in
            let f = screen.frame
            return "\(screen.localizedName) \(Int(f.width))×\(Int(f.height)) pt @\(Int(screen.backingScaleFactor))x"
                + (index == 0 ? " (main)" : "")
        }
        lines.append("Displays (\(screens.count)): " + (shown.isEmpty ? "none" : shown.joined(separator: "; ")))
        lines.append("Language: " + (Locale.preferredLanguages.first ?? "?"))
        if Demo.enabled { lines.append("Demo mode: on") }
        if Demo.screenshotMode { lines.append("Screenshot mode: on") }
        return lines
    }

    // MARK: Settings

    static func settings() -> [String] {
        var lines: [String] = []
        let login = UserDefaultsSettingsStore().load()
        let env = Demo.enabled ? nil : try? Env(path: Paths.envFile)
        let envGateway = env?["CITRIX_GATEWAY_URL"] != nil
        lines.append("Gateway: " + (login.gateway != nil ? "set in Settings" : envGateway ? "set in .env" : "not set")
                     + (login.gateway != nil && envGateway ? " and in .env" : "") + " (host not shown)")
        let envLogon = env?["CITRIX_USERNAME"] != nil && env?["CITRIX_PASSWORD"] != nil && !StoreService.autofill
        lines.append("Sign-in: " + (envLogon ? ".env (non-interactive)" : "login window"))
        switch login.passcodeMode {
        case .prompt: lines.append("Passcode: typed at each sign-in")
        case .totp: lines.append("Passcode: from a stored TOTP secret (\(login.totpDigits) digits, \(login.totpPeriod) s, \(login.totpAlgorithm.rawValue))")
        }
        lines.append("Stored password needs Touch ID or the Mac password: " + (login.protectPassword ? "yes" : "no"))
        lines.append("Scaling: \(ScalingSettings.load())")
        let cdm = CDMSettings.load()
        lines.append("Drive mapping: " + (cdm.enabled
            ? "on, \(cdm.readOnly ? "read-only" : "read-write"), drive \(cdm.letter):, "
                + (cdm.folder.standardizedFileURL == CDMSettings.defaultFolder.standardizedFileURL ? "default folder" : "other folder")
            : "off"))
        let print = PrintSettings.load()
        lines.append("Printing: " + (print.enabled ? "on, \(print.action == .preview ? "Preview" : "print panel") first" : "off"))
        let audio = AudioSettings.load()
        lines.append("Audio: " + (audio.enabled
            ? "on, microphone \(audio.microphone ? "on" : "off"), codecs \(audio.codecs.map(\.rawValue).sorted().joined(separator: ", "))"
            : "off"))
        let webcam = WebcamSettings.load()
        lines.append("Webcam: " + (webcam.enabled
            ? "on, " + (webcam.source == .synthetic ? "synthetic test pattern" : webcam.deviceID == nil ? "automatic camera" : "chosen camera (name not shown)")
            : "off"))
        lines.append("Cmd-Q with open connections: \(QuitAction.stored.rawValue)")
        lines.append("Reconnect offer after sign-in: \(ReconnectAtStart.stored.rawValue)")
        lines.append("Log file: " + (LogStore.fileEnabled ? "on" : "off"))
        if let env {
            lines.append(".env keys (values not shown): " + env.values.keys.filter { env[$0] != nil }.sorted().joined(separator: ", "))
        }
        let overrides = ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix("ICA_") || $0.hasPrefix("ICAVIEWER_") || $0.hasPrefix("CITRIX_") }.sorted()
        if !overrides.isEmpty { lines.append("Environment variables set (values not shown): " + overrides.joined(separator: ", ")) }
        return lines
    }

    // MARK: Scrubber context

    /// Everything the scrubber must hide that is known on this Mac. Reads the settings and `.env`;
    /// never the Keychain (stored passwords and TOTP secrets are not in the log in the first place).
    static func scrubberContext() -> ReportScrubber.Context {
        var c = ReportScrubber.Context()
        let login = UserDefaultsSettingsStore().load()
        let env = Demo.enabled ? nil : try? Env(path: Paths.envFile)
        let process = ProcessInfo.processInfo.environment
        if let host = login.gatewayHost { c.hosts.append(host) }
        for (key, value) in env?.values ?? [:] where !value.isEmpty {
            let upper = key.uppercased()
            if ["URL", "HOST", "GATEWAY", "STORE"].contains(where: upper.contains), value.contains(".") {
                if let host = LoginSettings.gatewayURL(from: value)?.host { c.hosts.append(host) }
                else if let host = URL(string: value)?.host { c.hosts.append(host) }
            }
            if ["PASSWORD", "SECRET", "TOKEN", "PASSCODE", "TICKET", "COOKIE", "KEY", "PIN"].contains(where: upper.contains) {
                c.secretValues.append(value)
            }
        }
        c.userNames = [login.username, env?["CITRIX_USERNAME"] ?? "", NSUserName(), NSFullUserName()].filter { !$0.isEmpty }
        if let domain = env?["CITRIX_DOMAIN"] { c.domains.append(domain) }
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { c.computerNames.append(name) }
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { c.computerNames.append(name) }
        c.resourceNames = ReportNames.shared.all + [LaunchPolicy.defaultTestResource]
        if let name = env?["CITRIX_RESOURCE"] { c.resourceNames.append(name) }
        if let name = process["ICAVIEWER_LAUNCH"], !name.isEmpty { c.resourceNames.append(name) }
        for key in ["ICA_TEST_RESOURCES"] {
            for list in [process[key], env?[key]].compactMap({ $0 }) {
                c.resourceNames += list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        c.censorWords = censorWords().map { ReportScrubber.Replacement(word: $0.word, with: $0.with) }
        return c
    }

    /// The private screenshot censor list (ICA_SHOT_CENSOR or `.shotcheck-censor`), as displayName uses it.
    private static func censorWords() -> [(word: String, with: String)] {
        if let text = ProcessInfo.processInfo.environment["ICA_SHOT_CENSOR"] { return DisplayName.parseReplacements(text) }
        let file = Paths.root.appendingPathComponent(".shotcheck-censor")
        return (try? String(contentsOf: file, encoding: .utf8)).map(DisplayName.parseReplacements) ?? []
    }

    // MARK: Files

    /// Writes the report into `folder`: Markdown, or a zip of it above 8 MB (GitHub takes up to 25 MB).
    nonisolated static func write(markdown: String, fileName: String, to folder: URL) throws -> URL {
        let data = Data(markdown.utf8)
        let target = folder.appendingPathComponent(fileName)
        guard data.count > 8 << 20 else {
            try data.write(to: target, options: .atomic)
            return target
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent(fileName)
        try data.write(to: source)
        let zip = target.deletingPathExtension().appendingPathExtension("zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    // MARK: sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}
