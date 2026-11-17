import Foundation
import Testing
@testable import ICAKit

// Direct StoreFront logon without a gateway (docs/16 §2, §3). Fixtures follow the public examples: the StoreFront
// Web API "Getting started" and "Explicit forms authentication examples" pages, and the Common Forms language and
// token-services documents of citrix/storefront-authentication-sdk. Example host names only.

private let storeBase = URL(string: "http://storefront.example/Citrix/StoreWeb/")!

private func reply(_ status: Int, _ body: String = "", headers: [String: String] = [:], url: URL) -> HTTPClient.Response {
    HTTPClient.Response(status: status, headers: headers, body: Data(body.utf8), url: url)
}

private let clientSettings = """
<?xml version="1.0" encoding="utf-8"?>
<clientSettings xmlns="http://citrix.com/delivery-services/webAPI/2-6/clientConfig">
  <authManager getUserNameURL="Authentication/GetUserName" logoffURL="Authentication/Logoff" />
  <resourcesProxy listURL="Resources/List" />
  <sessionsProxy listAvailableURL="Sessions/ListAvailable" disconnectURL="Sessions/Disconnect" logoffURL="Sessions/Logoff" />
</clientSettings>
"""

private let authMethods = """
<?xml version="1.0" encoding="UTF-8"?>
<authMethods xmlns="http://citrix.com/deliveryservices/webAPI/2-6/authMethods">
  <method name="IntegratedWindows" url="DomainPassthroughAuth/Login" />
  <method name="Certificate" url="SmartcardAuth/Login" />
  <method name="ExplicitForms" url="ExplicitAuth/Login" />
</authMethods>
"""

private func requirement(_ id: String, _ type: String, _ label: String, input: String) -> String {
    "<Requirement><Credential><ID>\(id)</ID><SaveID>ExplicitForms-\(id)</SaveID><Type>\(type)</Type></Credential>"
        + "<Label><Text>\(label)</Text><Type>plain</Type></Label><Input>\(input)</Input></Requirement>"
}

private func textInput(secret: Bool = false, initial: String = "") -> String {
    "<Text><Secret>\(secret)</Secret><ReadOnly>false</ReadOnly><InitialValue>\(initial)</InitialValue><Constraint>.+</Constraint></Text>"
}

private func loginForm(domainList: Bool = false, error: String? = nil, username: String = "", state: String = "ctx-1") -> String {
    var reqs = ""
    if let error {
        reqs += "<Requirement><Credential><Type>none</Type></Credential><Label><Text>\(error)</Text><Type>error</Type></Label></Requirement>"
    }
    reqs += requirement("username", "username", "User name:", input: "<AssistiveText>domain\\user or user@domain</AssistiveText>" + textInput(initial: username))
    reqs += requirement("password", "password", "Password:", input: textInput(secret: true))
    if domainList {
        reqs += requirement("domain", "domain", "Domain:", input: """
        <ComboBox><InitialSelection>corp</InitialSelection><DisplayValues>
        <DisplayValue><Display>CORP</Display><Value>corp</Value></DisplayValue>
        <DisplayValue><Display>LAB</Display><Value>lab</Value></DisplayValue>
        </DisplayValues></ComboBox>
        """)
    }
    reqs += "<Requirement><Credential><ID>saveCredentials</ID><Type>savecredentials</Type></Credential>"
        + "<Label><Text>Remember my password</Text><Type>plain</Type></Label><Input><CheckBox><InitialValue>false</InitialValue></CheckBox></Input></Requirement>"
    reqs += "<Requirement><Credential><ID>loginBtn</ID><Type>none</Type></Credential><Label><Type>none</Type></Label>"
        + "<Input><Button>Log On</Button></Input></Requirement>"
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <AuthenticateResponse xmlns="http://citrix.com/authentication/response/1">
      <Status>success</Status><Result>more-info</Result>\(state.isEmpty ? "<StateContext />" : "<StateContext>\(state)</StateContext>")
      <AuthenticationRequirements><PostBack>ExplicitAuth/LoginAttempt</PostBack>
      <CancelPostBack>ExplicitAuth/CancelForm</CancelPostBack><CancelButtonText>Cancel</CancelButtonText>
      <Requirements>\(reqs)</Requirements></AuthenticationRequirements>
    </AuthenticateResponse>
    """
}

private let loginSuccess = """
<?xml version="1.0" encoding="UTF-8"?>
<AuthenticationStatus xmlns="http://citrix.com/deliveryservices/webAPI/2-6/authStatus">
  <Result>success</Result><AuthType>ExplicitForms</AuthType>
</AuthenticationStatus>
"""

/// Scripted Receiver for Web site at `storeBase`: checks the password, records requests.
private final class FakeWebStore: @unchecked Sendable {
    struct Request { let method: String; let path: String; let headers: [String: String]; let form: [(String, String)]? }
    var requests: [Request] = []
    var domainList = false
    var methods = authMethods
    var state = "ctx-1"
    let password = "pw-1"

    var attempts: [[(String, String)]] { requests.filter { $0.path.hasSuffix("/ExplicitAuth/LoginAttempt") }.map { $0.form ?? [] } }

    func logon() -> StoreFrontLogon {
        var logon = StoreFrontLogon(http: HTTPClient(), base: storeBase, languages: ["en-US", "de-DE"])
        logon.http.trace = { _ in }
        logon.transport = { [self] method, url, headers, form in
            requests.append(Request(method: method, path: url.path, headers: headers, form: form))
            switch url.path {
            case "/Citrix/StoreWeb/Home/Configuration": return reply(200, clientSettings, url: url)
            case "/Citrix/StoreWeb/Authentication/GetAuthMethods": return reply(200, methods, url: url)
            case "/Citrix/StoreWeb/Resources/List":
                return reply(200, #"{"unauthorized": true}"#,
                             headers: ["CitrixWebReceiver-Authenticate": #"reason="TokenRequired", location="Authentication/GetAuthMethods""#], url: url)
            case "/Citrix/StoreWeb/ExplicitAuth/Login": return reply(200, loginForm(domainList: domainList, state: state), url: url)
            case "/Citrix/StoreWeb/ExplicitAuth/LoginAttempt":
                let fields = Dictionary(form ?? [], uniquingKeysWith: { a, _ in a })
                if fields["password"] == password { return reply(200, loginSuccess, url: url) }
                return reply(200, loginForm(domainList: domainList, error: "Incorrect user name or password",
                                            username: fields["username"] ?? ""), url: url)
            default: return reply(404, url: url)
            }
        }
        return logon
    }
}

@Suite struct StoreFrontLogonTests {
    @Test func explicitLogonFollowsTheWebAPIFlow() async throws {
        let store = FakeWebStore()
        try await store.logon().logon(.init(username: "CORP\\user1", password: "pw-1"))
        // The sequence of the lab's working logon (D107): site page, configuration, the unauthenticated list, methods.
        #expect(store.requests.map(\.path) == ["/Citrix/StoreWeb", "/Citrix/StoreWeb/Home/Configuration", "/Citrix/StoreWeb/Resources/List",
                                               "/Citrix/StoreWeb/Authentication/GetAuthMethods",
                                               "/Citrix/StoreWeb/ExplicitAuth/Login", "/Citrix/StoreWeb/ExplicitAuth/LoginAttempt"])
        #expect(store.requests.map(\.method) == ["GET", "POST", "POST", "POST", "POST", "POST"])
        #expect(store.requests[2].form?.map(\.0) == ["format", "resourceDetails"])
        // Plain HTTP store: the HTTPS indicator is No, so the store's cookies are not marked Secure.
        #expect(store.requests.allSatisfy { $0.headers["X-Citrix-IsUsingHTTPS"] == "No" })
        let login = try #require(store.requests.first { $0.path.hasSuffix("/ExplicitAuth/Login") })
        #expect(login.headers["X-Citrix-AM-CredentialTypes"]?.contains("domain") == true)
        #expect(login.headers["Accept-Language"] == "en-US, de-DE;q=0.8")
        let fields = try #require(store.attempts.first).map(\.0)
        #expect(fields == ["username", "password", "saveCredentials", "loginBtn", "StateContext"])
        let values = Dictionary(store.attempts[0], uniquingKeysWith: { a, _ in a })
        #expect(values["username"] == "CORP\\user1" && values["saveCredentials"] == "false")
        #expect(values["loginBtn"] == "Log On" && values["StateContext"] == "ctx-1")
    }

    @Test func emptyStateContextIsPostedBack() async throws {
        // Live (D107): the lab store answers `<StateContext />` and wants `StateContext=` back; without it: Result fail.
        let store = FakeWebStore()
        store.state = ""
        try await store.logon().logon(.init(username: "user1", password: "pw-1", domain: "CORP"))
        let fields = try #require(store.attempts.first)
        #expect(fields.map(\.0) == ["username", "password", "saveCredentials", "loginBtn", "StateContext"])
        #expect(fields.last?.1 == "")
        // No domain field: the domain becomes the `DOMAIN\user` prefix.
        #expect(fields.first?.1 == "CORP\\user1")
    }

    @Test func deviceIdOfAnotherHostIsNeitherRestoredNorOverwritten() {
        let http = HTTPClient()
        final class Memory: DeviceIdentityStore {
            var record: [String: String]? = ["value": "gw-dev", "domain": "gateway.example", "path": "/welcome/"]
            func load() -> [String: String]? { record }
            func save(_ r: [String: String]) { record = r }
        }
        let store = Memory()
        DeviceIdentity.restore(into: http, from: store, base: storeBase)
        #expect(http.cookieRecords(DeviceIdentity.cookieName).isEmpty)
        http.setCookie(HTTPCookie(properties: [.name: "CtxsDeviceId", .value: "gw-dev", .domain: "gateway.example", .path: "/welcome/"])!)
        DeviceIdentity.restore(into: http, from: store, base: storeBase)
        DeviceIdentity.remember(from: http, into: store, base: storeBase)
        #expect(store.record?["value"] == "gw-dev")   // nothing for this store's host yet: the record stays
    }

    @Test func csrfTokenComesFromTheStoresOwnCookie() async throws {
        // A jar loaded from disk may also hold a gateway's CsrfToken (D107: 403 on GetAuthMethods).
        let store = FakeWebStore()
        let logon = store.logon()
        for (host, value) in [("gateway.example", "GATEWAY-TOKEN"), ("storefront.example", "STORE-TOKEN")] {
            let path = host == "gateway.example" ? "/" : "/Citrix/StoreWeb/"
            logon.http.setCookie(HTTPCookie(properties: [.name: "CsrfToken", .value: value, .domain: host, .path: path])!)
        }
        #expect(logon.http.cookie("CsrfToken", for: storeBase) == "STORE-TOKEN")
        #expect(logon.http.cookie("CsrfToken", for: URL(string: "https://gateway.example/welcome/")!) == "GATEWAY-TOKEN")
        _ = try await logon.begin()
        #expect(store.requests.filter { $0.method == "POST" }.allSatisfy { $0.headers["Csrf-Token"] == "STORE-TOKEN" })
    }

    @Test func formParsesIntoTypedFields() async throws {
        let form = try await FakeWebStore().logon().begin()
        #expect(form.fields.map(\.kind) == [.username, .password, .checkbox, .button])
        #expect(form.fields.map(\.label) == ["User name:", "Password:", "Remember my password", "Log On"])
        #expect(form.postBack == "ExplicitAuth/LoginAttempt" && form.cancelPostBack == "ExplicitAuth/CancelForm")
    }

    @Test func wrongPasswordIsNeverRetried() async throws {
        let store = FakeWebStore()
        await #expect(throws: GatewayLogon.Failure.self) {
            try await store.logon().logon(.init(username: "user1", password: "wrong"))
        }
        #expect(store.attempts.count == 1)
    }

    @Test func interactiveRePromptShowsTheError() async throws {
        let store = FakeWebStore()
        let logon = store.logon()
        let form = try await logon.begin()
        guard case .form(let again) = try await logon.submit(form, values: ["username": "u", "password": "x"], button: nil) else {
            Issue.record("expected the form again"); return
        }
        #expect(again.isRePrompt && again.errors == ["Incorrect user name or password"])
        #expect(again.fields.first { $0.kind == .username }?.initialValue == "u")
    }

    @Test func domainListGetsTheDomainAndTheBareUserName() async throws {
        let store = FakeWebStore()
        store.domainList = true
        let form = try await store.logon().begin()
        let domain = try #require(form.fields.first { $0.kind == .domain })
        #expect(domain.choices == [.init(display: "CORP", value: "corp"), .init(display: "LAB", value: "lab")])
        #expect(domain.initialValue == "corp" && domain.accepts("lab") && !domain.accepts("other"))
        try await store.logon().logon(.init(username: "LAB\\user1", password: "pw-1"))
        let values = Dictionary(store.attempts[0], uniquingKeysWith: { a, _ in a })
        #expect(values["username"] == "user1" && values["domain"] == "lab")
        // An explicit domain wins; a name not in the list is refused before anything is posted.
        #expect(throws: GatewayLogon.Failure.self) {
            try GatewayLogon.values(for: form, .init(username: "user1", password: "p", domain: "nope"))
        }
        let byDisplay = try GatewayLogon.values(for: form, .init(username: "user1", password: "p", domain: "corp"))
        #expect(byDisplay["domain"] == "corp" && byDisplay["username"] == "user1")
    }

    @Test func storeWithoutExplicitFormsSaysSo() async throws {
        let store = FakeWebStore()
        store.methods = "<authMethods><method name=\"IntegratedWindows\" url=\"DomainPassthroughAuth/Login\"/></authMethods>"
        await #expect(throws: StoreFrontLogon.Failure.noExplicitForms(["IntegratedWindows"])) {
            try await store.logon().begin()
        }
    }

    @Test func authMethodsParse() {
        let methods = StoreFrontLogon.parseAuthMethods(Data(authMethods.utf8))
        #expect(methods.map(\.name) == ["IntegratedWindows", "Certificate", "ExplicitForms"])
        #expect(methods.last?.url == "ExplicitAuth/Login")
    }

    @Test func httpsIndicator() {
        #expect(StoreFrontLogon.usingHTTPS(URL(string: "https://storefront.example/Citrix/StoreWeb/")!) == "Yes")
        #expect(StoreFrontLogon.usingHTTPS(storeBase) == "No")
        #expect(StoreClient(http: HTTPClient(), directBase: URL(string: "http://storefront.example/Citrix/StoreWeb")!).usingHTTPS == "No")
        #expect(StoreClient(http: HTTPClient(), base: URL(string: "https://gateway.example/welcome/")!).usingHTTPS == "Yes")
        #expect(StoreClient(http: HTTPClient(), directBase: storeBase).base.absoluteString.hasSuffix("/StoreWeb/"))
    }

    @Test func directStoreWithoutLogonHandlerAsksForLogon() async {
        let store = StoreClient(http: HTTPClient(), directBase: storeBase)
        await #expect(throws: StoreClient.Failure.self) { try await store.signIn() }
    }
}

// MARK: - Account address and kind

@Suite struct AccountProbeTests {
    func page(_ path: String, _ body: String = "<html/>", cookies: String? = nil) -> HTTPClient.Response {
        reply(200, body, headers: cookies.map { ["Set-Cookie": $0] } ?? [:], url: URL(string: "https://host.example" + path)!)
    }

    let typed = URL(string: "https://host.example/")!

    @Test func gatewayLogonPage() {
        #expect(AccountProbe.classify(requested: typed, response: page("/logon/LogonPoint/tmindex.html"))
            == .init(kind: .gateway, url: typed))
        #expect(AccountProbe.classify(requested: typed, response: page("/", cookies: "NSC_TMAS=x; path=/"))?.kind == .gateway)
    }

    @Test func storeFrontRedirectKeepsTheSitePath() {
        let found = AccountProbe.classify(requested: typed, response: page("/Citrix/StoreWeb/"))
        #expect(found == .init(kind: .storeFront, url: URL(string: "https://host.example/Citrix/StoreWeb/")!))
        let deep = AccountProbe.classify(requested: typed, response: page("/Citrix/StoreWeb/receiver.html"))
        #expect(deep?.url.absoluteString == "https://host.example/Citrix/StoreWeb/")
    }

    @Test func storeFrontLinkedFromThePage() {
        let found = AccountProbe.classify(requested: typed,
                                          response: page("/", "<script>window.location='/Citrix/LabWeb/';</script>"))
        #expect(found?.kind == .storeFront && found?.url.absoluteString == "https://host.example/Citrix/LabWeb/")
    }

    @Test func somethingElseIsNotRecognised() {
        #expect(AccountProbe.classify(requested: typed, response: page("/iisstart.htm")) == nil)
    }

    @Test func storeServicesPathFallsBackToItsWebSite() async throws {
        var probe = AccountProbe(http: HTTPClient())
        var posted: [String] = []
        probe.transport = { method, url, _, _ in
            if method == "GET" { return reply(200, "<x/>", url: URL(string: "http://192.0.2.11/Citrix/Store/discovery")!) }
            posted.append(url.path)
            return url.path == "/Citrix/StoreWeb/Home/Configuration" ? reply(200, clientSettings, url: url) : reply(404, url: url)
        }
        let found = try await probe.probe(URL(string: "http://192.0.2.11/Citrix/Store/")!)
        #expect(found == .init(kind: .storeFront, url: URL(string: "http://192.0.2.11/Citrix/StoreWeb/")!))
        #expect(posted == ["/Citrix/Store/Home/Configuration", "/Citrix/StoreWeb/Home/Configuration"])
    }

    @Test func typedAddresses() {
        #expect(LoginSettings.accountURL(from: "gateway.example")?.absoluteString == "https://gateway.example/")
        #expect(LoginSettings.accountURL(from: "http://192.0.2.11")?.absoluteString == "http://192.0.2.11/")
        #expect(LoginSettings.accountURL(from: "storefront.example/Citrix/StoreWeb")?.absoluteString
            == "https://storefront.example/Citrix/StoreWeb/")
        #expect(LoginSettings.storeFrontURL(from: "ftp://x") == nil)
        var s = LoginSettings()
        s.gatewayURL = "http://192.0.2.11/Citrix/StoreWeb/"
        s.accountKind = .storeFront
        #expect(s.account?.absoluteString == "http://192.0.2.11/Citrix/StoreWeb/" && s.gatewayHost == "192.0.2.11")
        s.accountKind = .gateway
        #expect(s.account == nil)   // a gateway is https only
    }
}

// MARK: - Native Store Services API, direct with ExplicitForms

/// A StoreFront reached directly at https://storefront.example: store realm S, auth realm A, the ExplicitForms
/// protocol answering with a Common Forms conversation that ends with the primary token [P AUTH].
private final class FakeDirectNativeStore: @unchecked Sendable {
    struct Request { let method: String; let url: URL; let headers: [String: String]; let body: String; let contentType: String? }
    var requests: [Request] = []
    let sf = "https://storefront.example"

    func client() -> NativeStoreClient {
        let http = HTTPClient()
        http.trace = { _ in }
        let client = NativeStoreClient(http: http, gateway: URL(string: sf + "/")!, clientName: "MAC-ICA", deviceId: "dev-1",
                                       storePath: "/Citrix/Store")
        client.direct = true
        client.explicitCredentials = .init(username: "CORP\\user1", password: "pw-1")
        client.sleep = { _ in }
        client.transport = { [self] method, url, headers, body, contentType in
            let text = String(decoding: body ?? Data(), as: UTF8.self)
            requests.append(Request(method: method, url: url, headers: headers, body: text, contentType: contentType))
            return answer(url, headers, text, contentType)
        }
        return client
    }

    func challenge(_ realm: String, _ location: String, hint: String) -> [String: String] {
        ["WWW-Authenticate": "CitrixAuth realm=\"\(realm)\", reqtokentemplate=\"\", reason=\"notoken\", locations=\"\(location)\", serviceroot-hint=\"\(hint)\""]
    }

    func token(_ value: String) -> String {
        "<requesttokenresponse xmlns=\"http://citrix.com/delivery-services/1-0/auth/requesttokenresponse\"><for-service>x</for-service><lifetime>0.20:00:00</lifetime><token>\(value)</token></requesttokenresponse>"
    }

    func answer(_ url: URL, _ headers: [String: String], _ body: String, _ contentType: String?) -> HTTPClient.Response {
        let auth = headers["Authorization"]
        switch url.path {
        case "/Citrix/Store/discovery": return reply(200, "<discovery/>", url: url)
        case "/Citrix/Store/endpoints/v1":
            return reply(200, "<endpoints><endpoint id=\"ListResources\"><url>\(sf)/Citrix/Store/resources/v2</url></endpoint></endpoints>", url: url)
        case "/Citrix/StoreAuth/auth/v1/token":
            if auth == "CitrixAuth PRIMARY", body.contains("<for-service>S</for-service>") { return reply(200, token("SECONDARY"), url: url) }
            return reply(401, headers: challenge("A", "\(sf)/Citrix/StoreAuth/auth/v1/protocols", hint: "\(sf)/Citrix/StoreAuth/auth/v1/token"), url: url)
        case "/Citrix/StoreAuth/auth/v1/protocols":
            return reply(300, "<requesttokenchoices><choices><choice><protocol>CitrixAGBasic</protocol><location>\(sf)/Citrix/StoreAuth/CitrixAGBasic/Authenticate</location></choice>"
                         + "<choice><protocol>ExplicitForms</protocol><location>\(sf)/Citrix/StoreAuth/ExplicitForms/Start</location></choice></choices></requesttokenchoices>", url: url)
        case "/Citrix/StoreAuth/ExplicitForms/Start":
            return reply(200, loginForm().replacingOccurrences(of: "ExplicitAuth/LoginAttempt", with: "/Citrix/StoreAuth/ExplicitForms/AuthenticateAttempt"),
                         headers: ["Content-Type": "application/vnd.citrix.authenticateresponse-1+xml"], url: url)
        case "/Citrix/StoreAuth/ExplicitForms/AuthenticateAttempt":
            guard contentType == "application/x-www-form-urlencoded", body.contains("password=pw-1"),
                  body.contains("username=CORP%5Cuser1") else { return reply(200, loginForm(error: "Incorrect user name or password"), url: url) }
            return reply(200, token("PRIMARY"), url: url)
        case "/Citrix/Store/resources/v2":
            guard auth == "CitrixAuth SECONDARY" else {
                return reply(401, headers: challenge("S", "\(sf)/Citrix/StoreAuth/auth/v1/token", hint: "\(sf)/Citrix/Store"), url: url)
            }
            return reply(200, "<resources><resource><id>Controller.Notepad</id><title>Notepad</title><enabled>true</enabled></resource></resources>", url: url)
        default: return reply(404, url: url)
        }
    }
}

@Test func nativeDirectTokenFlowUsesExplicitForms() async throws {
    let fake = FakeDirectNativeStore()
    let client = fake.client()
    let resources = try await client.resources()
    #expect(resources.map(\.title) == ["Notepad"])
    #expect(client.lastProtocol == "ExplicitForms")
    // No gateway header in direct mode; nothing went to the CitrixAGBasic location.
    #expect(fake.requests.allSatisfy { $0.headers["X-Citrix-Gateway"] == nil && $0.url.host == "storefront.example" })
    #expect(!fake.requests.contains { $0.url.path.contains("CitrixAGBasic") })
    let start = try #require(fake.requests.first { $0.url.path.hasSuffix("/ExplicitForms/Start") })
    #expect(start.contentType == "application/vnd.citrix.requesttoken+xml")
    #expect(start.headers["Accept"]?.contains("application/vnd.citrix.authenticateresponse-1+xml") == true)
    let attempt = try #require(fake.requests.first { $0.url.path.hasSuffix("/AuthenticateAttempt") })
    #expect(attempt.body.contains("StateContext=ctx-1") && attempt.body.contains("saveCredentials=false"))
    #expect(attempt.headers["Accept"]?.contains("requesttokenresponse") == true)
}

@Test func nativeDirectWrongPasswordStopsAfterOnePost() async throws {
    let fake = FakeDirectNativeStore()
    let client = fake.client()
    client.explicitCredentials = .init(username: "CORP\\user1", password: "wrong")
    await #expect(throws: NativeStoreClient.Failure.self) { _ = try await client.resources() }
    #expect(fake.requests.filter { $0.url.path.hasSuffix("/AuthenticateAttempt") }.count == 1)
}
