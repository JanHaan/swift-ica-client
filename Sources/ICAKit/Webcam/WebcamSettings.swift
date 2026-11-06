import Foundation

/// The camera setting (docs/98b §10.5): pass the camera to the session, default **off** until verified live. When off,
/// the CTXMM module is not announced, so the host shows no HDX camera. The camera choice (by unique id, automatic =
/// system default) is read when a session starts. Both apply at the next connect.
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
    /// The chosen camera's `AVCaptureDevice.uniqueID`; nil = automatic (the system default). If it is missing at
    /// PLAY the system default is used (§10.5).
    public var deviceID: String?
    /// Its name when it was chosen, to show it in Settings while it is not connected.
    public var deviceName: String?
    /// `ICA_WEBCAM_SOURCE=synthetic`; not stored.
    public var source = Source.camera

    public init() {}

    public static let enabledKey = "webcam.enabled"
    public static let deviceIDKey = "webcam.deviceID"
    public static let deviceNameKey = "webcam.deviceName"

    /// From UserDefaults; ICA_WEBCAM=0/1 and ICA_WEBCAM_SOURCE=synthetic override (automated runs).
    public static func load(defaults: UserDefaults = .standard,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> WebcamSettings {
        var s = WebcamSettings()
        if defaults.object(forKey: enabledKey) != nil { s.enabled = defaults.bool(forKey: enabledKey) }
        if let id = defaults.string(forKey: deviceIDKey), !id.isEmpty {
            s.deviceID = id
            s.deviceName = defaults.string(forKey: deviceNameKey)
        }
        if let v = env["ICA_WEBCAM"]?.lowercased() {
            if ["0", "off", "no"].contains(v) { s.enabled = false } else if ["1", "on", "yes"].contains(v) { s.enabled = true }
        }
        if env["ICA_WEBCAM_SOURCE"]?.lowercased() == "synthetic" { s.source = .synthetic }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if let deviceID, !deviceID.isEmpty {
            defaults.set(deviceID, forKey: Self.deviceIDKey)
            defaults.set(deviceName, forKey: Self.deviceNameKey)
        } else {
            defaults.removeObject(forKey: Self.deviceIDKey)
            defaults.removeObject(forKey: Self.deviceNameKey)
        }
    }

    /// The engine configuration, or nil when the camera is off (no CTXMM module at all).
    public var engineConfig: WebcamEngine.Config? {
        enabled ? WebcamEngine.Config() : nil
    }
}
