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

// Backlog 2.2: the scroll pattern of scripts/vda/edt-noise.ps1 is found in a window crop and measured.
@Test func chromaMetricFindsScrollPattern() throws {
    // Hash(5, 7) = 1696039508 in the C# (checked on the VDA): bytes R, G, B = low, mid, high.
    #expect(ChromaMetric.scrollTexture(x: 5, y: 7) == (84, 130, 23))
    // The texture wraps every 1024 columns.
    #expect(ChromaMetric.scrollTexture(x: 5, y: 7) == ChromaMetric.scrollTexture(x: 5 + 1024, y: 7))
    // Stripe colour index (x + y/2) mod 6: red, blue, green, yellow, magenta, cyan.
    #expect(ChromaMetric.scrollTexture(x: 2, y: 320) == (255, 0, 0) && ChromaMetric.scrollTexture(x: 3, y: 320) == (0, 0, 255))
    #expect(ChromaMetric.scrollTexture(x: 2, y: 322) == (0, 0, 255) && ChromaMetric.scrollTexture(x: 0, y: 320) == (255, 0, 255))
    // A 1040×700 window crop: grey border, 30-row title bar, texture shifted by 4·37 px.
    let w = 1040, h = 700, top = 30, left = 8, shift = 4 * 37
    var crop = [UInt8](repeating: 200, count: w * h * 4)
    for j in top..<min(h, top + 640) { for i in left..<(left + 1024) where i < w {
        let t = ChromaMetric.scrollTexture(x: i - left + shift, y: j - top)
        let o = (j * w + i) * 4
        crop[o] = t.0; crop[o + 1] = t.1; crop[o + 2] = t.2; crop[o + 3] = 255
    } }
    let m = try #require(ChromaMetric.matchScroll(rgba: crop, width: w, height: h))
    #expect(m.top == top && m.phase == (shift - left + 1024) % 1024)
    #expect(m.psnr == 99 && m.psnrStripes == 99)
    // Shared chroma per 2×2 block (4:2:0-like) costs PSNR on the stripes.
    var blurred = crop
    for j in stride(from: 0, to: h - 1, by: 2) { for i in stride(from: 0, to: w - 1, by: 2) {
        for c in 0..<3 {
            let o = { (x: Int, y: Int) in (y * w + x) * 4 + c }
            let avg = (Int(crop[o(i, j)]) + Int(crop[o(i + 1, j)]) + Int(crop[o(i, j + 1)]) + Int(crop[o(i + 1, j + 1)])) / 4
            for (x, y) in [(i, j), (i + 1, j), (i, j + 1), (i + 1, j + 1)] { blurred[o(x, y)] = UInt8((Int(crop[o(x, y)]) * 3 + avg) / 4) }
        }
    } }
    let b = try #require(ChromaMetric.matchScroll(rgba: blurred, width: w, height: h))
    #expect(b.top == top && b.psnrStripes < 30)
}
