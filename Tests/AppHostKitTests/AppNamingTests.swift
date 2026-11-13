import Foundation
import Testing
@testable import AppHostKit

/// docs/99 §12.15, live bug of the phase-3 check: an Explorer window in a "Calculator" session got the launched
/// resource's name and icon, so two Dock tiles read "Calculator".
@Suite struct AppNamingTests {
    @Test func explorerInARechnerSessionIsNotNamedAfterTheLaunch() {
        let names = AppNaming.candidates(key: "aumid:Microsoft.Windows.Explorer", publishedName: nil, sessionResource: nil,
                                         rememberedResource: nil, twiName: "Microsoft.Windows.Explorer", launchResource: "Calculator")
        #expect(names == ["Explorer", "Microsoft.Windows.Explorer"])
        #expect(!names.contains("Calculator"))
    }

    @Test func precedence() {
        let all = AppNaming.candidates(key: "app:Calculator", publishedName: "Calculator", sessionResource: "Other",
                                       rememberedResource: "Remembered", twiName: "calc.exe", launchResource: "Calculator")
        #expect(all == ["Calculator", "Other", "Remembered", "calc"])   // "calc.exe" is the same store name
        // The session's mapping before a remembered one, both before the TWI name.
        let mapped = AppNaming.candidates(key: "aumid:Microsoft.Windows.Explorer", publishedName: nil, sessionResource: "Explorer Citrix ABC",
                                          rememberedResource: "Old", twiName: "Microsoft.Windows.Explorer", launchResource: "Calculator")
        #expect(mapped.first == "Explorer Citrix ABC" && mapped[1] == "Old")
        let remembered = AppNaming.candidates(key: "aumid:Microsoft.Windows.Explorer", publishedName: nil, sessionResource: nil,
                                              rememberedResource: "Explorer Citrix ABC", twiName: "Microsoft.Windows.Explorer", launchResource: nil)
        #expect(remembered.first == "Explorer Citrix ABC")
        // The launch resource counts only for its own app key.
        #expect(AppNaming.candidates(key: "app:Calculator", publishedName: nil, sessionResource: nil, rememberedResource: nil,
                                     twiName: nil, launchResource: "rechner  ekm") == ["rechner  ekm"])
        #expect(AppNaming.isOwnApp(key: "app:Calculator", resource: "Calculator"))
        #expect(!AppNaming.isOwnApp(key: "exe:C:\\Windows\\explorer.exe", resource: "Calculator"))
        #expect(!AppNaming.isOwnApp(key: "app:", resource: ""))
    }

    @Test func readableTWINames() {
        #expect(AppNaming.readable("Microsoft.Windows.Explorer") == "Explorer")
        #expect(AppNaming.readable("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App") == "WindowsCalculator")
        #expect(AppNaming.readable("Microsoft.Office.OUTLOOK.EXE.15") == "OUTLOOK")
        #expect(AppNaming.readable("C:\\Windows\\System32\\notepad.exe") == "notepad")
        #expect(AppNaming.readable("Microsoft Outlook") == "Microsoft Outlook")
        #expect(AppNaming.keyName("aumid:Microsoft.Windows.Explorer") == "Microsoft.Windows.Explorer")
        #expect(AppNaming.keyName("app:Calculator") == "Calculator")
        #expect(AppNaming.keyName("session") == nil && AppNaming.keyName("app:") == nil)
    }

    @Test func twoAppsNeverShareADockName() {
        #expect(AppNaming.unique("Calculator", taken: []) == "Calculator")
        #expect(AppNaming.unique("Calculator", taken: ["rechner ekm"]) == "Calculator (2)")
        #expect(AppNaming.unique("Calculator", taken: ["Calculator", "Calculator (2)"]) == "Calculator (3)")
        // Distinct keys also get distinct bundle ids and folders whatever their names.
        let a = HelperLabel(key: "aumid:Microsoft.Windows.Explorer", name: "Calculator")
        let b = HelperLabel(key: "app:Calculator", name: "Calculator")
        #expect(HelperBundle.bundleIdentifier(for: a) != HelperBundle.bundleIdentifier(for: b))
        #expect(HelperBundle.relativePath(for: a) != HelperBundle.relativePath(for: b))
    }
}

@Suite struct AppResourceMapTests {
    let store = AppResourceMap.storeID(URL(string: "https://store.example.com/Citrix/Store/")!)
    let other = AppResourceMap.storeID(URL(string: "https://other.example.com/Citrix/Store/")!)

    @Test func remembersPerStoreAndOneKeyPerResource() {
        var map = AppResourceMap()
        let c1 = map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Explorer Citrix ABC", executable: nil)
        #expect(c1)
        let c2 = map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Explorer Citrix ABC", executable: nil)
        #expect(!c2)
        #expect(map.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == "Explorer Citrix ABC")
        #expect(map.resource(store: other, key: "aumid:Microsoft.Windows.Explorer") == nil)
        // Another key for the same resource replaces the old one.
        map.remember(store: store, key: "exe:C:\\Windows\\explorer.exe", resource: "explorer citrix ekm", executable: nil)
        #expect(map.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == nil)
        #expect(map.resource(store: store, key: "exe:C:\\Windows\\explorer.exe") == "explorer citrix ekm")
    }

    /// A wrong mapping (Explorer → Calculator) goes as soon as the real app names itself.
    @Test func thePublishedAppConfirmsItself() {
        var map = AppResourceMap()
        map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Calculator", executable: nil)
        map.remember(store: store, key: "exe:notepad.exe", resource: "Notepad", executable: nil)
        let c3 = map.confirm(store: store, key: "app:Calculator", publishedName: "Calculator")
        #expect(c3)
        #expect(map.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == nil)
        #expect(map.resource(store: store, key: "exe:notepad.exe") == "Notepad")
        let c4 = map.confirm(store: store, key: "app:Calculator", publishedName: "Calculator")
        #expect(!c4)
    }

    @Test func persistsWithMode0600AndHashedKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appnaming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app-resources.json")
        var map = AppResourceMap()
        map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Explorer Citrix ABC", executable: nil)
        try map.save(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("Microsoft.Windows.Explorer") && !text.contains("store.example.com"))
        #expect(AppResourceMap.load(from: url) == map)
        #expect(AppResourceMap.load(from: dir.appendingPathComponent("missing.json")) == AppResourceMap())
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["app-resources.json"])   // no temp left
    }
}

/// Live check 2026-11-13 (dock-p3b): the logon-script console (cmd.exe) appeared right after a shared launch of
/// "Explorer Citrix ABC" was queued and was taken for it.
@Suite struct LaunchMappingTests {
    let cmd = "exe:%systemroot%\\system32\\cmd.exe"

    @Test func logonConsoleIsNeverTheLaunchedResource() {
        let exe = AppNaming.executableName(key: cmd, executablePath: nil)
        #expect(exe == "cmd.exe" && AppNaming.isSystemProcess(exe))
        #expect(!AppNaming.mayBeLaunchedApp(executable: exe, publishedName: nil, resource: "Explorer Citrix ABC", hint: nil, launchStarted: true))
        for name in ["logonui.exe", "conhost.exe", "USERINIT.EXE", "ctfmon.exe"] { #expect(AppNaming.isSystemProcess(name)) }
        // File Explorer and control-panel apps (rundll32) are published apps.
        #expect(!AppNaming.isSystemProcess("explorer.exe") && !AppNaming.isSystemProcess("rundll32.exe") && !AppNaming.isSystemProcess(nil))
    }

    @Test func onlyAfterTheLaunchStarted() {
        #expect(!AppNaming.mayBeLaunchedApp(executable: nil, publishedName: nil, resource: "Explorer Citrix ABC", hint: nil, launchStarted: false))
        #expect(AppNaming.mayBeLaunchedApp(executable: nil, publishedName: nil, resource: "Explorer Citrix ABC", hint: nil, launchStarted: true))
    }

    @Test func publishedNameAndExecutableHintDecide() {
        #expect(!AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "Calculator", resource: "Explorer Citrix ABC", hint: nil, launchStarted: true))
        #expect(AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "explorer citrix ekm", resource: "Explorer Citrix ABC", hint: nil, launchStarted: true))
        #expect(AppNaming.launchHint(initialProgram: "#Explorer Citrix ABC") == nil)
        let hint = AppNaming.launchHint(initialProgram: "C:\\Windows\\explorer.exe")
        #expect(hint == "explorer.exe")
        #expect(AppNaming.mayBeLaunchedApp(executable: "explorer.exe", publishedName: nil, resource: "X", hint: hint, launchStarted: true))
        #expect(!AppNaming.mayBeLaunchedApp(executable: "notepad.exe", publishedName: nil, resource: "X", hint: hint, launchStarted: true))
        // A resource that really is rundll32 names it: then it may be mapped.
        #expect(AppNaming.mayBeLaunchedApp(executable: "rundll32.exe", publishedName: nil, resource: "X",
                                           hint: AppNaming.launchHint(initialProgram: "rundll32.exe"), launchStarted: true))
    }

    @Test func systemProcessesAreNeverRememberedAndDroppedAtLoad() throws {
        let store = AppResourceMap.storeID(URL(string: "https://store.example.com/")!)
        var map = AppResourceMap()
        let refused = map.remember(store: store, key: cmd, resource: "Explorer Citrix ABC", executable: "cmd.exe")
        #expect(!refused && map.resource(store: store, key: cmd) == nil)
        // An entry of a hand-edited (or older) file pointing at cmd.exe goes at load.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appmap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app-resources.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = AppResourceMap.keyID(cmd), ok = AppResourceMap.keyID("aumid:Microsoft.Windows.Explorer")
        let json = """
        {"stores":{"\(store)":{"\(id)":{"resource":"Explorer Citrix ABC","executable":"cmd.exe"},"\(ok)":{"resource":"Explorer Citrix ABC","executable":"explorer.exe"}}}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = AppResourceMap.load(from: url)
        #expect(loaded.resource(store: store, key: cmd) == nil)
        #expect(loaded.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == "Explorer Citrix ABC")
        // The first build's string-valued format is not read at all.
        try Data(#"{"stores":{"\#(store)":{"\#(id)":"Explorer Citrix ABC"}}}"#.utf8).write(to: url)
        #expect(AppResourceMap.load(from: url) == AppResourceMap())
    }
}

/// Live recheck 2026-11-13 (dock-p3c): a fresh logon for "Explorer Citrix ABC" (a new connection, no shared launch):
/// the File Explorer window after the logon phase is that resource.
@Suite struct OwnLaunchTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    /// Feeds TWI app additions (seconds after t0) to the own launch, as SessionController does; logon ends at `logonEnd`.
    func run(_ resource: String, logonEnd: TimeInterval, hint: String? = nil,
             _ apps: [(at: TimeInterval, key: String, exe: String?, published: String?)]) -> [String: String] {
        var pending = [AwaitedLaunch(resource: resource, hint: hint, ownLaunch: true)]
        var mapped: [String: String] = [:]
        var ended = false
        for app in apps.sorted(by: { $0.at < $1.at }) {
            if !ended, app.at >= logonEnd { pending[0].startedAt = t0.addingTimeInterval(logonEnd); ended = true }
            guard mapped[app.key] == nil,
                  let i = AppNaming.firstMatch(pending, key: app.key, executable: app.exe, publishedName: app.published,
                                               at: t0.addingTimeInterval(app.at)) else { continue }
            mapped[app.key] = pending.remove(at: i).resource
        }
        return mapped
    }

    @Test func freshLogonExplorerIsMapped() {
        let explorer = "aumid:Microsoft.Windows.Explorer"
        let mapped = run("Explorer Citrix ABC", logonEnd: 26.81, [
            (14.21, "exe:%systemroot%\\system32\\logonui.exe", "logonui.exe", nil),
            (27.03, "exe:%systemroot%\\system32\\logonui.exe", "logonui.exe", nil),
            (27.20, "exe:%systemroot%\\system32\\cmd.exe", "cmd.exe", nil),
            (28.63, explorer, "explorer.exe", nil),
        ])
        #expect(mapped == [explorer: "Explorer Citrix ABC"])
    }

    @Test func soundInRundll32IsMapped() {
        let key = "exe:C:\\Windows\\System32\\rundll32.exe"
        let mapped = run("Sound ABC", logonEnd: 20, [
            (21.0, "exe:%systemroot%\\system32\\cmd.exe", "cmd.exe", nil),
            (23.0, key, AppNaming.executableName(key: key, executablePath: nil), nil),
        ])
        #expect(mapped == [key: "Sound ABC"])
    }

    /// The first live bug: a reconnect into a session whose Explorer came right after the host init (an app that
    /// ran before) must not become "Calculator"; Rechner names itself.
    @Test func reannouncedAppsAfterAReconnectAreNotTheLaunch() {
        let mapped = run("Calculator", logonEnd: 34.19, [
            (34.24, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil),
            (37.82, "app:Calculator", nil, "Calculator"),
        ])
        #expect(mapped == ["app:Calculator": "Calculator"])
    }

    @Test func nothingBeforeTheLogonPhaseEnds() {
        #expect(run("Explorer Citrix ABC", logonEnd: 30, [(28.0, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil)]).isEmpty)
        // Another published app is never the launch; the entry waits for the real one.
        let mapped = run("Explorer Citrix ABC", logonEnd: 10, [
            (11.0, "app:Calculator", nil, "Calculator"),
            (12.0, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil),
        ])
        #expect(mapped == ["aumid:Microsoft.Windows.Explorer": "Explorer Citrix ABC"])
    }
}

