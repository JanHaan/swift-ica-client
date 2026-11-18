import AppKit
import AVFoundation
import CoreMedia
import ICAKit

/// The Mac camera as the session's HDX webcam (docs/98b §10.1, §10.2). Lives in the app only: icactl has no camera
/// path (it uses `WebcamTestPattern`). Nothing is ever written to disk.
///
/// - Permission is asked for only when the host sends PLAY (`requestPermission`), never at launch or CREATE_CONTEXT.
/// - The `AVCaptureSession` exists only between PLAY and PAUSE/STOP/DESTROY/link drop/session end/"Disable Camera";
///   macOS shows its own green camera indicator meanwhile.
/// - Opening, starting and stopping the device run on `captureQueue`, never on the session queue: `start` and `stop`
///   only enqueue work there. A failure while opening, a runtime error, an interruption or the camera disappearing
///   is reported once through `failed` (the engine then tells the host the device failed, docs/98b §5.4).
/// - The device is the one chosen in Settings (by unique id); if it is not connected at PLAY, the system default is
///   used and the fallback is logged.
/// - Frames are limited to the format's frame rate by timestamp, then centre-cropped to 11:9 and scaled to 352×288
///   NV12 (`WebcamFrameScaler`).
final class Camera: NSObject, WebcamFrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Failure: Error, CustomStringConvertible {
        case notAuthorized
        var description: String { "no camera permission" }
    }

    /// One start: its callbacks are live until `stop` or the first failure.
    private final class Run {
        let deliver: (CVPixelBuffer, CMTime) -> Void
        let failed: (String) -> Void
        let scaler: WebcamFrameScaler
        let minInterval: Double
        var lastFrame: Double?
        var session: AVCaptureSession?
        /// Frame counts of this run, logged when it closes (docs/98b §13 W15): from the camera, over the frame rate,
        /// failed to scale, delivered to the engine, and dropped by AVFoundation as late.
        var received = 0, overRate = 0, scaleFailed = 0, delivered = 0, late = 0
        var opened: Double?
        var observers: [NSObjectProtocol] = []
        init(deliver: @escaping (CVPixelBuffer, CMTime) -> Void, failed: @escaping (String) -> Void, format: WebcamFormat) {
            self.deliver = deliver
            self.failed = failed
            scaler = WebcamFrameScaler(format: format)
            minInterval = 1.0 / Double(max(1, format.frameRate)) * 0.9
        }
    }

    /// Device open/start/stop and the notifications (startRunning and stopRunning block).
    private let captureQueue = DispatchQueue(label: "ica.webcam.camera")
    private let frameQueue = DispatchQueue(label: "ica.webcam.frames")
    /// Guards `current`; held while a callback runs, so none starts after `stop` returns.
    private let lock = NSLock()
    private var current: Run?
    private var name = ""
    /// The chosen camera (nil = system default), and its name for the log.
    let deviceID: String?
    let deviceName: String?
    /// Log lines (device choice and fallback; called on the capture queue).
    let log: (String) -> Void

    init(deviceID: String? = nil, deviceName: String? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.log = log
    }

    var sourceDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return name.isEmpty ? "Mac camera" : "Mac camera \"\(name)\""
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default: completion(false)
        }
    }

    func start(format: WebcamFormat, deliver: @escaping (CVPixelBuffer, CMTime) -> Void,
               failed: @escaping (String) -> Void) throws {
        stop()
        // Defence in depth: the engine asks first, but never open the camera without a grant.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw Failure.notAuthorized }
        let run = Run(deliver: deliver, failed: failed, format: format)
        lock.lock()
        current = run
        lock.unlock()
        captureQueue.async { [weak self] in self?.open(run) }
    }

    func stop() {
        lock.lock()
        let run = current
        current = nil
        lock.unlock()
        guard let run else { return }
        // The device is closed on the capture queue (after a pending open); no callback of this run starts any more.
        captureQueue.async { [lock, log] in Self.close(run, lock: lock, log: log) }
    }

    /// Capture queue. Opens the device unless the run was stopped meanwhile.
    private func open(_ run: Run) {
        guard isCurrent(run) else { return }
        var chosen: AVCaptureDevice?
        if let deviceID {
            chosen = CameraDevices.device(id: deviceID)
            if chosen == nil { log("the chosen camera \"\(deviceName ?? deviceID)\" is not connected; using the system default") }
        }
        guard let device = chosen ?? AVCaptureDevice.default(for: .video) else { return fail(run, "no camera") }
        log("opening \"\(device.localizedName)\"" + (chosen == nil ? " (system default)" : " (chosen in Settings)"))
        let s = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            s.beginConfiguration()
            guard s.canAddInput(input) else { return fail(run, "the camera cannot be used (input)") }
            s.addInput(input)
            let output = AVCaptureVideoDataOutput()
            // Only the pixel format: the scaler crops and scales (no size keys, which not every camera format accepts).
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: WebcamPixelBuffers.pixelFormat]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard s.canAddOutput(output) else { return fail(run, "the camera cannot be used (output)") }
            s.addOutput(output)
            s.commitConfiguration()
        } catch {
            return fail(run, "\(error.localizedDescription)")
        }
        let center = NotificationCenter.default
        run.observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.fail(run, "runtime error" + (error.map { " \($0.code): \($0.localizedDescription)" } ?? ""))
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: s, queue: nil) { [weak self] _ in
                self?.fail(run, "interrupted (another app took the camera?)")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.fail(run, "the camera was disconnected")
            },
        ]
        run.session = s
        lock.lock()
        name = device.localizedName
        lock.unlock()
        guard isCurrent(run) else { return Self.close(run, lock: lock, log: log) }
        lock.lock()
        run.opened = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        s.startRunning()
    }

    /// Capture queue: removes the observers, stops the device and logs the run's frame counts. Static, so the device
    /// is stopped even when the `Camera` is already gone.
    private static func close(_ run: Run, lock: NSLock, log: (String) -> Void) {
        run.observers.forEach(NotificationCenter.default.removeObserver)
        run.observers = []
        let hadSession = run.session != nil
        run.session?.stopRunning()
        run.session = nil
        guard hadSession else { return }
        lock.lock()
        let seconds = run.opened.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0
        let text = String(format: "camera closed after %.1f s: %d frames from the camera, %d over the frame rate, %d late (dropped by AVFoundation), "
                          + "%d failed to scale, %d delivered", seconds, run.received, run.overRate, run.late, run.scaleFailed, run.delivered)
        lock.unlock()
        log(text)
    }

    private func isCurrent(_ run: Run) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current === run
    }

    /// Reports the run's failure once (if it is still current) and closes the device.
    private func fail(_ run: Run, _ why: String) {
        lock.lock()
        guard current === run else { return lock.unlock() }
        current = nil
        run.failed(why)
        lock.unlock()
        captureQueue.async { [lock, log] in Self.close(run, lock: lock, log: log) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let run = current
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        run?.received += 1
        var due = run != nil
        if due, let run, let last = run.lastFrame, time.seconds - last < run.minInterval { due = false; run.overRate += 1 }
        if due { run?.lastFrame = time.seconds }
        lock.unlock()
        guard due, let run, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let frame = run.scaler.scale(image) else {
            lock.lock()
            run.scaleFailed += 1
            lock.unlock()
            return
        }
        // Delivered under the lock, and only while this run is current: nothing arrives after `stop` returns. The
        // callback only hops to the session queue, so the lock is held briefly.
        lock.lock()
        if current === run {
            run.delivered += 1
            run.deliver(frame, time)
        }
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        current?.late += 1
        lock.unlock()
    }
}
