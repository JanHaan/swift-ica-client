import AppHostKit
import CoreGraphics
import CoreText
import IOSurface
import ImageIO
import Foundation

/// Synthetic "session" for the spike: one shared surface, each window a region with its app's colour,
/// a grid (shows the crop is exact), a sweeping bar (frames), a header line (frame count, last input)
/// and click markers (input round trip: a click in a helper window appears where it was made).
final class Scene {
    struct Region {
        var spec: HelperWindowSpec
        var color: CGColor
        var barX: CGFloat = 0
        var header = ""
        var markers: [CGPoint] = []
    }

    static let headerHeight = 44
    static let barWidth: CGFloat = 36
    let surface: IOSurfaceRef
    private(set) var regions: [UInt32: Region] = [:]
    private(set) var frame = 0

    init?(width: Int, height: Int) {
        guard let surface = SharedSurface.create(width: width, height: height) else { return nil }
        self.surface = surface
        SharedSurface.draw(surface) { ctx in
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func add(_ spec: HelperWindowSpec, color: CGColor) {
        regions[spec.id] = Region(spec: spec, color: color, barX: CGFloat(spec.rect.x))
        paint(spec.id, spec.rect.cgRect)
    }

    func remove(_ id: UInt32) { regions.removeValue(forKey: id) }

    func setHeader(_ id: UInt32, _ text: String) { regions[id]?.header = text }

    /// Adds a marker at a session point; returns the dirty rect.
    func mark(_ id: UInt32, at point: CGPoint) -> WireRect? {
        guard regions[id] != nil else { return nil }
        regions[id]?.markers.append(point)
        if regions[id]!.markers.count > 40 { regions[id]!.markers.removeFirst() }
        let r = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20).integral
        paint(id, r)
        return WireRect(r)
    }

    /// Advances the animation; returns the dirty rects per window (the bar's old and new strip and the
    /// header line), already drawn into the surface.
    func step() -> [UInt32: [WireRect]] {
        frame += 1
        var dirty: [UInt32: [WireRect]] = [:]
        for id in regions.keys.sorted() {
            guard let region = regions[id] else { continue }
            let r = region.spec.rect.cgRect
            let span = r.width - Self.barWidth
            let t = CGFloat(frame) / 90 + CGFloat(id)
            let newX = r.minX + span * (0.5 + 0.5 * sin(t * .pi))
            let body = CGRect(x: r.minX, y: r.minY + CGFloat(Self.headerHeight), width: r.width, height: r.height - CGFloat(Self.headerHeight))
            let old = CGRect(x: region.barX, y: body.minY, width: Self.barWidth, height: body.height)
            let new = CGRect(x: newX, y: body.minY, width: Self.barWidth, height: body.height)
            regions[id]?.barX = newX
            let strip = old.union(new).integral.intersection(body)
            let header = CGRect(x: r.minX, y: r.minY, width: r.width, height: CGFloat(Self.headerHeight))
            paint(id, strip)
            paint(id, header)
            dirty[id] = [WireRect(strip), WireRect(header)]
        }
        return dirty
    }

    /// Repaints `clip` of one window region: background, grid, markers, bar, header text.
    private func paint(_ id: UInt32, _ clip: CGRect) {
        guard let region = regions[id] else { return }
        let r = region.spec.rect.cgRect
        let area = clip.intersection(r)
        guard !area.isNull, !area.isEmpty else { return }
        SharedSurface.draw(surface) { ctx in
            ctx.clip(to: area)
            ctx.setFillColor(region.color)
            ctx.fill(r)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            ctx.setLineWidth(1)
            var x = r.minX
            while x < r.maxX { ctx.stroke(CGRect(x: x + 0.5, y: r.minY, width: 0, height: r.height)); x += 50 }
            var y = r.minY + CGFloat(Self.headerHeight)
            while y < r.maxY { ctx.stroke(CGRect(x: r.minX, y: y + 0.5, width: r.width, height: 0)); y += 50 }
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(4)
            ctx.stroke(r.insetBy(dx: 2, dy: 2))                     // a 4 px frame: the crop edges
            ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1))
            for m in region.markers { ctx.fillEllipse(in: CGRect(x: m.x - 8, y: m.y - 8, width: 16, height: 16)) }
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            let top = r.minY + CGFloat(Self.headerHeight)
            ctx.fill(CGRect(x: region.barX, y: top, width: Self.barWidth, height: r.maxY - top))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: CGFloat(Self.headerHeight)))
            Self.text(ctx, "\(region.header)  ·  frame \(frame)", at: CGPoint(x: r.minX + 14, y: r.minY + 30), size: 22)
        }
    }

    /// Draws one line in the flipped (top-left) context; `at` is the baseline start.
    static func text(_ ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: CGColor = CGColor(gray: 1, alpha: 1)) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The whole surface as PNG (dockspike snapshot: check the drawing without any window).
    func png() -> Data? {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(surface), width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
                                  bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A 1024 px app icon: rounded square in the app's colour with a letter.
    static func icon(letter: String, color: CGColor) -> CGImage? {
        let side = 1024
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 560, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: tile.midX - bounds.midX, y: tile.midY - bounds.midY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}

extension WireRect {
    init(_ r: CGRect) {
        self.init(x: Int(r.minX.rounded(.down)), y: Int(r.minY.rounded(.down)),
                  width: Int(r.width.rounded(.up)), height: Int(r.height.rounded(.up)))
    }
}
