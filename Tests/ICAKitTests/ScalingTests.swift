import CoreGraphics
import Foundation
import Testing
@testable import ICAKit

// Screens in macOS global points (y up), main screen first, as NSScreen reports them.

private func screen(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, menuBar: CGFloat = 0, scale: CGFloat) -> ScalingScreen {
    ScalingScreen(frame: CGRect(x: x, y: y, width: w, height: h),
                  visible: CGRect(x: x, y: y, width: w, height: h - menuBar), backingScale: scale)
}

private let noLimit = (width: Int(Int32.max), height: Int(Int32.max))
private let auto = ScalingSettings()
/// This Mac: built-in Retina 1800×1169 pt (visible height 1130), external 2560×1440 pt 1x to its
/// right, bottoms aligned (no menu bar on the external here; `usersLayout` below has one on both). The monitors
/// start below the menu bar (docs/80 §7.1), so the built-in is laid out as 1800×1130 pt.
private let builtIn = screen(0, 0, 1800, 1169, menuBar: 39, scale: 2)
private let thisMac = [builtIn, screen(1800, 0, 2560, 1440, scale: 1)]

private func allEven(_ r: TWIRect) -> Bool { [r.left, r.top, r.right, r.bottom].allSatisfy { $0 % 2 == 0 } }

// MARK: Settings

@Test func scalingSettingsParseAndStore() throws {
    #expect(auto.windows == .auto && auto.client == .auto)
    #expect(ScalingSettings(windowsKey: "125", clientKey: "2x") == ScalingSettings(windows: .percent(125), client: .fixed(2)))
    #expect(ScalingSettings(windowsKey: "150 %", clientKey: "1") == ScalingSettings(windows: .percent(150), client: .fixed(1)))
    // Unknown values are Auto.
    #expect(ScalingSettings(windowsKey: "130", clientKey: "3x") == auto)
    #expect(ScalingSettings(windowsKey: nil, clientKey: "junk") == auto)
    let s = ScalingSettings(windows: .percent(175), client: .fixed(1))
    #expect(s.windowsKey == "175" && s.clientKey == "1x" && auto.windowsKey == "auto" && auto.clientKey == "auto")

    let suite = "ica.scaling.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ScalingSettings.load(defaults: defaults, env: [:]) == auto)
    s.save(to: defaults)
    #expect(ScalingSettings.load(defaults: defaults, env: [:]) == s)
    // Environment overrides (automated runs).
    #expect(ScalingSettings.load(defaults: defaults, env: ["ICA_SCALE_CLIENT": "2x", "ICA_SCALE_WINDOWS": "auto"])
            == ScalingSettings(windows: .auto, client: .fixed(2)))
}

@Test func scalingLimitsAreBlockBAndOverridable() {
    #expect(ScalingLimits.maxSessionWidth == 5120 && ScalingLimits.maxSessionHeight == 4096)
    #expect(ScalingLimits.redrawMaxCoordinate == 4095)
    #expect(ScalingLimits.sessionLimit(env: [:]) == (5120, 4096))
    #expect(ScalingLimits.sessionLimit(env: ["ICA_SCALE_LIMIT": "8720x2880"]) == (8720, 2880))
    #expect(ScalingLimits.sessionLimit(env: ["ICA_SCALE_LIMIT": "none"]).width > 100_000)
    #expect(ScalingLimits.sessionLimit(env: ["ICA_SCALE_LIMIT": "bad"]) == (5120, 4096))
}

// MARK: Single screen

@Test func singleRetinaScreenAutoIsSharpAtNormalSize() {
    let l = ScalingLayout.resolve(screens: [builtIn], settings: auto)
    #expect(l.note == nil && l.uniformScale == 2)
    #expect(l.width == 3600 && l.height == 2260)
    let m = l.monitors[0]
    #expect(m.scale == 2 && m.windowsPercent == 200)
    #expect(m.bounds == TWIRect(left: 0, top: 0, right: 3600, bottom: 2260))
    #expect(m.workArea == m.bounds)
    var display = WDDisplay()
    l.apply(to: &display)
    #expect(display.width == 3600 && display.height == 2260 && display.scalePercent == 200 && display.monitors.isEmpty)
    // cap 0x20 carries 200 (one monitor).
    let caps = WDModules.thinwireCapabilities(scalePercent: display.scalePercent, monitors: display.monitors, h264: true)
    #expect(Array(caps[4..<14]) == [0x0A, 0x00, 0x20, 0x00, 0x02, 0x00, 0x01, 0x00, 0xC8, 0x00])
}

@Test func singleNonRetinaScreenAutoStaysAt1x() {
    let l = ScalingLayout.resolve(screens: [screen(0, 0, 1920, 1080, menuBar: 25, scale: 1)], settings: auto)
    // 1055 pt below the 25 pt menu bar, down to even.
    #expect(l.width == 1920 && l.height == 1054 && l.monitors[0].scale == 1 && l.monitors[0].windowsPercent == 100)
    #expect(l.monitors[0].workArea == TWIRect(left: 0, top: 0, right: 1920, bottom: 1054))
}

@Test func manualOverridesOnOneScreen() {
    let retina = [builtIn]
    // Client 1x on Retina: the screen below the menu bar (live before D197: 1800×1168); Windows Auto follows the client scale.
    let one = ScalingLayout.resolve(screens: retina, settings: ScalingSettings(client: .fixed(1)))
    #expect(one.width == 1800 && one.height == 1130 && one.monitors[0].windowsPercent == 100 && one.note == nil)
    // Manual Windows 150 % with client Auto: more room at 2x.
    let w150 = ScalingLayout.resolve(screens: retina, settings: ScalingSettings(windows: .percent(150)))
    #expect(w150.width == 3600 && w150.monitors[0].windowsPercent == 150)
    // Client 2x on a 1x screen: 2 px per point, Windows Auto 200 %.
    let two = ScalingLayout.resolve(screens: [screen(0, 0, 1920, 1080, scale: 1)], settings: ScalingSettings(client: .fixed(2)))
    #expect(two.width == 3840 && two.height == 2160 && two.monitors[0].scale == 2 && two.monitors[0].windowsPercent == 200)
}

// MARK: Two screens


@Test func retinaPlusExternalSideBySidePerScreen() {
    let l = ScalingLayout.resolve(screens: thisMac, settings: auto, limit: noLimit)
    #expect(l.note == nil && l.uniformScale == nil)
    #expect(l.monitors.map(\.scale) == [2, 1] && l.monitors.map(\.windowsPercent) == [200, 100])
    // Built-in scaled about its top-left; the external anchored at the shared bottom-right corner.
    #expect(l.monitors[0].bounds == TWIRect(left: 0, top: 0, right: 3600, bottom: 2260))
    #expect(l.monitors[1].bounds == TWIRect(left: 3600, top: 820, right: 6160, bottom: 2260))
    #expect(l.width == 6160 && l.height == 2260)
    // Wire: per-monitor 0x20 and 0x11.
    var display = WDDisplay()
    l.apply(to: &display)
    #expect(display.monitors.map(\.scalePercent) == [200, 100])
    #expect(display.monitors[1].left == 3600 && display.monitors[1].bottom == 2260)
    let caps = WDModules.thinwireCapabilities(scalePercent: display.scalePercent, monitors: display.monitors, h264: true)
    #expect(Array(caps[4..<16]) == [0x0C, 0x00, 0x20, 0x00, 0x02, 0x00, 0x02, 0x00, 0xC8, 0x00, 0x64, 0x00])
    #expect(l.twiMonitors.map(\.bounds) == l.monitors.map(\.bounds))
}

@Test func retinaPlusExternalAutoFallsBackTo1xAboveTheLimit() {
    let l = ScalingLayout.resolve(screens: thisMac, settings: auto)
    #expect(l.note == .tooLarge(width: 6160, height: 2260, limitWidth: 5120, limitHeight: 4096, manual: false))
    #expect(l.uniformScale == 1 && l.monitors.map(\.windowsPercent) == [100, 100])
    // The union of the session frames in points, 4360×1440 (above the redraw range, below Block B).
    #expect(l.width == 4360 && l.height == 1440)
    // The built-in starts below its menu bar (pt 1130 = px 310), its work area too.
    #expect(l.monitors[0].bounds == TWIRect(left: 0, top: 310, right: 1800, bottom: 1440))
    #expect(l.monitors[0].origin == CGPoint(x: 0, y: 310))
    #expect(l.monitors[0].workArea == l.monitors[0].bounds)
    // Union map: px = (x − 0, 1440 − y).
    #expect(l.pointRect(TWIRect(x: 100, y: 400, width: 200, height: 100)) == CGRect(x: 100, y: 940, width: 200, height: 100))
    #expect(l.sessionRect(CGRect(x: 100, y: 940, width: 200, height: 100)) == TWIRect(x: 100, y: 400, width: 200, height: 100))
    // A point in the menu bar strip maps through the nearest monitor's map, above its top.
    #expect(l.sessionPoint(CGPoint(x: 10, y: 1168.5)) == (10, 271))
    #expect(l.sessionPoint(CGPoint(x: 2000.4, y: 0.5)) == (2000, 1439))
    #expect(l.monitors[1].bounds == TWIRect(left: 1800, top: 0, right: 4360, bottom: 1440))
    #expect(l.rule == .uniform(1))
}

@Test func manual2xThatDoesNotFitIsRefused() {
    let l = ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(client: .fixed(2)))
    #expect(l.note == .tooLarge(width: 8720, height: 2880, limitWidth: 5120, limitHeight: 4096, manual: true))
    #expect(l.width == 4360 && l.uniformScale == 1 && l.monitors.map(\.windowsPercent) == [100, 100])
    // A manual Windows percentage survives the fallback.
    let w = ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(windows: .percent(125), client: .fixed(2)))
    #expect(w.uniformScale == 1 && w.monitors.map(\.windowsPercent) == [125, 125])
    // With the limit lifted (live experiment) the 2x union is used as is.
    let big = ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(client: .fixed(2)), limit: noLimit)
    #expect(big.note == nil && big.width == 8720 && big.height == 2880 && big.monitors[1].bounds.left == 3600)
}

@Test func smallerRetinaWithExternalLeftOfPrimaryFits() {
    // External 1x at negative x, left of the Retina main screen, bottoms aligned.
    let screens = [screen(0, 0, 1512, 982, menuBar: 33, scale: 2), screen(-1920, 0, 1920, 1080, scale: 1)]
    let l = ScalingLayout.resolve(screens: screens, settings: auto)
    #expect(l.note == nil)
    #expect(l.monitors[0].bounds == TWIRect(left: 1920, top: 0, right: 4944, bottom: 1898))
    #expect(l.monitors[1].bounds == TWIRect(left: 0, top: 818, right: 1920, bottom: 1898))
    #expect(l.width == 4944 && l.height == 1898)
    #expect(l.monitors[0].workArea.top == 0)
    // Points on either side of the shared edge.
    #expect(l.sessionPoint(CGPoint(x: -1, y: 500)) == (1919, 1398))
    #expect(l.sessionPoint(CGPoint(x: 0, y: 500)) == (1920, 898))
    #expect(l.sessionPoint(CGPoint(x: 0.75, y: 948.6)) == (1921, 0))   // just below the 33 pt menu bar
}

@Test func stackedScreensExternalAbove() {
    // Retina main screen, 1x external above it, offset to the left (negative x).
    let screens = [screen(0, 0, 1512, 982, scale: 2), screen(-204, 982, 1920, 1080, scale: 1)]
    let l = ScalingLayout.resolve(screens: screens, settings: auto)
    #expect(l.note == nil)
    #expect(l.monitors[1].bounds == TWIRect(left: 0, top: 0, right: 1920, bottom: 1080))
    #expect(l.monitors[0].bounds == TWIRect(left: 204, top: 1080, right: 3228, bottom: 3044))
    #expect(l.width == 3228 && l.height == 3044)
    // A window on the Retina screen: px → points → px.
    let r = TWIRect(x: 500, y: 1500, width: 800, height: 600)
    let p = l.pointRect(r)
    #expect(p == CGRect(x: 148, y: 472, width: 400, height: 300))
    #expect(l.sessionRect(p) == r)
    // Uniform 1x: the plain union map.
    let one = ScalingLayout.resolve(screens: screens, settings: ScalingSettings(client: .fixed(1)))
    #expect(one.monitors[0].bounds == TWIRect(left: 204, top: 1080, right: 1716, bottom: 2062))
    #expect(one.monitors[1].bounds == TWIRect(left: 0, top: 0, right: 1920, bottom: 1080))
    #expect(one.width == 1920 && one.height == 2062)
}

@Test func overlappingPerScreenLayoutFallsBackTo1x() {
    // 1x main, 2x to its right, 1x below both: scaling the right screen pushes it over the lower one.
    let screens = [screen(0, 1000, 1000, 1000, scale: 1), screen(1000, 1000, 1000, 1000, scale: 2), screen(0, 0, 2000, 1000, scale: 1)]
    #expect(ScalingLayout.build(screens: screens, rule: .perScreen, windows: .auto, settings: auto) == nil)
    let l = ScalingLayout.resolve(screens: screens, settings: auto)
    #expect(l.note == .overlapping(manual: false) && l.uniformScale == 1 && l.width == 2000 && l.height == 2000)
}

@Test func evenAt1xEvenAboveTheLimit() {
    let wide = [screen(0, 0, 1920, 1080, scale: 1), screen(1920, 0, 1920, 1080, scale: 1), screen(3840, 0, 1920, 1080, scale: 1)]
    let l = ScalingLayout.resolve(screens: wide, settings: auto)
    #expect(l.note == .exceedsAtOneX(width: 5760, height: 1080, limitWidth: 5120, limitHeight: 4096))
    #expect(l.width == 5760)
}

@Test func oddEdgesBecomeEven() {
    #expect(ScalingLayout.evenDown(-3) == -4 && ScalingLayout.evenDown(5) == 4 && ScalingLayout.evenUp(5) == 6 && ScalingLayout.evenUp(-3) == -2)
    // Main 1799×1169 pt with a 25 pt menu bar and a 27 pt Dock on the left; a small screen to its right.
    let screens = [ScalingScreen(frame: CGRect(x: 0, y: 0, width: 1799, height: 1169),
                                 visible: CGRect(x: 27, y: 0, width: 1772, height: 1144), backingScale: 1),
                   screen(1799, 101, 1001, 501, scale: 1)]
    let l = ScalingLayout.resolve(screens: screens, settings: auto)
    #expect(l.monitors[0].bounds == TWIRect(left: 0, top: 0, right: 1798, bottom: 1144))
    #expect(l.monitors[0].workArea == TWIRect(left: 28, top: 0, right: 1798, bottom: 1144))
    #expect(l.monitors[1].bounds == TWIRect(left: 1798, top: 542, right: 2800, bottom: 1042))
    #expect(l.monitors.allSatisfy { allEven($0.bounds) && allEven($0.workArea) })
    #expect(l.width % 2 == 0 && l.height % 2 == 0 && l.width == 2800 && l.height == 1144)
}

// MARK: Conversions

@Test func pointPixelRoundTripsPerScreen() {
    let layouts = [
        ScalingLayout.resolve(screens: thisMac, settings: auto, limit: noLimit),
        ScalingLayout.resolve(screens: thisMac, settings: auto),
        ScalingLayout.resolve(screens: [screen(0, 0, 1512, 982, scale: 2), screen(-1920, 0, 1920, 1080, scale: 1)], settings: auto),
    ]
    for l in layouts {
        for (i, m) in l.monitors.enumerated() {
            for (dx, dy, w, h) in [(0, 0, 100, 80), (37, 51, 427, 633), (Int(m.bounds.width) - 300, Int(m.bounds.height) - 200, 300, 200)] {
                let r = TWIRect(x: m.bounds.left + Int32(dx), y: m.bounds.top + Int32(dy), width: Int32(w), height: Int32(h))
                #expect(l.monitorIndex(forSession: r) == i)
                let p = l.pointRect(r)
                #expect(m.frame.contains(CGPoint(x: p.midX, y: p.midY)))
                #expect(l.monitorIndex(forPoints: p) == i)
                #expect(l.sessionRect(p) == r)
            }
            // Pixels of a 2x screen are half points.
            #expect(l.pointRect(TWIRect(x: m.bounds.left + 1, y: m.bounds.top, width: 3, height: 2)).width == 3 / CGFloat(m.scale))
        }
    }
}

@Test func twiRectToFrameUsesTheMonitorHoldingMostOfIt() {
    let l = ScalingLayout.resolve(screens: thisMac, settings: auto, limit: noLimit)
    // Calculator on the Retina screen at 200 %: half the pixels in points.
    #expect(l.pointRect(TWIRect(x: 200, y: 100, width: 428, height: 632)) == CGRect(x: 100, y: 764, width: 214, height: 316))
    // Maximised on the external screen: Windows puts it 8 px over the edge into the built-in screen.
    let maxed = TWIRect(left: 3592, top: 812, right: 6168, bottom: 2268)
    #expect(l.monitorIndex(forSession: maxed) == 1)
    #expect(l.pointRect(maxed) == CGRect(x: 1792, y: -8, width: 2576, height: 1456))
    // Off every monitor: the nearest one.
    #expect(l.monitorIndex(forSession: TWIRect(x: 7000, y: 1000, width: 10, height: 10)) == 1)
    #expect(l.monitorIndex(forSession: TWIRect(x: -500, y: 10, width: 10, height: 10)) == 0)
}

@Test func viewPointsToSessionPixelsFloor() {
    let origin = TWIRect(x: 300, y: 200, width: 400, height: 300)
    #expect(ScalingLayout.sessionPoint(viewPoint: CGPoint(x: 10.75, y: 3.5), origin: origin, scale: 2) == (321, 207))
    #expect(ScalingLayout.sessionPoint(viewPoint: CGPoint(x: 10.75, y: 3.5), origin: origin, scale: 1) == (310, 203))
    #expect(ScalingLayout.sessionPoint(viewPoint: CGPoint(x: 0.49, y: 0.5), origin: origin, scale: 2) == (300, 201))
}

@Test func pointerBitmapsScaleToPoints() {
    let two = ScalingLayout.cursor(pixelWidth: 64, pixelHeight: 64, hotspot: CGPoint(x: 10, y: 21), scale: 2)
    #expect(two.size == CGSize(width: 32, height: 32) && two.hotspot == CGPoint(x: 5, y: 10.5))
    let one = ScalingLayout.cursor(pixelWidth: 32, pixelHeight: 32, hotspot: CGPoint(x: 4, y: 4), scale: 1)
    #expect(one.size == CGSize(width: 32, height: 32) && one.hotspot == CGPoint(x: 4, y: 4))
}

@Test func onScreenChecksAndMainScreenClampUsePixels() {
    let l = ScalingLayout.resolve(screens: [screen(0, 0, 1800, 1170, menuBar: 25, scale: 2)], settings: auto)
    #expect(l.isOnScreen(TWIRect(x: 100, y: 100, width: 400, height: 300)))
    #expect(!l.isOnScreen(TWIRect(x: 3700, y: 100, width: 400, height: 300)))
    // Top-left part back into the work area, 30 pt (60 px) below its top (the work area starts below the menu bar).
    #expect(l.onMainScreen(TWIRect(x: 5000, y: -400, width: 400, height: 300)) == TWIRect(x: 3200, y: 60, width: 400, height: 300))
}

// MARK: Screen changes during a session

@Test func screenChangeKeepsTheSessionSize() {
    let start = ScalingLayout.resolve(screens: thisMac, settings: auto)   // 1x fallback, 4360×1440
    // Unplug the external screen: the built-in keeps its monitor, the session its size.
    let unplugged = start.keepingSession(screens: [thisMac[0]])
    #expect(unplugged.width == 4360 && unplugged.height == 1440 && unplugged.monitors.count == 1)
    #expect(unplugged.monitors[0].bounds == start.monitors[0].bounds && unplugged.monitors[0].scale == 1)
    // Plug it back in the same place: the same layout as at connect.
    #expect(unplugged.keepingSession(screens: thisMac) == start)
    // Same screens again: unchanged.
    #expect(start.keepingSession(screens: thisMac) == start)

    // A 2x single-screen session that gains an external screen: clipped to the session, at 2x.
    let single = ScalingLayout.resolve(screens: [thisMac[0]], settings: auto)
    let more = single.keepingSession(screens: thisMac)
    #expect(more.width == 3600 && more.height == 2260)
    #expect(more.monitors.count == 1 && more.monitors[0].bounds == single.monitors[0].bounds)
}

// MARK: Redraw range

@Test func redrawRequestsAreClippedTo12Bits() {
    #expect(ThinwireCapabilities.redrawable(TWRect(0, 0, 4360, 1440)) == TWRect(0, 0, 4095, 1440))
    #expect(ThinwireCapabilities.redrawable(TWRect(4200, 0, 100, 100)).isEmpty)
    #expect(ThinwireCapabilities.redrawable(TWRect(100, 100, 50, 50)) == TWRect(100, 100, 50, 50))
    guard case let .wdPacket(_, body) = ThinwireCapabilities.redraw(TWRect(0, 0, 4360, 1440)) else {
        Issue.record("not a WD packet"); return
    }
    // right = 0xFFF, bottom = 0x5A0 (no wrap-around to 4360 & 0xFFF).
    #expect([UInt8](body) == [0x06, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x0F, 0x5A])

    let engine = ThinwireEngine()
    var sent: [ChannelOutput] = []
    var logs: [String] = []
    engine.output = { sent.append($0) }
    engine.log = { logs.append($0) }
    engine.requestRedraw(TWRect(0, 0, 4360, 1440))
    engine.requestRedraw(TWRect(4200, 0, 100, 100))
    #expect(sent.count == 1 && engine.stats.redrawsClipped == 2)
    #expect(logs.filter { $0.contains("clipped") }.count == 1)
}

// MARK: Review fixes

@Test func dragOntoAnotherScreenMapsThroughThatScreen() {
    let l = ScalingLayout.resolve(screens: thisMac, settings: auto, limit: noLimit)
    // Calculator on the Retina screen (monitor 0, 2x): px 200,100 428×632 = pt 100,764 214×316.
    let origin = TWIRect(x: 200, y: 100, width: 428, height: 632)
    let frame = CGRect(x: 100, y: 764, width: 214, height: 316)
    func event(_ screen: CGPoint) -> (x: Int, y: Int) {
        let view = CGPoint(x: screen.x - frame.minX, y: frame.maxY - screen.y)   // flipped view coordinates
        return l.eventPoint(viewPoint: view, origin: origin, scale: 2, screenPoint: screen, windowFrame: frame, windowMonitor: 0)
    }
    #expect(event(CGPoint(x: 110, y: 1070)) == (220, 120))          // on the window
    #expect(event(CGPoint(x: 50, y: 50)) == (100, 2160))            // its own screen: same map either way
    #expect(event(CGPoint(x: 50, y: 50)) == l.sessionPoint(CGPoint(x: 50, y: 50)))
    // Dragged onto the 1x external screen: its map, not the window's 2x one (which would say 4000).
    #expect(event(CGPoint(x: 2000, y: 500)) == (3800, 1760))
}

@Test func popupsFollowTheMonitorOfTheWindowTheyOverlap() {
    let windows: [(id: UInt32, rect: TWIRect, monitor: Int)] = [(1, TWIRect(x: 3000, y: 500, width: 1200, height: 800), 0),
                                                                (2, TWIRect(x: 4500, y: 1000, width: 500, height: 400), 1)]
    // A menu of window 1 that lies mostly on the external monitor still uses window 1's monitor.
    #expect(ScalingLayout.popupMonitor(TWIRect(x: 3700, y: 600, width: 400, height: 300), ownerId: 0, windows: windows) == 0)
    // The owner wins over a larger overlap with another window.
    #expect(ScalingLayout.popupMonitor(TWIRect(x: 4150, y: 1100, width: 400, height: 300), ownerId: 1, windows: windows) == 0)
    #expect(ScalingLayout.popupMonitor(TWIRect(x: 4150, y: 1100, width: 400, height: 300), ownerId: 0, windows: windows) == 1)
    #expect(ScalingLayout.popupMonitor(TWIRect(x: 0, y: 0, width: 10, height: 10), ownerId: 1, windows: windows) == nil)
}

@Test func settingsThatResolveToTheSameSessionNeedNoReconnect() {
    let connected = ScalingLayout.resolve(screens: thisMac, settings: auto)          // Auto fell back to 1x / 100 %
    #expect(ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(client: .fixed(1))).sameSession(as: connected))
    #expect(ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(client: .fixed(2))).sameSession(as: connected))
    #expect(ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(windows: .percent(100))).sameSession(as: connected))
    #expect(!ScalingLayout.resolve(screens: thisMac, settings: ScalingSettings(windows: .percent(125))).sameSession(as: connected))
    let single = ScalingLayout.resolve(screens: [builtIn], settings: auto)
    #expect(!ScalingLayout.resolve(screens: [builtIn], settings: ScalingSettings(client: .fixed(1))).sameSession(as: single))
    #expect(!ScalingLayout.resolve(screens: [builtIn], settings: ScalingSettings(windows: .percent(150))).sameSession(as: single))
}

// MARK: Monitors below the menu bar (docs/80 §7.1, D197)

/// The user's layout (log of 2026-11-25): built-in 1800×1169 pt with a 40 pt menu bar (notch), external
/// 2560×1440 pt with a 30 pt menu bar to its right, bottoms aligned, both Retina, client 1x / Windows 100 %.
private let usersLayout = [ScalingScreen(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                         visible: CGRect(x: 0, y: 0, width: 1800, height: 1129), backingScale: 2, safeTop: 38),
                           screen(1800, 0, 2560, 1440, menuBar: 30, scale: 2)]

@Test func sessionFrameIsTheScreenBelowTheMenuBar() {
    // Menu bar shown: the visible top. A Dock on the left or at the bottom does not change it.
    let dock = ScalingScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                             visible: CGRect(x: 60, y: 70, width: 1860, height: 985), backingScale: 1)
    #expect(dock.sessionFrame == CGRect(x: 0, y: 0, width: 1920, height: 1055))
    // No menu bar on this screen, or hidden automatically: the whole screen.
    #expect(screen(0, 0, 1920, 1080, scale: 1).sessionFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    // A notch: with the menu bar shown it is the taller one; hidden automatically, the band beside the notch stays out.
    #expect(usersLayout[0].sessionFrame == CGRect(x: 0, y: 0, width: 1800, height: 1129))
    let hidden = ScalingScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               backingScale: 2, safeTop: 32)
    #expect(hidden.sessionFrame == CGRect(x: 0, y: 0, width: 1512, height: 950))
    // Nonsense insets never give an empty frame.
    let odd = ScalingScreen(frame: CGRect(x: 0, y: 0, width: 100, height: 100), visible: CGRect(x: 0, y: 0, width: 100, height: 100),
                            backingScale: 1, safeTop: 500)
    #expect(odd.sessionFrame == odd.frame)
}

@Test func usersLayoutFullScreenWindowsFitBelowTheMenuBar() {
    let l = ScalingLayout.resolve(screens: usersLayout, settings: ScalingSettings(windows: .percent(100), client: .fixed(1)))
    #expect(l.note == nil && l.belowMenuBar && l.uniformScale == 1)
    #expect(l.width == 4360 && l.height == 1410)
    // Built-in: its top (px 281) is under its menu bar with nothing above: rounded into the screen, to 282.
    #expect(l.monitors[0].bounds == TWIRect(left: 0, top: 282, right: 1800, bottom: 1410))
    #expect(l.monitors[0].origin == CGPoint(x: 0, y: 281))
    #expect(l.monitors[1].bounds == TWIRect(left: 1800, top: 0, right: 4360, bottom: 1410))
    // The work area is the whole monitor now (no Dock in this layout).
    #expect(l.monitors.allSatisfy { $0.workArea == $0.bounds && allEven($0.bounds) })
    #expect(l.twiMonitors.map(\.bounds) == l.monitors.map(\.bounds))
    var display = WDDisplay()
    l.apply(to: &display)
    #expect(display.width == 4360 && display.height == 1410 && display.monitors.map(\.top) == [282, 0])
    // Remote Desktop Connection in full screen on the external monitor, and its connection bar at the monitor's top:
    // both start at the external's visible top (pt 1410), below its menu bar.
    let full = l.pointRect(l.monitors[1].bounds)
    #expect(full == CGRect(x: 1800, y: 0, width: 2560, height: 1410) && full.maxY <= usersLayout[1].visible.maxY)
    let bar = l.pointRect(TWIRect(x: 2792, y: 0, width: 576, height: 27))
    #expect(bar == CGRect(x: 2792, y: 1383, width: 576, height: 27))
    // Full screen on the built-in: below its 40 pt menu bar as well.
    #expect(l.pointRect(l.monitors[0].bounds).maxY <= usersLayout[0].visible.maxY)
    // Mouse: the first row below each menu bar is the monitor's first pixel row (the map's origin).
    #expect(l.sessionPoint(CGPoint(x: 2000, y: 1409.5)) == (2000, 0))
    #expect(l.sessionPoint(CGPoint(x: 10, y: 1128.5)) == (10, 281))
    for (i, m) in l.monitors.enumerated() {
        let r = TWIRect(x: m.bounds.left + 40, y: m.bounds.top + 30, width: 500, height: 300)
        #expect(l.monitorIndex(forPoints: l.pointRect(r)) == i && l.sessionRect(l.pointRect(r)) == r)
    }
    // Retina sharp (Auto, no limit): the same rule at 2x.
    let sharp = ScalingLayout.resolve(screens: usersLayout, settings: auto, limit: noLimit)
    #expect(sharp.monitors.map(\.bounds) == [TWIRect(left: 0, top: 562, right: 3600, bottom: 2820),
                                             TWIRect(left: 3600, top: 0, right: 8720, bottom: 2820)])
    #expect(sharp.pointRect(sharp.monitors[1].bounds).maxY == 1410)
}

@Test func stackedScreensAreJoinedBelowTheMenuBar() {
    // Retina main screen (33 pt menu bar), 1x external above it with a 24 pt menu bar, offset to the left.
    let screens = [screen(0, 0, 1512, 982, menuBar: 33, scale: 2), screen(-204, 982, 1920, 1080, menuBar: 24, scale: 1)]
    let l = ScalingLayout.resolve(screens: screens, settings: auto)
    #expect(l.note == nil && l.belowMenuBar)
    // No gap: the external's bottom is the main screen's first row below its menu bar.
    #expect(l.monitors[1].bounds == TWIRect(left: 0, top: 0, right: 1920, bottom: 1056))
    #expect(l.monitors[0].bounds == TWIRect(left: 204, top: 1056, right: 3228, bottom: 2954))
    #expect(l.width == 3228 && l.height == 2954)
    // Rows on either side of the edge are neighbours in the session.
    #expect(l.sessionPoint(CGPoint(x: 10, y: 982.5)) == (214, 1055))
    #expect(l.sessionPoint(CGPoint(x: 10, y: 948.5)) == (224, 1057))
    // Uniform 1x: joined as well, so the external's map is shifted by the main screen's strip.
    let one = ScalingLayout.resolve(screens: screens, settings: ScalingSettings(client: .fixed(1)))
    #expect(one.monitors[1].bounds == TWIRect(left: 0, top: 0, right: 1920, bottom: 1056))
    #expect(one.monitors[0].bounds == TWIRect(left: 204, top: 1056, right: 1716, bottom: 2004))
    #expect(one.width == 1920 && one.height == 2004)
    #expect(one.pointRect(TWIRect(x: 300, y: 1000, width: 100, height: 56)) == CGRect(x: 96, y: 982, width: 100, height: 56))
    #expect(one.pointRect(TWIRect(x: 300, y: 1056, width: 100, height: 100)) == CGRect(x: 96, y: 849, width: 100, height: 100))

    // Main screen above, external below it, both with a 25 pt menu bar: the external's strip is joined to the main's bottom.
    let below = ScalingLayout.resolve(screens: [screen(0, 0, 1920, 1080, menuBar: 25, scale: 1), screen(0, -1080, 1920, 1080, menuBar: 25, scale: 1)],
                                      settings: auto)
    #expect(below.belowMenuBar)
    #expect(below.monitors.map(\.bounds) == [TWIRect(left: 0, top: 0, right: 1920, bottom: 1054), TWIRect(left: 0, top: 1054, right: 1920, bottom: 2110)])
    #expect(below.sessionPoint(CGPoint(x: 5, y: -25.5)) == (5, 1055))
}

@Test func joinedStripsThatWouldOverlapUseTheWholeScreens() {
    // A wide screen above two side by side with different menu bars (40 and 20 pt): joining the wide one to the main's
    // strip pushes it 20 pt into the right one. The layout uses the whole screens (as before D197), no gap.
    let screens = [screen(0, 0, 1500, 1000, menuBar: 40, scale: 1), screen(1500, 0, 1500, 1000, menuBar: 20, scale: 1),
                   screen(0, 1000, 3000, 1000, scale: 1)]
    #expect(ScalingLayout.build(screens: screens, rule: .uniform(1), windows: .auto, settings: auto, belowMenuBar: true) == nil)
    let l = ScalingLayout.resolve(screens: screens, settings: auto)
    #expect(!l.belowMenuBar && l.note == nil)
    #expect(l.monitors.map(\.bounds) == [TWIRect(left: 0, top: 1000, right: 1500, bottom: 2000),
                                         TWIRect(left: 1500, top: 1000, right: 3000, bottom: 2000), TWIRect(left: 0, top: 0, right: 3000, bottom: 1000)])
    #expect(l.monitors.map(\.frame) == screens.map(\.frame))
    #expect(l.monitors[0].workArea.top == 1040 && l.monitors[1].workArea.top == 1020)
    #expect(l.logLines[0].hasSuffix("monitors: whole screens (joining the menu bar strips would overlap)"))
}

@Test func menuBarThatStartsOrStopsHidingKeepsTheSessionAndItsMap() {
    let shown = screen(0, 0, 1920, 1080, menuBar: 25, scale: 1), hidden = screen(0, 0, 1920, 1080, scale: 1)
    // Shown at connect, then hidden automatically: the session keeps its size and map until the next connect.
    let start = ScalingLayout.resolve(screens: [shown], settings: auto)
    #expect(start.width == 1920 && start.height == 1054)
    let later = start.keepingSession(screens: [hidden])
    #expect(later.width == 1920 && later.height == 1054 && later.monitors.count == 1)
    #expect(later.monitors[0].bounds == TWIRect(left: 0, top: 0, right: 1920, bottom: 1054))
    #expect(later.sessionPoint(CGPoint(x: 10, y: 500)) == start.sessionPoint(CGPoint(x: 10, y: 500)))
    // Hidden at connect (the whole screen), then shown: the monitor moves down to the strip's bottom (to even), same map.
    let full = ScalingLayout.resolve(screens: [hidden], settings: auto)
    #expect(full.height == 1080 && full.monitors[0].bounds.top == 0)
    let bar = full.keepingSession(screens: [shown])
    #expect(bar.width == 1920 && bar.height == 1080 && bar.monitors[0].bounds == TWIRect(left: 0, top: 24, right: 1920, bottom: 1080))
    #expect(bar.sessionPoint(CGPoint(x: 10, y: 500)) == full.sessionPoint(CGPoint(x: 10, y: 500)))
    // The Dock moving keeps the monitor (its session frame is the same); only the work area follows.
    let dockLeft = ScalingScreen(frame: shown.frame, visible: CGRect(x: 70, y: 0, width: 1850, height: 1055), backingScale: 1)
    let moved = start.keepingSession(screens: [dockLeft])
    #expect(moved.monitors[0].bounds == start.monitors[0].bounds && moved.monitors[0].workArea.left == 70)
}

@Test func desktopSessionLayoutIsUnchanged() {
    // The desktop window's content rect is passed as frame and visible frame (D139): nothing is taken off it.
    let rect = CGRect(x: 90, y: 60, width: 1620, height: 990)
    let l = ScalingLayout.resolve(screens: [ScalingScreen(frame: rect, visible: rect, backingScale: 2)], settings: auto)
    #expect(l.width == 3240 && l.height == 1980 && l.monitors[0].frame == rect && l.monitors[0].workArea == l.monitors[0].bounds)
}
