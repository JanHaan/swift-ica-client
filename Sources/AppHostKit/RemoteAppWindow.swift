import AppKit

/// The window of a remote app window (taskbar entry or owned dialog, docs/50 §5.1, D189), in the main process
/// (`SeamlessWindow`) and in the helper apps (`SurfaceWindow`).
///
/// It is borderless: a titled window gets rounded corners (16 pt on macOS 26) that cut off the square frame the
/// Windows app draws itself (its 1 px accent border, D189), and the private ways of squaring a titled window
/// (`_cornerMask`, `_cornerRadius`, `_setCornerRadius:`, the theme frame's layer) all stayed rounded on macOS 26.
/// A borderless window lacks what AppKit gives a titled one for free, and switchers need it, so this class adds it:
/// - AX subrole `AXStandardWindow` (a borderless window has none) for Cmd-` and third-party switchers;
/// - AXCloseButton, AXMinimizeButton and AXZoomButton (`StandardButtonElement`), which switchers press;
/// - `performClose`, `performMiniaturize`, `performZoom`, which AppKit refuses (beep) without the buttons;
/// - an entry in the Window menu and the Dock's window list (AppKit adds none for a borderless window, nor
///   follows its title);
/// - the light appearance: under Dark Mode the window server draws a dark outline and a light inner rim along
///   the edge, over the app's own 1 px border.
/// A titled window of this class (the full desktop session, the helper spike) keeps AppKit's behaviour.
open class RemoteAppWindow: NSWindow {
    /// Style for a remote app window: borderless, closable and miniaturizable (minimize and the Dock need the
    /// flags), resizable as the remote window is.
    public static func styleMask(resizable: Bool) -> NSWindow.StyleMask {
        var style: NSWindow.StyleMask = [.borderless, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        return style
    }

    /// Borderless (an app window), not titled (desktop session, spike).
    public var isSquare: Bool { !styleMask.contains(.titled) }

    /// Whether the AX zoom button works (maximise box of the remote window, main process); a titled window uses its
    /// own zoom button.
    public var zoomEnabled = false {
        didSet { standardWindowButton(.zoomButton)?.isEnabled = zoomEnabled }
    }

    private var windowsMenu = WindowsMenuMembership()

    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        if isSquare {
            appearance = NSAppearance(named: .aqua)
            hasShadow = true
        }
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { true }

    // MARK: Accessibility

    private lazy var closeElement = StandardButtonElement(.closeButton, window: self, enabled: { [weak self] in self?.styleMask.contains(.closable) ?? false }) { [weak self] in self?.performClose(nil) }
    private lazy var minimizeElement = StandardButtonElement(.minimizeButton, window: self, enabled: { [weak self] in self?.styleMask.contains(.miniaturizable) ?? false }) { [weak self] in self?.performMiniaturize(nil) }
    private lazy var zoomElement = StandardButtonElement(.zoomButton, window: self, enabled: { [weak self] in self?.zoomEnabled ?? false }) { [weak self] in self?.performZoom(nil) }

    open override func accessibilityRole() -> NSAccessibility.Role? { isSquare ? .window : super.accessibilityRole() }
    open override func accessibilitySubrole() -> NSAccessibility.Subrole? { isSquare ? .standardWindow : super.accessibilitySubrole() }
    open override func accessibilityCloseButton() -> Any? { isSquare ? closeElement : super.accessibilityCloseButton() }
    open override func accessibilityMinimizeButton() -> Any? { isSquare ? minimizeElement : super.accessibilityMinimizeButton() }
    open override func accessibilityZoomButton() -> Any? { isSquare ? zoomElement : super.accessibilityZoomButton() }
    open override func accessibilityChildren() -> [Any]? {
        guard isSquare else { return super.accessibilityChildren() }
        return [closeElement, minimizeElement, zoomElement] + (super.accessibilityChildren() ?? [])
    }

    // MARK: What the buttons do (AppKit beeps for a borderless window)

    open override func performClose(_ sender: Any?) {
        guard isSquare else { return super.performClose(sender) }
        guard styleMask.contains(.closable) else { return NSSound.beep() }
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }

    open override func performMiniaturize(_ sender: Any?) {
        guard isSquare else { return super.performMiniaturize(sender) }
        guard styleMask.contains(.miniaturizable) else { return NSSound.beep() }
        miniaturize(sender)
    }

    open override func performZoom(_ sender: Any?) {
        guard isSquare else { return super.performZoom(sender) }
        guard zoomEnabled else { return NSSound.beep() }
        zoom(sender)
    }

    // MARK: Window menu and the Dock's window list

    open override var title: String {
        didSet { if windowsMenu.isListed { NSApp.changeWindowsItem(self, title: title, filename: false) } }
    }

    open override var isExcludedFromWindowsMenu: Bool {
        didSet { syncWindowsMenu() }
    }

    open override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        syncWindowsMenu()
    }

    open override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        syncWindowsMenu()
    }

    open override func orderFrontRegardless() {
        super.orderFrontRegardless()
        syncWindowsMenu()
    }

    open override func close() {
        super.close()
        windowsMenu.closed = true
        syncWindowsMenu()
    }

    private func syncWindowsMenu() {
        switch windowsMenu.update(square: isSquare, shown: isVisible || isMiniaturized, excluded: isExcludedFromWindowsMenu) {
        case .add: NSApp.addWindowsItem(self, title: title, filename: false)
        case .remove: NSApp.removeWindowsItem(self)
        case .none: break
        }
    }
}

/// Whether a borderless remote window is listed in the Window menu (and so in the Dock's window list): from its
/// first showing until it is excluded (shown by a helper app) or closed. A titled window is AppKit's business.
public struct WindowsMenuMembership: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case add, remove, none }
    public private(set) var isListed = false
    public var closed = false

    public init() {}

    public mutating func update(square: Bool, shown: Bool, excluded: Bool) -> Action {
        let want = square && !excluded && !closed && (shown || isListed)
        if want == isListed { return .none }
        isListed = want
        return want ? .add : .remove
    }
}

/// A standard window button of a borderless window, for Accessibility only (it is never drawn): switchers read
/// AXCloseButton, AXMinimizeButton and AXZoomButton and press them.
public final class StandardButtonElement: NSAccessibilityElement {
    private weak var window: NSWindow?
    private let enabled: () -> Bool
    private let press: () -> Void
    private let index: Int

    public init(_ subrole: NSAccessibility.Subrole, window: NSWindow?, enabled: @escaping () -> Bool, press: @escaping () -> Void) {
        self.window = window
        self.enabled = enabled
        self.press = press
        index = [NSAccessibility.Subrole.closeButton, .minimizeButton, .zoomButton].firstIndex(of: subrole) ?? 0
        super.init()
        setAccessibilityRole(.button)
        setAccessibilitySubrole(subrole)
        setAccessibilityParent(window)
    }

    public override func isAccessibilityEnabled() -> Bool { enabled() }

    public override func accessibilityPerformPress() -> Bool {
        guard enabled() else { return false }
        press()
        return true
    }

    /// Where a titled window has its traffic lights (screen coordinates), so tools that look at the frame find
    /// the buttons in the window's top-left corner.
    public override func accessibilityFrame() -> NSRect {
        guard let frame = window?.frame else { return .zero }
        return NSRect(x: frame.minX + 8 + CGFloat(index) * 20, y: frame.maxY - 8 - 14, width: 14, height: 14)
    }
}
