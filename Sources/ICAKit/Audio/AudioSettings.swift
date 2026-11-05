import Foundation

/// The audio setting (docs/98 §10.4): play session audio, default **on**. It decides whether the CTXCAM module
/// is announced, so it applies at the next connect. Volume follows macOS; there is no microphone yet.
public struct AudioSettings: Equatable, Sendable {
    /// §10.4: "Play session audio (default on)".
    public static let defaultEnabled = true

    public var enabled = AudioSettings.defaultEnabled
    /// Codecs offered to the host (`ICA_AUDIO_CODECS=pcm,opus`); not stored.
    public var codecs: Set<AudioCodecKind> = Set(AudioCodecKind.allCases)

    public init() {}

    public static let enabledKey = "audio.enabled"

    /// From UserDefaults; ICA_AUDIO=0/1 and ICA_AUDIO_CODECS override (automated runs). Unknown codec names
    /// (speex, vorbis: not implemented) are ignored.
    public static func load(defaults: UserDefaults = .standard,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> AudioSettings {
        var s = AudioSettings()
        if defaults.object(forKey: enabledKey) != nil { s.enabled = defaults.bool(forKey: enabledKey) }
        if let v = env["ICA_AUDIO"]?.lowercased() {
            if ["0", "off", "no"].contains(v) { s.enabled = false } else if ["1", "on", "yes"].contains(v) { s.enabled = true }
        }
        if let list = env["ICA_AUDIO_CODECS"] {
            s.codecs = Set(list.lowercased().split(separator: ",").compactMap { AudioCodecKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// The engine configuration, or nil when audio is off (no CTXCAM module at all).
    public var engineConfig: AudioEngine.Config? {
        guard enabled else { return nil }
        var c = AudioEngine.Config()
        c.codecs = codecs
        return c
    }
}

/// One-shot fallback for an unknown host (docs/98 §13 D1): if a session that announced CTXCAM ends before it was
/// established (no seamless channel and no Thinwire INIT), the relaunch that follows omits CTXCAM once, so a
/// host that rejects the module cannot keep a resource from starting. The launch after that announces it again.
/// Per resource name; main thread.
public struct AudioFallback: Equatable, Sendable {
    private var omitNext: Set<String> = []

    public init() {}

    /// After a session ended and a relaunch was chosen. True if that relaunch omits CTXCAM.
    /// `announcedAudio`: the session's INIT_RESPONSE carried the CTXCAM module.
    /// `established`: it reached the seamless channel or the first Thinwire INIT.
    @discardableResult
    public mutating func relaunching(_ resource: String, announcedAudio: Bool, established: Bool) -> Bool {
        if announcedAudio && !established { omitNext.insert(resource) } else { omitNext.remove(resource) }
        return omitNext.contains(resource)
    }

    /// No relaunch follows (established, given up, or quitting): forget any pending omission.
    public mutating func clear(_ resource: String) { omitNext.remove(resource) }

    /// At launch: true (once) if this launch omits CTXCAM.
    public mutating func takeOmission(_ resource: String) -> Bool { omitNext.remove(resource) != nil }
}
