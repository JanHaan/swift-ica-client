import Foundation
import Testing
@testable import ICAKit

private final class MemorySettings: SettingsStore {
    var value = LoginSettings()
    func load() -> LoginSettings { value }
    func save(_ settings: LoginSettings) { value = settings }
}

private final class MemorySecrets: SecretStore {
    struct Item: Equatable { var value: String; var account: String; var protected: Bool }
    var items: [String: Item] = [:]
    var presenceChecks = 0
    var reads = 0

    func key(_ kind: SecretKind, _ host: String) -> String { "\(kind.rawValue)@\(host)" }
    func contains(_ kind: SecretKind, host: String) -> Bool { items[key(kind, host)] != nil }
    func store(_ value: String, kind: SecretKind, host: String, account: String, protected: Bool) throws {
        items[key(kind, host)] = Item(value: value, account: account, protected: protected)
    }
    func delete(_ kind: SecretKind, host: String) { items[key(kind, host)] = nil }
    func read(_ kinds: [SecretKind], host: String, reason: String) async throws -> [SecretKind: String] {
        reads += 1
        if kinds.contains(where: { items[key($0, host)]?.protected == true }) { presenceChecks += 1 }
        var out: [SecretKind: String] = [:]
        for kind in kinds { out[kind] = items[key(kind, host)]?.value }
        return out
    }
}

private let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"   // RFC 6238 test key

private func make() -> (LoginCredentials, MemorySettings, MemorySecrets) {
    let settings = MemorySettings()
    settings.value.gatewayURL = "https://gw.test/"
    let secrets = MemorySecrets()
    return (LoginCredentials(settings: settings, secrets: secrets), settings, secrets)
}

@Test func gatewayAddressNormalisation() {
    #expect(LoginSettings.gatewayURL(from: " gateway.example.com ")?.absoluteString == "https://gateway.example.com/")
    #expect(LoginSettings.gatewayURL(from: "https://gateway.example.com/logon/LogonPoint/tmindex.html")?.absoluteString
        == "https://gateway.example.com/")
    #expect(LoginSettings.gatewayURL(from: "http://gateway.example.com") == nil)   // HTTPS only
    #expect(LoginSettings.gatewayURL(from: "") == nil)
}

@Test func rememberPasswordOnlyIsUnprotectedByDefault() throws {
    let (credentials, settings, secrets) = make()
    try credentials.remember(host: "gw.test", username: "jan", password: "pw", totpSecret: nil)
    #expect(secrets.items.keys.sorted() == ["password@gw.test"])
    #expect(secrets.items["password@gw.test"] == .init(value: "pw", account: "jan", protected: false))
    #expect(settings.value.username == "jan" && settings.value.passcodeMode == .prompt)
    #expect(credentials.saved(host: "gw.test") == .init(username: "jan", hasPassword: true, hasTOTPSecret: false))
}

@Test func rememberTOTPSecretProtectsBothItems() throws {
    let (credentials, settings, secrets) = make()
    try credentials.remember(host: "gw.test", username: "jan", password: "pw", totpSecret: "gezd gnbv-gy3t qojq gezd gnbv gy3t qojq")
    #expect(secrets.items["totpSecret@gw.test"] == .init(value: secret, account: "jan", protected: true))
    #expect(secrets.items["password@gw.test"]?.protected == true)
    #expect(settings.value.passcodeMode == .totp && settings.value.protectPassword)
    // Only password and TOTP secret are ever stored: SecretKind has no passcode case.
    #expect(SecretKind.allCases == [.password, .totpSecret])
}

@Test func pastedSecretsAreNormalised() throws {
    #expect(LoginSettings.base32Secret(from: " gezd gnbv-gy3t\nqojq== \t") == "GEZDGNBVGY3TQOJQ")
    #expect(LoginSettings.base32Secret(from: "otpauth://totp/GW:jan?secret=gezdgnbvgy3tqojq&issuer=GW") == "GEZDGNBVGY3TQOJQ")
    #expect(LoginSettings().totp(secret: "\n gezd gnbv gy3t qojq gezd gnbv gy3t qojq \n") != nil)
    #expect(LoginSettings().totp(secret: "  \n") == nil)
    let (credentials, _, secrets) = make()
    try credentials.remember(host: "gw.test", username: "jan", password: nil, totpSecret: "gezd gnbv gy3t qojq\ngezd gnbv gy3t qojq")
    #expect(secrets.items["totpSecret@gw.test"]?.value == secret)
}

@Test func invalidTOTPSecretStoresNothing() {
    let (credentials, _, secrets) = make()
    #expect(throws: CredentialError.self) {
        try credentials.remember(host: "gw.test", username: "jan", password: "pw", totpSecret: "not base32 !")
    }
    #expect(secrets.items.isEmpty)
}

@Test func loadForLoginNeedsOnePresenceCheckAndGeneratesCodes() async throws {
    let (credentials, settings, secrets) = make()
    settings.value.totpDigits = 8
    try credentials.remember(host: "gw.test", username: "jan", password: "pw", totpSecret: secret)
    let login = try await credentials.loadForLogin(host: "gw.test", reason: "test")
    #expect(secrets.reads == 1 && secrets.presenceChecks == 1)
    #expect(login.username == "jan" && login.password == "pw")
    #expect(login.totp?.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
}

@Test func loadForLoginWithoutStoredItemsReadsNothing() async throws {
    let (credentials, _, secrets) = make()
    let login = try await credentials.loadForLogin(host: "gw.test", reason: "test")
    #expect(secrets.reads == 0 && login.password == nil && login.totp == nil)
}

@Test func forgetAllDeletesSecretsAndUsername() throws {
    let (credentials, settings, secrets) = make()
    try credentials.remember(host: "gw.test", username: "jan", password: "pw", totpSecret: secret)
    credentials.forgetAll(host: "gw.test")
    #expect(secrets.items.isEmpty)
    #expect(settings.value.username.isEmpty && settings.value.passcodeMode == .prompt)
    #expect(settings.value.gatewayURL == "https://gw.test/")
}

@Test func settingsUpdateRules() async throws {
    let (credentials, settings, secrets) = make()
    func update(password: String? = nil, protect: Bool = false, mode: LoginSettings.PasscodeMode = .prompt,
                secret newSecret: String? = nil, gateway: String = "gw.test") -> LoginCredentials.Update {
        .init(gatewayURL: gateway, username: "jan", newPassword: password, protectPassword: protect,
              passcodeMode: mode, newTOTPSecret: newSecret, totpDigits: 6, totpPeriod: 30, totpAlgorithm: .sha1)
    }
    // TOTP mode needs a secret.
    await #expect(throws: CredentialError.self) { try await credentials.apply(update(mode: .totp), reason: "") }
    // Secrets need a gateway host.
    await #expect(throws: CredentialError.self) { try await credentials.apply(update(password: "pw", gateway: ""), reason: "") }
    try await credentials.apply(update(password: "pw", protect: false), reason: "")
    #expect(secrets.items["password@gw.test"]?.protected == false)
    // Turning protection on re-stores the existing password.
    try await credentials.apply(update(protect: true), reason: "")
    #expect(secrets.items["password@gw.test"] == .init(value: "pw", account: "jan", protected: true))
    #expect(secrets.reads == 1)
    try await credentials.apply(update(protect: true, mode: .totp, secret: secret), reason: "")
    #expect(secrets.items["totpSecret@gw.test"]?.protected == true && settings.value.passcodeMode == .totp)
    // Back to typing the passcode deletes the secret.
    try await credentials.apply(update(protect: true, mode: .prompt), reason: "")
    #expect(secrets.items["totpSecret@gw.test"] == nil && settings.value.passcodeMode == .prompt)
    #expect(settings.value.gatewayURL == "gw.test" && settings.value.gatewayHost == "gw.test")
}

@Test func userDefaultsSettingsRoundTrip() throws {
    let suite = "ica-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults: defaults)
    #expect(store.load() == LoginSettings())
    var s = LoginSettings()
    s.gatewayURL = "https://gw.test/"
    s.username = "jan"
    s.passcodeMode = .totp
    s.totpDigits = 8
    s.totpPeriod = 60
    s.totpAlgorithm = .sha256
    s.protectPassword = true
    store.save(s)
    #expect(store.load() == s)
    // No secret ever lands in UserDefaults.
    #expect(!defaults.dictionaryRepresentation().keys.contains { $0.lowercased().contains("password") && !$0.contains("protect") })
}

/// Live Keychain round trip (login keychain of the user running the tests). Set ICA_KEYCHAIN_TEST=1.
/// Reads only the unprotected item; the protected one is created, detected and deleted without a prompt.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ICA_KEYCHAIN_TEST"] == "1"))
func keychainRoundTrip() async throws {
    let store = KeychainSecretStore()
    let host = "ica-keychain-test.invalid"
    defer { for kind in SecretKind.allCases { store.delete(kind, host: host) } }
    print("keychain mode: \(store.mode.rawValue)")
    #expect(!store.contains(.password, host: host))
    try store.store("value-1", kind: .password, host: host, account: "tester", protected: false)
    #expect(store.contains(.password, host: host) && !store.isProtected(.password, host: host))
    try store.store("value-2", kind: .password, host: host, account: "tester", protected: false)   // replace
    let values = try await store.read([.password], host: host, reason: "test")
    #expect(values[.password] == "value-2")
    try store.store(secret, kind: .totpSecret, host: host, account: "tester", protected: true)
    #expect(store.contains(.totpSecret, host: host) && store.isProtected(.totpSecret, host: host))
    store.delete(.password, host: host)
    store.delete(.totpSecret, host: host)
    #expect(!store.contains(.password, host: host) && !store.contains(.totpSecret, host: host))
}

@Test func singleLineFieldSanitising() {
    // Passwords: only line breaks go, spaces stay.
    #expect(FieldText.clean(" pa ss\r\n", password: true, final: true) == " pa ss")
    #expect(FieldText.clean("pw\u{2028}x\n", password: true, final: false) == "pwx")
    // Other fields: no line breaks, no leading whitespace; trailing whitespace only when final.
    #expect(FieldText.clean("  gezd gnbv\ngy3t \n", password: false, final: true) == "gezd gnbvgy3t")
    #expect(FieldText.clean(" jan ", password: false, final: false) == "jan ")   // typing a name
    #expect(FieldText.clean("gateway.example.com\r\n", password: false, final: true) == "gateway.example.com")
    #expect(FieldText.clean("\n", password: false, final: true) == "")
}
