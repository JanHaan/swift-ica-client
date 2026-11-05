import Foundation

/// Virtual channel engine for client drive mapping, `CTXCDM ` (channel 10, docs/95-file-transfer.md §A).
///
/// - The module (§A.1) announces one drive with flow type 3 (62500/4116); the host is expected to send
///   CONNECT first and then file requests. The client sends no flow acknowledgements (§A.1).
/// - Requests are parsed on the session queue and served one at a time, strictly in order, by a
///   `CDMServer` on `ioQueue` (file I/O off the network thread, §A.2 [P]); each reply goes out before the
///   next request starts. While the transport holds more than `backlogLimit` unacknowledged bytes the
///   next request waits (big READ streams cannot pile up in the CGP queue).
/// - At most `maxQueuedRequests` requests or `maxQueuedBytes` of their data wait; a host that floods past
///   that (it should stay within its 62500-byte window) stops the channel like a protocol error.
/// - An unknown command loses the stream for good (no length fields): the engine logs it, stops
///   parsing and never answers again; requests parsed before it are still served (§A.8 step 2).
///
/// Call everything on the session queue; `onEvent` is called there. Events carry command names, sizes,
/// statuses and paths relative to the shared folder, never file contents.
public final class CDMEngine: VirtualChannelEngine, VirtualChannelModule {
    public struct Config {
        public var fileSystem: CDMFileSystem
        /// The drive letter announced (§A.1); the host may still map it to another letter (§A.6).
        public var letter: Character
        /// Volume label (VOLUME_INFO).
        public var label: String
        /// Pace requests while the transport holds more unacknowledged bytes than this.
        public var backlogLimit = 2 << 20

        public init(fileSystem: CDMFileSystem, letter: Character = "M", label: String = "Mac") {
            self.fileSystem = fileSystem
            self.letter = letter
            self.label = label
        }
    }

    public enum Event: CustomStringConvertible {
        /// One served request, as the server logs it (aggregated for READ/WRITE: see CLOSE).
        case operation(String)
        /// The stream was lost (unknown command): CDM stopped for this session.
        case protocolError(String)
        case stopped

        public var description: String {
            switch self {
            case .operation(let text): return text
            case .protocolError(let text): return "protocol error: \(text)"
            case .stopped: return "stopped"
            }
        }
    }

    public static let maxQueuedRequests = 4096
    public static let maxQueuedBytes = 8 << 20

    public let channelName = CDMWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((Event) -> Void)?
    /// Serial queue for file I/O. Nil: requests are served inline (tests).
    public var ioQueue: DispatchQueue?
    /// Brings a block back onto the session queue (from `ioQueue`). Required with `ioQueue`.
    public var schedule: ((@escaping () -> Void) -> Void)?
    /// Runs a block on the session queue after a delay (pacing). Without it, no pacing.
    public var scheduleAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    /// Unacknowledged bytes in the transport (CGP retransmit queue).
    public var backlog: (() -> Int)?

    public let config: Config
    /// Why the channel stopped (unknown command, or session end); nil while it runs.
    public private(set) var stopReason: String?
    public private(set) var requestsServed = 0
    /// Requests parsed but not served yet.
    public var queuedCount: Int { queue.count - head }
    public private(set) var queuedBytes = 0

    private let server: CDMServer
    private var parser = CDMStreamParser()
    private var queue: [CDMRequest] = []
    /// First unserved request in `queue` (no O(n) removeFirst).
    private var head = 0
    private var busy = false
    private var ended = false

    public init(config: Config) {
        self.config = config
        server = CDMServer(fileSystem: config.fileSystem, letter: config.letter, label: config.label)
    }

    /// The server, for tests and diagnostics. Touch it only on `ioQueue` (or inline without one).
    public var serverForTesting: CDMServer { server }

    /// The CTXCDM module (§A.1): one fixed drive.
    public func module(channel: UInt8, date: Date) -> [UInt8] {
        WDModules.cdm(drives: [(config.letter, false)], channel: channel, date: date)
    }

    public func receive(_ data: Data) {
        guard stopReason == nil else { return }
        for item in parser.feed(data) {
            switch item {
            case .request(let request):
                guard stopReason == nil else { break }
                queue.append(request)
                queuedBytes += request.body.dataSize
                if queuedCount > Self.maxQueuedRequests || queuedBytes > Self.maxQueuedBytes {
                    let text = "host flooded the channel (\(queuedCount) requests, \(queuedBytes) B queued); CDM stops"
                    stopReason = text
                    clearQueue()
                    onEvent?(.protocolError(text))
                }
            case let .fatal(command, head):
                let text = "unknown command \(CDMWire.unknownName(command)); the stream cannot be resynchronised, CDM stops "
                    + "(head \(head.map { String(format: "%02x", $0) }.joined(separator: " ")))"
                stopReason = text
                onEvent?(.protocolError(text))
            }
        }
        pump()
    }

    /// Session end: drops queued requests and closes every handle.
    public func shutdown() {
        guard !ended else { return }
        ended = true
        if stopReason == nil { stopReason = "session ended" }
        clearQueue()
        let server = self.server
        if let ioQueue { ioQueue.async { server.closeAll() } } else { server.closeAll() }
        onEvent?(.stopped)
    }

    private func clearQueue() {
        queue.removeAll()
        head = 0
        queuedBytes = 0
    }

    private func dequeue() -> CDMRequest {
        let request = queue[head]
        head += 1
        queuedBytes -= request.body.dataSize
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 1024, head * 2 >= queue.count {
            queue.removeFirst(head)
            head = 0
        }
        return request
    }

    private func pump() {
        while !busy, queuedCount > 0 {
            if let backlog, let scheduleAfter, backlog() > config.backlogLimit {
                busy = true
                scheduleAfter(0.05) { [weak self] in
                    guard let self else { return }
                    self.busy = false
                    self.pump()
                }
                return
            }
            let request = dequeue()
            if let ioQueue, let schedule {
                busy = true
                let server = self.server
                ioQueue.async { [weak self] in
                    let result = server.handle(request)
                    schedule {
                        guard let self else { return }
                        self.busy = false
                        self.finish(result)
                        self.pump()
                    }
                }
                return
            }
            finish(server.handle(request))
        }
    }

    private func finish(_ result: CDMServer.Result) {
        requestsServed += 1
        for line in result.log { onEvent?(.operation(line)) }
        // A reply after shutdown would answer for a session that is gone.
        guard let reply = result.reply, !ended else { return }
        output?(.channel(reply.encode()))
    }
}

extension CDMRequestBody {
    /// Variable-length bytes the request carries (paths, WRITE data), for the queue bound.
    var dataSize: Int {
        switch self {
        case let .create(path, _, _, _, _, _), let .open(path, _), let .findFirst(path, _, _), let .getAttributes(path),
             let .setAttributes(path, _), let .delete(path), let .createDirectory(path, _, _, _, _), let .deleteDirectory(path),
             let .volumeInfo(path, _), let .findFirstIndex(path, _, _, _):
            return 16 + path.count
        case let .write(_, _, data): return 16 + data.count
        case let .rename(from, to): return 16 + from.count + to.count
        default: return 16
        }
    }
}
