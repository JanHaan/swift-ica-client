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
