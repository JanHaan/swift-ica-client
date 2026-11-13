import Foundation
import Testing
@testable import ICAKit

// Fixtures follow the public examples in citrix/storefront-store-services-api (launch.md,
// resource-enumeration.md, accounts-service.md, endpoints-service.md) and citrix/storefront-authentication-sdk
// (citrixauth-authentication-scheme.md, security-token-services-api.md); hosts are example names.

private let gateway = URL(string: "https://gateway.example/")!
private let sf = "https://sf.internal"

private func reply(_ status: Int, _ body: String = "", headers: [String: String] = [:], url: URL) -> HTTPClient.Response {
    HTTPClient.Response(status: status, headers: headers, body: Data(body.utf8), url: url)
}

private func challenge(realm: String, location: String, hint: String, reason: String = "notoken") -> [String: String] {
    ["WWW-Authenticate": "CitrixAuth realm=\"\(realm)\", reqtokentemplate=\"\", reason=\"\(reason)\", "
        + "locations=\"\(location)\", serviceroot-hint=\"\(hint)\""]
}

private func tokenResponse(_ token: String, lifetime: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <requesttokenresponse xmlns="http://citrix.com/delivery-services/1-0/auth/requesttokenresponse">
      <for-service>x</for-service><issued>2012-06-12T09:50:53Z</issued><expiry>2012-06-13T05:50:53Z</expiry>
      <lifetime>\(lifetime)</lifetime><token-template /><token>\(token)</token>
    </requesttokenresponse>
    """
}

private let resourcesXML = """
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns="http://citrix.com/delivery-services/2-0/resources"
           xmlns:a="http://citrix.com/delivery-services/2-0/subscriptions" enumeration="full">
  <resource>
    <id>Controller.Notepad</id>
    <link><url>\(sf)/Citrix/Store/resources/v2/Q2l0cml4Lk1QUy5BcHAu</url></link>
    <title>Notepad</title><summary>Notepad</summary><path>\\</path>
    <resourcetype>Citrix.MPS.Application</resourcetype>
    <clienttypes><clienttype>ica30</clienttype><clienttype>rdp</clienttype></clienttypes>
    <enabled>true</enabled>
    <launchica><url>\(sf)/Citrix/Store/resources/v2/Q2l0cml4Lk1QUy5BcHAu/launch/ica</url></launchica>
    <icon><url>\(sf)/Citrix/Store/resources/v2/E4wNXorb0I5OHEvZlhsOWFZPQ--/icon</url></icon>
  </resource>
  <resource><id>Controller.Off</id><title>Off</title><enabled>false</enabled></resource>
</resources>
"""

private let endpointsXML = """
<endpoints xmlns="http://citrix.com/deliveryservices/1-0/endpoints">
  <endpoint id="Endpoints"><url>\(sf)/Citrix/Store/endpoints/v1</url><capabilities><capability>endpoints</capability></capabilities></endpoint>
  <endpoint id="ListResourcesWithAutoProvision"><url>\(sf)/Citrix/Store/resources/v2</url></endpoint>
  <endpoint id="ListSessions"><url>\(sf)/Citrix/Store/sessions/v1/available</url></endpoint>
</endpoints>
"""

/// Scripted StoreFront behind a gateway: store realm S, auth realm A, CitrixAGBasic pass-through.
private final class FakeStore: @unchecked Sendable {
    struct Request { let method: String; let url: URL; let headers: [String: String]; let body: String; let contentType: String? }
    var requests: [Request] = []
    var choices = ["ExplicitForms", "CitrixAGBasic"]
    var launchAnswers: [String] = []

    func client() -> NativeStoreClient {
        let http = HTTPClient()
        http.trace = { _ in }
        let client = NativeStoreClient(http: http, gateway: gateway, clientName: "MAC-ICA", deviceId: "dev-1",
                                       storePath: "/Citrix/Store")
        client.sleep = { _ in }
        client.transport = { [self] method, url, headers, body, contentType in
            self.requests.append(Request(method: method, url: url, headers: headers,
                                         body: String(decoding: body ?? Data(), as: UTF8.self), contentType: contentType))
            return self.answer(method, url, headers, String(decoding: body ?? Data(), as: UTF8.self))
        }
        return client
    }

    func answer(_ method: String, _ url: URL, _ headers: [String: String], _ body: String) -> HTTPClient.Response {
        let auth = headers["Authorization"]
        switch url.path {
        case "/Citrix/Store/discovery":
            return reply(200, "<discovery><endpoints><url>\(sf)/Citrix/Store/endpoints/v1</url></endpoints></discovery>", url: url)
        case "/Citrix/Store/endpoints/v1":
            return reply(200, endpointsXML, url: url)
        case "/Citrix/StoreAuth/auth/v1/token":
            if auth == "CitrixAuth PRIMARY", body.contains("<for-service>S</for-service>") {
                return reply(200, tokenResponse("SECONDARY", lifetime: "0.01:00:00"), url: url)
            }
            return reply(401, headers: challenge(realm: "A", location: "\(sf)/Citrix/StoreAuth/auth/v1/protocols",
                                                hint: "\(sf)/Citrix/StoreAuth/auth/v1/token"), url: url)
        case "/Citrix/StoreAuth/auth/v1/protocols":
            let list = choices.map {
                "<choice><protocol>\($0)</protocol><location>\(sf)/Citrix/StoreAuth/\($0)/Authenticate</location></choice>"
            }.joined()
            return reply(300, "<requesttokenchoices xmlns=\"http://citrix.com/delivery-services/1-0/auth/requesttokenchoices\"><choices>\(list)</choices></requesttokenchoices>",
                         headers: ["Content-Type": "application/vnd.citrix.requesttokenchoices+xml"], url: url)
        case "/Citrix/StoreAuth/CitrixAGBasic/Authenticate":
            return reply(200, tokenResponse("PRIMARY", lifetime: "0.20:00:00"), url: url)
        default:
            guard auth == "CitrixAuth SECONDARY" else {
                return reply(401, headers: challenge(realm: "S", location: "\(sf)/Citrix/StoreAuth/auth/v1/token",
                                                    hint: "\(sf)/Citrix/Store/"), url: url)
            }
            if url.path == "/Citrix/Store/resources/v2" { return reply(200, resourcesXML, url: url) }
            if url.path.contains("/launch/ica") {
                if launchAnswers.isEmpty { return reply(404, headers: ["X-Citrix-Error-Reason": "ResourceDisabled"], url: url) }
                return reply(200, launchAnswers.removeFirst(), url: url)
            }
            return reply(404, url: url)
        }
    }
}

private func launchSuccess(_ ica: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <launch status="success" xmlns="http://citrix.com/delivery-services/1-0/launch"><result type="ica">
      <ica>\(NativeStoreClient.xmlEscape(ica))</ica><logonTicket>85EB92973D2C3804F93A99AAEC232D</logonTicket></result>
    </launch>
    """
}

// MARK: Challenge

@Test func challengeParsesThePublicExample() throws {
    let header = """
    CitrixAuth realm="6b78ab94-a709-4e3a-8b9b-a49ca317c70c",
                                 reqtokentemplate="", reason="notoken",
                                 locations="https://www.example.com/Citrix/Authentication/auth/v1/token|https://b.example/t",
                                 serviceroot-hint=\u{201D}https://www.example.com/Citrix/Store2/resources/v2\u{201D}
    """
    let c = try #require(CitrixAuthChallenge(header: header))
    #expect(c.realm == "6b78ab94-a709-4e3a-8b9b-a49ca317c70c")
    #expect(c.reason == "notoken" && c.template == "")
    #expect(c.locations == ["https://www.example.com/Citrix/Authentication/auth/v1/token", "https://b.example/t"])
    #expect(c.serviceRootHint == "https://www.example.com/Citrix/Store2/resources/v2")
    #expect(CitrixAuthChallenge(header: "Basic realm=\"x\"") == nil)
    #expect(CitrixAuthChallenge(header: nil) == nil)
}

// MARK: Token flow and enumeration

@Test func tokenFlowUsesGatewayPassThroughAndTheGatewayOrigin() async throws {
    let fake = FakeStore()
    let client = fake.client()
    let resources = try await client.resources()
    #expect(resources.map(\.title) == ["Notepad", "Off"])
    #expect(resources[0].enabled && !resources[1].enabled && resources[1].launchURL == nil)
    #expect(resources[0].clientTypes == ["ica30", "rdp"])
    #expect(resources[0].launchURL?.absoluteString
        == "https://gateway.example/Citrix/Store/resources/v2/Q2l0cml4Lk1QUy5BcHAu/launch/ica")
    #expect(client.lastProtocol == "CitrixAGBasic")
    #expect(client.offeredProtocols == ["ExplicitForms", "CitrixAGBasic"])
    // Everything went to the gateway with the gateway header; ExplicitForms was never used.
    #expect(fake.requests.allSatisfy { $0.url.host == "gateway.example" && $0.headers["X-Citrix-Gateway"] == "gateway.example" })
    #expect(fake.requests.allSatisfy { $0.headers["Citrix-TransactionId"] != nil })
    #expect(!fake.requests.contains { $0.url.path.contains("ExplicitForms") })
    // The pass-through post carries no credentials of ours.
    let agBasic = try #require(fake.requests.first { $0.url.path.hasSuffix("/CitrixAGBasic/Authenticate") })
    #expect(agBasic.headers["Authorization"] == nil)
    #expect(agBasic.contentType == "application/vnd.citrix.requesttoken+xml")
    #expect(agBasic.body.contains("<for-service>A</for-service>") && agBasic.body.contains("<reqtokentemplate/>"))
    // Enumeration: clientName query, then the secondary token.
    let list = fake.requests.filter { $0.url.path == "/Citrix/Store/resources/v2" }
    #expect(list.count == 2 && list.last?.headers["Authorization"] == "CitrixAuth SECONDARY")
    #expect(list.last?.url.query == "clientName=MAC-ICA")
    #expect(list.last?.headers["Accept"] == "application/vnd.citrix.resources+xml")
    // No web-API leftovers and no App Protection claim.
    #expect(!fake.requests.contains { $0.headers["Csrf-Token"] != nil || $0.headers["X-Citrix-AppProtection-Capable"] != nil })

    // A second call reuses the cached token: one request, no new token traffic.
    let before = fake.requests.count
    _ = try await client.resources()
    #expect(fake.requests.count == before + 1)
}

@Test func noGatewayProtocolIsAnErrorNotAPasswordPost() async throws {
    let fake = FakeStore()
    fake.choices = ["ExplicitForms"]
    await #expect(throws: NativeStoreClient.Failure.self) { _ = try await fake.client().resources() }
    #expect(!fake.requests.contains { $0.url.path.contains("ExplicitForms") })
}

@Test func accountServiceGivesTheStorePath() throws {
    let xml = """
    <accounts xmlns="http://citrix.com/delivery-services/2-1/accounts" xmlns:sr="http://www.citrix.com/ServiceRecord">
    <account><id>775552B2</id><name>Store</name><details><annotatedServices><annotatedService>
    <sr:Service type="Store"><sr:SRID>1</sr:SRID><sr:Name>Store</sr:Name>
    <sr:Address>https://storefront01/Citrix/Store/discovery</sr:Address></sr:Service>
    </annotatedService></annotatedServices></details></account></accounts>
    """
    #expect(NativeStoreClient.parseAccountStores(Data(xml.utf8)) == ["https://storefront01/Citrix/Store/discovery"])
}

@Test func endpointsAndGatewayRewrite() throws {
    let map = NativeStoreClient.parseEndpoints(Data(endpointsXML.utf8))
    #expect(map["ListSessions"]?.path == "/Citrix/Store/sessions/v1/available")
    let client = NativeStoreClient(http: HTTPClient(), gateway: gateway, clientName: "c", deviceId: "d")
    let url = client.throughGateway(URL(string: "https://sf.internal:8443/Citrix/Store/resources/v2?clientName=x")!)
    #expect(url.absoluteString == "https://gateway.example/Citrix/Store/resources/v2?clientName=x")
}

// MARK: Launch

@Test func launchParamsMatchTheStockShapeWithoutWebFields() throws {
    let start = Date(timeIntervalSince1970: 0)
    let plain = String(decoding: NativeStoreClient.launchParams(deviceId: "d<1", clientName: "MAC-ICA", launcher: nil, start: start), as: UTF8.self)
    #expect(plain.contains("xmlns=\"http://citrix.com/delivery-services/1-0/launchparams\""))
    #expect(plain.contains("<deviceId>d&lt;1</deviceId><clientName>MAC-ICA</clientName><display>seamless</display>"))
    #expect(plain.contains("<LaunchSource>WorkspaceApp</LaunchSource>"))
    #expect(plain.contains("<ResourceLaunchStartTime>1970-01-01 00:00:00.000</ResourceLaunchStartTime>"))
    #expect(!plain.contains("launcher>") && !plain.contains("clientAddress") && !plain.contains("Csrf")
        && !plain.contains("displayNameDesktopTitle") && !plain.contains("AppProtection"))
    let withLauncher = String(decoding: NativeStoreClient.launchParams(deviceId: "d", clientName: "c", launcher: "WI", start: start), as: UTF8.self)
    #expect(withLauncher.contains("<launcher>WI</launcher>"))
}

@Test func launchFollowsRetryThenReturnsTheUnescapedICAFile() async throws {
    let fake = FakeStore()
    let ica = "[Encoding]\nInputEncoding=UTF8\n[ApplicationServers]\nNotepad=\n[Notepad]\nInitialProgram=#Notepad & <x>\n"
    fake.launchAnswers = [
        """
        <launch status="retry" xmlns="http://citrix.com/delivery-services/1-0/launch"><result type="retry"><retry>
        <url>\(sf)/Citrix/Store/resources/v2/Q2l0cml4Lk1QUy5BcHAu/launch/ica/bbb567</url><after>30</after><reason>unknown</reason>
        </retry></result></launch>
        """,
        launchSuccess(ica),
    ]
    let client = fake.client()
    let notepad = try #require(try await client.resources().first)
    let text = try await client.launchICA(notepad)
    #expect(ICAFile(text: text)?["InitialProgram"] == "#Notepad & <x>")
    let launches = fake.requests.filter { $0.url.path.contains("/launch/ica") }
    #expect(launches.map(\.url.path) == ["/Citrix/Store/resources/v2/Q2l0cml4Lk1QUy5BcHAu/launch/ica",
                                         "/Citrix/Store/resources/v2/Q2l0cml4Lk1QUy5BcHAu/launch/ica/bbb567"])
    #expect(launches.allSatisfy { $0.contentType == "application/vnd.citrix.launchparams+xml"
        && $0.headers["Accept"] == "application/vnd.citrix.launchdata+xml" && $0.url.host == "gateway.example" })
}

@Test func launchFailureAndNotFoundReasons() async throws {
    let fake = FakeStore()
    fake.launchAnswers = [
        "<launch xmlns=\"http://citrix.com/delivery-services/1-0/launch\" status=\"failure\"><result type=\"error\"><error><id>ResourceUnavailable</id><text>The resource is unavailable</text></error></result></launch>",
    ]
    let client = fake.client()
    let notepad = try #require(try await client.resources().first)
    do { _ = try await client.launchICA(notepad); Issue.record("expected failure") } catch {
        #expect("\(error)".contains("ResourceUnavailable"))
    }
    do { _ = try await client.launchICA(notepad); Issue.record("expected 404") } catch {
        #expect("\(error)".contains("404") && "\(error)".contains("ResourceDisabled"))
    }
}

@Test func launchDataParsesThePublicExample() throws {
    let parsed = NativeStoreClient.parseLaunch(Data(launchSuccess("[WFClient]\nVersion=2\n").utf8))
    #expect(parsed == .success(ica: "[WFClient]\nVersion=2", logonTicket: "85EB92973D2C3804F93A99AAEC232D"))
    #expect(NativeStoreClient.parseLaunch(Data("<html/>".utf8)) == nil)
}

// MARK: Key diff and device id

@Test func keyDiffNeverShowsSecretValues() throws {
    let web = try #require(ICAFile(text: "[A]\nLauncher=WI\nAddress=SECRET1\nWebSocketPort=8008\nLogonTicket=T1\n"))
    let native = try #require(ICAFile(text: "[A]\nAddress=SECRET2\nLogonTicket=T2\nLaunchSource=WorkspaceApp\n"))
    let text = ICAKeyDiff.lines(web: web, native: native).joined(separator: "\n")
    #expect(text.contains("Launcher=WI") && text.contains("LaunchSource=WorkspaceApp") && text.contains("WebSocketPort=8008"))
    #expect(text.contains("Address (value differs)"))
    #expect(!text.contains("SECRET") && !text.contains("T1") && !text.contains("T2"))
}

@Test func deviceIdIsStableAndPrivate() throws {
    let path = NSTemporaryDirectory() + "native-device-id-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let first = NativeDeviceId.loadOrCreate(path: path)
    #expect(NativeDeviceId.loadOrCreate(path: path) == first && !first.isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}
