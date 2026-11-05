import CoreGraphics
import Foundation

/// Size limits that decide whether a scaled session is possible (docs/80 §1.2, §5 item 3). The one
/// place for these numbers; the viewer logs them at connect.
public enum ScalingLimits {
    /// Block B of the CTXTW module ("maximum mode"), a constant in the reference: 0x1400 × 0x1000.
    public static let maxSessionWidth = 0x1400
    public static let maxSessionHeight = 0x1000
    /// WD REDRAW (0x06) carries 12-bit edges with exclusive right/bottom (docs/40 §4.2), so the
    /// largest right/bottom is 4095 and the last column/row it can ask for is 4094: pixels at x or
    /// y ≥ 4095 cannot be requested. Redraw requests are clipped to this; it does not limit the
    /// session size (live, a 4360 px wide session works: the host repaints the rest itself).
    public static let redrawMaxCoordinate = 0xFFF

    public static var summary: String {
        "session ≤ \(maxSessionWidth)x\(maxSessionHeight) px (Block B), redraw right/bottom ≤ \(redrawMaxCoordinate) (12-bit, exclusive)"
    }

    /// ICA_SCALE_LIMIT=WxH overrides the session limit (live experiment, docs/80 §5 item 3); "none" lifts it.
    public static func sessionLimit(env: [String: String] = ProcessInfo.processInfo.environment) -> (width: Int, height: Int) {
        guard let text = env["ICA_SCALE_LIMIT"]?.lowercased() else { return (maxSessionWidth, maxSessionHeight) }
        if text == "none" { return (Int(Int32.max), Int(Int32.max)) }
        let parts = text.split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : (maxSessionWidth, maxSessionHeight)
    }
}

/// The user's two scaling settings (D29, docs/80 §4.1). Both default to Auto.
public struct ScalingSettings: Equatable, Sendable, CustomStringConvertible {
    public enum Windows: Equatable, Sendable {
        /// Per screen: 100 × that screen's client scale (200 % on a 2x screen).
        case auto
        /// The same percentage on every monitor.
        case percent(UInt16)
    }
    public enum Client: Equatable, Sendable {
        /// Per screen: its backingScaleFactor (2x on Retina, 1x otherwise).
        case auto
        /// Session pixels per point on every screen (1 or 2).
        case fixed(Int)
    }

    public var windows: Windows
    public var client: Client

    public static let windowsChoices: [UInt16] = [100, 125, 150, 175, 200]
    public static let clientChoices = [1, 2]

    public init(windows: Windows = .auto, client: Client = .auto) {
        self.windows = windows
        self.client = client
    }

    /// Stored form: "auto" or the percentage ("125").
    public var windowsKey: String {
        if case .percent(let p) = windows { return String(p) }
        return "auto"
    }
    /// Stored form: "auto", "1x" or "2x".
    public var clientKey: String {
        if case .fixed(let k) = client { return "\(k)x" }
        return "auto"
    }

    /// Lenient parse of the stored forms; anything unknown is Auto.
    public init(windowsKey: String?, clientKey: String?) {
        self.init()
        if let w = windowsKey.flatMap({ UInt16($0.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) }),
           Self.windowsChoices.contains(w) { windows = .percent(w) }
        if let c = clientKey.map({ $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " x")) }).flatMap(Int.init),
           Self.clientChoices.contains(c) { client = .fixed(c) }
    }

    public static let windowsDefaultsKey = "scaling.windows"
    public static let clientDefaultsKey = "scaling.client"

    /// From UserDefaults; ICA_SCALE_WINDOWS / ICA_SCALE_CLIENT override (automated runs).
    public static func load(defaults: UserDefaults = .standard,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> ScalingSettings {
        ScalingSettings(windowsKey: env["ICA_SCALE_WINDOWS"] ?? defaults.string(forKey: windowsDefaultsKey),
                        clientKey: env["ICA_SCALE_CLIENT"] ?? defaults.string(forKey: clientDefaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(windowsKey, forKey: Self.windowsDefaultsKey)
        defaults.set(clientKey, forKey: Self.clientDefaultsKey)
    }

    public var description: String { "Windows \(windowsKey == "auto" ? "auto" : windowsKey + " %"), client \(clientKey)" }
}

/// A Mac screen as the layout sees it: macOS global points (y up), and its backing scale.
public struct ScalingScreen: Equatable, Sendable {
    public var frame: CGRect
    public var visible: CGRect
    public var backingScale: CGFloat
    public init(frame: CGRect, visible: CGRect, backingScale: CGFloat) {
        self.frame = frame; self.visible = visible; self.backingScale = backingScale
    }
}

/// One monitor of the session: its Mac screen and its session-pixel rects.
public struct ScalingMonitor: Equatable, Sendable {
    /// Screen frame and visible frame, macOS global points.
    public var frame: CGRect
    public var visible: CGRect
    public var backingScale: CGFloat
    /// k: session pixels per point on this screen.
    public var scale: Int
    /// W: the Windows scaling sent for this monitor (cap 0x20).
    public var windowsPercent: UInt16
    /// Session pixels, exclusive right/bottom, every edge even (docs/80 §1.5): what goes on the wire.
    public var bounds: TWIRect
    public var workArea: TWIRect
    /// Session pixel of the screen's top-left before even rounding: the point ↔ pixel map is anchored
    /// here, so at 1x it is exactly the union map (rounding the wire rects never shifts windows).
    public var origin: CGPoint
}

/// The session pixel layout for a set of screens and the scaling settings (docs/80 §1.6, §2.3, §4).
/// Pure: the viewer builds it from NSScreen at connect and converts every coordinate through it.
///
/// Each monitor maps points to pixels on its own: px = origin + (pt − screen top-left) · k,
/// y flipped. With one k for all screens this is the affine map of the screen union (§2.3); with
/// k per screen the monitors are laid out the MMDPI way (§1.6): from the primary along shared edges,
/// each neighbour scaled about an anchor on the edge it shares with its parent.
public struct ScalingLayout: Equatable, Sendable {
    /// Why the session does not use the requested scale.
    public enum Note: Equatable, Sendable {
        /// The requested layout is larger than the limit; the session uses 1x. `manual`: the user chose 2x.
        case tooLarge(width: Int, height: Int, limitWidth: Int, limitHeight: Int, manual: Bool)
        /// Per-screen scaling would make monitors overlap (screen arrangement); the session uses 1x.
        case overlapping(manual: Bool)
        /// Even 1x is larger than the limit; nothing smaller to fall back to (sent as is).
        case exceedsAtOneX(width: Int, height: Int, limitWidth: Int, limitHeight: Int)
    }

    /// How the scale was chosen, kept so a screen change mid-session follows the same rule.
    public enum ScaleRule: Equatable, Sendable {
        case perScreen
        case uniform(Int)
    }

    /// Primary (main screen) first.
    public let monitors: [ScalingMonitor]
    /// Session size in pixels (Block A HRes/VRes), even.
    public let width: Int
    public let height: Int
    /// What the user asked for.
    public let settings: ScalingSettings
    /// The rule actually used (Auto per screen, or one scale after a fallback).
    public let rule: ScaleRule
    public let note: Note?

    /// The one k when all monitors share it.
    public var uniformScale: Int? {
        let ks = Set(monitors.map(\.scale))
        return ks.count == 1 ? ks.first : nil
    }

    // MARK: Building

    /// The layout for `screens` (main screen first) and `settings`, with the size limit applied:
    /// a layout above the limit (or with overlapping monitors) falls back to 1x on every screen, with
    /// Windows Auto at 100 % (a manual Windows percentage stays).
    public static func resolve(screens input: [ScalingScreen], settings: ScalingSettings,
                               limit: (width: Int, height: Int) = (ScalingLimits.maxSessionWidth, ScalingLimits.maxSessionHeight)) -> ScalingLayout {
        let screens = input.isEmpty ? [defaultScreen] : input
        let rule: ScaleRule
        switch settings.client {
        case .auto: rule = .perScreen
        case .fixed(let k): rule = .uniform(k)
        }
        let manual = settings.client != .auto
        let wanted = build(screens: screens, rule: rule, windows: settings.windows, settings: settings)
        func fits(_ l: ScalingLayout) -> Bool { l.width <= limit.width && l.height <= limit.height }
        if let wanted, fits(wanted) { return wanted }
        let ones = build(screens: screens, rule: .uniform(1), windows: settings.windows, settings: settings)!   // one scale never overlaps
        guard fits(ones) else {
            // Nothing smaller to fall back to: sent as is.
            return ones.with(note: .exceedsAtOneX(width: ones.width, height: ones.height, limitWidth: limit.width, limitHeight: limit.height))
        }
        let note: Note = wanted.map { .tooLarge(width: $0.width, height: $0.height, limitWidth: limit.width, limitHeight: limit.height, manual: manual) }
            ?? .overlapping(manual: manual)
        return ones.with(note: note)
    }

    static let defaultScreen = ScalingScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                             visible: CGRect(x: 0, y: 0, width: 1920, height: 1080), backingScale: 1)

    /// k for a backing scale: 2 for Retina (≥ 1.5), else 1.
    public static func autoScale(_ backing: CGFloat) -> Int { backing >= 1.5 ? 2 : 1 }

    private init(monitors: [ScalingMonitor], width: Int, height: Int, settings: ScalingSettings, rule: ScaleRule, note: Note?) {
        self.monitors = monitors; self.width = width; self.height = height
        self.settings = settings; self.rule = rule; self.note = note
    }

    private func with(note: Note?) -> ScalingLayout {
        ScalingLayout(monitors: monitors, width: width, height: height, settings: settings, rule: rule, note: note)
    }

    private static func windowsPercent(_ w: ScalingSettings.Windows, scale: Int) -> UInt16 {
        if case .percent(let p) = w { return p }
        return UInt16(100 * scale)
    }

    /// Floor / ceiling to an even value (also for negative values).
    static func evenDown(_ v: Int) -> Int { v - (v & 1) }
    static func evenUp(_ v: Int) -> Int { v + (v & 1) }

    /// Lays out the screens. Nil if monitors would overlap.
    static func build(screens: [ScalingScreen], rule: ScaleRule, windows: ScalingSettings.Windows,
                      settings: ScalingSettings) -> ScalingLayout? {
        let ks: [Int] = screens.map {
            switch rule {
            case .perScreen: return autoScale($0.backingScale)
            case .uniform(let k): return max(1, k)
            }
        }
        // Top-down point coordinates (y grows downwards from the union's top).
        let refY = screens.map(\.frame.maxY).max()!
        struct R { var left, top, right, bottom: CGFloat }
        let rects = screens.map { R(left: $0.frame.minX, top: refY - $0.frame.maxY, right: $0.frame.maxX, bottom: refY - $0.frame.minY) }
        // Transform per screen: px = offset + p · k.
        var offsets = [CGPoint?](repeating: nil, count: screens.count)
        func apply(_ i: Int, _ p: CGPoint) -> CGPoint {
            let o = offsets[i]!, k = CGFloat(ks[i])
            return CGPoint(x: o.x + p.x * k, y: o.y + p.y * k)
        }
        // Primary: scaled about its own top-left.
        let k0 = CGFloat(ks[0])
        offsets[0] = CGPoint(x: rects[0].left - rects[0].left * k0, y: rects[0].top - rects[0].top * k0)
        var queue = [0]
        while !queue.isEmpty {
            let i = queue.removeFirst()
            let a = rects[i]
            for j in screens.indices where offsets[j] == nil {
                let b = rects[j]
                guard let anchor = sharedEdgeAnchor(a.left, a.top, a.right, a.bottom, b.left, b.top, b.right, b.bottom) else { continue }
                // Neighbour: its anchor lands where the parent maps it, then it scales about the anchor.
                let mapped = apply(i, anchor), kj = CGFloat(ks[j])
                offsets[j] = CGPoint(x: mapped.x - anchor.x * kj, y: mapped.y - anchor.y * kj)
                queue.append(j)
            }
        }
        // Screens without a shared edge: anchored at their own top-left through the primary's map.
        for j in screens.indices where offsets[j] == nil {
            let tl = CGPoint(x: rects[j].left, y: rects[j].top)
            let mapped = apply(0, tl), kj = CGFloat(ks[j])
            offsets[j] = CGPoint(x: mapped.x - tl.x * kj, y: mapped.y - tl.y * kj)
        }
        let raw = screens.indices.map { i -> (l: Int, t: Int, r: Int, b: Int) in
            let tl = apply(i, CGPoint(x: rects[i].left, y: rects[i].top))
            let br = apply(i, CGPoint(x: rects[i].right, y: rects[i].bottom))
            return (Int(tl.x.rounded(.down)), Int(tl.y.rounded(.down)), Int(br.x.rounded(.down)), Int(br.y.rounded(.down)))
        }
        // Shift so the bounding box starts at 0,0, then move every edge to an even value (§1.5).
        let minX = raw.map(\.l).min()!, minY = raw.map(\.t).min()!
        var monitors: [ScalingMonitor] = []
        for (i, s) in screens.enumerated() {
            let r = raw[i]
            let bounds = TWIRect(left: Int32(evenDown(r.l - minX)), top: Int32(evenDown(r.t - minY)),
                                 right: Int32(evenDown(r.r - minX)), bottom: Int32(evenDown(r.b - minY)))
            var m = ScalingMonitor(frame: s.frame, visible: s.visible, backingScale: s.backingScale, scale: ks[i],
                                   windowsPercent: windowsPercent(windows, scale: ks[i]), bounds: bounds, workArea: bounds,
                                   origin: CGPoint(x: r.l - minX, y: r.t - minY))
            m.workArea = workArea(of: m)
            monitors.append(m)
        }
        for i in monitors.indices {
            for j in monitors.indices where j > i && overlaps(monitors[i].bounds, monitors[j].bounds) { return nil }
        }
        let width = monitors.map { Int($0.bounds.right) }.max()!, height = monitors.map { Int($0.bounds.bottom) }.max()!
        return ScalingLayout(monitors: monitors, width: evenDown(width), height: evenDown(height), settings: settings, rule: rule, note: nil)
    }

    /// Anchor on the edge two screens share (within 1 pt, overlapping along it), top-down coordinates.
    /// Along the edge it is the aligned end if the screens are aligned there (top/left first, then
    /// bottom/right), else the start of the overlap (docs/80 §1.6 step 1; the choice is ours, [I]).
    static func sharedEdgeAnchor(_ al: CGFloat, _ at: CGFloat, _ ar: CGFloat, _ ab: CGFloat,
                                 _ bl: CGFloat, _ bt: CGFloat, _ br: CGFloat, _ bb: CGFloat) -> CGPoint? {
        func along(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat? {
            let lo = max(a0, b0), hi = min(a1, b1)
            guard hi - lo > 0 else { return nil }
            if abs(a0 - b0) <= 1 { return lo }
            if abs(a1 - b1) <= 1 { return hi }
            return lo
        }
        if abs(ar - bl) <= 1, let y = along(at, ab, bt, bb) { return CGPoint(x: bl, y: y) }   // b right of a
        if abs(br - al) <= 1, let y = along(at, ab, bt, bb) { return CGPoint(x: br, y: y) }   // b left of a
        if abs(ab - bt) <= 1, let x = along(al, ar, bl, br) { return CGPoint(x: x, y: bt) }   // b below a
        if abs(bb - at) <= 1, let x = along(al, ar, bl, br) { return CGPoint(x: x, y: bb) }   // b above a
        return nil
    }

    static func overlaps(_ a: TWIRect, _ b: TWIRect) -> Bool {
        min(a.right, b.right) > max(a.left, b.left) && min(a.bottom, b.bottom) > max(a.top, b.top)
    }

    /// Visible frame through the monitor's map, edges moved inwards to even values, inside the bounds.
    static func workArea(of m: ScalingMonitor) -> TWIRect {
        let k = CGFloat(m.scale), b = m.bounds, ox = m.origin.x, oy = m.origin.y
        let l = Int((ox + (m.visible.minX - m.frame.minX) * k).rounded())
        let t = Int((oy + (m.frame.maxY - m.visible.maxY) * k).rounded())
        let r = Int((ox + (m.visible.maxX - m.frame.minX) * k).rounded())
        let bt = Int((oy + (m.frame.maxY - m.visible.minY) * k).rounded())
        let left = min(max(evenUp(l), Int(b.left)), Int(b.right)), top = min(max(evenUp(t), Int(b.top)), Int(b.bottom))
        let right = max(min(evenDown(r), Int(b.right)), left), bottom = max(min(evenDown(bt), Int(b.bottom)), top)
        return TWIRect(left: Int32(left), top: Int32(top), right: Int32(right), bottom: Int32(bottom))
    }

    // MARK: Wire values

    /// Monitors for TWI 0x35/0x3b (session pixels), primary first.
    public var twiMonitors: [TWIMonitor] { monitors.map { TWIMonitor(bounds: $0.bounds, workArea: $0.workArea) } }

    /// Monitors for Thinwire cap 0x11 / C2H 0x1D and cap 0x20 (per-monitor scale), primary first.
    public var wdMonitors: [WDMonitor] {
        monitors.map { m in
            WDMonitor(left: Int(m.bounds.left), top: Int(m.bounds.top), right: Int(m.bounds.right), bottom: Int(m.bounds.bottom),
                      workLeft: Int(m.workArea.left), workTop: Int(m.workArea.top), workRight: Int(m.workArea.right),
                      workBottom: Int(m.workArea.bottom), scalePercent: m.windowsPercent)
        }
    }

    /// The CTXTW display for this layout: Block A size, cap 0x20 (one value with one monitor, else one
    /// per monitor) and, with several monitors, cap 0x11.
    public func apply(to display: inout WDDisplay) {
        display.width = width
        display.height = height
        display.scalePercent = monitors[0].windowsPercent
        display.monitors = monitors.count > 1 ? wdMonitors : []
    }

    // MARK: Conversions

    /// The monitor holding most of a session rect (Windows' own rule, MonitorFromRect), else the nearest.
    public func monitorIndex(forSession r: TWIRect) -> Int {
        Self.best(monitors.map { m in
            let w = Int(min(r.right, m.bounds.right)) - Int(max(r.left, m.bounds.left))
            let h = Int(min(r.bottom, m.bounds.bottom)) - Int(max(r.top, m.bounds.top))
            let area = CGFloat(max(0, w)) * CGFloat(max(0, h))
            let cx = CGFloat(r.left + r.right) / 2, cy = CGFloat(r.top + r.bottom) / 2
            let dx = max(CGFloat(m.bounds.left) - cx, 0, cx - CGFloat(m.bounds.right))
            let dy = max(CGFloat(m.bounds.top) - cy, 0, cy - CGFloat(m.bounds.bottom))
            return (area, dx * dx + dy * dy)
        })
    }

    /// The monitor whose screen holds most of a point rect, else the nearest.
    public func monitorIndex(forPoints r: CGRect) -> Int {
        Self.best(monitors.map { m in
            let i = m.frame.intersection(r)
            let area = i.isNull ? 0 : i.width * i.height
            let dx = max(m.frame.minX - r.midX, 0, r.midX - m.frame.maxX)
            let dy = max(m.frame.minY - r.midY, 0, r.midY - m.frame.maxY)
            return (area, dx * dx + dy * dy)
        })
    }

    /// The monitor whose screen contains the point, else the nearest.
    public func monitorIndex(forPoint p: CGPoint) -> Int {
        monitors.firstIndex { $0.frame.contains(p) } ?? monitorIndex(forPoints: CGRect(x: p.x, y: p.y, width: 0, height: 0))
    }

    /// The monitor whose session rect contains the pixel, else the nearest.
    public func monitorIndex(forSessionX x: Int, y: Int) -> Int {
        if let i = monitors.firstIndex(where: { x >= $0.bounds.left && x < $0.bounds.right && y >= $0.bounds.top && y < $0.bounds.bottom }) {
            return i
        }
        return monitorIndex(forSession: TWIRect(x: Int32(clamping: x), y: Int32(clamping: y), width: 0, height: 0))
    }

    private static func best(_ scores: [(area: CGFloat, distance: CGFloat)]) -> Int {
        var best = 0
        for i in scores.indices.dropFirst() {
            let a = scores[i], b = scores[best]
            if a.area > b.area || (a.area == b.area && a.area == 0 && a.distance < b.distance) { best = i }
        }
        return best
    }

    /// Session rect → macOS global points, through one monitor's map (default: the one holding most of
    /// it). Fractional points are fine: with k = backing scale they land on device pixels.
    public func pointRect(_ r: TWIRect, monitor index: Int? = nil) -> CGRect {
        let m = monitors[index ?? monitorIndex(forSession: r)]
        let k = CGFloat(m.scale)
        let w = CGFloat(r.width) / k, h = CGFloat(r.height) / k
        let x = m.frame.minX + (CGFloat(r.left) - m.origin.x) / k
        let top = m.frame.maxY - (CGFloat(r.top) - m.origin.y) / k
        return CGRect(x: x, y: top - h, width: w, height: h)
    }

    /// macOS global points → session rect, through one monitor's map (default: the screen holding most
    /// of it); edges rounded (docs/80 §2.3).
    public func sessionRect(_ r: CGRect, monitor index: Int? = nil) -> TWIRect {
        let m = monitors[index ?? monitorIndex(forPoints: r)]
        let k = CGFloat(m.scale)
        let left = Int32(clamping: Int((m.origin.x + (r.minX - m.frame.minX) * k).rounded()))
        let top = Int32(clamping: Int((m.origin.y + (m.frame.maxY - r.maxY) * k).rounded()))
        return TWIRect(x: left, y: top, width: Int32(clamping: Int((r.width * k).rounded())), height: Int32(clamping: Int((r.height * k).rounded())))
    }

    /// macOS global point → session pixel (floor, like the mouse path), through the screen under it.
    public func sessionPoint(_ p: CGPoint) -> (x: Int, y: Int) {
        let m = monitors[monitorIndex(forPoint: p)]
        let k = CGFloat(m.scale)
        return (Int((m.origin.x + (p.x - m.frame.minX) * k).rounded(.down)),
                Int((m.origin.y + (m.frame.maxY - p.y) * k).rounded(.down)))
    }

    /// Session pixel for a mouse event of a window placed by `windowMonitor`. On the window or on its
    /// monitor's screen: the window's own map, origin + floor(p · k). Elsewhere (a drag carried onto
    /// another screen, maybe with another k): the map of the screen under the pointer.
    public func eventPoint(viewPoint: CGPoint, origin: TWIRect, scale: CGFloat, screenPoint: CGPoint,
                           windowFrame: CGRect, windowMonitor: Int) -> (x: Int, y: Int) {
        let own = windowMonitor < monitors.count ? monitors[windowMonitor].frame : windowFrame
        if windowFrame.contains(screenPoint) || own.contains(screenPoint) {
            return Self.sessionPoint(viewPoint: viewPoint, origin: origin, scale: scale)
        }
        return sessionPoint(screenPoint)
    }

    /// Monitor for a popup (menu, tooltip): the monitor of the app window it overlaps (its owner if
    /// that one overlaps, else the one it overlaps most), so a menu of a window straddling two screens
    /// is placed by the same map as the window. Nil when it overlaps none.
    public static func popupMonitor(_ popup: TWIRect, ownerId: UInt32,
                                    windows: [(id: UInt32, rect: TWIRect, monitor: Int)]) -> Int? {
        func area(_ r: TWIRect) -> Int {
            max(0, Int(min(r.right, popup.right)) - Int(max(r.left, popup.left)))
                * max(0, Int(min(r.bottom, popup.bottom)) - Int(max(r.top, popup.top)))
        }
        let hits = windows.filter { area($0.rect) > 0 }
        if let owner = hits.first(where: { $0.id == ownerId && ownerId != 0 }) { return owner.monitor }
        return hits.max { area($0.rect) < area($1.rect) }?.monitor
    }

    /// True if a reconnect with `other` would give the same session: size, per-monitor scale and
    /// Windows scaling (different settings can resolve to the same layout, e.g. after a fallback).
    public func sameSession(as other: ScalingLayout) -> Bool {
        width == other.width && height == other.height && monitors.map(\.scale) == other.monitors.map(\.scale)
            && monitors.map(\.windowsPercent) == other.monitors.map(\.windowsPercent)
    }

    /// View-local point (flipped, points) of a window whose remote rect starts at `origin` → session
    /// pixel: origin + floor(p · k) (docs/80 §2.3).
    public static func sessionPoint(viewPoint p: CGPoint, origin: TWIRect, scale: CGFloat) -> (x: Int, y: Int) {
        (Int(origin.left) + Int((p.x * scale).rounded(.down)), Int(origin.top) + Int((p.y * scale).rounded(.down)))
    }

    /// True if some screen shows the top strip (title area, up to 40 pt) of this remote rect.
    public func isOnScreen(_ r: TWIRect) -> Bool {
        let p = pointRect(r)
        let strip = CGRect(x: p.minX, y: p.maxY - min(p.height, 40), width: p.width, height: min(p.height, 40))
        return monitors.contains { $0.frame.intersection(strip).width >= 40 }
    }

    /// Clamps a remote rect so its top-left part lies in the main monitor's work area (brings back a
    /// window that ended up outside every screen).
    public func onMainScreen(_ r: TWIRect) -> TWIRect {
        let main = monitors[0].workArea
        let inset = Int32(30 * monitors[0].scale)
        let x = min(max(r.left, main.left), max(main.left, main.right - r.width))
        let y = min(max(r.top, main.top + inset), max(main.top, main.bottom - r.height))
        return TWIRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// NSCursor geometry for a pointer bitmap of `pixelWidth`×`pixelHeight` with its hotspot (pixels,
    /// top-left origin), shown on a screen with k session pixels per point: size and hotspot / k.
    public static func cursor(pixelWidth: Int, pixelHeight: Int, hotspot: CGPoint, scale: Int) -> (size: CGSize, hotspot: CGPoint) {
        let k = CGFloat(max(1, scale))
        return (CGSize(width: CGFloat(pixelWidth) / k, height: CGFloat(pixelHeight) / k), CGPoint(x: hotspot.x / k, y: hotspot.y / k))
    }

    // MARK: Screen changes during a session

    /// The layout for new screens without changing the session size (docs/80 §3.2): the same rule if
    /// it gives the same size; otherwise screens that are still where they were keep their monitor,
    /// others map through the primary monitor's scale and are clipped to the session (dropped if they
    /// end up empty or overlapping).
    public func keepingSession(screens input: [ScalingScreen]) -> ScalingLayout {
        let screens = input.isEmpty ? monitors.map { ScalingScreen(frame: $0.frame, visible: $0.visible, backingScale: $0.backingScale) } : input
        if let same = Self.build(screens: screens, rule: rule, windows: settings.windows, settings: settings),
           same.width == width, same.height == height {
            return same.with(note: note)
        }
        let session = TWIRect(left: 0, top: 0, right: Int32(width), bottom: Int32(height))
        let primary = monitors[0]
        var list: [ScalingMonitor] = []
        for s in screens {
            var m: ScalingMonitor
            if let old = monitors.first(where: { $0.frame == s.frame }) {
                m = old
                m.visible = s.visible
                m.backingScale = s.backingScale
            } else {
                let k = CGFloat(primary.scale)
                let l = Int((primary.origin.x + (s.frame.minX - primary.frame.minX) * k).rounded(.down))
                let t = Int((primary.origin.y + (primary.frame.maxY - s.frame.maxY) * k).rounded(.down))
                let full = TWIRect(left: Int32(Self.evenDown(l)), top: Int32(Self.evenDown(t)),
                                   right: Int32(Self.evenDown(l + Int((s.frame.width * k).rounded(.down)))),
                                   bottom: Int32(Self.evenDown(t + Int((s.frame.height * k).rounded(.down)))))
                // The map stays anchored at the unclipped top-left: shift the frame by what clipping removed.
                let clipped = TWIRect(left: max(full.left, 0), top: max(full.top, 0),
                                      right: min(full.right, session.right), bottom: min(full.bottom, session.bottom))
                guard clipped.width > 0, clipped.height > 0 else { continue }
                let dx = CGFloat(clipped.left - full.left) / k, dy = CGFloat(clipped.top - full.top) / k
                let frame = CGRect(x: s.frame.minX + dx, y: s.frame.maxY - dy - CGFloat(clipped.height) / k,
                                   width: CGFloat(clipped.width) / k, height: CGFloat(clipped.height) / k)
                let visible = s.visible.intersection(frame)
                m = ScalingMonitor(frame: frame, visible: visible.isNull ? frame : visible, backingScale: s.backingScale,
                                   scale: primary.scale, windowsPercent: primary.windowsPercent, bounds: clipped, workArea: clipped,
                                   origin: CGPoint(x: l + Int(clipped.left - full.left), y: t + Int(clipped.top - full.top)))
            }
            guard !list.contains(where: { Self.overlaps($0.bounds, m.bounds) }) else { continue }
            m.workArea = Self.workArea(of: m)
            list.append(m)
        }
        if list.isEmpty { list = [primary] }
        return ScalingLayout(monitors: list, width: width, height: height, settings: settings, rule: rule, note: note)
    }

    // MARK: Logging

    /// One line per monitor plus the session size and limits.
    public var logLines: [String] {
        var lines = ["scaling: settings \(settings); session \(width)x\(height) px; limits: \(ScalingLimits.summary)"]
        for (i, m) in monitors.enumerated() {
            lines.append("scaling: monitor \(i): \(Int(m.frame.minX)),\(Int(m.frame.minY)) \(Int(m.frame.width))x\(Int(m.frame.height)) pt, backing \(m.backingScale)"
                         + " → \(m.scale)x, Windows \(m.windowsPercent) %, px \(m.bounds.left),\(m.bounds.top) \(m.bounds.width)x\(m.bounds.height),"
                         + " work \(m.workArea.left),\(m.workArea.top) \(m.workArea.width)x\(m.workArea.height)")
        }
        if let note { lines.append("scaling: \(note)") }
        return lines
    }
}
