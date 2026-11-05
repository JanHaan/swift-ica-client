import Foundation
import CoreGraphics

/// A window icon as received from the host. `blob` is the raw payload (docs/50 §2.5); `image` is the
/// decoded picture when the blob could be decoded.
public struct TWIIcon: @unchecked Sendable {
    public var type: UInt32          // 0 small, 1 big (by inference)
    public var blob: Data
    public var image: CGImage?
    public var width: Int { image?.width ?? 0 }
    public var height: Int { image?.height ?? 0 }
    public init(type: UInt32, blob: Data) {
        self.type = type
        self.blob = blob
        self.image = TWIIconDecoder.decode(blob)
    }
}

/// Decodes the icon blob: u32 LE offsets at +12 (1-bpp AND mask), +16 (BITMAPINFOHEADER), +20 (colour bits).
/// Height in the header is the colour image height (not doubled). Rows are bottom-up and padded to 4 bytes.
/// Mask bit 1 = transparent. 32 bpp uses its alpha channel unless all alpha bytes are 0.
/// Supported depths: 1, 4, 8, 24, 32.
public enum TWIIconDecoder {
    public static func decode(_ blob: Data) -> CGImage? {
        let b = [UInt8](blob)
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard let maskOff = u32(12), let bmiOff = u32(16), let bitsOff = u32(20),
              let headerSize = u32(bmiOff), bmiOff + 40 <= b.count,
              let rawW = u32(bmiOff + 4), let rawH = u32(bmiOff + 8) else { return nil }
        let width = Int(Int32(truncatingIfNeeded: rawW))
        let height = abs(Int(Int32(truncatingIfNeeded: rawH)))
        let bpp = Int(b[bmiOff + 14]) | Int(b[bmiOff + 15]) << 8
        guard (1...512).contains(width), (1...512).contains(height), [1, 4, 8, 24, 32].contains(bpp) else { return nil }

        var palette: [(b: UInt8, g: UInt8, r: UInt8)] = []
        if bpp <= 8 {
            let base = bmiOff + max(headerSize, 40)
            for i in 0..<(1 << bpp) {
                let o = base + i * 4
                guard o + 4 <= b.count else { return nil }
                palette.append((b[o], b[o + 1], b[o + 2]))
            }
        }
        let stride = ((width * bpp + 31) / 32) * 4
        let maskStride = ((width + 31) / 32) * 4
        guard bitsOff >= 0, bitsOff + stride * height <= b.count else { return nil }
        let hasMask = maskOff > 0 && maskOff + maskStride * height <= b.count

        func masked(_ x: Int, _ row: Int) -> Bool {   // row counted from the bottom
            guard hasMask else { return false }
            return b[maskOff + row * maskStride + x / 8] & (0x80 >> UInt8(x % 8)) != 0
        }

        var anyAlpha = false
        if bpp == 32 {
            outer: for row in 0..<height {
                for x in 0..<width where b[bitsOff + row * stride + x * 4 + 3] != 0 { anyAlpha = true; break outer }
            }
        }

        // Output: premultiplied BGRA, top-down.
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = height - 1 - y
            let src = bitsOff + row * stride
            for x in 0..<width {
                var bl: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255
                switch bpp {
                case 32:
                    bl = b[src + x * 4]; g = b[src + x * 4 + 1]; r = b[src + x * 4 + 2]
                    a = anyAlpha ? b[src + x * 4 + 3] : (masked(x, row) ? 0 : 255)
                case 24:
                    bl = b[src + x * 3]; g = b[src + x * 3 + 1]; r = b[src + x * 3 + 2]
                    a = masked(x, row) ? 0 : 255
                default:
                    let index: Int
                    switch bpp {
                    case 8: index = Int(b[src + x])
                    case 4: index = Int((b[src + x / 2] >> (x % 2 == 0 ? 4 : 0)) & 0x0f)
                    default: index = Int((b[src + x / 8] >> UInt8(7 - x % 8)) & 1)
                    }
                    (bl, g, r) = palette[index]
                    a = masked(x, row) ? 0 : 255
                }
                let o = (y * width + x) * 4
                out[o] = UInt8(UInt16(bl) * UInt16(a) / 255)
                out[o + 1] = UInt8(UInt16(g) * UInt16(a) / 255)
                out[o + 2] = UInt8(UInt16(r) * UInt16(a) / 255)
                out[o + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Reads back one pixel as (r,g,b,a) non-premultiplied-ish raw bytes; for tests and diagnostics.
    public static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let data = image.dataProvider?.data as Data?, x < image.width, y < image.height else { return nil }
        let o = y * image.bytesPerRow + x * 4
        guard o + 4 <= data.count else { return nil }
        let base = data.startIndex
        return (data[base + o + 2], data[base + o + 1], data[base + o], data[base + o + 3])
    }
}
