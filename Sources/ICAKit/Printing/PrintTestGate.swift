import Foundation

/// The safety gate of `icactl printtest` (docs/97 §10 L3/L4): Enter in a print dialog could print on paper
/// if anything but the client's PDF printer is selected, so it is pressed only when every check passes.
///
/// 1. Before Ctrl+P: the host used CTXCPM (at least one ENUM) and sent a printer or driver name containing
///    "PDF" over it. Otherwise no print dialog is opened at all.
/// 2. Before Enter: ICA_PRINTTEST_CONFIRM=1, this run's dialog screenshot was saved, and the orchestrator
///    created `.session/printtest-confirm-<runid>` for **this** run after the screenshot (it viewed it).
///    Anything else, including a timeout, ends with Esc.
public enum PrintTestGate {
    public enum Decision: Equatable, Sendable {
        case proceed
        case refuse(String)
    }

    /// How long the test waits for the confirmation file.
    public static let confirmTimeout: TimeInterval = 120

    public static func newRunID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    public static func confirmFileName(runID: String) -> String { "printtest-confirm-\(runID)" }

    /// Check 1 (before Ctrl+P).
    public static func mayOpenDialog(enumCount: Int, hostNames: [String]) -> Decision {
        guard enumCount >= 1 else { return .refuse("the host sent no CTXCPM ENUM (printing channel not used)") }
        guard hostNames.contains(where: { $0.uppercased().contains("PDF") }) else {
            return .refuse("the host announced no printer or driver named *PDF* over CTXCPM")
        }
        return .proceed
    }

    /// Check 2 (before Enter). `confirmCreated` is the confirmation file's creation (or modification) date,
    /// nil if it does not exist; it must not predate the screenshot.
    public static func mayConfirm(confirmEnv: Bool, dialogGate: Decision, screenshotSaved: Date?, confirmCreated: Date?) -> Decision {
        if case .refuse(let why) = dialogGate { return .refuse(why) }
        guard confirmEnv else { return .refuse("ICA_PRINTTEST_CONFIRM=1 is not set") }
        guard let shot = screenshotSaved else { return .refuse("no dialog screenshot of this run") }
        guard let created = confirmCreated else { return .refuse("no confirmation file for this run") }
        // File-system dates have coarse resolution: allow 1 s.
        guard created.timeIntervalSince(shot) >= -1 else { return .refuse("the confirmation file predates this run's screenshot") }
        return .proceed
    }

    /// Date of the confirmation file, or nil. A symlink or anything but a regular file does not count.
    public static func confirmationDate(at url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
    }
}
