import Foundation

extension LogonForm {
    /// A username / password / passcode form with the app's built-in labels only (never strings from a
    /// gateway). The demo mode (ICAVIEWER_DEMO=1) renders it for README screenshots without any network.
    public static func demo(languages: [String] = Locale.preferredLanguages) -> LogonForm {
        let strings = LogonStrings(language: LogonStrings.pick(languages))
        func field(_ id: String, _ kind: Field.Kind, key: String, type: String, secret: Bool = false) -> Field {
            Field(id: id, kind: kind, label: strings.text(for: key), labelKey: key, credentialType: type, secret: secret,
                  constraint: ".+", initialValue: nil, readOnly: false, buttonValue: nil)
        }
        let fields = [
            Field(id: "#0", kind: .heading, label: strings.text(for: "dualauth_please_log_on"), labelKey: "dualauth_please_log_on",
                  credentialType: "none", secret: false, constraint: nil, initialValue: nil, readOnly: false, buttonValue: nil),
            field("login", .username, key: "dualauth_user_name", type: "username"),
            field("passwd", .password, key: "dualauth_password", type: "password", secret: true),
            field("passwd1", .passcode, key: "dualauth_passcode", type: "password", secret: true),
            Field(id: "Logon", kind: .button, label: strings.text(for: "dualauth_submit"), labelKey: "dualauth_submit",
                  credentialType: "none", secret: false, constraint: nil, initialValue: nil, readOnly: false,
                  buttonValue: "dualauth_submit"),
        ]
        return LogonForm(fields: fields, postBack: "", cancelPostBack: nil, isRePrompt: false, stateContext: nil,
                         postedIDs: [], strings: strings)
    }
}
