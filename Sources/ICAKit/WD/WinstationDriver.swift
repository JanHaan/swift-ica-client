import Foundation

/// The ICA Winstation Driver: handshake (INIT_REQUEST → INIT_RESPONSE → INIT_CONNECT →
/// INIT_CONNECT_RESPONSE), then framed/encrypted WD packets, VC dispatch and input
/// (docs/30-winstation.md). Not thread-safe: drive it from one serial queue (see `ICASession`).
public final class WinstationDriver {
    public struct Configuration: Sendable {
        public var logon = WDLogon()
        public var display = WDDisplay()
        public var policy = WDCapabilityPolicy()
        /// Port reported in the TD module address (the connect port).
        public var tdPort: UInt16 = 443
        public var outBufLength: UInt16 = 1460
        /// Bytes the transport adds per frame (CGP budget 7, docs/20 §8).
        public var transportOverhead = 7
        public var maxVirtualWrite = 5000

        public init() {}
    }

    public enum Phase: Equatable, Sendable { case handshake, connected, closed }

    public enum Event {
        case initRequest(WDInitRequest)
        case initResponseSent(modules: [String], negotiated: [WDCapability])
        /// One INIT_CONNECT: remaining count, module class, payload (no secrets: server data).
        case initConnect(remaining: UInt8, moduleClass: UInt8, payload: [UInt8])
        case connected(reducerVersion: UInt16, reducerPower: UInt8, expanderPower: UInt8, capabilities: [WDCapability])
        case encryption(WDEncryptionPD.Mode)
        case sessionInfo(tag: String, value: [UInt8])
        case credentialRequest(answered: Bool)
        case setLED(UInt8)
        case mousePosition(x: UInt16, y: UInt16)
        case terminate(reason: UInt8)
        /// Every server packet after parsing (for statistics), VC writes included.
        case packet(WDPacket)
        case droppedChannelData(channel: UInt8, bytes: Int)
        case failure(String)
    }

    public let configuration: Configuration
    /// One transport write (one CGP data packet).
    public var transmit: ([UInt8]) -> Void = { _ in }
    public var onEvent: (Event) -> Void = { _ in }
    /// Every framed client → server WD packet as queued (type byte first), for diagnostics (`PacketRing`).
    public var onPacketSent: (([UInt8]) -> Void)?
    /// How engine output is brought onto the driver's queue; default runs inline.
    public var schedule: (@escaping () -> Void) -> Void = { $0() }

    public private(set) var phase = Phase.handshake
    public private(set) var initRequest: WDInitRequest?
    public private(set) var negotiated: [WDCapability] = []
    public private(set) var finalCapabilities: [WDCapability] = []

    private var engines: [UInt8: VirtualChannelEngine] = [:]
    private var channelOrder: [(name: String, number: UInt8)] = []
    private var handshakeParser = WDStreamParser()
    private var parser = WDStreamParser()
    private var framer = WDFrameAssembler()
    private var crypto: WDEncryptionPD
    private var sawEncryptionPD = false
    private var outQueue: [[UInt8]] = []
    private var batchDepth = 0
    private let obfuscationSeed: UInt8

    public init(configuration: Configuration, encryptionKey: UInt8 = UInt8.random(in: 1...255),
                obfuscationSeed: UInt8 = UInt8.random(in: 1...255)) {
        self.configuration = configuration
        crypto = WDEncryptionPD(key: encryptionKey)
        self.obfuscationSeed = obfuscationSeed
    }

    // MARK: Channels

    /// Registers an engine before the handshake; returns its channel number. `number` asks for a specific free
    /// channel outside the fixed table (CTXGDT on 29, docs/76 §6.1); taken or invalid numbers fall back to the
    /// normal allocation.
    @discardableResult
    public func register(_ engine: VirtualChannelEngine, number requested: UInt8? = nil) -> UInt8 {
        let name = engine.channelName
        let number: UInt8
        if let existing = channelOrder.first(where: { $0.name == name }) { number = existing.number }
        else if let fixed = WDModules.fixedChannels[name] { number = fixed }
        else if let requested, requested >= 20, requested < 0x3A, !channelOrder.contains(where: { $0.number == requested }),
                !WDModules.fixedChannels.values.contains(requested) { number = requested }
        else {
            var n: UInt8 = 20
            while channelOrder.contains(where: { $0.number == n }) || WDModules.fixedChannels.values.contains(n) { n += 1 }
            number = n
        }
        if !channelOrder.contains(where: { $0.name == name }) { channelOrder.append((name, number)) }
        engines[number] = engine
        engine.output = { [weak self] output in
            guard let self else { return }
            self.schedule { self.handleEngineOutput(channel: number, output) }
        }
        return number
    }

    public func channelNumber(_ name: String) -> UInt8? { channelOrder.first { $0.name == name }?.number }

    private func handleEngineOutput(channel: UInt8, _ output: ChannelOutput) {
        switch output {
        case .channel(let data): sendVirtual(channel: channel, [UInt8](data))
        case .wdPacket(let type, let body): send([type] + [UInt8](body))
        }
    }

    // MARK: Receive

    public func receive(_ data: Data) {
        guard phase != .closed else { return }
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 { flush() }
        }
        let bytes = [UInt8](data)
        if phase == .handshake {
            let (packets, rest) = handshakeParser.feed(bytes) { packet in
                // Framing starts right after the last INIT_CONNECT (remaining 0) or a TERMINATE.
                (packet.type == WDPacketType.initConnect && packet.payload.count > 2 && packet.payload[2] == 0)
                    || packet.type == WDPacketType.terminate
            }
            for packet in packets { handle(packet) }
            if phase == .connected, !rest.isEmpty { receiveFramed(rest) }
        } else {
            receiveFramed(bytes)
        }
    }

    private func receiveFramed(_ bytes: [UInt8]) {
        for frame in framer.feed(bytes) {
            guard phase == .connected else { return }
            flush()
            let outputs: [WDEncryptionPD.Output]
            do { outputs = try crypto.receive(frame) } catch {
                onEvent(.failure("encryption PD: \(error)"))
                continue
            }
            for output in outputs {
                switch output {
                case .data(let plain):
                    var stream = plain
                    if v3 {
                        do { stream = try expander.expand(plain) } catch {
                            onEvent(.failure("V3 expander: \(error)"))
                            continue
                        }
                    }
                    for packet in parser.feed(stream).packets { handle(packet) }
                case .reply(let payload):
                    transmit(WDFraming.frame(payload))
                case .established(let mode):
                    onEvent(.encryption(mode))
                }
            }
        }
    }

    private func handle(_ packet: WDPacket) {
        onEvent(.packet(packet))
        if let channel = packet.channel {
            if let engine = engines[channel] { engine.receive(Data(packet.payload)) }
            else { onEvent(.droppedChannelData(channel: channel, bytes: packet.payload.count)) }
            return
        }
        let p = packet.payload
        switch packet.type {
        case WDPacketType.initRequest:
            handleInitRequest(p)
        case WDPacketType.initConnect:
            handleInitConnect(p)
        case WDPacketType.terminate:
            let reason = p.first ?? 0xFF
            onEvent(.terminate(reason: reason))
            sendNow(WDBuild.terminateAck)
            if reason == 0 { resetToHandshake() } else { phase = .closed }
        case WDPacketType.channelMonitor:
            if p.first == 1 { send(WDBuild.pingResponse) }
        case WDPacketType.sessionInfo:
            let tag = String(decoding: p.prefix(7), as: UTF8.self)
            onEvent(.sessionInfo(tag: tag, value: Array(p.dropFirst(8))))
        case WDPacketType.command:
            if p.count >= 2, p[0] == 1, p[1] == 1 {
                let logon = configuration.logon
                let long = negotiated.contains { $0.id == WDCapability.longCredentials }
                send(WDBuild.credentials(username: String(logon.username.prefix(long ? 256 : 20)),
                                         domain: String(logon.domain.prefix(long ? 256 : 17)),
                                         password: String(logon.password.prefix(long ? 256 : 14))))
                onEvent(.credentialRequest(answered: true))
            }
        case WDPacketType.setLED:
            onEvent(.setLED(p.first ?? 0))
        case WDPacketType.setMousePosition where p.count >= 4:
            onEvent(.mousePosition(x: UInt16(p[0]) | UInt16(p[1]) << 8, y: UInt16(p[2]) | UInt16(p[3]) << 8))
        default:
            break
        }
    }

    private func resetToHandshake() {
        phase = .handshake
        framer = WDFrameAssembler()
        parser.reset()
        handshakeParser.reset()
        crypto.reset()
        outQueue = []
    }

    // MARK: Handshake

    private func handleInitRequest(_ payload: [UInt8]) {
        let request: WDInitRequest
        do { request = try WDInitRequest(payload: payload) } catch {
            onEvent(.failure("INIT_REQUEST parse: \(error)"))
            return
        }
        initRequest = request
        onEvent(.initRequest(request))
        guard request.level > 6 else {
            onEvent(.failure("WD level \(request.level) not supported"))
            return
        }
        negotiated = configuration.policy.negotiate(server: request.capabilities)
        do {
            let (modules, names) = try buildModules()
            for packet in WDModules.initResponsePackets(modules) { transmit(packet) }
            onEvent(.initResponseSent(modules: names, negotiated: negotiated))
        } catch {
            onEvent(.failure("INIT_RESPONSE build: \(error)"))
        }
    }

    func buildModules() throws -> ([[UInt8]], [String]) {
        let config = configuration
        let channels = channelOrder.sorted { $0.number < $1.number }.map { ($0.name, $0.number) }
        var modules: [[UInt8]] = [
            WDModules.wd(capabilities: negotiated, channels: channels, maxVirtualWrite: UInt16(config.maxVirtualWrite),
                         reducerVersion: WDCapabilityPolicy.reducerVersion(negotiated)),
            WDModules.td(outBufLength: config.outBufLength, port: config.tdPort),
            WDModules.framing(),
            WDModules.encryption(),
        ]
        var names = ["WD", "TD", "PDRFRAME", "PDCRYPT1"]
        // CTXTW first, then the other VDs in registration order.
        let vds = channelOrder.filter { $0.name == "CTXTW  " } + channelOrder.filter { $0.name != "CTXTW  " }
        for vd in vds {
            if vd.name == "CTXTW  " {
                modules.append(WDModules.thinwire(display: config.display, channel: vd.number))
            } else if let custom = engines[vd.number] as? VirtualChannelModule {
                modules.append(custom.module(channel: vd.number, date: Date()))
            } else {
                modules.append(WDModules.vdHeader(vd.name == "CTXTWI\0" ? .twi : WDModuleIdentity(
                    moduleClass: .vd, versionLow: 1, versionHigh: 1, name: "", hostName: "ICA"), channel: vd.number, date: Date()).bytes())
            }
            names.append(vd.name.replacingOccurrences(of: "\0", with: ""))
        }
        let credentialsInModule = !negotiated.contains { $0.id == WDCapability.credentialRequest }
        let long = negotiated.contains { $0.id == WDCapability.longCredentials }
        modules.append(try WDModules.ui(logon: config.logon, credentialsInModule: credentialsInModule,
                                        longCredentials: long, seed: obfuscationSeed))
        names.append("UI")
        return (modules, names)
    }

    private func handleInitConnect(_ p: [UInt8]) {
        guard p.count >= 4 else { onEvent(.failure("short INIT_CONNECT")); return }
        let remaining = p[2], moduleClass = p[3]
        onEvent(.initConnect(remaining: remaining, moduleClass: moduleClass, payload: p))
        if moduleClass == WDModuleClass.pd.rawValue, p.count > 8, p[8] == 0x0B { sawEncryptionPD = true }
        var reducerVersion: UInt16 = 0, reducerPower: UInt8 = 0, expanderPower: UInt8 = 0
        if moduleClass == WDModuleClass.wd.rawValue, p.count >= 36 {
            reducerPower = p[26]
            expanderPower = p[27]
            reducerVersion = UInt16(p[30]) | UInt16(p[31]) << 8
            let capLength = Int(p[32]) | Int(p[33]) << 8
            let capOffset = Int(p[34]) | Int(p[35]) << 8
            if capLength > 0, capOffset + capLength <= p.count,
               let caps = try? WDCapabilityBlock.parse(Array(p[capOffset..<(capOffset + capLength)])) {
                finalCapabilities = caps
            }
            if reducerVersion != 0 && reducerVersion != 3 {
                onEvent(.failure("server selected reducer version \(reducerVersion); only 0 and 3 are implemented"))
            }
            if reducerVersion == 3 && expanderPower != 0 {
                onEvent(.failure("server kept expander power \(expanderPower); compressed V3 segments cannot be decoded"))
            }
            lastReducer = (reducerVersion, reducerPower, expanderPower)
        }
        guard remaining == 0 else { return }
        if !sawEncryptionPD { onEvent(.failure("server did not confirm PDCRYPT1")) }
        sendNow(WDBuild.initConnectResponse)
        v3 = lastReducer.0 == 3
        expander = WDV3Expander()
        phase = .connected
        framer = WDFrameAssembler()
        parser.reset()
        onEvent(.connected(reducerVersion: lastReducer.0, reducerPower: lastReducer.1, expanderPower: lastReducer.2,
                           capabilities: finalCapabilities))
    }

    private var lastReducer: (UInt16, UInt8, UInt8) = (0, 0, 0)
    /// V3 frame format in both directions once connected (reducer version 3, powers 0).
    public private(set) var v3 = false
    private var expander = WDV3Expander()

    // MARK: Send

    /// Queues one complete WD packet (type byte included). Sent framed/encrypted once connected.
    /// Diagnostics: counts of client → server packets since the last `takeSentCounts`, keyed by
    /// "WD xx", or "VC ch:yy" with yy = first payload byte (the TWI message type on channel 12).
    public private(set) var sentCounts: [String: Int] = [:]

    public func takeSentCounts() -> [String: Int] {
        defer { sentCounts = [:] }
        return sentCounts
    }

    private func countSent(_ packet: [UInt8]) {
        onPacketSent?(packet)
        guard let type = packet.first else { return }
        var key = String(format: "WD %02x", type)
        if WDPacketType.isVirtualWrite(type) {
            let header = type == WDPacketType.virtualWrite1 ? 1 : (type == WDPacketType.virtualWrite8 ? 2 : 3)
            if packet.count > header + 1 { key = String(format: "VC %d:%02x", packet[header], packet[header + 1]) }
        }
        sentCounts[key, default: 0] += 1
    }

    public func send(_ packet: [UInt8]) {
        guard phase == .connected else { return }
        countSent(packet)
        outQueue.append(packet)
        if batchDepth == 0 { flush() }
    }

    /// Writes on a virtual channel, split so that each write fits one frame.
    public func sendVirtual(channel: UInt8, _ data: [UInt8]) {
        let chunk = max(1, min(configuration.maxVirtualWrite, frameBudget - 1 - 4))
        var start = 0
        while start < data.count {
            let end = min(data.count, start + chunk)
            send(WDBuild.virtualWrite(channel: channel, Array(data[start..<end])))
            start = end
        }
    }

    /// Frame payload limit: OutBufLength − 3 − transport overhead (docs/30 §11).
    var frameBudget: Int { Int(configuration.outBufLength) - 3 - configuration.transportOverhead }

    /// Handshake-phase write (unframed) or an immediate framed write.
    private func sendNow(_ packet: [UInt8]) {
        if phase == .connected {
            countSent(packet)
            outQueue.append(packet)
            flush()
        } else {
            transmit(packet)
        }
    }

    /// Packs queued packets into frames without splitting a packet unless it alone exceeds a frame.
    public func flush() {
        guard phase == .connected, !outQueue.isEmpty else { return }
        let limit = frameBudget - crypto.overhead
        if v3 {
            for frame in WDV3Reducer.frames(outQueue, budget: limit) { transmit(WDFraming.frame(crypto.send(frame))) }
            outQueue = []
            return
        }
        var current: [UInt8] = []
        func emit() {
            guard !current.isEmpty else { return }
            transmit(WDFraming.frame(crypto.send(current)))
            current = []
        }
        for packet in outQueue {
            if current.count + packet.count <= limit {
                current += packet
                continue
            }
            emit()
            var start = 0
            while packet.count - start > limit {
                current = Array(packet[start..<(start + limit)])
                emit()
                start += limit
            }
            current = Array(packet[start...])
        }
        emit()
        outQueue = []
    }

    // MARK: Input API (docs/30 §14)

    public func keyScancode(_ code: UInt8, up: Bool) { send(WDBuild.scancode(code, up: up)) }
    public func keyScancodes(_ codes: [UInt8], up: Bool) { send(WDBuild.multiScancode(codes, up: up)) }
    public func keyUnicode(_ unit: UInt16, flags: WDBuild.UnicodeFlags) { send(WDBuild.unicodeKey(unit, flags: flags)) }

    /// Mouse event at a pixel position of the session (size from the configuration's display).
    public func mouse(x: Int, y: Int, state: WDBuild.MouseState) {
        let (nx, ny) = WDBuild.normalise(x: x, y: y, width: configuration.display.width, height: configuration.display.height)
        send(WDBuild.mouse([WDBuild.MouseRecord(x: nx, y: ny, state: state)]))
    }

    /// Several mouse records in one packet (e.g. a move followed by a button change).
    public func mouse(_ events: [(x: Int, y: Int, state: WDBuild.MouseState)]) {
        guard !events.isEmpty else { return }
        let d = configuration.display
        send(WDBuild.mouse(events.map { e in
            let (nx, ny) = WDBuild.normalise(x: e.x, y: e.y, width: d.width, height: d.height)
            return WDBuild.MouseRecord(x: nx, y: ny, state: e.state)
        }))
    }

    /// True if the server negotiated Unicode keyboard mode (cap 0x14): characters go as "insert" events.
    public var unicodeInsertMode: Bool { negotiated.contains { $0.id == WDCapability.unicodeKeyboard } }

    public func setLED(_ mask: UInt8) { send(WDBuild.setLED(mask)) }

    public func wheel(x: Int, y: Int, delta: Int16) {
        guard initRequest?.extendedMouse ?? false else { return }
        let (nx, ny) = WDBuild.normalise(x: x, y: y, width: configuration.display.width, height: configuration.display.height)
        send(WDBuild.wheel(x: nx, y: ny, delta: delta))
    }

    /// Repaint request; clipped to the 12-bit range (larger values would wrap, docs/80 §5 item 3).
    public func redraw(left: Int = 0, top: Int = 0, right: Int? = nil, bottom: Int? = nil) {
        let r = right ?? configuration.display.width, b = bottom ?? configuration.display.height
        let c = ThinwireCapabilities.redrawable(TWRect(left, top, r - left, b - top))
        guard !c.isEmpty else { return }
        send(WDBuild.redraw(left: c.x, top: c.y, right: c.maxX, bottom: c.maxY))
    }
}
