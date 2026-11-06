import AppKit
import ImageIO
import ICAKit

/// Dock phase 0 (docs/99): the app's single Dock tile and Cmd-Tab icon show the icon of the remote
/// app whose window is key; any other key window (launcher, settings, Connection Center) or none shows
/// the normal ICA Viewer icon. Only `NSApp.applicationIconImage` changes: window ownership, AX roles,
/// window numbers and activation stay as they are. ICA_DOCK_ICON=0 turns it off.
///
/// Icon source: the store's resource icon (fetched lazily, cached in memory and under
/// ~/Library/Caches/ICAViewer/icons) unless the TWI window icon is larger; until it arrives, the TWI icon.
/// Main thread only, like the session controller.
final class DockIcon {
    static let shared = DockIcon()
    static let enabled = ProcessInfo.processInfo.environment["ICA_DOCK_ICON"] != "0"

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

    // Store icons.
    private var store: StoreClient?
    private var index: [String: String] = [:]
    private var images: [String: CGImage] = [:]          // iconurl → decoded image
    private var inflight: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private let retryAfter: TimeInterval = 300

    /// Called whenever the key window, the app's activation or an app's windows or icons change.
    func scheduleRefresh() {
        guard Self.enabled else { return }
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// The store's resource list arrived (names → icon URLs); icons load when first needed.
    func register(resources: [StoreClient.Resource], store: StoreClient) {
        guard Self.enabled else { return }
        self.store = store
        index = StoreIconIndex.index(resources)
        scheduleRefresh()
    }

    private func refresh() {
        work = nil
        var remote = (NSApp.keyWindow as? SeamlessWindow)?.remote
        if remote == nil, !NSApp.isActive, NSApp.keyWindow == nil,
           let last = lastRemote, last.window.isVisible || last.window.isMiniaturized {
            remote = last      // another app is in front: keep the last remote app's icon
        }
        lastRemote = remote
        guard let remote, let source = remote.controller?.dockSource(for: remote) else { return show(nil, nil) }
        if let url = StoreIconIndex.iconURL(in: index, names: source.names), let store {
            let stored = storeImage(url, store: store)
            if let stored, stored.width >= (source.twi?.width ?? 0) { return show(source.key, ("store", stored)) }
        }
        if let twi = source.twi { return show(source.key, ("twi \(twi.width)x\(twi.height) \(twi.hashValue)", twi)) }
        show(nil, nil)
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

    // MARK: Store icon cache

    private func storeImage(_ iconurl: String, store: StoreClient) -> CGImage? {
        if let image = images[iconurl] { return image }
        let file = Self.cacheDirectory.appendingPathComponent(StoreIconIndex.cacheFileName(base: store.base, iconurl: iconurl))
        if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            images[iconurl] = image
            return image
        }
        if !inflight.contains(iconurl), failedAt[iconurl].map({ Date().timeIntervalSince($0) > retryAfter }) ?? true,
           let url = URL(string: iconurl, relativeTo: store.base)?.absoluteURL {
            inflight.insert(iconurl)
            Task { @MainActor [self] in
                defer { inflight.remove(iconurl) }
                guard let response = try? await store.http.send("GET", url, headers: ["Accept": "image/png,image/*"]),
                      response.status == 200, response.body.count <= 4 << 20, let image = Self.decode(response.body) else {
                    failedAt[iconurl] = Date()
                    return
                }
                images[iconurl] = image
                Self.write(response.body, to: file)
                scheduleRefresh()
            }
        }
        return nil
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (1...2048).contains(image.width), (1...2048).contains(image.height) else { return nil }
        return image
    }

    private static let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("ICAViewer", isDirectory: true).appendingPathComponent("icons", isDirectory: true)
    }()

    private static func write(_ data: Data, to file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
