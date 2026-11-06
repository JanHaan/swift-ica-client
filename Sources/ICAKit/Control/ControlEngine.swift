import Foundation

/// Virtual channel engine for the control channel `CTXCTL ` (docs/55-session-sharing.md §4–§8): starts another
/// published app inside this running session (session sharing).
///
/// - Module (§4.1): the common 48-byte VD with versions 1/2, host name "ICA", flow type 0, no VD data; the WD gives
///   it the first free channel ≥ 20.
/// - Handshake (§5): the host sends the capability request 0x00, we answer 0x01 (caps 1, 2, 3, 5, 6, 0x0A only, each
///   with the host's len byte), the host commits with 0x02. Only then is the channel ready.
/// - Launches (§6, §7): `launch` queues until the commit, then sends 0x03; each 0x04 status is matched to the oldest
///   outstanding request (FIFO, no id on the wire). Status 5 is ignored and dequeues nothing, as in the reference.
///   A request without a response within `responseTimeout` fails as `.timedOut`; it stays in the FIFO as a
///   placeholder, so a late response does not get attributed to a newer launch.
/// - Commit with cap 5 = 1 (§5.3): our own app goes out over the channel once (reconnect case). Its response, if
///   any, is consumed first; shared launches wait for it at most `ownResponseWait`.
/// - Session events 0x0F are logged; 0x09/0x0C and unknown commands are skipped by length.
///
/// Call everything on the session queue; `onEvent` and the launch completions are called there.
public final class ControlEngine: VirtualChannelEngine, VirtualChannelModule {
    public struct Config: Sendable {
        /// Our own app (§5.3), sent only when the commit asks for it. nil: never.
        public var own: ControlLaunch?
        /// A sent launch without a 0x04 fails after this long (docs/55 §10 step 6; the reference has no timer).
        public var responseTimeout: TimeInterval = 20
        /// A launch waits this long for the capability commit (session still logging on or resuming).
        public var readyTimeout: TimeInterval = 90
        /// After our own launch (§5.3), shared launches wait this long for its response.
        public var ownResponseWait: TimeInterval = 5

        public init() {}
    }

    public enum State: Equatable, Sendable {
        /// No capability commit yet; launches queue.
        case waiting
        /// Capability commit seen: launches go out at once.
        case ready
        /// The session ended.
        case ended
    }

    public enum LaunchResult: Equatable, Sendable, CustomStringConvertible {
        /// Status 0: the app's windows arrive over TWI (§7.3 step 2).
        case started
        /// A non-zero status (§7.2).
        case failed(status: UInt32)
        /// No 0x04 within `responseTimeout`.
        case timedOut
        /// Never sent: no valid application string, the channel never became ready, or the session ended first.
        case notSent(String)
        /// Sent, but the session ended before the response.
        case sessionEnded

        public var description: String {
            switch self {
            case .started: return "started (status 0)"
            case .failed(let status): return "failed (\(ControlWire.statusName(status)))"
            case .timedOut: return "no response (timeout)"
            case .notSent(let why): return "not sent (\(why))"
            case .sessionEnded: return "session ended before the response"
            }
        }
    }

    public enum Event: CustomStringConvertible {
        /// The module as handed to the WD.
        case module([UInt8])
        case log(String)
        /// Capability commit seen; launches can go out.
        case ready(commandLineLimit: Int)
        /// A launch request went out (whole message, header included).
        case launchSent(id: Int, bytes: [UInt8])
        case launchFinished(id: Int, LaunchResult)

        public var description: String {
            switch self {
            case .module(let bytes): return "module \(bytes.count) B: " + ControlEngine.hex(bytes, limit: 64)
            case .log(let text): return text
            case .ready(let limit): return "ready (command-line limit \(limit) B)"
            case .launchSent(let id, let bytes): return "→ launch request #\(id) \(bytes.count) B: " + ControlEngine.hex(bytes, limit: 96)
            case .launchFinished(let id, let result): return "launch #\(id) \(result)"
            }
        }
    }

    /// What the channel saw (session queue; for logs and icactl sharetest).
    public struct Diagnostics: Sendable {
        public var moduleBytes: [UInt8] = []
        public var firstHostBytes: Date?
        public var hostWrites = 0
        public var capabilityRequest: [UInt8]?
        public var capabilityResponse: [UInt8]?
        public var capabilityCommit: [UInt8]?
        public var hostCapabilities: [ControlCapability] = []
        public var commitCapabilities: [ControlCapability] = []
        public var answeredCapabilities: [ControlCapability] = []
        public var readyAt: Date?
        public var launchRequests: [[UInt8]] = []
        public var launchResponses: [[UInt8]] = []
        public var ownLaunchSent = false
        public var sessionGuid: String?
        public var skippedCommands: [UInt8: Int] = [:]
        public var malformed = 0
    }

    public let channelName = ControlWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((Event) -> Void)?
    public let config: Config
    /// Runs a block on the session queue after a delay (timeouts). Nil: no timeouts (tests drive them by hand).
    public var scheduleAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    public private(set) var state = State.waiting
    public private(set) var diagnostics = Diagnostics()
    /// Cap 3 limit in bytes (& ~1); 0 without cap 3 (§6.3).
    public private(set) var commandLineLimit = 0

    private struct Entry {
        var id: Int
        var launch: ControlLaunch
        var completion: ((LaunchResult) -> Void)?
        /// Our own app (§5.3): no completion; removed if unanswered after `ownResponseWait`.
        var own = false
    }

    private var parser = ControlStreamParser()
    private var nextId = 1
    /// Not sent yet (waiting for the commit or for our own launch's response).
    private var queued: [Entry] = []
    /// Sent, in order; a timed-out entry stays as a placeholder with its completion cleared.
    private var outstanding: [Entry] = []
    private var answeredLaunchData = false
    private var ownPending = false
    /// The CGP link is down (output is queued for the resume): timeouts wait for the link.
    private var linkDown = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The 48-byte module (§4.1).
    public func module(channel: UInt8, date: Date) -> [UInt8] {
        let bytes = WDModules.control(channel: channel, date: date)
        diagnostics.moduleBytes = bytes
        onEvent?(.module(bytes))
        return bytes
    }

    /// Launches remaining in the queue or awaiting their response (placeholders not counted).
    public var pendingLaunches: Int { queued.count + outstanding.filter { $0.completion != nil }.count }

    // MARK: Launch

    /// Starts `launch` in this session; `completion` is called once, on the session queue. Returns the request id.
    @discardableResult
    public func launch(_ launch: ControlLaunch, completion: @escaping (LaunchResult) -> Void) -> Int {
        let id = nextId
        nextId += 1
        guard state != .ended else {
            completion(.notSent("the session has ended"))
            return id
        }
        guard launch.applicationString != nil else {
            log("launch #\(id): InitialProgram does not start with # (§6.1); not sent")
            completion(.notSent("InitialProgram does not start with #"))
            return id
        }
        queued.append(Entry(id: id, launch: launch, completion: completion))
        if state != .ready || ownPending { log("launch #\(id) queued (\(state == .ready ? "own launch pending" : "waiting for the capability commit"))") }
        scheduleAfter?(config.readyTimeout) { [weak self] in self?.readyTimedOut(id) }
        pump()
        return id
    }

    private func readyTimedOut(_ id: Int) {
        guard let i = queued.firstIndex(where: { $0.id == id }) else { return }
        if linkDown { return rearm(config.readyTimeout) { [weak self] in self?.readyTimedOut(id) } }
        let entry = queued.remove(at: i)
        finish(entry, .notSent("the channel was not ready after \(Int(config.readyTimeout)) s"))
    }

    private func pump() {
        guard state == .ready, !ownPending else { return }
        while !queued.isEmpty { send(queued.removeFirst()) }
    }

    private func send(_ entry: Entry) {
        guard let bytes = entry.launch.request(commandLineLimit: commandLineLimit) else {
            finish(entry, .notSent("InitialProgram does not start with #"))
            return
        }
        if entry.launch.limitedCommandLine(limit: commandLineLimit) != entry.launch.commandLine {
            log("launch #\(entry.id): command line cut to the host's limit of \(commandLineLimit) B (§6.3)")
        }
        outstanding.append(entry)
        diagnostics.launchRequests.append(bytes)
        output?(.channel(Data(bytes)))
        onEvent?(.launchSent(id: entry.id, bytes: bytes))
        let id = entry.id
        if entry.own {
            scheduleAfter?(config.ownResponseWait) { [weak self] in self?.ownWaitOver(id) }
        } else {
            scheduleAfter?(config.responseTimeout) { [weak self] in self?.responseTimedOut(id) }
        }
    }

    private func responseTimedOut(_ id: Int) {
        guard let i = outstanding.firstIndex(where: { $0.id == id }), outstanding[i].completion != nil else { return }
        if linkDown { return rearm(config.responseTimeout) { [weak self] in self?.responseTimedOut(id) } }
        let entry = outstanding[i]
        outstanding[i].completion = nil   // placeholder: a late response pops it, not a newer launch
        finish(entry, .timedOut)
    }

    private func ownWaitOver(_ id: Int) {
        guard let i = outstanding.firstIndex(where: { $0.id == id && $0.own }) else { return }
        // The reference does not track this launch (§5.3), so the host may never answer it.
        outstanding.remove(at: i)
        log("own launch #\(id): no response within \(Int(config.ownResponseWait)) s; assuming none comes")
        ownPending = false
        pump()
    }

    private func rearm(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        log("link down: launch timeout restarts (\(Int(delay)) s)")
        scheduleAfter?(delay, block)
    }

    /// The CGP link went down; a resume follows or the session ends (`shutdown`).
    public func suspend() { linkDown = true }
    public func resume() { linkDown = false }

    private func finish(_ entry: Entry, _ result: LaunchResult) {
        onEvent?(.launchFinished(id: entry.id, result))
        entry.completion?(result)
    }

    /// The session ended: every launch still waiting is completed.
    public func shutdown() {
        guard state != .ended else { return }
        state = .ended
        let waiting = queued, sent = outstanding
        queued = []
        outstanding = []
        ownPending = false
        waiting.forEach { finish($0, .notSent("the session ended first")) }
        sent.filter { $0.completion != nil }.forEach { finish($0, .sessionEnded) }
    }

    // MARK: Receive

    public func receive(_ data: Data) {
        guard state != .ended else { return }
        if diagnostics.firstHostBytes == nil { diagnostics.firstHostBytes = Date() }
        diagnostics.hostWrites += 1
        for message in parser.feed([UInt8](data)) { handle(message) }
    }

    private func handle(_ message: ControlStreamParser.Message) {
        let p = message.payload
        switch message.command {
        case ControlWire.Command.capabilityRequest:
            diagnostics.capabilityRequest = p
            let caps = ControlCapability.parseList(p)
            diagnostics.hostCapabilities = caps
            log("← capability request \(p.count) B: [\(caps.map(\.description).joined(separator: ", "))]")
            if state == .ready { log("capability request while ready: waiting for a new commit") }
            state = .waiting
            commandLineLimit = ControlCapability.commandLineLimit(caps) ?? 0
            let hasLaunchData = !(config.own?.commandLine.isEmpty ?? true)
            let (payload, answered) = ControlCapability.response(to: caps, hasLaunchData: hasLaunchData)
            answeredLaunchData = answered.contains { $0.id == ControlWire.Capability.launchData }
            diagnostics.answeredCapabilities = answered
            let reply = ControlWire.message(ControlWire.Command.capabilityResponse, payload)
            diagnostics.capabilityResponse = reply
            output?(.channel(Data(reply)))
            log("→ capability response \(reply.count) B: " + Self.hex(reply, limit: 96))
        case ControlWire.Command.capabilityCommit:
            diagnostics.capabilityCommit = p
            let caps = ControlCapability.parseList(p)
            diagnostics.commitCapabilities = caps
            if let limit = ControlCapability.commandLineLimit(caps) { commandLineLimit = limit }
            log("← capability commit \(p.count) B: [\(caps.map(\.description).joined(separator: ", "))]")
            let wantsOwn = caps.first { $0.id == ControlWire.Capability.launchData }?.data.first == 1
            state = .ready
            if diagnostics.readyAt == nil { diagnostics.readyAt = Date() }
            if wantsOwn, answeredLaunchData, let own = config.own, own.applicationString != nil, !diagnostics.ownLaunchSent {
                diagnostics.ownLaunchSent = true
                ownPending = true
                let id = nextId
                nextId += 1
                log("commit asks for our own app (cap 5 = 1, §5.3): sending it as launch #\(id)")
                send(Entry(id: id, launch: own, completion: nil, own: true))
            }
            onEvent?(.ready(commandLineLimit: commandLineLimit))
            pump()
        case ControlWire.Command.launchResponse:
            diagnostics.launchResponses.append(p)
            guard p.count >= 4 else {
                diagnostics.malformed += 1
                return log("← launch response with \(p.count) B (no status); ignored")
            }
            let status = ControlWire.u32(p, 0)
            if status == ControlWire.ignoredStatus {
                return log("← launch response status 5 (unnamed, ignored as in the reference; nothing dequeued)")
            }
            guard !outstanding.isEmpty else { return log("← launch response \(ControlWire.statusName(status)) without a pending request") }
            let entry = outstanding.removeFirst()
            if entry.own {
                log("← own launch #\(entry.id): \(ControlWire.statusName(status))")
                ownPending = false
                pump()
            } else if entry.completion == nil {
                log("← late launch response for #\(entry.id) (timed out before): \(ControlWire.statusName(status))")
            } else {
                finish(entry, status == 0 ? .started : .failed(status: status))
            }
        case ControlWire.Command.sessionEvent:
            sessionEvent(p)
        default:
            diagnostics.skippedCommands[message.command, default: 0] += 1
            log(String(format: "← command 0x%02X, %d B: skipped", message.command, p.count))
        }
    }

    /// §8: `u16, u16, u32` (unused), `u32 type`, then the event data.
    private func sessionEvent(_ p: [UInt8]) {
        guard p.count >= 12 else {
            diagnostics.malformed += 1
            return log("← session event with \(p.count) B; ignored")
        }
        switch ControlWire.u32(p, 8) {
        case 1:
            let state = ControlWire.u32(p, 12)
            log("← session event: state \([1: "LOCK", 2: "DISCONNECT", 3: "LOGOFF"][state] ?? "\(state)")")
        case 2 where p.count >= 28:
            let b = Array(p[12..<28])
            let guid = String(format: "%08X-%04X-%04X-", ControlWire.u32(b, 0), ControlWire.u16(b, 4), ControlWire.u16(b, 6))
                + b[8..<10].map { String(format: "%02X", $0) }.joined() + "-" + b[10...].map { String(format: "%02X", $0) }.joined()
            diagnostics.sessionGuid = guid
            log("← session event: session GUID received")
        case let type:
            log("← session event type \(type), \(p.count) B")
        }
    }

    private func log(_ text: String) { onEvent?(.log(text)) }

    static func hex(_ bytes: [UInt8], limit: Int) -> String {
        bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ") + (bytes.count > limit ? " … (\(bytes.count) B)" : "")
    }
}
