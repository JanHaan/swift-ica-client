import Foundation

/// Monotonic time stamps shared by the pasteboard side (main thread) and the engine (session queue),
/// for the "host wins" ordering rule (docs/70 §5.5).
public enum ClipboardClock {
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// What the Mac side offers at one moment. `content` nil (or empty) means nothing we can carry, or a
/// concealed/transient item: the "empty" list is announced then (§5.4).
public struct ClipboardSnapshot: Sendable {
    public var content: ClipboardContent?
    public var takenAt: UInt64

    public init(content: ClipboardContent?, takenAt: UInt64 = ClipboardClock.now()) {
        self.content = content
        self.takenAt = takenAt
    }
}

/// Virtual channel engine for `CTXCLIP` (channel 17, docs/70-clipboard.md).
///
/// - Handshake (§5.1): CLIP_INIT → CLIP_INIT_REPLY; with version ≥ 2 FORMAT_NAMES → FORMAT_NAMES_REPLY;
///   then the "empty" FORMAT_LIST once, and the channel is READY.
/// - Host → Mac (§5.3): a host FORMAT_LIST starts an eager fetch, one DATA_REQUEST at a time (text,
///   "HTML Format", "Rich Text Format", and CF_BITMAP only without text), 5 s timeout each (§6 [P]);
///   when done, `.hostClipboard` carries everything at once.
/// - Mac → host (§5.4): `announceLocal` converts a snapshot and sends FORMAT_LIST; host requests are
///   served from that snapshot, anything else gets a failure response.
///
/// Call everything on the session queue. `onEvent` is called there too. Events never carry
/// clipboard contents except `.hostClipboard` (for the pasteboard); log `summary` only.
public final class ClipboardEngine: VirtualChannelEngine {
    public struct Config: Sendable {
        /// Fetch host data and deliver it (§5.7: off = never send DATA_REQUEST, still parse everything).
        public var hostToMac = true
        /// Offer Mac data (§5.7: off = only the "empty" list, every request fails).
        public var macToHost = true
        public var html = true
        public var rtf = true
        public var images = true
        /// Give up on one format after this long without a DATA_RESPONSE (§6 [P]).
        public var requestTimeout: TimeInterval = 5
        /// Host → Mac data above this is consumed and discarded; Mac → host data above it fails (§4.8).
        public var dataCap = 64 << 20
        /// No image with a longer side is announced or accepted (§4.8).
        public var maxImageSide = 16384
        /// Pace our output while the transport holds more unacknowledged bytes than this (see `backlog`).
        public var backlogLimit = 2 << 20
        /// Highest version we answer (docs/75 §4.1). 3 by default; 4 only for the discovery test
        /// (`ICA_CLIP_VERSION=4` in icactl), which also reads the host's DATA_REQUEST with a u32 index.
        public var maxVersion: UInt16 = ClipboardWire.maxClientVersion
        /// Discovery trace (test builds only, it shows payload bytes): `.trace` lines with every VC write
        /// both ways and every host message in hex (header + up to 64 payload bytes).
        public var traceWire = false
        /// Experimental file formats (docs/75 §6, §7): offer `ClipboardContent.files` as FileGroupDescriptorW +
        /// FileContents, and fetch host file groups (descriptor, then contents per index when
        /// `fetchFileContents`). Off by default.
        public var files = false
        /// At most this many file entries are fetched from the host (test cap).
        public var maxFileEntries = 16
        public init() {}
    }

    public enum Phase: Sendable { case uninit, awaitingNames, ready }

    public enum Event: CustomStringConvertible {
        case hostInit(lowVersion: UInt16, hostVersion: UInt16, version: UInt16)
        /// The host's registered formats (FORMAT_NAMES): ids and names, no data.
        case formatNames([ClipboardFormatName])
        case ready(version: UInt16)
        /// Host FORMAT_LIST after filtering (private formats dropped, at most 100).
        case hostFormats([UInt16])
        /// Host FORMAT_LIST "clipboard empty" (flags 0x000C), or "no list" without 0x0008 (`ignored`).
        case hostEmpty(flags: UInt16, ignored: Bool)
        case fetchStarted([UInt16])
        case fetched(format: UInt16, bytes: Int)
        case fetchFailed(format: UInt16, reason: String)
        /// Host data for the Mac pasteboard. `echo`: the host list came while our own announce was
        /// current and its text equals what we announced, so the Mac already holds it (§5.6).
        case hostClipboard(ClipboardContent, formats: [UInt16], echo: Bool)
        /// The host list has nothing we convert (or every fetch failed).
        case hostNothingUsable([UInt16])
        /// Our FORMAT_LIST went out (empty = the "empty" form).
        case announced([UInt16])
        case localDropped(reason: String)
        case localDeferred
        case hostRequest(format: UInt16, served: Bool, bytes: Int)
        case unsolicitedResponse(format: UInt16?, bytes: Int)
        /// A response (or failure) for a request that was cancelled or timed out: discarded.
        case lateResponse(format: UInt16?, bytes: Int, requested: UInt16)
        /// Zero bytes skipped where a command should start (see `ClipboardHostMessage.padding`).
        case padding(bytes: Int, after: String)
        /// Unknown command or untrustworthy layout: buffered bytes dropped, host list cleared (§2.1 [P]).
        case protocolError(String)
        /// Every field of a host DATA_REQUEST for a file format (discovery, docs/75 §10 E2).
        case hostFileRequest(format: UInt16, flags: UInt16, index: UInt32?, served: Bool, bytes: Int, detail: String)
        /// The host's FILEGROUPDESCRIPTORW (names and sizes, no contents).
        case hostFileGroup([ClipboardFileEntry])
        /// FileContents for one index (test only: the data is for comparison, never logged).
        case hostFileContents(index: UInt32, name: String?, data: Data)
        /// Discovery trace line (`Config.traceWire`); may contain payload bytes of test data.
        case trace(String)

        public var description: String {
            func list(_ ids: [UInt16]) -> String { ids.isEmpty ? "(none)" : ids.map { ClipboardFormat.label($0) }.joined(separator: ", ") }
            switch self {
            case .hostInit(let low, let v, let n): return String(format: "← CLIP_INIT host versions %d…%d → CLIP_INIT_REPLY version %d", low, v, n)
            case .formatNames(let e): return "← FORMAT_NAMES \(e.count) entries → FORMAT_NAMES_REPLY: " + e.map { String(format: "0x%04X \"%@\" (%ld B)", $0.id, $0.name, $0.raw.count) }.joined(separator: ", ")
            case .ready(let v): return "ready (version \(v)); → FORMAT_LIST empty"
            case .hostFormats(let ids): return "← FORMAT_LIST \(list(ids))"
            case .hostEmpty(let flags, let ignored): return String(format: "← FORMAT_LIST no entries, flags 0x%04x%@", flags, ignored ? " (ignored)" : " (host clipboard empty)")
            case .fetchStarted(let ids): return "fetching \(list(ids))"
            case .fetched(let f, let n): return "← DATA_RESPONSE \(ClipboardFormat.label(f)) \(n) B"
            case .fetchFailed(let f, let why): return "fetch of \(ClipboardFormat.label(f)) failed: \(why)"
            case .hostClipboard(let c, let ids, let echo): return "host clipboard ready (\(list(ids))): \(c.summary)\(echo ? " [echo of our announce]" : "")"
            case .hostNothingUsable(let ids): return "host clipboard has nothing we convert (\(list(ids)))"
            case .announced(let ids): return "→ FORMAT_LIST \(ids.isEmpty ? "empty" : list(ids))"
            case .localDropped(let why): return "local announce dropped: \(why)"
            case .localDeferred: return "local announce deferred until the host fetch ends"
            case .hostRequest(let f, let ok, let n): return "← DATA_REQUEST \(ClipboardFormat.label(f)) → " + (ok ? "DATA_RESPONSE \(n) B" : "failure")
            case .unsolicitedResponse(let f, let n): return "← unsolicited DATA_RESPONSE \(f.map { ClipboardFormat.label($0) } ?? "failure") \(n) B (discarded)"
            case .lateResponse(let f, let n, let r): return "← late DATA_RESPONSE \(f.map { ClipboardFormat.label($0) } ?? "failure") \(n) B for an earlier request of \(ClipboardFormat.label(r)) (discarded)"
            case .padding(let n, let after): return "skipped \(n) zero bytes after [\(after)]"
            case .protocolError(let why): return "protocol error: \(why)"
            case .hostFileRequest(let f, let flags, let index, let ok, let n, let detail):
                return String(format: "← DATA_REQUEST %@ flags 0x%04x index %@ → %@%@", ClipboardFormat.label(f), flags,
                              index.map { String($0) } ?? "-", ok ? "DATA_RESPONSE \(n) B" : "failure", detail.isEmpty ? "" : " (\(detail))")
            case .hostFileGroup(let entries):
                return "← FileGroupDescriptorW \(entries.count) entries: " + entries.map {
                    "\"\($0.name)\" \($0.isDirectory ? "dir" : "\($0.size) B") attrs 0x\(String($0.attributes, radix: 16)) flags 0x\(String($0.flags, radix: 16))"
                }.joined(separator: ", ")
            case .hostFileContents(let i, let name, let data): return "← FileContents index \(i) \(name.map { "\"\($0)\"" } ?? "?"): \(data.count) B"
            case .trace(let line): return "trace " + line
            }
        }
    }

    public let channelName = ClipboardWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((Event) -> Void)?
    /// Runs a block on the engine's queue after a delay (timeouts, output pacing). The session sets it;
    /// without it nothing times out.
    public var scheduleAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    /// Unacknowledged bytes in the transport (CGP retransmit queue). Big responses are paced so the
    /// queue stays under `backlogLimit` (the CGP queue gives up SR above 8 MiB).
    public var backlog: (() -> Int)?
    public var now: () -> UInt64 = ClipboardClock.now

    public let config: Config
    public private(set) var phase = Phase.uninit
    public private(set) var version: UInt16 = 0
    /// Host list in force (after filtering).
    public private(set) var hostFormats: [UInt16] = []
    /// Registered id → name (trailing NULs removed), in the host's order.
    public private(set) var formatNames: [(id: UInt16, name: String)] = []
    /// What we announced last (empty = "empty" form or nothing).
    public private(set) var localFormats: [UInt16] = []
    public var isFetching: Bool { fetching }
    public var pendingRequest: UInt16? { pending?.format }

    private var parser: ClipboardStreamParser
    /// One of our DATA_REQUESTs: a format, and at version 4 the index (FileContents: the file).
    private struct Request: Equatable { var format: UInt16; var index: UInt32? }
    private var pending: (format: UInt16, token: Int)?
    private var pendingIndex: UInt32?
    /// Every DATA_REQUEST we sent that has no response yet, oldest first. The current `pending` request is
    /// the last one; older entries were cancelled or timed out, and their late responses are discarded
    /// (a failure response has no format, so it can only be matched by order).
    private var outstanding: [(format: UInt16, token: Int, sentAt: UInt64)] = []
    /// When the pending request's timeout was (re-)armed, and when host bytes last arrived.
    private var armedAt: UInt64 = 0
    private var lastInboundAt: UInt64 = 0
    private var token = 0
    private var fetching = false
    private var fetchQueue: [Request] = []
    /// The host's file group of the current fetch (FileContents results are matched to it by index).
    private var hostFileEntries: [ClipboardFileEntry] = []
    /// Fetch FileContents after the descriptor (`Config.files`); off = descriptor only (e.g. to check a selection).
    public var fetchFileContents = true
    private var fetched = ClipboardContent()
    private var fetchedFormats: [UInt16] = []
    private var echoCandidate = false
    private var hostListAt: UInt64 = 0
    private var hostListSeen = false

    private enum LocalData { case bytes(Data), image(ClipboardImage) }
    private var localData: [UInt16: LocalData] = [:]
    private var localFiles: [ClipboardLocalFile] = []
    private var localText: String?
    private var localOwns = false
    private var lastAnnouncedEmpty = false
    private var deferred: ClipboardSnapshot?
    private var beforeReady: ClipboardSnapshot?

    /// Whole messages not started yet. `data` messages (DATA_RESPONSE) are paced and keep their order;
    /// `control` messages go ahead of data messages that have not started. A message already in
    /// progress is never interrupted: the stream has no framing.
    private enum OutKind { case control, data }
    private var outQueue: [(kind: OutKind, message: Data)] = []
    private var current: (kind: OutKind, message: Data, offset: Int)?
    private var pumpScheduled = false

    public init(config: Config = Config()) {
        self.config = config
        parser = ClipboardStreamParser(dataCap: config.dataCap)
        parser.maxVersion = max(1, config.maxVersion)
        parser.keepRaw = config.traceWire
    }

    public func registeredId(_ name: String) -> UInt16? { formatNames.first { $0.name == name }?.id }

    public func label(_ id: UInt16) -> String {
        ClipboardFormat.label(id, names: Dictionary(formatNames.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }

    private func emit(_ event: Event) { onEvent?(event) }

    // MARK: Output (1020-byte writes, paced)

    private func write(_ message: Data, _ kind: OutKind = .control) {
        if kind == .control, let index = outQueue.firstIndex(where: { $0.kind == .data }) {
            outQueue.insert((kind, message), at: index)
        } else {
            outQueue.append((kind, message))
        }
        pump()
    }

    private var backlogHigh: Bool {
        guard let backlog, scheduleAfter != nil else { return false }
        return backlog() > config.backlogLimit
    }

    /// Sends 1020-byte writes; data messages wait while the transport backlog is high.
    private func pump() {
        while true {
            if current == nil {
                guard let next = outQueue.first else { return }
                if next.kind == .data, backlogHigh { return schedulePump() }
                outQueue.removeFirst()
                current = (next.kind, next.message, next.message.startIndex)
            } else if current!.kind == .data, backlogHigh {
                return schedulePump()
            }
            let (kind, message, offset) = current!
            let end = min(message.endIndex, offset + ClipboardWire.writeSplit)
            current = end < message.endIndex ? (kind, message, end) : nil
            let chunk = message.subdata(in: offset..<end)
            if config.traceWire { emit(.trace("→ VC \(chunk.count) B: " + Self.hex(chunk.prefix(96)) + (chunk.count > 96 ? " …" : ""))) }
            output?(.channel(chunk))
        }
    }

    private func schedulePump() {
        guard !pumpScheduled, let scheduleAfter else { return }
        pumpScheduled = true
        scheduleAfter(0.05) { [weak self] in
            self?.pumpScheduled = false
            self?.pump()
        }
    }

    // MARK: Receive

    public func receive(_ data: Data) {
        lastInboundAt = now()
        if config.traceWire { emit(.trace("← VC \(data.count) B: " + Self.hex(data.prefix(96)) + (data.count > 96 ? " …" : ""))) }
        let messages = parser.feed(data)
        let raw = parser.raw
        for (i, message) in messages.enumerated() {
            if config.traceWire, i < raw.count { emit(.trace("← msg \(Self.hex(raw[i]))")) }
            handle(message)
        }
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

    private func handle(_ message: ClipboardHostMessage) {
        switch message {
        case .initRequest(let lowVersion, let hostVersion):
            version = min(max(1, config.maxVersion), hostVersion)
            cancelFetch()
            outstanding = []
            formatNames = []
            hostFormats = []
            hostListSeen = false
            lastAnnouncedEmpty = false
            localOwns = false
            localFormats = []
            localData = [:]
            phase = .uninit
            write(ClipboardWire.initReply(version: version))
            emit(.hostInit(lowVersion: lowVersion, hostVersion: hostVersion, version: version))
            if version < ClipboardWire.namesVersion { becomeReady() } else { phase = .awaitingNames }
        case .formatNames(_, let entries):
            // The id → name map holds registered ids only (§3.2.3); the reply echoes every id.
            for entry in entries where ClipboardWire.registeredRange.contains(entry.id) {
                if let index = formatNames.firstIndex(where: { $0.id == entry.id }) { formatNames[index].name = entry.name }
                else { formatNames.append((entry.id, entry.name)) }
            }
            write(ClipboardWire.formatNamesReply(ids: entries.map(\.id)))
            emit(.formatNames(entries))
            if phase == .awaitingNames { becomeReady() }
        case .formatList(let flags, let formats):
            hostList(flags: flags, formats: formats)
        case .dataRequest(let flags, let format, let index):
            serve(format, flags: flags, index: index)
        case .dataResponse(let format, let length, let data):
            response(format: format, length: length, data: data)
        case .dataFailure:
            guard let entry = takeOutstanding(format: nil) else { return emit(.unsolicitedResponse(format: nil, bytes: 0)) }
            guard let p = pending, p.token == entry.token else {
                return emit(.lateResponse(format: nil, bytes: 0, requested: entry.format))
            }
            pending = nil
            emit(.fetchFailed(format: p.format, reason: "host sent a failure response"))
            requestNext()
        case .unknown(let command, let flags, let head, let previous):
            lostSync(String(format: "unknown command 0x%04x, flags %@, bytes [%@], after [%@]", command,
                            flags.map { String(format: "0x%04x", $0) } ?? "-", Self.hex(head), Self.hex(previous)))
        case .malformed(let command, let flags, let reason, let head, let previous):
            lostSync(String(format: "command 0x%04x flags 0x%04x: %@, bytes [%@], after [%@]", command, flags, reason,
                            Self.hex(head), Self.hex(previous)))
        case .padding(let bytes, let previous):
            emit(.padding(bytes: bytes, after: Self.hex(previous)))
        }
    }

    private func lostSync(_ why: String) {
        parser.reset()
        cancelFetch()
        outstanding = []
        hostFormats = []
        emit(.protocolError(why + "; buffered bytes dropped, host list cleared"))
    }

    private func becomeReady() {
        phase = .ready
        announceEmpty()
        emit(.ready(version: version))
        if let snapshot = beforeReady {
            beforeReady = nil
            announceLocal(snapshot)
        }
        if !hostFormats.isEmpty, !localOwns { startFetch() }
    }

    // MARK: Host → Mac (§5.3)

    private func hostList(flags: UInt16, formats: [UInt16]) {
        if flags & ClipboardWire.flagNone != 0, flags & ClipboardWire.flagEmpty == 0 {
            // 0x0004 without 0x0008: the reference does nothing (§3.2.5).
            return emit(.hostEmpty(flags: flags, ignored: true))
        }
        lastAnnouncedEmpty = false
        echoCandidate = localOwns && !localFormats.isEmpty
        localOwns = false
        cancelFetch()
        hostListAt = now()
        hostListSeen = true
        if deferred != nil {
            // Taken before this list: the host wins (§5.5).
            deferred = nil
            emit(.localDropped(reason: "a newer host list arrived"))
        }
        if flags & ClipboardWire.flagNone != 0 {
            hostFormats = []
            return emit(.hostEmpty(flags: flags, ignored: false))
        }
        var list = formats.filter { $0 != 0 && !ClipboardWire.privateRange.contains($0) }
        if list.count > ClipboardWire.hostListCapacity { list = Array(list.prefix(ClipboardWire.hostListCapacity)) }
        hostFormats = list
        emit(.hostFormats(list))
        if phase == .ready { startFetch() }
    }

    private func cancelFetch() {
        pending = nil
        token += 1
        fetching = false
        fetchQueue = []
        fetched = ClipboardContent()
        fetchedFormats = []
        hostFileEntries = []
    }

    private func startFetch() {
        guard config.hostToMac, !hostFormats.isEmpty else { return }
        var want: [UInt16] = []
        if hostFormats.contains(ClipboardFormat.unicodeText) { want.append(ClipboardFormat.unicodeText) }
        if config.html, let id = registeredId(ClipboardFormat.htmlName), hostFormats.contains(id) { want.append(id) }
        if config.rtf, let id = registeredId(ClipboardFormat.rtfName), hostFormats.contains(id) { want.append(id) }
        // Images only without text: Office copies offer both and the bitmap can be huge (§4.5, §5.3 [P]).
        if config.images, hostFormats.contains(ClipboardFormat.bitmap), !hostFormats.contains(ClipboardFormat.unicodeText) {
            want.append(ClipboardFormat.bitmap)
        }
        // Files (experimental): the descriptor first; FileContents per index are queued once it is parsed.
        if config.files, let id = registeredId(ClipboardFileFormat.groupDescriptorName), hostFormats.contains(id) { want.append(id) }
        guard !want.isEmpty else { return emit(.hostNothingUsable(hostFormats)) }
        fetching = true
        fetchQueue = want.map { Request(format: $0, index: version >= ClipboardWire.filesVersion ? 0 : nil) }
        fetched = ClipboardContent()
        fetchedFormats = []
        emit(.fetchStarted(want))
        requestNext()
    }

    private func requestNext() {
        guard fetching else { return }
        guard !fetchQueue.isEmpty else { return finishFetch() }
        let request = fetchQueue.removeFirst()
        let format = request.format
        token += 1
        let current = token
        pending = (format, current)
        pendingIndex = request.index
        outstanding.append((format, current, now()))
        write(ClipboardWire.dataRequest(format: format, index: request.index))
        armTimeout(current)
    }

    private func armTimeout(_ which: Int) {
        armedAt = now()
        scheduleAfter?(config.requestTimeout) { [weak self] in self?.requestTimedOut(which) }
    }

    private func requestTimedOut(_ which: Int) {
        guard let p = pending, p.token == which else { return }
        if parser.inPayload, lastInboundAt > armedAt {
            // A response is still arriving: wait as long as bytes keep flowing.
            return armTimeout(which)
        }
        pending = nil  // stays in `outstanding`: a late answer is discarded
        emit(.fetchFailed(format: p.format, reason: "no response within \(Int(config.requestTimeout)) s"))
        requestNext()
    }

    /// The request a response answers. Responses come in request order; for a success the format also
    /// tells, so older requests of another format were never answered and are dropped. Entries older than
    /// three timeouts are forgotten (the host will not answer them any more).
    private func takeOutstanding(format: UInt16?) -> (format: UInt16, token: Int, sentAt: UInt64)? {
        let limit = UInt64(3 * config.requestTimeout * 1_000_000_000)
        let t = now()
        outstanding.removeAll { $0.token != pending?.token && t > $0.sentAt && t - $0.sentAt > limit }
        if let format {
            guard let index = outstanding.firstIndex(where: { $0.format == format }) else { return nil }
            let entry = outstanding[index]
            outstanding.removeFirst(index + 1)
            return entry
        }
        return outstanding.isEmpty ? nil : outstanding.removeFirst()
    }

    private func response(format: UInt16, length: Int, data: Data?) {
        let entry = takeOutstanding(format: format)
        if let entry, entry.token != pending?.token {
            // For a cancelled or timed-out request: discarded; the pending request keeps waiting.
            return emit(.lateResponse(format: format, bytes: length, requested: entry.format))
        }
        guard let p = pending, p.format == format, entry != nil else {
            // Unsolicited: no request of ours for this format. A request still pending for another format
            // keeps waiting ([P]: the reference goes IDLE).
            emit(.unsolicitedResponse(format: format, bytes: length))
            if pending == nil, !fetching, localOwns, !localFormats.isEmpty {
                // We own the clipboard: re-assert our list (§5.3 step 5).
                write(ClipboardWire.formatList(localFormats))
                emit(.announced(localFormats))
            }
            return
        }
        pending = nil
        if let data {
            emit(.fetched(format: format, bytes: data.count))
            store(format: format, index: pendingIndex, data: data)
        } else {
            emit(.fetchFailed(format: format, reason: "\(length) B is over the \(config.dataCap) B cap (discarded)"))
        }
        requestNext()
    }

    private func store(format: UInt16, index: UInt32?, data: Data) {
        switch format {
        case registeredId(ClipboardFileFormat.groupDescriptorName) where config.files:
            let entries: [ClipboardFileEntry]
            do { entries = try ClipboardFileGroup.parse(data, maxEntries: 1000) } catch {
                return emit(.fetchFailed(format: format, reason: "FILEGROUPDESCRIPTORW not usable: \(error)"))
            }
            hostFileEntries = entries
            emit(.hostFileGroup(entries))
            guard fetchFileContents, let contents = registeredId(ClipboardFileFormat.contentsName), hostFormats.contains(contents) else { return }
            // One request per file (directories have no contents), by zero-based index (docs/75 §5).
            for (i, e) in entries.enumerated().prefix(config.maxFileEntries) where !e.isDirectory && e.size <= UInt64(config.dataCap) {
                fetchQueue.append(Request(format: contents, index: UInt32(i)))
            }
            return
        case registeredId(ClipboardFileFormat.contentsName) where config.files:
            let i = index ?? 0
            let name = Int(i) < hostFileEntries.count ? hostFileEntries[Int(i)].name : nil
            return emit(.hostFileContents(index: i, name: name, data: data))
        case ClipboardFormat.unicodeText:
            fetched.text = ClipboardText.decodeHost(data)
        case ClipboardFormat.bitmap:
            do { fetched.image = try ClipboardDIB.decode(data, maxSide: config.maxImageSide) } catch {
                return emit(.fetchFailed(format: format, reason: "DIB not usable: \(error)"))
            }
        case registeredId(ClipboardFormat.htmlName):
            guard let fragment = ClipboardHTML.fragment(data) else {
                return emit(.fetchFailed(format: format, reason: "no HTML in the data"))
            }
            fetched.html = ClipboardHTML.macDocument(fragment: fragment)
        case registeredId(ClipboardFormat.rtfName):
            fetched.rtf = ClipboardRTF.decodeHost(data)
        default:
            return
        }
        fetchedFormats.append(format)
    }

    private func finishFetch() {
        fetching = false
        let content = fetched
        let formats = fetchedFormats
        fetched = ClipboardContent()
        fetchedFormats = []
        if content.isEmpty {
            emit(.hostNothingUsable(hostFormats))
        } else if let d = deferred, d.takenAt > hostListAt {
            // The Mac changed after this host list: the Mac copy wins and is announced below (§5.5 [P]).
            emit(.localDropped(reason: "host data not delivered: the Mac clipboard changed during the fetch"))
        } else {
            let echo = echoCandidate && content.text != nil && content.text == localText
            emit(.hostClipboard(content, formats: formats, echo: echo))
        }
        if let d = deferred {
            deferred = nil
            announceLocal(d)
        }
    }

    // MARK: Mac → host (§5.4)

    /// A new Mac clipboard snapshot. Before READY it waits for READY; a snapshot older than the latest
    /// host list is dropped (the host wins); during a host fetch it is deferred until the fetch ends.
    public func announceLocal(_ snapshot: ClipboardSnapshot) {
        guard phase == .ready else {
            beforeReady = snapshot
            return
        }
        if hostListSeen, snapshot.takenAt < hostListAt {
            return emit(.localDropped(reason: "snapshot older than the host's latest list"))
        }
        if fetching {
            deferred = snapshot
            return emit(.localDeferred)
        }
        sendLocal(snapshot.content)
    }

    private func sendLocal(_ content: ClipboardContent?) {
        guard config.macToHost, let content, !content.isEmpty else { return announceEmpty() }
        var formats: [UInt16] = []
        var data: [UInt16: LocalData] = [:]
        if let text = content.text, !text.isEmpty {
            formats.append(ClipboardFormat.unicodeText)
            data[ClipboardFormat.unicodeText] = .bytes(ClipboardText.encodeForHost(text))
        }
        // Registered formats only under the id the host gave the name (§3.2.5).
        if config.html, let html = content.html, !html.isEmpty, let id = registeredId(ClipboardFormat.htmlName) {
            formats.append(id)
            data[id] = .bytes(ClipboardHTML.build(html))
        }
        if config.rtf, let rtf = content.rtf, !rtf.isEmpty, let id = registeredId(ClipboardFormat.rtfName) {
            formats.append(id)
            data[id] = .bytes(ClipboardRTF.encodeForHost(rtf))
        }
        if config.images, let image = content.image, image.width > 0, image.height > 0,
           image.width <= config.maxImageSide, image.height <= config.maxImageSide,
           52 + 4 * image.width * image.height <= config.dataCap {
            formats.append(ClipboardFormat.bitmap)
            data[ClipboardFormat.bitmap] = .image(image)
        }
        // Files (experimental): only under the ids the host gave both shell names (docs/75 §7.1).
        var files: [ClipboardLocalFile] = []
        if config.files, let list = content.files, !list.isEmpty,
           let group = registeredId(ClipboardFileFormat.groupDescriptorName), let contents = registeredId(ClipboardFileFormat.contentsName),
           let descriptor = try? ClipboardFileGroup.build(list.map(\.entry)) {
            formats += [group, contents]
            data[group] = .bytes(descriptor)
            files = list
        }
        guard !formats.isEmpty else { return announceEmpty() }
        localFormats = formats
        localData = data
        localFiles = files
        localText = content.text
        localOwns = true
        lastAnnouncedEmpty = false
        write(ClipboardWire.formatList(formats))
        emit(.announced(formats))
    }

    /// The "empty" FORMAT_LIST, sent once until a host list or a non-empty announce clears the flag (§5.1).
    private func announceEmpty() {
        localFormats = []
        localData = [:]
        localFiles = []
        localText = nil
        localOwns = false
        guard !lastAnnouncedEmpty else { return }
        lastAnnouncedEmpty = true
        write(ClipboardWire.emptyFormatList)
        emit(.announced([]))
    }

    private func serve(_ format: UInt16, flags: UInt16 = 0, index: UInt32? = nil) {
        if config.files, let contents = registeredId(ClipboardFileFormat.contentsName), format == contents {
            return serveFile(format: format, flags: flags, index: index)
        }
        if config.files, let group = registeredId(ClipboardFileFormat.groupDescriptorName), format == group {
            let data = localFormats.contains(format) ? resolve(format) : nil
            if let data { write(ClipboardWire.dataResponse(format: format, data: data), .data) } else { write(ClipboardWire.dataFailure, .data) }
            return emit(.hostFileRequest(format: format, flags: flags, index: index, served: data != nil, bytes: data?.count ?? 0,
                                         detail: "\(localFiles.count) entries"))
        }
        guard config.macToHost, localFormats.contains(format), let data = resolve(format), data.count <= config.dataCap else {
            write(ClipboardWire.dataFailure, .data)
            return emit(.hostRequest(format: format, served: false, bytes: 0))
        }
        write(ClipboardWire.dataResponse(format: format, data: data), .data)
        emit(.hostRequest(format: format, served: true, bytes: data.count))
    }

    /// FileContents: the whole file of entry `index` (whole-file hypothesis; ranges unknown, docs/75 §4.3). Without
    /// an index (version ≤ 3) entry 0 is served and that is logged.
    private func serveFile(format: UInt16, flags: UInt16, index: UInt32?) {
        let i = Int(index ?? 0)
        var detail = index == nil ? "no index at version \(version): entry 0" : ""
        guard config.macToHost, localFormats.contains(format), i < localFiles.count else {
            write(ClipboardWire.dataFailure, .data)
            if detail.isEmpty { detail = i >= localFiles.count ? "index out of range (\(localFiles.count) files)" : "no files announced" }
            return emit(.hostFileRequest(format: format, flags: flags, index: index, served: false, bytes: 0, detail: detail))
        }
        let file = localFiles[i]
        guard !file.entry.isDirectory, file.entry.size <= UInt64(config.dataCap), let data = file.read() else {
            write(ClipboardWire.dataFailure, .data)
            return emit(.hostFileRequest(format: format, flags: flags, index: index, served: false, bytes: 0, detail: "entry \(i) not readable"))
        }
        write(ClipboardWire.dataResponse(format: format, data: data), .data)
        let name = "\"\(file.entry.name)\""
        emit(.hostFileRequest(format: format, flags: flags, index: index, served: true, bytes: data.count, detail: detail.isEmpty ? name : detail + ", " + name))
    }

    /// Snapshot data for a format; an image is converted on its first request and kept.
    private func resolve(_ format: UInt16) -> Data? {
        switch localData[format] {
        case .bytes(let data): return data
        case .image(let image):
            guard let rgba = image.rgba(), let dib = ClipboardDIB.encode(width: image.width, height: image.height, rgba: rgba) else { return nil }
            localData[format] = .bytes(dib)
            return dib
        case nil: return nil
        }
    }
}
