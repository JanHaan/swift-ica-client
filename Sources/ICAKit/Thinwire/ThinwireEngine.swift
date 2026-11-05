import CoreGraphics
import CoreVideo
import Foundation

/// One server capability entry echoed in INIT (docs/40-thinwire.md §2.4).
public struct ThinwireCapability: Equatable {
    public let id: UInt16
    public let data: [UInt8]
}

/// Session parameters from the Thinwire INIT command (docs/40-thinwire.md §3.3).
public struct ThinwireSessionInfo {
    public let version: UInt8
    public let sessionId: UInt32
    /// 1..5; 4 = 16 bpp (RGB555), 5 = 24 bpp.
    public let colorDepth: UInt8
    public let width: Int
    public let height: Int
    public let cacheLog2Bytes: Int
    public let handleLog2: Int
    public let maxObjectSize: Int
    public let unknown4: Int
    public let unknown5: Int
    public let serverCapabilities: [ThinwireCapability]
    /// Profile chosen by the server through cap 0x17 (0 if not echoed): 2 = H.264, 3 = H.264 + lossless overlays.
    public let profile: UInt32

    public func has(_ capId: UInt16) -> Bool { serverCapabilities.contains { $0.id == capId } }
    public var endOfFrameSupported: Bool { has(0x0E) }
    public var isVideoProfile: Bool { profile == 2 || profile == 3 }
}

/// Virtual channel engine for `CTXTW  ` (channel 9): parses the Thinwire command stream,
/// decodes H.264 and cached bitmaps into a `Framebuffer`, and reports dirty regions and pointer shapes.
///
/// Call `receive` (and the request methods) from the WD's serial queue. Callbacks run synchronously
/// on that queue; they must not call `receive` re-entrantly.
public final class ThinwireEngine: VirtualChannelEngine {
    public struct Config {
        /// Frame-rate limit sent as C2H 0x1F right after the INIT ack, if the server echoed cap 0x1C
        /// (docs/40-thinwire.md §4.1, §9.7). Clamped to 4...32 like the reference; nil sends nothing.
        public var fpsLimit: UInt16? = 15
        /// Minimum spacing of redraw requests caused by stream errors.
        public var errorRedrawInterval: TimeInterval = 1
        public init() {}
    }

    public struct Stats {
        public var bytes = 0
        public var commands = 0
        public var frames = 0
        public var pictures = 0
        public var resyncs = 0
        public var errors = 0
        public var opcodes: [UInt8: Int] = [:]
    }

    public let channelName = "CTXTW  "
    public static let channelNumber = 9

    public var output: ((ChannelOutput) -> Void)?
    /// Dirty regions (framebuffer pixels, top-left origin) after each END_OF_FRAME.
    public var onUpdate: (([CGRect]) -> Void)?
    /// New pointer shape and hotspot; nil image = hidden pointer.
    public var onPointer: ((CGImage?, CGPoint) -> Void)?
    /// Called after each INIT, once the framebuffer has the new size.
    public var onInit: ((ThinwireSessionInfo) -> Void)?
    public var log: ((String) -> Void)? {
        didSet { cache.log = log }
    }

    public var config: Config
    public private(set) var framebuffer: Framebuffer?
    public private(set) var sessionInfo: ThinwireSessionInfo?
    public private(set) var stats = Stats()

    private var buffer: [UInt8] = []
    private let cache = TWCache()
    private var current = TWPoint.zero
    private var colorDepth: UInt8 = 5
    private var fillColor: UInt32 = 0
    private var brushColor: UInt32 = 0
    private var textColor: UInt32 = 0
    private var textBackground: UInt32 = 0xffffff
    private var textOpaque = false
    private var palette = TWBitmap.defaultPalette
    private var clip: [TWRect]?

    private struct PendingImage {
        var total: Int
        var format: UInt8
        var origin: TWPoint
        var width: Int
        var height: Int
        var colorFormat: UInt32
        var rects: [TWRect]
        var fullFrame: Bool
        var data: [UInt8]
    }
    private var image: PendingImage?
    private var decoders: [TWRect: TWH264Decoder] = [:]
    private var decoderOrder: [TWRect] = []
    private var frameCounter = 0
    private var pictureDecoded = false
    private var overlays: [(rect: TWRect, bgra: [UInt8])] = []
    private var overlaysAdded = false
    private var lastPointer: (CGImage?, CGPoint)?
    private var stopwatches: [UInt16: Date] = [:]
    private var loggedOnce: Set<String> = []
    private var lastErrorRedraw: Date?

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: VirtualChannelEngine

    public func receive(_ data: Data) {
        stats.bytes += data.count
        buffer.append(contentsOf: data)
        var pos = 0
        let count = buffer.count
        var dropped = false
        buffer.withUnsafeBufferPointer { buf in
            while pos < count {
                var r = TWReader(buf, from: pos)
                let saved = current
                do {
                    try command(&r)
                    pos = r.pos
                    stats.commands += 1
                } catch TWError.underflow {
                    current = saved
                    break
                } catch TWError.unknownOpcode(let op) {
                    current = saved
                    unknownOpcode(op, dropping: count - pos)
                    pos = count
                    dropped = true
                    break
                } catch {
                    // The command was consumed; its content could not be applied.
                    stats.errors += 1
                    log?("Thinwire: \(error)")
                    pos = max(r.pos, pos + 1)
                }
            }
        }
        buffer.removeFirst(pos)
        if dropped { buffer.removeAll(keepingCapacity: true) }
        if let info = sessionInfo, !info.endOfFrameSupported { flush() }
    }

    // MARK: Requests

    /// Asks the server to repaint `rect` (default: the whole session) via WD packet 0x06.
    public func requestRedraw(_ rect: TWRect? = nil) {
        let r = rect ?? TWRect(0, 0, sessionInfo?.width ?? 0, sessionInfo?.height ?? 0)
        guard !r.isEmpty else { return }
        output?(ThinwireCapabilities.redraw(r))
    }

    /// Sends C2H 0x1F (client FPS limit).
    public func sendFPSLimit(_ fps: UInt16) {
        output?(ThinwireCapabilities.fpsLimit(min(max(fps, 4), 32)))
    }

    /// Sends C2H 0x1E (enhanced mode change) for a resize, when the server echoed cap 0x19.
    public func sendResize(width: Int, height: Int, capabilityBlob: Data = ThinwireCapabilities.recommendedBlob()) {
        output?(ThinwireCapabilities.enhancedModeChange(width: UInt16(clamping: width), height: UInt16(clamping: height), capabilityBlob: capabilityBlob))
    }

    // MARK: Command dispatch

    private func command(_ r: inout TWReader) throws {
        let op = try r.u8()
        switch op {
        case 0x90: try cmdInit(&r)
        case 0x91: try cmdSetPointer(&r)
        case 0x92:
            // Hide; 0xBC later restores the last shape set by 0x91.
            onPointer?(nil, .zero)
        case 0x93: clip = nil
        case 0x94: clip = [try r.rect(&current)]
        case 0x95: try cmdComplexClip(&r)
        case 0x96: brushColor = try color(&r)
        case 0x97: try cmdPatternBrush(&r)
        case 0x98: textOpaque.toggle()
        case 0x99: textColor = try color(&r)
        case 0x9A: textBackground = try color(&r)
        case 0x9B: try cmdChangePalette(&r)
        case 0x9C:
            let rc = try r.rect(&current)
            fillClipped(rc, fillColor)
        case 0x9D:
            let c = try color(&r)
            let rc = try r.rect(&current)
            fillColor = c
            fillClipped(rc, c)
        case 0x9E:
            let rc = try r.rect(&current)
            fill(rc, fillColor)
        case 0x9F:
            let c: UInt32
            if sessionInfo?.isVideoProfile ?? false { c = try r.u24be() } else { c = try color(&r) }
            let rc = try r.rect(&current)
            fillColor = c
            fill(rc, c)
        case 0xA0:
            let o = try r.packedSize()
            let s = try r.packedSize()
            let handle = Int(try r.u16())
            let dst = try r.point(&current)
            try blitCached(handle, palette: nil, src: TWRect(o.x, o.y, s.x, s.y), to: dst)
        case 0xA1:
            let handle = Int(try r.u16())
            let dst = try r.point(&current)
            try blitCached(handle, palette: nil, src: nil, to: dst)
        case 0xA2:
            let rop = try r.u8()
            let src = try r.rect(&current)
            let dst = try r.point(&current)
            screenCopy(src, to: dst, rop: rop)
        case 0xA3: try cmdBitBlt(&r)
        case 0xA4: try cmdTextOut(&r)
        case 0xA6, 0xA7:
            let n = try r.varint()
            try r.need(n)
            let bytes = UnsafeBufferPointer(rebasing: r.buf[r.pos..<(r.pos + n)])
            r.pos += n
            cache.newObject(bytes)
        case 0xA8, 0xA9:
            let n = try r.varint()
            try r.need(n)
            let bytes = UnsafeBufferPointer(rebasing: r.buf[r.pos..<(r.pos + n)])
            r.pos += n
            cache.extendLast(bytes)
        case 0xAA, 0xAB, 0xAC, 0xB7, 0xB8, 0xB9, 0xBA, 0xBD:
            break
        case 0xAD:
            let n = try r.varint()
            let bits = try r.bytes((n + 7) / 8)
            cache.purge(bits: bits, count: n)
        case 0xAE:
            stopwatches[try r.u16()] = Date()
        case 0xAF:
            let id = try r.u16()
            let elapsed = stopwatches.removeValue(forKey: id).map { UInt32(clamping: Int(Date().timeIntervalSince($0) * 1000)) } ?? 0
            output?(ThinwireCapabilities.stopwatchReply(id: id, elapsedMs: elapsed))
        case 0xBB:
            try r.skip(17)
        case 0xBC:
            if let (img, hot) = lastPointer { onPointer?(img, hot) }
        case 0xBE:
            _ = try r.u8()
            present()
        case 0xC0: try cmdFrameMetrics(&r)
        case 0xC2: try cmdImage(&r, rects: false, flags: false)
        case 0xC3: try cmdImageContinue(&r)
        case 0xC5: try cmdImage(&r, rects: true, flags: false)
        case 0xC6:
            let handle = Int(try r.u16())
            let dst = try r.point(&current)
            try addOverlay(handle, at: dst)
        case 0xC7:
            let s = try r.packedSize()
            let p = try r.point(&current)
            let rc = TWRect(p.x, p.y, s.x, s.y)
            if let i = overlays.firstIndex(where: { $0.rect == rc }) { overlays.remove(at: i) }
        case 0xC8: try cmdImage(&r, rects: true, flags: true)
        default:
            throw TWError.unknownOpcode(op)
        }
        stats.opcodes[op, default: 0] += 1
    }

    private func color(_ r: inout TWReader) throws -> UInt32 {
        switch colorDepth {
        case 1, 2, 3: return palette[Int(try r.u8())]
        case 4: return TWColor.expand555(UInt32(try r.u16()))
        default: return try r.u24be()
        }
    }

    private func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        guard !loggedOnce.contains(key) else { return }
        loggedOnce.insert(key)
        log?(message())
    }

    private func unknownOpcode(_ op: UInt8, dropping n: Int) {
        stats.resyncs += 1
        image = nil
        logOnce(String(format: "op%02X", op),
                String(format: "Thinwire: unknown opcode 0x%02X; dropping %d buffered bytes, resuming at the next payload, requesting a redraw", op, n))
        let now = Date()
        if lastErrorRedraw.map({ now.timeIntervalSince($0) >= config.errorRedrawInterval }) ?? true {
            lastErrorRedraw = now
            requestRedraw()
        }
    }

    // MARK: INIT

    private func cmdInit(_ r: inout TWReader) throws {
        let version = try r.u8()
        let sessionId = try r.u32()
        let depth = try r.u8()
        let size = try r.packedSize()
        let v1 = try r.varint(), v2 = try r.varint(), v3 = try r.varint(), v4 = try r.varint()
        let v5 = try r.varint()
        var blob: [UInt8] = []
        if version >= 3 {
            let len = Int(try r.u16())
            _ = try r.u16()
            blob = try r.bytes(len)
        }
        // Fully parsed; apply.
        current = .zero
        colorDepth = depth
        clip = nil
        image = nil
        overlays = []
        overlaysAdded = false
        pictureDecoded = false
        frameCounter = 0
        decoders.values.forEach { $0.invalidate() }
        decoders = [:]
        decoderOrder = []
        palette = TWBitmap.defaultPalette
        let caps = ThinwireCapabilities.parseServerBlob(blob).map { ThinwireCapability(id: $0.id, data: $0.data) }
        var profile: UInt32 = 0
        if let p = caps.first(where: { $0.id == 0x17 }), p.data.count >= 2 {
            profile = UInt32(p.data[0]) | UInt32(p.data[1]) << 8
        }
        let info = ThinwireSessionInfo(version: version, sessionId: sessionId, colorDepth: depth, width: size.x, height: size.y,
                                       cacheLog2Bytes: v1, handleLog2: v2, maxObjectSize: v3, unknown4: v4, unknown5: v5,
                                       serverCapabilities: caps, profile: profile)
        sessionInfo = info
        let capList = caps.map { String(format: "%02X", $0.id) }.joined(separator: ",")
        log?("Thinwire: INIT v\(version) \(size.x)x\(size.y) depth \(depth) cache 2^\(v1) B / 2^\(v2) handles / max \(v3) (\(v4), \(v5)); profile \(profile); caps [\(capList)]")
        if version < 3 { log?("Thinwire: INIT version \(version) < 3 carries no capabilities; unsupported") }
        if depth != 5 { log?("Thinwire: colour depth \(depth) (H.264 profiles need 5)") }
        if !info.isVideoProfile { log?("Thinwire: server chose profile \(profile), not 2/3; only part of the GDI command set is implemented") }

        do {
            try cache.configure(log2Bytes: v1, handleLog2: v2, maxObjectSize: v3)
        } catch {
            log?("Thinwire: \(error)")
        }
        if let fb = framebuffer {
            if !fb.resize(width: size.x, height: size.y) { log?("Thinwire: framebuffer resize to \(size.x)x\(size.y) failed") }
            else { fb.clear() }
        } else {
            framebuffer = Framebuffer(width: size.x, height: size.y)
            if framebuffer == nil { log?("Thinwire: framebuffer \(size.x)x\(size.y) could not be created") }
        }

        output?(ThinwireCapabilities.initAck(sessionId: sessionId))
        if let fps = config.fpsLimit, info.has(0x1C) { sendFPSLimit(fps) }
        requestRedraw(TWRect(0, 0, size.x, size.y))
        onInit?(info)
    }

    // MARK: Drawing helpers

    private func fill(_ rc: TWRect, _ c: UInt32) {
        guard let fb = framebuffer else { return logOnce("nofb", "Thinwire: drawing before INIT ignored") }
        fb.fill(rc, rgb: c)
    }

    private func clipRects(for rc: TWRect) -> [TWRect] {
        guard let clip else { return [rc] }
        return clip.map { rc.intersection($0) }.filter { !$0.isEmpty }
    }

    private func fillClipped(_ rc: TWRect, _ c: UInt32) {
        for part in clipRects(for: rc) { fill(part, c) }
    }

    /// Fetches and decodes a cached bitmap, optionally with an attached palette object.
    private func bitmap(_ handle: Int, palette paletteHandle: Int?) throws -> TWBitmap {
        var bmp: TWBitmap
        if let cached = cache.decodedBitmap(handle) {
            bmp = cached
        } else {
            guard let obj = cache.object(handle) else { throw TWError.invalid("bitmap handle \(handle) not in cache") }
            bmp = try TWBitmapCodec.decodeObject(obj)
            bmp.prepareOpaque()
            cache.storeDecoded(bmp, for: handle)
        }
        if let paletteHandle {
            guard let obj = cache.object(paletteHandle), obj.count >= 2 else { throw TWError.invalid("palette handle \(paletteHandle) not in cache") }
            let n = Int(obj[1]) + 1
            switch obj[0] {
            case 3:
                guard obj.count >= 2 + 3 * n else { throw TWError.invalid("palette object truncated") }
                bmp.palette = (0..<n).map { i in UInt32(obj[2 + 3 * i]) << 16 | UInt32(obj[3 + 3 * i]) << 8 | UInt32(obj[4 + 3 * i]) }
            case 4:
                guard obj.count >= 2 + n else { throw TWError.invalid("palette object truncated") }
                bmp.palette = (0..<n).map { i in palette[Int(obj[2 + i])] }
            default:
                throw TWError.invalid("cache object type \(obj[0]) is not a palette")
            }
        }
        return bmp
    }

    private func blitCached(_ handle: Int, palette pal: Int?, src: TWRect?, to dst: TWPoint, rop: UInt8 = 0xCC) throws {
        guard let fb = framebuffer else { return logOnce("nofb", "Thinwire: drawing before INIT ignored") }
        let bmp: TWBitmap
        do {
            bmp = try bitmap(handle, palette: pal)
        } catch {
            // As the reference does for a missing source: ask for a repaint of the destination.
            let s = src ?? TWRect(0, 0, 0, 0)
            if !s.isEmpty { requestRedraw(TWRect(dst.x, dst.y, s.width, s.height)) }
            throw error
        }
        let pixels = bmp.opaquePixels(systemPalette: palette)
        let srcRect = src ?? TWRect(0, 0, bmp.width, bmp.height)
        let destRect = TWRect(dst.x, dst.y, srcRect.width, srcRect.height)
        let fn = ropFunction(rop)
        for part in clipRects(for: destRect) {
            fb.blit(pixels, srcWidth: bmp.width, srcHeight: bmp.height, srcRect: srcRect, to: dst, limit: part, rop: fn)
        }
    }

    private func screenCopy(_ src: TWRect, to dst: TWPoint, rop: UInt8) {
        guard let fb = framebuffer else { return }
        let fn = ropFunction(rop)
        for part in clipRects(for: TWRect(dst.x, dst.y, src.width, src.height)) {
            fb.copy(from: src, to: dst, limit: part, rop: fn)
        }
    }

    /// ROP3 on (source, destination) with the current solid brush as pattern; nil = plain copy.
    private func ropFunction(_ rop: UInt8) -> ((UInt32, UInt32) -> UInt32)? {
        if rop == 0xCC { return nil }
        let p = brushColor
        return { s, d in ThinwireEngine.rop3(rop, p, s, d) }
    }

    static func rop3(_ rop: UInt8, _ p: UInt32, _ s: UInt32, _ d: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for i in 0..<8 where rop & (1 << UInt8(i)) != 0 {
            let pp = i & 4 != 0 ? p : ~p
            let ss = i & 2 != 0 ? s : ~s
            let dd = i & 1 != 0 ? d : ~d
            result |= pp & ss & dd
        }
        return result & 0xffffff
    }

    static func ropUsesSource(_ rop: UInt8) -> Bool { ((rop >> 2) ^ rop) & 0x33 != 0 }

    // MARK: GDI-level commands (profile 0 subset)

    private func cmdComplexClip(_ r: inout TWReader) throws {
        let p = try r.point(&current)
        let handle = Int(try r.u16())
        guard let obj = cache.object(handle) else { throw TWError.invalid("clip region handle \(handle) not in cache") }
        var rects: [TWRect] = []
        try obj.withUnsafeBufferPointer { buf in
            var o = TWReader(buf)
            do {
                guard try o.u8() == 5 else { throw TWError.invalid("cache object is not a rect list") }
                let bounds = try o.packedSize()
                let n = try o.varint() + 2
                rects.append(TWRect(p.x, p.y, bounds.x, bounds.y))
                var pt = p
                for _ in 1..<n { rects.append(try o.rect(&pt)) }
            } catch TWError.underflow {
                throw TWError.invalid("rect list object truncated")
            }
        }
        clip = rects.count > 1 ? Array(rects.dropFirst()) : rects
    }

    private func cmdPatternBrush(_ r: inout TWReader) throws {
        let flags = try r.u8()
        var pal: Int?
        if flags & 1 != 0 { pal = Int(try r.u16()) }
        let handle = Int(try r.u16())
        if flags & 2 != 0 { _ = try r.packedSize() }
        logOnce("patbrush", "Thinwire: pattern brushes are approximated by their first pixel")
        if let bmp = try? bitmap(handle, palette: pal) { brushColor = bmp.rgbPixels(systemPalette: palette).first ?? 0 }
    }

    private func cmdChangePalette(_ r: inout TWReader) throws {
        let first = Int(try r.u8())
        let handle = Int(try r.u16())
        guard let obj = cache.object(handle), obj.count >= 2 else { throw TWError.invalid("palette handle \(handle) not in cache") }
        let n = Int(obj[1]) + 1
        for i in 0..<n where first + i < 256 {
            switch obj[0] {
            case 3 where obj.count >= 5 + 3 * i:
                palette[first + i] = UInt32(obj[2 + 3 * i]) << 16 | UInt32(obj[3 + 3 * i]) << 8 | UInt32(obj[4 + 3 * i])
            case 4 where obj.count > 2 + i:
                palette[first + i] = palette[Int(obj[2 + i])]
            default:
                break
            }
        }
    }

    private func cmdBitBlt(_ r: inout TWReader) throws {
        let rop = try r.u8()
        guard ThinwireEngine.ropUsesSource(rop) else {
            let rc = try r.rect(&current)
            guard let fb = framebuffer else { return }
            for part in clipRects(for: rc) {
                switch rop {
                case 0x00: fb.fill(part, rgb: 0)
                case 0xFF: fb.fill(part, rgb: 0xffffff)
                case 0xF0: fb.fill(part, rgb: brushColor)
                case 0xAA: break
                default:
                    let p = brushColor
                    fb.transform(part) { d in ThinwireEngine.rop3(rop, p, 0, d) }
                }
            }
            return
        }
        let flags = try r.u8()
        var surface: Int?
        var pal: Int?
        var handle = 0
        if flags & 4 != 0 {
            surface = Int(try r.u16())
        } else if flags & 1 != 0 {
            pal = Int(try r.u16())
            handle = Int(try r.u16())
        } else {
            handle = Int(try r.u16())
        }
        var sub: TWRect?
        if flags & 2 != 0 {
            let o = try r.packedSize()
            let s = try r.packedSize()
            sub = TWRect(o.x, o.y, s.x, s.y)
        }
        let dst = try r.point(&current)
        if let surface {
            guard surface == 0, let sub else {
                if let sub { requestRedraw(TWRect(dst.x, dst.y, sub.width, sub.height)) }
                throw TWError.invalid("offscreen surface \(surface) not supported")
            }
            screenCopy(sub, to: dst, rop: rop)
            return
        }
        try blitCached(handle, palette: pal, src: sub, to: dst, rop: rop)
    }

    private func cmdTextOut(_ r: inout TWReader) throws {
        let rc = try r.rect(&current)
        let n = Int(try r.u8()) + 1
        let start = try r.point(&current)
        var handles: [Int] = []
        for _ in 0..<n { handles.append(Int(try r.u16())) }
        guard let fb = framebuffer else { return }
        if textOpaque { fillClipped(rc, textBackground) }
        var pen = start
        let fg = textColor
        for (i, h) in handles.enumerated() {
            guard let obj = cache.object(h) else { throw TWError.invalid("glyph handle \(h) not in cache") }
            var glyph: (w: Int, h: Int, d1: TWPoint, d2: TWPoint, bits: [UInt8])?
            obj.withUnsafeBufferPointer { buf in
                var o = TWReader(buf)
                guard let _ = try? o.u8(), let size = try? o.packedSize(),
                      let d1 = try? o.rawDelta(), let d2 = try? o.rawDelta() else { return }
                let w = size.x + 1, gh = size.y + 1
                guard let bits = try? o.bytes(((w + 7) >> 3) * gh) else { return }
                glyph = (w, gh, d1, d2, bits)
            }
            guard let g = glyph else { throw TWError.invalid("glyph object \(h) truncated") }
            if i > 0 { pen = TWPoint(pen.x + g.d2.x, pen.y + g.d2.y) }
            let at = TWPoint(pen.x + g.d1.x, pen.y + g.d1.y)
            pen.x += g.w
            let rowBytes = (g.w + 7) >> 3
            var mono = [UInt32](repeating: 0, count: g.w * g.h)
            for y in 0..<g.h {
                for x in 0..<g.w where g.bits[y * rowBytes + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0 {
                    mono[y * g.w + x] = 1
                }
            }
            for part in clipRects(for: TWRect(at.x, at.y, g.w, g.h)) {
                fb.blit(mono, srcWidth: g.w, srcHeight: g.h, srcRect: TWRect(0, 0, g.w, g.h), to: at, limit: part) { s, d in s != 0 ? fg : d }
            }
        }
    }

    // MARK: Pointer

    private func cmdSetPointer(_ r: inout TWReader) throws {
        let flags = try r.u8()
        let hot = try r.packedSize()
        var pal: Int?
        let colorHandle: Int
        var maskHandle: Int?
        if flags & 1 != 0 {
            colorHandle = Int(try r.u16())
        } else {
            let flags2 = try r.u8()
            if flags2 & 1 != 0 { pal = Int(try r.u16()) }
            colorHandle = Int(try r.u16())
            maskHandle = Int(try r.u16())
        }
        let colorBmp = try bitmap(colorHandle, palette: pal)
        let maskBmp = try maskHandle.map { try bitmap($0, palette: nil) }
        let image = try TWPointer.makeImage(color: colorBmp, mask: maskBmp, systemPalette: colorDepth <= 3 ? palette : nil)
        let hotspot = CGPoint(x: hot.x, y: hot.y)
        lastPointer = (image, hotspot)
        onPointer?(image, hotspot)
    }

    // MARK: Frames, images, overlays

    private func cmdFrameMetrics(_ r: inout TWReader) throws {
        let count = try r.u8()
        guard count != 0 else { return }
        let mask = try r.u8()
        if mask & 1 != 0 { _ = try r.u8() }
        _ = try r.u32()
        guard mask != 0 else { return }
        for bit: UInt8 in [0x01, 0x02, 0x04, 0x08, 0x10] where mask & bit != 0 { _ = try r.varint() }
    }

    private func cmdImage(_ r: inout TWReader, rects withRects: Bool, flags withFlags: Bool) throws {
        try r.need(13)
        let total = Int(try r.u32())
        let format = try r.u8()
        let x = Int(try r.u16()), y = Int(try r.u16())
        let w = Int(try r.u16()), h = Int(try r.u16())
        var colorFormat: UInt32 = 6
        if withFlags { colorFormat = try r.u32() & 0x0f }
        var rects: [TWRect] = []
        var full = false
        if withRects {
            let info = try r.u16()
            let n = Int(info & 0x1f)
            full = info & 0x8000 != 0
            try r.need(8 * n)
            for _ in 0..<n {
                let l = Int(try r.u16()), t = Int(try r.u16()), rr = Int(try r.u16()), b = Int(try r.u16())
                rects.append(TWRect(l, t, rr - l, b - t))
            }
        } else {
            rects = [TWRect(0, 0, w, h)]
            full = true
        }
        let chunkLen = try r.varint()
        let chunk = try r.bytes(chunkLen)
        // Apply.
        if image != nil { logOnce("imgabandon", "Thinwire: new image header before the previous image was complete") }
        guard total >= 0, total <= 64 << 20 else {
            image = nil
            throw TWError.invalid("image of \(total) bytes refused")
        }
        var data = [UInt8]()
        data.reserveCapacity(total)
        data.append(contentsOf: chunk)
        image = PendingImage(total: total, format: format, origin: TWPoint(x, y), width: w, height: h, colorFormat: colorFormat,
                             rects: rects, fullFrame: full, data: data)
        try finishImageIfComplete()
    }

    private func cmdImageContinue(_ r: inout TWReader) throws {
        let n = try r.varint()
        try r.need(n)
        guard image != nil else {
            try r.skip(n)
            throw TWError.invalid("image continuation without an image")
        }
        image!.data.append(contentsOf: r.buf[r.pos..<(r.pos + n)])
        r.pos += n
        try finishImageIfComplete()
    }

    private func finishImageIfComplete() throws {
        guard let img = image, img.data.count >= img.total else { return }
        image = nil
        var payload = img.data
        if payload.count > img.total {
            logOnce("imgover", "Thinwire: image chunks exceed the announced size")
            payload.removeLast(payload.count - img.total)
        }
        guard let fb = framebuffer else { return logOnce("nofb", "Thinwire: drawing before INIT ignored") }
        if img.format >> 4 == 6 {
            if img.colorFormat == 8 { logOnce("yuv444", "Thinwire: YUV 4:4:4 frames are not supported; decoding anyway") }
            let key = TWRect(img.origin.x, img.origin.y, img.width, img.height)
            let decoder: TWH264Decoder
            if let d = decoders[key] {
                decoder = d
            } else {
                decoder = TWH264Decoder()
                decoder.log = log
                decoders[key] = decoder
                decoderOrder.append(key)
                if decoderOrder.count > 4 {
                    let old = decoderOrder.removeFirst()
                    decoders.removeValue(forKey: old)?.invalidate()
                }
            }
            guard let picture = decoder.decode(payload) else { return }
            stats.pictures += 1
            frameCounter += 1
            var rects = img.rects
            if frameCounter == 60 || img.fullFrame {
                frameCounter = 0
                rects = [TWRect(0, 0, img.width, img.height)]
            }
            for rc in rects {
                fb.draw(picture: picture, srcRect: rc, to: TWPoint(img.origin.x + rc.x, img.origin.y + rc.y))
            }
            pictureDecoded = true
        } else {
            let bmp: TWBitmap = try payload.withUnsafeBufferPointer { buf in
                var pr = TWReader(buf)
                do {
                    return try TWBitmapCodec.decode(format: img.format, width: img.width, height: img.height, reader: &pr)
                } catch TWError.underflow {
                    throw TWError.invalid("image payload truncated")
                }
            }
            fb.blit(bmp.opaquePixels(systemPalette: palette), srcWidth: bmp.width, srcHeight: bmp.height,
                    srcRect: TWRect(0, 0, bmp.width, bmp.height), to: img.origin)
        }
    }

    private func addOverlay(_ handle: Int, at dst: TWPoint) throws {
        let bmp = try bitmap(handle, palette: nil)
        let px = bmp.rgbPixels(systemPalette: palette)
        var bgra = [UInt8](repeating: 255, count: px.count * 4)
        for (i, c) in px.enumerated() {
            bgra[i * 4] = UInt8(c & 0xff)
            bgra[i * 4 + 1] = UInt8((c >> 8) & 0xff)
            bgra[i * 4 + 2] = UInt8((c >> 16) & 0xff)
        }
        overlays.append((TWRect(dst.x, dst.y, bmp.width, bmp.height), bgra))
        overlaysAdded = true
    }

    private func present() {
        stats.frames += 1
        if let fb = framebuffer, pictureDecoded || overlaysAdded {
            for o in overlays { fb.blitBGRA(o.bgra, width: o.rect.width, height: o.rect.height, at: TWPoint(o.rect.x, o.rect.y)) }
        }
        pictureDecoded = false
        overlaysAdded = false
        flush()
    }

    private func flush() {
        guard let fb = framebuffer, fb.hasDirtyRegions else { return }
        let rects = fb.present()
        if !rects.isEmpty { onUpdate?(rects) }
    }
}
