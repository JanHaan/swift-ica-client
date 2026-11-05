import CoreGraphics
import Foundation
import ImageIO

/// A decoded Thinwire bitmap (docs/40-thinwire.md §3.4, §9.3).
struct TWBitmap {
    enum Pixels {
        /// Direct colour, 0xRRGGBB per pixel (high byte may hold junk; ignore it).
        case rgb([UInt32])
        /// Palette indices, one per pixel, with the source bit depth (1, 4 or 8).
        case indexed([UInt8], bpp: Int)
    }

    let width: Int
    let height: Int
    var pixels: Pixels
    /// RGB palette (0xRRGGBB) attached through a type-3 cache object, if any.
    var palette: [UInt32]?
    /// Framebuffer words (0xFFRRGGBB) for direct-colour bitmaps, computed once when cached.
    var opaque: [UInt32]?

    var pixelCount: Int { width * height }

    /// Raw value at index `i`: the colour for direct bitmaps, the palette index otherwise.
    @inline(__always) func rawValue(_ i: Int) -> UInt32 {
        switch pixels {
        case .rgb(let p): return p[i]
        case .indexed(let p, _): return UInt32(p[i])
        }
    }

    /// Resolves every pixel to 0xRRGGBB.
    func rgbPixels(systemPalette: [UInt32]?) -> [UInt32] {
        switch pixels {
        case .rgb(let p):
            return p
        case .indexed(let p, let bpp):
            let pal = palette ?? (bpp == 1 ? TWBitmap.monochrome : (systemPalette ?? TWBitmap.defaultPalette))
            return p.map { Int($0) < pal.count ? pal[Int($0)] : 0 }
        }
    }

    /// Pixels as framebuffer words (0xFFRRGGBB), ready for a row-wise memcpy.
    func opaquePixels(systemPalette: [UInt32]?) -> [UInt32] {
        if let opaque { return opaque }
        return rgbPixels(systemPalette: systemPalette).map { 0xff00_0000 | ($0 & 0xffffff) }
    }

    /// Fills `opaque` for direct-colour bitmaps (paletted ones depend on the session palette).
    mutating func prepareOpaque() {
        if case .rgb(let p) = pixels, opaque == nil { opaque = p.map { 0xff00_0000 | ($0 & 0xffffff) } }
    }

    static let monochrome: [UInt32] = [0x000000, 0xffffff]

    /// Fallback palette: VGA's 16 colours, then a grey ramp.
    static let defaultPalette: [UInt32] = {
        let vga: [UInt32] = [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0,
                             0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff]
        var p = vga
        for i in 16..<256 { let g = UInt32(i); p.append(g << 16 | g << 8 | g) }
        return p
    }()
}

enum TWBitmapCodec {
    /// Decodes a bitmap cache object: u8 type (1), u8 format, packed size (w-1, h-1), payload.
    static func decodeObject(_ bytes: [UInt8]) throws -> TWBitmap {
        try bytes.withUnsafeBufferPointer { buf in
            var r = TWReader(buf)
            do {
                let type = try r.u8()
                guard type == 1 else { throw TWError.invalid("cache object type \(type) is not a bitmap") }
                let format = try r.u8()
                let size = try r.packedSize()
                return try decode(format: format, width: size.x + 1, height: size.y + 1, reader: &r)
            } catch TWError.underflow {
                throw TWError.invalid("bitmap object truncated")
            }
        }
    }

    /// Decodes a payload with an explicit format byte and size (cache bitmaps and image commands).
    static func decode(format: UInt8, width: Int, height: Int, reader r: inout TWReader) throws -> TWBitmap {
        let codec = format >> 4
        let pf = Int(format & 0x0f)
        guard width > 0, height > 0, width * height <= 1 << 26 else {
            throw TWError.invalid("bitmap size \(width)x\(height)")
        }
        let n = width * height
        if pf >= 4 {
            guard pf == 4 || pf == 5 else { throw TWError.invalid("bitmap pixel format \(pf) unsupported") }
            switch codec {
            case 0:
                var out = [UInt32](repeating: 0, count: n)
                for i in 0..<n {
                    out[i] = pf == 4 ? TWColor.expand555(UInt32(try r.u16())) : try r.u24be()
                }
                return TWBitmap(width: width, height: height, pixels: .rgb(out))
            case 1, 2:
                var d = TWRLEDecoder(mode: pf == 4 ? .direct16 : .direct24, v2: codec == 2, width: width, height: height)
                try d.run(&r)
                return TWBitmap(width: width, height: height, pixels: .rgb(d.out))
            case 3:
                return try decodeJPEG(&r, width: width, height: height)
            default:
                throw TWError.invalid("bitmap codec \(codec) unsupported")
            }
        }
        switch pf {
        case 1, 2:
            let bpp = pf == 1 ? 1 : 4
            switch codec {
            case 0:
                return TWBitmap(width: width, height: height, pixels: .indexed(try rawPacked(&r, width: width, height: height, bpp: bpp), bpp: bpp))
            case 1, 2:
                return TWBitmap(width: width, height: height, pixels: .indexed(try packedRLE(&r, width: width, height: height, bpp: bpp), bpp: bpp))
            default:
                throw TWError.invalid("bitmap codec \(codec) unsupported for \(bpp) bpp")
            }
        case 3:
            switch codec {
            case 0:
                return TWBitmap(width: width, height: height, pixels: .indexed(try r.bytes(n), bpp: 8))
            case 1, 2:
                var d = TWRLEDecoder(mode: .byte8, v2: false, width: width, height: height)
                try d.run(&r)
                return TWBitmap(width: width, height: height, pixels: .indexed(d.out.map { UInt8(truncatingIfNeeded: $0) }, bpp: 8))
            default:
                throw TWError.invalid("bitmap codec \(codec) unsupported for 8 bpp")
            }
        default:
            throw TWError.invalid("bitmap pixel format \(pf) unsupported")
        }
    }

    /// Raw 1/4 bpp: rows padded to whole bytes, MSB first.
    static func rawPacked(_ r: inout TWReader, width: Int, height: Int, bpp: Int) throws -> [UInt8] {
        let rowBytes = (width * bpp + 7) / 8
        let mask = UInt8((1 << bpp) - 1)
        let perByte = 8 / bpp
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            var x = 0
            for _ in 0..<rowBytes {
                let b = try r.u8()
                for k in 0..<perByte where x + k < width {
                    out[y * width + x + k] = (b >> UInt8(8 - bpp * (k + 1))) & mask
                }
                x += perByte
            }
        }
        return out
    }

    /// RLE for 1/4 bpp (§9.3.3). Units are whole bytes; a padded row buffer supplies "above".
    static func packedRLE(_ r: inout TWReader, width: Int, height: Int, bpp: Int) throws -> [UInt8] {
        let rowBytes = (width * bpp + 7) / 8
        if rowBytes * height < 32 { return try rawPacked(&r, width: width, height: height, bpp: bpp) }
        let perUnit = 8 / bpp
        let padded = rowBytes * perUnit
        let mask = UInt8((1 << bpp) - 1)
        var rowBuf = [UInt8](repeating: 0, count: padded)
        var out = [UInt8](repeating: 0, count: width * height)
        var col = 0, row = 0
        var unit = [UInt8](repeating: 0, count: perUnit)

        func emit(_ values: [UInt8]) {
            for k in 0..<perUnit {
                rowBuf[col + k] = values[k]
                if col + k < width && row < height { out[row * width + col + k] = values[k] }
            }
            col += perUnit
            if col >= padded { col = 0; row += 1 }
        }

        while row < height {
            let hdr = try r.u8()
            var literals = Int((hdr >> 4) & 7)
            if literals == 7 { literals = try r.extendedCount() }
            var run = Int(hdr & 0x0f)
            if run == 15 { run = try r.extendedCount() }
            run += 1
            for _ in 0..<literals {
                let b = try r.u8()
                for k in 0..<perUnit { unit[k] = (b >> UInt8(8 - bpp * (k + 1))) & mask }
                emit(unit)
            }
            if hdr & 0x80 == 0 {
                for _ in 0..<run {
                    if row >= height { break }
                    let src = (col - perUnit + padded) % padded
                    for k in 0..<perUnit { unit[k] = rowBuf[src + k] }
                    emit(unit)
                }
            } else {
                for _ in 0..<run {
                    if row >= height { break }
                    for k in 0..<perUnit { unit[k] = rowBuf[col + k] }
                    emit(unit)
                }
            }
        }
        return out
    }

    static func decodeJPEG(_ r: inout TWReader, width: Int, height: Int) throws -> TWBitmap {
        let data = Data(try r.bytes(r.remaining))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw TWError.invalid("JPEG decode failed")
        }
        var bgra = [UInt32](repeating: 0, count: width * height)
        let ok = bgra.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw TWError.invalid("JPEG context failed") }
        return TWBitmap(width: width, height: height, pixels: .rgb(bgra.map { $0 & 0xffffff }))
    }
}

/// RLE v1/v2 for 8, 16 and 24 bpp (docs/40-thinwire.md §9.3.1 and §9.3.2).
struct TWRLEDecoder {
    enum Mode { case direct16, direct24, byte8 }

    let mode: Mode
    let v2: Bool
    let width: Int
    let count: Int
    var out: [UInt32]
    var pos = 0
    var cur: UInt32 = 0
    var prev: UInt32
    var last: UInt32 = 0
    var secondLast: UInt32 = 0
    var colorCache: [UInt32] = []
    var mode2Counter = -10

    init(mode: Mode, v2: Bool, width: Int, height: Int) {
        self.mode = mode
        self.v2 = v2 && mode != .byte8
        self.width = width
        count = width * height
        out = [UInt32](repeating: 0, count: count)
        prev = mode == .byte8 ? 0xff : 0xffff_ffff
        if self.v2 { colorCache = mode == .direct16 ? TWRLEDecoder.seed16 : TWRLEDecoder.seed24 }
    }

    @inline(__always) mutating func emit(_ v: UInt32) {
        if pos < count { out[pos] = v }
        pos += 1
        secondLast = last
        last = v
    }

    @inline(__always) func above(_ i: Int) -> UInt32 {
        i >= width && i - width < count ? out[i - width] : 0
    }

    var bytesPerPixel: Int {
        switch mode { case .direct16: return 2; case .direct24: return 3; case .byte8: return 1 }
    }

    mutating func rawPixel(_ r: inout TWReader) throws -> UInt32 {
        switch mode {
        case .direct16: return TWColor.expand555(UInt32(try r.u16()))
        case .direct24: return try r.u24le()
        case .byte8: return UInt32(try r.u8())
        }
    }

    mutating func run(_ r: inout TWReader) throws {
        if count * bytesPerPixel < 32 {
            try explicitV1(&r, count)
            return
        }
        while pos < count {
            let hdr = try r.u8()
            let (literals, runCode) = try TWRLEDecoder.lengths(hdr & 0x3f, &r)
            let explicit = hdr & 0x40 != 0
            if literals > 0 {
                if !explicit {
                    alternating(literals)
                } else if v2 {
                    try explicitV2(&r, literals)
                } else {
                    try explicitV1(&r, literals)
                }
            }
            let runLength = runCode + 1
            if hdr & 0x80 == 0 { fill(runLength, explicit: explicit) } else { copy(runLength, explicit: explicit) }
        }
    }

    /// Maps the 6-bit op code to (literal count, run code); escapes read extended counts, literals first.
    static func lengths(_ k: UInt8, _ r: inout TWReader) throws -> (Int, Int) {
        let esc = -1
        var lit: Int, run: Int
        switch k {
        case 0x00...0x16: lit = 0; run = Int(k)
        case 0x17: lit = 0; run = esc
        case 0x18...0x22: lit = 1; run = Int(k) - 0x18
        case 0x23: lit = 1; run = esc
        case 0x24...0x28: lit = 2; run = Int(k) - 0x24
        case 0x29: lit = 2; run = esc
        case 0x2a...0x34: lit = Int(k) - 0x27; run = 0
        case 0x35: lit = esc; run = 0
        case 0x36...0x3a: lit = Int(k) - 0x33; run = 1
        case 0x3b: lit = esc; run = 1
        case 0x3c, 0x3d: lit = Int(k) - 0x39; run = 2
        case 0x3e: lit = esc; run = 2
        default: lit = esc; run = esc
        }
        if lit == esc { lit = try r.extendedCount() }
        if run == esc { run = try r.extendedCount() }
        return (lit, run)
    }

    mutating func alternating(_ n: Int) {
        for _ in 0..<(n >> 1) { emit(prev); emit(cur) }
        if n & 1 != 0 {
            emit(prev)
            swap(&prev, &cur)
        }
    }

    mutating func explicitV1(_ r: inout TWReader, _ n: Int) throws {
        for _ in 0..<n { emit(try rawPixel(&r)) }
        if n == 1 {
            prev = cur
            cur = last
        } else {
            cur = last
            prev = secondLast
        }
    }

    mutating func explicitV2(_ r: inout TWReader, _ n: Int) throws {
        if mode2Counter > 0 {
            var p = pos > 0 ? last : 0
            for _ in 0..<n {
                p = mode == .direct24 ? try delta24(&r, p) : try delta16(&r, p)
                emit(p)
            }
        } else {
            for _ in 0..<n {
                let t = try r.u8()
                if t & 0x80 != 0 {
                    mode2Counter += 1
                    emit(try newColor(&r, t))
                } else {
                    mode2Counter -= 1
                    let i = Int(t)
                    let c = colorCache[i]
                    if i & 1 != 0 { colorCache.swapAt(i, i - 1) }
                    emit(c)
                }
            }
        }
        prev = pos > 1 ? secondLast : cur
        cur = last
    }

    mutating func newColor(_ r: inout TWReader, _ t: UInt8) throws -> UInt32 {
        let color: UInt32
        let hash: UInt32
        if mode == .direct24 {
            let c = try r.u24le()
            hash = (c ^ (c >> 5) ^ (c >> 11) ^ (c >> 15) ^ (c >> 20)) & 0x3f
            color = c
        } else {
            let v = UInt32(t & 0x7f) << 8 | UInt32(try r.u8())
            hash = (v ^ (v >> 4) ^ (v >> 7) ^ (v >> 13)) & 0x3f
            color = TWColor.expand555(v)
        }
        let slot = Int(hash) << 1
        colorCache[slot + 1] = colorCache[slot]
        colorCache[slot] = color
        return color
    }

    mutating func delta24(_ r: inout TWReader, _ x: UInt32) throws -> UInt32 {
        let p = UInt32(try r.u8())
        let b: UInt32, g: UInt32, rr: UInt32
        if p & 0x80 != 0 {
            if p & 0x40 != 0 {
                if p & 0x20 != 0 {
                    mode2Counter -= 2
                    b = UInt32(try r.u8()); g = UInt32(try r.u8()); rr = UInt32(try r.u8())
                } else {
                    mode2Counter -= 1
                    let q = UInt32(try r.u16())
                    b = ((p << 2) & 0x7c) | ((q >> 7) & 2) | (q & 1)
                    g = (q >> 1) & 0x7f
                    rr = q >> 9
                }
            } else {
                mode2Counter += 2
                b = p & 3; g = (p >> 2) & 3; rr = (p >> 4) & 3
            }
        } else {
            mode2Counter += 1
            let q = UInt32(try r.u8())
            b = p & 0x1f
            g = ((p >> 2) & 0x18) | (q & 7)
            rr = q >> 3
        }
        @inline(__always) func zz(_ f: UInt32) -> UInt32 { (f & 1 != 0 ? f ^ 0x1ff : f) >> 1 }
        let packed = zz(rr) << 16 | zz(g) << 8 | zz(b)
        return (x &+ packed) & 0xffffff
    }

    mutating func delta16(_ r: inout TWReader, _ c0: UInt32) throws -> UInt32 {
        let p = UInt32(try r.u8())
        let b: UInt32, g: UInt32, rr: UInt32
        if p & 0x80 == 0 {
            b = p & 3; g = p >> 4; rr = (p >> 2) & 3
            mode2Counter += 1
        } else {
            let x = UInt32(try r.u8())
            b = (p >> 2) & 0x1f
            g = ((p << 3) & 0x18) | (x & 7)
            rr = x >> 3
            mode2Counter -= 1
        }
        @inline(__always) func zz(_ f: UInt32) -> UInt32 { f & 1 != 0 ? f ^ 0x3f : f }
        let t = (zz(rr) << 18) &+ (zz(g) << 10) &+ (zz(b) << 2)
        var c = c0 | 0x070707
        c = c &+ t
        return (c & 0xf8f8f8) | ((c >> 5) & 0x070707)
    }

    mutating func fill(_ n: Int, explicit: Bool) {
        guard n > 0, pos < count else { return }
        let end = min(count, pos + n)
        while pos < end { emit(cur) }
        if !explicit && pos < count {
            swap(&prev, &cur)
            emit(cur)
        }
    }

    mutating func copy(_ n: Int, explicit: Bool) {
        let end = min(count, pos + n)
        while pos < end { emit(above(pos)) }
        if explicit {
            let l = pos > 0 ? last : 0
            if l != cur { prev = cur; cur = l }
        } else {
            let up = above(pos)
            if up != prev {
                swap(&prev, &cur)
            }
            if pos < count { emit(cur) }
        }
    }

    // Seed tables of the RLE v2 colour cache (protocol constants, docs/40-thinwire.md §9.3.2).
    static let seed16: [UInt32] = [
        0x0000, 0x6110, 0x2000, 0x7e1f, 0x4000, 0x2110, 0x6000, 0x0110, 0x63ff, 0x0000, 0x43ff, 0x7f08, 0x23ff, 0x7e18, 0x03ff, 0x6739,
        0x03f0, 0x6118, 0x23f0, 0x4118, 0x43f0, 0x2118, 0x63f0, 0x0118, 0x011f, 0x5ad6, 0x7f00, 0x211f, 0x411f, 0x7e10, 0x611f, 0x0000,
        0x4100, 0x2010, 0x6100, 0x0010, 0x0100, 0x6010, 0x2100, 0x7f1f, 0x7f18, 0x0000, 0x0000, 0x0000, 0x0842, 0x0000, 0x7e08, 0x7bde,
        0x23e0, 0x2018, 0x03e0, 0x0018, 0x63e0, 0x6018, 0x43e0, 0x4018, 0x401f, 0x7f10, 0x601f, 0x35ad, 0x001f, 0x0000, 0x7e00, 0x201f,
        0x39ce, 0x0000, 0x7d08, 0x4a52, 0x7fe0, 0x7c18, 0x0000, 0x0000, 0x0200, 0x6310, 0x2200, 0x7c1f, 0x4200, 0x2310, 0x6200, 0x0310,
        0x031f, 0x0000, 0x7d00, 0x231f, 0x431f, 0x7c10, 0x631f, 0x0421, 0x6318, 0x0208, 0x4318, 0x2208, 0x2318, 0x4208, 0x0318, 0x6208,
        0x7d18, 0x2529, 0x56b5, 0x0000, 0x0000, 0x0000, 0x7ff0, 0x7c08, 0x4300, 0x2210, 0x6300, 0x0210, 0x0300, 0x6210, 0x2300, 0x7d1f,
        0x421f, 0x7d10, 0x621f, 0x0000, 0x021f, 0x6b5a, 0x7c00, 0x221f, 0x7fff, 0x2218, 0x0218, 0x6308, 0x6218, 0x0308, 0x4218, 0x2308,
    ].map(TWColor.expand555)

    static let seed24: [UInt32] = [
        0x000000, 0xff8000, 0xececec, 0xbfbfbf, 0xc7c7c7, 0x949494, 0xdedede, 0x8d8d8d, 0x000080, 0xff8080, 0xc2c2c2, 0x919191, 0x0000c0, 0xff80c0, 0xf0f0f0, 0xa3a3a3,
        0x800000, 0xffc000, 0xe3e3e3, 0xb0b0b0, 0xc000c0, 0xc8c8c8, 0xd1d1d1, 0x828282, 0xc00000, 0x800080, 0xcdcdcd, 0x9e9e9e, 0x8000c0, 0xffc0c0, 0xffffff, 0xacacac,
        0xebebeb, 0xb8b8b8, 0xff0000, 0x008000, 0xc0ffff, 0xd9d9d9, 0xc0c0c0, 0x939393, 0xc5c5c5, 0x969696, 0x008080, 0xc0c000, 0x80ffff, 0xf7f7f7, 0xff00c0, 0x0080c0,
        0xe4e4e4, 0xb7b7b7, 0x808000, 0x00c000, 0xd6d6d6, 0x858585, 0xc080c0, 0xcfcfcf, 0xcacaca, 0x999999, 0x808080, 0xc08000, 0x00ffff, 0xf8f8f8, 0x8080c0, 0x00c0c0,
        0x00ffc0, 0xd0d0d0, 0x8080ff, 0x00c0ff, 0x00ff80, 0xe2e2e2, 0xfbfbfb, 0xa8a8a8, 0xfefefe, 0xadadad, 0xc080ff, 0xe7e7e7, 0x00ff00, 0xcccccc, 0xd5d5d5, 0x868686,
        0x80ffc0, 0xdfdfdf, 0xff00ff, 0x0080ff, 0xc0ff00, 0x80ff80, 0xf4f4f4, 0xa7a7a7, 0xc0ffc0, 0xf1f1f1, 0xc0c0ff, 0xe8e8e8, 0x80ff00, 0xc0ff80, 0xdadada, 0x898989,
        0x8000ff, 0xffc0ff, 0xffffc0, 0xd7d7d7, 0xfcfcfc, 0xafafaf, 0xffff80, 0xe5e5e5, 0xc000ff, 0xe0e0e0, 0xf9f9f9, 0xaaaaaa, 0xd2d2d2, 0x818181, 0xffff00, 0xcbcbcb,
        0x0000ff, 0xff80ff, 0xd8d8d8, 0x8b8b8b, 0xf3f3f3, 0xa0a0a0, 0xeaeaea, 0xb9b9b9, 0xefefef, 0xbcbcbc, 0xf6f6f6, 0xa5a5a5, 0xdddddd, 0x8e8e8e, 0xc4c4c4, 0x979797,
    ]
}
