import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Multi-size `.icns` from one image (docs/99 §7): ImageIO's icns writer, one rendition per size.
public enum HelperIcon {
    public static let sizes = [16, 32, 64, 128, 256, 512, 1024]

    public static func icnsData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for side in sizes {
            guard let scaled = scale(image, side: side) else { return nil }
            CGImageDestinationAddImage(dest, scaled, nil)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Square, aspect-preserving, high-quality interpolation (small sources are upscaled).
    static func scale(_ image: CGImage, side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let s = CGFloat(side) / CGFloat(max(image.width, image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }
}
