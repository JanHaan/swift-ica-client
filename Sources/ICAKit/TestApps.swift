import Foundation

/// An app a live test drives (D110): the store resource, the executables its windows belong to, and a word the
/// title of its blank document contains. The company farm's apps are built in; the lab's come from `lab/apps.conf`.
public struct TestApp: Equatable, Sendable {
    public var resource: String
    /// Lowercased executable basenames (`notepad.exe`, `soffice.bin`).
    public var executables: [String]
    /// Lowercased; nil when the test does not check the title.
    public var titleWord: String?
    /// Title prefixes of first-run dialogs the app shows over its first window (LibreOffice's "Welcome to LibreOffice!"
    /// and "Tip of the Day: 1/224" in a new profile). A test may close these with Esc; any other window still stops it.
    public var firstRunDialogs: [String]

    public init(resource: String, executables: [String], titleWord: String? = nil, firstRunDialogs: [String] = []) {
        self.resource = resource
        self.executables = executables.map { $0.lowercased() }
        self.titleWord = titleWord.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.firstRunDialogs = firstRunDialogs
    }

    /// Every title is a listed first-run dialog (and there is at least one).
    public func onlyFirstRunDialogs(_ titles: [String]) -> Bool {
        !titles.isEmpty && titles.allSatisfy { title in firstRunDialogs.contains { !$0.isEmpty && title.hasPrefix($0) } }
    }

    /// A window is the app's when its executable (from the TWI process table or an `exe:` key) is one of
    /// `executables`; when the executable is unknown, when its app key is the published app's (`app:<resource>`) or
    /// names an executable's stem.
    public func matches(executable: String?, appKey: String?) -> Bool {
        if let executable, !executable.isEmpty { return executables.contains(GuardedLogoff.basename(executable)) }
        let key = appKey?.lowercased() ?? ""
        if key == "app:" + resource.lowercased() { return true }
        return executables.contains { exe in
            let stem = exe.split(separator: ".").first.map(String.init) ?? exe
            return !stem.isEmpty && key.contains(stem)
        }
    }

    /// The title contains `titleWord` (any title when there is none).
    public func isDocumentTitle(_ title: String) -> Bool {
        guard let titleWord else { return true }
        return title.lowercased().contains(titleWord)
    }
}

/// `lab/apps.conf` (D110): the one list of lab apps and lab suite tests, read by icactl and `scripts/live-suite.sh
/// --lab`. Lines (`|`-separated, `#` comments, blank lines ignored):
///
///     app|<resource>|<executables, comma-separated>|<title word>[|<first-run dialog title prefixes, comma-separated>]
///     test|<name>|<resource>|<extra environment>|<icactl arguments>
///
/// The suite runs `icactl <arguments> "<resource>"` for each test, in order.
public struct LabConfig: Equatable, Sendable {
    public struct Test: Equatable, Sendable {
        public var name: String
        public var resource: String
        public var environment: String
        public var arguments: String
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case badLine(Int, String)
        case unknownResource(Int, String)
        case duplicate(Int, String)

        public var description: String {
            switch self {
            case .badLine(let n, let why): "line \(n): \(why)"
            case .unknownResource(let n, let name): "line \(n): the test's resource \"\(name)\" has no app line"
            case .duplicate(let n, let name): "line \(n): \"\(name)\" is listed twice"
            }
        }
    }

    public var apps: [TestApp] = []
    public var tests: [Test] = []

    public init(apps: [TestApp] = [], tests: [Test] = []) {
        self.apps = apps
        self.tests = tests
    }

    /// The default file: `<package root>/lab/apps.conf`, or `ICA_LAB_APPS`.
    public static func defaultPath(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["ICA_LAB_APPS"] ?? root.appendingPathComponent("lab/apps.conf").path
    }

    public static func load(path: String) throws -> LabConfig {
        try parse(String(contentsOfFile: path, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> LabConfig {
        var config = LabConfig()
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let n = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            switch fields[0] {
            case "app":
                guard fields.count == 4 || fields.count == 5, !fields[1].isEmpty else {
                    throw ParseError.badLine(n, "expected app|<resource>|<executables>|<title word>[|<first-run dialogs>]")
                }
                guard config.app(fields[1]) == nil else { throw ParseError.duplicate(n, fields[1]) }
                let exes = fields[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let dialogs = fields.count == 5
                    ? fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                config.apps.append(TestApp(resource: fields[1], executables: exes, titleWord: fields[3], firstRunDialogs: dialogs))
            case "test":
                guard fields.count == 5, !fields[1].isEmpty, !fields[4].isEmpty else {
                    throw ParseError.badLine(n, "expected test|<name>|<resource>|<environment>|<icactl arguments>")
                }
                guard config.app(fields[2]) != nil else { throw ParseError.unknownResource(n, fields[2]) }
                guard !config.tests.contains(where: { $0.name == fields[1] }) else { throw ParseError.duplicate(n, fields[1]) }
                config.tests.append(Test(name: fields[1], resource: fields[2], environment: fields[3], arguments: fields[4]))
            default:
                throw ParseError.badLine(n, "unknown record \"\(fields[0])\" (app or test)")
            }
        }
        return config
    }

    /// The app with this resource name (exact, then case-insensitive).
    public func app(_ resource: String) -> TestApp? {
        apps.first { $0.resource == resource } ?? apps.first { $0.resource.caseInsensitiveCompare(resource) == .orderedSame }
    }

    /// Every app's resource name, for `ICA_TEST_RESOURCES`.
    public var resourceNames: [String] { apps.map(\.resource) }
}
