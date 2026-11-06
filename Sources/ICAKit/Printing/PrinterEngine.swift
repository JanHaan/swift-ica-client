import Foundation

/// A finished print job: the PDF the host's universal print driver rendered (docs/97 §3.9, §5). The
/// data is the joined WRITE payloads of one OPEN … CLOSE; it is not checked here (see `PrintDocument`).
public struct PrintJob: Sendable {
    /// Per session, from 1.
    public var id: Int
    public var data: Data
    /// The printer name the host sent in OPEN (e.g. the session's PDF printer), terminator dropped.
    public var printerName: String
    public var writes: Int
}

/// Virtual channel engine for client printing, `CTXCPM ` (channel 4, docs/97-printing.md), PDF mode
/// (§6.1 phase 1): no client printers are announced; jobs for the host's *Citrix PDF Printer* arrive as
/// PDF in WRITE chunks between OPEN and CLOSE on context 1.
///
/// - The module (§1.2) is 56 bytes with flow type 1 (ACK, 62500/4102) and capability flags 0x8000.
/// - The host speaks first; every client packet is a reply (§1.3). After each completely parsed command
///   the engine sends the flow-control ACK `32 04 <u16 n>`, n = the command's byte length (§1.4), also
///   for commands without a reply and for unknown command bytes (n = 2, §3.10).
/// - Reference quirks handled (§3.4, §3.6, §7): WRITE to an unknown context consumes its data (the
///   reference does not and desyncs); GET_INFO on the PDF context answers with defaults (the reference
///   throws); several contexts are kept apart.
/// - A job larger than `Config.maxJobBytes` is dropped: further WRITEs are consumed and acknowledged,
///   CLOSE answers "no data" (0x0607) and `.jobRefused` reports it.
///
/// Call everything on the session queue; `onEvent` is called there. Events carry command names, tags,
/// sizes and the printer name, never job data or document names.
public final class PrinterEngine: VirtualChannelEngine, VirtualChannelModule {
    public struct Config: Sendable {
        /// Largest job kept (bytes); beyond it the job is refused.
        public var maxJobBytes = 256 << 20
        /// The devmode answered to GET_INFO (§3.6).
        public var devmode = PrinterDevmode()

        public init() {}
    }

    public enum Event: CustomStringConvertible {
        /// One handled host command, as a log line (WRITEs are summarised at CLOSE).
        case command(String)
        /// A finished job (CLOSE with data), after the CLOSE reply went out.
        case job(PrintJob)
        /// A job was dropped (too large, replaced by a new OPEN, or the session ended).
        case jobRefused(id: Int, reason: String)
        case stopped

        public var description: String {
            switch self {
            case .command(let text): return text
            case .job(let job): return "job \(job.id): \(job.data.count) B in \(job.writes) writes"
            case .jobRefused(let id, let reason): return "job \(id) dropped: \(reason)"
            case .stopped: return "stopped"
            }
        }
    }

    public let channelName = PrinterWire.channelName
    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((Event) -> Void)?
    public let config: Config

    /// Strings in OPEN/METAFILE: UTF-16LE after CONNECT2 version ≥ 5 (§3.1).
    public private(set) var encoding = PrinterWire.Encoding.ascii
    /// Commands parsed and acknowledged, and the sum of the ACK values.
    public private(set) var commandsHandled = 0
    public private(set) var bytesAcknowledged = 0
    public private(set) var jobsFinished = 0
    /// Command counts by name (UNKNOWN_xx for bytes without a handler).
    public private(set) var commandCounts: [String: Int] = [:]
    /// Printer and driver names the host sent (SET_METAFILE entry strings, OPEN names), terminators dropped.
    public private(set) var hostNames: [String] = []

    private var channel = PrinterWire.channelNumber
    private var parser = PrinterStreamParser()
    private var jobs: [UInt16: OpenJob] = [:]
    private var nextJobID = 1
    private var ended = false

    private struct OpenJob {
        var id: Int
        var printer: String
        var data = Data()
        var writes = 0
        var minWrite = Int.max
        var maxWrite = 0
        var untagged = 0
        /// Set once the job was dropped; later WRITEs are consumed without keeping data.
        var refused: String?
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The 56-byte PDF-mode module (§1.2). Also fixes the channel number for the ACKs.
    public func module(channel: UInt8, date: Date) -> [UInt8] {
        self.channel = channel
        return WDModules.printer(channel: channel, date: date)
    }

    public func receive(_ data: Data) {
        guard !ended else { return }
        for item in parser.feed(data) {
            handle(item.request)
            commandsHandled += 1
            bytesAcknowledged += item.length
            for ack in PrinterReply.acks(channel: channel, length: item.length) { output?(ack) }
        }
    }

    /// Session end: open jobs are discarded, nothing is sent any more.
    public func shutdown() {
        guard !ended else { return }
        ended = true
        for (_, job) in jobs.sorted(by: { $0.key < $1.key }) where job.refused == nil {
            onEvent?(.jobRefused(id: job.id, reason: "session ended before CLOSE (\(job.data.count) B received)"))
        }
        jobs.removeAll()
        parser.reset()
        onEvent?(.stopped)
    }

    /// Open job contexts (tests and diagnostics).
    public var openContexts: [UInt16] { jobs.keys.sorted() }

    // MARK: Commands

    private func reply(_ data: Data) { output?(.channel(data)) }

    private func log(_ text: String) { onEvent?(.command(text)) }

    private func count(_ name: String) { commandCounts[name, default: 0] += 1 }

    private func handle(_ request: PrinterRequest) {
        let tag = request.tag
        switch request.body {
        case let .connect2(a, b, version, flags):
            count("CONNECT2")
            encoding = version >= 5 ? .utf16 : .ascii
            log(String(format: "CONNECT2 tag %d: a 0x%04x b 0x%04x version %d flags 0x%04x → strings %@", tag, a, b, version, flags,
                       encoding == .utf16 ? "UTF-16" : "ASCII"))

        case .queryMetafile:
            count("QUERY_METAFILE")
            let data = PrinterReply.queryMetafile(tag: tag, encoding: encoding)
            reply(data)
            log("QUERY_METAFILE tag \(tag) → PDF (\(data.count) B reply)")

        case let .setMetafile(size, entries):
            count("SET_METAFILE")
            reply(PrinterReply.setMetafile(tag: tag))
            for e in entries {
                for part in [e.first, e.second] where !part.isEmpty { hostNames.append(Self.trimNULs(encoding.decode(part))) }
            }
            let list = entries.map { e in
                // Host printer and driver names can carry user or site names: lengths only.
                "\(Self.trimNULs(encoding.decode(e.first)).count)/\(Self.trimNULs(encoding.decode(e.second)).count) chars x \(e.unknown) flags \(e.flags)"
            }
            log("SET_METAFILE tag \(tag): size \(size), \(entries.count) entries [\(list.joined(separator: ", "))]")

        case let .enumPrinters(index, maxSize):
            count("ENUM")
            reply(PrinterReply.enumEmpty(tag: tag))
            log("ENUM tag \(tag): index \(index) max \(maxSize) → no client printers")

        case let .open(flags, name):
            count("OPEN")
            let printer = Self.dropTerminator(encoding.decode(name))
            hostNames.append(printer)
            guard flags & PrinterWire.openRequiredFlags == PrinterWire.openRequiredFlags else {
                reply(PrinterReply.open(tag: tag, result: PrinterWire.Result.accessDenied, context: 0xFFFF))
                log(String(format: "OPEN tag %d flags 0x%02x printer (%d chars) → refused (flags lack 0x11)", tag, flags, printer.count))
                return
            }
            let context = PrinterWire.pdfContext
            if let old = jobs[context], old.refused == nil {
                onEvent?(.jobRefused(id: old.id, reason: "a new OPEN replaced it before CLOSE (\(old.data.count) B received)"))
            }
            let id = startJob(context: context, printer: printer)
            reply(PrinterReply.open(tag: tag, result: PrinterWire.Result.success, context: context))
            log(String(format: "OPEN tag %d flags 0x%02x printer (%d chars, %d B name) → context %d, job %d", tag, flags, printer.count,
                       name.count, context, id))

        case let .getInfo(context, flags, size):
            count("GET_INFO")
            let ok = context == PrinterWire.pdfContext && flags == PrinterWire.getInfoFlags
            let result = ok ? PrinterWire.Result.success : PrinterWire.Result.invalidHandle
            reply(PrinterReply.getInfo(tag: tag, result: result, devmode: config.devmode))
            log(String(format: "GET_INFO tag %d: context %d flags 0x%x size %d → result 0x%04x, orientation %d paper %d",
                       tag, context, flags, size, result, config.devmode.orientation, config.devmode.paperSize))

        case let .write(context, data):
            count("WRITE")
            write(tag: tag, context: context, data: data)

        case let .close(context):
            count("CLOSE")
            close(tag: tag, context: context)

        case .unknown(let byte):
            count(String(format: "UNKNOWN_%02x", byte))
            log(String(format: "unknown command 0x%02x tag %d: header consumed, ACK 2", byte, tag))
        }
    }

    @discardableResult
    private func startJob(context: UInt16, printer: String) -> Int {
        let id = nextJobID
        nextJobID += 1
        jobs[context] = OpenJob(id: id, printer: printer)
        return id
    }

    private func write(tag: UInt8, context: UInt16, data: Data) {
        if jobs[context] == nil, context == PrinterWire.pdfContext {
            // The reference accepts context 1 without an OPEN (§3.4: "unknown context (and not 1)").
            let id = startJob(context: context, printer: "")
            log("WRITE tag \(tag) to context 1 without OPEN → job \(id)")
        }
        guard var job = jobs[context] else {
            // Unknown context: the data was consumed by the parser (the reference leaves it in the stream).
            if tag != 0 { reply(PrinterReply.write(tag: tag, result: PrinterWire.Result.writeUnknownContext, size: 0)) }
            log("WRITE tag \(tag) to unknown context \(context): \(data.count) B skipped → result 0xff0e")
            return
        }
        job.writes += 1
        job.minWrite = min(job.minWrite, data.count)
        job.maxWrite = max(job.maxWrite, data.count)
        if tag == 0 { job.untagged += 1 }
        if job.writes == 1 { log("WRITE tag \(tag) context \(context): first chunk \(data.count) B (job \(job.id))") }
        if job.refused == nil {
            if job.data.count + data.count > config.maxJobBytes {
                let reason = "larger than \(config.maxJobBytes >> 20) MiB"
                job.refused = reason
                job.data = Data()
                onEvent?(.jobRefused(id: job.id, reason: reason))
            } else {
                job.data.append(data)
            }
        }
        jobs[context] = job
        if tag != 0 { reply(PrinterReply.write(tag: tag, result: PrinterWire.Result.success, size: UInt16(data.count))) }
    }

    private func close(tag: UInt8, context: UInt16) {
        guard let job = jobs.removeValue(forKey: context) else {
            reply(PrinterReply.close(tag: tag, result: PrinterWire.Result.invalidHandle))
            log("CLOSE tag \(tag) unknown context \(context) → result 0x0607")
            return
        }
        let writes = job.writes == 0 ? "no writes"
            : "\(job.writes) writes of \(job.minWrite)…\(job.maxWrite) B, \(job.untagged) with tag 0"
        guard job.refused == nil, !job.data.isEmpty else {
            reply(PrinterReply.close(tag: tag, result: PrinterWire.Result.invalidHandle))
            log("CLOSE tag \(tag) context \(context): job \(job.id) \(job.refused.map { "dropped (\($0))" } ?? "empty"), \(writes) → result 0x0607")
            return
        }
        // Reply first, as the reference does, then hand the job off (§3.5).
        reply(PrinterReply.close(tag: tag, result: PrinterWire.Result.success))
        jobsFinished += 1
        log("CLOSE tag \(tag) context \(context): job \(job.id) \(job.data.count) B, \(writes) → result 0")
        onEvent?(.job(PrintJob(id: job.id, data: job.data, printerName: job.printer, writes: job.writes)))
    }

    // MARK: Helpers

    /// The OPEN name's last character is a terminator (§3.3); trailing NULs are dropped as well.
    static func dropTerminator(_ text: String) -> String {
        var s = text
        if !s.isEmpty { s.removeLast() }
        while s.hasSuffix("\0") { s.removeLast() }
        return s
    }

    static func trimNULs(_ text: String) -> String {
        var s = text
        while s.hasSuffix("\0") { s.removeLast() }
        return s
    }

}
