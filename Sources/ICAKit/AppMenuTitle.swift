import Foundation

/// The name the menu bar shows for the key remote application (docs/99 Phase 0).
public enum AppMenuTitle {
    /// The store resource a remote app belongs to (first candidate name that matches a resource, by
    /// `StoreIconIndex.normalize`), else the first non-empty candidate (the TWI app name). nil without
    /// candidates. Session entries and disabled resources are not matched.
    public static func name(resources: [StoreClient.Resource], candidates: [String]) -> String? {
        let usable = resources.filter { !$0.isSession && $0.disabled != true }
        for candidate in candidates {
            let key = StoreIconIndex.normalize(candidate)
            if !key.isEmpty, let r = usable.first(where: { StoreIconIndex.normalize($0.name) == key }) { return r.name }
        }
        return candidates.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// `title` on one line, at most `limit` characters (the menu bar is short); longer ones end in an ellipsis.
    public static func clamped(_ title: String, limit: Int = 40) -> String {
        let line = title.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard line.count > limit, limit > 1 else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
