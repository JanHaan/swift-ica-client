import CryptoKit
import Foundation

/// Identity of one generated helper app (docs/99 §3, §6): the stable app key decides the bundle id and
/// the directory, the name is what the Dock, Cmd-Tab and the menu bar show.
public struct HelperLabel: Equatable, Sendable {
    /// Stable app key (normalised published name, else appId, else executable path). Only its hash
    /// leaves memory: bundle id and directory name.
    public var key: String
    /// Display name, e.g. "Microsoft Outlook".
    public var name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// Pure parts of the bundle generator: naming, paths and the Info.plist rewrite (docs/99 §6).
///
/// Layout: `<apps>/<key hash>/<Name>.app`. The Dock and Cmd-Tab label of an app without localized
/// display names is its **file name**, not CFBundleName, so the bundle is named after the app; the
/// key-hash directory keeps the path stable per app and makes a rename a new bundle in the same place.
public enum HelperBundle {
    public static let bundleIdPrefix = "local.alttab.ICAViewer.app."
    public static let iconFile = "AppIcon"
    // Custom Info.plist keys that decide whether an existing bundle is current.
    public static let templateHashKey = "ICATemplateHash"
    public static let iconHashKey = "ICAIconHash"
    public static let keyHashKey = "ICAKeyHash"

    /// First 16 hex digits of SHA-256 over the key's UTF-8 bytes.
    public static func keyHash(_ key: String) -> String {
        hexPrefix(SHA256.hash(data: Data(key.utf8)), 16)
    }

    public static func bundleIdentifier(for label: HelperLabel) -> String {
        bundleIdPrefix + keyHash(label.key)
    }

    /// A file-system-safe bundle name: no path separators or colons (Finder shows ':' as '/'), no
    /// leading dot, no control characters, at most 80 characters; "App" if nothing is left.
    public static func fileName(for name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "App" : cleaned) + ".app"
    }

    /// `<key hash>/<Name>.app`, relative to the apps directory.
    public static func relativePath(for label: HelperLabel) -> String {
        keyHash(label.key) + "/" + fileName(for: label.name)
    }

    /// The template's Info.plist relabelled for one app. Keeps the executable, version and every other
    /// template key; replaces identity and icon, and records the hashes `isCurrent` compares.
    public static func relabel(_ template: [String: Any], label: HelperLabel, templateHash: String,
                               iconHash: String?) -> [String: Any] {
        var info = template
        info["CFBundleIdentifier"] = bundleIdentifier(for: label)
        info["CFBundleName"] = label.name
        info["CFBundleDisplayName"] = label.name
        info["LSMultipleInstancesProhibited"] = true
        info.removeValue(forKey: "CFBundleIconName")       // asset-catalog icon of the template
        if let iconHash {
            info["CFBundleIconFile"] = iconFile
            info[iconHashKey] = iconHash
        } else {
            info.removeValue(forKey: "CFBundleIconFile")
            info.removeValue(forKey: iconHashKey)
        }
        info[templateHashKey] = templateHash
        info[keyHashKey] = keyHash(label.key)
        return info
    }

    /// True when an existing bundle's Info.plist already is what `relabel` would write: same template
    /// build, same name and key, same icon. Then the generator neither copies nor re-signs.
    public static func isCurrent(existing: [String: Any]?, label: HelperLabel, templateHash: String,
                                 iconHash: String?) -> Bool {
        guard let existing else { return false }
        return existing[templateHashKey] as? String == templateHash
            && existing["CFBundleIdentifier"] as? String == bundleIdentifier(for: label)
            && existing["CFBundleName"] as? String == label.name
            && existing[iconHashKey] as? String == iconHash
    }

    /// Fingerprint of a template build: SHA-256 prefix over its Info.plist and main executable, so a
    /// rebuilt template regenerates every helper without a version bump.
    public static func templateHash(templateURL: URL) throws -> String {
        let infoURL = templateURL.appendingPathComponent("Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String else {
            throw HelperBundleError.badTemplate("no CFBundleExecutable in \(infoURL.path)")
        }
        var hasher = SHA256()
        hasher.update(data: infoData)
        hasher.update(data: try Data(contentsOf: templateURL.appendingPathComponent("Contents/MacOS/\(exe)")))
        return hexPrefix(hasher.finalize(), 16)
    }

    public static func hash(_ data: Data) -> String { hexPrefix(SHA256.hash(data: data), 16) }

    private static func hexPrefix(_ digest: SHA256.Digest, _ count: Int) -> String {
        String(digest.map { String(format: "%02x", $0) }.joined().prefix(count))
    }
}

public enum HelperBundleError: Error, CustomStringConvertible {
    case badTemplate(String)
    case codesign(String)
    case icon(String)

    public var description: String {
        switch self {
        case .badTemplate(let s): "bad template: \(s)"
        case .codesign(let s): "codesign: \(s)"
        case .icon(let s): "icon: \(s)"
        }
    }
}
