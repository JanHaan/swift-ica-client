import Foundation
import Testing
@testable import AppHostKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-06: a helper bundle is reused only when it holds
// exactly the code this process would build; a planted or edited bundle with a valid ad-hoc signature is replaced,
// and a broken template is refused. Offline (codesign only, nothing launched or registered).

@Suite(.serialized) struct HelperBundleReuseTests {
    private func makeTemplate(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Template.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.alttab.ICAViewer.helper", "CFBundleName": "ICAViewerHelper",
                                   "CFBundleExecutable": "helper", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/helper"))
        try HelperBundleGenerator.sign(app, identity: "-", hardenedRuntime: true)
        return app
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macf-l06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Swaps the bundle's executable for other code and re-signs it ad hoc: still a valid signature.
    private func plant(_ bundle: URL) throws {
        let exe = bundle.appendingPathComponent("Contents/MacOS/helper")
        try FileManager.default.removeItem(at: exe)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: exe)
        try HelperBundleGenerator.sign(bundle, identity: "-", hardenedRuntime: true)
        try HelperBundleGenerator.verify(bundle)
    }

    @Test func aBundleFromAnEarlierRunIsKeptOnlyWithTheSameCode() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let generator = HelperBundleGenerator(template: try makeTemplate(in: dir), appsDirectory: dir.appendingPathComponent("Apps"),
                                              registerWithLaunchServices: false)
        let label = HelperLabel(key: "l06.alpha", name: "L06 Alpha")
        let first = try generator.generate(label, icon: nil)
        let built = try #require(CodeIdentity.cdhash(bundle: first.url))

        HelperBundleGenerator.forgetRecords()                                    // a new run: nothing built yet
        #expect(try generator.generate(label, icon: nil).outcome == .unchanged)  // same code: kept as it is
        #expect(CodeIdentity.cdhash(bundle: first.url) == built)

        HelperBundleGenerator.forgetRecords()
        try plant(first.url)                                                     // planted between runs
        #expect(CodeIdentity.cdhash(bundle: first.url) != built)
        #expect(try generator.generate(label, icon: nil).outcome == .updated)
        #expect(CodeIdentity.cdhash(bundle: first.url) == built)
    }

    @Test func aBundleChangedDuringTheRunIsReplaced() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let generator = HelperBundleGenerator(template: try makeTemplate(in: dir), appsDirectory: dir.appendingPathComponent("Apps"),
                                              registerWithLaunchServices: false)
        let label = HelperLabel(key: "l06.beta", name: "L06 Beta")
        let first = try generator.generate(label, icon: nil)
        let built = try #require(CodeIdentity.cdhash(bundle: first.url))
        #expect(try generator.generate(label, icon: nil).outcome == .unchanged)  // recorded this run: fast path
        try plant(first.url)
        #expect(try generator.generate(label, icon: nil).outcome == .updated)
        #expect(CodeIdentity.cdhash(bundle: first.url) == built)
    }

    @Test func aBrokenTemplateIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = try makeTemplate(in: dir)
        let exe = template.appendingPathComponent("Contents/MacOS/helper")
        let handle = try FileHandle(forWritingTo: exe)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))                               // code changed after signing
        try handle.close()
        let generator = HelperBundleGenerator(template: template, appsDirectory: dir.appendingPathComponent("Apps"),
                                              registerWithLaunchServices: false)
        #expect(throws: HelperBundleError.self) { _ = try generator.generate(HelperLabel(key: "l06.gamma", name: "L06 Gamma"), icon: nil) }
        let apps = (FileManager.default.enumerator(atPath: dir.appendingPathComponent("Apps").path)?.allObjects as? [String]) ?? []
        #expect(!apps.contains { $0.hasSuffix(".app") })                         // nothing was generated from it
    }
}
