import Foundation
import ICAKit

/// `icactl relay-decode <dir>`: decodes `ica-C.bin` / `ica-S.bin` written by scripts/cgp-split.py from a
/// scripts/cgp-relay.py recording of the stock client's own session (black box, §69d(3)).
/// Writes `wd-C.log` / `wd-S.log` (one line per WD packet) and prints a per-channel summary.
/// `soft` (pcap-decode, many connections per capture): a stream that cannot be decoded prints why and returns false
/// instead of exiting.
@discardableResult
func relayDecode(_ dir: String, soft: Bool = false) -> Bool {
    func giveUp(_ message: String) -> Bool {
        if soft { print(message); return false }
        fail(message)
    }
    func load(_ name: String) -> [UInt8] {
        guard let d = FileManager.default.contents(atPath: "\(dir)/\(name)") else { fail("missing \(dir)/\(name)") }
        return [UInt8](d)
    }
    let c2s = load("ica-C.bin"), s2c = load("ica-S.bin")
    let detect: [UInt8] = [0x7F, 0x7F, 0x49, 0x43, 0x41, 0x00]

    struct Direction {
        var name: String
        var handshake: [(type: UInt8, payload: [UInt8])] = []
        var framed: [UInt8] = []
        /// Offset of `framed` in the direction's ica-X.bin (for the timing index, `wd-X.idx`).
        var framedStart = 0
    }

    // Handshake (unframed) part of each direction.
    func split(_ bytes: [UInt8], name: String, stop: @escaping (WDPacket) -> Bool) -> Direction {
        var b = bytes
        if b.starts(with: detect) { b.removeFirst(detect.count) }
        var parser = WDStreamParser()
        var stopped = false
        let (packets, rest) = parser.feed(b) { p in
            if stop(p) { stopped = true; return true }
            return false
        }
        if !stopped { print("\(name): handshake did not end (\(packets.count) packets)") }
        return Direction(name: name, handshake: packets.map { ($0.type, $0.payload) }, framed: rest, framedStart: bytes.count - rest.count)
    }
    let server = split(s2c, name: "S") { $0.type == WDPacketType.initConnect && $0.payload.count > 2 && $0.payload[2] == 0 }
    // Client handshake: `type u16-length payload` (INIT_RESPONSE 0x01 … INIT_CONNECT_RESPONSE 04 00 00).
    var client = Direction(name: "C")
    do {
        var b = c2s
        if b.starts(with: detect) { b.removeFirst(detect.count) }
        var i = 0
        while i + 3 <= b.count {
            let type = b[i], n = Int(b[i + 1]) | Int(b[i + 2]) << 8
            guard i + 3 + n <= b.count else { break }
            client.handshake.append((type, Array(b[(i + 3)..<(i + 3 + n)])))
            i += 3 + n
            if type == WDPacketType.initConnectResponse { break }
        }
        client.framed = Array(b[i...])
        client.framedStart = c2s.count - client.framed.count
    }

    // Negotiated parameters from the server's INIT_CONNECTs (WD class).
    var reducer: (UInt16, UInt8, UInt8) = (0, 0, 0)
    var caps: [WDCapability] = []
    for p in server.handshake where p.type == WDPacketType.initConnect {
        let q = p.payload
        guard q.count >= 36, q[3] == WDModuleClass.wd.rawValue else { continue }
        reducer = (UInt16(q[30]) | UInt16(q[31]) << 8, q[26], q[27])
        let len = Int(q[32]) | Int(q[33]) << 8, off = Int(q[34]) | Int(q[35]) << 8
        if len > 0, off + len <= q.count, let c = try? WDCapabilityBlock.parse(Array(q[off..<(off + len)])) { caps = c }
    }
    let htNegotiated = caps.contains { $0.id == WDCapability.highThroughput }
    let v3 = reducer.0 == 3
    print("negotiated: reducer v\(reducer.0) reducerPower \(reducer.1) expanderPower \(reducer.2), HT cap \(htNegotiated)")
    print("final caps: " + caps.map { String(format: "0x%02x", $0.id) }.joined(separator: " "))

    // Frames of each direction.
    var fa = WDFrameAssembler(), fb = WDFrameAssembler()
    let clientFrames = fa.feed(client.framed), serverFrames = fb.feed(server.framed)

    // Key from the client's PDCRYPT1 reply (04 00 key).
    guard let keyFrame = clientFrames.first(where: { $0.count == 3 && $0[0] == 0x04 }) else { return giveUp("no PDCRYPT1 key reply in client frames") }
    let key = keyFrame[2]

    // Client direction: mirror of the server's receive side.
    var clientPlain: [[UInt8]] = []
    // End offset in ica-X.bin of the raw frame each plain frame came from (timing index, `wd-X.idx`).
    var clientPlainEnd: [Int] = [], serverPlainEnd: [Int] = []
    var clientCipher = WDBasicCipher(key: key)
    var clientPermanent: Bool? = nil
    var clientEnd = client.framedStart
    for f in clientFrames {
        clientEnd += 2 + f.count
        defer { while clientPlainEnd.count < clientPlain.count { clientPlainEnd.append(clientEnd) } }
        if let perm = clientPermanent {
            var b = f
            if perm { clientCipher.decrypt(&b) }
            clientPlain.append(b); continue
        }
        guard let h = f.first else { continue }
        var body = Array(f.dropFirst())
        switch h {
        case 0x00: clientPlain.append(body)
        case 0x01: clientCipher.decrypt(&body); clientPlain.append(body)
        case 0x04: break
        case 0x06, 0x07: clientCipher.decrypt(&body); clientPermanent = h == 0x07
        default: print("C: unknown crypt header \(h)")
        }
    }
    var serverPD = WDEncryptionPD(key: key)
    var serverPlain: [[UInt8]] = []
    var serverEnd = server.framedStart
    for f in serverFrames {
        serverEnd += 2 + f.count
        do {
            for o in try serverPD.receive(f) { if case .data(let d) = o { serverPlain.append(d); serverPlainEnd.append(serverEnd) } }
        } catch { print("S: crypt \(error)") }
    }
    print("frames: C \(clientFrames.count) (pending \(fa.pendingBytes)), S \(serverFrames.count) (pending \(fb.pendingBytes)); key \(String(format: "0x%02x", key))")

    // Coder powers per direction: C→S uses the reducer power (INIT_CONNECT byte 26), S→C the expander power
    // (byte 27), as seen from the client. ICA_V3_SWAP=1 tries the other assignment.
    let env = ProcessInfo.processInfo.environment
    let swap = env["ICA_V3_SWAP"] == "1"
    let cPower = Int(swap ? reducer.2 : reducer.1), sPower = Int(swap ? reducer.1 : reducer.2)
    // Readings of §12.3 (WDV3CoderOptions), switchable for experiments:
    // ICA_V3_OPTS="table=0,match=0,halve=0,countdown=50,period=50,max=500,flag=0,desc=1".
    var options = WDV3CoderOptions()
    for item in (env["ICA_V3_OPTS"] ?? "").split(separator: ",") {
        let kv = item.split(separator: "=")
        guard kv.count == 2, let v = Int(kv[1]) else { continue }
        switch kv[0] {
        case "table": options.sharedContextTable = v != 0
        case "match": options.sharedMatchState = v != 0
        case "halve": options.halveAtInit = v != 0
        case "countdown": options.initialCountdown = v
        case "period": options.initialPeriod = v
        case "max": options.maxPeriod = v
        case "flag": options.missFlagInLiteral = v != 0
        case "desc": options.leavesAscending = v == 0
        default: print("unknown ICA_V3_OPTS key \(kv[0])")
        }
    }
    let traceFrames = Int(env["ICA_V3_TRACE"] ?? "") ?? 0  // per-segment trace of the first n frames

    struct Expanded {
        var packets: [WDPacket] = []
        /// Plain-frame index each packet completed in.
        var frameOf: [Int] = []
        var failed = 0
        var firstFailure: Int?
        var errors: [String] = []
        var expander: WDV3Expander?
    }
    /// One expander (and coder) per direction, frames in order: the coder state carries across frames.
    func expandAll(_ frames: [[UInt8]], name: String, power: Int, ht: Bool, trace: Bool) -> Expanded {
        var result = Expanded()
        guard var expander = try? WDV3Expander(power: power > 0 ? power : nil, options: options) else {
            fail("\(name): no V3 coder for power \(power)")
        }
        var frameNo = 0
        if trace && traceFrames > 0 { expander.trace = { line in if frameNo < traceFrames { print("\(name)#\(frameNo) \(line)") } } }
        var parser = WDStreamParser()
        for (i, f) in frames.enumerated() {
            frameNo = i
            var plain = f
            if ht { guard let (p, _) = WDHighThroughput.strip(f) else { continue }; plain = p }
            var stream = plain
            if v3 {
                do { stream = try expander.expand(plain) } catch {
                    result.failed += 1
                    if result.firstFailure == nil { result.firstFailure = i }
                    if result.errors.count < 5 { result.errors.append("\(name)#\(i): V3 \(error)") }
                    parser.reset()
                    continue
                }
            }
            let got = parser.feed(stream).packets
            result.packets += got
            result.frameOf += Array(repeating: i, count: got.count)
        }
        result.expander = expander
        return result
    }
    // HT header: the stock client may run it although cap 0x10 is not in the final list (docs/30 §8.3
    // quirk), so unless negotiated, both readings are tried and the one with fewer V3 failures wins.
    func expandDirection(_ frames: [[UInt8]], name: String, power: Int) -> Expanded {
        let ht: Bool
        if let forced = env["ICA_HT"] { ht = forced == "1" }
        else if htNegotiated || !v3 { ht = htNegotiated }
        else {
            let on = expandAll(frames, name: name, power: power, ht: true, trace: false).failed
            let off = expandAll(frames, name: name, power: power, ht: false, trace: false).failed
            ht = on <= off
        }
        let r = expandAll(frames, name: name, power: power, ht: ht, trace: true)
        for e in r.errors { print(e) }
        if let x = r.expander {
            print("\(name): HT header \(ht ? "on" : "off"), coder power \(power), segments compressed \(x.compressedSegments) "
                  + "recompress \(x.recompressSegments) thinwire-aware(0x3D) \(x.thinwireAwareSegments); "
                  + "frames by leftover bytes \(x.leftoverBytes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")); specials "
                  + x.specialLog.map { "\($0.command)(\($0.arguments.map(String.init).joined(separator: ",")))" }.joined(separator: " "))
        }
        return r
    }
    let c = expandDirection(clientPlain, name: "C", power: cPower)
    let s = expandDirection(serverPlain, name: "S", power: sPower)
    let cPackets = c.packets, sPackets = s.packets
    print("V3 failures: C \(c.failed)\(c.firstFailure.map { " (first at frame \($0))" } ?? ""), "
          + "S \(s.failed)\(s.firstFailure.map { " (first at frame \($0))" } ?? "")")

    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    func write(_ name: String, _ handshake: [(type: UInt8, payload: [UInt8])], _ packets: [WDPacket]) {
        var lines: [String] = []
        for p in handshake { lines.append("HS type \(String(format: "0x%02x", p.type)) len \(p.payload.count) \(hex(p.payload))") }
        for p in packets {
            let ch = p.channel.map { "ch \($0)" } ?? "--"
            lines.append("type \(String(format: "0x%02x", p.type)) \(ch) len \(p.payload.count) \(hex(p.payload))")
        }
        try? lines.joined(separator: "\n").write(toFile: "\(dir)/wd-\(name).log", atomically: true, encoding: .utf8)
        var perChannel: [String: (Int, Int)] = [:]
        for p in packets {
            let k = p.channel.map { "ch\($0)" } ?? String(format: "t%02x", p.type)
            perChannel[k, default: (0, 0)].0 += 1
            perChannel[k, default: (0, 0)].1 += p.payload.count
        }
        print("\(name): \(handshake.count) handshake packets, \(packets.count) framed: "
              + perChannel.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.0)/\($0.value.1)B" }.joined(separator: " "))
    }
    write("C", client.handshake, cPackets)
    write("S", server.handshake, sPackets)
    // Timing index: per framed packet line of wd-X.log, the end offset of its frame in ica-X.bin (scripts/relay-timing.py
    // maps it to the record time).
    func index(_ name: String, _ r: Expanded, _ ends: [Int]) {
        let lines = r.frameOf.map { $0 < ends.count ? String(ends[$0]) : "?" }
        try? lines.joined(separator: "\n").write(toFile: "\(dir)/wd-\(name).idx", atomically: true, encoding: .utf8)
    }
    index("C", c, clientPlainEnd)
    index("S", s, serverPlainEnd)
    return true
}
