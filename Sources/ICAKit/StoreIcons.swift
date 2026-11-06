import Foundation
import CryptoKit

/// Maps remote application names to the store's resource icon URLs (docs/99 Phase 0: the Dock icon
/// follows the key remote app, and the store's icon is sharper than the small TWI window icons).
public enum StoreIconIndex {
    /// Name key for matching a TWI app name to a resource name: case, spacing and a trailing `.exe` ignored.
    public static func normalize(_ name: String) -> String {
        var s = name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.hasSuffix(".exe") { s.removeLast(4) }
        return s
    }

    /// Normalised resource name → `iconurl`, for resources that have one. The first of equal names wins.
    public static func index(_ resources: [StoreClient.Resource]) -> [String: String] {
        var out: [String: String] = [:]
        for r in resources {
            guard let url = r.iconurl, !url.isEmpty, !r.isSession else { continue }
            let key = normalize(r.name)
            if out[key] == nil { out[key] = url }
        }
        return out
    }

    /// The icon URL of the first candidate name the index knows.
    public static func iconURL(in index: [String: String], names: [String]) -> String? {
        for name in names {
            if let url = index[normalize(name)] { return url }
        }
        return nil
    }

    /// Stable cache file name for an icon of a store: SHA-256 of `<base>|<iconurl>`, so different stores
    /// never share a file.
    public static func cacheFileName(base: URL, iconurl: String) -> String {
        let digest = SHA256.hash(data: Data("\(base.absoluteString)|\(iconurl)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }
}
