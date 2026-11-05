import Foundation
import Network

/// A TCP+TLS byte stream with async send/receive (Network.framework, system trust store).
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
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
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
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.onSendError?(Failure.failed("\(error)")) }
        })
    }

    public var onSendError: ((Error) -> Void)?

    /// Receives continuously; `handler` runs on `queue` for every chunk, and once with a failure at the end.
    public func startReceiving(_ handler: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { handler(.success(data)) }
            if let error { handler(.failure(Failure.failed("\(error)"))); return }
            if isComplete { handler(.failure(Failure.closed)); return }
            self?.startReceiving(handler)
        }
    }

    public func close() { connection.cancel() }
}
