import Foundation
import Testing
@testable import ICAKit

// Session → Mac reads against a simulated host and link (virtual time; synthetic data). The host answers one request
// at a time, in order (docs/76 §7.17 [B]); its replies share one link of fixed bandwidth and latency.

private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
private func msg(_ cmd: UInt8, _ seq: UInt32, _ body: [UInt8]) -> [UInt8] { [cmd] + u32(seq) + u16(UInt16(7 + body.count)) + body }

/// A fake host with one file, a fake link and a virtual clock.
private final class SimulatedTransfer {
    let engine = GDTEngine()
    let data: [UInt8]
    let latency: Double          // one way, seconds
    let bandwidth: Double        // host → Mac, bytes per second
    /// The most bytes the host returns per Read (short reads below the asked count).
    let hostMaxRead: Int
    var now = 0.0
    private var linkFree = 0.0
    private var events: [(t: Double, n: Int, toHost: Bool, bytes: [UInt8])] = []
    private var order = 0
    private var position = 0
    var updates: [GDTFetchUpdate] = []
    var readsInFlightMax = 0
    var unexpected = 0
    var lastSent: UInt8?
    private var outstandingReads = 0

    init(size: Int, latency: Double, bandwidth: Double, hostMaxRead: Int = .max) {
        data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 11) }
        self.latency = latency
        self.bandwidth = bandwidth
        self.hostMaxRead = hostMaxRead
        engine.output = { [unowned self] in
            if case .channel(let d) = $0 {
                let m = GDTMessage([UInt8](d))!
                lastSent = m.command
                if m.command == 0x0C { outstandingReads += 1; readsInFlightMax = max(readsInFlightMax, outstandingReads) }
                schedule(now + latency, toHost: true, [UInt8](d))
            }
        }
        engine.onEvent = { [unowned self] in if case .file(.unexpected) = $0 { unexpected += 1 } }
    }

    private func schedule(_ t: Double, toHost: Bool, _ bytes: [UInt8]) {
        order += 1
        events.append((t, order, toHost, bytes))
    }

    /// The host's reply to one request, sent when the link is free.
    private func host(_ request: [UInt8]) {
        let m = GDTMessage(request)!
        var replies: [[UInt8]] = []
        let entry = ClipboardFileEntry(name: "big.bin", size: UInt64(data.count))
        switch m.command {
        case 0x14:
            let obj = Array(m.body[0..<8])
            let fgd = [UInt8](try! ClipboardFileGroup.build([entry]))
            replies = [msg(0x15, m.seq, obj + u32(UInt32(fgd.count))), msg(0x16, m.seq, obj + u16(UInt16(fgd.count)) + fgd),
                       msg(0x17, m.seq, obj + u32(0) + u32(1))]
        case 0x04:
            position = 0
            replies = [msg(0x05, m.seq, u32(0) + u64(0x77))]
        case 0x0C:
            let count = Int(LEBytes.u32(m.body, 8))
            let n = min(count, hostMaxRead, data.count - position)
            replies = [msg(0x0D, m.seq, u64(0x77) + u32(UInt32(n)))]
            var off = position
            while off < position + n {
                let k = min(4999 - 17, position + n - off)
                replies.append(msg(0x0E, m.seq, u64(0x77) + u16(UInt16(k)) + Array(data[off..<off + k])))
                off += k
            }
            replies.append(msg(0x0F, m.seq, u64(0x77) + u32(n == 0 ? 1 : 0)))
            position += n
        case 0x06:
            replies = [msg(0x07, m.seq, u64(0x77))]
        default: return
        }
        let bytes = replies.reduce(0) { $0 + $1.count }
        let depart = max(now, linkFree)
        linkFree = depart + Double(bytes) / bandwidth
        for r in replies { schedule(linkFree + latency, toHost: false, r) }
    }

    /// Runs the fetch to its end; returns the virtual seconds it took.
    func run(readSize: Int, readAhead: Int, into url: URL, cancelAt: Int? = nil) -> Double {
        engine.files.readSize = readSize
        engine.files.readAhead = readAhead
        engine.files.maxFileSize = .max
        engine.files.quarantineAgent = nil
        let entry = ClipboardFileEntry(name: "big.bin", size: UInt64(data.count))
        engine.files.fetch(.files(targets: [0: url], expect: [entry]), systemFormat: 1) { [unowned self] u in
            updates.append(u)
            if let cancelAt, case .progress(_, let n) = u, n >= cancelAt { engine.files.cancelFetch("user cancelled") }
        }
        while !events.isEmpty {
            let k = events.indices.min { (events[$0].t, events[$0].n) < (events[$1].t, events[$1].n) }!
            let e = events.remove(at: k)
            now = e.t
            if e.toHost { host(e.bytes) } else {
                if e.bytes.first == 0x0F { outstandingReads -= 1 }
                engine.receive(Data(e.bytes))
            }
        }
        return now
    }
}

@Suite struct GDTPipelineTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gdt-pipe-\(UUID().uuidString).bin")
    }

    /// 8 MiB over a 30 ms RTT link at 4 MiB/s: strict request/response with 64 KiB pays the RTT per read; bigger reads
    /// or reads in flight approach the link rate. Every variant stores the same bytes.
    @Test func throughputByReadSizeAndDepth() throws {
        let size = 8 << 20
        var times: [String: Double] = [:]
        for (label, readSize, depth) in [("64K×1", 65536, 1), ("1M×1", 1 << 20, 1), ("64K×4", 65536, 4), ("1M×2", 1 << 20, 2)] {
            let sim = SimulatedTransfer(size: size, latency: 0.015, bandwidth: 4 * 1_048_576)
            let url = temp()
            defer { try? FileManager.default.removeItem(at: url) }
            let t = sim.run(readSize: readSize, readAhead: depth, into: url)
            #expect(sim.updates.last == GDTFetchUpdate.done(files: 1), "\(label)")
            #expect(try Data(contentsOf: url) == Data(sim.data), "\(label)")
            #expect(sim.readsInFlightMax == depth, "\(label)")
            times[label] = t
        }
        let rate = { (label: String) in Double(size) / 1_048_576 / times[label]! }
        print("GDT pipeline (virtual): " + times.keys.sorted().map { String(format: "%@ %.2f MiB/s", $0, rate($0)) }.joined(separator: ", "))
        // Measured (virtual): 64K×1 1.34 MiB/s, 1M×1 3.38, 64K×4 3.76, 1M×2 3.76 (link 4 MiB/s incl. headers).
        #expect(rate("64K×1") < 1.6)
        #expect(rate("1M×1") > 3.2 && rate("64K×4") > 3.6 && rate("1M×2") > 3.6)
    }

    /// Cancel with reads in flight: the stream is released, the partial file removed, late replies dropped quietly.
    @Test func cancelWithReadsInFlight() throws {
        let sim = SimulatedTransfer(size: 2 << 20, latency: 0.01, bandwidth: 4_194_304)
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = sim.run(readSize: 65536, readAhead: 4, into: url, cancelAt: 300_000)
        #expect(sim.updates.last == GDTFetchUpdate.failed("user cancelled"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(sim.lastSent == 0x06 && sim.unexpected == 0 && !sim.engine.files.isFetching)
    }

    /// The host returns less than asked: reads in flight still land in order and the file is complete.
    @Test func shortReadsInFlight() throws {
        let sim = SimulatedTransfer(size: 300_000, latency: 0.01, bandwidth: 4_194_304, hostMaxRead: 20_000)
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = sim.run(readSize: 65536, readAhead: 3, into: url)
        #expect(sim.updates.last == GDTFetchUpdate.done(files: 1))
        #expect(try Data(contentsOf: url) == Data(sim.data))
    }
}
