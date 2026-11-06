import Foundation
import CoreGraphics

/// Draws a remote application icon onto a square transparent canvas for the Dock tile (docs/99 Phase 0).
public enum IconCanvas {
    /// `image` scaled to fit the canvas minus `inset` (fraction of the side, per edge), aspect kept,
    /// centred, high-quality interpolation (the TWI icons are 16 to 48 px, the canvas is 512).
    public static func render(_ image: CGImage, side: Int = 512, inset: Double = 0.08) -> CGImage? {
        guard side > 0, image.width > 0, image.height > 0,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let room = Double(side) * (1 - 2 * max(0, min(inset, 0.4)))
        let scale = room / Double(max(image.width, image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }
}
