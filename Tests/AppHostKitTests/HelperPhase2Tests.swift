import CoreGraphics
import Foundation
import Testing
@testable import AppHostKit

/// docs/99 §12 phase 2: menu bar model, popups, local gestures, pointer shapes.
@Suite struct HelperMenuTests {
    @Test func englishAndGermanMenus() {
        let en = HelperMenu.sections(appName: "Notepad", german: false)
        #expect(en.map(\.role) == [.app, .edit, .window, .ica, .help])
        #expect(en.map(\.title) == ["Notepad", "Edit", "Window", "ICA", "Help"])
        #expect(en[0].items.filter { !$0.isSeparator }.map(\.title)
            == ["About Notepad", "Hide Notepad", "Hide Others", "Show All", "Quit Notepad"])
        #expect(en[3].items.filter { !$0.isSeparator }.map(\.title)
            == ["Open Launcher", "Connection Center", "Settings…", "Report a Problem…", "Disconnect Session…", "Log Off Session…"])
        let de = HelperMenu.sections(appName: "Calculator", german: true)
        #expect(de.map(\.title) == ["Calculator", "Bearbeiten", "Fenster", "ICA", "Hilfe"])
        #expect(de[0].items.first?.title == "Über Calculator")
        #expect(de[0].items.last?.title == "Calculator beenden")
        #expect(de[1].items.filter { !$0.isSeparator }.map(\.title) == ["Widerrufen", "Ausschneiden", "Kopieren", "Einsetzen", "Alles auswählen"])
        #expect(de[3].items.last?.title == "Sitzung abmelden…")
        // Same structure in both languages.
        #expect(en.map { $0.items.map(\.action) } == de.map { $0.items.map(\.action) })
        #expect(en.map { $0.items.map(\.shortcut) } == de.map { $0.items.map(\.shortcut) })
        #expect(HelperMenu.isGerman(["de-DE", "en"]) && !HelperMenu.isGerman(["en-US", "de"]) && !HelperMenu.isGerman([]))
    }

    @Test func editItemsAreTheForwardedShortcuts() {
        let edit = HelperMenu.sections(appName: "A", german: false)[1].items.filter { !$0.isSeparator }
        #expect(edit.map(\.action) == EditCommand.allCases.map { .edit($0) })
        #expect(edit.map { $0.shortcut } == EditCommand.allCases.map { HelperShortcut($0.letter) })
        #expect(EditCommand.allCases.map(\.letter) == ["z", "x", "c", "v", "a"])
    }

    /// The menu takes only these from the remote app (documented in docs/99 §12.22); Settings and the
    /// Connection Center have none, so Ctrl+, and Ctrl+Shift+C still reach it.
    @Test func takenShortcutsAreTheDocumentedOnes() {
        let taken = HelperMenu.takenShortcuts(HelperMenu.sections(appName: "A", german: false))
        #expect(taken.map(\.description) == ["⌘H", "⌥⌘H", "⌘Q", "⌘W", "⌘M", "⌃⌥⌘L"])
        #expect(!taken.contains(HelperShortcut(",")) && !taken.contains(HelperShortcut("c", [.shift, .command])))
        #expect(Set(taken).count == taken.count)
        #expect(HelperMenu.launcherShortcut.description == "⌃⌥⌘L")
        #expect(HelperMenu.readmeURL.absoluteString.hasPrefix("https://github.com/"))
    }
}

@Suite struct HelperPhase2WireTests {
    @Test func newMessagesRoundTrip() throws {
        let bands = HelperHitBands(resizeEdge: 4, caption: .init(top: 4, bottom: 33, left: 27, right: 142))
        let spec = HelperWindowSpec(id: 5, title: "", rect: WireRect(x: 1, y: 2, width: 3, height: 4), seamless: true,
                                    popup: true, menu: true, resizable: false, zoomable: true, bands: bands)
        let host: [HostMessage] = [
            .windowAdded(spec), .gestureDone(windowId: 5), .cursor(.hidden),
            .cursor(HelperCursor(png: Data([0x89, 0x50]), pixelWidth: 64, pixelHeight: 64, hotX: 10, hotY: 2.5)),
        ]
        for m in host { #expect(try WireCoding.decode(HostMessage.self, from: WireCoding.encode(m)) == m) }
        let helper: [HelperMessage] = [
            .gestureEnded(windowId: 2, frame: WirePointRect(x: 10, y: 20, width: 300, height: 200)),
            .edit(windowId: 2, .paste), .zoom(windowId: 2), .command(.showLauncher), .command(.logoff),
        ]
        for m in helper {
            #expect(try WireCoding.decode(HelperMessage.self, from: WireCoding.encode(m)) == m)
            #expect(!m.mayDrop)
        }
    }

    @Test func phase1SpecsDecodeWithoutPhase2Fields() throws {
        let json = #"{"id":7,"title":"Alpha","rect":{"x":1,"y":2,"width":3,"height":4},"seamless":true,"scale":2}"#
        let spec = try WireCoding.decode(HelperWindowSpec.self, from: Data(json.utf8))
        #expect(spec.popup == nil && spec.bands == nil && spec.resizable == nil && spec.zoomable == nil && spec.menu == nil)
    }

    @Test func popupsGoToARunningHelperOnly() {
        #expect(HelperRouting.popupHelperKey(appKey: "app:Notepad", helperRunning: true) == "app:Notepad")
        #expect(HelperRouting.popupHelperKey(appKey: "app:Notepad", helperRunning: false) == nil)
        #expect(HelperRouting.popupHelperKey(appKey: "session", helperRunning: true) == nil)
        #expect(HelperRouting.popupHelperKey(appKey: "_NONE_", helperRunning: true) == nil)
    }

    @Test func largeCursorStillFits() throws {
        // A 128 px shape compresses far below this; the host checks the encoded size before sending.
        let cursor = HelperCursor(png: Data(repeating: 0xAB, count: 20_000), pixelWidth: 128, pixelHeight: 128, hotX: 0, hotY: 0)
        #expect(try WireCoding.encode(HostMessage.cursor(cursor)).count < MachChannel.maxPayload)
    }
}

@Suite struct HelperGestureTests {
    @Test func hitBandsInViewPoints() {
        let bands = HelperHitBands(resizeEdge: 4, caption: .init(top: 4, bottom: 33, left: 27, right: 142))
        let size = CGSize(width: 400, height: 300)
        #expect(bands.isResizeEdge(CGPoint(x: 2, y: 100), size: size))
        #expect(bands.isResizeEdge(CGPoint(x: 397, y: 100), size: size))
        #expect(bands.isResizeEdge(CGPoint(x: 200, y: 298), size: size))
        #expect(!bands.isResizeEdge(CGPoint(x: 200, y: 100), size: size))
        #expect(bands.isCaption(CGPoint(x: 27, y: 4), size: size))
        #expect(bands.isCaption(CGPoint(x: 257.9, y: 32.9), size: size))
        #expect(!bands.isCaption(CGPoint(x: 258, y: 10), size: size))      // caption buttons
        #expect(!bands.isCaption(CGPoint(x: 20, y: 10), size: size))       // system menu icon
        #expect(!bands.isCaption(CGPoint(x: 100, y: 33), size: size))      // client area
        let none = HelperHitBands()
        #expect(none.isEmpty && !none.isResizeEdge(.zero, size: size) && !none.isCaption(CGPoint(x: 100, y: 10), size: size))
    }

    @Test func cursorGeometryFollowsK() {
        let c = HelperCursor(png: nil, pixelWidth: 64, pixelHeight: 48, hotX: 10, hotY: 6)
        #expect(c.geometry(scale: 2).size == CGSize(width: 32, height: 24))
        #expect(c.geometry(scale: 2).hotspot == CGPoint(x: 5, y: 3))
        #expect(c.geometry(scale: 1).size == CGSize(width: 64, height: 48))
        #expect(c.geometry(scale: 0).size == CGSize(width: 64, height: 48))
    }

    @Test func snapshotCopiesTheCropFromTheSurface() throws {
        let surface = try #require(SharedSurface.create(width: 40, height: 30))
        SharedSurface.draw(surface) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 5, width: 5, height: 5))           // flipped context: top-left origin
        }
        let image = try #require(SharedSurface.image(surface, rect: WireRect(x: 10, y: 5, width: 20, height: 10)))
        #expect(image.width == 20 && image.height == 10)
        // Clipped to the surface.
        let clipped = try #require(SharedSurface.image(surface, rect: WireRect(x: 30, y: 25, width: 20, height: 20)))
        #expect(clipped.width == 10 && clipped.height == 5)
        #expect(SharedSurface.image(surface, rect: WireRect(x: 40, y: 0, width: 5, height: 5)) == nil)
        let data = try #require(image.dataProvider?.data as Data?)
        let first = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        #expect(first == SharedSurface.pixel(surface, x: 10, y: 5))     // the red square at the crop's top-left
        let last = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (9 * 20 + 19) * 4, as: UInt32.self) }
        #expect(last == SharedSurface.pixel(surface, x: 29, y: 14))     // the blue background
        #expect(first != last)
        #expect(SharedSurface.snapshotContentsRect(viewPixels: CGSize(width: 40, height: 10), imageSize: CGSize(width: 20, height: 10))
            == CGRect(x: 0, y: 0, width: 2, height: 1))
    }
}

@Suite struct HelperReviewFixTests {
    /// Popups never keep a helper: after the last app window they go back to the main process and the helper
    /// quits normally (its own windowless rule counts app windows only).
    @Test func popupsAreHandedBackWithTheLastAppWindow() {
        #expect(HelperRouting.popupsToHandBack([(id: 1, isApp: true), (id: 2, isApp: false)]) == nil)
        #expect(HelperRouting.popupsToHandBack([(id: 2, isApp: false), (id: 3, isApp: false)]) == [2, 3])
        #expect(HelperRouting.popupsToHandBack([(id: UInt32, isApp: Bool)]()) == [])
    }

    @Test func framesFromHelpersAreValidated() {
        let screens = CGRect(x: -1440, y: 0, width: 4000, height: 1440)
        let ok = WirePointRect(x: 100, y: 200, width: 800, height: 600)
        #expect(HelperRouting.validFrame(ok, limit: screens) == ok.cgRect)
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(HelperRouting.validFrame(WirePointRect(x: bad, y: 0, width: 10, height: 10), limit: screens) == nil)
            #expect(HelperRouting.validFrame(WirePointRect(x: 0, y: 0, width: bad, height: 10), limit: screens) == nil)
            #expect(HelperRouting.validPoint(x: 0, y: bad, limit: screens) == nil)
        }
        #expect(HelperRouting.validFrame(WirePointRect(x: 0, y: 0, width: 0, height: 10), limit: screens) == nil)
        #expect(HelperRouting.validFrame(WirePointRect(x: 0, y: 0, width: -5, height: 10), limit: screens) == nil)
        // Huge values are clamped (no trap in the Int conversion of the session maths).
        let huge = HelperRouting.validFrame(WirePointRect(x: 1e300, y: -1e300, width: 1e300, height: 1e9), limit: screens)
        #expect(huge == CGRect(x: 2560, y: -1440, width: 4000, height: 1440))
        // A window hanging off the left edge keeps its position.
        #expect(HelperRouting.validFrame(WirePointRect(x: -1800, y: 10, width: 800, height: 600), limit: screens)?.minX == -1800)
        #expect(HelperRouting.validPoint(x: 1e300, y: -1e300, limit: screens) == CGPoint(x: 6560, y: -1440))
        #expect(HelperRouting.validPoint(x: 5, y: 6, limit: screens) == CGPoint(x: 5, y: 6))
    }

    @Test func onlyOwnKeyEquivalentsGoToTheMenu() {
        let menu = HelperMenu.sections(appName: "A", german: true)
        #expect(HelperMenu.isOwnShortcut(key: "q", modifiers: .command, in: menu))
        #expect(HelperMenu.isOwnShortcut(key: "H", modifiers: [.option, .command], in: menu))
        #expect(HelperMenu.isOwnShortcut(key: "l", modifiers: [.control, .option, .command], in: menu))
        // AppKit's own items and anything else reach the remote app.
        #expect(!HelperMenu.isOwnShortcut(key: "?", modifiers: [.shift, .command], in: menu))
        #expect(!HelperMenu.isOwnShortcut(key: "f", modifiers: [.control, .command], in: menu))
        #expect(!HelperMenu.isOwnShortcut(key: "\u{F702}", modifiers: .control, in: menu))
        #expect(!HelperMenu.isOwnShortcut(key: "s", modifiers: .command, in: menu))
        #expect(!HelperMenu.isOwnShortcut(key: "q", modifiers: [.shift, .command], in: menu))
    }

    @Test func arrowCursorRoundTripsAndOldMessagesDecode() throws {
        let m = HostMessage.cursor(.systemArrow)
        #expect(try WireCoding.decode(HostMessage.self, from: WireCoding.encode(m)) == m)
        let json = #"{"png":null,"pixelWidth":0,"pixelHeight":0,"hotX":0,"hotY":0}"#
        #expect(try WireCoding.decode(HelperCursor.self, from: Data(json.utf8)).arrow == nil)
    }
}
