import Foundation

/// One ICA session through the gateway: TLS → CGP bind (STA ticket) → TcpProxy channel →
/// ICA detect → Winstation Driver, with the Thinwire (`CTXTW`, ch 9) and seamless (`CTXTWI`, ch 12)
/// engines registered. The CGP transport resumes the session after a dead link (docs/20 §3.12);
/// nothing above CGP notices except that user input is dropped while suspended.
///
/// Threading: everything (transport, WD, both engines) runs on one serial queue, the session queue.
/// All engine callbacks (`thinwire.onUpdate/onPointer/onInit`, `seamless.onEvent`) and `onEvent` are
/// delivered on that queue; UI code must hop to the main thread itself. Calls into the WD or the
/// engines from elsewhere must go through `perform`.
public final class ICASession: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case notGatewayFile
        public var description: String { "ICA file lacks SSLProxyHost/Address/CGPSecurityTicket" }
    }

    public enum Event {
        case log(String)
        case cgpBound([CGPSession.Capability])
        case channelOpened(status: UInt16)
        case detect
        case keepalive(raw: Data)
        case wd(WinstationDriver.Event)
        /// The link died; the session is suspended until the deadline (§3.12.3). Drop user input.
        case suspended(CGPTransport.Suspension)
        /// Resume attempt n started (TCP+TLS connect, then the resume bind).
        case resuming(attempt: Int)
        /// The session runs again over a new connection (§3.12.6).
        case resumed(CGPSession.ResumeResult)
        /// Session reliability ended without a resume (§3.12.8); `.closed` follows.
        case gaveUp(CGPTransport.GiveUp)
        /// The session ended; text says why.
        case closed(String)
    }

    public let wd: WinstationDriver
    public let thinwire: ThinwireEngine
    public let seamless: SeamlessEngine
    /// Clipboard engine (`CTXCLIP`, ch 17), when the session was created with a clipboard config.
    /// Set `clipboard.onEvent` before `start`; it is called on the session queue.
    public let clipboard: ClipboardEngine?
    /// Client drive mapping engine (`CTXCDM `, ch 10), when the session was created with a CDM config.
    /// Set `cdm.onEvent` before `start`; it is called on the session queue.
    public let cdm: CDMEngine?
    /// Client printing engine (`CTXCPM `, ch 4, PDF mode), when the session was created with a printing
    /// config. Set `printer.onEvent` before `start`; it is called on the session queue.
    public let printer: PrinterEngine?
    /// Client audio engine (`CTXCAM `, ch 19, playback), when the session was created with an audio config.
    /// Set `audio.sink` and `audio.onEvent` before `start`; both are called on the session queue.
    public let audio: AudioEngine?
    /// Webcam engine (`CTXMM  `, ch 18), when the session was created with a webcam config. Set `webcam.source` and
    /// `webcam.onEvent` before `start`; `onEvent` is called on the session queue.
    public let webcam: WebcamEngine?
    /// Control engine (`CTXCTL `, first free channel ≥ 20), when the session was created with a control config: starts
    /// further published apps inside this session (docs/55). Set `control.onEvent` before `start`; it is called on the
    /// session queue.
    public let control: ControlEngine?
    /// CTXGDT discovery engine (ch 29, docs/76 §6), when the session was created with a GDT config (`ICA_GDT=1` in
    /// icactl). Set `gdt.onEvent` before `start`; it is called on the session queue.
    public let gdt: GDTEngine?
    private let gdtChannel: UInt8?
    public let host: String
    public let port: UInt16
    public var onEvent: (Event) -> Void = { _ in }
    /// Thinwire INIT (session queue), after the session's own handling. Use this instead of
    /// `thinwire.onInit`, which the session owns.
    public var onThinwireInit: ((ThinwireSessionInfo) -> Void)?
    /// Send TWI PAUSE + RESUME after each Thinwire INIT (reference behaviour). Off only for experiments.
    public var pauseResumeOnThinwireInit = true
    /// When that PAUSE/RESUME last actually went out (the host then re-announces its windows). Session queue.
    public private(set) var lastPauseResumeSent: Date?
    /// Handshake milestones for the early-drop classification (session queue).
    private var dropMonitor = EarlyDropMonitor()
    /// Last packets each way, redacted (session queue; dumped on an early drop).
    private var packetRing = PacketRing(capacity: 8)
    /// Set when the connection closed before the first Thinwire INIT (before `.closed` is delivered). Any
    /// thread after `.closed`.
    public private(set) var earlyDrop: EarlyDrop?

    public let transport: CGPTransport
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<Bool>()
    private var closed = false
    private let suspendedLock = NSLock()
    private var suspendedFlag = false

    /// `clipboard` nil: no CTXCLIP module and no bind entry, so the host has no clipboard channel
    /// (docs/70 §5.7). `cdm` nil: no CTXCDM module, so no client drive (docs/95 §A). `printing` nil: no
    /// CTXCPM module, so the host creates no PDF printer for this client (docs/97 §6.2). `audio` nil: no CTXCAM
    /// module, so the host plays no sound to this client (docs/98 §1). `webcam` nil: no CTXMM module, so the host
    /// shows no HDX camera (docs/98b §10.5). `control` nil: no CTXCTL module, so no later app can start inside this
    /// session (docs/55 §1). `gdt` nil: no CTXGDT module and no bind entry (the default; docs/76 §6).
    public init(ica: ICAFile, configuration: WinstationDriver.Configuration, clipboard: ClipboardEngine.Config? = nil,
                cdm: CDMEngine.Config? = nil, printing: PrinterEngine.Config? = nil, audio: AudioEngine.Config? = nil,
                webcam: WebcamEngine.Config? = nil, control: ControlEngine.Config? = nil, gdt: GDTEngine.Config? = nil) throws {
        guard let proxy = ica["SSLProxyHost"], let ticket = ica["Address"], ica.bool("CGPSecurityTicket") else {
            throw Failure.notGatewayFile
        }
        let colon = proxy.lastIndex(of: ":")
        host = colon.map { String(proxy[..<$0]) } ?? proxy
        port = colon.flatMap { UInt16(proxy[proxy.index(after: $0)...]) } ?? 443
        var config = configuration
        config.tdPort = port
        wd = WinstationDriver(configuration: config)
        thinwire = ThinwireEngine()
        var twi = SeamlessEngine.Config()
        twi.seamless = config.logon.seamless
        twi.sessionWidth = Int32(config.display.width)
        twi.sessionHeight = Int32(config.display.height)
        seamless = SeamlessEngine(config: twi)
        let full = TWIRect(x: 0, y: 0, width: Int32(config.display.width), height: Int32(config.display.height))
        seamless.setMonitors([TWIMonitor(bounds: full, workArea: full)])
        wd.register(thinwire)
        wd.register(seamless)
        // Registered after CTXTWI, so the module follows it in the INIT_RESPONSE (docs/70 §1.2).
        self.clipboard = clipboard.map { ClipboardEngine(config: $0) }
        if let engine = self.clipboard { wd.register(engine) }
        self.cdm = cdm.map { CDMEngine(config: $0) }
        if let engine = self.cdm { wd.register(engine) }
        // After CTXCLIP and before CTXCPM (docs/98b §1.1, §11 step 1); the 50-byte module comes from the engine.
        self.webcam = webcam.map { WebcamEngine(config: $0) }
        if let engine = self.webcam { wd.register(engine) }
        // After CTXCLIP (docs/97 §1.2 [P]); the module and its per-command ACKs come from the engine.
        self.printer = printing.map { PrinterEngine(config: $0) }
        if let engine = self.printer { wd.register(engine) }
        // After CTXCLIP (docs/98 §1.1, §11 step 1); the 55-byte module and the credits come from the engine.
        self.audio = audio.map { AudioEngine(config: $0) }
        if let engine = self.audio { wd.register(engine) }
        // The first VC without a fixed number, after CTXCAM, as in the reference: channel 20 (docs/55 §4.1).
        self.control = control.map { ControlEngine(config: $0) }
        if let engine = self.control { wd.register(engine) }
        // Discovery only: last, on the stock client's channel 29 (D57).
        let gdtEngine = gdt.map { GDTEngine(config: $0) }
        self.gdt = gdtEngine
        let driver = wd
        gdtChannel = gdtEngine.map { driver.register($0, number: GDTWire.channelNumber) }
        queue = DispatchQueue(label: "ica.session")
        queue.setSpecific(key: Self.queueKey, value: true)
        transport = CGPTransport(host: host, port: port, ticket: ticket, queue: queue)
        // T_sr without a server cap 9: the ICA file's SessionReliabilityTTL (§3.12.4).
        transport.srTimeoutFallback = ica["SessionReliabilityTTL"].flatMap(TimeInterval.init)
        transport.configureTestHooks(from: ProcessInfo.processInfo.environment)
        wd.schedule = { [weak self] block in self?.perform(block) }
        wd.transmit = { [weak self] bytes in
            guard let self else { return }
            if self.wd.phase != .connected { self.packetRing.sentHandshake(bytes) }
            // Acks ride on data only once connected; during the handshake only the >5 rule applies.
            self.transport.send(Data(bytes), piggybackAck: self.wd.phase == .connected)
        }
        wd.onPacketSent = { [weak self] packet in self?.packetRing.sent(packet) }
        wd.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .terminate(let reason):
                // After WD TERMINATE the host closes TCP without CGP FINISH (live): that is the end.
                self.dropMonitor.terminate(reason)
                self.transport.expectServerClose("WD TERMINATE \(reason)")
            case .connected: self.dropMonitor.connectResponseSent()
            case .packet(let p):
                self.dropMonitor.hostPacket()
                self.packetRing.received(p)
                if let gdt = self.gdt, let channel = p.channel, channel == self.gdtChannel {
                    gdt.noteWDPacketType(p.type)
                }
            default: break
            }
            self.onEvent(.wd(event))
        }
        transport.onEvent = { [weak self] event in self?.transportEvent(event) }
        if let engine = self.clipboard {
            let queue = self.queue
            engine.scheduleAfter = { delay, block in queue.asyncAfter(deadline: .now() + delay, execute: block) }
            // Big clipboard responses wait while the CGP retransmit queue is long (its cap is 8 MiB).
            engine.backlog = { [weak self] in self?.transport.status.queuedBytes ?? 0 }
        }
        if let engine = self.cdm {
            let queue = self.queue
            // File I/O off the session queue; replies come back to it in order.
            engine.ioQueue = DispatchQueue(label: "ica.cdm")
            engine.schedule = { [weak self] block in self?.perform(block) }
            engine.scheduleAfter = { delay, block in queue.asyncAfter(deadline: .now() + delay, execute: block) }
            engine.backlog = { [weak self] in self?.transport.status.queuedBytes ?? 0 }
        }
        if let engine = self.audio {
            let queue = self.queue
            // The idle flush of WRITE credits (docs/98 §6.3).
            engine.scheduleAfter = { delay, block in queue.asyncAfter(deadline: .now() + delay, execute: block) }
            // Microphone: permission answers and encoded frames come back to the session queue; encoding runs
            // on its own queue (docs/98 §7).
            engine.schedule = { [weak self] block in self?.perform(block) }
            engine.captureQueue = DispatchQueue(label: "ica.audio.capture")
        }
        if let engine = self.webcam {
            let queue = self.queue
            // Permission answers, frames and encoded samples come back to the session queue (docs/98b §10); the W4/W12
            // checks run after a delay; frames are skipped before encoding while the CGP queue is long (§8).
            engine.schedule = { [weak self] block in self?.perform(block) }
            engine.scheduleAfter = { delay, block in queue.asyncAfter(deadline: .now() + delay, execute: block) }
            engine.backlog = { [weak self] in self?.transport.status.queuedBytes ?? 0 }
        }
        if let engine = self.control {
            let queue = self.queue
            // Launch timeouts (the response and the wait for the capability commit).
            engine.scheduleAfter = { delay, block in queue.asyncAfter(deadline: .now() + delay, execute: block) }
        }
        // After every Thinwire INIT: TWI PAUSE + RESUME, as the reference client does (docs/50 §7.1).
        thinwire.onInit = { [weak self] info in
            guard let self else { return }
            // From the first Thinwire INIT on, a dead link is resumed (docs/20 §3.12.2, early drop).
            self.transport.markEstablished()
            self.dropMonitor.thinwireInit()
            let text: String
            if !self.pauseResumeOnThinwireInit { text = "disabled" }
            else if self.seamless.pauseResume() {
                text = "sent"
                self.lastPauseResumeSent = Date()
            } else {
                text = "not possible yet (no TWI host init)"
            }
            self.onEvent(.log("Thinwire INIT \(info.width)x\(info.height) → TWI PAUSE/RESUME \(text)"))
            self.onThinwireInit?(info)
        }
    }

    private func transportEvent(_ event: CGPTransport.Event) {
        switch event {
        case .log(let text): onEvent(.log(text))
        case .bound(let caps): onEvent(.cgpBound(caps))
        case .channelOpened(let status): onEvent(.channelOpened(status: status))
        case .detect: onEvent(.detect)
        case .keepalive(let raw): onEvent(.keepalive(raw: raw))
        case .data(let payload): wd.receive(payload)
        case .suspended(let info):
            setSuspended(true)
            audio?.suspend()
            webcam?.suspend()
            control?.suspend()
            onEvent(.suspended(info))
        case .resuming(let attempt): onEvent(.resuming(attempt: attempt))
        case .resumed(let result):
            setSuspended(false)
            audio?.resume()
            webcam?.resume()
            control?.resume()
            onEvent(.resumed(result))
        case .gaveUp(let info): onEvent(.gaveUp(info))
        case .closed(let reason):
            if let drop = dropMonitor.classify() {
                earlyDrop = drop
                onEvent(.log(drop.summary))
                for line in packetRing.lines { onEvent(.log("early drop: " + line)) }
            }
            closed = true
            setSuspended(false)
            cdm?.shutdown()
            printer?.shutdown()
            audio?.shutdown()
            webcam?.shutdown()
            control?.shutdown()
            onEvent(.closed(reason))
        }
    }

    private func setSuspended(_ value: Bool) {
        suspendedLock.lock()
        suspendedFlag = value
        suspendedLock.unlock()
    }

    /// True while the link is down and a resume is pending (CGP states 5 and 6). Any thread.
    public var isSuspended: Bool {
        suspendedLock.lock()
        defer { suspendedLock.unlock() }
        return suspendedFlag
    }

    /// Runs `block` on the session queue (inline if already there).
    public func perform(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { block() } else { queue.async(execute: block) }
    }

    /// Runs `body` on the session queue with the driver and the seamless engine (input, TWI requests).
    /// While suspended this output is queued by CGP and sent after the resume (§3.12.7).
    public func send(_ body: @escaping (WinstationDriver, SeamlessEngine) -> Void) {
        perform { [self] in
            guard !closed else { return }
            body(wd, seamless)
        }
    }

    /// User keyboard or mouse input: dropped while suspended (§3.12.3 step 3), not queued.
    public func sendInput(_ body: @escaping (WinstationDriver) -> Void) {
        perform { [self] in
            guard !closed, !isSuspended else { return }
            body(wd)
        }
    }

    /// A Mac clipboard snapshot for the host (any thread). Ignored without a clipboard channel. While
    /// suspended the announce is queued by CGP like other channel output.
    public func clipboardAnnounce(_ snapshot: ClipboardSnapshot) {
        perform { [self] in
            guard !closed, let clipboard else { return }
            clipboard.announceLocal(snapshot)
        }
    }

    /// Asks the server to log the session off (TWI LOGOFF). False if the TWI channel cannot send yet,
    /// or while suspended (the caller then closes without FINISH, §3.12.8).
    /// The server answers with WD TERMINATE 1 a few seconds later and the session closes.
    public func logoff(completion: @escaping (Bool) -> Void = { _ in }) {
        perform { [self] in
            // The microphone and the camera stop the moment the session starts ending, not when the logoff completes.
            audio?.disableMicrophone(notifyHost: false, reason: "logoff")
            webcam?.disableCamera(notifyHost: false, reason: "logoff")
            guard !closed, !isSuspended, seamless.canSend else { return completion(false) }
            seamless.logoff()
            transport.expectServerClose("TWI logoff")
            completion(true)
        }
    }

    /// Starts another published app inside this session over CTXCTL (docs/55 §6), any thread. Queued until the channel
    /// is ready; `completion` runs once, on the session queue. Without a control channel: `.notSent` at once.
    public func launchInSession(_ launch: ControlLaunch, completion: @escaping (ControlEngine.LaunchResult) -> Void) {
        perform { [self] in
            guard let control else { return completion(.notSent("no control channel in this session")) }
            guard !closed else { return completion(.notSent("the session has ended")) }
            control.launch(launch, completion: completion)
        }
    }

    /// Connects and starts the receive loop; returns once the bind request is on the wire.
    public func start() async throws { try await transport.start() }

    /// Ends the CGP session politely (FINISH_REQUEST), then closes after `timeout` at the latest.
    /// While suspended: closes at once, without FINISH.
    public func close(timeout: TimeInterval = 5) async {
        // The microphone and the camera stop before FINISH goes out (disconnect, quit, reconnect to apply settings).
        perform { [self] in
            audio?.disableMicrophone(notifyHost: false, reason: "disconnect")
            webcam?.disableCamera(notifyHost: false, reason: "disconnect")
        }
        await transport.close(timeout: timeout)
    }

    /// "Disable microphone" for this session (any thread): capture stops at once, the host is told the
    /// device failed, and later capture OPENs are answered "failed" (docs/98 §10.3).
    public func disableMicrophone() {
        perform { [self] in audio?.disableMicrophone(notifyHost: !closed, reason: "disabled by the user") }
    }

    /// "Disable Camera for This Session" (any thread): the camera stops at once, the host gets the 0x86 error for the
    /// open context, and later device contexts are answered with the error (docs/98b §10.4).
    public func disableCamera() {
        perform { [self] in webcam?.disableCamera(notifyHost: !closed, reason: "disabled by the user") }
    }

    /// Suspends until the session has ended.
    public func waitUntilClosed() async { await transport.waitUntilClosed() }

    public var isClosed: Bool { transport.isClosed }

    /// True once the first Thinwire INIT arrived: the host built the session's display. Before that a
    /// dead link is an early drop, not resumed (docs/20 §3.12.2). Any thread.
    public var isEstablished: Bool { transport.isEstablished }

    public var acksSent: Int { transport.status.acksSent }

    // MARK: OS events (docs/20 §3.12.2), any thread

    /// Network path: `online` false = offline event; true = online event (also a changed interface).
    public func networkChanged(online: Bool) { transport.networkChanged(online: online) }
    public func systemWillSleep() { transport.systemWillSleep() }
    public func systemDidWake() { transport.systemDidWake() }
}

// MARK: - CGP transport

/// Time and timers of `CGPTransport`: liveness and keepalive ticker, wake and path checks, resume
/// attempts, first read, T_sr deadline, close timeouts, test hooks. `SystemCGPClock` is the real
/// one; tests inject a manual clock and advance it explicitly.
public protocol CGPClock: AnyObject, Sendable {
    /// Monotonic, runs during system sleep.
    func now() -> ContinuousClock.Instant
    /// Monotonic, stops during system sleep.
    func uptime() -> SuspendingClock.Instant
    /// Wall time (UI countdown, relaunch hint).
    func date() -> Date
    /// Runs `work` once on `queue` after `delay` s: on the uptime clock (`DispatchTime`) or, with
    /// `wall`, on the wall clock that runs during sleep (`DispatchWallTime`).
    @discardableResult
    func schedule(after delay: TimeInterval, wall: Bool, on queue: DispatchQueue, _ work: @escaping () -> Void) -> CGPTimer
    /// Runs `work` on `queue` every `interval` s on the uptime clock, first after one interval.
    func scheduleRepeating(every interval: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> CGPTimer
}

/// A pending timer of a `CGPClock`; once cancelled it never runs.
public protocol CGPTimer: AnyObject {
    func cancel()
}

extension DispatchWorkItem: CGPTimer {}

/// Dispatch timers on the given queue.
public final class SystemCGPClock: CGPClock {
    public init() {}
    public func now() -> ContinuousClock.Instant { .now }
    public func uptime() -> SuspendingClock.Instant { .now }
    public func date() -> Date { Date() }

    @discardableResult
    public func schedule(after delay: TimeInterval, wall: Bool, on queue: DispatchQueue, _ work: @escaping () -> Void) -> CGPTimer {
        let item = DispatchWorkItem(block: work)
        if wall { queue.asyncAfter(wallDeadline: .now() + delay, execute: item) } else { queue.asyncAfter(deadline: .now() + delay, execute: item) }
        return item
    }

    public func scheduleRepeating(every interval: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> CGPTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        return SourceTimer(timer)
    }

    private final class SourceTimer: CGPTimer {
        let source: DispatchSourceTimer
        init(_ source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }
}

/// The CGP session over one or more TCP/TLS connections: first bind, default channel, ICA detect,
/// link liveness, client keepalives and the session-reliability resume loop (docs/20 §3.12).
/// ICA bytes go in through `send` and come out as `.data` events. Runs on one serial queue; events
/// are delivered on it.
public final class CGPTransport: @unchecked Sendable {
    /// Times from §3.12.2 and §3.12.4; tests shorten them.
    public struct Timing: Sendable {
        public var startDelay: TimeInterval = 3
        public var retryDelay: TimeInterval = 3
        public var connectTimeout: TimeInterval = 20
        public var firstReadTimeout: TimeInterval = 20
        public var livenessInterval: TimeInterval = 5
        public var livenessMinimum: TimeInterval = 25
        public var wakeCheckMinimum: TimeInterval = 5
        public var pathVerification: TimeInterval = 15
        /// Resolution of the keepalive and liveness timer.
        public var tick: TimeInterval = 1
        /// T_sr when neither server cap 9 nor the ICA file give one.
        public var defaultSRTimeout: TimeInterval = 180
        public init() {}
    }

    public struct Suspension: Sendable {
        /// T_sr end (wall time, for the countdown).
        public let deadline: Date
        public let reason: String
        /// Server cap 9 UI dimming % (§3.12.9), if the server sent cap 9.
        public let dimming: Int?
    }

    public struct GiveUp: Sendable {
        public enum Cause: Sendable {
            case deadline, offline
            case refused(CGPSession.ResumeRefusal)
            case serverFinish(reason: UInt8)
            case queueOverflow
            case channelRefused(UInt16)
        }
        public let cause: Cause
        /// Text for the user (§3.12.8 table).
        public let message: String
        /// False only when the server ended the session normally (FINISH reason 0x00).
        public let offerRelaunch: Bool
        /// Without an explicit refusal the VDA may hold the session for SR until about then; a store
        /// relaunch before it would not reconnect yet (§3.12.11).
        public let relaunchNotBefore: Date?
    }

    public enum Event {
        case log(String)
        case bound([CGPSession.Capability])
        case channelOpened(status: UInt16)
        case detect
        case keepalive(raw: Data)
        /// ICA bytes for the WD (detect string removed).
        case data(Data)
        case suspended(Suspension)
        case resuming(attempt: Int)
        case resumed(CGPSession.ResumeResult)
        case gaveUp(GiveUp)
        case closed(String)
    }

    public struct Status: Sendable {
        public var state: CGPSession.State = .notStarted
        public var receivedSequenced = 0
        public var sent = 0
        public var acknowledged = 0
        public var queued = 0
        public var queuedBytes = 0
        public var ackOverrun = 0
        public var attempts = 0
        public var resumes = 0
        public var acksSent = 0
        public var keepalivesSent = 0
    }

    public let host: String
    public let port: UInt16
    public var timing = Timing()
    /// ICA `SessionReliabilityTTL`.
    public var srTimeoutFallback: TimeInterval?
    public var onEvent: (Event) -> Void = { _ in }
    /// Test hooks (first connection only): abrupt drop after n s; stall reads and writes after n s.
    public var testDropAfter: TimeInterval?
    public var testBlackhole: (after: TimeInterval, duration: TimeInterval)?

    private let tls: Bool
    private let ticket: String
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    let cgp = CGPSession()
    private var stream: TLSStream?
    /// Bumped whenever the current connection is dropped; callbacks of older connections are ignored.
    private var generation = 0
    private var sawDetect = false
    private var detectAgain = 0
    private var channelOpened = false
    private var closed = false
    private var finishing = false
    /// Set once the session is ending on the ICA level (TERMINATE received, logoff sent).
    private var endExpected: String?
    /// Set by the owner once the session is established (ICA: first Thinwire INIT). Before that a
    /// dead link is an early drop: closed at once, no SR (deviation, docs/20 §3.12.2).
    private var established = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var counters = Status()

    // Liveness and keepalive (§3.12.2). Silence is measured with a clock that runs during sleep; a
    // tick that sees a sleep gap runs the wake check instead of judging the gap as silence.
    private let clock: CGPClock
    private var lastReceived: ContinuousClock.Instant
    private var lastSent: ContinuousClock.Instant
    private var lastLivenessCheck: ContinuousClock.Instant
    private var lastTick: (ContinuousClock.Instant, SuspendingClock.Instant)
    private var ticker: CGPTimer?
    private var wakeCheck: CGPTimer?
    private var pathCheck: CGPTimer?
    private var online = true

    // Resume loop (§3.12.4).
    private var srDeadline: ContinuousClock.Instant?
    private var srTimeoutUsed: TimeInterval = 0
    private var suspendedAt: Date?
    private var onlineDuringSuspension = false
    private var deadlineTimer: CGPTimer?
    private var attemptWork: CGPTimer?
    private var attemptDue: ContinuousClock.Instant?
    private var attemptToken = 0
    private var attemptInProgress = false
    private var attempt = 0
    private var firstReadTimer: CGPTimer?

    public init(host: String, port: UInt16, tls: Bool = true, ticket: String, queue: DispatchQueue,
                clock: CGPClock = SystemCGPClock()) {
        self.host = host
        self.port = port
        self.tls = tls
        self.ticket = ticket
        self.queue = queue
        self.clock = clock
        let now = clock.now()
        lastReceived = now
        lastSent = now
        lastLivenessCheck = now
        lastTick = (now, clock.uptime())
        queue.setSpecific(key: queueKey, value: true)
        cgp.output = { [weak self] packet in self?.write(packet) }
    }

    /// `ICA_TEST_DROP_AFTER=<s>`, `ICA_TEST_BLACKHOLE_AFTER=<s>[:<duration s, default 60>]`.
    public func configureTestHooks(from env: [String: String]) {
        if let drop = env["ICA_TEST_DROP_AFTER"].flatMap(TimeInterval.init) { testDropAfter = drop }
        if let spec = env["ICA_TEST_BLACKHOLE_AFTER"] {
            let parts = spec.split(separator: ":").compactMap { TimeInterval(String($0)) }
            if let after = parts.first { testBlackhole = (after, parts.count > 1 ? parts[1] : 60) }
        }
    }

    public func perform(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { block() } else { queue.async(execute: block) }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    public var isClosed: Bool { onQueue { closed } }

    public var status: Status {
        onQueue {
            var s = counters
            s.state = cgp.state
            s.receivedSequenced = cgp.receivedSequenced
            s.sent = cgp.txSent
            s.acknowledged = cgp.txAcked
            s.queued = cgp.queueCount
            s.queuedBytes = cgp.queueBytes
            s.ackOverrun = cgp.ackOverrun
            return s
        }
    }

    private func log(_ text: String) { onEvent(.log(text)) }

    // MARK: First connection

    /// Connects and starts the receive loop; returns once the bind request is on the wire.
    public func start() async throws {
        let stream = TLSStream(host: host, port: port, tls: tls, queue: queue)
        try await stream.connect(timeout: timing.connectTimeout)
        perform { [self] in
            guard !closed else { return stream.close() }
            log("\(tls ? "TLS" : "TCP") connected to \(host):\(port)")
            install(stream)
            write(cgp.bindRequest(ticket: ticket))
            log("→ CGP bind request (ticket \(ticket.count) chars)")
            scheduleTestHooks()
        }
    }

    private func install(_ stream: TLSStream) {
        generation += 1
        let current = generation
        self.stream = stream
        stream.onSendError = { [weak self] error in
            self?.perform { self?.linkFailed("send failed: \(error)", generation: current) }
        }
        stream.startReceiving { [weak self] result in
            guard let self, current == self.generation, !self.closed else { return }
            switch result {
            case .success(let chunk): self.handle(chunk)
            case .failure(let error): self.linkFailed("transport: \(error)", generation: current)
            }
        }
    }

    /// Closes the current connection (no FINISH) and ignores anything it still delivers.
    private func dropStream() {
        generation += 1
        firstReadTimer?.cancel()
        firstReadTimer = nil
        stream?.close()
        stream = nil
    }

    private func write(_ data: Data) {
        stream?.enqueue(data)
        lastSent = clock.now()
    }

    /// ICA bytes from the WD. Queued for retransmit; written while connected (§3.12.7).
    public func send(_ ica: Data, piggybackAck: Bool) {
        perform { [self] in
            guard !closed else { return }
            checkQueue(cgp.sendData(ica, piggybackAck: piggybackAck))
        }
    }

    /// The retransmit queue went over its limit (§3.12.7). Our reading of the 8 MiB cap: it protects
    /// memory, not the session. In CONNECTED the session runs on without SR (queue freed, nothing
    /// stored any more) and only a later dead link gives up. While suspended the queue cannot be
    /// freed without losing data, so SR gives up at once.
    private func checkQueue(_ withinLimit: Bool) {
        guard !withinLimit, !cgp.reliabilityAbandoned else { return }
        if cgp.state == .connected || cgp.state == .closing {
            log("CGP retransmit queue over \(cgp.queueLimit) B: session reliability off for this session (no resume possible)")
            cgp.abandonReliability()
        } else {
            giveUp(.queueOverflow)
        }
    }

    // MARK: Incoming

    private func handle(_ chunk: Data) {
        firstReadTimer?.cancel()
        firstReadTimer = nil
        // Packets parsed before a failure in the same chunk are already counted: deliver them first.
        let (events, failure) = cgp.consume(chunk)
        if failure == nil || !events.isEmpty { lastReceived = clock.now() }
        for event in events {
            switch event {
            case .signature:
                break
            case .bindResponse(let caps):
                onEvent(.bound(caps))
                logBindDetails()
                cgp.openChannel()
                startTicker()
            case .resumed(let result):
                resumed(result)
            case .resumeRefused(let why):
                giveUp(.refused(why))
            case .channelOpenResponse(_, let status, let raw):
                if channelOpened {
                    // After a resume (§3.12.6): status 0 changes nothing; anything else ends SR.
                    log("← CGP channel open response after resume: status \(status)")
                    if status != 0 { giveUp(.channelRefused(status)) }
                    break
                }
                channelOpened = true
                onEvent(.channelOpened(status: status))
                log("   channel open response body [" + raw.map { String(format: "%02x", $0) }.joined(separator: " ") +
                    "], sequenced received so far \(cgp.receivedSequenced)")
                if status != 0 { finish("channel open refused: status \(status)") }
            case .data(let payload):
                if payload.starts(with: CGPSession.icaDetect) {
                    if !sawDetect {
                        sawDetect = true
                        onEvent(.detect)
                        checkQueue(cgp.sendDetectReply())
                    } else {
                        // Once the handshake is done a leading detect string is stripped, never answered (§3.12.6).
                        detectAgain += 1
                        if detectAgain == 1 { log("← ICA detect string again (stripped, not answered)") }
                    }
                    if payload.count > 6 { onEvent(.data(payload.dropFirst(6))) }
                } else {
                    onEvent(.data(payload))
                }
            case .keepalive(let raw):
                // The reference client never answers keepalives; it only acks (below) when more
                // than 5 received packets are unacknowledged.
                onEvent(.keepalive(raw: raw))
            case .finishRequest(let type, let reason):
                if cgp.state == .resuming {
                    // Refusal in state 6: answer, no FINISH_REQUEST of our own (§3.12.8), give up.
                    write(cgp.finishResponse(closeType: type))
                    giveUp(.serverFinish(reason: reason))
                } else {
                    write(cgp.finishResponse(closeType: type))
                    if !finishing { write(cgp.finishRequest(closeType: type)) }
                    finish("server finished CGP (type \(type), reason 0x\(String(reason, radix: 16)))")
                }
            case .finishResponse:
                if finishing { finish("CGP finish acknowledged") }
            case .other(let command, let body):
                // Known control packets other than bind carry no secrets; show them for diagnosis. An
                // unknown command might carry a ticket update (§3.12.10): length only.
                if CGPSession.Command(rawValue: command) == nil {
                    log("← CGP unknown cmd 0x\(String(command, radix: 16)) \(body.count)B (contents not shown)")
                } else {
                    log("← CGP cmd 0x\(String(command, radix: 16)) \(body.count)B [" +
                        body.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ") + "]")
                }
            }
            if closed { return }
        }
        if let failure {
            if cgp.state == .resuming { attemptFailed("CGP: \(failure)") } else { finish("CGP: \(failure) (chunk \(chunk.count)B)") }
            return
        }
        if let ack = cgp.pendingAck() {
            counters.acksSent += 1
            if counters.acksSent == 1 { log("→ CGP ack (received sequenced \(cgp.receivedSequenced)); further acks not logged") }
            write(ack)
        }
    }

    /// Reconnect-relevant values of the first bind response, without secrets (§3.12.10).
    private func logBindDetails() {
        var parts: [String] = []
        if let p = cgp.reliabilityParams { parts.append("cap 9 timeout \(p.timeout) s, UI flags \(p.uiFlags), dimming \(p.dimming) %, TCP \(p.tcpTimeout)") }
        if let k = cgp.keepaliveIntervals { parts.append("cap 7 \(k.c2h)/\(k.h2c) ms") }
        if let sr = cgp.serverReliability {
            parts.append("SR cookie \(sr.cookieLength) B, nextSeq \(sr.nextSeq), reconnect \(sr.reconnectFlag), items \(sr.itemCount)")
        }
        parts.append(cgp.hasServerTicket ? "reconnect ticket from server" : "no server ticket (STA ticket kept)")
        log("   CGP reliability: " + parts.joined(separator: "; ") + "; T_sr \(Int(srTimeout)) s")
    }

    // MARK: Link liveness (§3.12.2)

    private var srTimeout: TimeInterval {
        if let t = cgp.reliabilityParams?.timeout, t > 0 { return TimeInterval(t) }
        return srTimeoutFallback ?? timing.defaultSRTimeout
    }
    private var h2c: TimeInterval { TimeInterval(cgp.keepaliveIntervals?.h2c ?? 3000) / 1000 }
    private var c2h: TimeInterval { TimeInterval(cgp.keepaliveIntervals?.c2h ?? 3000) / 1000 }
    private var livenessLimit: TimeInterval { max(timing.livenessMinimum, 1.5 * h2c) }

    private func startTicker() {
        ticker?.cancel()
        let now = clock.now()
        lastTick = (now, clock.uptime())
        lastLivenessCheck = now
        ticker = clock.scheduleRepeating(every: timing.tick, on: queue) { [weak self] in self?.tick() }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        wakeCheck?.cancel()
        wakeCheck = nil
        pathCheck?.cancel()
        pathCheck = nil
    }

    private func tick() {
        guard !closed else { return }
        let now = clock.now(), up = clock.uptime()
        let slept = (now - lastTick.0) - (up - lastTick.1) > .seconds(2)
        lastTick = (now, up)
        let livenessDue = now - lastLivenessCheck >= .seconds(timing.livenessInterval)
        if livenessDue { lastLivenessCheck = now }
        switch cgp.state {
        case .connected:
            if slept { return startWakeCheck("sleep gap seen by the timer") }
            // Client keepalive: nothing sent for the C2H interval (deviation, §3.12.2).
            if c2h > 0, now - lastSent >= .seconds(c2h) {
                counters.keepalivesSent += 1
                write(cgp.keepalive())
            }
            if livenessDue, wakeCheck == nil, now - lastReceived > .seconds(livenessLimit) {
                suspend("nothing received for \(Int(livenessLimit)) s")
            }
        case .resuming:
            if livenessDue, now - lastReceived > .seconds(2 * livenessLimit) {
                attemptFailed("nothing received for \(Int(2 * livenessLimit)) s")
            }
        default:
            break
        }
    }

    private func linkFailed(_ reason: String, generation: Int) {
        guard generation == self.generation, !closed else { return }
        switch cgp.state {
        case .connected: suspend(reason)
        case .resuming: attemptFailed(reason)
        case .suspended, .failed, .closed: break
        case .notStarted, .binding, .closing: finish(reason)
        }
    }

    public func systemWillSleep() {
        perform { [self] in
            // No wire action and never a FINISH before sleep (§3.12.2).
            if !closed { log("system will sleep (state \(cgp.state.rawValue))") }
        }
    }

    /// Wake: one keepalive, then suspend if nothing arrives within max(5 s, 1.5 × H2C) (§3.12.2).
    public func systemDidWake() {
        perform { [self] in
            guard !closed else { return }
            log("system woke (state \(cgp.state.rawValue))")
            if cgp.state == .connected { startWakeCheck("wake") }
        }
    }

    private func startWakeCheck(_ why: String) {
        guard cgp.state == .connected, wakeCheck == nil else { return }
        write(cgp.keepalive())
        counters.keepalivesSent += 1
        let mark = clock.now()
        let limit = max(timing.wakeCheckMinimum, 1.5 * h2c)
        log("\(why): keepalive sent, expecting data within \(Int(limit)) s")
        wakeCheck = clock.schedule(after: limit, wall: false, on: queue) { [weak self] in
            guard let self else { return }
            self.wakeCheck = nil
            if self.cgp.state == .connected, self.lastReceived < mark { self.suspend("nothing received within \(Int(limit)) s after \(why)") }
        }
    }

    /// OS path event. Offline or online while connected: verify after 15 s; online while suspended:
    /// cancel the wait and attempt after the start delay (§3.12.2, §3.12.4).
    public func networkChanged(online: Bool) {
        perform { [self] in
            guard !closed else { return }
            self.online = online
            if online, cgp.state == .suspended || cgp.state == .resuming { onlineDuringSuspension = true }
            log("network \(online ? "online / path changed" : "offline") (state \(cgp.state.rawValue))")
            switch cgp.state {
            case .connected:
                guard pathCheck == nil else { return }
                let mark = clock.now()
                pathCheck = clock.schedule(after: timing.pathVerification, wall: false, on: queue) { [weak self] in
                    guard let self else { return }
                    self.pathCheck = nil
                    if self.cgp.state == .connected, self.lastReceived < mark {
                        self.suspend("nothing received within \(Int(self.timing.pathVerification)) s after a network change")
                    }
                }
            case .suspended:
                // Cancel the wait, unless an attempt is due within the start delay anyway (a flapping
                // path must not keep postponing it).
                let dueSoon = attemptDue.map { $0 - clock.now() <= .seconds(timing.startDelay) } ?? false
                if online, !attemptInProgress, !dueSoon { scheduleAttempt(after: timing.startDelay) }
            default:
                break
            }
        }
    }

    // MARK: Suspend and resume (§3.12.3, §3.12.4)

    /// The session got past its handshake (ICA: first Thinwire INIT); from now on a dead link is resumed.
    public func markEstablished() {
        perform { [self] in
            guard !established else { return }
            established = true
        }
    }

    public var isEstablished: Bool { onQueue { established } }

    /// The session is ending above CGP (WD TERMINATE received, TWI logoff sent): from now on a closed
    /// or silent link ends the session instead of suspending it.
    public func expectServerClose(_ why: String) {
        perform { [self] in
            guard !closed, endExpected == nil else { return }
            endExpected = why
        }
    }

    private func suspend(_ reason: String) {
        guard cgp.state == .connected, !closed else { return }
        if !established {
            // Early drop (D10: the VDA sometimes closes ~20 ms after INIT_CONNECT_RESPONSE, before
            // logon). Nothing to resume; a fresh launch is the remedy, so end now (deviation, §3.12.2).
            return finish("early drop: link closed before the session was established (\(reason))")
        }
        if let why = endExpected {
            // Live: after ICA TERMINATE the host closes TCP without CGP FINISH. Not a dead link:
            // state 9, no suspend, no resume (docs/20 §3.12.2).
            return finish("ended by server: connection closed after \(why) (\(reason))")
        }
        if cgp.reliabilityAbandoned {
            log("link dead (\(reason)) with session reliability off")
            return giveUp(.queueOverflow)
        }
        cgp.suspend()                                   // 1. state 5, nothing on the wire
        stopTicker()
        srTimeoutUsed = srTimeout                       // 2. fix T_sr, show the UI
        srDeadline = clock.now() + .seconds(srTimeoutUsed)
        let deadline = clock.date().addingTimeInterval(srTimeoutUsed)
        suspendedAt = clock.date()
        onlineDuringSuspension = online
        attempt = 0
        log("link dead (\(reason)): suspended, resume window \(Int(srTimeoutUsed)) s; queue \(cgp.queueCount) packets, " +
            "received sequenced \(cgp.receivedSequenced)")
        onEvent(.suspended(Suspension(deadline: deadline, reason: reason, dimming: cgp.reliabilityParams?.dimming)))  // 3. input off (app)
        dropStream()                                    // 4. close the socket; parser reset in cgp.suspend()
        armDeadline(after: srTimeoutUsed)
        scheduleAttempt(after: timing.startDelay)       // 5. first attempt after the start delay
    }

    private var deadlinePassed: Bool { srDeadline.map { clock.now() >= $0 } ?? false }

    /// Wall-clock timer at T_sr + 100 ms (runs during sleep, §3.12.4).
    private func armDeadline(after seconds: TimeInterval) {
        deadlineTimer?.cancel()
        deadlineTimer = clock.schedule(after: seconds + 0.1, wall: true, on: queue) { [weak self] in self?.checkDeadline() }
    }

    private func checkDeadline() {
        guard !closed, cgp.state == .suspended || cgp.state == .resuming, let srDeadline else { return }
        let left = srDeadline - clock.now()
        if left > .zero {
            // Fired early (the wall clock was stepped): re-arm for what is left on the continuous clock.
            return armDeadline(after: Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        }
        giveUp(onlineDuringSuspension ? .deadline : .offline)
    }

    private func scheduleAttempt(after delay: TimeInterval) {
        attemptWork?.cancel()
        attemptDue = clock.now() + .seconds(delay)
        attemptWork = clock.schedule(after: delay, wall: false, on: queue) { [weak self] in self?.runAttempt() }
    }

    private func runAttempt() {
        attemptDue = nil
        guard !closed, cgp.state == .suspended, !attemptInProgress else { return }
        if deadlinePassed { return giveUp(onlineDuringSuspension ? .deadline : .offline) }
        guard online else { return scheduleAttempt(after: timing.retryDelay) }
        attempt += 1
        counters.attempts += 1
        attemptInProgress = true
        attemptToken += 1
        let token = attemptToken
        onEvent(.resuming(attempt: attempt))
        log("resume attempt \(attempt): connecting to \(host):\(port)")
        let stream = TLSStream(host: host, port: port, tls: tls, queue: queue)
        let timeout = timing.connectTimeout
        Task { [weak self] in
            do {
                try await stream.connect(timeout: timeout)
                self?.perform { self?.attemptConnected(stream, token: token) }
            } catch {
                self?.perform {
                    guard let self, token == self.attemptToken, self.attemptInProgress else { return }
                    self.attemptFailed("connect: \(error)")
                }
            }
        }
    }

    private func attemptConnected(_ stream: TLSStream, token: Int) {
        guard token == attemptToken, attemptInProgress, !closed, cgp.state == .suspended else { return stream.close() }
        install(stream)
        cgp.beginConnection()
        // Signature and resume bind in one write; state 6 (§3.12.4 step 2).
        let bind = cgp.resumeBindRequest()
        write(bind)
        log("→ CGP resume bind (\(bind.count) B): nextSeq \(cgp.receivedSequenced + 1), firstUnacked \(cgp.firstUnacked), " +
            "queue \(cgp.queueCount) packets / \(cgp.queueBytes) B")
        lastReceived = clock.now()
        startTicker()
        firstReadTimer = clock.schedule(after: timing.firstReadTimeout, wall: false, on: queue) { [weak self] in
            guard let self, self.cgp.state == .resuming else { return }
            self.attemptFailed("no data within \(Int(self.timing.firstReadTimeout)) s")
        }
    }

    /// Failure before the resume bind response: back to state 5 and retry while T_sr lasts
    /// (deviation, §3.12.1).
    private func attemptFailed(_ reason: String) {
        guard !closed, attemptInProgress else { return }
        attemptInProgress = false
        log("resume attempt \(attempt) failed: \(reason)")
        stopTicker()
        dropStream()
        if cgp.state == .resuming { cgp.suspend() }
        if deadlinePassed { return giveUp(onlineDuringSuspension ? .deadline : .offline) }
        scheduleAttempt(after: timing.retryDelay)
    }

    private func resumed(_ result: CGPSession.ResumeResult) {
        attemptInProgress = false
        counters.resumes += 1
        deadlineTimer?.cancel()
        deadlineTimer = nil
        attemptWork?.cancel()
        attemptWork = nil
        attemptDue = nil
        firstReadTimer?.cancel()
        firstReadTimer = nil
        srDeadline = nil
        log("← CGP resume accepted after \(attempt) attempt(s): sent nextSeq \(result.sentNextSeq), server nextSeq " +
            "\(result.serverNextSeq), queue \(result.queueBefore) → dropped \(result.dropped), retransmitted \(result.retransmitted)")
        onEvent(.resumed(result))
        lastReceived = clock.now()
        startTicker()   // liveness and keepalive restart (§3.12.6 step 8)
    }

    /// SR is over: no FINISH (§3.12.8), close the socket, tell the app, end the session.
    private func giveUp(_ cause: GiveUp.Cause) {
        guard !closed else { return }
        cgp.markFailed()
        attemptInProgress = false
        // Ignore the connection from now on; `finish` closes it after a short grace, so a FINISH_RESPONSE
        // owed in state 6 still leaves.
        generation += 1
        let info = Self.giveUpInfo(cause, notBefore: (suspendedAt ?? clock.date()).addingTimeInterval(srTimeoutUsed > 0 ? srTimeoutUsed : srTimeout))
        log("session reliability gave up: \(info.message) (\(cause))")
        onEvent(.gaveUp(info))
        finish("session reliability gave up: \(info.message)")
    }

    /// Message and next step per cause (§3.12.8 table, §3.12.11).
    static func giveUpInfo(_ cause: GiveUp.Cause, notBefore: Date) -> GiveUp {
        let notResumed = "The session could not be resumed."
        switch cause {
        case .deadline:
            return GiveUp(cause: cause, message: "Unable to re-establish a connection to the server.", offerRelaunch: true, relaunchNotBefore: nil)
        case .offline:
            return GiveUp(cause: cause, message: "Check your network connection.", offerRelaunch: true, relaunchNotBefore: nil)
        case .refused(.refused):
            return GiveUp(cause: cause, message: notResumed, offerRelaunch: true, relaunchNotBefore: nil)
        case .refused, .queueOverflow, .channelRefused:
            // Our own decision (deviations): the server may still hold the session for SR.
            return GiveUp(cause: cause, message: notResumed, offerRelaunch: true, relaunchNotBefore: notBefore)
        case .serverFinish(let reason):
            let text: String
            var offer = true
            switch reason {
            case 0x00: text = "The session has ended."; offer = false
            case 0x01: text = notResumed
            case 0x02: text = "The server is shutting down."
            case 0x03: text = "An administrator disconnected the session."
            case 0x11, 0x12, 0x13, 0x14: text = "The gateway rejected the reconnect ticket."
            case 0x15: text = "The server could not read the reconnect request."
            case 0x16: text = "A licensing problem prevented the reconnect."
            case 0x17: text = "The gateway could not resolve the session host."
            case 0x18: text = "The session host refused the connection."
            default: text = notResumed + String(format: " (reason 0x%02x)", reason)
            }
            return GiveUp(cause: cause, message: text, offerRelaunch: offer, relaunchNotBefore: nil)
        }
    }

    // MARK: Close

    /// FINISH from CONNECTED (§3.9); in any other state the socket is closed without FINISH (§3.12.8).
    public func close(timeout: TimeInterval = 5) async {
        perform { [self] in
            guard !closed, !finishing else { return }
            if cgp.state == .connected {
                finishing = true
                cgp.markClosing()
                write(cgp.finishRequest())
                clock.schedule(after: timeout, wall: false, on: queue) { [weak self] in self?.finish("closed after finish timeout") }
            } else {
                let suspended = cgp.state == .suspended || cgp.state == .resuming
                finish(suspended ? "closed while suspended (no FINISH)" : "closed")
            }
        }
        await waitUntilClosed()
    }

    /// Suspends until the session has ended.
    public func waitUntilClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            perform { [self] in
                if closed { continuation.resume() } else { closeWaiters.append(continuation) }
            }
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        cgp.markClosed()
        stopTicker()
        [deadlineTimer, attemptWork, firstReadTimer].forEach { $0?.cancel() }
        attemptInProgress = false
        // Let queued writes (finish response, logoff) leave before the connection is cancelled.
        if let stream { clock.schedule(after: 0.5, wall: false, on: queue) { stream.close() } }
        onEvent(.closed(reason))
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Test hooks

    private func scheduleTestHooks() {
        if let after = testDropAfter {
            testDropAfter = nil
            clock.schedule(after: after, wall: false, on: queue) { [weak self] in
                guard let self, !self.closed, self.cgp.state == .connected, let stream = self.stream else { return }
                self.log("test: dropping the connection abruptly (no FINISH)")
                stream.abort()
                self.linkFailed("test drop", generation: self.generation)
            }
        }
        if let hole = testBlackhole {
            testBlackhole = nil
            clock.schedule(after: hole.after, wall: false, on: queue) { [weak self] in
                guard let self, !self.closed, self.cgp.state == .connected, let stream = self.stream else { return }
                self.log("test: blackhole for \(Int(hole.duration)) s (no reads, no writes)")
                stream.blackhole(for: hole.duration)
            }
        }
    }
}
