import Foundation
import ICAKit

/// `icactl pcap-decode <capture.pcap(ng)> [outdir]` (lab backlog 0.3): reads a packet capture (the VDA's pktmon
/// pcapng, tcpdump, Wireshark), reassembles every TCP connection on 1494/2598 (`ICA_PCAP_PORTS=…` for others) per
/// direction, unwraps CGP, and runs the relay decoder (`relay-decode`, D79) on each connection's ICA streams.
/// UDP datagrams on those ports (EDT, docs/80-edt.md) are listed with their timing in `udp.log`.
///
/// Per connection `<outdir>/tcpN-<port>/`: `ica-C.bin`, `ica-S.bin`, `cgp.log`, the relay decoder's `wd-C.log` /
/// `wd-S.log` / `.idx`, `wd-X.time` (seconds since the capture start per framed WD line) and `channels.txt`
/// (VC names from the client's bind table, packets and bytes per direction).
func pcapDecode(_ path: String, outdir: String?) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let frames: [CapturedFrame]
    do { frames = try CaptureFile.read(data) } catch { fail("\(path): \(error)") }
    var ports = ICACapture.defaultPorts
    if let list = ProcessInfo.processInfo.environment["ICA_PCAP_PORTS"] {
        ports = Set(list.split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) })
    }
    let capture = ICACapture(frames: frames, ports: ports)
    let out = outdir ?? ((path as NSString).deletingPathExtension + ".decode")
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let t0 = capture.firstTime ?? frames.first?.time ?? 0
    func rel(_ t: Double) -> String { String(format: "%.6f", t - t0) }
    func hex<S: Sequence>(_ b: S) -> String where S.Element == UInt8 { b.map { String(format: "%02x", $0) }.joined() }

    print("\(path): \(frames.count) frames, \(capture.skipped) not on ports \(ports.sorted().map(String.init).joined(separator: "/")), "
          + "\(capture.duplicateFrames) duplicate copies dropped, \(capture.reassembledDatagrams) IPv4 datagrams reassembled from fragments, \(capture.incompleteFragments) first fragments without the rest; \(capture.connections.count) TCP connections, "
          + "\(capture.datagrams.count) UDP datagrams")
    if let first = frames.map(\.time).min() {
        print("capture start \(Date(timeIntervalSince1970: first)) (times below: seconds since the first ICA packet)")
    }

    for (n, conn) in capture.connections.enumerated() {
        let dir = "\(out)/tcp\(n)-\(conn.server.port)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        print("\n== tcp\(n) \(conn.client) -> \(conn.server)  +\(rel(conn.firstTime))..+\(rel(conn.lastTime)) s"
              + (conn.reset ? " RST" : "") + (conn.c2s.sawSyn ? "" : " (no SYN: started before the capture)"))
        let c = ICAStreamExtract(conn.c2s.bytes), s = ICAStreamExtract(conn.s2c.bytes)
        for (name, d, x) in [("C", conn.c2s, c), ("S", conn.s2c, s)] {
            print("\(name): tcp \(d.bytes.count) B in \(d.segments) segments, \(d.duplicates) retransmitted/duplicate, "
                  + "\(d.gaps) gaps (\(d.missingBytes) B missing)\(d.sawFin ? ", FIN" : "")\(d.sawRst ? ", RST" : "")"
                  + (x.isCGP ? "; CGP cmds " + x.commands.sorted { $0.key < $1.key }.map { String(format: "0x%02x:%d", $0.key, $0.value) }.joined(separator: " ")
                     + ", ICA \(x.ica.count) B, leftover \(x.leftover)" : "; raw ICA"))
            FileManager.default.createFile(atPath: "\(dir)/ica-\(name).bin", contents: Data(x.ica), attributes: [.posixPermissions: 0o600])
        }
        let cgpLog = c.log.map { "C \($0)" } + s.log.map { "S \($0)" }
        try? cgpLog.joined(separator: "\n").write(toFile: "\(dir)/cgp.log", atomically: true, encoding: .utf8)
        guard c.ica.count > 6, s.ica.count > 6 else { print("too little ICA data to decode"); continue }
        guard relayDecode(dir, soft: true) else { continue }

        // Timing per framed WD line: wd-X.idx holds the end offset in ica-X.bin; map it to the TCP stream, then to
        // the capture time of the segment that completed it.
        for (name, d, x) in [("C", conn.c2s, c), ("S", conn.s2c, s)] {
            guard let idx = try? String(contentsOfFile: "\(dir)/wd-\(name).idx", encoding: .utf8) else { continue }
            let lines = idx.split(separator: "\n").map { line -> String in
                guard let icaEnd = Int(line), let tcp = x.tcpOffset(forICAEnd: icaEnd), let t = d.time(atEnd: tcp) else { return "?" }
                return rel(t)
            }
            try? lines.joined(separator: "\n").write(toFile: "\(dir)/wd-\(name).time", atomically: true, encoding: .utf8)
        }
        writeChannels(dir)
    }

    // UDP: one line per datagram, plus a summary per server port and direction.
    var lines: [String] = []
    struct Tally { var count = 0, bytes = 0, first = 0.0, last = 0.0, sizes: [Int: Int] = [:], heads: [String: Int] = [:] }
    var tallies: [String: Tally] = [:]
    var previous: [String: Double] = [:]
    // Bytes shown per datagram: 128, all with ICA_PCAP_UDP_FULL=1.
    let udpShown = ProcessInfo.processInfo.environment["ICA_PCAP_UDP_FULL"] == "1" ? Int.max : 128
    for d in capture.datagrams {
        let key = "\(d.server.port) \(d.fromClient ? "C>S" : "S>C") \(d.client.port)"
        let gap = previous[key].map { String(format: "%+.6f", d.time - $0) } ?? "first"
        previous[key] = d.time
        lines.append("+\(rel(d.time)) \(key) len \(d.payload.count)\(d.declaredLength.map { " (cut short, UDP length \($0))" } ?? "") gap \(gap) \(hex(d.payload.prefix(udpShown)))")
        var t = tallies[key] ?? Tally(first: d.time)
        t.count += 1; t.bytes += d.payload.count; t.last = d.time
        t.sizes[d.payload.count, default: 0] += 1
        t.heads[hex(d.payload.prefix(2)), default: 0] += 1
        tallies[key] = t
    }
    try? lines.joined(separator: "\n").write(toFile: "\(out)/udp.log", atomically: true, encoding: .utf8)
    if !tallies.isEmpty { print("\n== UDP (server port, direction, client port)") }
    for (key, t) in tallies.sorted(by: { $0.value.first < $1.value.first }) {
        let sizes = t.sizes.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        let heads = t.heads.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        print("\(key): \(t.count) datagrams, \(t.bytes) B, +\(rel(t.first))..+\(rel(t.last)) s; sizes \(sizes); first bytes \(heads)")
    }
    print("\noutput: \(out)")
}

/// `channels.txt`: VC number → name from the client's WD module bind table (INIT_RESPONSE in wd-C.log), with packets
/// and bytes per direction from the framed lines.
private func writeChannels(_ dir: String) {
    guard let clog = try? String(contentsOfFile: "\(dir)/wd-C.log", encoding: .utf8),
          let slog = try? String(contentsOfFile: "\(dir)/wd-S.log", encoding: .utf8) else { return }
    var names: [Int: String] = [:]
    var product = "?"
    for line in clog.split(separator: "\n") where line.hasPrefix("HS type 0x01 ") {
        let f = line.split(separator: " ")
        guard f.count == 6, let bytes = GDTEngine.parseHex(String(f[5])), bytes.count > 86, bytes[3] == WDModuleClass.wd.rawValue,
              let layout = try? WDModuleLayout(bytes) else { continue }
        product = "product id \(layout.productID), \(layout.bindTable.count) VCs in the bind table, caps "
            + layout.capabilities.map { String(format: "0x%02x", $0.id) }.joined(separator: " ")
        for e in layout.bindTable { names[Int(e.number)] = e.name.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces) }
    }
    func count(_ log: String) -> [Int: (Int, Int)] {
        var r: [Int: (Int, Int)] = [:]
        for line in log.split(separator: "\n") where line.hasPrefix("type ") {
            let f = line.split(separator: " ")
            guard f.count >= 6, f[2] == "ch", let ch = Int(f[3]), let len = Int(f[5]) else { continue }
            r[ch, default: (0, 0)].0 += 1
            r[ch, default: (0, 0)].1 += len
        }
        return r
    }
    let c = count(clog), s = count(slog)
    print("client WD module: \(product)")
    var out = ["# client WD module: \(product)", "ch name C-packets C-bytes S-packets S-bytes"]
    for ch in Set(c.keys).union(s.keys).sorted() {
        out.append("\(ch) \(names[ch] ?? "?") \(c[ch]?.0 ?? 0) \(c[ch]?.1 ?? 0) \(s[ch]?.0 ?? 0) \(s[ch]?.1 ?? 0)")
    }
    try? out.joined(separator: "\n").write(toFile: "\(dir)/channels.txt", atomically: true, encoding: .utf8)
    print("channels: " + out.dropFirst(2).map { l in let f = l.split(separator: " "); return "\(f[0]) \(f[1])" }.joined(separator: ", "))
}
