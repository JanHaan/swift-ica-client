import CoreGraphics
import Foundation
import IOSurface

/// The shared session surface of the spike host and the helpers: BGRA, top-left origin, like the
/// Framebuffer's front surface. Shared across processes only through `IOSurfaceCreateMachPort`;
/// never `kIOSurfaceIsGlobal` (docs/99 §4).
public enum SharedSurface {
    public static func create(width: Int, height: Int) -> IOSurfaceRef? {
        IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241,     // 'BGRA'
        ] as CFDictionary)
    }

    /// The BGRA pixel at (x, y) as 0xAARRGGBB, read under a read-only lock; nil outside.
    public static func pixel(_ surface: IOSurfaceRef, x: Int, y: Int) -> UInt32? {
        guard x >= 0, y >= 0, x < IOSurfaceGetWidth(surface), y < IOSurfaceGetHeight(surface) else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let row = IOSurfaceGetBaseAddress(surface) + y * IOSurfaceGetBytesPerRow(surface)
        return row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)   // little-endian BGRA = 0xAARRGGBB
    }

    /// Copy of a rect of the surface (clipped to it) as an opaque CGImage: the frozen content of a window
    /// during a local resize (D20), taken in the helper from the shared surface, no image transfer.
    public static func image(_ surface: IOSurfaceRef, rect r: WireRect) -> CGImage? {
        let sw = IOSurfaceGetWidth(surface), sh = IOSurfaceGetHeight(surface)
        let x0 = max(0, r.x), y0 = max(0, r.y), x1 = min(sw, r.x + r.width), y1 = min(sh, r.y + r.height)
        guard x1 > x0, y1 > y0 else { return nil }
        let w = x1 - x0, h = y1 - y0
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress! + row * w * 4, base + (y0 + row) * rowBytes + x0 * 4, w * 4)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// contentsRect for a snapshot of `imageSize` pixels shown 1:1, anchored top-left, in a view of
    /// `viewPixels` (unit coordinates; > 1 makes Core Animation extend the edge pixels into newly exposed
    /// areas), as `TWILocalGesture.snapshotContentsRect` in the main process.
    public static func snapshotContentsRect(viewPixels: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: 0, y: 0, width: viewPixels.width / imageSize.width, height: viewPixels.height / imageSize.height)
    }

    /// Draws into the surface with Core Graphics under a write lock. The context is flipped to the
    /// surface's top-left origin (text drawn with it needs a flipped text matrix).
    public static func draw(_ surface: IOSurfaceRef, _ body: (CGContext) -> Void) {
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(surface), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
    }
}
