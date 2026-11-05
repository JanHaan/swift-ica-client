import Foundation

/// One ICA session through the gateway: TLS → CGP bind (STA ticket) → TcpProxy channel →
/// ICA detect → Winstation Driver, with the Thinwire (`CTXTW`, ch 9) and seamless (`CTXTWI`, ch 12)
/// engines registered.
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
        /// The session ended; text says why.
        case closed(String)
    }

    public let wd: WinstationDriver
    public let thinwire: ThinwireEngine
    public let seamless: SeamlessEngine
    public let host: String
    public let port: UInt16
    public var onEvent: (Event) -> Void = { _ in }

    private let ticket: String
    private let cgp = CGPSession()
    private let stream: TLSStream
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<Bool>()
    private var sawDetect = false
    public private(set) var acksSent = 0
    private var closed = false
    private var finishing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(ica: ICAFile, configuration: WinstationDriver.Configuration) throws {
        guard let proxy = ica["SSLProxyHost"], let ticket = ica["Address"], ica.bool("CGPSecurityTicket") else {
            throw Failure.notGatewayFile
        }
        let colon = proxy.lastIndex(of: ":")
        host = colon.map { String(proxy[..<$0]) } ?? proxy
        port = colon.flatMap { UInt16(proxy[proxy.index(after: $0)...]) } ?? 443
        self.ticket = ticket
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
        queue = DispatchQueue(label: "ica.session")
        queue.setSpecific(key: Self.queueKey, value: true)
        stream = TLSStream(host: host, port: port, queue: queue)
        wd.schedule = { [weak self] block in self?.perform(block) }
        wd.transmit = { [weak self] bytes in
            guard let self else { return }
            // Acks ride on data only once connected; during the handshake only the >5 rule applies.
            self.stream.enqueue(self.cgp.dataPacket(Data(bytes), piggybackAck: self.wd.phase == .connected))
        }
        wd.onEvent = { [weak self] event in self?.onEvent(.wd(event)) }
        stream.onSendError = { [weak self] error in self?.perform { self?.finish("send failed: \(error)") } }
    }

    /// Runs `block` on the session queue (inline if already there).
    public func perform(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { block() } else { queue.async(execute: block) }
    }

    /// Runs `body` on the session queue with the driver and the seamless engine (input, TWI requests).
    public func send(_ body: @escaping (WinstationDriver, SeamlessEngine) -> Void) {
        perform { [self] in
            guard !closed else { return }
            body(wd, seamless)
        }
    }

    /// Asks the server to log the session off (TWI LOGOFF). False if the TWI channel cannot send yet.
    /// The server answers with WD TERMINATE 1 a few seconds later and the session closes.
    public func logoff(completion: @escaping (Bool) -> Void = { _ in }) {
        perform { [self] in
            guard !closed, seamless.canSend else { return completion(false) }
            seamless.logoff()
            completion(true)
        }
    }

    /// Connects and starts the receive loop; returns once the bind request is on the wire.
    public func start() async throws {
        try await stream.connect()
        perform { [self] in
            onEvent(.log("TLS connected to \(host):\(port)"))
            stream.enqueue(cgp.bindRequest(ticket: ticket))
            onEvent(.log("→ CGP bind request (ticket \(ticket.count) chars)"))
            stream.startReceiving { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let chunk): self.handle(chunk)
                case .failure(let error): self.finish("transport: \(error)")
                }
            }
        }
    }

    private func handle(_ chunk: Data) {
        guard !closed else { return }
        let events: [CGPSession.Event]
        do { events = try cgp.feed(chunk) } catch {
            finish("CGP: \(error) (chunk \(chunk.count)B)")
            return
        }
        for event in events {
            switch event {
            case .signature:
                break
            case .bindResponse(let caps):
                onEvent(.cgpBound(caps))
                stream.enqueue(cgp.channelOpenRequest())
            case .channelOpenResponse(_, let status, let raw):
                onEvent(.channelOpened(status: status))
                onEvent(.log("   channel open response body [" + raw.map { String(format: "%02x", $0) }.joined(separator: " ") +
                             "], sequenced received so far \(cgp.receivedSequenced)"))
                if status != 0 { finish("channel open refused: status \(status)") }
            case .data(let payload):
                if !sawDetect, payload.starts(with: CGPSession.icaDetect) {
                    sawDetect = true
                    onEvent(.detect)
                    stream.enqueue(cgp.detectReply())
                    if payload.count > 6 { wd.receive(payload.dropFirst(6)) }
                } else {
                    wd.receive(payload)
                }
            case .keepalive(let raw):
                // The reference client never answers keepalives; it only acks (below) when more
                // than 5 received packets are unacknowledged.
                onEvent(.keepalive(raw: raw))
            case .finishRequest(let type, let reason):
                stream.enqueue(cgp.finishResponse(closeType: type))
                if !finishing { stream.enqueue(cgp.finishRequest(closeType: type)) }
                finish("server finished CGP (type \(type), reason 0x\(String(reason, radix: 16)))")
            case .finishResponse:
                if finishing { finish("CGP finish acknowledged") }
            case .other(let command, let body):
                // Control packets other than bind carry no secrets; show them for diagnosis.
                onEvent(.log("← CGP cmd 0x\(String(command, radix: 16)) \(body.count)B [" +
                             body.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ") + "]"))
            }
            if closed { return }
        }
        if let ack = cgp.pendingAck() {
            acksSent += 1
            if acksSent == 1 { onEvent(.log("→ CGP ack (received sequenced \(cgp.receivedSequenced)); further acks not logged")) }
            stream.enqueue(ack)
        }
    }

    /// Ends the CGP session politely (FINISH_REQUEST), then closes after `timeout` at the latest.
    public func close(timeout: TimeInterval = 5) async {
        perform { [self] in
            guard !closed, !finishing else { return }
            finishing = true
            stream.enqueue(cgp.finishRequest())
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish("closed after finish timeout") }
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

    public var isClosed: Bool {
        var result = false
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { result = closed } else { queue.sync { result = closed } }
        return result
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        // Let queued writes (finish response, logoff) leave before the connection is cancelled.
        queue.asyncAfter(deadline: .now() + 0.5) { [stream] in stream.close() }
        onEvent(.closed(reason))
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }
}
