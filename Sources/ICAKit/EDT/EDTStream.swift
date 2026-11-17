import Foundation
import Network

/// The byte stream CGP runs on: TCP(+TLS) (`TLSStream`) or EDT (`EDTStream`, D132). All callbacks run on `queue`.
public protocol ICAByteStream: AnyObject {
    var onSendError: ((Error) -> Void)? { get set }
    func connect(timeout: TimeInterval) async throws
    /// Fire-and-forget write; writes keep their order.
    func enqueue(_ data: Data)
    /// `handler` runs on the queue for every chunk, and once with a failure at the end.
    func startReceiving(_ handler: @escaping (Result<Data, Error>) -> Void)
    /// Graceful close.
    func close()
    /// Abrupt close (test hooks).
    func abort()
    /// Test hook: neither read nor write for `duration` seconds.
    func blackhole(for duration: TimeInterval)
    /// "TCP", "TLS" or "EDT" for logs.
    var kind: String { get }
}

extension TLSStream: ICAByteStream {
    public var kind: String { "TCP" }
}

/// CGP over EDT (docs/80, D132): a UDP socket (Network.framework) to the VDA's UDP CGP port with `EDTConnection` as the
/// reliable byte stream. Everything runs on `queue`; a 10 ms timer drives the connection's ACK/NAK/RTO/keep-alive.
/// `connect` throws when the EDT handshake does not complete in time, so the caller can fall back to TCP.
public final class EDTStream: ICAByteStream, @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case handshake(String)
        case closed(String)
        public var description: String {
            switch self {
            case .handshake(let why): "EDT handshake failed: \(why)"
            case .closed(let why): "EDT connection closed: \(why)"
            }
        }
    }

    public let host: String
    public let port: UInt16
    public let queue: DispatchQueue
    public let edt: EDTConnection
    public var onSendError: ((Error) -> Void)?
    public var kind: String { dtlsServerName == nil ? "EDT" : "EDT/DTLS" }
    /// Protocol notes and statistics for the session log.
    public var log: (String) -> Void = { _ in }

    private let connection: NWConnection
    private let t0 = ContinuousClock.now
    private var timer: DispatchSourceTimer?
    private var handler: ((Result<Data, Error>) -> Void)?
    private var pendingDeliveries: [Data] = []
    private var finished = false
    private var lastStats = ContinuousClock.now

    /// DTLS server name (EDT over DTLS, D148): set, the datagrams run inside DTLS 1.2+ with this SNI and the TLS trust
    /// of the TCP path (`TLSStream.tlsOptions`, i.e. the system store and the lab CA where configured).
    public let dtlsServerName: String?
    /// Bytes DTLS adds to every datagram (record header 13 + AES-GCM explicit nonce 8 + tag 16, rounded up): taken off
    /// the packet size offered, so an EDT packet plus DTLS still fits the path.
    public static let dtlsOverhead = 40

    /// `host` is an IPv4 address or a name; the handshake carries the peer's IPv4 address (docs/80 §4.1), so with a name
    /// `peerIPv4` gives it.
    public init(host: String, port: UInt16, queue: DispatchQueue, config: EDTConnection.Config? = nil,
                dtlsServerName: String? = nil, peerIPv4: [UInt8]? = nil) {
        self.host = host
        self.port = port
        self.queue = queue
        self.dtlsServerName = dtlsServerName
        let ip = peerIPv4 ?? host.split(separator: ".").compactMap { UInt8($0) }
        edt = EDTConnection(config: config ?? EDTConnection.Config(peerIPv4: ip.count == 4 ? ip : [0, 0, 0, 0]))
        // Don't fragment (D135): an oversized probe must be lost, not fragmented, or path MTU discovery would lie.
        let parameters: NWParameters
        if let name = dtlsServerName {
            let tls = TLSStream.tlsOptions()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .DTLSv12)
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, name)
            parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        } else {
            parameters = NWParameters.udp
        }
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.disableFragmentation = true }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    /// True once the EDT handshake completed (queue).
    public private(set) var isConnected = false

    /// MTU of a network interface (link-layer `if_data`), e.g. 1280 for Tailscale's utun.
    public static func interfaceMTU(_ name: String) -> Int? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name, let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.pointee.ifa_data else { continue }
            return Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
        }
        return nil
    }

    private func now() -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            edt.send = { [weak self] bytes in
                self?.connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
            }
            edt.log = { [weak self] in self?.log($0) }
            edt.deliver = { [weak self] bytes in self?.deliver(Data(bytes)) }
            edt.onState = { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected:
                    self.isConnected = true
                    finish(.success(()))
                case .closed(let why):
                    finish(.failure(Failure.handshake(why)))
                    self.fail(Failure.closed(why))
                default: break
                }
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveLoop()
                    self.startTimer()
                    // Offer the route's interface MTU (at most 1500), so the VDA's packets fit our first hop (D135).
                    let name = self.connection.currentPath?.availableInterfaces.first?.name
                    let mtu = name.flatMap(Self.interfaceMTU)
                    let overhead = self.dtlsServerName == nil ? 0 : Self.dtlsOverhead
                    let offer = min(1500, mtu ?? Int(self.edt.config.maxPacketSize)) - overhead
                    self.log("EDT: route via \(name ?? "?") (MTU \(mtu.map(String.init) ?? "?"))\(overhead > 0 ? ", DTLS \(self.dtlsServerName!)" : ""): offering packet size \(offer)")
                    self.edt.connect(now: self.now(), maxPacketSize: offer)
                case .failed(let error):
                    finish(.failure(Failure.handshake("\(error)")))
                    self.fail(Failure.closed("\(error)"))
                case .waiting(let error):
                    finish(.failure(Failure.handshake("waiting: \(error)")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !resumed else { return }
                finish(.failure(Failure.handshake("no reply within \(Int(timeout)) s")))
                self?.stop()
            }
        }
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty { self.edt.receive([UInt8](data), now: self.now()) }
            if let error { return self.fail(Failure.closed("\(error)")) }
            self.receiveLoop()
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.edt.tick(now: self.now())
            if ContinuousClock.now - self.lastStats > .seconds(30) {
                self.lastStats = ContinuousClock.now
                self.log("EDT stats: \(self.edt.stats); rtt \(Int(self.edt.rtt * 1000)) ms, window \(Int(self.edt.window))")
            }
        }
        timer = t
        t.resume()
    }

    private func deliver(_ data: Data) {
        if let handler { handler(.success(data)) } else { pendingDeliveries.append(data) }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        log("EDT end: \(error); \(edt.stats)")
        handler?(.failure(error))
        connection.cancel()
    }

    private func stop() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        connection.cancel()
    }

    public func enqueue(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.edt.write([UInt8](data), now: self.now())
        }
    }

    public func startReceiving(_ handler: @escaping (Result<Data, Error>) -> Void) {
        self.handler = handler
        let early = pendingDeliveries
        pendingDeliveries = []
        early.forEach { handler(.success($0)) }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.edt.close(now: self.now(), reason: "closed by us")
            self.log("EDT closed by us; \(self.edt.stats)")
            self.stop()
        }
    }

    public func abort() { stop() }

    public func blackhole(for duration: TimeInterval) { log("EDT: blackhole test hook not supported") }
}
