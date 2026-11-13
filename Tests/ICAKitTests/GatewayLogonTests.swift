import Foundation
import Testing
@testable import ICAKit

// MARK: Helpers

private let base = URL(string: "https://gateway.test/")!

private func fixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "nfactor-xen-requirements", withExtension: "xml",
                                             subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func response(_ body: Data, path: String = "/nf/auth/doAuthentication.do", status: Int = 200) -> HTTPClient.Response {
    HTTPClient.Response(status: status, headers: ["Content-Type": "application/xml"], body: body,
                        url: URL(string: path, relativeTo: base)!.absoluteURL)
}

/// A synthetic AuthenticateResponse.
private func xml(_ requirements: String = "", result: String = "more-info", state: String? = nil) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <AuthenticateResponse xmlns="http://citrix.com/authentication/response/1">
    <Status>success</Status><Result>\(result)</Result><StateContext>\(state ?? "")</StateContext>
    <AuthenticationRequirements><PostBack>/nf/auth/doAuthentication.do</PostBack>
    <CancelPostBack>/nf/auth/doLogoff.do</CancelPostBack><Requirements>\(requirements)</Requirements>
    </AuthenticationRequirements></AuthenticateResponse>
    """.utf8)
}

private func field(_ id: String, _ type: String, _ label: String, secret: Bool = false) -> String {
    "<Requirement><Credential><ID>\(id)</ID><Type>\(type)</Type></Credential>"
        + "<Label><Text>\(label)</Text><Type>nsg-login-label</Type></Label>"
        + "<Input><Text>\(secret ? "<Secret>true</Secret>" : "")<Constraint>.+</Constraint></Text></Input></Requirement>"
}

private func label(_ text: String, type: String) -> String {
    "<Requirement><Credential><Type>none</Type></Credential><Label><Text>\(text)</Text><Type>\(type)</Type></Label><Input/></Requirement>"
}

private let submitButton = "<Requirement><Credential><ID>Logon</ID><Type>none</Type></Credential>"
    + "<Label><Type>none</Type></Label><Input><Button>dualauth_submit</Button></Input></Requirement>"

/// Scripted gateway: answers GETs with an HTML page (no string bundles) and POSTs to the logon
/// endpoints from a queue; records every request.
private final class FakeGateway: @unchecked Sendable {
    var queue: [Data]
    var strings: [String: String] = [:]
    var requests: [(method: String, path: String, form: [(String, String)]?)] = []

    init(_ queue: [Data]) { self.queue = queue }

    var posts: [[(String, String)]] {
        requests.filter { $0.path == "/nf/auth/doAuthentication.do" }.map { $0.form ?? [] }
    }

    func logon(languages: [String] = ["en-US"]) -> GatewayLogon {
        var logon = GatewayLogon(http: HTTPClient(), base: base, languages: languages)
        logon.http.trace = { _ in }
        logon.transport = { [self] method, url, _, form in
            self.requests.append((method, url.path, form))
            if method == "GET" {
                if url.path == "/" {
                    return response(Data("<html/>".utf8), path: "/logon/LogonPoint/tmindex.html")
                }
                if let text = self.strings[url.path] { return response(Data(text.utf8), path: url.path) }
                return response(Data(), path: url.path, status: 404)
            }
            guard !self.queue.isEmpty else { return response(Data("no more".utf8), status: 500) }
            return response(self.queue.removeFirst(), path: url.path)
        }
        return logon
    }
}

// MARK: Form parsing

@Test func fixtureParsesIntoTypedForm() async throws {
    let gateway = FakeGateway([try fixture()])
    let form = try await gateway.logon().begin()
    #expect(form.fields.map(\.kind) == [.heading, .username, .password, .passcode, .checkbox, .button])
    #expect(form.fields.map(\.id) == ["#0", "login", "passwd", "passwd1", "savecredentials", "Logon"])
    #expect(form.fields.map(\.label) == ["Please sign in", "User name:", "Password:", "Passcode:",
                                          "Remember my credentials", "Sign In"])
    #expect(form.fields[1].labelKey == "dualauth_user_name")
    #expect(form.fields[2].secret && form.fields[3].secret && !form.fields[1].secret)
    #expect(form.fields[1].constraint == ".+")
    #expect(form.fields[1].accepts("jan") && !form.fields[1].accepts(""))
    #expect(form.fields[4].isSaveCredentials && form.fields[4].initialValue == "false")
    #expect(form.fields[5].buttonValue == "dualauth_submit")
    #expect(form.postBack == "/nf/auth/doAuthentication.do" && form.cancelPostBack == "/nf/auth/doLogoff.do")
    #expect(!form.isRePrompt && form.errors.isEmpty)
    #expect(form.summary == "#0:heading,login:username,passwd:password,passwd1:passcode,savecredentials:checkbox,Logon:button")
}

@Test func fixtureLabelsInGermanFromBuiltInTable() async throws {
    let form = try await FakeGateway([try fixture()]).logon(languages: ["de-DE", "en-DE"]).begin()
    #expect(form.fields.map(\.label) == ["Bitte anmelden", "Benutzername:", "Kennwort:", "Passcode:",
                                          "Anmeldedaten merken", "Anmelden"])
}

@Test func labelsComeFromTheGatewayStringBundle() async throws {
    let gateway = FakeGateway([try fixture()])
    // Synthetic bundle in the RfWebUI shape: identifier and quoted keys, comments, escapes.
    gateway.strings["/logon/LogonPoint/receiver/js/localization/de/ctxs.strings.de.js"] = """
    // comment: "ignored": "x"
    (function ($) {
        $.localization.addStringBundle("de", {
            About: "Info",
            /* block */ "dualauth_user_name": "Nutzerkennung:",
            "dualauth_password":"Gatewaykennwort:",
            dualauth_submit: "Los \\u00e4\\"q\\"",
        });
    })(jQuery);
    """
    gateway.strings["/logon/LogonPoint/custom/strings.de.json"] = #"{"dualauth_password": "Domänenkennwort:"}"#
    let form = try await gateway.logon(languages: ["de-DE"]).begin()
    #expect(form.fields[1].label == "Nutzerkennung:")
    #expect(form.fields[2].label == "Domänenkennwort:")      // administrator override wins
    #expect(form.fields[3].label == "Passcode:")             // not in the bundle: built-in table
    #expect(form.fields[5].label == "Los ä\"q\"")
    #expect(form.strings.language == "de")
}

@Test func bundleParserAndLanguagePick() {
    let table = LogonStrings.parseBundle(#"x({a_b: "1", "c d": 'two', e: "ü\n", f: g, "h": "i"})"#)
    #expect(table == ["a_b": "1", "c d": "two", "e": "ü\n", "h": "i"])
    #expect(LogonStrings.pick(["hu-DE", "de-DE"]) == "de")
    #expect(LogonStrings.pick(["zh-Hant-TW"]) == "zh-TW")
    #expect(LogonStrings.pick(["hu"]) == "en")
    let strings = LogonStrings(language: "en")
    #expect(strings.text(for: "dualauthdeviceid_user_name") == "User name:")   // any schema prefix
    #expect(strings.text(for: "myschema_enter_pin_now") == "Enter pin now")    // humanised
    #expect(strings.text(for: "Incorrect credentials. Try again.") == "Incorrect credentials. Try again.")
    #expect(strings.text(for: "Literal text") == "Literal text")
}

@Test func passcodeInference() {
    let doc = xml(
        field("a", "password", "dualauthorotpregisterdynamic_password", secret: true)   // schema name contains "otp"
            + field("b", "password", "dualauthorpush_vip_or_totp", secret: true)
            + field("c", "passcode", "x_code")
            + field("d", "newpassword", "nsg_newpass", secret: true)
            + field("e", "textcredential", "nsg_domain")
            + field("f", "nfactor_otp", "y"))
    let form = LogonForm(try! FormResponse(response(doc)), strings: LogonStrings(language: "en"), postedIDs: [])
    #expect(form.fields.map(\.kind) == [.password, .passcode, .passcode, .newPassword, .text, .passcode])
}

@Test func encodeKeepsOrderForcesSaveCredentialsOffAndAddsState() throws {
    let doc = xml(field("login", "username", "u") + field("passwd", "password", "p")
        + "<Requirement><Credential><ID>savecredentials</ID><Type>savecredentials</Type></Credential><Label><Text>r</Text></Label>"
        + "<Input><CheckBox><InitialValue>true</InitialValue></CheckBox></Input></Requirement>" + submitButton, state: "S1")
    let form = LogonForm(try FormResponse(response(doc)), strings: LogonStrings(language: "en"), postedIDs: [])
    let body = GatewayLogon.encode(form, values: ["login": "u1", "passwd": "p1", "savecredentials": "true"], button: nil)
    #expect(body.map(\.0) == ["login", "passwd", "savecredentials", "Logon", "StateContext"])
    #expect(body.map(\.1) == ["u1", "p1", "false", "dualauth_submit", "S1"])
}

// MARK: Interactive sequence

@Test func multiFactorSequenceThenSuccess() async throws {
    let gateway = FakeGateway([
        xml(label("dualauth_please_log_on", type: "nsg-login-label")
            + field("login", "username", "dualauth_user_name") + field("passwd", "password", "dualauth_password", secret: true)
            + submitButton, state: "S1"),
        xml(label("Enter the code from your app", type: "plain")
            + field("otp", "password", "otp_passcode", secret: true) + submitButton, state: "S2"),
        xml(result: "success"),
    ])
    let logon = gateway.logon()
    let first = try await logon.begin()
    #expect(first.fields.map(\.kind) == [.heading, .username, .password, .button])
    guard case .form(let second) = try await logon.submit(first, values: ["login": "jan", "passwd": "pw"]) else {
        Issue.record("expected a second factor"); return
    }
    #expect(second.fields.map(\.kind) == [.heading, .passcode, .button])
    #expect(!second.isRePrompt)
    guard case .success = try await logon.submit(second, values: ["otp": "123456"]) else {
        Issue.record("expected success"); return
    }
    let posts = gateway.posts
    #expect(posts.count == 2)
    #expect(posts[0].map(\.0) == ["login", "passwd", "Logon", "StateContext"] && posts[0].last?.1 == "S1")
    #expect(posts[1].map(\.0) == ["otp", "Logon", "StateContext"] && posts[1][0].1 == "123456" && posts[1].last?.1 == "S2")
    #expect(gateway.requests.last?.path == "/cgi/setclient")
    // The logon starts at the requirements endpoint.
    #expect(gateway.requests.contains { $0.method == "POST" && $0.path == "/nf/auth/getAuthenticationRequirements.do" })
}

@Test func nativeLogonSkipsWebClientSelection() async throws {
    // docs/15 §1.1: native clients don't call /cgi/setclient?wica (ICA_SKIP_SETCLIENT=1 / native mode).
    let gateway = FakeGateway([
        xml(field("login", "username", "dualauth_user_name") + field("passwd", "password", "dualauth_password", secret: true)
            + submitButton, state: "S1"),
        xml(result: "success"),
    ])
    var logon = gateway.logon()
    logon.selectWebClient = false
    let form = try await logon.begin()
    guard case .success = try await logon.submit(form, values: ["login": "jan", "passwd": "pw"]) else {
        Issue.record("expected success"); return
    }
    #expect(!gateway.requests.contains { $0.path == "/cgi/setclient" })
}

@Test func rePromptCarriesErrorLabels() async throws {
    let again = xml(label("errorMessageLabel4001", type: "error") + field("login", "username", "dualauth_user_name")
        + field("passwd", "password", "dualauth_password", secret: true) + submitButton)
    let gateway = FakeGateway([try fixture(), again])
    let logon = gateway.logon(languages: ["de-DE"])
    let form = try await logon.begin()
    guard case .form(let next) = try await logon.submit(form, values: ["login": "jan", "passwd": "wrong", "passwd1": "1"]) else {
        Issue.record("expected a re-prompt"); return
    }
    #expect(next.isRePrompt)
    #expect(next.errors == ["Benutzername oder Kennwort ist falsch."])
    #expect(next.fields.first?.kind == .error)
}

@Test func failedResultIsReported() async throws {
    let gateway = FakeGateway([try fixture(), xml(label("Account Locked", type: "error"), result: "fail")])
    let logon = gateway.logon()
    let form = try await logon.begin()
    guard case .failed(let text) = try await logon.submit(form, values: [:]) else { Issue.record("expected failure"); return }
    #expect(text == "Account locked")
}

// MARK: Non-interactive

@Test func noTOTPFormLogsOnWithoutPasscode() async throws {
    let gateway = FakeGateway([
        xml(field("login", "username", "singleauth_user_name") + field("passwd", "password", "singleauth_password", secret: true)
            + submitButton),
        xml(result: "success"),
    ])
    var passcodeCalls = 0
    try await gateway.logon().logon(.init(username: "jan", password: "pw", passcode: { passcodeCalls += 1; return "x" }))
    #expect(passcodeCalls == 0)
    #expect(gateway.posts.count == 1)
    #expect(gateway.posts[0].map(\.0) == ["login", "passwd", "Logon"])
}

@Test func nonInteractiveLogonNeverRepostsThePassword() async throws {
    // The gateway answers the post with the same credential form again (wrong password or reused code).
    let gateway = FakeGateway([try fixture(), try fixture(), try fixture()])
    var passcodeCalls = 0
    await #expect(throws: GatewayLogon.Failure.self) {
        try await gateway.logon().logon(.init(username: "jan", password: "pw", passcode: { passcodeCalls += 1; return "123456" }))
    }
    #expect(gateway.posts.count == 1)
    #expect(passcodeCalls == 1)
}

@Test func nonInteractiveLogonWithoutPasscodeDoesNotPost() async throws {
    let gateway = FakeGateway([try fixture()])
    do {
        try await gateway.logon().logon(.init(username: "jan", password: "pw", passcode: { nil }))
        Issue.record("expected needsInput")
    } catch GatewayLogon.Failure.needsInput(let what) {
        #expect(what == "passcode")
    }
    #expect(gateway.posts.isEmpty)
}
