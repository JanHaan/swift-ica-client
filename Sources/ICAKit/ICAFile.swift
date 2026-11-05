import Foundation

/// A launch (.ica) file, flattened the way the reference engine does it (docs/10-launch.md A.1):
/// keys are case-sensitive, the first occurrence wins, except inside the section of the
/// application named in `[ApplicationServers]`, which overrides earlier values.
public struct ICAFile {
    public private(set) var values: [String: String] = [:]
    /// Keys in file order, for display.
    public private(set) var keys: [String] = []

    /// Keys whose values are secrets or single-use tickets and must not be shown.
    public static let secretKeys: Set<String> = [
        "Address", "LogonTicket", "ClearPassword", "Password", "LaunchReference", "SessionsharingKey",
        "SSPIEnable", "AutologonAllowed", "RtmeDetail", "CGPAddressTicket",
    ]

    public init?(text: String) {
        guard text.first == "[" else { return nil }
        var appSections: Set<String> = []
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<end])
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            if section == "ApplicationServers" { appSections.insert(key) }
            if values[key] == nil || appSections.contains(section) {
                if values[key] == nil { keys.append(key) }
                values[key] = value
            }
        }
    }

    public subscript(_ key: String) -> String? { values[key] }

    public func bool(_ key: String) -> Bool {
        ["on", "true", "yes", "1"].contains(values[key]?.lowercased() ?? "")
    }

    /// Lines for display with secret values redacted.
    public var redactedDescription: String {
        keys.map { key in
            let value = values[key] ?? ""
            let isSecret = Self.secretKeys.contains(key) || key.lowercased().contains("ticket")
                || key.lowercased().hasPrefix("vdaauthinfo") || key.lowercased().contains("token")
            return isSecret ? "\(key)=<\(value.count) chars>" : "\(key)=\(value)"
        }.joined(separator: "\n")
    }
}
