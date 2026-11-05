import Foundation

public enum TWIWindowKind: Equatable, Sendable {
    /// Taskbar entry or captioned dialog: becomes a real NSWindow.
    case appWindow
    /// Menu, tooltip, tool window, no-activate window: non-activating panel.
    case popup
    /// Not visible.
    case hidden
}

public struct TWIWindowChange: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let title = TWIWindowChange(rawValue: 1 << 0)
    public static let style = TWIWindowChange(rawValue: 1 << 1)
    public static let windowRect = TWIWindowChange(rawValue: 1 << 2)
    public static let clientRect = TWIWindowChange(rawValue: 1 << 3)
    public static let owner = TWIWindowChange(rawValue: 1 << 4)
    public static let kind = TWIWindowChange(rawValue: 1 << 5)
    public static let app = TWIWindowChange(rawValue: 1 << 6)
    public static let flags = TWIWindowChange(rawValue: 1 << 7)
    public static let zOrder = TWIWindowChange(rawValue: 1 << 8)
    public static let icon = TWIWindowChange(rawValue: 1 << 9)
}

public struct TWIWindow: @unchecked Sendable {
    public var id: UInt32
    public var flags: UInt16
    public var style: UInt32
    public var exStyle: UInt32
    public var windowRect: TWIRect
    public var clientRect: TWIRect
    public var ownerId: UInt32
    public var title: String
    public var isMenu: Bool
    /// Own or inherited from the owner chain; nil when unknown.
    public var processId: UInt32?
    public var appIdString: String?
    /// Last "window above me" value from a change message (semantics unconfirmed, see docs/50 §6.12).
    public var windowAbove: UInt32?
    public var kind: TWIWindowKind
    public var hasTaskbarEntry: Bool
    /// Key of the remote application this window belongs to (see `TWIApp`).
    public var appKey: String
    public var icons: [UInt32: TWIIcon] = [:]
    /// Icon type received first; it is the one to display.
    public var primaryIconType: UInt32?

    public var icon: TWIIcon? { primaryIconType.flatMap { icons[$0] } }
    public var isVisible: Bool { style & TWIStyle.visible != 0 }
    public var isMinimized: Bool { style & TWIStyle.minimize != 0 }
    public var isMaximized: Bool { style & TWIStyle.maximize != 0 }
    public var isDisabled: Bool { style & TWIStyle.disabled != 0 }
    public var isTopmost: Bool { exStyle & TWIStyle.exTopmost != 0 }
    public var isResizable: Bool { style & TWIStyle.thickFrame != 0 }
}

/// A remote application: a group of top-level windows.
public struct TWIApp: Equatable, Sendable {
    public var key: String
    public var name: String
    /// Published application name from the `#Name` form of the process app-name string.
    public var publishedName: String?
    public var appId: String?
    public var executablePath: String?
    /// Windows of kind `.appWindow`, in creation order.
    public var windowIds: [UInt32]
}

public enum SeamlessEvent {
    case channelReady(TWIHostInit)
    case seamlessStateChanged(active: Bool)
    case systemMetricsChanged(TWISystemMetrics)
    case appAdded(TWIApp)
    case appChanged(TWIApp)
    case appRemoved(TWIApp)
    case windowAdded(TWIWindow)
    case windowChanged(TWIWindow, TWIWindowChange)
    case windowRemoved(TWIWindow)
    /// Host focus: nil when no remote window is in the foreground.
    case windowActivated(UInt32?)
    case iconChanged(windowId: UInt32, TWIIcon)
    case processCreated(TWIProcessInfo)
    case processEnded(processId: UInt32)
    /// The window list is about to be cleared (OPEN, RESUME, CLOSE); the host usually re-announces the
    /// same windows right after, so a UI may keep its windows briefly and reuse them by id.
    case windowsReset
}

/// Window list state machine (docs/50 §4). Feed it host messages with `apply`; it publishes `SeamlessEvent`s.
/// Not thread-safe; call from one queue.
public final class WindowModel {
    public var onEvent: ((SeamlessEvent) -> Void)?
    /// A change arrived for an unknown window without a full field set: send RESEND_WINDOW.
    public var onResendNeeded: ((UInt32) -> Void)?
    /// A window with a taskbar entry was created minimised (the reference client sends RESTORE).
    public var onMinimizedCreated: ((UInt32) -> Void)?

    public private(set) var windows: [UInt32: TWIWindow] = [:]
    public private(set) var creationOrder: [UInt32] = []
    public private(set) var apps: [String: TWIApp] = [:]
    public private(set) var processes: [UInt32: TWIProcessInfo] = [:]
    public private(set) var endedProcesses: Set<UInt32> = []
    public private(set) var foregroundWindow: UInt32?
    /// Last non-zero foreground window, to re-activate when the client regains focus.
    public private(set) var lastForegroundWindow: UInt32?
    public private(set) var droppedIconCount = 0

    private var pendingIcons: [UInt32: [(UInt32, TWIIcon)]] = [:]
    private var events: [SeamlessEvent] = []

    public init() {}

    public var orderedWindows: [TWIWindow] { creationOrder.compactMap { windows[$0] } }

    public static let noGroup = "_NONE_"
    public static let sessionAppKey = "session"

    // MARK: Classification

    /// Taskbar entry rules (docs/50 §4.3).
    public static func hasTaskbarEntry(style: UInt32, exStyle: UInt32, ownerId: UInt32, isMenu: Bool) -> Bool {
        if style & TWIStyle.visible == 0 { return false }
        if isMenu { return false }
        if exStyle & TWIStyle.exToolWindow != 0 { return false }
        if exStyle & TWIStyle.exNoActivate != 0 && exStyle & TWIStyle.exAppWindow == 0 { return false }
        if ownerId == 0 { return true }
        return exStyle & TWIStyle.exAppWindow != 0
    }

    public static func classify(style: UInt32, exStyle: UInt32, ownerId: UInt32, isMenu: Bool) -> (kind: TWIWindowKind, taskbar: Bool) {
        let taskbar = hasTaskbarEntry(style: style, exStyle: exStyle, ownerId: ownerId, isMenu: isMenu)
        if style & TWIStyle.visible == 0 { return (.hidden, taskbar) }
        if taskbar { return (.appWindow, true) }
        // Owned, captioned, ordinary window: a dialog.
        if !isMenu, ownerId != 0, style & TWIStyle.caption == TWIStyle.caption,
           exStyle & (TWIStyle.exToolWindow | TWIStyle.exNoActivate) == 0 { return (.appWindow, false) }
        return (.popup, false)
    }

    // MARK: Applying messages

    /// Applies a host window/process message. Returns true if the message was a model message.
    @discardableResult
    public func apply(_ message: TWIHostMessage) -> Bool {
        switch message {
        case .create(let c): create(c)
        case .destroy(let id): destroy(id)
        case .change(let c): change(c)
        case .foreground(let id): foreground(id)
        case .windowIcon(let id, let type, let blob): setIcon(windowId: id, type: type, blob: blob)
        case .processCreated(let p): processCreated(p)
        case .processEnded(let pid, _): processEnded(pid)
        default: return false
        }
        flush()
        return true
    }

    /// Completed icon (single message or reassembled chunks).
    public func setIcon(windowId: UInt32, type: UInt32, blob: Data) {
        let icon = TWIIcon(type: type, blob: blob)
        guard var w = windows[windowId] else {
            pendingIcons[windowId, default: []].append((type, icon))
            droppedIconCount += 1
            return
        }
        store(icon, in: &w)
        windows[windowId] = w
        events.append(.windowChanged(w, .icon))
        events.append(.iconChanged(windowId: windowId, icon))
        flush()
    }

    /// Clears all windows (OPEN, RESUME, CLOSE). Processes are kept.
    public func reset() {
        let removed = orderedWindows
        if !removed.isEmpty { events.append(.windowsReset) }
        windows.removeAll(); creationOrder.removeAll(); pendingIcons.removeAll()
        let hadForeground = foregroundWindow != nil
        foregroundWindow = nil
        for w in removed { events.append(.windowRemoved(w)) }
        if hadForeground { events.append(.windowActivated(nil)) }
        flush()
    }

    /// Full reset including processes.
    public func resetAll() {
        processes.removeAll(); endedProcesses.removeAll(); lastForegroundWindow = nil
        reset()
    }

    private func store(_ icon: TWIIcon, in w: inout TWIWindow) {
        w.icons[icon.type] = icon
        if w.primaryIconType == nil { w.primaryIconType = icon.type }
    }

    private func create(_ c: TWICreate) {
        guard c.id != 0, windows[c.id] == nil else { return }
        var pid: UInt32? = (c.processId ?? 0) == 0 ? nil : c.processId
        var appId: String? = (c.appId?.isEmpty ?? true) ? nil : c.appId
        if let owner = windows[c.ownerId], c.ownerId != 0 {
            if pid == nil { pid = owner.processId }
            if appId == nil { appId = owner.appIdString }
        }
        let isMenu = c.source == .menu
        let cls = Self.classify(style: c.style, exStyle: c.exStyle, ownerId: c.ownerId, isMenu: isMenu)
        var w = TWIWindow(
            id: c.id, flags: c.flags, style: c.style, exStyle: c.exStyle, windowRect: c.windowRect,
            clientRect: c.clientRect, ownerId: c.ownerId, title: c.title ?? "", isMenu: isMenu, processId: pid,
            appIdString: appId, windowAbove: nil, kind: cls.kind, hasTaskbarEntry: cls.taskbar, appKey: Self.sessionAppKey)
        w.appKey = groupKey(for: w).key
        if let icons = pendingIcons.removeValue(forKey: c.id) {
            for (_, icon) in icons { store(icon, in: &w) }
        }
        windows[c.id] = w
        creationOrder.append(c.id)
        events.append(.windowAdded(w))
        if w.isMinimized && w.hasTaskbarEntry { onMinimizedCreated?(c.id) }
        inheritUnresolved()
    }

    /// Owned windows created before their owner pick up its process/app-id once it exists.
    private func inheritUnresolved() {
        for id in creationOrder {
            guard var w = windows[id], w.ownerId != 0, w.processId == nil || w.appIdString == nil,
                  let owner = windows[w.ownerId] else { continue }
            if w.processId == nil { w.processId = owner.processId }
            if w.appIdString == nil { w.appIdString = owner.appIdString }
            let key = groupKey(for: w).key
            var changes: TWIWindowChange = []
            if key != w.appKey { w.appKey = key; changes.insert(.app) }
            windows[id] = w
            if !changes.isEmpty { events.append(.windowChanged(w, changes)) }
        }
    }

    private func destroy(_ id: UInt32) {
        guard let w = windows.removeValue(forKey: id) else { return }
        creationOrder.removeAll { $0 == id }
        if foregroundWindow == id { foregroundWindow = nil }
        events.append(.windowRemoved(w))
    }

    private func change(_ ch: TWIChange) {
        guard ch.id != 0 else { return }
        guard var w = windows[ch.id] else {
            if ch.mask == .full {
                create(TWICreate(
                    source: .v1, id: ch.id, flags: ch.flags, style: ch.style ?? 0, exStyle: ch.exStyle ?? 0,
                    windowRect: ch.windowRect ?? .zero, clientRect: ch.clientRect ?? .zero, ownerId: ch.ownerId ?? 0,
                    processId: nil, appId: nil, title: ch.title))
            } else {
                onResendNeeded?(ch.id)
            }
            return
        }
        var changes: TWIWindowChange = []
        if w.flags != ch.flags { w.flags = ch.flags; changes.insert(.flags) }
        if let v = ch.style, v != w.style { w.style = v; changes.insert(.style) }
        if let v = ch.exStyle, v != w.exStyle { w.exStyle = v; changes.insert(.style) }
        if let v = ch.windowRect, v != w.windowRect { w.windowRect = v; changes.insert(.windowRect) }
        if let v = ch.clientRect, v != w.clientRect { w.clientRect = v; changes.insert(.clientRect) }
        if let v = ch.ownerId, v != w.ownerId { w.ownerId = v; changes.insert(.owner) }
        if let v = ch.windowAbove, v != w.windowAbove { w.windowAbove = v; changes.insert(.zOrder) }
        if let v = ch.title, v != w.title { w.title = v; changes.insert(.title) }
        if changes.contains(.style) || changes.contains(.owner) {
            let cls = Self.classify(style: w.style, exStyle: w.exStyle, ownerId: w.ownerId, isMenu: w.isMenu)
            if cls.kind != w.kind { w.kind = cls.kind; changes.insert(.kind) }
            w.hasTaskbarEntry = cls.taskbar
        }
        if changes.contains(.owner), let owner = windows[w.ownerId] {
            if w.processId == nil { w.processId = owner.processId }
            if w.appIdString == nil { w.appIdString = owner.appIdString }
        }
        let key = groupKey(for: w).key
        if key != w.appKey { w.appKey = key; changes.insert(.app) }
        windows[ch.id] = w
        if !changes.isEmpty { events.append(.windowChanged(w, changes)) }
    }

    private func foreground(_ id: UInt32) {
        let new: UInt32? = id == 0 ? nil : id
        if let n = new { lastForegroundWindow = n }
        guard new != foregroundWindow else { return }
        foregroundWindow = new
        events.append(.windowActivated(new))
    }

    private func processCreated(_ p: TWIProcessInfo) {
        processes[p.processId] = p
        endedProcesses.remove(p.processId)
        events.append(.processCreated(p))
        for id in creationOrder {
            guard var w = windows[id] else { continue }
            let key = groupKey(for: w).key
            if key != w.appKey {
                w.appKey = key
                windows[id] = w
                events.append(.windowChanged(w, .app))
            }
        }
    }

    /// The process entry stays so that windows keep their group; it is marked as ended.
    private func processEnded(_ pid: UInt32) {
        endedProcesses.insert(pid)
        events.append(.processEnded(processId: pid))
    }

    // MARK: Grouping (docs/50 §5.2)

    /// Published application name: text after `#` in the process app-name string.
    static func publishedName(_ p: TWIProcessInfo) -> String? {
        let parts = p.appName.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    static func executableName(_ path: String) -> String {
        var name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
        if name.lowercased().hasSuffix(".exe") { name.removeLast(4) }
        return name
    }

    struct GroupInfo { var key: String; var name: String; var published: String?; var appId: String?; var exe: String? }

    func groupKey(for w: TWIWindow) -> GroupInfo {
        // 1. Published-app name of the process or its nearest ancestor.
        var pid = w.processId
        var hops = 0
        while let current = pid, hops < 32, let p = processes[current] {
            if let name = Self.publishedName(p) {
                return GroupInfo(key: "app:" + name, name: name, published: name, appId: nil,
                                 exe: processes[w.processId ?? 0]?.executablePath)
            }
            pid = p.parentId == current || p.parentId == 0 ? nil : p.parentId
            hops += 1
        }
        // 2. App-id string.
        if let id = w.appIdString, !id.isEmpty, id != Self.noGroup {
            return GroupInfo(key: "aumid:" + id, name: id, published: nil, appId: id,
                             exe: w.processId.flatMap { processes[$0]?.executablePath })
        }
        // 3. Executable path.
        // Display name: string A (live: the executable's file description, e.g. "Windows-Rechner"), else the exe stem.
        if let pid = w.processId, let p = processes[pid], !p.executablePath.isEmpty {
            let name = p.stringA.isEmpty ? Self.executableName(p.executablePath) : p.stringA
            return GroupInfo(key: "exe:" + p.executablePath.lowercased(), name: name,
                             published: nil, appId: nil, exe: p.executablePath)
        }
        // 5. Fallback: the session itself.
        return GroupInfo(key: Self.sessionAppKey, name: "Remote Application", published: nil, appId: nil, exe: nil)
    }

    private func currentApps() -> [String: TWIApp] {
        var result: [String: TWIApp] = [:]
        for id in creationOrder {
            guard let w = windows[id], w.kind == .appWindow else { continue }
            let g = groupKey(for: w)
            if var app = result[g.key] {
                app.windowIds.append(id)
                result[g.key] = app
            } else {
                result[g.key] = TWIApp(key: g.key, name: g.name, publishedName: g.published, appId: g.appId,
                                       executablePath: g.exe, windowIds: [id])
            }
        }
        return result
    }

    /// Publishes pending events, adding app add/change/remove around them.
    private func flush() {
        let new = currentApps()
        var added: [SeamlessEvent] = [], changed: [SeamlessEvent] = [], removed: [SeamlessEvent] = []
        for key in new.keys.sorted() {
            let app = new[key]!
            if let old = apps[key] {
                if old.name != app.name || old.publishedName != app.publishedName || old.executablePath != app.executablePath
                    || old.appId != app.appId { changed.append(.appChanged(app)) }
            } else { added.append(.appAdded(app)) }
        }
        for key in apps.keys.sorted() where new[key] == nil { removed.append(.appRemoved(apps[key]!)) }
        apps = new
        let all = added + events + changed + removed
        events = []
        guard let cb = onEvent else { return }
        for e in all { cb(e) }
    }

    /// Emits events recorded outside `apply` (used by the engine).
    func publish(_ event: SeamlessEvent) {
        events.append(event)
        flush()
    }

    /// Best icon for an application: the largest decoded icon over its windows.
    public func icon(forApp key: String) -> TWIIcon? {
        var best: TWIIcon?
        for w in windows.values where w.appKey == key && w.kind == .appWindow {
            for icon in w.icons.values where icon.image != nil {
                if icon.width > (best?.width ?? 0) { best = icon }
            }
        }
        return best
    }
}
