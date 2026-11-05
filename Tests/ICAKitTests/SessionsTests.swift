import Foundation
import Testing
@testable import ICAKit

// Fixtures are written from docs/90 (the StoreFront Web API examples quoted there); no real data.

private let listJSON = #"""
{ "deviceId": "WR_MO-969cDcqgF",
  "sessions": [ {
    "sessionId": "Q29udHJvbGxlci5TLTEtNS0x",
    "connectionState": "connected",
    "userSessionType": "Application",
    "sessionStartTime": "2023-11-21T15:50:10.43Z",
    "clientName": "WR_MO-969cDcqgF", "clientType": "ica30",
    "deviceId": "WR_MO-969cDcqgF", "deviceType": "Windows",
    "applications": [ { "id": "Controller.Calculator", "name": "Calculator", "iconUrl": "Resources/Icon/x" } ],
    "machineData": { "machineId": "Controller.S-1-5-21-1", "machineName": "DOMAIN\\CVAD-01",
      "powerState": "Unmanaged", "registrationState": "Registered", "sessionSupport": "MultiSession",
      "shutDownSupported": false, "turnOffSupported": false } } ] }
"""#

private let availableJSON = #"""
[ { "launchurl": "Sessions/LaunchIca/Q29udHJvbGxlci4xODM5MC4y",
    "launchstatusurl": "Sessions/GetLaunchStatus/Q29udHJvbGxlci4xODM5MC4y",
    "initialapp": "Calculator", "publishername": "Controller" } ]
"""#

private let configXML = #"""
<clientSettings><storeProxy keepAliveURL="Home/KeepAlive">
<sessionsProxy listAvailableURL="Sessions/ListAvailable" disconnectURL="Sessions/Disconnect" logoffURL="Sessions/Logoff"/>
<sessionControlProxy listSessionsURL="Sessions/List" logoffSessionsURL="Sessions/LogOffSessions" disconnectSessionsURL="Sessions/DisconnectSessions"/>
<machinesProxy powerOffMachineURL="Machines/PowerOff" shutDownMachineURL="Machines/ShutDown"/>
</storeProxy></clientSettings>
"""#

private func data(_ s: String) -> Data { Data(s.utf8) }

// MARK: - Decoding

@Test func sessionListDecodesTheReferenceExample() throws {
    let list = try SessionsJSON.sessionList(data(listJSON))
    #expect(list.deviceId == "WR_MO-969cDcqgF")
    #expect(list.sessions.count == 1)
    let s = list.sessions[0]
    #expect(s.sessionId == "Q29udHJvbGxlci5TLTEtNS0x")
    #expect(s.connectionState == .connected && s.isConnected)
    #expect(s.userSessionType == "Application")
    #expect(s.clientName == "WR_MO-969cDcqgF" && s.clientType == "ica30" && s.deviceType == "Windows")
    #expect(s.applications == [.init(id: "Controller.Calculator", name: "Calculator", iconUrl: "Resources/Icon/x")])
    #expect(s.machineName == "DOMAIN\\CVAD-01" && s.machineHost == "CVAD-01")
    let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                  year: 2023, month: 11, day: 21, hour: 15, minute: 50, second: 10).date!
    #expect(abs((s.sessionStartTime ?? .distantPast).timeIntervalSince(expected) - 0.43) < 0.01)
    #expect(s.shortId.count == 8 && s.shortId == StoreSessionInfo.fingerprint(s.sessionId))
}

@Test func sessionListIsTolerant() throws {
    // Bare array, other key case, numbers for text, unknown state, entries without id skipped, no fraction.
    let json = #"""
    [ {"SessionID": 42, "ConnectionState": "Active", "sessionStartTime": "2023-11-21T15:50:10Z"},
      {"connectionState": "disconnected"},
      {"sessionId": "b", "connectionState": "suspended", "applications": [{"id": "CVAD.X"}, {"bogus": 1}, 7]} ]
    """#
    let list = try SessionsJSON.sessionList(data(json))
    #expect(list.deviceId == nil)
    #expect(list.sessions.map(\.sessionId) == ["42", "b"])
    #expect(list.skipped == 1)
    #expect(list.sessions[0].connectionState == .active && list.sessions[0].isConnected)
    #expect(list.sessions[0].sessionStartTime != nil)
    #expect(list.sessions[1].connectionState == .other("suspended") && !list.sessions[1].isConnected)
    #expect(list.sessions[1].applications == [.init(id: "CVAD.X", name: "CVAD.X")])
    #expect(try SessionsJSON.sessionList(data(#"{"sessions": []}"#)).sessions.isEmpty)
}

@Test func emptyOrBadBodiesFail() {
    #expect(throws: SessionsError.emptyBody("Sessions/ListAvailable")) { try SessionsJSON.available(Data()) }
    #expect(throws: SessionsError.emptyBody("Sessions/List")) { try SessionsJSON.sessionList(data("  \n")) }
    #expect(throws: SessionsError.malformed("Sessions/List")) { try SessionsJSON.sessionList(data("<html>logon</html>")) }
}

@Test func listAvailableDecodesTheReferenceExample() throws {
    let entries = try SessionsJSON.available(data(availableJSON))
    #expect(entries.count == 1)
    let e = entries[0]
    #expect(e.launchId == "Q29udHJvbGxlci4xODM5MC4y")
    #expect(e.initialapp == "Calculator" && e.publishername == "Controller")
    let r = e.resource
    #expect(r.isSession && r.launchurl == e.launchurl && r.launchstatusurl == e.launchstatusurl && r.name == "Calculator")
    // Entries without both URLs are skipped; other key case is accepted.
    let odd = try SessionsJSON.available(data(#"[{"LaunchUrl": "Sessions/LaunchIca/a", "launchStatusUrl": "Sessions/GetLaunchStatus/a"}, {"launchurl": "x"}]"#))
    #expect(odd.count == 1 && odd[0].initialapp == nil)
}

@Test func actionResultsAndWorkspaceStatusDecode() throws {
    let results = try SessionsJSON.results(data(#"""
    {"results": [{"sessionId": "a", "isSuccess": true, "failureReason": null},
                 {"sessionId": "b", "isSuccess": "false", "failureReason": "Session not found"}, {"isSuccess": true}]}
    """#), "Sessions/LogOffSessions")
    #expect(results == [.init(sessionId: "a", isSuccess: true), .init(sessionId: "b", isSuccess: false, failureReason: "Session not found")])
    #expect(try SessionsJSON.workspaceStatus(data(#"{"status": "success"}"#), "x") == .success)
    #expect(try SessionsJSON.workspaceStatus(data(#"{"status": "partial"}"#), "x") == .partial)
    #expect(try SessionsJSON.workspaceStatus(data(#"{"status": "failure"}"#), "x") == .failure)
    #expect(try SessionsJSON.workspaceStatus(data(#"{"Status": "odd"}"#), "x") == .other("odd"))
}

@Test func keyPathsListKeysWithoutValues() {
    let keys = SessionsJSON.keyPaths(data(listJSON))
    #expect(keys.contains("deviceId") && keys.contains("sessions[].sessionId") && keys.contains("sessions[].applications[].name"))
    #expect(keys.contains("sessions[].machineData.machineName"))
    #expect(!keys.joined().contains("WR_MO"))
}

@Test func endpointsComeFromTheConfiguration() {
    let e = SessionEndpoints(configuration: configXML)
    #expect(e == SessionEndpoints())
    let custom = SessionEndpoints(configuration: #"<sessionsProxy listAvailableURL="S/LA" disconnectURL="S/D" logoffURL="S/L"/>"#)
    #expect(custom.listAvailable == "S/LA" && custom.disconnect == "S/D" && custom.logoff == "S/L")
    #expect(custom.list == nil && custom.disconnectSessions == nil && custom.logOffSessions == nil)
    // Nothing readable: literals.
    #expect(SessionEndpoints(configuration: "") == SessionEndpoints())
}

// MARK: - Requests (fake transport)

final class FakeTransport: StoreTransport {
    struct Sent {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data?
        var contentType: String?
    }

    var sent: [Sent] = []
    var answers: [(Sent) -> (Int, [String: String], String)]
    var cookies = ["CsrfToken": "csrf-value"]

    init(_ answers: [(Sent) -> (Int, [String: String], String)]) { self.answers = answers }

    func send(_ method: String, _ url: URL, headers: [String: String], body: Data?, contentType: String?) async throws
        -> HTTPClient.Response {
        let s = Sent(method: method, path: url.relativePath, headers: headers, body: body, contentType: contentType)
        sent.append(s)
        let answer = answers.isEmpty ? { _ in (500, [:], "") } : answers.removeFirst()
        let (status, h, text) = answer(s)
        return HTTPClient.Response(status: status, headers: h, body: Data(text.utf8), url: url)
    }

    func cookie(_ name: String) -> String? { cookies[name] }
}

private func api(_ host: String, _ t: FakeTransport, reauth: (() async throws -> Void)? = nil) -> StoreSessions {
    StoreSessions(transport: t, base: URL(string: "https://\(host)/welcome/")!, reauthenticate: reauth)
}

@Test func listSendsWebUIHeadersByGET() async throws {
    let t = FakeTransport([{ _ in (200, [:], listJSON) }])
    let list = try await api("a.test", t).list()
    #expect(list.sessions.count == 1)
    #expect(t.sent.count == 1)
    #expect(t.sent[0].method == "GET" && t.sent[0].path == "Sessions/List")
    #expect(t.sent[0].headers["Csrf-Token"] == "csrf-value" && t.sent[0].headers["X-Citrix-IsUsingHTTPS"] == "Yes")
    #expect(t.sent[0].headers["CsrfToken"] == nil && t.sent[0].headers["isUsingHttps"] == nil)
}

@Test func csrfRetryOnceWithTheReferenceSpelling() async throws {
    let t = FakeTransport([{ _ in (403, [:], "") }, { _ in (200, [:], listJSON) }, { _ in (200, [:], listJSON) }])
    let a = api("csrf.test", t)
    _ = try await a.list()
    #expect(t.sent.count == 2)
    #expect(t.sent[1].headers["CsrfToken"] == "csrf-value" && t.sent[1].headers["isUsingHttps"] == "Yes")
    #expect(t.sent[1].headers["Csrf-Token"] == "csrf-value")
    #expect(a.lastHeaderForm == .apiReference)
    // Learned for this store: the next call starts with it.
    _ = try await api("csrf.test", t).list()
    #expect(t.sent.count == 3 && t.sent[2].headers["CsrfToken"] == "csrf-value")
}

@Test func csrfRetryIsOnlyOnce() async throws {
    let t = FakeTransport([{ _ in (403, [:], "") }, { _ in (403, [:], "") }, { _ in (200, [:], "[]") }])
    await #expect(throws: SessionsError.http("Sessions/List", 403)) { try await api("csrf2.test", t).list() }
    #expect(t.sent.count == 2)
    // A refused action is not repeated a third time either.
    let t2 = FakeTransport([{ _ in (403, [:], "") }, { _ in (403, [:], "") }])
    await #expect(throws: SessionsError.http("Sessions/DisconnectSessions", 403)) {
        try await api("csrf3.test", t2).disconnect(ids: ["a"])
    }
    #expect(t2.sent.count == 2)
}

@Test func challengeSignsInAgainOnce() async throws {
    let challenge = ["CitrixWebReceiver-Authenticate": "CitrixAGBasic"]
    var signIns = 0
    let t = FakeTransport([{ _ in (200, challenge, "") }, { _ in (200, [:], availableJSON) }])
    let entries = try await api("auth.test", t, reauth: { signIns += 1 }).available(excludeActive: false)
    #expect(signIns == 1 && entries.count == 1 && t.sent.count == 2)
    // A second challenge is not followed again.
    let t2 = FakeTransport([{ _ in (200, challenge, "") }, { _ in (200, challenge, "") }, { _ in (200, [:], "[]") }])
    signIns = 0
    await #expect(throws: SessionsError.emptyBody("Sessions/ListAvailable")) {
        try await api("auth2.test", t2, reauth: { signIns += 1 }).available(excludeActive: false)
    }
    #expect(signIns == 1 && t2.sent.count == 2)
}

@Test func listFallsBackToPOSTOn405AndReportsUnsupported() async throws {
    let t = FakeTransport([{ _ in (405, [:], "") }, { _ in (200, [:], listJSON) }])
    _ = try await api("m.test", t).list()
    #expect(t.sent.map(\.method) == ["GET", "POST"])
    #expect(t.sent[1].contentType == "application/x-www-form-urlencoded")
    let t2 = FakeTransport([{ _ in (405, [:], "") }, { _ in (404, [:], "") }])
    await #expect(throws: SessionsError.unsupported("Sessions/List")) { try await api("m2.test", t2).list() }
    var e = SessionEndpoints()
    e.list = nil
    let t3 = FakeTransport([])
    let a = StoreSessions(transport: t3, base: URL(string: "https://m3.test/welcome/")!, endpoints: e)
    await #expect(throws: SessionsError.unsupported("Sessions/List")) { try await a.list() }
    #expect(t3.sent.isEmpty)
}

@Test func listAvailableForms() async throws {
    let t = FakeTransport([{ _ in (200, [:], "[]") }, { _ in (200, [:], "[]") }])
    let a = api("la.test", t)
    _ = try await a.available(excludeActive: false)
    _ = try await a.available(excludeActive: true)
    #expect(t.sent.allSatisfy { $0.method == "POST" && $0.path == "Sessions/ListAvailable" })
    #expect(String(decoding: t.sent[0].body ?? Data(), as: UTF8.self) == "resourceTypes=Citrix.MPS.Application")
    #expect(String(decoding: t.sent[1].body ?? Data(), as: UTF8.self) == "resourceTypes=Citrix.MPS.Application&excludeActive=true")
}

@Test func byIdCallsSendJSONSessionIds() async throws {
    let t = FakeTransport([{ _ in (200, [:], #"{"results": [{"sessionId": "s1", "isSuccess": true}]}"#) },
                           { _ in (200, [:], #"{"results": []}"#) }])
    let a = api("id.test", t)
    let r = try await a.disconnect(ids: ["s1"])
    #expect(r == [.init(sessionId: "s1", isSuccess: true)])
    _ = try await a.logOff(ids: ["s2", "s3"])
    #expect(t.sent.map(\.path) == ["Sessions/DisconnectSessions", "Sessions/LogOffSessions"])
    #expect(t.sent.allSatisfy { $0.method == "POST" && $0.contentType == "application/json" })
    let body = try JSONSerialization.jsonObject(with: t.sent[1].body ?? Data()) as? [String: [String]]
    #expect(body == ["SessionIds": ["s2", "s3"]])
    // No ids: no request.
    #expect(try await a.logOff(ids: []).isEmpty)
    #expect(t.sent.count == 2)
    let t2 = FakeTransport([{ _ in (400, [:], "Bad session request") }])
    await #expect(throws: SessionsError.http("Sessions/LogOffSessions", 400)) { try await api("id2.test", t2).logOff(ids: ["x"]) }
}

// MARK: - Safety gates

private func session(_ id: String, _ state: StoreSessionInfo.ConnectionState, device: String? = nil, client: String? = nil,
                     apps: [String], started: TimeInterval = 0) -> StoreSessionInfo {
    StoreSessionInfo(sessionId: id, connectionState: state, sessionStartTime: Date(timeIntervalSince1970: started),
                     clientName: client, deviceId: device, applications: apps.map { .init(id: "CVAD.\($0)", name: $0) })
}

private func refused(_ v: DeviceWideGuard.Verdict) -> Bool { if case .refused = v { true } else { false } }

@Test func deviceWideGuardNeedsEveryListedSessionToBeOurs() {
    let ours: (StoreSessionInfo) -> Bool = { TestSessionGate.allows($0, allowed: ["Calculator"]) }
    let rechner = session("r", .connected, device: "D1", apps: ["Calculator"])
    let rechner2 = session("r2", .disconnected, device: "D1", apps: ["Calculator"])
    let outlookHere = session("o", .connected, device: "D1", apps: ["Outlook"])
    let outlookByName = session("o2", .disconnected, device: "OTHER", client: "mac-ica", apps: ["Outlook"])
    let outlookElsewhere = session("e", .connected, device: "D2", client: "PC-1", apps: ["Outlook"])
    func check(_ list: StoreSessionList, cookie: String? = "D1") -> DeviceWideGuard.Verdict {
        DeviceWideGuard.check(list, cookieDeviceId: cookie, clientNames: ["MAC-ICA"], isOurs: ours)
    }

    #expect(check(.init(deviceId: "D1", sessions: [rechner, rechner2])) == .allowed(["r", "r2"]))
    // Any session that is not ours blocks it, wherever the store says it runs (the tie is not trusted).
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner, outlookHere]))))
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner, outlookByName]))))
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner, outlookElsewhere]))))
    // Unreadable entries, or a session without a device id: refused.
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner], skipped: 1))))
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner, session("n", .connected, apps: ["Calculator"])]))))
    // The store's device id must be the cookie we send (app and icactl may differ).
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner]), cookie: nil)))
    #expect(refused(check(.init(deviceId: "D1", sessions: [rechner]), cookie: "D9")))
    // No device id from the store, or nothing tied to this device: refused.
    #expect(refused(check(.init(deviceId: nil, sessions: [rechner]))))
    #expect(refused(DeviceWideGuard.check(.init(deviceId: "D1", sessions: [session("x", .connected, device: "D2", apps: ["Calculator"])]),
                                          cookieDeviceId: "D1", clientNames: [], isOurs: ours)))
}

@Test func deviceWideCallIsNotSentWhenTheGuardRefuses() async throws {
    let ours: (StoreSessionInfo) -> Bool = { TestSessionGate.allows($0, allowed: TestSessionGate.defaultResources) }
    let outlook = #"{"deviceId": "D1", "sessions": [{"sessionId": "o", "connectionState": "connected", "deviceId": "D1", "applications": [{"name": "Outlook"}]}]}"#
    let t = FakeTransport([{ _ in (200, [:], outlook) }, { _ in (200, [:], #"{"status": "success"}"#) }])
    t.cookies[DeviceIdentity.cookieName] = "D1"
    await #expect(throws: SessionsError.self) { try await api("dw.test", t).logOffDevice(clientNames: [], isOurs: ours) }
    #expect(t.sent.map(\.path) == ["Sessions/List"])

    let mine = #"{"deviceId": "D1", "sessions": [{"sessionId": "r", "connectionState": "connected", "deviceId": "D1", "applications": [{"name": "Calculator"}]}]}"#
    // Cookie differs from the store's device id: not sent.
    let t1 = FakeTransport([{ _ in (200, [:], mine) }, { _ in (200, [:], #"{"status": "success"}"#) }])
    t1.cookies[DeviceIdentity.cookieName] = "OTHER"
    await #expect(throws: SessionsError.self) { try await api("dw1.test", t1).disconnectDevice(clientNames: [], isOurs: ours) }
    #expect(t1.sent.map(\.path) == ["Sessions/List"])
    // An unreadable entry in the list: not sent.
    let skipped = #"{"deviceId": "D1", "sessions": [{"sessionId": "r", "connectionState": "connected", "deviceId": "D1", "applications": [{"name": "Calculator"}]}, {"connectionState": "connected"}]}"#
    let t3 = FakeTransport([{ _ in (200, [:], skipped) }, { _ in (200, [:], #"{"status": "success"}"#) }])
    t3.cookies[DeviceIdentity.cookieName] = "D1"
    await #expect(throws: SessionsError.self) { try await api("dw3.test", t3).disconnectDevice(clientNames: [], isOurs: ours) }
    #expect(t3.sent.map(\.path) == ["Sessions/List"])

    let t2 = FakeTransport([{ _ in (200, [:], mine) }, { _ in (200, [:], #"{"status": "success"}"#) }])
    t2.cookies[DeviceIdentity.cookieName] = "D1"
    #expect(try await api("dw2.test", t2).disconnectDevice(clientNames: [], isOurs: ours) == .success)
    #expect(t2.sent.map(\.path) == ["Sessions/List", "Sessions/Disconnect"])
    #expect(t2.sent[1].method == "POST" && (t2.sent[1].body ?? Data()).isEmpty)
}

@Test func testSessionGate() {
    #expect(TestSessionGate.allowedNames([:]) == ["Calculator", "Notepad"])
    // ICA_TEST_RESOURCES alone changes nothing; only with ICA_ALLOW_ANY_RESOURCE=1.
    #expect(TestSessionGate.allowedNames(["ICA_TEST_RESOURCES": "Outlook"]) == ["Calculator", "Notepad"])
    #expect(TestSessionGate.allowedNames(["ICA_TEST_RESOURCES": " Calculator , ", "ICA_ALLOW_ANY_RESOURCE": "1"]) == ["Calculator"])
    #expect(TestSessionGate.allowedNames(["ICA_TEST_RESOURCES": " , ", "ICA_ALLOW_ANY_RESOURCE": "1"]) == ["Calculator", "Notepad"])
    let allowed = TestSessionGate.defaultResources
    #expect(TestSessionGate.allows(session("a", .connected, apps: ["Calculator", "Notepad"]), allowed: allowed))
    #expect(!TestSessionGate.allows(session("b", .connected, apps: ["Calculator", "Outlook ABC"]), allowed: allowed))
    #expect(!TestSessionGate.allows(session("c", .disconnected, apps: []), allowed: allowed))
    #expect(!TestSessionGate.allows(session("d", .connected, apps: ["rechner ekm"]), allowed: allowed))
    // App names as ids only: resolved through the resource list.
    let resources = try! JSONDecoder().decode([StoreClient.Resource].self, from: data(#"[{"id": "CVAD.Calc", "name": "Calculator"}]"#))
    let byId = StoreSessionInfo(sessionId: "e", connectionState: .connected, applications: [.init(id: "cvad.calc", name: "Calc")])
    #expect(TestSessionGate.allows(byId, allowed: allowed, resources: resources))
    #expect(!TestSessionGate.allows(byId, allowed: allowed))
    #expect(TestSessionGate.resolvedNames(byId, resources: resources) == ["Calculator"])
    #expect(TestSessionGate.allows(AvailableSession(launchurl: "a", launchstatusurl: "b", initialapp: "Notepad"), allowed: allowed))
    #expect(!TestSessionGate.allows(AvailableSession(launchurl: "a", launchstatusurl: "b"), allowed: allowed))
}

// MARK: - Connection Center model

private func entry(_ id: String, _ app: String) -> AvailableSession {
    AvailableSession(launchurl: "Sessions/LaunchIca/\(id)", launchstatusurl: "Sessions/GetLaunchStatus/\(id)", initialapp: app)
}

@Test func stateRule() {
    let s = session("x", .connected, device: "D1", client: "MAC-ICA", apps: ["A"])
    #expect(SessionDirectory.state(of: s, deviceId: "D1", clientNames: []) == .connectedHere)
    #expect(SessionDirectory.state(of: s, deviceId: "D2", clientNames: ["mac-ica"]) == .connectedHere)
    #expect(SessionDirectory.state(of: s, deviceId: "D2", clientNames: []) == .connectedElsewhere(clientName: "MAC-ICA", deviceType: nil))
    #expect(SessionDirectory.state(of: session("y", .disconnected, device: "D1", apps: []), deviceId: "D1", clientNames: []) == .disconnected)
    #expect(SessionDirectory.state(of: session("z", .active, device: "D1", apps: []), deviceId: "D1", clientNames: []) == .connectedHere)
}

private let mixedList = StoreSessionList(deviceId: "D1", sessions: [
    session("here", .connected, device: "D1", apps: ["Calculator"]),
    session("disc", .disconnected, device: "D1", apps: ["Notepad"]),
    session("away", .connected, device: "D2", client: "PC-1", apps: ["Outlook"]),
])

@Test func mergeOffersReconnectOnlyForJoinedDisconnectedSessions() {
    let disc = entry("1", "Notepad"), away = entry("2", "Outlook")
    let rows = SessionDirectory.merge(list: mixedList, available: [disc, away], excludingActive: [disc], clientNames: [])
    #expect(rows.count == 3)
    let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id ?? "", $0) })
    #expect(byId["here"]?.state == .connectedHere && byId["here"]?.reconnect == nil && byId["here"]?.takeOver == nil)
    #expect(byId["disc"]?.reconnect == disc && byId["disc"]?.takeOver == nil)
    #expect(byId["away"]?.reconnect == nil && byId["away"]?.takeOver == away)
    #expect(byId["away"]?.state == .connectedElsewhere(clientName: "PC-1", deviceType: nil))

    // excludeActive call failed: the List decides; the elsewhere session is still Take Over only.
    let unsure = SessionDirectory.merge(list: mixedList, available: [disc, away], excludingActive: nil, clientNames: [])
    #expect(unsure.first { $0.id == "disc" }?.reconnect == disc)
    #expect(unsure.first { $0.id == "away" }?.reconnect == nil && unsure.first { $0.id == "away" }?.takeOver == away)
}

@Test func mergeNeverTrustsExcludeActiveAlone() {
    let disc = entry("1", "Notepad"), away = entry("2", "Outlook")
    // The store ignored excludeActive (same answer twice) although a session is open elsewhere.
    let ignored = SessionDirectory.merge(list: mixedList, available: [disc, away], excludingActive: [disc, away], clientNames: [])
    #expect(ignored.first { $0.id == "away" }?.reconnect == nil && ignored.first { $0.id == "away" }?.takeOver == away)
    #expect(ignored.first { $0.id == "disc" }?.reconnect == disc)
    // Even a trusted answer cannot turn a session the List shows elsewhere into a Reconnect.
    let other = entry("3", "Notepad")
    let wrong = SessionDirectory.merge(list: mixedList, available: [away, other], excludingActive: [away], clientNames: [])
    #expect(wrong.first { $0.id == "away" }?.reconnect == nil && wrong.first { $0.id == "away" }?.takeOver == away)
    // An entry of the trusted answer that is not disconnected in the List: Take Over.
    #expect(wrong.first { $0.id == "disc" }?.reconnect == nil && wrong.first { $0.id == "disc" }?.takeOver == other)
    // An unjoined entry is Take Over, even if excludeActive listed it.
    let lone = entry("4", "Paint")
    let unjoined = SessionDirectory.merge(list: mixedList, available: [away, lone], excludingActive: [lone], clientNames: [])
    #expect(unjoined.last == StoreSession(id: nil, state: .unknown, initialApp: "Paint", takeOver: lone))
    #expect(unjoined.allSatisfy { $0.reconnect == nil })
}

@Test func mergeWithoutSessionsListOffersOnlyTakeOver() {
    let a = entry("1", "Notepad"), b = entry("2", "Outlook")
    let rows = SessionDirectory.merge(list: nil, available: [a, b], excludingActive: [a], clientNames: [])
    #expect(rows == [StoreSession(id: nil, state: .unknown, initialApp: "Notepad", takeOver: a),
                     StoreSession(id: nil, state: .unknown, initialApp: "Outlook", takeOver: b)])
}

@Test func mergeJoinRuleAndAmbiguity() {
    let e = entry("1", "Calculator")
    let one = StoreSessionList(deviceId: "D1", sessions: [
        session("calc", .disconnected, apps: ["Calculator"], started: 200),
        session("other", .disconnected, apps: ["Notepad"], started: 50),
    ])
    let rows = SessionDirectory.merge(list: one, available: [e], excludingActive: [e], clientNames: [])
    #expect(rows.first { $0.id == "calc" }?.reconnect == e)
    #expect(rows.first { $0.id == "other" }?.reconnect == nil && rows.count == 2)

    // Two sessions with the same app, one entry: ambiguous, neither Reconnect nor Take Over.
    let two = StoreSessionList(deviceId: "D1", sessions: [
        session("late", .disconnected, apps: ["Calculator"], started: 200),
        session("early", .connected, device: "D2", apps: ["Calculator"], started: 100),
    ])
    let amb = SessionDirectory.merge(list: two, available: [e], excludingActive: nil, clientNames: [])
    #expect(amb.count == 2 && amb.allSatisfy { $0.joinAmbiguous && $0.reconnect == nil && $0.takeOver == nil })

    // Two entries with the same initial app, one session: ambiguous too, and no extra rows.
    let e2 = entry("2", "Calculator")
    let single = StoreSessionList(deviceId: "D1", sessions: [session("calc", .disconnected, apps: ["Calculator"])])
    let twice = SessionDirectory.merge(list: single, available: [e, e2], excludingActive: [e, e2], clientNames: [])
    #expect(twice.count == 1 && twice[0].joinAmbiguous && twice[0].reconnect == nil && twice[0].takeOver == nil)
    // Two entries, two sessions, same app: all ambiguous.
    let both = SessionDirectory.merge(list: StoreSessionList(deviceId: "D1", sessions: [
        session("a", .disconnected, apps: ["Calculator"]), session("b", .disconnected, apps: ["Calculator"])]),
        available: [e, e2], excludingActive: [e, e2], clientNames: [])
    #expect(both.count == 2 && both.allSatisfy { $0.joinAmbiguous && $0.reconnect == nil })
    // A shared session claimed by entries of two of its apps: ambiguous.
    let word = entry("w", "Word"), excel = entry("x", "Excel")
    let shared = SessionDirectory.merge(list: StoreSessionList(deviceId: "D1", sessions: [
        session("s", .disconnected, apps: ["Word", "Excel"])]), available: [word, excel], excludingActive: [word, excel], clientNames: [])
    #expect(shared.count == 1 && shared[0].joinAmbiguous && shared[0].reconnect == nil)

    // An entry not (yet) in Sessions/List gets its own row, Take Over only.
    let extra = SessionDirectory.merge(list: StoreSessionList(deviceId: "D1", sessions: []), available: [e], excludingActive: [e],
                                       clientNames: [])
    #expect(extra == [StoreSession(id: nil, state: .unknown, initialApp: "Calculator", takeOver: e)])
    // Sessions connected here never get an entry.
    let here = StoreSessionList(deviceId: "D1", sessions: [session("h", .connected, device: "D1", apps: ["Calculator"])])
    let r = SessionDirectory.merge(list: here, available: [e], excludingActive: [e], clientNames: [])
    #expect(r.first { $0.id == "h" }?.reconnect == nil && r.count == 2)
}

// MARK: - Device identity

final class MemoryIdentity: DeviceIdentityStore {
    var record: [String: String]?
    var saves = 0
    func load() -> [String: String]? { record }
    func save(_ r: [String: String]) { record = r; saves += 1 }
}

@Test func deviceIdCookieIsRestoredAndRemembered() {
    let base = URL(string: "https://store.test/welcome/")!
    let http = HTTPClient()
    let store = MemoryIdentity()
    DeviceIdentity.restore(into: http, from: store, base: base)
    #expect(http.cookie(DeviceIdentity.cookieName) == nil)
    let set = HTTPCookie(properties: [.name: "CtxsDeviceId", .value: "dev-1", .domain: "store.test", .path: "/Citrix/"])!
    http.setCookie(set)
    DeviceIdentity.remember(from: http, into: store)
    #expect(store.record == ["value": "dev-1", "domain": "store.test", "path": "/Citrix/"])
    DeviceIdentity.remember(from: http, into: store)
    #expect(store.saves == 1)
    // Empty jar after a gateway logon: the saved id comes back with its domain and path.
    http.clearCookies()
    DeviceIdentity.restore(into: http, from: store, base: base)
    let back = http.cookieRecord(DeviceIdentity.cookieName)
    #expect(back?.value == "dev-1" && back?.path == "/Citrix/" && back?.domain == "store.test")
    // An id already in the jar is never replaced.
    store.record = ["value": "dev-2"]
    DeviceIdentity.restore(into: http, from: store, base: base)
    #expect(http.cookie(DeviceIdentity.cookieName) == "dev-1")
}

@Test func fileDeviceIdentityRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ica-dev-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("device-id.plist").path
    let f = FileDeviceIdentity(path: path)
    #expect(f.load() == nil)
    f.save(["value": "v", "path": "/"])
    #expect(FileDeviceIdentity(path: path).load() == ["value": "v", "path": "/"])
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}
