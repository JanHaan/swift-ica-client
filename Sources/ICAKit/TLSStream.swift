import Foundation
import Network

/// A TCP+TLS byte stream with async send/receive (Network.framework, system trust store). One
/// instance per connection; a resumed CGP session opens a new one (docs/20 §3.12.4).
public final class TLSStream: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case closed
        case failed(String)

        public var description: String {
            switch self {
            case .closed: "connection closed by peer"
            case .failed(let text): "connection failed: \(text)"
            }
        }
    }

    private let connection: NWConnection
    /// The queue all connection callbacks (and `startReceiving` handlers) run on.
    public let queue: DispatchQueue

    public init(host: String, port: UInt16, tls: Bool = true, queue: DispatchQueue = DispatchQueue(label: "ica.tls")) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    public func connect(timeout: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { [connection] result in
                guard !resumed else { return }
                resumed = true
                // A failed or timed-out attempt must not become ready later.
                if case .failure = result { connection.cancel() }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(Failure.failed("\(error)")))
                case .waiting(let error): finish(.failure(Failure.failed("waiting: \(error)")))
                case .cancelled: finish(.failure(Failure.closed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(Failure.failed("timeout"))) }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Failure.failed("\(error)")) } else { continuation.resume() }
            })
        }
    }

    /// Next chunk of received bytes; throws `.closed` at end of stream.
    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: Failure.failed("\(error)")) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(throwing: Failure.closed) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    /// Fire-and-forget send; writes keep their call order. Errors go to `onSendError`.
    public func enqueue(_ data: Data) {
        if holdUntil != nil { held.append(data); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.onSendError?(Failure.failed("\(error)")) }
        })
    }

    public var onSendError: ((Error) -> Void)?

    /// Receives continuously; `handler` runs on `queue` for every chunk, and once with a failure at the end.
    public func startReceiving(_ handler: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var results: [Result<Data, Error>] = []
            if let data, !data.isEmpty { results.append(.success(data)) }
            if let error { results.append(.failure(Failure.failed("\(error)"))) }
            else if isComplete { results.append(.failure(Failure.closed)) }
            let more = results.allSatisfy { if case .success = $0 { true } else { false } }
            if self.holdUntil != nil {
                // Blackhole: deliver nothing and read no further until it ends.
                self.heldIncoming += results
                self.resumeReceiving = more ? { [weak self] in self?.startReceiving(handler) } : nil
                self.heldHandler = handler
                return
            }
            results.forEach(handler)
            if more { self.startReceiving(handler) }
        }
    }

    /// Graceful cancel (TCP FIN after pending writes).
    public func close() { connection.cancel() }

    /// Abrupt cancel without waiting for pending writes (test hook `ICA_TEST_DROP_AFTER`).
    public func abort() { connection.forceCancel() }

    // MARK: Blackhole test hook (`ICA_TEST_BLACKHOLE_AFTER`)

    private var holdUntil: DispatchTime?
    private var held: [Data] = []
    private var heldIncoming: [Result<Data, Error>] = []
    private var heldHandler: ((Result<Data, Error>) -> Void)?
    private var resumeReceiving: (() -> Void)?

    /// For `duration` seconds neither read nor write: writes are held, received data is not delivered
    /// and no further reads are issued, as on a stalled path. Afterwards everything continues in order.
    /// Call on `queue`.
    public func blackhole(for duration: TimeInterval) {
        guard holdUntil == nil else { return }
        let end = DispatchTime.now() + duration
        holdUntil = end
        queue.asyncAfter(deadline: end) { [weak self] in
            guard let self else { return }
            self.holdUntil = nil
            let writes = self.held
            self.held = []
            writes.forEach(self.enqueue)
            let incoming = self.heldIncoming
            self.heldIncoming = []
            if let handler = self.heldHandler { incoming.forEach(handler) }
            let next = self.resumeReceiving
            self.resumeReceiving = nil
            next?()
        }
    }
}
