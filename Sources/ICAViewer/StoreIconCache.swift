import AppKit
import ImageIO
import ICAKit

extension Notification.Name {
    /// The store changed or an icon finished loading; observers (launcher rows, Dock icon) look again.
    static let storeIconsChanged = Notification.Name("ICAStoreIconsChanged")
}

/// The store's resource icons (docs/99 Phase 0): fetched lazily on first use, cached in memory and under
/// ~/Library/Caches/ICAViewer/icons (0600), shared by the Dock icon and the launcher rows.
/// Main thread only, like the session controller.
final class StoreIconCache {
    static let shared = StoreIconCache()

    private var store: StoreClient?
    private var images: [String: CGImage] = [:]          // cache file name (store base + iconurl) → decoded image
    private var inflight: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private let retryAfter: TimeInterval = 300

    /// The store the icon URLs belong to (they are relative to its base).
    func register(store: StoreClient) {
        self.store = store
        NotificationCenter.default.post(name: .storeIconsChanged, object: self)
    }

    /// The decoded icon if it is cached; otherwise nil, and a fetch starts (once; failures retry after
    /// 5 minutes). `.storeIconsChanged` is posted when it arrives.
    func image(forIconURL iconurl: String) -> CGImage? {
        guard let store else { return nil }
        let name = StoreIconIndex.cacheFileName(base: store.base, iconurl: iconurl)
        if let image = images[name] { return image }
        let file = Self.cacheDirectory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            images[name] = image
            return image
        }
        if !inflight.contains(name), failedAt[name].map({ Date().timeIntervalSince($0) > retryAfter }) ?? true,
           let url = URL(string: iconurl, relativeTo: store.base)?.absoluteURL {
            inflight.insert(name)
            Task { @MainActor [self] in
                defer { inflight.remove(name) }
                guard let response = try? await store.http.send("GET", url, headers: ["Accept": "image/png,image/*"]),
                      response.status == 200, response.body.count <= 4 << 20, let image = Self.decode(response.body) else {
                    failedAt[name] = Date()
                    return
                }
                images[name] = image
                Self.write(response.body, to: file)
                NotificationCenter.default.post(name: .storeIconsChanged, object: self)
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
