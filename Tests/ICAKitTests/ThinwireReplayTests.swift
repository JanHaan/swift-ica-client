import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ICAKit

/// Replays real channel-9 payloads captured with `ICA_CAPTURE_REPLAY=1 icactl session` into
/// `.session/replay/ch9-<seq>.bin` (plain runs write to `.session/last/`, so they never replace this set).
/// Skipped when no capture exists. Captures stay in `.session/` and are never copied into the repo.
/// Writes the final framebuffer to `.session/replay/replay-ch9.png`; THINWIRE_REPLAY_PNG=<path> writes a second copy,
/// THINWIRE_REPLAY_POINTERS=<prefix> writes every pointer shape.
@Test func thinwireReplayCapturedPayloads() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".session/replay")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("ch9-") && $0.hasSuffix(".bin") }
        .sorted { (Int($0.dropFirst(4).dropLast(4)) ?? 0) < (Int($1.dropFirst(4).dropLast(4)) ?? 0) }
    guard !names.isEmpty else { return }   // no capture: nothing to replay

    let payloads = try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
    let sink = ThinwireTestSink()
    let e = ThinwireEngine()
    sink.attach(e)
    for p in payloads { e.receive(p) }

    let s = e.stats
    let ops = s.opcodes.sorted { $0.key < $1.key }.map { String(format: "%02X:%d", $0.key, $0.value) }.joined(separator: " ")
    var report = "Thinwire replay: \(names.count) payloads, \(s.bytes) bytes, \(s.commands) commands, \(s.frames) frames, "
    report += "\(s.pictures) pictures, \(s.resyncs) resyncs, \(s.errors) errors, \(sink.pointers.count) pointer shapes, "
    report += "\(sink.updates.count) updates\n  opcodes: \(ops)"
    if let info = e.sessionInfo {
        report += "\n  INIT: \(info.width)x\(info.height) depth \(info.colorDepth) profile \(info.profile) cache 2^\(info.cacheLog2Bytes)/2^\(info.handleLog2)/\(info.maxObjectSize)"
    }
    let wd = sink.wdPackets.map { String(format: "%02X", $0.0) }.joined(separator: ",")
    report += "\n  replies: \(wd)"
    for l in sink.logs.prefix(30) { report += "\n  log: \(l)" }
    print(report)

    // Final framebuffer for inspection (stays in .session/, never in the repo).
    // Right after a present the front surface must equal the back buffer. A capture may end
    // mid-frame (live captures stop at 300 payloads), so replay once more and check at the last
    // completed END_OF_FRAME rather than after the trailing partial frame.
    let presents = sink.updates.count
    if presents > 0 {
        let check = ThinwireEngine()
        let checkSink = ThinwireTestSink()
        checkSink.attach(check)
        var seen = 0
        var mismatches: Int?
        check.onUpdate = { [unowned check] _ in
            seen += 1
            guard seen == presents, let fb = check.framebuffer else { return }
            var n = 0
            for y in stride(from: 0, to: fb.height, by: 3) {
                for x in stride(from: 0, to: fb.width, by: 3) where fb.pixel(x: x, y: y) != fb.backPixel(x: x, y: y) { n += 1 }
            }
            mismatches = n
        }
        for p in payloads { check.receive(p) }
        withExtendedLifetime(checkSink) {}
        #expect(mismatches == 0, "front differs from back at the last present (\(String(describing: mismatches)))")
    }
    if let fb = e.framebuffer {
        let out = dir.appendingPathComponent("replay-ch9.png")
        #expect(fb.writePNG(to: out))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        if let png = ProcessInfo.processInfo.environment["THINWIRE_REPLAY_PNG"] { fb.writePNG(to: URL(fileURLWithPath: png)) }
    }
    if let p = ProcessInfo.processInfo.environment["THINWIRE_REPLAY_POINTERS"] {
        for (i, ptr) in sink.pointers.enumerated() {
            guard let img = ptr.0,
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(p)-\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    #expect(e.sessionInfo != nil, "capture contains no INIT")
    #expect(s.resyncs == 0, "stream desynchronised")
}

/// Micro-benchmark: replays all ch9 captures several times and prints ms per frame and per payload.
/// Meaningful in release: `swift test -c release --filter Thinwire`. Skipped without captures.
@Test func thinwireReplayBenchmark() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".session/replay")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("ch9-") && $0.hasSuffix(".bin") }
        .sorted { (Int($0.dropFirst(4).dropLast(4)) ?? 0) < (Int($1.dropFirst(4).dropLast(4)) ?? 0) }
    guard !names.isEmpty else { return }
    let payloads = try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
    let rounds = 5
    var frames = 0, updates = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<rounds {
        let e = ThinwireEngine()
        e.onUpdate = { _ in updates += 1 }
        for p in payloads { e.receive(p) }
        frames += e.stats.frames
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    print(String(format: "Thinwire benchmark: %d rounds, %.1f ms total, %.3f ms/frame, %.3f ms/payload, %d updates",
                 rounds, ms, ms / Double(max(frames, 1)), ms / Double(rounds * payloads.count), updates))
}
