import Foundation
import Testing
@testable import AppHostKit

@Suite struct HelperBundleTests {
    private let label = HelperLabel(key: "microsoft outlook", name: "Microsoft Outlook")
    private let template: [String: Any] = [
        "CFBundleIdentifier": "local.alttab.ICAViewer.helper",
        "CFBundleName": "ICAViewerHelper",
        "CFBundleExecutable": "ICAViewerHelper",
        "CFBundleShortVersionString": "0.1",
        "CFBundleIconName": "AppIcon",
        "NSPrincipalClass": "NSApplication",
    ]

    @Test func keyHashIsStableHexAndKeyed() {
        let h = HelperBundle.keyHash("microsoft outlook")
        #expect(h.count == 16 && h.allSatisfy(\.isHexDigit))
        #expect(h == HelperBundle.keyHash("microsoft outlook"))
        #expect(h != HelperBundle.keyHash("microsoft word"))
        #expect(HelperBundle.bundleIdentifier(for: label) == "local.alttab.ICAViewer.app." + h)
    }

    @Test func bundleIdentifierDependsOnKeyNotName() {
        let renamed = HelperLabel(key: label.key, name: "Mail (Two)")
        #expect(HelperBundle.bundleIdentifier(for: renamed) == HelperBundle.bundleIdentifier(for: label))
    }

    @Test func fileNameIsSafe() {
        #expect(HelperBundle.fileName(for: "Microsoft Outlook") == "Microsoft Outlook.app")
        #expect(HelperBundle.fileName(for: "AC/DC: Live") == "AC-DC- Live.app")
        #expect(HelperBundle.fileName(for: "..hidden") == "hidden.app")
        #expect(HelperBundle.fileName(for: "  \n ") == "App.app")
        #expect(HelperBundle.fileName(for: "a\u{7}b") == "a b.app")
        #expect(HelperBundle.fileName(for: String(repeating: "x", count: 200)).count == 84)
        #expect(HelperBundle.relativePath(for: label) == HelperBundle.keyHash(label.key) + "/Microsoft Outlook.app")
    }

    @Test func relabelReplacesIdentityAndKeepsTheRest() {
        let info = HelperBundle.relabel(template, label: label, templateHash: "t1", iconHash: "i1")
        #expect(info["CFBundleIdentifier"] as? String == HelperBundle.bundleIdentifier(for: label))
        #expect(info["CFBundleName"] as? String == "Microsoft Outlook")
        #expect(info["CFBundleDisplayName"] as? String == "Microsoft Outlook")
        #expect(info["LSMultipleInstancesProhibited"] as? Bool == true)
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
        #expect(info["CFBundleIconName"] == nil)
        #expect(info[HelperBundle.iconHashKey] as? String == "i1")
        #expect(info[HelperBundle.templateHashKey] as? String == "t1")
        #expect(info[HelperBundle.keyHashKey] as? String == HelperBundle.keyHash(label.key))
        #expect(info["CFBundleExecutable"] as? String == "ICAViewerHelper")
        #expect(info["CFBundleShortVersionString"] as? String == "0.1")
        #expect(info["NSPrincipalClass"] as? String == "NSApplication")
    }

    @Test func relabelWithoutIconDropsIconKeys() {
        var withIcon = template
        withIcon["CFBundleIconFile"] = "Old"
        withIcon[HelperBundle.iconHashKey] = "stale"
        let info = HelperBundle.relabel(withIcon, label: label, templateHash: "t", iconHash: nil)
        #expect(info["CFBundleIconFile"] == nil)
        #expect(info[HelperBundle.iconHashKey] == nil)
    }

    @Test func relabelledPlistSerializes() throws {
        let info = HelperBundle.relabel(template, label: label, templateHash: "t", iconHash: "i")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(back["CFBundleName"] as? String == "Microsoft Outlook")
    }

    @Test func isCurrentComparesTemplateNameKeyAndIcon() {
        let info = HelperBundle.relabel(template, label: label, templateHash: "t", iconHash: "i")
        #expect(HelperBundle.isCurrent(existing: info, label: label, templateHash: "t", iconHash: "i"))
        #expect(!HelperBundle.isCurrent(existing: nil, label: label, templateHash: "t", iconHash: "i"))
        #expect(!HelperBundle.isCurrent(existing: info, label: label, templateHash: "t2", iconHash: "i"))
        #expect(!HelperBundle.isCurrent(existing: info, label: label, templateHash: "t", iconHash: "i2"))
        #expect(!HelperBundle.isCurrent(existing: info, label: label, templateHash: "t", iconHash: nil))
        #expect(!HelperBundle.isCurrent(existing: info, label: HelperLabel(key: label.key, name: "Outlook"), templateHash: "t", iconHash: "i"))
        #expect(!HelperBundle.isCurrent(existing: info, label: HelperLabel(key: "other", name: label.name), templateHash: "t", iconHash: "i"))
    }
}

@Suite struct HelperLaunchTests {
    @Test func argumentsRoundTrip() {
        let launch = HelperLaunch(broker: HelperLaunch.brokerName(hostPid: 42), token: HelperLaunch.makeToken(), hostPid: 42, headless: true)
        #expect(HelperLaunch.parse(["/path/exe"] + launch.arguments, environment: launch.environment) == launch)
        // The token never goes into argv (ps shows it to every user), only into the environment.
        #expect(!launch.arguments.contains(launch.token))
        #expect(HelperLaunch.parse(["/path/exe"] + launch.arguments) == nil)
        #expect(launch.environment == [HelperLaunch.tokenVariable: launch.token])
        // The environment wins over a --token argument.
        #expect(HelperLaunch.parse(["exe", "--broker", "b", "--token", "argv", "--host-pid", "7"],
                                   environment: [HelperLaunch.tokenVariable: "env"])?.token == "env")
        #expect(launch.token.count == 32)
        #expect(launch.broker == "local.alttab.ICAViewer.broker.42")
    }

    @Test func ignoresForeignArgumentsAndRejectsIncomplete() {
        let parsed = HelperLaunch.parse(["exe", "-psn_0_12345", "--broker", "b", "-NSDocumentRevisionsDebugMode", "YES", "--token", "t", "--host-pid", "7"])
        #expect(parsed == HelperLaunch(broker: "b", token: "t", hostPid: 7))
        #expect(HelperLaunch.parse(["exe", "--broker", "b", "--token", "t"]) == nil)
        #expect(HelperLaunch.parse(["exe", "--broker", "b", "--token", "t", "--host-pid", "x"]) == nil)
        #expect(HelperLaunch.parse(["exe", "--broker", "b", "--token", "t", "--host-pid"]) == nil)
        #expect(HelperLaunch.parse(["exe", "--broker", "", "--token", "t", "--host-pid", "3"]) == nil)
    }
    @Test func tokensDiffer() { #expect(HelperLaunch.makeToken() != HelperLaunch.makeToken()) }
}

@Suite struct WireTests {
    @Test func messagesRoundTrip() throws {
        let host: [HostMessage] = [
            .hello(appName: "Spike Alpha"), .surface(width: 1600, height: 1000),
            .windowAdded(HelperWindowSpec(id: 3, title: "Beta — Message", rect: WireRect(x: 1, y: 2, width: 3, height: 4))),
            .windowChanged(HelperWindowSpec(id: 4, title: "Editor", rect: WireRect(x: 10, y: 20, width: 800, height: 600),
                                            frame: WirePointRect(x: 5, y: 900, width: 400, height: 300), scale: 2, seamless: true,
                                            minimized: false, topmost: true, dim: 0.2)),
            .windowRemoved(id: 3), .frame(seed: 9, dirty: [WireRect(x: 0, y: 0, width: 10, height: 10)], sentNs: 123),
            .activate(windowId: 1), .yieldActivation(toPid: 77), .probe(x: 1, y: 2, sentNs: 3), .quit,
        ]
        for m in host { #expect(try WireCoding.decode(HostMessage.self, from: WireCoding.encode(m)) == m) }
        let helper: [HelperMessage] = [
            .checkIn(token: "t", pid: 5),
            .key(windowId: 1, phase: .down, keyCode: 0, characters: "ä", charactersIgnoringModifiers: "a", modifiers: 0x100000,
                 isRepeat: false, sentNs: 1),
            .key(windowId: 1, phase: .flags, keyCode: 56, characters: "", charactersIgnoringModifiers: "", modifiers: 0x20102,
                 isRepeat: false, sentNs: 1),
            .mouse(windowId: 2, kind: .down, button: 0, x: 10.5, y: 20, screenX: 300.5, screenY: -20, clickCount: 2,
                   modifiers: 0x40000, sentNs: 2),
            .scroll(windowId: 2, dx: 0, dy: -3, precise: true, x: 1, y: 2, screenX: 3, screenY: 4, sentNs: 3),
            .focus(windowId: 2), .resignedKey(windowId: 2), .appActive(true), .close(windowId: 2),
            .minimized(windowId: 2, true), .moved(windowId: 2, frame: WirePointRect(x: -1440, y: 25.5, width: 400, height: 300)),
            .frameStats(count: 120, meanUs: 80, p95Us: 300, maxUs: 900), .probeResult(pixel: 0xFF00_00FF, seed: 4, sentNs: 5),
            .yielded(toPid: 9, wasActive: true), .activation("ok"), .appQuit,
        ]
        for m in helper { #expect(try WireCoding.decode(HelperMessage.self, from: WireCoding.encode(m)) == m) }
    }

    @Test func frameMessageFitsTheChannel() throws {
        let rects = (0..<64).map { WireRect(x: $0 * 10, y: $0, width: 1000, height: 1000) }
        let data = try WireCoding.encode(HostMessage.frame(seed: .max, dirty: rects, sentNs: .max))
        #expect(data.count < MachChannel.maxPayload)
    }

    @Test func rectIntersection() {
        let a = WireRect(x: 0, y: 0, width: 10, height: 10)
        #expect(a.intersects(WireRect(x: 9, y: 9, width: 5, height: 5)))
        #expect(!a.intersects(WireRect(x: 10, y: 0, width: 5, height: 5)))   // touching edges only
        #expect(!a.intersects(WireRect(x: 0, y: 10, width: 5, height: 5)))
    }
}
