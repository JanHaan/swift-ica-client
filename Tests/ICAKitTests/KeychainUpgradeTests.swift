import Foundation
import Security
import Testing
@testable import ICAKit

// 0.7.0 → 0.8.0 upgrade: in data-protection mode, storing (and deleting) a secret also removes the same item from
// the login keychain, where 0.7.0 kept it. Pure: the queries only, the real keychain is never touched (`mode` is set,
// so its probe never runs).

@Suite struct KeychainUpgradeTests {
    private func store(_ mode: KeychainSecretStore.Mode) -> KeychainSecretStore {
        let s = KeychainSecretStore()
        s.mode = mode
        return s
    }

    @Test func dataProtectionModeAlsoTargetsTheLegacyLoginKeychainItem() {
        for kind in SecretKind.allCases {
            let q = store(.dataProtection).deleteQueries(kind, host: "gw.example")
            #expect(q.count == 2)
            #expect(q[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(q[1][kSecUseDataProtectionKeychain as String] == nil)     // the login keychain
            // Same item otherwise: class, server/service, account key, not synchronisable.
            for key in [kSecClass, kSecAttrServer, kSecAttrService, kSecAttrAccount, kSecAttrSynchronizable] as [CFString] {
                #expect("\(q[0][key as String] ?? "-")" == "\(q[1][key as String] ?? "-")")
            }
        }
    }

    @Test func loginModeHasOnlyTheOneItem() {
        let q = store(.login).deleteQueries(.password, host: "gw.example")
        #expect(q.count == 1 && q[0][kSecUseDataProtectionKeychain as String] == nil)
    }
}
