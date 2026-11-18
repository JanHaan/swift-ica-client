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
}
