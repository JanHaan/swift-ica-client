import Foundation

/// Where finished session files go when they cannot be put on the Mac clipboard (docs/75 §11.5): out of the staging
/// folder (removed at quit) into the user's Downloads, under macOS-style unique names ("name 2.zip").
public enum ClipboardFileSaver {
    /// `name`, or "stem 2.ext", "stem 3.ext" … the first that does not exist in `directory`.
    public static func uniqueURL(for name: String, in directory: URL, fileManager fm: FileManager = .default) -> URL {
        func taken(_ url: URL) -> Bool { (try? url.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
        let first = directory.appendingPathComponent(name)
        if !taken(first) { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// Moves every top-level item of the staging `folder` into `destination` (a rename on one volume, else a copy
    /// and delete), then removes the emptied folder. Returns the new URLs; throws if nothing could be moved.
    public static func move(from folder: URL, to destination: URL, fileManager fm: FileManager = .default) throws -> [URL] {
        let names = try fm.contentsOfDirectory(atPath: folder.path).sorted()
        var moved: [URL] = []
        var firstError: Error?
        for name in names {
            let target = uniqueURL(for: name, in: destination, fileManager: fm)
            do {
                try fm.moveItem(at: folder.appendingPathComponent(name), to: target)
                moved.append(target)
            } catch { firstError = firstError ?? error }
        }
        if moved.isEmpty, let firstError { throw firstError }
        if firstError == nil { try? fm.removeItem(at: folder) }
        return moved
    }
}

/// Keeps objects alive while something on screen still points at them (a panel's buttons only hold their target
/// weakly): `keep` on show, `release` on close.
public final class ObjectKeeper {
    private var objects: [ObjectIdentifier: AnyObject] = [:]
    public init() {}
    public var count: Int { objects.count }
    public func keep(_ object: AnyObject) { objects[ObjectIdentifier(object)] = object }
    public func release(_ object: AnyObject) { objects[ObjectIdentifier(object)] = nil }
}
