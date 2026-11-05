import Foundation

/// Virtual channel engine for the seamless windows channel `CTXTWI\0` (channel 12).
/// Parses host messages, answers the host init, keeps the `WindowModel`, and builds client requests.
/// Call `receive` and the request methods from the WD's serial queue.
public final class SeamlessEngine: VirtualChannelEngine {
    public struct Config {
        /// Seamless wanted (action 0). False answers with action 1.
        public var seamless = true
        public var advertiseIconChunks = true
        /// Window bitmaps (0x42) are parsed but their content is not used, so off by default.
        public var advertiseBitmaps = false
        public var advertiseFlag2000 = false
        /// Send RESTORE for windows with a taskbar entry that are created minimised.
        public var restoreMinimizedOnCreate = true
        /// Session size, used for the work area when no monitor is known and the host size is unknown.
        public var sessionWidth: Int32 = 0
        public var sessionHeight: Int32 = 0
        public init() {}
    }

    public let channelName = "CTXTWI\0"
    public static let channelNumber = 12

    public var output: ((ChannelOutput) -> Void)?
    public var onEvent: ((SeamlessEvent) -> Void)? {
        get { model.onEvent }
        set { model.onEvent = newValue }
    }

    public var config: Config
    public let model = WindowModel()

    public private(set) var hostInit: TWIHostInit?
    public private(set) var isSeamlessActive = false
    public private(set) var systemMetrics: TWISystemMetrics?
    public private(set) var usesUTF8 = false
    public private(set) var clientFlags: TWIClientFlags = []
    public private(set) var monitors: [TWIMonitor] = []

    // Statistics.
    public private(set) var messageCounts: [UInt8: Int] = [:]
    public private(set) var unknownTypeCounts: [UInt8: Int] = [:]
    public private(set) var malformedCount = 0
    public private(set) var droppedWhileInactive = 0
    public var unknownMessageCount: Int { unknownTypeCounts.values.reduce(0, +) }

    private var framer = TWIStreamFramer()
    private var chunks = TWIChunkAssembler()

    public init(config: Config = Config()) {
        self.config = config
        model.onResendNeeded = { [weak self] id in self?.send(TWIRequest.resendWindow(windowId: id)) }
        model.onMinimizedCreated = { [weak self] id in
            guard let self, self.config.restoreMinimizedOnCreate else { return }
            self.send(TWIRequest.restore(windowId: id))
        }
    }

    // MARK: Receive

    public func receive(_ data: Data) {
        for frame in framer.feed(data) { handle(frame) }
    }

    private func handle(_ frame: TWIStreamFramer.Frame) {
        messageCounts[frame.type, default: 0] += 1
        let message: TWIHostMessage
        do { message = try TWIMessageParser.parse(frame, utf8: usesUTF8) } catch {
            malformedCount += 1
            return
        }
        switch message {
        case .hostInit(let h): handleHostInit(h)
        case .open: handleOpen()
        case .close: handleClose()
        case .systemMetrics(let m):
            systemMetrics = m
            model.publish(.systemMetricsChanged(m))
        case .metricsAck:
            if (hostInit?.hostVersion ?? 0) >= 3 { sendMetrics() }
        case .unknown(let type, _):
            unknownTypeCounts[type, default: 0] += 1
        case .windowRect, .rectList, .bitmapChunk:
            // Parsed for completeness; the reference client discards them.
            if case .bitmapChunk(let c) = message { _ = chunks.add(c) }
        case .iconChunk(let c):
            guard isSeamlessActive else { droppedWhileInactive += 1; return }
            if let done = chunks.add(c) { model.setIcon(windowId: done.windowId, type: done.iconType, blob: done.blob) }
        case .create, .destroy, .change, .windowIcon, .foreground, .processCreated, .processEnded:
            guard isSeamlessActive else { droppedWhileInactive += 1; return }
            model.apply(message)
        }
    }

    private func handleHostInit(_ h: TWIHostInit) {
        hostInit = h
        usesUTF8 = h.flags.contains(.utf8)
        clientFlags = Self.clientFlags(host: h.flags, config: config)
        output?(.channel(TWIRequest.clientInit(seamless: config.seamless, flags: clientFlags)))
        model.publish(.channelReady(h))
    }

    /// Client bits mirror the reference client: set each exactly when the host offers it.
    static func clientFlags(host: TWIHostFlags, config: Config) -> TWIClientFlags {
        var f: TWIClientFlags = [.bit4, .bit8]
        if host.contains(.monitorLayout) { f.insert(.monitorLayout) }
        if host.contains(.extendedInfo) {
            f.insert(.extendedInfo)
            if host.contains(.iconChunks), config.advertiseIconChunks { f.insert(.iconChunks) }
            if host.contains(.bitmaps), config.advertiseBitmaps { f.insert(.bitmaps) }
        }
        if host.contains(.utf8) { f.insert(.utf8) }
        if host.contains(.flag20000), config.advertiseFlag2000 { f.insert(.flag2000) }
        return f
    }

    private func handleOpen() {
        isSeamlessActive = true
        chunks.reset()
        model.reset()
        model.publish(.seamlessStateChanged(active: true))
        sendMetrics()
    }

    private func handleClose() {
        guard isSeamlessActive else { return }
        isSeamlessActive = false
        chunks.reset()
        model.reset()
        model.publish(.seamlessStateChanged(active: false))
    }

    // MARK: Sending

    /// Nothing may be sent before the host init has arrived.
    public var canSend: Bool { hostInit != nil && output != nil }

    @discardableResult
    private func send(_ data: Data) -> Bool {
        guard canSend else { return false }
        output?(.channel(data))
        return true
    }

    private var hostWantsMonitorLayout: Bool { hostInit?.flags.contains(.monitorLayout) ?? false }

    private func sendMetrics() {
        let host = hostInit
        let w = config.sessionWidth > 0 ? config.sessionWidth : Int32(host?.desktopWidth ?? 0)
        let h = config.sessionHeight > 0 ? config.sessionHeight : Int32(host?.desktopHeight ?? 0)
        send(TWIRequest.clientMetrics(workArea: TWIRequest.workArea(monitors: monitors, sessionWidth: w, sessionHeight: h)))
        sendMonitorLayout()
    }

    private func sendMonitorLayout() {
        // The reference client always has at least one monitor; with none known there is nothing to describe.
        if hostWantsMonitorLayout, !monitors.isEmpty { send(TWIRequest.monitorLayout(monitors)) }
    }

    /// Set the local monitor layout (session pixels). Re-sends metrics when the channel is already open.
    /// Debouncing (the reference client waits 1200 ms) is up to the caller.
    public func setMonitors(_ list: [TWIMonitor]) {
        monitors = list
        if isSeamlessActive { sendMetrics() }
    }

    public func activate(windowId: UInt32) { send(TWIRequest.activate(windowId: windowId)) }
    /// Tell the host that no remote window has focus (the reference client does so ~300 ms after losing focus).
    public func deactivateAll() { send(TWIRequest.activate(windowId: 0)) }
    public func moveResize(windowId: UInt32, rect: TWIRect) { send(TWIRequest.moveResize(windowId: windowId, rect: rect)) }
    public func restore(windowId: UInt32) { send(TWIRequest.restore(windowId: windowId)) }
    public func minimize(windowId: UInt32) { send(TWIRequest.minimize(windowId: windowId)) }
    public func maximize(windowId: UInt32) { send(TWIRequest.maximize(windowId: windowId)) }
    public func resendWindow(windowId: UInt32) { send(TWIRequest.resendWindow(windowId: windowId)) }
    public func logoff() { send(TWIRequest.logoff()) }

    /// Uses 0x3c if the host announced flag 0x200, else 0x0e.
    public func requestClose(windowId: UInt32) {
        if hostInit?.flags.contains(.closeAlt) ?? false { send(TWIRequest.closeAlt(windowId: windowId)) }
        else { send(TWIRequest.close(windowId: windowId)) }
    }

    /// Thinwire display layout changed: PAUSE, RESUME, reset the window list, re-send the monitor layout.
    public func displayLayoutChanged() {
        guard isSeamlessActive else { return }
        send(TWIRequest.pause())
        send(TWIRequest.resume())
        chunks.reset()
        model.reset()
        sendMonitorLayout()
    }
}
