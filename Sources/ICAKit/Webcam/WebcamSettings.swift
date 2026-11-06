import Foundation

/// The camera setting (docs/98b §10.5): pass the camera to the session, default **off** until verified live. When off,
/// the CTXMM module is not announced, so the host shows no HDX camera. Applies at the next connect.
public struct WebcamSettings: Equatable, Sendable {
    /// §10.5: "default off until verified live".
    public static let defaultEnabled = false

    public enum Source: String, Sendable {
        /// The Mac camera (app only).
        case camera
        /// The generated test pattern; never opens the camera (§10.6).
        case synthetic
    }

    public var enabled = WebcamSettings.defaultEnabled
    /// `ICA_WEBCAM_SOURCE=synthetic`; not stored.
    public var source = Source.camera

    public init() {}

    public static let enabledKey = "webcam.enabled"

    /// From UserDefaults; ICA_WEBCAM=0/1 and ICA_WEBCAM_SOURCE=synthetic override (automated runs).
    public static func load(defaults: UserDefaults = .standard,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> WebcamSettings {
        var s = WebcamSettings()
        if defaults.object(forKey: enabledKey) != nil { s.enabled = defaults.bool(forKey: enabledKey) }
        if let v = env["ICA_WEBCAM"]?.lowercased() {
            if ["0", "off", "no"].contains(v) { s.enabled = false } else if ["1", "on", "yes"].contains(v) { s.enabled = true }
        }
        if env["ICA_WEBCAM_SOURCE"]?.lowercased() == "synthetic" { s.source = .synthetic }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// The engine configuration, or nil when the camera is off (no CTXMM module at all).
    public var engineConfig: WebcamEngine.Config? {
        enabled ? WebcamEngine.Config() : nil
    }
}
