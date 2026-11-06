import AppKit
import AVFoundation
import ICAKit

/// The Mac microphone as the session's capture device (docs/98 §10.3). Lives in the app only: icactl has no
/// microphone path (it uses `AudioToneSource`). Nothing is ever written to disk.
///
/// - Permission is asked for only when the host OPENs the capture device (`requestPermission`), never at launch.
/// - The input node exists only between START_RECORD and STOP_RECORD/CLOSE/suspend/session end; macOS shows its
///   own microphone indicator meanwhile.
/// - The tap's buffers are converted to the OPEN's rate and channel count (AVAudioConverter; mono input feeds
///   both channels of a stereo stream).
final class Microphone: AudioCaptureSource {
    enum Failure: Error, CustomStringConvertible {
        case noInput, noConverter
        var description: String {
            switch self {
            case .noInput: return "no audio input device"
            case .noConverter: return "cannot convert the input to the session format"
            }
        }
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    func start(format: AudioStreamFormat, deliver: @escaping ([Float]) -> Void) throws {
        stop()
        let e = AVAudioEngine()
        let input = e.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noInput }
        let channels = format.channels
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: hardware, to: target) else { throw Failure.noConverter }
        if hardware.channelCount == 1, channels == 2 { converter.channelMap = [0, 0] }
        if hardware.channelCount > AVAudioChannelCount(channels) { converter.downmix = true }
        let ratio = format.sampleRate / hardware.sampleRate
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardware.sampleRate * 0.02), format: hardware) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let p = out.floatChannelData?[0] else { return }
            deliver(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength) * channels)))
        }
        e.prepare()
        do { try e.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        lock.lock()
        engine = e
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let e = engine
        engine = nil
        lock.unlock()
        guard let e else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
    }
}

/// The one-time note after a denied microphone permission (docs/98 §10.3): one line, a button to the privacy
/// settings, non-modal so the session keeps running.
@MainActor
enum MicrophoneNote {
    private static var shown = false
    private static var panel: NSPanel?

    static func show() {
        guard !shown else { return }
        shown = true
        let text = NSTextField(labelWithString: loc(
            "The session asked for the microphone, but ICA Viewer has no permission to use it.",
            "Die Sitzung wollte das Mikrofon nutzen, aber ICA Viewer hat keine Berechtigung dafür."))
        let settings = NSButton(title: loc("Open Privacy Settings", "Datenschutz-Einstellungen öffnen"), target: nil, action: nil)
        let close = NSButton(title: "OK", target: nil, action: nil)
        close.keyEquivalent = "\r"
        let target = NoteTarget()
        settings.target = target
        settings.action = #selector(NoteTarget.openSettings)
        close.target = target
        close.action = #selector(NoteTarget.close)
        let buttons = NSStackView(views: [settings, close])
        let stack = NSStackView(views: [text, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = loc("Microphone", "Mikrofon")
        p.isReleasedWhenClosed = false
        p.contentView = stack
        p.setContentSize(stack.fittingSize)
        p.center()
        objc_setAssociatedObject(p, &NoteTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        panel = p
        p.orderFrontRegardless()
    }

    fileprivate static func dismiss() { panel?.close() }

    private final class NoteTarget: NSObject {
        nonisolated(unsafe) static var key = 0
        @objc func openSettings() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            MainActor.assumeIsolated { MicrophoneNote.dismiss() }
        }
        @objc func close() { MainActor.assumeIsolated { MicrophoneNote.dismiss() } }
    }
}

/// The in-app recording indicator (docs/98 §10.3): a menu-bar item exists only while a session records from the
/// microphone. Its menu names the sessions and offers "Disable Microphone" per session, which stops capture at
/// once and answers that session's later capture OPENs as failed. (macOS shows its own orange dot as well.)
@MainActor
final class MicrophoneIndicator: NSObject {
    static let shared = MicrophoneIndicator()

    private var recording: [ObjectIdentifier: (name: String, disable: () -> Void)] = [:]
    private var order: [ObjectIdentifier] = []
    private var item: NSStatusItem?

    /// `disable` stops the microphone for that session (called on main).
    func update(_ session: AnyObject, name: String, recording on: Bool, disable: @escaping () -> Void) {
        let id = ObjectIdentifier(session)
        if on {
            if recording[id] == nil { order.append(id) }
            recording[id] = (name, disable)
        } else {
            recording[id] = nil
            order.removeAll { $0 == id }
        }
        refresh()
    }

    private func refresh() {
        guard !order.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            i.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: loc("Microphone in use", "Mikrofon aktiv"))
            item = i
        }
        let menu = NSMenu()
        for (index, id) in order.enumerated() {
            guard let entry = recording[id] else { continue }
            let title = NSMenuItem(title: loc("Microphone: recording — \(entry.name)", "Mikrofon: Aufnahme — \(entry.name)"), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let disable = NSMenuItem(title: loc("Disable Microphone for This Session", "Mikrofon für diese Sitzung deaktivieren"),
                                     action: #selector(disableClicked(_:)), keyEquivalent: "")
            disable.target = self
            disable.tag = index
            menu.addItem(disable)
        }
        item?.menu = menu
        item?.button?.toolTip = loc("ICA Viewer: a session is recording from the microphone",
                                    "ICA Viewer: Eine Sitzung nimmt über das Mikrofon auf")
    }

    @objc private func disableClicked(_ sender: NSMenuItem) {
        guard sender.tag < order.count, let entry = recording[order[sender.tag]] else { return }
        entry.disable()
    }
}
