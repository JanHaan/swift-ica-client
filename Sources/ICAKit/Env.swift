import Foundation

/// Key/value settings from a `.env` file. Empty values count as absent.
public struct Env {
    public let values: [String: String]

    public init(path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        self.values = values
    }

    public subscript(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }
}
