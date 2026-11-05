import CoreGraphics
import Foundation

/// Builds a pointer image from Thinwire cache bitmaps (docs/40-thinwire.md §6.1, §9.1).
enum TWPointer {
    /// - Parameters:
    ///   - color: the XOR image (direct colour or paletted).
    ///   - mask: the AND mask; nil for the single-bitmap form, where `color` holds the AND mask in its
    ///     top half and the XOR image in its bottom half.
    static func makeImage(color: TWBitmap, mask: TWBitmap?, systemPalette: [UInt32]?) throws -> CGImage {
        let w = color.width
        let h: Int
        let xorOffset: Int
        let andValue: (Int) -> UInt32
        if let mask {
            guard mask.width == color.width, mask.height == color.height else {
                throw TWError.invalid("pointer mask \(mask.width)x\(mask.height) does not match image \(color.width)x\(color.height)")
            }
            h = color.height
            xorOffset = 0
            andValue = { mask.rawValue($0) }
        } else {
            guard color.height >= 2 else { throw TWError.invalid("single-bitmap pointer of height \(color.height)") }
            h = color.height / 2
            xorOffset = w * h
            andValue = { color.rawValue($0) }
        }
        let rgb = color.rgbPixels(systemPalette: systemPalette)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let xorRaw = color.rawValue(xorOffset + i)
            let o = i * 4
            if andValue(i) == 0 {
                let c = rgb[xorOffset + i]
                rgba[o] = UInt8((c >> 16) & 0xff)
                rgba[o + 1] = UInt8((c >> 8) & 0xff)
                rgba[o + 2] = UInt8(c & 0xff)
                rgba[o + 3] = 255
            } else if xorRaw & 0xffffff != 0 {
                // "Invert screen" pixel: drawn as opaque black (see §9.1).
                rgba[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw TWError.invalid("pointer image creation failed") }
        return image
    }
}
