import Foundation
import Testing
@testable import ICAKit

// D155: the 4:2:0 vs 4:4:4 tell of chromaprobe.

@Test func chromaMetricTellsSharedFromPerPixelChroma() {
    let w = 64, h = 32
    var rng = SystemRandomNumberGenerator()
    var perPixel = [UInt8](repeating: 255, count: w * h * 4)
    for i in stride(from: 0, to: perPixel.count, by: 4) { for c in 0..<3 { perPixel[i + c] = UInt8.random(in: 0...255, using: &rng) } }
    // 4:2:0-like: one colour per 2×2 block (aligned at even x/y), luma noise kept small.
    var shared = perPixel
    for y in 0..<h { for x in 0..<w {
        let src = ((y / 2 * 2) * w + (x / 2 * 2)) * 4, dst = (y * w + x) * 4
        for c in 0..<3 { shared[dst + c] = perPixel[src + c] }
    } }
    let a = ChromaMetric.insideAcross(rgba: perPixel, width: w, height: h, originX: 0, originY: 0)
    let b = ChromaMetric.insideAcross(rgba: shared, width: w, height: h, originX: 0, originY: 0)
    #expect(a.0 / a.1 > 0.8 && a.0 / a.1 < 1.25)
    #expect(b.0 < 0.001 && b.1 > 10)
    // An odd crop origin flips which pairs are inside a block.
    let c = ChromaMetric.insideAcross(rgba: shared, width: w, height: h, originX: 1, originY: 0)
    #expect(c.1 < 0.001)
}
