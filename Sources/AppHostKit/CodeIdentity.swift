import Foundation
import Security

/// Which code a helper runs (docs/99 §12.17): the host records the generated bundle's cdhash and checks
/// the bundle again before the launch and the running process at check-in (by its audit token), so a
/// bundle swapped or edited after generation, or another process with a stolen token, is refused.
public enum CodeIdentity {
    /// The cdhash (hex, lower case) of a signed bundle on disk; nil if it is unsigned or unreadable.
    public static func cdhash(bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The code requirement "exactly this cdhash"; nil unless `cdhash` is plain hex (it goes into the
    /// requirement language).
    public static func requirement(cdhash: String) -> String? {
        guard !cdhash.isEmpty, cdhash.count <= 128, cdhash.allSatisfy(\.isHexDigit) else { return nil }
        return "cdhash H\"\(cdhash.lowercased())\""
    }

    /// errSecSuccess when the process behind `auditToken` is valid and runs exactly the code with `cdhash`.
    public static func check(auditToken: audit_token_t, cdhash: String) -> OSStatus {
        guard let text = requirement(cdhash: cdhash) else { return errSecParam }
        var token = auditToken
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        var status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else { return status }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { return status }
        return SecCodeCheckValidity(code, [], requirement)
    }

    /// This process's own audit token (tests, diagnostics).
    public static func ownAuditToken() -> audit_token_t? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? token : nil
    }
}
