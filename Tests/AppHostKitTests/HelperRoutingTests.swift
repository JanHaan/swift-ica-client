import Foundation
import Testing
@testable import AppHostKit

@Suite struct HelperRoutingTests {
    @Test func onlyAppWindowsWithARealAppKeyGetAHelper() {
        #expect(HelperRouting.helperKey(appKey: "app:Notepad", isAppWindow: true) == "app:Notepad")
        #expect(HelperRouting.helperKey(appKey: "exe:c:\\windows\\notepad.exe", isAppWindow: true) == "exe:c:\\windows\\notepad.exe")
        // Popups and menus stay in the main process in phase 1.
        #expect(HelperRouting.helperKey(appKey: "app:Notepad", isAppWindow: false) == nil)
        // No app behind the window (logon console, orphans): main process.
        #expect(HelperRouting.helperKey(appKey: "session", isAppWindow: true) == nil)
        #expect(HelperRouting.helperKey(appKey: "_NONE_", isAppWindow: true) == nil)
        #expect(HelperRouting.helperKey(appKey: "", isAppWindow: true) == nil)
    }

    @Test func dirtyRectsAreFilteredByCrops() {
        let crops = [WireRect(x: 0, y: 0, width: 100, height: 100), WireRect(x: 500, y: 500, width: 10, height: 10)]
        let dirty = [WireRect(x: 90, y: 90, width: 20, height: 20), WireRect(x: 200, y: 200, width: 50, height: 50),
                     WireRect(x: 505, y: 400, width: 1, height: 101)]
        #expect(HelperRouting.dirtyRects(dirty, crops: crops) == [dirty[0], dirty[2]])
        #expect(HelperRouting.dirtyRects(dirty, crops: []).isEmpty)
        // Touching edges do not intersect.
        #expect(HelperRouting.dirtyRects([WireRect(x: 100, y: 0, width: 5, height: 5)], crops: crops).isEmpty)
    }

    @Test func wireRectRoundsEdges() {
        #expect(HelperRouting.wireRect(CGRect(x: 10, y: 20, width: 300, height: 200)) == WireRect(x: 10, y: 20, width: 300, height: 200))
        // Fractional view sizes × k: edges, not sizes, are rounded, so adjacent crops stay adjacent.
        #expect(HelperRouting.wireRect(CGRect(x: 10.4, y: 20.6, width: 99.4, height: 0.5)) == WireRect(x: 10, y: 21, width: 100, height: 0))
    }

    @Test func handlesAreStableUniqueAndNeverReused() {
        var handles = HelperHandles<String>()
        let a = handles.handle(for: "a"), b = handles.handle(for: "b")
        #expect(a != b && a != 0 && b != 0)
        #expect(handles.handle(for: "a") == a)
        #expect(handles.owner(of: b) == "b")
        #expect(handles.remove("a") == a)
        #expect(handles.owner(of: a) == nil && handles.existing(for: "a") == nil)
        // A window that comes back gets a new handle: late messages about the old one hit nothing.
        let again = handles.handle(for: "a")
        #expect(again != a && again != b)
        #expect(handles.count == 2)
        #expect(handles.remove("zzz") == nil)
    }

    @Test func activationHandover() {
        let host: Int32 = 100, helpers: Set<Int32> = [201, 202]
        // Main process in front (launcher): it yields to the helper, which activates.
        #expect(ActivationHandover.plan(frontmost: host, host: host, helpers: helpers, target: 201)
                == [.hostYields(toPid: 201), .activate(pid: 201)])
        // Another helper in front: it yields first (acknowledged), then the target activates.
        #expect(ActivationHandover.plan(frontmost: 202, host: host, helpers: helpers, target: 201)
                == [.helperYields(fromPid: 202, toPid: 201), .activate(pid: 201)])
        // Back to a window of the main process.
        #expect(ActivationHandover.plan(frontmost: 202, host: host, helpers: helpers, target: host)
                == [.helperYields(fromPid: 202, toPid: host), .activate(pid: host)])
        // Already in front: only make the window key.
        #expect(ActivationHandover.plan(frontmost: 201, host: host, helpers: helpers, target: 201) == [.activate(pid: 201)])
        // Another app is in front, or nothing is known: never steal activation.
        #expect(ActivationHandover.plan(frontmost: 999, host: host, helpers: helpers, target: 201) == nil)
        #expect(ActivationHandover.plan(frontmost: nil, host: host, helpers: helpers, target: 201) == nil)
    }

    @Test func spikeSpecsDecodeWithoutTheNewFields() throws {
        let json = #"{"id":7,"title":"Alpha","rect":{"x":1,"y":2,"width":3,"height":4}}"#
        let spec = try WireCoding.decode(HelperWindowSpec.self, from: Data(json.utf8))
        #expect(spec == HelperWindowSpec(id: 7, title: "Alpha", rect: WireRect(x: 1, y: 2, width: 3, height: 4)))
        #expect(spec.frame == nil && spec.seamless == nil && spec.scale == nil)
    }

    @Test func onlyPointerMovesAndStatsMayDrop() {
        func mouse(_ kind: MouseKind) -> HelperMessage {
            .mouse(windowId: 1, kind: kind, button: 0, x: 0, y: 0, screenX: 0, screenY: 0, clickCount: 0, modifiers: 0, sentNs: 0)
        }
        #expect(mouse(.moved).mayDrop && mouse(.dragged).mayDrop)
        #expect(!mouse(.down).mayDrop && !mouse(.up).mayDrop)
        #expect(HelperMessage.frameStats(count: 1, meanUs: 1, p95Us: 1, maxUs: 1).mayDrop)
        #expect(!HelperMessage.key(windowId: 1, phase: .up, keyCode: 0, characters: "", charactersIgnoringModifiers: "",
                                   modifiers: 0, isRepeat: false, sentNs: 0).mayDrop)
        #expect(!HelperMessage.appQuit.mayDrop && !HelperMessage.focus(windowId: 1).mayDrop)
    }

    @Test func largeSpecFitsTheChannel() throws {
        let spec = HelperWindowSpec(id: .max, title: String(repeating: "Ü", count: 2000), rect: WireRect(x: -1, y: -1, width: 5120, height: 4096),
                                    frame: WirePointRect(x: -2560.25, y: 1439.75, width: 2560, height: 1440), scale: 2, seamless: true,
                                    minimized: true, topmost: true, dim: 0.2)
        #expect(try WireCoding.encode(HostMessage.windowChanged(spec)).count < MachChannel.maxPayload)
    }
}

@Suite struct CodeIdentityTests {
    @Test func requirementOnlyFromHex() {
        #expect(CodeIdentity.requirement(cdhash: "00AAff12") == #"cdhash H"00aaff12""#)
        #expect(CodeIdentity.requirement(cdhash: "") == nil)
        #expect(CodeIdentity.requirement(cdhash: #"00" or anchor apple"#) == nil)
        #expect(CodeIdentity.requirement(cdhash: String(repeating: "a", count: 129)) == nil)
    }

    @Test func aProcessWithOtherCodeIsRefused() throws {
        let own = try #require(CodeIdentity.ownAuditToken())
        #expect(pid_t(bitPattern: own.val.5) == getpid())
        #expect(CodeIdentity.check(auditToken: own, cdhash: String(repeating: "0", count: 40)) != errSecSuccess)
        #expect(CodeIdentity.check(auditToken: own, cdhash: "not hex") == errSecParam)
    }

    @Test func unsignedPathHasNoCdhash() {
        #expect(CodeIdentity.cdhash(bundle: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).app")) == nil)
    }
}
