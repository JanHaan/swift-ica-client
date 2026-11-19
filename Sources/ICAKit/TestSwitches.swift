import Foundation
import Security

/// Environment switches in a distributed build (security review L-07/L-08). The viewer reads many `ICA_*` and
/// `ICAVIEWER_*` variables for tests and lab diagnosis: some weaken security (`ICA_HELPER_VERIFY=0` skips the helper
/// code check, `ICA_HELPER_TEMPLATE` picks the code that gets re-signed, `ICA_IGNORE_ENCRYPTION_LEVEL`,
/// `ICA_ROOT`/`ICA_ENV` choose the credentials file), others drive the app unattended. `launchctl setenv` hands them to
/// every app the user starts. So a Developer ID build (what the DMG ships) removes them from its own environment
/// before anything reads it: default deny, with an allowlist of plain preferences, and feature switches only when they
/// turn a feature off. Development, ad-hoc and Apple Development builds (all lab and VM runs) keep every switch;
/// icactl is a development tool and never scrubs.
public enum TestSwitches {
    /// Preferences and tuning that neither weaken security nor automate anything.
    static let releaseAllowed: Set<String> = [
        "ICA_LOG_FILE", "ICA_DOCK_ICON", "ICA_MENU_TITLE", "ICA_FPS_ACTIVE", "ICA_FPS_IDLE", "ICA_KBD_LAYOUT",
        "ICA_FONT_SMOOTHING", "ICA_SCALE_CLIENT", "ICA_SCALE_LIMIT", "ICA_SCALE_WINDOWS", "ICA_TW_H264",
        "ICA_TWI_PAUSE_RESUME", "ICA_COMPRESSION", "ICA_GATEWAY_UA", "ICA_AUDIO_LAG_MS", "ICA_AUDIO_PREROLL_MS",
        "ICA_CLIP_PASTE_DELAY_MS", "ICA_GDT_READSIZE", "ICA_GDT_READAHEAD", "ICA_HELPER_APPS", "ICA_PRINT_ACTION",
        "ICA_SHOT_CENSOR", "ICAVIEWER_DEMO", "ICAVIEWER_DEMO_SHOW", "ICAVIEWER_SCREENSHOT", "ICAVIEWER_SINGLE_SCREEN",
        "ICAVIEWER_DESKTOP_FULLSCREEN",
    ]
    /// Feature switches allowed only with a value that turns the feature off (or read-only): turning a redirection
    /// on, or pointing it at another folder, is the user's decision in Settings.
    static let releaseOffOnly: [String: Set<String>] = [
        "ICA_CDM": ["0", "off", "no"], "ICA_PRINTING": ["0", "off", "no"], "ICA_AUDIO": ["0", "off", "no"],
        "ICA_AUDIO_MIC": ["0", "off", "no"], "ICA_WEBCAM": ["0", "off", "no"], "ICA_CLIPBOARD": ["0", "off", "no"],
        "ICA_CLIP_IMAGES": ["0", "off", "no"], "ICA_CDM_READONLY": ["1", "on", "yes"],
        "ICA_TW_YUV444": ["0"], "ICA_EDT": ["0", "off", "no"],
    ]

    /// Whether a release build keeps `name=value` (only `ICA_*`/`ICAVIEWER_*` names are ever touched).
    public static func keptInRelease(_ name: String, _ value: String) -> Bool {
        guard name.hasPrefix("ICA_") || name.hasPrefix("ICAVIEWER_") else { return true }
        if releaseAllowed.contains(name) { return true }
        if let off = releaseOffOnly[name] { return off.contains(value.lowercased()) }
        return false
    }

    /// The names a release build drops from `environment`, sorted.
    public static func gated(_ environment: [String: String]) -> [String] {
        environment.filter { !keptInRelease($0.key, $0.value) }.map(\.key).sorted()
    }

    /// True when this process is signed with a Developer ID Application certificate (Apple's documented requirement
    /// for Developer ID code).
    public static let isDeveloperIDBuild: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return satisfiesDeveloperID(code)
    }()

    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func satisfiesDeveloperID(_ code: SecCode) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(developerIDRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// A static code (a bundle on disk) against the same requirement (diagnostics, tests).
    public static func isDeveloperIDSigned(bundle: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerIDRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Call first in `main`: in a release build, unsets every gated switch of this process (ProcessInfo reads the live
    /// environment, so every later read, also in ICAKit, sees the scrubbed one). Returns the names removed.
    @discardableResult
    public static func scrubProcessEnvironment(release: Bool = isDeveloperIDBuild) -> [String] {
        guard release else { return [] }
        let names = gated(ProcessInfo.processInfo.environment)
        for name in names { unsetenv(name) }
        return names
    }
}
