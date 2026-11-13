import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AppHostKit

/// The generator on a minimal template in a temp directory (codesign only; nothing is launched or
/// registered with LaunchServices).
@Suite struct HelperBundleGeneratorTests {
    private func makeTemplate(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Template.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.alttab.ICAViewer.helper", "CFBundleName": "ICAViewerHelper",
                                   "CFBundleExecutable": "helper", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/helper"))
        return app
    }

    private func icon(_ gray: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
        return ctx.makeImage()!
    }

    @Test func generatesRelabelsSignsAndIsIdempotent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("apphostkit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let template = try makeTemplate(in: dir)
        // A template from a downloaded app carries quarantine; the copy must not.
        #expect(setxattr(template.path, HelperBundleGenerator.quarantineAttribute, "0081;00000000;Test;", 19, 0, 0) == 0)
        let apps = dir.appendingPathComponent("Apps", isDirectory: true)
        let generator = HelperBundleGenerator(template: template, appsDirectory: apps, registerWithLaunchServices: false)
        let label = HelperLabel(key: "spike.alpha", name: "Spike Alpha")

        let first = try generator.generate(label, icon: icon(0.5))
        #expect(first.outcome == .created)
        #expect(first.url.path == apps.appendingPathComponent(HelperBundle.relativePath(for: label)).path)
        let info = try #require(HelperBundleGenerator.readInfo(first.url))
        #expect(info["CFBundleName"] as? String == "Spike Alpha")
        #expect(info["CFBundleIdentifier"] as? String == HelperBundle.bundleIdentifier(for: label))
        #expect(!HelperBundleGenerator.hasQuarantine(first.url))
        try HelperBundleGenerator.verify(first.url)
        let details = try HelperBundleGenerator.codesign(["-dv", first.url.path])
        #expect(details.contains("Identifier=" + HelperBundle.bundleIdentifier(for: label)))
        #expect(details.contains("adhoc") && details.contains("runtime"))
        let icns = first.url.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let source = try #require(CGImageSourceCreateWithURL(icns as CFURL, nil))
        #expect(CGImageSourceGetCount(source) >= 5)            // multi-size icns from ImageIO (docs/99 §7)

        #expect(try generator.generate(label, icon: icon(0.5)).outcome == .unchanged)
        #expect(try generator.generate(label, icon: icon(0.9)).outcome == .updated)

        // Rename: same key, same directory, the old bundle goes.
        let renamed = try generator.generate(HelperLabel(key: label.key, name: "Spike Alpha 2"), icon: nil)
        #expect(renamed.outcome == .created)
        let bundles = try fm.contentsOfDirectory(atPath: renamed.url.deletingLastPathComponent().path)
        #expect(bundles == ["Spike Alpha 2.app"])              // no staging leftovers either
        #expect(!fm.fileExists(atPath: renamed.url.appendingPathComponent("Contents/Resources/AppIcon.icns").path))

        // Tampering after signing is caught, and the next generate repairs it.
        let plist = renamed.url.appendingPathComponent("Contents/Info.plist")
        var tampered = try #require(HelperBundleGenerator.readInfo(renamed.url))
        tampered["Extra"] = true
        try PropertyListSerialization.data(fromPropertyList: tampered, format: .xml, options: 0).write(to: plist)
        #expect(throws: HelperBundleError.self) { try HelperBundleGenerator.verify(renamed.url) }
        #expect(try generator.generate(HelperLabel(key: label.key, name: "Spike Alpha 2"), icon: nil).outcome == .updated)
        try HelperBundleGenerator.verify(renamed.url)
    }

    @Test func icnsHasEveryRendition() throws {
        let data = try #require(HelperIcon.icnsData(icon(0.3)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let widths = Set((0..<CGImageSourceGetCount(source)).compactMap { i -> Int? in
            (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        })
        #expect(widths.isSuperset(of: [16, 32, 128, 256, 512]))
    }
}
