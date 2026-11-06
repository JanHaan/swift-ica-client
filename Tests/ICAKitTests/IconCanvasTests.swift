import CoreGraphics
import Testing
@testable import ICAKit

@Suite struct IconCanvasTests {
    private func square(_ side: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }

    @Test func centresAndKeepsTheMargin() throws {
        let out = try #require(IconCanvas.render(square(32), side: 256, inset: 0.25))
        #expect(out.width == 256 && out.height == 256)
        let centre = try #require(TWIIconDecoder.pixel(out, x: 128, y: 128))
        #expect(centre.r == 255 && centre.a == 255)
        let corner = try #require(TWIIconDecoder.pixel(out, x: 10, y: 10))
        #expect(corner.a == 0)
    }

    @Test func keepsAspectRatio() throws {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let out = try #require(IconCanvas.render(ctx.makeImage()!, side: 200, inset: 0))
        #expect(TWIIconDecoder.pixel(out, x: 100, y: 100)?.a == 255)
        #expect(TWIIconDecoder.pixel(out, x: 100, y: 10)?.a == 0)   // letterboxed above
    }
}
