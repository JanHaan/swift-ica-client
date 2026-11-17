import Foundation

// Offline reader for packet captures of ICA sessions (lab backlog 0.3): pcap and pcapng files (as written by the
// VDA's pktmon, tcpdump or Wireshark), Ethernet / raw IP / BSD loopback, IPv4/IPv6, TCP reassembly per direction,
// CGP unwrapping into the per-direction ICA byte streams that `icactl relay-decode` reads (D79), and UDP datagrams
// (EDT, docs/80-edt.md) with their timing. No I/O; the caller reads the file.

/// One captured frame: timestamp in seconds since the epoch and the link-layer bytes.
public struct CapturedFrame: Sendable {
    public var time: Double
    public var linkType: UInt32
    public var bytes: [UInt8]
    public init(time: Double, linkType: UInt32, bytes: [UInt8]) {
        self.time = time
        self.linkType = linkType
        self.bytes = bytes
    }
}

public enum CaptureFileError: Error, CustomStringConvertible, Equatable {
    case unknownFormat(UInt32)
    case truncated(at: Int)
    case badBlock(type: UInt32, at: Int)
    public var description: String {
        switch self {
        case .unknownFormat(let m): return String(format: "not a pcap/pcapng file (magic 0x%08x)", m)
        case .truncated(let at): return "file truncated at offset \(at)"
        case .badBlock(let t, let at): return String(format: "bad pcapng block 0x%08x at offset %d", t, at)
        }
    }
}

/// Link types handled by `CapturedPacket.parse` (LINKTYPE_* values from the public tcpdump.org list).
public enum CaptureLinkType {
    public static let null: UInt32 = 0
    public static let ethernet: UInt32 = 1
    public static let raw: UInt32 = 101
    public static let rawAlt: UInt32 = 12
    public static let ipv4: UInt32 = 228
    public static let ipv6: UInt32 = 229
}

/// Reads classic pcap (both byte orders, micro- and nanosecond magic) and pcapng (SHB/IDB/EPB/SPB/obsolete PB,
/// both byte orders, `if_tsresol`, several sections). Unknown blocks are skipped.
public enum CaptureFile {
    public static func read(_ data: Data) throws -> [CapturedFrame] {
        let b = [UInt8](data)
        guard b.count >= 4 else { throw CaptureFileError.truncated(at: 0) }
        let le = u32(b, 0, little: true)
        switch le {
        case 0x0A0D_0D0A: return try readPcapng(b)
        case 0xA1B2_C3D4, 0xA1B2_3C4D: return try readPcap(b, little: true, nano: le == 0xA1B2_3C4D)
        case 0xD4C3_B2A1, 0x4D3C_B2A1: return try readPcap(b, little: false, nano: le == 0x4D3C_B2A1)
        default: throw CaptureFileError.unknownFormat(le)
        }
    }

    static func u16(_ b: [UInt8], _ i: Int, little: Bool) -> UInt16 {
        little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    static func u32(_ b: [UInt8], _ i: Int, little: Bool) -> UInt32 {
        little ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            : UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func readPcap(_ b: [UInt8], little: Bool, nano: Bool) throws -> [CapturedFrame] {
        guard b.count >= 24 else { throw CaptureFileError.truncated(at: b.count) }
        let link = u32(b, 20, little: little) & 0x0FFF_FFFF
        var frames: [CapturedFrame] = []
        var i = 24
        while i + 16 <= b.count {
            let sec = u32(b, i, little: little), frac = u32(b, i + 4, little: little)
            let incl = Int(u32(b, i + 8, little: little))
            guard i + 16 + incl <= b.count else { throw CaptureFileError.truncated(at: i) }
            let t = Double(sec) + Double(frac) / (nano ? 1e9 : 1e6)
            frames.append(CapturedFrame(time: t, linkType: link, bytes: Array(b[(i + 16)..<(i + 16 + incl)])))
            i += 16 + incl
        }
        return frames
    }

    private struct Interface {
        var linkType: UInt32
        var unitsPerSecond: Double = 1e6
        var offset: Double = 0
    }

    private static func readPcapng(_ b: [UInt8]) throws -> [CapturedFrame] {
        var frames: [CapturedFrame] = []
        var interfaces: [Interface] = []
        var little = true
        var i = 0
        while i + 12 <= b.count {
            var type = u32(b, i, little: little)
            if type == 0x0A0D_0D0A {
                // The byte-order magic decides the section's byte order.
                guard i + 12 <= b.count else { throw CaptureFileError.truncated(at: i) }
                let bom = u32(b, i + 8, little: true)
                if bom == 0x1A2B_3C4D { little = true } else if bom == 0x4D3C_2B1A { little = false } else {
                    throw CaptureFileError.badBlock(type: type, at: i)
                }
                type = 0x0A0D_0D0A
                interfaces = []
            }
            let total = Int(u32(b, i + 4, little: little))
            guard total >= 12, total % 4 == 0 else { throw CaptureFileError.badBlock(type: type, at: i) }
            guard i + total <= b.count else { throw CaptureFileError.truncated(at: i) }
            let body = Array(b[(i + 8)..<(i + total - 4)])
            switch type {
            case 0x0000_0001:  // Interface Description Block
                guard body.count >= 8 else { throw CaptureFileError.badBlock(type: type, at: i) }
                var iface = Interface(linkType: UInt32(u16(body, 0, little: little)))
                forEachOption(body, from: 8, little: little) { code, value in
                    if code == 9, let r = value.first {  // if_tsresol
                        iface.unitsPerSecond = r & 0x80 == 0 ? pow(10, Double(r & 0x7F)) : pow(2, Double(r & 0x7F))
                    } else if code == 14, value.count == 8 {  // if_tsoffset (seconds)
                        let hi = UInt64(u32(value, little ? 4 : 0, little: little)), lo = UInt64(u32(value, little ? 0 : 4, little: little))
                        iface.offset = Double(Int64(bitPattern: hi << 32 | lo))
                    }
                }
                interfaces.append(iface)
            case 0x0000_0006, 0x0000_0002:  // Enhanced Packet Block, obsolete Packet Block
                guard body.count >= 20 else { throw CaptureFileError.badBlock(type: type, at: i) }
                let ifIndex = type == 6 ? Int(u32(body, 0, little: little)) : Int(u16(body, 0, little: little))
                let hi = UInt64(u32(body, 4, little: little)), lo = UInt64(u32(body, 8, little: little))
                let captured = Int(u32(body, 12, little: little))
                guard 20 + captured <= body.count else { throw CaptureFileError.badBlock(type: type, at: i) }
                let iface = ifIndex < interfaces.count ? interfaces[ifIndex] : Interface(linkType: CaptureLinkType.ethernet)
                let t = Double(hi << 32 | lo) / iface.unitsPerSecond + iface.offset
                frames.append(CapturedFrame(time: t, linkType: iface.linkType, bytes: Array(body[20..<(20 + captured)])))
            case 0x0000_0003:  // Simple Packet Block: no timestamp, interface 0
                guard body.count >= 4 else { throw CaptureFileError.badBlock(type: type, at: i) }
                let link = interfaces.first?.linkType ?? CaptureLinkType.ethernet
                let original = Int(u32(body, 0, little: little))
                frames.append(CapturedFrame(time: frames.last?.time ?? 0, linkType: link,
                                            bytes: Array(body[4..<min(body.count, 4 + original)])))
            default:
                break
            }
            i += total
        }
        return frames
    }

    private static func forEachOption(_ body: [UInt8], from start: Int, little: Bool, _ visit: (UInt16, [UInt8]) -> Void) {
        var j = start
        while j + 4 <= body.count {
            let code = u16(body, j, little: little), len = Int(u16(body, j + 2, little: little))
            if code == 0 { return }
            guard j + 4 + len <= body.count else { return }
            visit(code, Array(body[(j + 4)..<(j + 4 + len)]))
            j += 4 + ((len + 3) & ~3)
        }
    }
}

/// An IP endpoint as text ("10.77.0.12") plus a port.
public struct CaptureEndpoint: Hashable, Sendable, CustomStringConvertible {
    public var address: String
    public var port: UInt16
    public init(_ address: String, _ port: UInt16) {
        self.address = address
        self.port = port
    }
    public var description: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}

/// A TCP segment or UDP datagram out of one frame.
public struct CapturedPacket: Sendable {
    public enum Transport: Sendable, Equatable { case tcp, udp }
    public var time: Double
    public var transport: Transport
    public var source: CaptureEndpoint
    public var destination: CaptureEndpoint
    /// IPv4 identification (nil for IPv6): with the payload, it tells a duplicate (pktmon logs a packet at more than
    /// one point of the stack) from a retransmission.
    public var ipID: UInt16?
    public var seq: UInt32 = 0
    public var ack: UInt32 = 0
    /// TCP flags byte (FIN 0x01, SYN 0x02, RST 0x04, PSH 0x08, ACK 0x10).
    public var flags: UInt8 = 0
    public var payload: [UInt8]
    /// UDP: the length the header declares (more than `payload` for a datagram cut short, e.g. a lone first fragment).
    public var udpLength: Int?

    public var syn: Bool { flags & 0x02 != 0 }
    public var fin: Bool { flags & 0x01 != 0 }
    public var rst: Bool { flags & 0x04 != 0 }

    /// Offset and ethertype (0x0800 / 0x86DD) of the IP header in a frame.
    static func ipHeader(_ frame: CapturedFrame) -> (offset: Int, etherType: UInt16)? {
        let b = frame.bytes
        var i = 0
        var etherType: UInt16
        switch frame.linkType {
        case CaptureLinkType.ethernet:
            guard b.count >= 14 else { return nil }
            etherType = CaptureFile.u16(b, 12, little: false)
            i = 14
            while etherType == 0x8100 || etherType == 0x88A8 {  // VLAN tags
                guard b.count >= i + 4 else { return nil }
                etherType = CaptureFile.u16(b, i + 2, little: false)
                i += 4
            }
        case CaptureLinkType.null:
            guard b.count >= 4 else { return nil }
            let family = CaptureFile.u32(b, 0, little: true) & 0xFFFF
            let familyBE = CaptureFile.u32(b, 0, little: false)
            etherType = family == 2 || familyBE == 2 ? 0x0800 : 0x86DD
            i = 4
        case CaptureLinkType.raw, CaptureLinkType.rawAlt, CaptureLinkType.ipv4, CaptureLinkType.ipv6:
            guard let v = b.first else { return nil }
            etherType = v >> 4 == 6 ? 0x86DD : 0x0800
        default:
            return nil
        }
        return (i, etherType)
    }

    /// An IPv4 fragment: the reassembly key, its byte offset, whether more follow, the IP header and the payload.
    struct Fragment {
        var key: String
        var offset: Int
        var more: Bool
        var header: [UInt8]
        var payload: [UInt8]
    }

    static func fragment(_ frame: CapturedFrame) -> Fragment? {
        guard let (i, etherType) = ipHeader(frame), etherType == 0x0800 else { return nil }
        let b = frame.bytes
        guard b.count >= i + 20, b[i] >> 4 == 4 else { return nil }
        let field = CaptureFile.u16(b, i + 6, little: false)
        let more = field & 0x2000 != 0, offset = Int(field & 0x1FFF) * 8
        guard more || offset > 0 else { return nil }
        let ihl = Int(b[i] & 0x0F) * 4, total = Int(CaptureFile.u16(b, i + 2, little: false))
        let end = total >= ihl ? min(b.count, i + total) : b.count
        guard i + ihl <= end else { return nil }
        let key = b[(i + 12)..<(i + 20)].map(String.init).joined(separator: ".") + "/\(b[i + 9])/\(CaptureFile.u16(b, i + 4, little: false))"
        return Fragment(key: key, offset: offset, more: more, header: Array(b[i..<(i + ihl)]), payload: Array(b[(i + ihl)..<end]))
    }

    /// The TCP or UDP packet in a frame, or nil (other protocols, IP fragments: see `ICACapture`, truncated frames).
    public static func parse(_ frame: CapturedFrame) -> CapturedPacket? {
        let b = frame.bytes
        guard let (start, etherType) = ipHeader(frame) else { return nil }
        var i = start
        var proto: UInt8
        var src: String, dst: String
        var ipID: UInt16?
        var end: Int
        if etherType == 0x0800 {
            guard b.count >= i + 20, b[i] >> 4 == 4 else { return nil }
            let ihl = Int(b[i] & 0x0F) * 4
            let totalLength = Int(CaptureFile.u16(b, i + 2, little: false))
            let fragment = CaptureFile.u16(b, i + 6, little: false)
            guard fragment & 0x3FFF == 0 else { return nil }  // a fragment: reassembled by ICACapture
            ipID = CaptureFile.u16(b, i + 4, little: false)
            proto = b[i + 9]
            src = b[(i + 12)..<(i + 16)].map(String.init).joined(separator: ".")
            dst = b[(i + 16)..<(i + 20)].map(String.init).joined(separator: ".")
            // Offloaded captures may carry total length 0 (TSO): then the frame end counts.
            end = totalLength >= ihl ? min(b.count, i + totalLength) : b.count
            i += ihl
        } else if etherType == 0x86DD {
            guard b.count >= i + 40 else { return nil }
            let payloadLength = Int(CaptureFile.u16(b, i + 4, little: false))
            proto = b[i + 6]
            func v6(_ o: Int) -> String {
                stride(from: o, to: o + 16, by: 2).map { String(CaptureFile.u16(b, $0, little: false), radix: 16) }.joined(separator: ":")
            }
            src = v6(i + 8)
            dst = v6(i + 24)
            end = payloadLength > 0 ? min(b.count, i + 40 + payloadLength) : b.count
            i += 40
            // Hop-by-hop, routing, destination options: skip.
            while [0, 43, 60].contains(proto), b.count >= i + 8 {
                proto = b[i]
                i += (Int(b[i + 1]) + 1) * 8
            }
        } else {
            return nil
        }
        guard i <= end else { return nil }
        if proto == 6 {
            guard end >= i + 20 else { return nil }
            let off = Int(b[i + 12] >> 4) * 4
            guard off >= 20, i + off <= end else { return nil }
            return CapturedPacket(time: frame.time, transport: .tcp,
                                  source: CaptureEndpoint(src, CaptureFile.u16(b, i, little: false)),
                                  destination: CaptureEndpoint(dst, CaptureFile.u16(b, i + 2, little: false)),
                                  ipID: ipID,
                                  seq: CaptureFile.u32(b, i + 4, little: false), ack: CaptureFile.u32(b, i + 8, little: false),
                                  flags: b[i + 13], payload: Array(b[(i + off)..<end]))
        }
        if proto == 17 {
            guard end >= i + 8 else { return nil }
            let udpLength = Int(CaptureFile.u16(b, i + 4, little: false))
            let stop = udpLength >= 8 ? min(end, i + udpLength) : end
            return CapturedPacket(time: frame.time, transport: .udp,
                                  source: CaptureEndpoint(src, CaptureFile.u16(b, i, little: false)),
                                  destination: CaptureEndpoint(dst, CaptureFile.u16(b, i + 2, little: false)),
                                  ipID: ipID, payload: Array(b[(i + 8)..<stop]), udpLength: udpLength - 8)
        }
        return nil
    }
}

/// One direction of a TCP connection, reassembled in sequence order: retransmissions and duplicates are dropped,
/// out-of-order segments wait for the gap to fill. A gap that never fills (a packet the capture missed) is skipped
/// at the end and counted in `gaps` / `missingBytes`.
public struct TCPDirection: Sendable {
    public private(set) var bytes: [UInt8] = []
    /// (end offset in `bytes`, capture time) per appended segment, for timing.
    public private(set) var timeline: [(end: Int, time: Double)] = []
    public private(set) var segments = 0
    public private(set) var duplicates = 0
    public private(set) var gaps = 0
    public private(set) var missingBytes = 0
    public private(set) var sawSyn = false
    public private(set) var sawFin = false
    public private(set) var sawRst = false
    public private(set) var firstTime: Double?
    /// Sequence number of `bytes[0]`.
    private var base: UInt32?
    private var pending: [UInt32: (time: Double, payload: [UInt8])] = [:]

    public init() {}

    /// Stream offset of a sequence number (wrapping arithmetic), relative to the first data byte.
    private func offset(_ seq: UInt32) -> Int { Int(Int32(bitPattern: seq &- (base ?? seq))) }

    public mutating func add(_ p: CapturedPacket) {
        if firstTime == nil { firstTime = p.time }
        if p.syn {
            sawSyn = true
            if base == nil || bytes.isEmpty { base = p.seq &+ 1 }
        }
        if p.fin { sawFin = true }
        if p.rst { sawRst = true }
        guard !p.payload.isEmpty else { return }
        segments += 1
        if base == nil { base = p.seq }
        let seq = p.syn ? p.seq &+ 1 : p.seq
        if offset(seq) + p.payload.count <= bytes.count { duplicates += 1; return }
        if let old = pending[seq], old.payload.count >= p.payload.count { duplicates += 1; return }
        pending[seq] = (p.time, p.payload)
        drain(now: p.time)
    }

    /// Appends every pending segment that is now contiguous; its time is when it became contiguous (`now`).
    private mutating func drain(now: Double? = nil) {
        var progressed = true
        while progressed {
            progressed = false
            for (seq, seg) in pending {
                let start = offset(seq), stop = start + seg.payload.count
                if stop <= bytes.count { pending[seq] = nil; progressed = true; continue }
                if start <= bytes.count {
                    bytes += seg.payload[(bytes.count - start)...]
                    timeline.append((bytes.count, max(seg.time, now ?? seg.time)))
                    pending[seq] = nil
                    progressed = true
                }
            }
        }
    }

    /// Skips the remaining holes (lost segments), appending what lies after them in order.
    public mutating func finish() {
        drain()
        while let next = pending.keys.min(by: { offset($0) < offset($1) }) {
            let start = offset(next)
            if start > bytes.count {
                gaps += 1
                missingBytes += start - bytes.count
                // Zero fill keeps later offsets right; decoders see garbage there, which the gap count explains.
                bytes += [UInt8](repeating: 0, count: start - bytes.count)
            }
            drain()
        }
    }

    /// Capture time of the segment that brought stream offset `offset` (the byte before it) into the stream.
    public func time(atEnd offset: Int) -> Double? {
        var lo = 0, hi = timeline.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].end < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < timeline.count ? timeline[lo].time : timeline.last?.time
    }
}

/// A reassembled TCP connection. "Client" is the side not on a server port (or the SYN sender).
public struct TCPConnection: Sendable {
    public var client: CaptureEndpoint
    public var server: CaptureEndpoint
    public var c2s = TCPDirection()
    public var s2c = TCPDirection()
    public var firstTime: Double
    public var lastTime: Double
    public var reset = false
}

/// A UDP datagram on a watched port.
public struct CapturedDatagram: Sendable {
    public var time: Double
    public var fromClient: Bool
    public var client: CaptureEndpoint
    public var server: CaptureEndpoint
    public var payload: [UInt8]
    /// Set when only the first IP fragment was captured: the full UDP payload length. pktmon's port filter drops the
    /// later fragments (they carry no UDP header).
    public var declaredLength: Int?
}

/// The ICA-relevant traffic of a capture: TCP connections and UDP datagrams with one end on a server port.
public struct ICACapture: Sendable {
    public static let defaultPorts: Set<UInt16> = [1494, 2598]
    public var connections: [TCPConnection] = []
    public var datagrams: [CapturedDatagram] = []
    public var frames = 0
    public var skipped = 0
    /// Frames dropped as copies of the previous ones (same IP id, ports and payload).
    public var duplicateFrames = 0
    /// IPv4 datagrams put back together from fragments.
    public var reassembledDatagrams = 0
    /// First fragments without the rest (kept cut short, `CapturedDatagram.declaredLength` set).
    public var incompleteFragments = 0
    public var firstTime: Double?

    public init(frames input: [CapturedFrame], ports: Set<UInt16> = ICACapture.defaultPorts) {
        frames = input.count
        var index: [String: Int] = [:]
        // pktmon logs one packet at several components: drop exact copies seen shortly before.
        var recent: [Int: Double] = [:]
        // IPv4 fragments (EDT sends 1500-byte packets; the tailnet path MTU is smaller) are put back together into one
        // raw-IP frame at the time of the last fragment. A first fragment whose rest never came (pktmon's port filter
        // drops later fragments: they carry no UDP header) stays a cut-short frame at its own time.
        var fragments: [String: [Int: (time: Double, part: CapturedPacket.Fragment)]] = [:]
        var ready: [CapturedFrame] = []
        for frame in input.sorted(by: { $0.time < $1.time }) {
            guard let f = CapturedPacket.fragment(frame) else { ready.append(frame); continue }
            fragments[f.key, default: [:]][f.offset] = (frame.time, f)
            guard let parts = fragments[f.key], let last = parts.values.first(where: { !$0.part.more })?.part,
                  let first = parts[0]?.part else { continue }
            var payload: [UInt8] = []
            for o in parts.keys.sorted() where o <= payload.count {
                let part = parts[o]!.part.payload
                if o + part.count > payload.count { payload += part[(payload.count - o)...] }
            }
            guard payload.count >= last.offset + last.payload.count else { continue }
            fragments[f.key] = nil
            reassembledDatagrams += 1
            var header = first.header
            let total = header.count + payload.count
            header[2] = UInt8(total >> 8); header[3] = UInt8(total & 0xFF)
            header[6] = 0; header[7] = 0
            ready.append(CapturedFrame(time: frame.time, linkType: CaptureLinkType.raw, bytes: header + payload))
        }
        for parts in fragments.values {
            guard let (time, first) = parts[0] else { continue }
            incompleteFragments += 1
            var header = first.header
            header[6] = 0; header[7] = 0
            ready.append(CapturedFrame(time: time, linkType: CaptureLinkType.raw, bytes: header + first.payload))
        }
        for frame in ready.sorted(by: { $0.time < $1.time }) {
            guard let p = CapturedPacket.parse(frame) else { skipped += 1; continue }
            let toServer = ports.contains(p.destination.port), fromServer = ports.contains(p.source.port)
            guard toServer || fromServer else { skipped += 1; continue }
            if firstTime == nil { firstTime = p.time }
            if let id = p.ipID {
                var h = Hasher()
                h.combine(p.source); h.combine(p.destination); h.combine(id); h.combine(p.seq); h.combine(p.flags); h.combine(p.payload)
                let key = h.finalize()
                if let t = recent[key], p.time - t < 1 { duplicateFrames += 1; continue }
                recent[key] = p.time
                if recent.count > 4096 { recent = recent.filter { p.time - $0.value < 1 } }
            }
            // A port on both ends (unlikely): the SYN sender or the lower-numbered destination is the client.
            let fromClient = toServer && !(fromServer && p.syn && p.flags & 0x10 != 0)
            let client = fromClient ? p.source : p.destination, server = fromClient ? p.destination : p.source
            switch p.transport {
            case .udp:
                var d = CapturedDatagram(time: p.time, fromClient: fromClient, client: client, server: server, payload: p.payload)
                if let n = p.udpLength, n > p.payload.count { d.declaredLength = n }
                datagrams.append(d)
            case .tcp:
                let key = "\(client)>\(server)"
                // A new SYN on a finished/reset connection with the same ports starts a new connection.
                if let n = index[key], p.syn, p.flags & 0x10 == 0, fromClient,
                   connections[n].c2s.sawFin || connections[n].reset || !connections[n].c2s.bytes.isEmpty {
                    index[key] = nil
                }
                let n: Int
                if let k = index[key] { n = k } else {
                    n = connections.count
                    index[key] = n
                    connections.append(TCPConnection(client: client, server: server, firstTime: p.time, lastTime: p.time))
                }
                connections[n].lastTime = p.time
                if p.rst { connections[n].reset = true }
                if fromClient { connections[n].c2s.add(p) } else { connections[n].s2c.add(p) }
            }
        }
        for n in connections.indices {
            connections[n].c2s.finish()
            connections[n].s2c.finish()
        }
    }
}

/// The ICA payload of one direction of a connection: raw ICA (port 1494) as is, or the data of a CGP stream
/// (port 2598, "\x1aCGP/01" first) unwrapped, as scripts/cgp-split.py does for relay recordings.
public struct ICAStreamExtract: Sendable {
    public var isCGP = false
    public var ica: [UInt8] = []
    /// (end offset in `ica`, end offset in the TCP stream) per CGP data packet, for timing.
    public var map: [(icaEnd: Int, tcpEnd: Int)] = []
    /// Count per CGP command byte.
    public var commands: [UInt8: Int] = [:]
    /// One line per non-data CGP packet (`cmd 0x.. len n: hex…`).
    public var log: [String] = []
    /// Bytes after the last complete CGP packet.
    public var leftover = 0

    public init(_ stream: [UInt8]) {
        let signature = [UInt8](CGPSession.signature)
        guard stream.starts(with: signature) else {
            ica = stream
            map = [(stream.count, stream.count)]
            return
        }
        isCGP = true
        var i = signature.count
        while i < stream.count {
            var n = Int(stream[i]), j = i + 1
            if n >= 0x80 {
                guard i + 1 < stream.count else { break }
                n = (n & 0x7F) | Int(stream[i + 1]) << 7
                j = i + 2
            }
            guard n >= 1, j + n <= stream.count else { break }
            let packet = Array(stream[j..<(j + n)])
            i = j + n
            let cmd = packet[0]
            commands[cmd, default: 0] += 1
            if cmd == CGPSession.Command.data.rawValue {
                ica += packet[1...]
                map.append((ica.count, i))
            } else if cmd == CGPSession.Command.dataWithAck.rawValue, packet.count >= 2 {
                let k = packet[1] < 0x80 ? 2 : 3
                if k <= packet.count { ica += packet[k...] }
                map.append((ica.count, i))
            } else {
                log.append(String(format: "cmd 0x%02x len %d: ", cmd, n) + packet.prefix(48).map { String(format: "%02x", $0) }.joined())
            }
        }
        leftover = stream.count - i
    }

    /// The TCP stream offset that completed ICA offset `icaEnd`.
    public func tcpOffset(forICAEnd icaEnd: Int) -> Int? {
        var lo = 0, hi = map.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if map[mid].icaEnd < icaEnd { lo = mid + 1 } else { hi = mid }
        }
        return lo < map.count ? map[lo].tcpEnd : nil
    }
}
