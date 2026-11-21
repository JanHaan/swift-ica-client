import AppHostKit
import Foundation
import Security

/// Whether this is a development build: no version in the Info.plist (`swift run`), or an ad-hoc signed bundle
/// (`scripts/bundle.sh` without a Developer ID, as the macOS test VM runs it). A released build is signed with a
/// Developer ID and is neither. Test-only environment hooks (`ICAVIEWER_KEEPALIVE_SECONDS`) are honoured only here.
enum BuildKind {
    static let isDevelopment: Bool = AppVersion.current.isDevelopment || isAdHocSigned()

    private static func isAdHocSigned() -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}
