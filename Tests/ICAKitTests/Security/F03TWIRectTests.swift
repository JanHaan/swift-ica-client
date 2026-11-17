import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-03b: TWI rectangles from the host are clamped. Offline.

@Suite struct F03TWIRectTests {
    @Test func twiRectanglesAreClampedSoTheirArithmeticCannotTrap() throws {
        var bytes: [UInt8] = []
        for v: UInt32 in [0x8000_0000, 0x7FFF_FFFF, 0x7FFF_FFFF, 0x8000_0000] {
            bytes += (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }
        }
        let r = try TWIPayload(Data(bytes)).rect(0)
        #expect(r.left == -TWIRect.coordinateLimit && r.top == TWIRect.coordinateLimit)
        #expect(r.width == 2 * TWIRect.coordinateLimit && r.height == -2 * TWIRect.coordinateLimit)
        #expect(r.left + r.right == 0)
        var plain: [UInt8] = []
        for v: Int32 in [-32000, -32000, 1920, 1080] { plain += (0..<4).map { UInt8((UInt32(bitPattern: v) >> (8 * UInt32($0))) & 0xFF) } }
        #expect(try TWIPayload(Data(plain)).rect(0) == TWIRect(left: -32000, top: -32000, right: 1920, bottom: 1080))
    }
}
