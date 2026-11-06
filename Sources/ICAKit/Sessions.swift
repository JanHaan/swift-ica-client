import CryptoKit
import Foundation

// Store-side sessions: list, reconnect, disconnect and log off (docs/90-connection-center.md).
//
// Safety (D30, docs/90 §0): listing is read-only. Disconnect and log off act on the user's real
// sessions; callers decide which ids they may touch (icactl: `TestSessionGate`; the viewer: the user,
// after a confirmation). The device-wide calls (`Sessions/Disconnect`, `Sessions/Logoff`) are only
// reachable through `StoreSessions.disconnectDevice`/`logOffDevice`, which run `DeviceWideGuard`
// on a fresh `Sessions/List` first (§8.6 item 4). Nothing here logs ids, cookies or tokens.

// MARK: - Transport

/// What the sessions API needs from the HTTP layer; `HTTPClient` in the app, a fake in tests.
public protocol StoreTransport: AnyObject {
    func send(_ method: String, _ url: URL, headers: [String: String], body: Data?, contentType: String?) async throws
        -> HTTPClient.Response
    func cookie(_ name: String) -> String?
}

extension HTTPClient: StoreTransport {}

// MARK: - Models

/// One session from `Sessions/List` (docs/90 §5.1).
public struct StoreSessionInfo: Equatable, Sendable {
    public enum ConnectionState: Equatable, Sendable {
        case connected, disconnected, active
        case other(String)

        init(_ text: String?) {
            switch text?.lowercased() {
            case "connected": self = .connected
            case "disconnected": self = .disconnected
            case "active": self = .active
            default: self = .other(text ?? "")
            }
        }

        public var name: String {
            switch self {
            case .connected: "connected"
            case .disconnected: "disconnected"
            case .active: "active"
            case .other(let s): s.isEmpty ? "unknown" : s
            }
        }
    }

    public struct App: Equatable, Sendable {
        public var id: String?
        public var name: String
        public var iconUrl: String?

        public init(id: String?, name: String, iconUrl: String? = nil) {
            self.id = id
            self.name = name
            self.iconUrl = iconUrl
        }
    }

    public var sessionId: String
    public var connectionState: ConnectionState
    public var userSessionType: String?
    public var sessionStartTime: Date?
    public var clientName: String?
    public var clientType: String?
    public var deviceId: String?
    public var deviceType: String?
    public var applications: [App]
    public var machineName: String?
    public var machineId: String?

    public init(sessionId: String, connectionState: ConnectionState, userSessionType: String? = nil,
                sessionStartTime: Date? = nil, clientName: String? = nil, clientType: String? = nil,
                deviceId: String? = nil, deviceType: String? = nil, applications: [App] = [],
                machineName: String? = nil, machineId: String? = nil) {
        self.sessionId = sessionId
        self.connectionState = connectionState
        self.userSessionType = userSessionType
        self.sessionStartTime = sessionStartTime
        self.clientName = clientName
        self.clientType = clientType
        self.deviceId = deviceId
        self.deviceType = deviceType
        self.applications = applications
        self.machineName = machineName
        self.machineId = machineId
    }

    /// `connected` and `active` both count as connected until §11 item 4 tells them apart.
    public var isConnected: Bool { connectionState == .connected || connectionState == .active }

    public var appNames: [String] { applications.map(\.name) }

    /// Short, stable stand-in for the id in logs and on the command line (first 8 hex digits of
    /// its SHA-256), so the id itself never has to be printed.
    public var shortId: String { StoreSessionInfo.fingerprint(sessionId) }

    public static func fingerprint(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The host part of `DOMAIN\HOST` (§8.4).
    public var machineHost: String? {
        machineName.map { $0.split(separator: "\\").last.map(String.init) ?? $0 }
    }
}

/// `Sessions/List` answer: the caller's device id and the user's sessions.
public struct StoreSessionList: Equatable, Sendable {
    public var deviceId: String?
    public var sessions: [StoreSessionInfo]
    /// Entries the parser could not use (no `sessionId`, not an object). The device-wide guard refuses
    /// while any exist: an unreadable session might be the user's.
    public var skipped: Int

    public init(deviceId: String?, sessions: [StoreSessionInfo], skipped: Int = 0) {
        self.deviceId = deviceId
        self.sessions = sessions
        self.skipped = skipped
    }
}

/// One `Sessions/ListAvailable` entry (§4.1): a session not connected from this client.
public struct AvailableSession: Equatable, Sendable {
    public var launchurl: String
    public var launchstatusurl: String
    public var initialapp: String?
    public var publishername: String?

    public init(launchurl: String, launchstatusurl: String, initialapp: String? = nil, publishername: String? = nil) {
        self.launchurl = launchurl
        self.launchstatusurl = launchstatusurl
        self.initialapp = initialapp
        self.publishername = publishername
    }

    /// The launch id (last path component of `launchurl`).
    public var launchId: String { launchurl.split(separator: "/").last.map(String.init) ?? launchurl }

    /// As a resource for `StoreClient.launchICA` (§4.2).
    public var resource: StoreClient.Resource {
        StoreClient.Resource(session: self)
    }
}

/// Per-id result of `DisconnectSessions` / `LogOffSessions` (§5.2).
public struct SessionActionResult: Equatable, Sendable {
    public var sessionId: String
    public var isSuccess: Bool
    public var failureReason: String?

    public init(sessionId: String, isSuccess: Bool, failureReason: String? = nil) {
        self.sessionId = sessionId
        self.isSuccess = isSuccess
        self.failureReason = failureReason
    }
}

/// `{"status": …}` of the device-wide `Sessions/Disconnect` / `Sessions/Logoff` (§4.3).
public enum WorkspaceStatus: Equatable, Sendable {
    case success, failure, partial
    case other(String)

    init(_ text: String?) {
        switch text?.lowercased() {
        case "success": self = .success
        case "failure": self = .failure
        case "partial": self = .partial
        default: self = .other(text ?? "")
        }
    }
}

public enum SessionsError: Error, CustomStringConvertible, Equatable {
    case http(String, Int)
    case emptyBody(String)
    case unsupported(String)
    case malformed(String)
    case refused(String)

    public var description: String {
        switch self {
        case .http(let what, 403): "\(what): the store refused the request (security token, HTTP 403)"
        case .http(let what, let status): "\(what) failed with HTTP \(status)"
        case .emptyBody(let what): "\(what): empty answer"
        case .unsupported(let what): "\(what) is not offered by this store"
        case .malformed(let what): "\(what): unexpected answer"
        case .refused(let reason): "refused: \(reason)"
        }
    }
}

// MARK: - Tolerant JSON

/// Field lookup that ignores key case and accepts numbers or booleans where text is expected.
struct LooseObject {
    let fields: [String: Any]

    init?(_ any: Any?) {
        guard let dict = any as? [String: Any] else { return nil }
        fields = dict
    }

    func raw(_ key: String) -> Any? {
        if let v = fields[key] { return v }
        return fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    func string(_ key: String) -> String? {
        switch raw(key) {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch raw(key) {
        case let n as NSNumber: n.boolValue
        case let s as String: ["true", "yes", "1"].contains(s.lowercased()) ? true : ["false", "no", "0"].contains(s.lowercased()) ? false : nil
        default: nil
        }
    }

    func object(_ key: String) -> LooseObject? { LooseObject(raw(key)) }
    func array(_ key: String) -> [Any] { raw(key) as? [Any] ?? [] }
}

public enum SessionsJSON {
    static func json(_ data: Data, _ what: String) throws -> Any {
        guard !data.isEmpty, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SessionsError.emptyBody(what) }
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw SessionsError.malformed(what)
        }
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        // Without a zone ("2023-11-21T15:50:10.43"): read as UTC.
        plain.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        let trimmed = text.split(separator: ".").first.map(String.init) ?? text
        return plain.date(from: trimmed)
    }

    /// `Sessions/List`: `{deviceId, sessions: [...]}`; a bare array is accepted too. Entries without
    /// a `sessionId` are skipped (they cannot be acted on).
    public static func sessionList(_ data: Data) throws -> StoreSessionList {
        let root = try json(data, "Sessions/List")
        let top = LooseObject(root)
        let items: [Any]
        if let array = root as? [Any] { items = array } else if let top { items = top.array("sessions") } else {
            throw SessionsError.malformed("Sessions/List")
        }
        let sessions = items.compactMap(LooseObject.init).compactMap { o -> StoreSessionInfo? in
            guard let id = o.string("sessionId"), !id.isEmpty else { return nil }
            let apps = o.array("applications").compactMap(LooseObject.init).compactMap { a -> StoreSessionInfo.App? in
                let name = a.string("name") ?? a.string("id")
                return name.map { StoreSessionInfo.App(id: a.string("id"), name: $0, iconUrl: a.string("iconUrl")) }
            }
            let machine = o.object("machineData")
            return StoreSessionInfo(
                sessionId: id, connectionState: .init(o.string("connectionState")),
                userSessionType: o.string("userSessionType"), sessionStartTime: date(o.string("sessionStartTime")),
                clientName: o.string("clientName"), clientType: o.string("clientType"), deviceId: o.string("deviceId"),
                deviceType: o.string("deviceType"), applications: apps,
                machineName: machine?.string("machineName"), machineId: machine?.string("machineId"))
        }
        return StoreSessionList(deviceId: top?.string("deviceId"), sessions: sessions, skipped: items.count - sessions.count)
    }

    /// `Sessions/ListAvailable`: an array of `{launchurl, launchstatusurl, initialapp, publishername}`;
    /// `{"sessions": [...]}` is accepted too. Entries without both URLs are skipped.
    public static func available(_ data: Data) throws -> [AvailableSession] {
        let root = try json(data, "Sessions/ListAvailable")
        let items: [Any]
        if let array = root as? [Any] { items = array } else if let top = LooseObject(root) { items = top.array("sessions") } else {
            throw SessionsError.malformed("Sessions/ListAvailable")
        }
        return items.compactMap(LooseObject.init).compactMap { o in
            guard let launch = o.string("launchurl"), let status = o.string("launchstatusurl") else { return nil }
            return AvailableSession(launchurl: launch, launchstatusurl: status, initialapp: o.string("initialapp"),
                                    publishername: o.string("publishername"))
        }
    }

    /// `DisconnectSessions` / `LogOffSessions`: `{"results": [{sessionId, isSuccess, failureReason}]}`.
    public static func results(_ data: Data, _ what: String) throws -> [SessionActionResult] {
        let root = try json(data, what)
        let items: [Any]
        if let array = root as? [Any] { items = array } else if let top = LooseObject(root) { items = top.array("results") } else {
            throw SessionsError.malformed(what)
        }
        return items.compactMap(LooseObject.init).compactMap { o in
            guard let id = o.string("sessionId") else { return nil }
            return SessionActionResult(sessionId: id, isSuccess: o.bool("isSuccess") ?? false,
                                       failureReason: o.string("failureReason"))
        }
    }

    /// Key paths of a JSON answer for live checks, without values: `deviceId`, `sessions[].sessionId`,
    /// `sessions[].applications[].name`, … (docs/90 §11 items 4–5).
    public static func keyPaths(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var paths = Set<String>()
        func walk(_ any: Any, _ prefix: String) {
            if let dict = any as? [String: Any] {
                for (key, value) in dict {
                    let path = prefix.isEmpty ? key : prefix + "." + key
                    paths.insert(path)
                    walk(value, path)
                }
            } else if let array = any as? [Any] {
                for item in array { walk(item, prefix + "[]") }
            }
        }
        walk(root, "")
        return paths.sorted()
    }

    /// Device-wide `Sessions/Disconnect` / `Sessions/Logoff`: `{"status": …}`.
    public static func workspaceStatus(_ data: Data, _ what: String) throws -> WorkspaceStatus {
        guard let top = LooseObject(try json(data, what)) else { throw SessionsError.malformed(what) }
        return WorkspaceStatus(top.string("status"))
    }
}

// MARK: - Endpoint paths (§2.1)

public struct SessionEndpoints: Equatable, Sendable {
    public var listAvailable = "Sessions/ListAvailable"
    public var disconnect = "Sessions/Disconnect"
    public var logoff = "Sessions/Logoff"
    /// nil: the store has no by-id session control (no `sessionControlProxy`).
    public var list: String? = "Sessions/List"
    public var logOffSessions: String? = "Sessions/LogOffSessions"
    public var disconnectSessions: String? = "Sessions/DisconnectSessions"

    public init() {}

    /// From the `Home/Configuration` XML; literals for anything missing. Without a
    /// `sessionControlProxy` element the by-id paths are nil.
    public init(configuration xml: String) {
        func element(_ name: String) -> String? {
            guard let range = xml.range(of: "<\(name)[\\s/>][^>]*", options: .regularExpression) else { return nil }
            return String(xml[range])
        }
        func attribute(_ name: String, in element: String) -> String? {
            guard let range = element.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
            let text = element[range].dropFirst(name.count + 2).dropLast()
            return text.isEmpty ? nil : String(text)
        }
        if let s = element("sessionsProxy") {
            if let v = attribute("listAvailableURL", in: s) { listAvailable = v }
            if let v = attribute("disconnectURL", in: s) { disconnect = v }
            if let v = attribute("logoffURL", in: s) { logoff = v }
        }
        if let c = element("sessionControlProxy") {
            list = attribute("listSessionsURL", in: c) ?? list
            logOffSessions = attribute("logoffSessionsURL", in: c) ?? logOffSessions
            disconnectSessions = attribute("disconnectSessionsURL", in: c) ?? disconnectSessions
        } else if xml.contains("<sessionsProxy") {
            // A configuration we could read, without session control.
            list = nil
            logOffSessions = nil
            disconnectSessions = nil
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: SessionEndpoints] = [:]

    /// Paths seen in the last `Home/Configuration` for a store base (set by `StoreClient.signIn`).
    public static func remembered(for base: URL) -> SessionEndpoints {
        lock.lock(); defer { lock.unlock() }
        return known[base.absoluteString] ?? SessionEndpoints()
    }

    static func remember(_ endpoints: SessionEndpoints, for base: URL) {
        lock.lock(); defer { lock.unlock() }
        known[base.absoluteString] = endpoints
    }
}

// MARK: - API

/// The store's session calls (docs/90 §4, §5) with the §3 conventions: CSRF headers with one retry
/// in the API reference's spelling after a 403, and one re-sign-in after a challenge.
public final class StoreSessions: @unchecked Sendable {
    /// Which CSRF/HTTPS header spelling the store accepted (§3.2, §11 item 4).
    public enum HeaderForm: String, Sendable {
        /// `Csrf-Token`, `X-Citrix-IsUsingHTTPS` (the cached web UI).
        case webUI
        /// Additionally `CsrfToken`, `isUsingHttps` (the StoreFront Web API reference).
        case apiReference
    }

    private static let formLock = NSLock()
    nonisolated(unsafe) private static var learned: [String: HeaderForm] = [:]

    /// The spelling that worked for this store host in this process, if a call needed the fallback.
    public var preferredHeaderForm: HeaderForm? {
        get { Self.formLock.lock(); defer { Self.formLock.unlock() }; return Self.learned[base.host ?? ""] }
        set { Self.formLock.lock(); Self.learned[base.host ?? ""] = newValue; Self.formLock.unlock() }
    }

    let transport: StoreTransport
    public let base: URL
    public var endpoints: SessionEndpoints
    /// Signs in to the store again (`StoreClient.signIn`) after a `CitrixWebReceiver-Authenticate` challenge.
    let reauthenticate: (() async throws -> Void)?
    /// Called before and after every request (device id cookie, `StoreClient.syncDeviceId`).
    let around: (() -> Void)?
    /// Paths, status codes and the header form only.
    public var log: (String) -> Void = { _ in }
    /// Form of the last request that got an answer other than 403.
    public private(set) var lastHeaderForm: HeaderForm?

    public init(transport: StoreTransport, base: URL, endpoints: SessionEndpoints = SessionEndpoints(),
                reauthenticate: (() async throws -> Void)? = nil, around: (() -> Void)? = nil) {
        self.transport = transport
        self.base = base
        self.endpoints = endpoints
        self.reauthenticate = reauthenticate
        self.around = around
    }

    func headers(_ form: HeaderForm) -> [String: String] {
        let https = base.scheme?.lowercased() == "https" ? "Yes" : "No"
        var h = ["X-Citrix-IsUsingHTTPS": https, "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"]
        let csrf = transport.cookie("CsrfToken")
        if let csrf { h["Csrf-Token"] = csrf }
        if form == .apiReference {
            if let csrf { h["CsrfToken"] = csrf }
            h["isUsingHttps"] = https
        }
        return h
    }

    enum Body {
        case none
        case form([(String, String)])
        case json(Data)
    }

    /// One call with the §3.2/§3.3 retries: a challenge header → sign in again, repeat once; 403 → repeat
    /// once with the API reference's header spelling. A 403 means the store did not act, so the repeat
    /// cannot run an action twice.
    func request(_ method: String, _ path: String, _ body: Body = .none) async throws -> HTTPClient.Response {
        guard let url = URL(string: path, relativeTo: base) else { throw SessionsError.malformed(path) }
        let (data, type): (Data?, String?) = switch body {
        case .none: (method == "POST" ? Data() : nil, nil)
        case .form(let f): (Data(HTTPClient.formEncode(f).utf8), "application/x-www-form-urlencoded")
        case .json(let d): (d, "application/json")
        }
        var form = preferredHeaderForm ?? .webUI
        var reauthed = false
        var csrfRetried = false
        while true {
            around?()
            let response = try await transport.send(method, url, headers: headers(form), body: data, contentType: type)
            around?()
            if response.header("CitrixWebReceiver-Authenticate") != nil, !reauthed, let reauthenticate {
                log("sessions: \(path) challenged; signing in again")
                reauthed = true
                try await reauthenticate()
                continue
            }
            if response.status == 403, !csrfRetried, form == .webUI {
                log("sessions: \(path) HTTP 403 with Csrf-Token; retrying with CsrfToken/isUsingHttps")
                csrfRetried = true
                form = .apiReference
                continue
            }
            if response.status != 403 {
                lastHeaderForm = form
                if csrfRetried { preferredHeaderForm = form }
            }
            log("sessions: \(method) \(path) → \(response.status) (\(form.rawValue) headers)")
            return response
        }
    }

    /// Read-only calls for the live checks (§11 items 4–5): the raw answer of `Sessions/List` (GET, 405
    /// → POST) or `Sessions/ListAvailable`. Never an action endpoint.
    public enum ReadOnlyCall: Sendable {
        case list
        case available(excludeActive: Bool)
    }

    public func probe(_ call: ReadOnlyCall) async throws -> (response: HTTPClient.Response, method: String, headers: HeaderForm?) {
        switch call {
        case .list:
            guard let path = endpoints.list else { throw SessionsError.unsupported("Sessions/List") }
            let get = try await request("GET", path)
            if get.status != 405 { return (get, "GET", lastHeaderForm) }
            return (try await request("POST", path, .form([])), "POST", lastHeaderForm)
        case .available(let exclude):
            var form = [("resourceTypes", "Citrix.MPS.Application")]
            if exclude { form.append(("excludeActive", "true")) }
            return (try await request("POST", endpoints.listAvailable, .form(form)), "POST", lastHeaderForm)
        }
    }

    // MARK: Session control (§5)

    /// `Sessions/List` by GET; 405 → POST with an empty form (§5.1).
    public func list() async throws -> StoreSessionList {
        guard let path = endpoints.list else { throw SessionsError.unsupported("Sessions/List") }
        var response = try await request("GET", path)
        if response.status == 405 { response = try await request("POST", path, .form([])) }
        if response.status == 404 || response.status == 405 { throw SessionsError.unsupported("Sessions/List") }
        guard response.status == 200 else { throw SessionsError.http("Sessions/List", response.status) }
        return try SessionsJSON.sessionList(response.body)
    }

    /// `Sessions/DisconnectSessions` for these ids (§5.2). The caller decides which ids it may touch.
    public func disconnect(ids: [String]) async throws -> [SessionActionResult] {
        try await byId(endpoints.disconnectSessions, "Sessions/DisconnectSessions", ids)
    }

    /// `Sessions/LogOffSessions` for these ids (§5.3). Ends the sessions and their apps.
    public func logOff(ids: [String]) async throws -> [SessionActionResult] {
        try await byId(endpoints.logOffSessions, "Sessions/LogOffSessions", ids)
    }

    private func byId(_ path: String?, _ what: String, _ ids: [String]) async throws -> [SessionActionResult] {
        guard !ids.isEmpty else { return [] }
        guard let path else { throw SessionsError.unsupported(what) }
        let body = try JSONSerialization.data(withJSONObject: ["SessionIds": ids])
        let response = try await request("POST", path, .json(body))
        guard response.status == 200 else { throw SessionsError.http(what, response.status) }
        return try SessionsJSON.results(response.body, what)
    }

    // MARK: Workspace control (§4)

    /// `Sessions/ListAvailable` for apps. `excludeActive`: leave out sessions connected on other
    /// devices; reconnecting an entry of the full list can take a session away from another device (§4.1).
    public func available(excludeActive: Bool) async throws -> [AvailableSession] {
        var form = [("resourceTypes", "Citrix.MPS.Application")]
        if excludeActive { form.append(("excludeActive", "true")) }
        let response = try await request("POST", endpoints.listAvailable, .form(form))
        guard response.status == 200 else { throw SessionsError.http("Sessions/ListAvailable", response.status) }
        return try SessionsJSON.available(response.body)
    }

    /// Device-wide disconnect, only if `DeviceWideGuard` passes on a fresh `Sessions/List` (§8.6).
    public func disconnectDevice(clientNames: Set<String>, isOurs: (StoreSessionInfo) -> Bool) async throws -> WorkspaceStatus {
        try await deviceWide(endpoints.disconnect, "Sessions/Disconnect", clientNames: clientNames, isOurs: isOurs)
    }

    /// Device-wide log off, only if `DeviceWideGuard` passes on a fresh `Sessions/List` (§8.6).
    public func logOffDevice(clientNames: Set<String>, isOurs: (StoreSessionInfo) -> Bool) async throws -> WorkspaceStatus {
        try await deviceWide(endpoints.logoff, "Sessions/Logoff", clientNames: clientNames, isOurs: isOurs)
    }

    private func deviceWide(_ path: String, _ what: String, clientNames: Set<String>,
                            isOurs: (StoreSessionInfo) -> Bool) async throws -> WorkspaceStatus {
        let current = try await list()
        if case .refused(let reason) = DeviceWideGuard.check(current, cookieDeviceId: transport.cookie(DeviceIdentity.cookieName),
                                                             clientNames: clientNames, isOurs: isOurs) {
            log("sessions: \(what) refused: \(reason)")
            throw SessionsError.refused(reason)
        }
        let response = try await request("POST", path, .form([]))
        guard response.status == 200 else { throw SessionsError.http(what, response.status) }
        return try SessionsJSON.workspaceStatus(response.body, what)
    }
}

// MARK: - Safety gates

/// Device-wide calls act on every session the store ties to the calling device (§4.4, §8.6 item 4),
/// and how it ties them is not documented. So the guard does not rely on the tie: it allows the call
/// only if every listed session is one the caller wants to act on, the list had no unreadable entry,
/// every session carries a device id, and the store's device id equals the `CtxsDeviceId` cookie we
/// send. That stays safe even if the app and icactl end up with different device ids.
public enum DeviceWideGuard {
    public enum Verdict: Equatable {
        case allowed([String])
        case refused(String)
    }

    public static func tied(_ list: StoreSessionList, clientNames: Set<String>) -> [StoreSessionInfo] {
        let device = list.deviceId.flatMap { $0.isEmpty ? nil : $0 }
        let names = Set(clientNames.filter { !$0.isEmpty }.map { $0.lowercased() })
        return list.sessions.filter { s in
            (device != nil && s.deviceId == device) || (s.clientName.map { names.contains($0.lowercased()) } ?? false)
        }
    }

    /// `cookieDeviceId`: the `CtxsDeviceId` cookie in the jar the call will be sent with.
    public static func check(_ list: StoreSessionList, cookieDeviceId: String?, clientNames: Set<String>,
                             isOurs: (StoreSessionInfo) -> Bool) -> Verdict {
        guard let device = list.deviceId, !device.isEmpty else { return .refused("the store did not report this device's id") }
        guard let cookie = cookieDeviceId, cookie == device else {
            return .refused("the store's device id does not match our CtxsDeviceId cookie")
        }
        guard list.skipped == 0 else { return .refused("\(list.skipped) session entr(ies) could not be read") }
        let noDevice = list.sessions.filter { ($0.deviceId ?? "").isEmpty }
        guard noDevice.isEmpty else { return .refused("\(noDevice.count) session(s) carry no device id") }
        let mine = tied(list, clientNames: clientNames)
        guard !mine.isEmpty else { return .refused("no session is tied to this device") }
        let foreign = list.sessions.filter { !isOurs($0) }
        guard foreign.isEmpty else {
            return .refused("\(foreign.count) listed session(s) are not ours (\(foreign.map(\.shortId).joined(separator: ", ")))")
        }
        return .allowed(mine.map(\.sessionId))
    }
}

/// Headless test runs may only disconnect, log off or reconnect sessions whose apps are all test
/// resources (D30): "Calculator" and "Notepad". ICA_TEST_RESOURCES replaces that list only
/// together with ICA_ALLOW_ANY_RESOURCE=1.
public enum TestSessionGate {
    public static let defaultResources = ["Calculator", "Notepad"]

    public static func allowedNames(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard env["ICA_ALLOW_ANY_RESOURCE"] == "1", let text = env["ICA_TEST_RESOURCES"] else { return defaultResources }
        let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? defaultResources : names
    }

    /// The session's app names, resolved through the resource list by id where possible.
    public static func resolvedNames(_ session: StoreSessionInfo, resources: [StoreClient.Resource]) -> [String] {
        session.applications.map { app in
            app.id.flatMap { id in resources.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name } ?? app.name
        }
    }

    /// True only if the session lists at least one app and every app is an allowed test resource.
    public static func allows(_ session: StoreSessionInfo, allowed: [String], resources: [StoreClient.Resource] = []) -> Bool {
        guard !session.applications.isEmpty, !allowed.isEmpty else { return false }
        return session.applications.allSatisfy { app in
            if allowed.contains(app.name) { return true }
            guard let id = app.id, let r = resources.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                return false
            }
            return allowed.contains(r.name)
        }
    }

    /// For a ListAvailable entry (only `initialapp` is known).
    public static func allows(_ entry: AvailableSession, allowed: [String]) -> Bool {
        entry.initialapp.map(allowed.contains) ?? false
    }
}

// MARK: - Connection Center model (§8.1, §7.2)

/// One row of the Connection Center: a store session joined with its reconnect entry.
public struct StoreSession: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case connectedHere
        case connectedElsewhere(clientName: String?, deviceType: String?)
        case disconnected
        case unknown
    }

    /// `Sessions/List` id; nil if the session is known only from ListAvailable.
    public var id: String?
    public var state: State
    public var isDesktop: Bool
    public var started: Date?
    public var machine: String?
    public var apps: [StoreSessionInfo.App]
    public var initialApp: String?
    /// Set only when the entry joined exactly one `Sessions/List` session, that session is
    /// disconnected, and (if trusted) the excludeActive answer lists the entry too.
    public var reconnect: AvailableSession?
    /// Any other joined or unjoined entry: it may be open on another device; launch only after the
    /// user confirmed.
    public var takeOver: AvailableSession?
    /// The join is not one-to-one (§7.2): neither Reconnect nor Take Over for this row.
    public var joinAmbiguous = false
    public var info: StoreSessionInfo?

    public init(id: String?, state: State, isDesktop: Bool = false, started: Date? = nil, machine: String? = nil,
                apps: [StoreSessionInfo.App] = [], initialApp: String? = nil, reconnect: AvailableSession? = nil,
                takeOver: AvailableSession? = nil, joinAmbiguous: Bool = false, info: StoreSessionInfo? = nil) {
        self.id = id
        self.state = state
        self.isDesktop = isDesktop
        self.started = started
        self.machine = machine
        self.apps = apps
        self.initialApp = initialApp
        self.reconnect = reconnect
        self.takeOver = takeOver
        self.joinAmbiguous = joinAmbiguous
        self.info = info
    }

    /// App names for display: the session's apps, else the initial app.
    public var appNames: [String] {
        let names = apps.map(\.name)
        return names.isEmpty ? (initialApp.map { [$0] } ?? []) : names
    }
}

public enum SessionDirectory {
    /// The WD's client name when the ICA file has none (WDModules.swift).
    public static var defaultClientName: String { WDLogon().clientName }

    /// §8.1 state rule.
    public static func state(of s: StoreSessionInfo, deviceId: String?, clientNames: Set<String>) -> StoreSession.State {
        if s.connectionState == .disconnected { return .disconnected }
        guard s.isConnected else { return .unknown }
        let names = Set(clientNames.map { $0.lowercased() })
        let here = (deviceId.map { !$0.isEmpty && s.deviceId == $0 } ?? false)
            || (s.clientName.map { names.contains($0.lowercased()) } ?? false)
        return here ? .connectedHere : .connectedElsewhere(clientName: s.clientName, deviceType: s.deviceType)
    }

    /// Sessions that may be offered as a plain Reconnect (§9.5, §8.5): listed by id, disconnected in
    /// `Sessions/List`, joined one-to-one with a ListAvailable entry. Never one open elsewhere.
    public static func reconnectable(_ rows: [StoreSession]) -> [StoreSession] {
        rows.filter { $0.id != nil && $0.state == .disconnected && !$0.joinAmbiguous && $0.reconnect != nil && $0.takeOver == nil }
    }

    /// Joins `Sessions/List` with the two `ListAvailable` answers (§7.2).
    /// - `available`: without `excludeActive` (disconnected and connected-elsewhere sessions).
    /// - `excludingActive`: with `excludeActive=true`; nil if that call failed.
    /// - `list`: nil if `Sessions/List` failed or is not offered.
    ///
    /// `excludeActive` is only a hint: an entry is offered as a plain Reconnect only if it joins exactly
    /// one List session, nothing else joins that session, and the List says it is disconnected. The
    /// excludeActive answer is ignored when it cannot have excluded anything although the List shows
    /// sessions open elsewhere. Unjoined entries, and joins to other states, are Take Over (confirmed).
    public static func merge(list: StoreSessionList?, available: [AvailableSession], excludingActive: [AvailableSession]?,
                             clientNames: Set<String>) -> [StoreSession] {
        var entries = available
        for e in excludingActive ?? [] where !entries.contains(where: { $0.launchurl == e.launchurl }) { entries.append(e) }

        guard let list else {
            // Nothing to join with: no entry is known to be disconnected.
            return entries.map { StoreSession(id: nil, state: .unknown, initialApp: $0.initialapp, takeOver: $0) }
        }

        var rows = list.sessions.map { s in
            StoreSession(id: s.sessionId, state: state(of: s, deviceId: list.deviceId, clientNames: clientNames),
                         isDesktop: s.userSessionType?.lowercased() == "desktop", started: s.sessionStartTime,
                         machine: s.machineHost, apps: s.applications, info: s)
        }
        var trusted = excludingActive
        if let ex = trusted, ex.count == available.count,
           rows.contains(where: { if case .connectedElsewhere = $0.state { true } else { false } }) {
            trusted = nil   // it excluded nothing although sessions are open elsewhere
        }
        let safe = Set((trusted ?? []).map(\.launchurl))

        func candidates(_ e: AvailableSession) -> [Int] {
            guard let app = e.initialapp?.lowercased() else { return [] }
            return rows.indices.filter { i in
                rows[i].state != .connectedHere && rows[i].apps.contains { $0.name.lowercased() == app || $0.id?.lowercased() == app }
            }
        }
        let candidateSets = entries.map(candidates)
        var claims = [Int: Int]()   // row → number of entries that could be its
        for set in candidateSets { for i in set { claims[i, default: 0] += 1 } }

        var extra: [StoreSession] = []
        for (e, set) in zip(entries, candidateSets) {
            guard !set.isEmpty else {
                // Not in Sessions/List (yet): its own row; it may be open elsewhere.
                extra.append(StoreSession(id: nil, state: .unknown, initialApp: e.initialapp, takeOver: e))
                continue
            }
            guard set.count == 1, claims[set[0]] == 1 else {
                for i in set { rows[i].joinAmbiguous = true }
                continue
            }
            let i = set[0]
            rows[i].initialApp = e.initialapp
            if rows[i].state == .disconnected, trusted == nil || safe.contains(e.launchurl) {
                rows[i].reconnect = e
            } else {
                rows[i].takeOver = e
            }
        }
        for i in rows.indices where rows[i].joinAmbiguous {
            rows[i].reconnect = nil
            rows[i].takeOver = nil
        }
        return rows + extra
    }
}

// MARK: - Device identity (§8.6)

/// Where the store's device id cookie is kept between runs: the app's settings (UserDefaults) for
/// ICAViewer, a 0600 file in `.session/` for icactl. Never logged.
public protocol DeviceIdentityStore: AnyObject {
    func load() -> [String: String]?
    func save(_ record: [String: String])
}

public final class UserDefaultsDeviceIdentity: DeviceIdentityStore {
    let defaults: UserDefaults
    let key: String

    public init(defaults: UserDefaults = .standard, key: String = "storeDeviceId") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: String]? { defaults.dictionary(forKey: key) as? [String: String] }
    public func save(_ record: [String: String]) { defaults.set(record, forKey: key) }
}

public final class FileDeviceIdentity: DeviceIdentityStore {
    let path: String

    public init(path: String) { self.path = path }

    public func load() -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    }

    public func save(_ record: [String: String]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

/// Keeps the `CtxsDeviceId` cookie stable across logons: the gateway logon starts with an empty jar
/// (D11), which would make every run a new device (§8.6 items 2–3).
public enum DeviceIdentity {
    public static let cookieName = "CtxsDeviceId"

    /// Puts the saved cookie back if the jar has none.
    public static func restore(into http: HTTPClient, from store: DeviceIdentityStore, base: URL) {
        guard http.cookieRecord(cookieName) == nil, let record = store.load(), let value = record["value"], !value.isEmpty,
              let host = base.host else { return }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName, .value: value,
            .domain: record["domain"] ?? host, .path: record["path"] ?? "/",
            .expires: Date().addingTimeInterval(10 * 365 * 86400),
        ]
        if base.scheme == "https" { properties[.secure] = "TRUE" }
        if let cookie = HTTPCookie(properties: properties) { http.setCookie(cookie) }
    }

    /// Saves the jar's cookie when it is new or changed.
    public static func remember(from http: HTTPClient, into store: DeviceIdentityStore) {
        guard let cookie = http.cookieRecord(cookieName), !cookie.value.isEmpty else { return }
        let record = ["value": cookie.value, "domain": cookie.domain, "path": cookie.path]
        if store.load() != record { store.save(record) }
    }
}
