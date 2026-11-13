import AppHostKit
import AppKit
import ICAKit

/// Dock phase 0 (docs/99): the app's single Dock tile and Cmd-Tab icon show the icon of the remote
/// app whose window is key; any other key window (launcher, settings, Connection Center) or none shows
/// the normal ICA Viewer icon. Only `NSApp.applicationIconImage` changes: window ownership, AX roles,
/// window numbers and activation stay as they are. ICA_DOCK_ICON=0 turns it off.
///
/// The same focus tracker sets the menu-bar application menu title to the key remote app's name (the
/// Dock and Cmd-Tab names come from the bundle and cannot change per process). ICA_MENU_TITLE=0 turns
/// that off alone; ICA_DOCK_ICON=0 turns off both.
///
/// Icon source: the store's resource icon (`StoreIconCache`) unless the TWI window icon is larger; until
/// it arrives, the TWI icon. Main thread only, like the session controller.
final class DockIcon {
    static let shared = DockIcon()
    static let enabled = ProcessInfo.processInfo.environment["ICA_DOCK_ICON"] != "0"
    static let menuTitleEnabled = enabled && ProcessInfo.processInfo.environment["ICA_MENU_TITLE"] != "0"

    /// What a controller knows about the app behind a window.
    struct Source {
        var key: String          // stable app key (TWIApp.key)
        var names: [String]      // candidate resource names, best first (matching only; never shown or logged)
        var twi: CGImage?        // largest decoded TWI icon of the app
    }

    private let debounce: TimeInterval = 0.15
    private var work: DispatchWorkItem?
    /// Last remote window that was key; kept while the app is inactive so Cmd-Tab keeps the app's icon.
    private weak var lastRemote: RemoteWindow?
    /// (app key, source tag) of the icon now set; nil = the normal icon.
    private var shown: (key: String, tag: String)?

    // Store resources: names → icon URLs, and the list for the menu title.
    private var index: [String: String] = [:]
    private var resources: [StoreClient.Resource] = []
    /// The app menu's own titles, kept to restore them; nil until the title was first changed.
    private var originalMenuTitles: (item: String, submenu: String)?
    private var shownMenuTitle: String?

    init() {
        NotificationCenter.default.addObserver(forName: .storeIconsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    /// Called whenever the key window, the app's activation or an app's windows or icons change.
    func scheduleRefresh() {
        guard Self.enabled else { return }
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// The store's resource list arrived (names → icon URLs); icons load when first needed. `store` (its base
    /// URL) selects the remembered app ↔ resource mappings (`RememberedAppResources`).
    func register(resources: [StoreClient.Resource], store: URL? = nil) {
        if let store { RememberedAppResources.shared.store = AppResourceMap.storeID(store) }
        guard Self.enabled else { return }
        self.resources = resources
        index = StoreIconIndex.index(resources)
        scheduleRefresh()
    }

    /// Name and icon for a helper app of this remote app (docs/99 §12): the store resource name if one
    /// matches, else the TWI app name; the store icon unless the TWI icon is larger (as `refresh`). Works
    /// with ICA_DOCK_ICON=0 too (then without store data). The icon may still be loading: nil until then.
    func identity(for source: Source) -> (name: String?, icon: CGImage?) {
        let name = AppMenuTitle.name(resources: resources, candidates: source.names)
        if let url = StoreIconIndex.iconURL(in: index, names: source.names),
           let stored = StoreIconCache.shared.image(forIconURL: url), stored.width >= (source.twi?.width ?? 0) {
            return (name, stored)
        }
        return (name, source.twi)
    }

    private func refresh() {
        work = nil
        var remote = (NSApp.keyWindow as? SeamlessWindow)?.remote
        if remote == nil, !NSApp.isActive, NSApp.keyWindow == nil,
           let last = lastRemote, last.window.isVisible || last.window.isMiniaturized {
            remote = last      // another app is in front: keep the last remote app's icon
        }
        lastRemote = remote
        guard let remote, let source = remote.controller?.dockSource(for: remote) else {
            setMenuTitle(nil)
            return show(nil, nil)
        }
        setMenuTitle(AppMenuTitle.name(resources: resources, candidates: source.names))
        if let url = StoreIconIndex.iconURL(in: index, names: source.names) {
            let stored = StoreIconCache.shared.image(forIconURL: url)
            if let stored, stored.width >= (source.twi?.width ?? 0) { return show(source.key, ("store", stored)) }
        }
        if let twi = source.twi { return show(source.key, ("twi \(twi.width)x\(twi.height) \(twi.hashValue)", twi)) }
        show(nil, nil)
    }

    /// The bold application menu title: the remote app's name (censored like the other UI names), or the
    /// menu's own title again for nil. Only titles change; the menu's items stay.
    private func setMenuTitle(_ name: String?) {
        guard Self.menuTitleEnabled, let item = NSApp.mainMenu?.items.first else { return }
        let title = name.map { AppMenuTitle.clamped(displayName($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard title != shownMenuTitle else { return }
        if originalMenuTitles == nil { originalMenuTitles = (item.title, item.submenu?.title ?? "") }
        shownMenuTitle = title
        item.title = title ?? originalMenuTitles?.item ?? ""
        item.submenu?.title = title ?? originalMenuTitles?.submenu ?? ""
        vlog(title == nil ? "menu title: normal" : "menu title: remote app")
    }

    private func show(_ key: String?, _ icon: (tag: String, image: CGImage)?) {
        guard let key, let icon else {
            if shown != nil { shown = nil; NSApp.applicationIconImage = nil; vlog("dock icon: normal") }
            return
        }
        if let shown, shown.key == key, shown.tag == icon.tag { return }
        guard let canvas = IconCanvas.render(icon.image) else { return }
        shown = (key, icon.tag)
        NSApp.applicationIconImage = NSImage(cgImage: canvas, size: NSSize(width: 128, height: 128))
        vlog("dock icon: remote app (\(icon.tag == "store" ? "store" : "TWI") icon, \(icon.image.width) px)")
    }
}

/// TWI app key → published resource learnt by session sharing, remembered per store across runs (`AppResourceMap`,
/// 0600 in the app's support folder), so a later run names and icons that app right even when it is not launched
/// by a shared launch (docs/99 §12.15). Main thread only.
final class RememberedAppResources {
    static let shared = RememberedAppResources()
    /// The current store (`AppResourceMap.storeID`), set when its resource list arrives; nil = nothing is read or written.
    var store: String?
    private var map = AppResourceMap.load(from: AppResourceMap.defaultURL)

    /// At start: an older or hand-edited file may hold system-process entries; `load` dropped them, the file follows.
    init() {
        let url = AppResourceMap.defaultURL
        guard FileManager.default.fileExists(atPath: url.path), AppResourceMap.load(from: url) != rawMap(url) else { return }
        save()
    }

    private func rawMap(_ url: URL) -> AppResourceMap? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppResourceMap.self, from: data)
    }

    func resource(for key: String) -> String? {
        guard let store else { return nil }
        return map.resource(store: store, key: key)
    }

    /// Session sharing found that `key` is `resource`, and the app kept its window (confirmed).
    func remember(_ key: String, is resource: String, executable: String?) {
        guard let store, map.remember(store: store, key: key, resource: resource, executable: executable) else { return }
        vlog("app resources: remembered \(logName(key)) as \(logName(resource))")
        save()
    }

    /// The app named itself (TWI published name): other keys remembered for that resource are dropped.
    func confirm(_ key: String, publishedName: String) {
        guard let store, map.confirm(store: store, key: key, publishedName: publishedName) else { return }
        save()
    }

    private func save() {
        do { try map.save(to: AppResourceMap.defaultURL) } catch { vlog("app resources: not saved (\(error))") }
    }
}
