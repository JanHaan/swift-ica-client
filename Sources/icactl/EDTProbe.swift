import Foundation
import ICAKit

/// `icactl edtprobe <vda-ipv4> [port] [seconds]` (D130, needs ICA_EDT=1): the EDT handshake only, with ICAKit's
/// `EDTConnection` over a plain UDP socket: induction, conclusion, then `seconds` (default 3) of keep-alives both ways,
/// then our shutdown. No CGP, no ICA, no session; the VDA forgets the half-open connection.
func runEDTProbe(host: String, port: UInt16, seconds: Double) {
    setvbuf(stdout, nil, _IOLBF, 0)
    let parts = host.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { fail("edtprobe needs an IPv4 address") }
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { fail("socket: \(errno)") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { fail("connect: \(errno)") }
    var tv = timeval(tv_sec: 0, tv_usec: 100_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let t0 = Date()
    func now() -> Double { Date().timeIntervalSince(t0) }
    func show(_ dir: String, _ bytes: [UInt8]) {
        let p = try? EDTPacket.parse(bytes)
        let kind = p?.controlType.map { "\($0)" } ?? (p == nil ? "?" : "data")
        print(String(format: "+%7.3f %@ %@ %d B %@", now(), dir, kind, bytes.count, bytes.prefix(24).map { String(format: "%02x", $0) }.joined()))
    }
    let c = EDTConnection(config: EDTConnection.Config(peerIPv4: parts))
    c.send = { bytes in
        show("C>S", bytes)
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) }
    }
    c.onState = { print(String(format: "+%7.3f state %@", now(), "\($0)")) }
    c.connect(now: now())
    var buffer = [UInt8](repeating: 0, count: 2048)
    var connectedAt: Double?
    while true {
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 2048, 0) }
        if n > 0 {
            let bytes = Array(buffer[0..<n])
            show("S>C", bytes)
            c.receive(bytes, now: now())
        }
        c.tick(now: now())
        if case .closed = c.state { break }
        if case .connected = c.state, connectedAt == nil { connectedAt = now() }
        if let at = connectedAt, now() - at >= seconds { c.close(now: now(), reason: "probe done"); break }
        if now() > 30 { c.close(now: now(), reason: "probe timeout"); break }
    }
    let ok = connectedAt != nil
    print("RESULT: \(ok ? "PASS" : "FAIL") edtprobe \(host):\(port): handshake \(ok ? "complete" : "incomplete"), "
          + "cookie \(c.cookie.map { String(format: "%08x", $0) } ?? "none"), keep-alives received \(c.keepAlivesReceived), end: \(c.state)")
    if !ok { exit(1) }
}
