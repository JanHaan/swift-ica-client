import Foundation
import Testing
@testable import AppHostKit

/// docs/99 §12.15, live bug of the phase-3 check: an Explorer window in a "Calc App" session got the launched
/// resource's name and icon, so two Dock tiles read "Calc App".
@Suite struct AppNamingTests {
    @Test func explorerInACalcSessionIsNotNamedAfterTheLaunch() {
        let names = AppNaming.candidates(key: "aumid:Microsoft.Windows.Explorer", publishedName: nil, sessionResource: nil,
                                         rememberedResource: nil, twiName: "Microsoft.Windows.Explorer", launchResource: "Calc App")
        #expect(names == ["Explorer", "Microsoft.Windows.Explorer"])
        #expect(!names.contains("Calc App"))
    }

    @Test func precedence() {
        let all = AppNaming.candidates(key: "app:Calc App", publishedName: "Calc App", sessionResource: "Other",
                                       rememberedResource: "Remembered", twiName: "calc.exe", launchResource: "Calc App")
        #expect(all == ["Calc App", "Other", "Remembered", "calc"])   // "calc.exe" is the same store name
        // The session's mapping before a remembered one, both before the TWI name.
        let mapped = AppNaming.candidates(key: "aumid:Microsoft.Windows.Explorer", publishedName: nil, sessionResource: "Files App",
                                          rememberedResource: "Old", twiName: "Microsoft.Windows.Explorer", launchResource: "Calc App")
        #expect(mapped.first == "Files App" && mapped[1] == "Old")
        let remembered = AppNaming.candidates(key: "aumid:Microsoft.Windows.Explorer", publishedName: nil, sessionResource: nil,
                                              rememberedResource: "Files App", twiName: "Microsoft.Windows.Explorer", launchResource: nil)
        #expect(remembered.first == "Files App")
        // The launch resource counts only for its own app key.
        #expect(AppNaming.candidates(key: "app:Calc App", publishedName: nil, sessionResource: nil, rememberedResource: nil,
                                     twiName: nil, launchResource: "calc  app") == ["calc  app"])
        #expect(AppNaming.isOwnApp(key: "app:Calc App", resource: "Calc App"))
        #expect(!AppNaming.isOwnApp(key: "exe:C:\\Windows\\explorer.exe", resource: "Calc App"))
        #expect(!AppNaming.isOwnApp(key: "app:", resource: ""))
    }

    @Test func readableTWINames() {
        #expect(AppNaming.readable("Microsoft.Windows.Explorer") == "Explorer")
        #expect(AppNaming.readable("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App") == "WindowsCalculator")
        #expect(AppNaming.readable("Microsoft.Office.OUTLOOK.EXE.15") == "OUTLOOK")
        #expect(AppNaming.readable("C:\\Windows\\System32\\notepad.exe") == "notepad")
        #expect(AppNaming.readable("Microsoft Outlook") == "Microsoft Outlook")
        #expect(AppNaming.keyName("aumid:Microsoft.Windows.Explorer") == "Microsoft.Windows.Explorer")
        #expect(AppNaming.keyName("app:Calc App") == "Calc App")
        #expect(AppNaming.keyName("session") == nil && AppNaming.keyName("app:") == nil)
    }

    @Test func twoAppsNeverShareADockName() {
        #expect(AppNaming.unique("Calc App", taken: []) == "Calc App")
        #expect(AppNaming.unique("Calc App", taken: ["calc app"]) == "Calc App (2)")
        #expect(AppNaming.unique("Calc App", taken: ["Calc App", "Calc App (2)"]) == "Calc App (3)")
        // Distinct keys also get distinct bundle ids and folders whatever their names.
        let a = HelperLabel(key: "aumid:Microsoft.Windows.Explorer", name: "Calc App")
        let b = HelperLabel(key: "app:Calc App", name: "Calc App")
        #expect(HelperBundle.bundleIdentifier(for: a) != HelperBundle.bundleIdentifier(for: b))
        #expect(HelperBundle.relativePath(for: a) != HelperBundle.relativePath(for: b))
    }
}

@Suite struct AppResourceMapTests {
    let store = AppResourceMap.storeID(URL(string: "https://store.example.com/Citrix/Store/")!)
    let other = AppResourceMap.storeID(URL(string: "https://other.example.com/Citrix/Store/")!)

    @Test func remembersPerStoreAndOneKeyPerResource() {
        var map = AppResourceMap()
        let c1 = map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Files App", executable: nil)
        #expect(c1)
        let c2 = map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Files App", executable: nil)
        #expect(!c2)
        #expect(map.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == "Files App")
        #expect(map.resource(store: other, key: "aumid:Microsoft.Windows.Explorer") == nil)
        // D172: a launch mapping only adds. Another key for the same resource is not recorded while the old one stands.
        let c3 = map.remember(store: store, key: "exe:C:\\Windows\\explorer.exe", resource: "files app", executable: nil)
        #expect(!c3)
        #expect(map.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == "Files App")
        #expect(map.resource(store: store, key: "exe:C:\\Windows\\explorer.exe") == nil)
        // Same key, same resource: its executable may be filled in.
        let c4 = map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "files app", executable: "explorer.exe")
        #expect(c4)
    }

    /// The 0.10.0 bug: a wrong guess (Explorer is "Text App") must not replace the remembered "Files App"; once the
    /// real app publishes its name, a wrong entry goes and the right one can be learnt.
    @Test func aGuessNeverReplacesARememberedMapping() {
        var map = AppResourceMap()
        let explorer = "aumid:Microsoft.Windows.Explorer"
        map.remember(store: store, key: explorer, resource: "Files App", executable: "explorer.exe")
        let changed = map.remember(store: store, key: explorer, resource: "Text App", executable: "explorer.exe")
        #expect(!changed)
        #expect(map.resource(store: store, key: explorer) == "Files App")
        // A wrong entry from 0.10.0 (Explorer → Text App) heals when Text App's own app names itself.
        var old = AppResourceMap()
        old.remember(store: store, key: explorer, resource: "Text App", executable: "explorer.exe")
        let refused = old.remember(store: store, key: explorer, resource: "Files App", executable: "explorer.exe")
        #expect(!refused)
        old.confirm(store: store, key: "app:Text App", publishedName: "Text App")
        let learnt = old.remember(store: store, key: explorer, resource: "Files App", executable: "explorer.exe")
        #expect(learnt)
        #expect(old.resource(store: store, key: explorer) == "Files App")
    }

    /// A wrong mapping (Explorer → Calc App) goes as soon as the real app names itself.
    @Test func thePublishedAppConfirmsItself() {
        var map = AppResourceMap()
        map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Calc App", executable: nil)
        map.remember(store: store, key: "exe:notepad.exe", resource: "Text App", executable: nil)
        let c3 = map.confirm(store: store, key: "app:Calc App", publishedName: "Calc App")
        #expect(c3)
        #expect(map.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == nil)
        #expect(map.resource(store: store, key: "exe:notepad.exe") == "Text App")
        let c4 = map.confirm(store: store, key: "app:Calc App", publishedName: "Calc App")
        #expect(!c4)
    }

    @Test func persistsWithMode0600AndHashedKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appnaming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app-resources.json")
        var map = AppResourceMap()
        map.remember(store: store, key: "aumid:Microsoft.Windows.Explorer", resource: "Files App", executable: nil)
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
/// "Files App" was queued and was taken for it.
@Suite struct LaunchMappingTests {
    let cmd = "exe:%systemroot%\\system32\\cmd.exe"

    @Test func logonConsoleIsNeverTheLaunchedResource() {
        let exe = AppNaming.executableName(key: cmd, executablePath: nil)
        #expect(exe == "cmd.exe" && AppNaming.isSystemProcess(exe))
        #expect(!AppNaming.mayBeLaunchedApp(executable: exe, publishedName: nil, resource: "Files App", hint: nil, launchStarted: true))
        for name in ["logonui.exe", "conhost.exe", "USERINIT.EXE", "ctfmon.exe"] { #expect(AppNaming.isSystemProcess(name)) }
        // File Explorer and control-panel apps (rundll32) are published apps.
        #expect(!AppNaming.isSystemProcess("explorer.exe") && !AppNaming.isSystemProcess("rundll32.exe") && !AppNaming.isSystemProcess(nil))
    }

    @Test func onlyAfterTheLaunchStarted() {
        #expect(!AppNaming.mayBeLaunchedApp(executable: nil, publishedName: nil, resource: "Files App", hint: nil, launchStarted: false))
        #expect(AppNaming.mayBeLaunchedApp(executable: nil, publishedName: nil, resource: "Files App", hint: nil, launchStarted: true))
    }

    @Test func publishedNameAndExecutableHintDecide() {
        #expect(!AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "Calc App", resource: "Files App", hint: nil, launchStarted: true))
        #expect(AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "files app", resource: "Files App", hint: nil, launchStarted: true))
        #expect(AppNaming.launchHint(initialProgram: "#Files App") == nil)
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
        let refused = map.remember(store: store, key: cmd, resource: "Files App", executable: "cmd.exe")
        #expect(!refused && map.resource(store: store, key: cmd) == nil)
        // An entry of a hand-edited (or older) file pointing at cmd.exe goes at load.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appmap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app-resources.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = AppResourceMap.keyID(cmd), ok = AppResourceMap.keyID("aumid:Microsoft.Windows.Explorer")
        let json = """
        {"stores":{"\(store)":{"\(id)":{"resource":"Files App","executable":"cmd.exe"},"\(ok)":{"resource":"Files App","executable":"explorer.exe"}}}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = AppResourceMap.load(from: url)
        #expect(loaded.resource(store: store, key: cmd) == nil)
        #expect(loaded.resource(store: store, key: "aumid:Microsoft.Windows.Explorer") == "Files App")
        // The first build's string-valued format is not read at all.
        try Data(#"{"stores":{"\#(store)":{"\#(id)":"Files App"}}}"#.utf8).write(to: url)
        #expect(AppResourceMap.load(from: url) == AppResourceMap())
    }
}

/// Live recheck 2026-11-13 (dock-p3c): a fresh logon for "Files App" (a new connection, no shared launch):
/// the File Explorer window after the logon phase is that resource.
@Suite struct OwnLaunchTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    /// Feeds TWI app additions (seconds after t0) to the own launch, as SessionController does; logon ends at
    /// `logonEnd`, the host's seamless (re)activations come at `enumerations`.
    func run(_ resource: String, logonEnd: TimeInterval, hint: String? = nil, alias: String? = nil, enumerations: [TimeInterval] = [],
             remembered: [String: String] = [:],
             _ apps: [(at: TimeInterval, key: String, exe: String?, published: String?)]) -> [String: String] {
        var naming = LaunchNaming(own: AwaitedLaunch(resource: resource, hint: hint, alias: alias, ownLaunch: true))
        var mapped: [String: String] = [:]
        var present: Set<String> = []
        enum Event { case logon, enumeration, app(key: String, exe: String?, published: String?) }
        var events: [(at: TimeInterval, order: Int, event: Event)] = [(logonEnd, 0, .logon)]
        events += enumerations.map { ($0, 1, .enumeration) }
        events += apps.map { ($0.at, 2, .app(key: $0.key, exe: $0.exe, published: $0.published)) }
        for (at, _, event) in events.sorted(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            let now = t0.addingTimeInterval(at)
            switch event {
            case .logon: naming.logonPhaseEnded(at: now)
            case .enumeration: naming.enumerated(at: now)
            case .app(let key, let exe, let published):
                present.insert(key)
                guard mapped[key] == nil else { continue }
                if case .taken(let entry) = naming.appAdded(key: key, executable: exe, publishedName: published,
                                                            remembered: remembered.filter { present.contains($0.key) }, at: now) {
                    mapped[key] = entry.resource
                }
            }
        }
        return mapped
    }

    @Test func freshLogonExplorerIsMapped() {
        let explorer = "aumid:Microsoft.Windows.Explorer"
        let mapped = run("Files App", logonEnd: 26.81, [
            (14.21, "exe:%systemroot%\\system32\\logonui.exe", "logonui.exe", nil),
            (27.03, "exe:%systemroot%\\system32\\logonui.exe", "logonui.exe", nil),
            (27.20, "exe:%systemroot%\\system32\\cmd.exe", "cmd.exe", nil),
            (28.63, explorer, "explorer.exe", nil),
        ])
        #expect(mapped == [explorer: "Files App"])
    }

    @Test func soundInRundll32IsMapped() {
        let key = "exe:C:\\Windows\\System32\\rundll32.exe"
        let mapped = run("Audio App", logonEnd: 20, [
            (21.0, "exe:%systemroot%\\system32\\cmd.exe", "cmd.exe", nil),
            (23.0, key, AppNaming.executableName(key: key, executablePath: nil), nil),
        ])
        #expect(mapped == [key: "Audio App"])
    }

    /// The first live bug: a reconnect into a session whose Explorer came right after the host init (an app that
    /// ran before) must not become "Calc App"; Rechner names itself.
    @Test func reannouncedAppsAfterAReconnectAreNotTheLaunch() {
        let mapped = run("Calc App", logonEnd: 34.19, [
            (34.24, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil),
            (37.82, "app:Calc App", nil, "Calc App"),
        ])
        #expect(mapped == ["app:Calc App": "Calc App"])
    }

    @Test func nothingBeforeTheLogonPhaseEnds() {
        #expect(run("Files App", logonEnd: 30, [(28.0, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil)]).isEmpty)
        // Another published app is never the launch; the entry waits for the real one.
        let mapped = run("Files App", logonEnd: 10, [
            (11.0, "app:Calc App", nil, "Calc App"),
            (12.0, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil),
        ])
        #expect(mapped == ["aumid:Microsoft.Windows.Explorer": "Files App"])
    }

    /// Live: the store showed "Browser App", the host named the app by its farm-internal name; `InitialProgram`
    /// carries that internal name as `#<name>`.
    @Test func internalPublishedNameFromInitialProgramMatchesTheLaunch() {
        #expect(AppNaming.launchAlias(initialProgram: "#Browser App_1") == "Browser App_1")
        #expect(AppNaming.launchAlias(initialProgram: " # ") == nil)
        #expect(AppNaming.launchAlias(initialProgram: "C:\\Windows\\explorer.exe") == nil)
        #expect(AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "Browser App_1", resource: "Browser App", hint: nil,
                                           alias: "Browser App_1", launchStarted: true))
        #expect(!AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "Other App", resource: "Browser App", hint: nil,
                                            alias: "Browser App_1", launchStarted: true))
        #expect(!AppNaming.mayBeLaunchedApp(executable: nil, publishedName: "Browser App_1", resource: "Browser App", hint: nil,
                                            alias: "Browser App_1", launchStarted: false))
        var naming = LaunchNaming(own: AwaitedLaunch(resource: "Browser App", alias: "Browser App_1", ownLaunch: true))
        naming.logonPhaseEnded(at: Date(timeIntervalSince1970: 0))
        let outcome = naming.appAdded(key: "app:Browser App_1", executable: nil, publishedName: "Browser App_1", remembered: [:],
                                      at: Date(timeIntervalSince1970: 2))
        #expect(outcome == .taken(AwaitedLaunch(resource: "Browser App", alias: "Browser App_1",
                                                startedAt: Date(timeIntervalSince1970: 0), ownLaunch: true)))
        // On a reconnect it is still taken, re-announced at once: a published name is no guess.
        #expect(run("Browser App", logonEnd: 6.77, alias: "Browser App_1", enumerations: [7.84], [
            (7.91, "aumid:Microsoft.Windows.Explorer", "explorer.exe", nil),
            (8.14, "app:Browser App_1", nil, "Browser App_1"),
        ]) == ["app:Browser App_1": "Browser App"])
    }

    // MARK: D172, a reconnect to running apps (0.10.0 known issue)

    let explorer = "aumid:Microsoft.Windows.Explorer"

    /// The bad manual run (manual-20261119-085226): after an ICA Viewer restart, a reconnect through "Text App"; the
    /// logon phase ended at 6.77 s, the host answered PAUSE/RESUME at 7.84 s and re-announced Explorer at 7.91 s,
    /// past the 0.5 s grace. Explorer must not become "Text App"; Text App names itself.
    @Test func reconnectWithExistingWindowsTakesNoGuess() {
        let apps: [(at: TimeInterval, key: String, exe: String?, published: String?)] = [
            (5.94, "exe:%systemroot%\\system32\\logonui.exe", "logonui.exe", nil),
            (7.91, explorer, "explorer.exe", nil),
            (8.14, "app:Draw App", nil, "Draw App"),
            (8.16, "app:Text App", nil, "Text App"),
            (8.18, "app:Paint App", nil, "Paint App"),
            (8.20, explorer, "explorer.exe", nil),        // the window again after the reset
            (30.0, "exe:C:\\Tools\\later.exe", "later.exe", nil),   // a new app later is no guess either
        ]
        #expect(run("Text App", logonEnd: 6.77, enumerations: [7.84], apps) == ["app:Text App": "Text App"])
        // The same when the first re-announced app is not the earliest of the burst (chained within 0.5 s each).
        #expect(run("Text App", logonEnd: 6.77, enumerations: [7.0], [
            (7.3, "app:Draw App", nil, "Draw App"),
            (7.7, explorer, "explorer.exe", nil),
        ]).isEmpty)
        // A plain reconnect (no logon UI): the apps come before the logon phase counts as over (3 s after host init).
        #expect(run("Files App", logonEnd: 3.0, [
            (0.05, "app:Text App", nil, "Text App"),
            (0.07, explorer, "explorer.exe", nil),
            (5.0, "exe:C:\\Tools\\later.exe", "later.exe", nil),
        ]).isEmpty)
        var naming = LaunchNaming(own: AwaitedLaunch(resource: "Text App", ownLaunch: true))
        naming.logonPhaseEnded(at: t0)
        naming.enumerated(at: t0.addingTimeInterval(1.07))
        _ = naming.appAdded(key: explorer, executable: "explorer.exe", publishedName: nil, remembered: [:], at: t0.addingTimeInterval(1.14))
        #expect(naming.reconnected && naming.awaitsOwnLaunch)
    }

    /// A fresh logon, also one the timing rule calls a reconnect pattern (the lab logs on in 1–2 s): the enumeration
    /// after the logon lists no app, so the first real app later is the launch.
    @Test func freshLaunchStillTakesTheFirstRealApp() {
        // Lab, manual run: logon phase end 27.55 s, seamless reactivated 27.64 s, the app at 29.28 s.
        #expect(run("Files App", logonEnd: 27.55, enumerations: [27.64], [
            (26.29, "exe:%systemroot%\\system32\\logonui.exe", "logonui.exe", nil),
            (27.80, "exe:%systemroot%\\system32\\ctfmon.exe", "ctfmon.exe", nil),   // system: no reconnect evidence
            (29.28, explorer, "explorer.exe", nil),
        ]) == [explorer: "Files App"])
        var naming = LaunchNaming(own: AwaitedLaunch(resource: "Files App", ownLaunch: true))
        naming.logonPhaseEnded(at: t0)
        _ = naming.appAdded(key: explorer, executable: "explorer.exe", publishedName: nil, remembered: [:], at: t0.addingTimeInterval(2))
        #expect(!naming.reconnected)
    }

    /// A remembered mapping beats a guess: an app remembered as another resource, or a second app for a resource
    /// whose remembered app is in the session, is not taken; an unremembered or matching one is.
    @Test func rememberedMappingBeatsAGuess() {
        // Fresh logon for "Text App"; Explorer is remembered as "Files App" and comes first.
        #expect(run("Text App", logonEnd: 10, remembered: [explorer: "Files App"], [
            (12.0, explorer, "explorer.exe", nil),
            (13.0, "exe:C:\\Tools\\text.exe", "text.exe", nil),
        ]) == ["exe:C:\\Tools\\text.exe": "Text App"])
        // Remembered as this very resource: taken.
        #expect(run("Files App", logonEnd: 10, remembered: [explorer: "files app"], [(12.0, explorer, "explorer.exe", nil)])
                == [explorer: "Files App"])
        // The resource's remembered app is already here (a second Files App launch): another new app is not it.
        var again = LaunchNaming()
        again.add(AwaitedLaunch(resource: "Files App", known: [explorer]))
        again.sharedLaunchStarted("Files App", at: t0)
        let second = again.appAdded(key: "exe:C:\\Tools\\other.exe", executable: "other.exe", publishedName: nil,
                                    remembered: [explorer: "Files App"], at: t0.addingTimeInterval(1))
        #expect(second == .notTaken(remembered: "Files App"))
        // A shared launch: the same rule, and the outcome names the remembered resource for the log.
        var naming = LaunchNaming()
        naming.add(AwaitedLaunch(resource: "Text App", known: ["app:Draw App"]))
        naming.sharedLaunchStarted("Text App", at: t0)
        let blocked = naming.appAdded(key: explorer, executable: "explorer.exe", publishedName: nil,
                                      remembered: [explorer: "Files App"], at: t0.addingTimeInterval(1))
        #expect(blocked == .notTaken(remembered: "Files App"))
        let taken = naming.appAdded(key: "exe:C:\\Tools\\text.exe", executable: "text.exe", publishedName: nil,
                                    remembered: [explorer: "Files App"], at: t0.addingTimeInterval(2))
        #expect(taken == .taken(AwaitedLaunch(resource: "Text App", known: ["app:Draw App"], startedAt: t0)))
        #expect(naming.pending.isEmpty)
        let unrelated = naming.appAdded(key: "app:Draw App", executable: nil, publishedName: "Draw App", remembered: [:], at: t0)
        #expect(unrelated == .none)
    }
}
