import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// The one Thinwire session surface in server desktop coordinates (top-left origin).
/// Seamless windows are crops of it (docs/50-twi.md §3).
///
/// Double-buffered (docs/40-thinwire.md §9.6): every drawing command writes into a private back
/// buffer and records dirty rects. `present()` copies only those rects into the **front** surface,
/// an IOSurface-backed BGRA `CVPixelBuffer` (`pixelBuffer` / `ioSurface`), under `IOSurfaceLock`.
/// The front surface therefore only ever holds complete frames. Written only on the engine's queue.
public final class Framebuffer {
    public private(set) var width: Int
    public private(set) var height: Int
    /// Front surface: complete frames only. Safe to use as CALayer contents.
    public private(set) var pixelBuffer: CVPixelBuffer

    public var ioSurface: IOSurfaceRef? { CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() }
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    /// IOSurface modification seed of the front surface; changes with every present.
    public var seed: UInt32 { ioSurface.map { IOSurfaceGetSeed($0) } ?? 0 }

    private var lockDepth = 0
    /// Back buffer: BGRA, `rowBytes` per row, private to the engine.
    private var back: UnsafeMutablePointer<UInt8>
    private var rowBytes: Int
    private var dirty: [TWRect] = []
    private var yuvInfoVideo: vImage_YpCbCrToARGB?
    private var yuvInfoFull: vImage_YpCbCrToARGB?

    public init?(width: Int, height: Int) {
        guard let pb = Framebuffer.makeBuffer(width: width, height: height) else { return nil }
        self.width = width
        self.height = height
        pixelBuffer = pb
        rowBytes = width * 4
        back = .allocate(capacity: width * 4 * height)
        clear()
    }

    deinit { back.deallocate() }

    static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    /// Replaces both buffers with a new size (INIT with a different screen size). Contents are cleared,
    /// and the front surface is a new IOSurface: re-read `ioSurface` afterwards.
    @discardableResult
    public func resize(width: Int, height: Int) -> Bool {
        guard width != self.width || height != self.height else { return true }
        precondition(lockDepth == 0, "resize inside an update batch")
        guard let pb = Framebuffer.makeBuffer(width: width, height: height) else { return false }
        self.width = width
        self.height = height
        pixelBuffer = pb
        back.deallocate()
        rowBytes = width * 4
        back = .allocate(capacity: width * 4 * height)
        dirty.removeAll()
        clear()
        return true
    }

    // MARK: Back buffer access

    /// Kept for batching symmetry; the back buffer is plain memory and needs no lock.
    func beginUpdates() { lockDepth += 1 }

    func endUpdates() {
        precondition(lockDepth > 0)
        lockDepth -= 1
    }

    @discardableResult
    private func withPixels<T>(_ body: (UnsafeMutablePointer<UInt8>, Int) -> T) -> T {
        body(back, rowBytes)
    }

    // MARK: Dirty tracking and present

    func markDirty(_ r: TWRect) {
        let c = r.intersection(TWRect(0, 0, width, height))
        guard !c.isEmpty else { return }
        if dirty.contains(where: { $0.contains(c) }) { return }
        dirty.removeAll { c.contains($0) }
        dirty.append(c)
        if dirty.count > 32 {
            let all = dirty.reduce(TWRect(0, 0, 0, 0)) { $0.union($1) }
            dirty = [all]
        }
    }

    public var hasDirtyRegions: Bool { !dirty.isEmpty }

    /// Copies the rects drawn since the last present from the back buffer into the front IOSurface
    /// and returns what actually changed. Rows identical to the front are skipped (memcmp); a rect
    /// is shrunk to its first..last differing row. If nothing differs, the IOSurface is neither
    /// write-locked nor modified (its seed stays) and the result is empty.
    @discardableResult
    public func present() -> [CGRect] {
        guard !dirty.isEmpty else { return [] }
        let rects = dirty
        dirty.removeAll()
        guard let surface = ioSurface else { return [] }
        // Pass 1, read-only: find the changed row span of each rect.
        var changed: [TWRect] = []
        IOSurfaceLock(surface, .readOnly, nil)
        let front = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let frb = IOSurfaceGetBytesPerRow(surface)
        for r in rects {
            let n = r.width * 4
            var first = -1, last = -1
            for y in r.y..<r.maxY where memcmp(front + y * frb + r.x * 4, back + y * rowBytes + r.x * 4, n) != 0 {
                if first < 0 { first = y }
                last = y
            }
            if first >= 0 { changed.append(TWRect(r.x, first, r.width, last - first + 1)) }
        }
        IOSurfaceUnlock(surface, .readOnly, nil)
        guard !changed.isEmpty else { return [] }
        copyToFront(changed)
        return changed.map(\.cgRect)
    }

    /// Same as `present()` (name kept from the single-buffered API).
    public func takeDirtyRects() -> [CGRect] { present() }

    private func copyToFront(_ rects: [TWRect]) {
        guard let surface = ioSurface else { return }
        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, [], &seed) == kIOReturnSuccess else { return }
        let dst = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let drb = IOSurfaceGetBytesPerRow(surface)
        for r in rects {
            for y in r.y..<r.maxY {
                memcpy(dst + y * drb + r.x * 4, back + y * rowBytes + r.x * 4, r.width * 4)
            }
        }
        IOSurfaceUnlock(surface, [], &seed)
    }

    // MARK: Reading

    /// Front-surface pixel as 0xAARRGGBB (what is on screen), for tests and debugging.
    public func pixel(x: Int, y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height, let surface = ioSurface else { return 0 }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let p = IOSurfaceGetBaseAddress(surface) + y * IOSurfaceGetBytesPerRow(surface) + x * 4
        return p.loadUnaligned(as: UInt32.self).littleEndian
    }

    /// Back-buffer pixel as 0xAARRGGBB (the frame being drawn).
    func backPixel(x: Int, y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return UnsafeRawPointer(back + y * rowBytes + x * 4).loadUnaligned(as: UInt32.self).littleEndian
    }

    /// Snapshot of the front surface (or a sub-rect) as a CGImage (copies the pixels).
    public func makeImage(rect: CGRect? = nil) -> CGImage? {
        let r = (rect.map { TWRect(Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)) } ?? TWRect(0, 0, width, height))
            .intersection(TWRect(0, 0, width, height))
        guard !r.isEmpty else { return nil }
        guard let surface = ioSurface else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let front = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let data: Data = { (p: UnsafeMutablePointer<UInt8>, rb: Int) -> Data in
            var d = Data(count: r.width * r.height * 4)
            d.withUnsafeMutableBytes { dst in
                for row in 0..<r.height {
                    memcpy(dst.baseAddress! + row * r.width * 4, p + (r.y + row) * rb + r.x * 4, r.width * 4)
                }
            }
            return d
        }(front, IOSurfaceGetBytesPerRow(surface))
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Debug helper: writes the surface (or a sub-rect) as a PNG.
    @discardableResult
    public func writePNG(to url: URL, rect: CGRect? = nil) -> Bool {
        guard let image = makeImage(rect: rect),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Drawing (all clip to the surface; callers clip to the Thinwire clip region)

    /// Clears both buffers to opaque black (INIT); nothing is reported as dirty.
    func clear() {
        fill(TWRect(0, 0, width, height), rgb: 0)
        dirty.removeAll()
        copyToFront([TWRect(0, 0, width, height)])
    }

    /// Solid fill with 0xRRGGBB.
    func fill(_ rect: TWRect, rgb: UInt32) {
        let r = rect.intersection(TWRect(0, 0, width, height))
        guard !r.isEmpty else { return }
        var v = (0xff00_0000 | rgb).littleEndian
        for y in r.y..<r.maxY { memset_pattern4(back + y * rowBytes + r.x * 4, &v, r.width * 4) }
        markDirty(r)
    }

    /// Applies `op` to each pixel of `rect` (value is 0x00RRGGBB in and out).
    func transform(_ rect: TWRect, _ op: (UInt32) -> UInt32) {
        let r = rect.intersection(TWRect(0, 0, width, height))
        guard !r.isEmpty else { return }
        withPixels { p, rb in
            for y in r.y..<r.maxY {
                let row = UnsafeMutableRawPointer(p + y * rb + r.x * 4).assumingMemoryBound(to: UInt32.self)
                for x in 0..<r.width {
                    row[x] = (0xff00_0000 | (op(UInt32(littleEndian: row[x]) & 0xffffff) & 0xffffff)).littleEndian
                }
            }
        }
        markDirty(r)
    }

    /// Draws `src` (srcWidth × srcHeight framebuffer words, i.e. 0xFFRRGGBB, row-major) with its
    /// `srcRect` origin at `dst`, limited to `limit`. Without `rop` this is a row-wise memcpy.
    /// `rop` combines (source, destination) as 0x00RRGGBB values.
    func blit(_ src: [UInt32], srcWidth: Int, srcHeight: Int, srcRect: TWRect, to dst: TWPoint, limit: TWRect? = nil,
              rop: ((UInt32, UInt32) -> UInt32)? = nil) {
        let s = srcRect.intersection(TWRect(0, 0, srcWidth, srcHeight))
        guard !s.isEmpty, src.count >= srcWidth * srcHeight else { return }
        // Source pixel (u, v) lands at (u - ox, v - oy).
        let ox = srcRect.x - dst.x, oy = srcRect.y - dst.y
        var d = TWRect(s.x - ox, s.y - oy, s.width, s.height).intersection(TWRect(0, 0, width, height))
        if let limit { d = d.intersection(limit) }
        guard !d.isEmpty else { return }
        let base = back, rb = rowBytes, n = d.width
        src.withUnsafeBufferPointer { sp in
            let sbase = sp.baseAddress!
            for y in d.y..<d.maxY {
                let drow = UnsafeMutableRawPointer(base + y * rb + d.x * 4).assumingMemoryBound(to: UInt32.self)
                let srow = sbase + (y + oy) * srcWidth + (d.x + ox)
                if let rop {
                    for x in 0..<n {
                        drow[x] = 0xff00_0000 | (rop(srow[x] & 0xffffff, drow[x] & 0xffffff) & 0xffffff)
                    }
                } else {
                    memcpy(drow, srow, n * 4)
                }
            }
        }
        markDirty(d)
    }

    /// Draws BGRA bytes (opaque) of size w × h at `dst`.
    func blitBGRA(_ bytes: [UInt8], width w: Int, height h: Int, at dst: TWPoint) {
        let d = TWRect(dst.x, dst.y, w, h).intersection(TWRect(0, 0, width, height))
        guard !d.isEmpty else { return }
        bytes.withUnsafeBufferPointer { src in
            for y in d.y..<d.maxY {
                let sy = y - dst.y, sx = d.x - dst.x
                memcpy(back + y * rowBytes + d.x * 4, src.baseAddress! + (sy * w + sx) * 4, d.width * 4)
            }
        }
        markDirty(d)
    }

    /// Screen-to-screen copy with an optional ROP on (source, destination). Without a ROP this is
    /// a row-wise memmove in an order that is safe for overlapping rects.
    func copy(from src: TWRect, to dst: TWPoint, limit: TWRect? = nil, rop: ((UInt32, UInt32) -> UInt32)? = nil) {
        let s = src.intersection(TWRect(0, 0, width, height))
        guard !s.isEmpty else { return }
        let ox = src.x - dst.x, oy = src.y - dst.y
        var d = TWRect(s.x - ox, s.y - oy, s.width, s.height).intersection(TWRect(0, 0, width, height))
        if let limit { d = d.intersection(limit) }
        guard !d.isEmpty else { return }
        if let rop {
            // Snapshot the source first so the ROP never reads already-written pixels.
            var snap = [UInt32](repeating: 0, count: d.width * d.height)
            snap.withUnsafeMutableBytes { sb in
                for row in 0..<d.height {
                    memcpy(sb.baseAddress! + row * d.width * 4, back + (d.y + row + oy) * rowBytes + (d.x + ox) * 4, d.width * 4)
                }
            }
            blit(snap, srcWidth: d.width, srcHeight: d.height, srcRect: TWRect(0, 0, d.width, d.height),
                 to: TWPoint(d.x, d.y), rop: rop)
            return
        }
        let rows: [Int] = oy < 0 ? Array((d.y..<d.maxY).reversed()) : Array(d.y..<d.maxY)
        for y in rows {
            memmove(back + y * rowBytes + d.x * 4, back + (y + oy) * rowBytes + (d.x + ox) * 4, d.width * 4)
        }
        markDirty(d)
    }

    /// Copies `srcRect` of a decoded video picture to `dst`. Accepts BGRA or NV12 (420v/420f).
    func draw(picture pb: CVPixelBuffer, srcRect: TWRect, to dst: TWPoint) {
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
        var s = srcRect.intersection(TWRect(0, 0, pw, ph))
        // Clip against the surface too.
        let d0 = TWRect(dst.x + (s.x - srcRect.x), dst.y + (s.y - srcRect.y), s.width, s.height)
        let d = d0.intersection(TWRect(0, 0, width, height))
        s = TWRect(s.x + (d.x - d0.x), s.y + (d.y - d0.y), d.width, d.height)
        guard !s.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pb)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let sb = CVPixelBufferGetBaseAddress(pb) else { return }
            let srb = CVPixelBufferGetBytesPerRow(pb)
            withPixels { p, rb in
                for y in 0..<s.height {
                    memcpy(p + (d.y + y) * rb + d.x * 4, sb + (s.y + y) * srb + s.x * 4, s.width * 4)
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            convertNV12(pb, fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, s: s, d: d)
        default:
            return
        }
        markDirty(d)
    }

    private func conversionInfo(fullRange: Bool) -> vImage_YpCbCrToARGB? {
        if fullRange, let i = yuvInfoFull { return i }
        if !fullRange, let i = yuvInfoVideo { return i }
        // BT.601, as the reference client uses (docs/40-thinwire.md §5.1).
        var range = fullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        var info = vImage_YpCbCrToARGB()
        let err = vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info,
                                                                kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        if fullRange { yuvInfoFull = info } else { yuvInfoVideo = info }
        return info
    }

    /// NV12 region → BGRA. The region is widened to even coordinates for the chroma grid,
    /// converted into a scratch buffer, and the exact rect is copied out.
    private func convertNV12(_ pb: CVPixelBuffer, fullRange: Bool, s: TWRect, d: TWRect) {
        guard var info = conversionInfo(fullRange: fullRange),
              let y0p = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let c0p = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let pw = CVPixelBufferGetWidth(pb) & ~1, ph = CVPixelBufferGetHeight(pb) & ~1
        let ax = s.x & ~1, ay = s.y & ~1
        let ax1 = min(pw, (s.maxX + 1) & ~1), ay1 = min(ph, (s.maxY + 1) & ~1)
        let aw = ax1 - ax, ah = ay1 - ay
        guard aw > 0, ah > 0 else { return }
        let yrb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var srcY = vImage_Buffer(data: y0p + ay * yrb + ax, height: vImagePixelCount(ah), width: vImagePixelCount(aw), rowBytes: yrb)
        var srcC = vImage_Buffer(data: c0p + (ay / 2) * crb + ax, height: vImagePixelCount(ah / 2), width: vImagePixelCount(aw / 2), rowBytes: crb)
        let permute: [UInt8] = [3, 2, 1, 0]
        let direct = ax == s.x && ay == s.y && aw == s.width && ah == s.height
        if direct {
            withPixels { p, rb in
                var dstB = vImage_Buffer(data: p + d.y * rb + d.x * 4, height: vImagePixelCount(ah), width: vImagePixelCount(aw), rowBytes: rb)
                _ = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcC, &dstB, &info, permute, 255, vImage_Flags(kvImageNoFlags))
            }
            return
        }
        var scratch = [UInt8](repeating: 0, count: aw * ah * 4)
        scratch.withUnsafeMutableBytes { raw in
            var dstB = vImage_Buffer(data: raw.baseAddress!, height: vImagePixelCount(ah), width: vImagePixelCount(aw), rowBytes: aw * 4)
            _ = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcC, &dstB, &info, permute, 255, vImage_Flags(kvImageNoFlags))
        }
        let cw = min(s.maxX, ax1) - s.x, ch = min(s.maxY, ay1) - s.y
        guard cw > 0, ch > 0 else { return }
        scratch.withUnsafeBytes { raw in
            withPixels { p, rb in
                for row in 0..<ch {
                    memcpy(p + (d.y + row) * rb + d.x * 4, raw.baseAddress! + ((s.y - ay + row) * aw + (s.x - ax)) * 4, cw * 4)
                }
            }
        }
    }
}
