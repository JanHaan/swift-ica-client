import Foundation
import LocalAuthentication
import Security

// MARK: - Settings (no secrets)

/// Login settings that are not secret. Secrets (password, TOTP secret) live only in a `SecretStore`.
public struct LoginSettings: Equatable {
    public enum PasscodeMode: String, Sendable {
        /// The user types the passcode at each login.
        case prompt
        /// A stored TOTP secret generates the passcode.
        case totp
    }

    public var gatewayURL = ""
    public var username = ""
    public var passcodeMode = PasscodeMode.prompt
    public var totpDigits = 6
    public var totpPeriod = 30
    public var totpAlgorithm = TOTP.Algorithm.sha1
    /// Require Touch ID or the Mac password to read the stored password.
    public var protectPassword = false

    public init() {}

    /// The gateway root URL (`https://host/`), accepting a bare host name.
    public var gateway: URL? { Self.gatewayURL(from: gatewayURL) }
    public var gatewayHost: String? { gateway?.host }

    public static func gatewayURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// A TOTP generator for `secret` with these settings (`nil` if the secret is not valid base32).
    public func totp(secret: String) -> TOTP? {
        let base32 = Self.base32Secret(from: secret)
        guard !base32.isEmpty else { return nil }
        return TOTP(base32Secret: base32, digits: totpDigits, period: totpPeriod, algorithm: totpAlgorithm)
    }

    /// The base32 secret from pasted text: spaces, line breaks, dashes and padding removed, upper case.
    /// Also accepts an `otpauth://totp/...?secret=...` URI.
    public static func base32Secret(from text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("otpauth://"),
           let secret = URLComponents(string: text)?.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value {
            text = secret
        }
        return text.uppercased().filter { !$0.isWhitespace && !"-=".contains($0) }
    }
}

public protocol SettingsStore: AnyObject {
    func load() -> LoginSettings
    func save(_ settings: LoginSettings)
}

/// Settings in UserDefaults (never secrets).
public final class UserDefaultsSettingsStore: SettingsStore {
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> LoginSettings {
        var s = LoginSettings()
        s.gatewayURL = defaults.string(forKey: "login.gatewayURL") ?? ""
        s.username = defaults.string(forKey: "login.username") ?? ""
        s.passcodeMode = defaults.string(forKey: "login.passcodeMode").flatMap(LoginSettings.PasscodeMode.init) ?? .prompt
        if defaults.object(forKey: "login.totpDigits") != nil { s.totpDigits = defaults.integer(forKey: "login.totpDigits") }
        if defaults.object(forKey: "login.totpPeriod") != nil { s.totpPeriod = defaults.integer(forKey: "login.totpPeriod") }
        s.totpAlgorithm = defaults.string(forKey: "login.totpAlgorithm").flatMap(TOTP.Algorithm.init) ?? .sha1
        s.protectPassword = defaults.bool(forKey: "login.protectPassword")
        return s
    }

    public func save(_ s: LoginSettings) {
        defaults.set(s.gatewayURL, forKey: "login.gatewayURL")
        defaults.set(s.username, forKey: "login.username")
        defaults.set(s.passcodeMode.rawValue, forKey: "login.passcodeMode")
        defaults.set(s.totpDigits, forKey: "login.totpDigits")
        defaults.set(s.totpPeriod, forKey: "login.totpPeriod")
        defaults.set(s.totpAlgorithm.rawValue, forKey: "login.totpAlgorithm")
        defaults.set(s.protectPassword, forKey: "login.protectPassword")
    }
}

// MARK: - Secrets

/// The only secrets that are ever stored. There is deliberately no case for a passcode.
public enum SecretKind: String, Sendable, CaseIterable {
    case password
    case totpSecret
}

public protocol SecretStore: AnyObject {
    /// Whether an item exists, without reading its value (never prompts).
    func contains(_ kind: SecretKind, host: String) -> Bool
    /// Stores or replaces a secret. `protected`: reading requires user presence (Touch ID or the Mac password).
    func store(_ value: String, kind: SecretKind, host: String, account: String, protected: Bool) throws
    func delete(_ kind: SecretKind, host: String)
    /// Reads the existing items of `kinds`. One user-presence check covers all protected items.
    func read(_ kinds: [SecretKind], host: String, reason: String) async throws -> [SecretKind: String]
}

public enum CredentialError: Error, CustomStringConvertible {
    case invalidTOTPSecret
    case noGateway
    case keychain(String, OSStatus)

    public var description: String {
        switch self {
        case .invalidTOTPSecret: "the TOTP secret is not valid base32"
        case .noGateway: "no gateway address"
        case .keychain(let what, let status): "Keychain \(what) failed (\(status))"
        }
    }
}

/// Secrets read for one login. Drop it as soon as the fields are filled.
public struct LoginSecrets {
    public var username: String
    public var password: String?
    public var totp: TOTP?
}

/// Login credentials: settings plus Keychain secrets. Never stores a passcode.
public final class LoginCredentials {
    public let settings: SettingsStore
    public let secrets: SecretStore
    public var log: (String) -> Void = { _ in }

    public init(settings: SettingsStore, secrets: SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    public struct Saved: Equatable {
        public var username: String
        public var hasPassword: Bool
        public var hasTOTPSecret: Bool
    }

    /// What is saved for `host`, without reading any secret.
    public func saved(host: String) -> Saved {
        let s = settings.load()
        let saved = Saved(username: s.username, hasPassword: secrets.contains(.password, host: host),
                          hasTOTPSecret: s.passcodeMode == .totp && secrets.contains(.totpSecret, host: host))
        return saved
    }

    /// Saves a successful login. `password`/`totpSecret` nil leave the stored item as it is.
    /// `protectPassword` nil: on when a TOTP secret is (or gets) stored, else the current setting.
    public func remember(host: String, username: String, password: String?, totpSecret: String?,
                         protectPassword: Bool? = nil) throws {
        var s = settings.load()
        if let totpSecret, s.totp(secret: totpSecret) == nil { throw CredentialError.invalidTOTPSecret }
        let willHaveSecret = totpSecret != nil || (s.passcodeMode == .totp && secrets.contains(.totpSecret, host: host))
        let protect = protectPassword ?? (willHaveSecret ? true : s.protectPassword)
        if let password {
            try secrets.store(password, kind: .password, host: host, account: username, protected: protect)
        }
        if let totpSecret {
            // The TOTP secret is always protected: next to the password it would otherwise collapse 2FA.
            try secrets.store(Self.normalise(totpSecret), kind: .totpSecret, host: host, account: username, protected: true)
            s.passcodeMode = .totp
        }
        s.username = username
        s.protectPassword = protect
        settings.save(s)
        log("remembered login for \(host): password \(password == nil ? "unchanged" : "stored"), "
            + "secret \(totpSecret == nil ? "unchanged" : "stored"), password protected: \(protect ? "yes" : "no")")
    }

    /// Switches to typing the passcode and deletes the TOTP secret.
    public func forgetTOTPSecret(host: String) {
        secrets.delete(.totpSecret, host: host)
        var s = settings.load()
        s.passcodeMode = .prompt
        settings.save(s)
    }

    /// Deletes password, TOTP secret and username for `host`. The gateway address stays.
    public func forgetAll(host: String) {
        for kind in SecretKind.allCases { secrets.delete(kind, host: host) }
        var s = settings.load()
        s.username = ""
        s.passcodeMode = .prompt
        s.protectPassword = false
        settings.save(s)
        log("forgot saved login for \(host)")
    }

    /// Reads the stored secrets for a login (one Touch ID/password prompt if any of them is protected).
    public func loadForLogin(host: String, reason: String) async throws -> LoginSecrets {
        let s = settings.load()
        var kinds: [SecretKind] = []
        if secrets.contains(.password, host: host) { kinds.append(.password) }
        if s.passcodeMode == .totp, secrets.contains(.totpSecret, host: host) { kinds.append(.totpSecret) }
        let values = kinds.isEmpty ? [:] : try await secrets.read(kinds, host: host, reason: reason)
        log("loaded login for \(host): password present: \(values[.password] != nil ? "yes" : "no"), "
            + "secret present: \(values[.totpSecret] != nil ? "yes" : "no")")
        return LoginSecrets(username: s.username, password: values[.password],
                            totp: values[.totpSecret].flatMap { s.totp(secret: $0) })
    }

    /// A change from the settings window. `nil` secrets keep the stored item.
    public struct Update {
        public var gatewayURL: String
        public var username: String
        public var newPassword: String?
        public var protectPassword: Bool
        public var passcodeMode: LoginSettings.PasscodeMode
        public var newTOTPSecret: String?
        public var totpDigits: Int
        public var totpPeriod: Int
        public var totpAlgorithm: TOTP.Algorithm

        public init(gatewayURL: String, username: String, newPassword: String?, protectPassword: Bool,
                    passcodeMode: LoginSettings.PasscodeMode, newTOTPSecret: String?,
                    totpDigits: Int = 6, totpPeriod: Int = 30, totpAlgorithm: TOTP.Algorithm = .sha1) {
            self.gatewayURL = gatewayURL
            self.username = username
            self.newPassword = newPassword
            self.protectPassword = protectPassword
            self.passcodeMode = passcodeMode
            self.newTOTPSecret = newTOTPSecret
            self.totpDigits = totpDigits
            self.totpPeriod = totpPeriod
            self.totpAlgorithm = totpAlgorithm
        }
    }

    /// Applies a settings change. Changing the password protection of a stored password re-stores it,
    /// which reads it first (one prompt if it is protected now).
    public func apply(_ update: Update, reason: String) async throws {
        var s = settings.load()
        s.gatewayURL = update.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        s.username = update.username.trimmingCharacters(in: .whitespacesAndNewlines)
        s.totpDigits = update.totpDigits
        s.totpPeriod = update.totpPeriod
        s.totpAlgorithm = update.totpAlgorithm
        let host = s.gatewayHost
        let needsHost = update.newPassword != nil || update.newTOTPSecret != nil
        if needsHost, host == nil { throw CredentialError.noGateway }
        if let secret = update.newTOTPSecret, s.totp(secret: secret) == nil { throw CredentialError.invalidTOTPSecret }
        if update.passcodeMode == .totp, update.newTOTPSecret == nil,
           !(host.map { secrets.contains(.totpSecret, host: $0) } ?? false) {
            throw CredentialError.invalidTOTPSecret
        }
        if let host {
            if let password = update.newPassword {
                try secrets.store(password, kind: .password, host: host, account: s.username, protected: update.protectPassword)
            } else if update.protectPassword != s.protectPassword, secrets.contains(.password, host: host) {
                var old = try await secrets.read([.password], host: host, reason: reason)
                if let password = old[.password] {
                    try secrets.store(password, kind: .password, host: host, account: s.username, protected: update.protectPassword)
                }
                old = [:]
            }
            switch update.passcodeMode {
            case .totp:
                if let secret = update.newTOTPSecret {
                    try secrets.store(Self.normalise(secret), kind: .totpSecret, host: host, account: s.username, protected: true)
                }
            case .prompt:
                secrets.delete(.totpSecret, host: host)
            }
        }
        s.passcodeMode = update.passcodeMode
        s.protectPassword = update.protectPassword
        settings.save(s)
        log("settings saved: gateway \(host ?? "none"), password \(update.newPassword == nil ? "unchanged" : "stored"), "
            + "passcode \(update.passcodeMode.rawValue), secret \(update.newTOTPSecret == nil ? "unchanged" : "stored"), "
            + "password protected: \(update.protectPassword ? "yes" : "no")")
    }

    static func normalise(_ secret: String) -> String { LoginSettings.base32Secret(from: secret) }
}

// MARK: - Keychain

/// Secrets in the Keychain: `kSecClassInternetPassword` for the password (server = gateway host),
/// `kSecClassGenericPassword` for the TOTP secret. Never synchronised, this device only.
///
/// Protection: in the data protection keychain a protected item carries `SecAccessControl` with
/// `.userPresence`, enforced by the Keychain. That keychain needs a signed app with a provisioning
/// profile (keychain-access-groups); ad-hoc and development-signed builds get errSecMissingEntitlement.
/// There the store falls back to the login keychain, whose ACL limits the item to this app, and
/// checks user presence itself (LocalAuthentication) before reading a protected item.
public final class KeychainSecretStore: SecretStore {
    public enum Mode: String { case dataProtection = "data protection keychain, Keychain-enforced user presence"
                               case login = "login keychain, app-enforced user presence" }

    static let totpService = "local.alttab.ICAViewer.totp"
    static let protectedMarker = "requires user presence"
    public var log: (String) -> Void = { _ in }

    public init() {}

    public lazy var mode: Mode = {
        // Probe: can this process use the data protection keychain?
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.totpService + ".probe",
                                    kSecAttrAccount as String: "probe", kSecUseDataProtectionKeychain as String: true]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        query.removeValue(forKey: kSecValueData as String)
        query.removeValue(forKey: kSecAttrAccessible as String)
        SecItemDelete(query as CFDictionary)
        let mode: Mode = status == errSecSuccess ? .dataProtection : .login
        log("keychain mode: \(mode.rawValue) (probe status \(status))")
        return mode
    }()

    func baseQuery(_ kind: SecretKind, host: String) -> [String: Any] {
        var q: [String: Any]
        switch kind {
        case .password:
            q = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: host,
                 kSecAttrProtocol as String: kSecAttrProtocolHTTPS]
        case .totpSecret:
            q = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.totpService,
                 kSecAttrAccount as String: host]
        }
        q[kSecAttrSynchronizable as String] = false
        if mode == .dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Attributes of an existing item, without its data and without user interaction.
    func attributes(_ kind: SecretKind, host: String) -> [String: Any]? {
        var q = baseQuery(kind, host: host)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return status == errSecSuccess || status == errSecInteractionNotAllowed ? (out as? [String: Any]) ?? [:] : nil
    }

    public func contains(_ kind: SecretKind, host: String) -> Bool { attributes(kind, host: host) != nil }

    func isProtected(_ kind: SecretKind, host: String) -> Bool {
        guard let attrs = attributes(kind, host: host) else { return false }
        return attrs[kSecAttrComment as String] as? String == Self.protectedMarker || attrs[kSecAttrAccessControl as String] != nil
    }

    public func store(_ value: String, kind: SecretKind, host: String, account: String, protected: Bool) throws {
        delete(kind, host: host)
        var q = baseQuery(kind, host: host)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrLabel as String] = kind == .password ? host : "ICA Viewer TOTP (\(host))"
        if kind == .password { q[kSecAttrAccount as String] = account }
        if protected { q[kSecAttrComment as String] = Self.protectedMarker }
        if protected, mode == .dataProtection {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
                throw CredentialError.keychain("access control", errSecParam)
            }
            q[kSecAttrAccessControl as String] = access
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain("add \(kind.rawValue)", status) }
        log("keychain: stored \(kind.rawValue) for \(host), protected: \(protected ? "yes" : "no")")
    }

    public func delete(_ kind: SecretKind, host: String) {
        var query = baseQuery(kind, host: host)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess { log("keychain: deleted \(kind.rawValue) for \(host)") }
        if mode == .dataProtection {
            // Items an unsigned (ad-hoc) build left in the login keychain.
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            if SecItemDelete(query as CFDictionary) == errSecSuccess {
                log("keychain: deleted \(kind.rawValue) for \(host) from the login keychain")
            }
        }
    }

    public func read(_ kinds: [SecretKind], host: String, reason: String) async throws -> [SecretKind: String] {
        let context = LAContext()
        // One prompt per login: the evaluated context is reused for every item read below.
        context.touchIDAuthenticationAllowableReuseDuration = 10
        defer { context.invalidate() }
        if kinds.contains(where: { isProtected($0, host: host) }) {
            log("keychain: asking for user presence")
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
        var values: [SecretKind: String] = [:]
        for kind in kinds {
            var q = baseQuery(kind, host: host)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationContext as String] = context
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = out as? Data else {
                throw CredentialError.keychain("read \(kind.rawValue)", status)
            }
            values[kind] = String(decoding: data, as: UTF8.self)
        }
        return values
    }
}

// MARK: - Single-line field text

/// Cleans text in single-line fields (pasted text often carries a line break).
public enum FieldText {
    /// Line breaks are always removed. Passwords keep every other character, spaces included. Other
    /// fields lose leading whitespace while typing, and trailing whitespace too when `final`
    /// (a paste, or the value being submitted), so typing an inner space still works.
    public static func clean(_ text: String, password: Bool, final: Bool) -> String {
        var out = String(text.unicodeScalars.filter { !CharacterSet.newlines.contains($0) })
        guard !password else { return out }
        out = String(out.drop { $0.isWhitespace })
        if final { while out.last?.isWhitespace == true { out.removeLast() } }
        return out
    }
}
