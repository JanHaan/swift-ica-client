import Foundation

/// Chroma of horizontal neighbours inside vs across 2×2 chroma blocks (block borders at even session x), BT.601 Cb/Cr
/// (D155, `icactl chromaprobe`): 4:2:0 video shares one chroma sample per 2×2 block, so the inside difference collapses;
/// 4:4:4 does not.
public enum ChromaMetric {
    public static func insideAcross(rgba: [UInt8], width: Int, height: Int, originX: Int, originY: Int) -> (Double, Double) {
        func cbcr(_ i: Int) -> (Double, Double) {
            let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
            return (-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
        var inside = 0.0, across = 0.0, ni = 0, na = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let a = cbcr((y * width + x) * 4), b = cbcr((y * width + x + 1) * 4)
                let d = abs(a.0 - b.0) + abs(a.1 - b.1)
                if (originX + x) % 2 == 0 { inside += d; ni += 1 } else { across += d; na += 1 }
            }
        }
        return (ni > 0 ? inside / Double(ni) : 0, na > 0 ? across / Double(na) : 0)
    }

    // MARK: The scroll pattern of scripts/vda/edt-noise.ps1 (-Pattern scroll, backlog 2.2)

    public static let scrollWidth = 1024, scrollHeight = 640, scrollStep = 4

    /// Texture pixel (x, y), x taken mod 1024: rows 0-319 per-pixel hash colours, rows 320-639 1-px saturated
    /// stripes. Must stay identical to the C# in edt-noise.ps1.
    public static func scrollTexture(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let x = ((x % scrollWidth) + scrollWidth) % scrollWidth
        if y < 320 {
            var h = UInt32(x) &* 0x9E37_79B1 &+ UInt32(y) &* 0x85EB_CA77
            h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
            return (UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h >> 16))
        }
        let stripes: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 0, 255), (0, 255, 0), (255, 255, 0), (255, 0, 255), (0, 255, 255)]
        return stripes[(x + y / 2) % 6]
    }

    public struct ScrollMatch: Equatable {
        /// Texture column of crop column 0 (mod 1024), texture row 0's crop row.
        public var phase: Int, top: Int
        /// PSNR over the matched pixels: all, the hash-colour rows, the stripe rows.
        public var psnr: Double, psnrNoise: Double, psnrStripes: Double
        public var pixels: Int
    }

    /// Finds the scroll texture in an RGBA crop (the window, title bar included; texture row 0 within `maxTop` rows
    /// of the crop top; the texture spans the crop's width but for the margins) and measures how close the decoded pixels are to it. Nil if no alignment matches.
    /// `margin` columns on each side are left out of the PSNR (window borders).
    public static func matchScroll(rgba: [UInt8], width: Int, height: Int, maxTop: Int = 80, margin: Int = 16) -> ScrollMatch? {
        func px(_ i: Int, _ j: Int) -> (Int, Int, Int) { let o = (j * width + i) * 4; return (Int(rgba[o]), Int(rgba[o + 1]), Int(rgba[o + 2])) }
        // Alignment: 64 pixels of one crop row in the hash rows, compared by luma (lossy video keeps luma best);
        // the candidate with the smallest sum of absolute differences wins if it stands out from the typical one.
        let probeY = min(height - 1, maxTop + 100), probeX = max(0, width / 2 - 32)
        guard probeX + 64 <= width, probeY < height else { return nil }
        @inline(__always) func luma(_ r: Int, _ g: Int, _ b: Int) -> Int { (77 * r + 150 * g + 29 * b) >> 8 }
        let row = (0..<64).map { k -> Int in let (r, g, b) = px(probeX + k, probeY); return luma(r, g, b) }
        var best = (sad: Int.max, phase: 0, top: 0)
        for top in 0...min(maxTop, probeY) {
            let ty = probeY - top
            guard ty < 320 else { continue }
            for phase in 0..<scrollWidth {
                var sad = 0
                for k in 0..<64 {
                    let t = scrollTexture(x: probeX + k + phase, y: ty)
                    sad += abs(row[k] - luma(Int(t.0), Int(t.1), Int(t.2)))
                    if sad >= best.sad { break }
                }
                if sad < best.sad { best = (sad, phase, top) }
            }
        }
        // Random alignments differ by ~85 per pixel (uniform luma); a match by a few.
        guard best.sad < 64 * 30 else { return nil }
        var se = [0.0, 0.0], n = [0, 0]
        for j in best.top..<min(height, best.top + scrollHeight) {
            let ty = j - best.top, half = ty < 320 ? 0 : 1
            for i in margin..<max(margin, width - margin) {
                let (r, g, b) = px(i, j), t = scrollTexture(x: i + best.phase, y: ty)
                let dr = Double(r - Int(t.0)), dg = Double(g - Int(t.1)), db = Double(b - Int(t.2))
                se[half] += dr * dr + dg * dg + db * db
                n[half] += 3
            }
        }
        func psnr(_ e: Double, _ c: Int) -> Double { c == 0 ? .nan : e == 0 ? 99 : 10 * log10(255 * 255 * Double(c) / e) }
        return ScrollMatch(phase: best.phase, top: best.top, psnr: psnr(se[0] + se[1], n[0] + n[1]), psnrNoise: psnr(se[0], n[0]),
                           psnrStripes: psnr(se[1], n[1]), pixels: (n[0] + n[1]) / 3)
    }
}
