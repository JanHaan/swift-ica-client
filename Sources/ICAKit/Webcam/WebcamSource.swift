import CoreMedia
import CoreVideo
import Foundation

/// Where webcam frames come from (docs/98b §10.1, §10.6): the Mac camera in the app (`Camera` in ICAViewer; icactl
/// has none) or the synthetic `WebcamTestPattern`. The engine asks for permission only at the host's first PLAY and
/// starts the source only on PLAY; it stops it on PAUSE/STOP/DESTROY, a link drop, logoff, disconnect, the session end
/// and "Disable Camera".
public protocol WebcamFrameSource: AnyObject {
    /// For the log: "synthetic test pattern" or the camera's name (no ids).
    var sourceDescription: String { get }
    /// Asks for camera permission (prompting at most once). Completion on any thread.
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    /// Starts delivering frames of `format`'s size (NV12) at about its frame rate, on any thread. `time` is the
    /// frame's host-clock time. Must not block: slow work (opening the device) runs on the source's own queue, and a
    /// failure there or later (runtime error, interruption, the device disappears) is reported once through `failed`,
    /// on any thread. Throws only for what is known at once (no permission).
    func start(format: WebcamFormat, deliver: @escaping (CVPixelBuffer, CMTime) -> Void,
               failed: @escaping (String) -> Void) throws
    /// Stops without blocking on the device; no `deliver` or `failed` call starts after it returns.
    func stop()
}

/// A generated picture instead of a camera (`ICA_WEBCAM_SOURCE=synthetic`, icactl camtest, tests): moving colour
/// bars, a moving white square, and the frame number and time of day as digits. Always permitted; it never creates
/// an `AVCaptureSession`. Ticks at the format's frame rate on its own queue.
public final class WebcamTestPattern: WebcamFrameSource {
    public let sourceDescription = "synthetic test pattern"
    public let format: WebcamFormat
    private let queue = DispatchQueue(label: "ica.webcam.pattern")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    public private(set) var framesGenerated = 0

    public init(format: WebcamFormat = .standard) {
        self.format = format
        pool = WebcamPixelBuffers.pool(format)
    }

    public func requestPermission(_ completion: @escaping (Bool) -> Void) { completion(true) }

    public func start(format: WebcamFormat, deliver: @escaping (CVPixelBuffer, CMTime) -> Void,
                      failed: @escaping (String) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(max(1, format.frameRate))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self, let frame = self.frame(self.framesGenerated) else { return }
            self.framesGenerated += 1
            deliver(frame, CMClockGetTime(CMClockGetHostTimeClock()))
        }
        lock.lock()
        timer = t
        lock.unlock()
        t.resume()
    }

    public func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        guard let t else { return }
        t.cancel()
        // A tick already running finishes before stop returns.
        queue.sync {}
    }

    /// Frame `n` of the pattern (also used by tests and the offline encoder check, without a timer).
    public func frame(_ n: Int, date: Date = Date()) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(out, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = format.width, h = format.height
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        // Eight bars, moving left by 4 px per frame.
        let bars: [(UInt8, UInt8, UInt8)] = [(235, 128, 128), (210, 16, 146), (170, 166, 16), (145, 54, 34),
                                            (106, 202, 222), (81, 90, 240), (41, 240, 110), (16, 128, 128)]
        let barWidth = max(1, w / bars.count)
        let shift = (n * 4) % w
        func bar(_ x: Int) -> (UInt8, UInt8, UInt8) { bars[min(bars.count - 1, ((x + shift) % w) / barWidth)] }
        for y in 0..<h {
            let row = yBase + y * yStride
            for x in 0..<w { row[x] = bar(x).0 }
        }
        for y in 0..<(h / 2) {
            let row = cBase + y * cStride
            for x in 0..<(w / 2) {
                let c = bar(x * 2)
                row[x * 2] = c.1
                row[x * 2 + 1] = c.2
            }
        }
        func box(_ x0: Int, _ y0: Int, _ bw: Int, _ bh: Int, luma: UInt8) {
            for y in max(0, y0)..<min(h, y0 + bh) {
                for x in max(0, x0)..<min(w, x0 + bw) { yBase[y * yStride + x] = luma }
            }
            for y in max(0, y0 / 2)..<min(h / 2, (y0 + bh) / 2) {
                for x in max(0, x0 / 2)..<min(w / 2, (x0 + bw) / 2) {
                    cBase[y * cStride + x * 2] = 128
                    cBase[y * cStride + x * 2 + 1] = 128
                }
            }
        }
        // A white square bouncing across the middle.
        let travel = w - 48
        let p = (n * 6) % (2 * travel)
        box(p < travel ? p : 2 * travel - p, h / 2 - 24, 48, 48, luma: 235)
        // "nnnnnn hh:mm:ss" on a black band at the bottom, 3×5 digits at 4 px per dot.
        let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second], from: date)
        let text = String(format: "%06d %02d:%02d:%02d", n % 1_000_000, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let dot = 4, top = h - 32
        box(0, top - 4, w, 28, luma: 16)
        var x = 8
        for ch in text {
            if let glyph = Self.glyphs[ch] {
                for (row, bits) in glyph.enumerated() {
                    for col in 0..<3 where bits & (4 >> col) != 0 {
                        box(x + col * dot, top + row * dot, dot, dot, luma: 235)
                    }
                }
            }
            x += 4 * dot
        }
        return out
    }

    /// 3×5 digit glyphs (bit 2 = left column).
    static let glyphs: [Character: [UInt8]] = [
        "0": [7, 5, 5, 5, 7], "1": [2, 6, 2, 2, 7], "2": [7, 1, 7, 4, 7], "3": [7, 1, 7, 1, 7], "4": [5, 5, 7, 1, 1],
        "5": [7, 4, 7, 1, 7], "6": [7, 4, 7, 5, 7], "7": [7, 1, 1, 1, 1], "8": [7, 5, 7, 5, 7], "9": [7, 5, 7, 1, 7],
        ":": [0, 2, 0, 2, 0], " ": [0, 0, 0, 0, 0],
    ]
}
