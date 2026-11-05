import Testing
import Foundation
@testable import ICAKit

/// Server INIT_REQUEST captured live from the VDA behind gateway.example.com (capabilities only, no secrets).
let liveInitRequestHex = [
    "00060207002004000600020007001000060001001e0002000000000000000c0010001300000000000000080019000700",
    "00000c002200000000000000000004000100060004000900060007000300440008000000000000000000000000000000",
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "000048002600000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "00000000000000000000000000000000000003000000000000000400090004000b000a000d0001000200020010000a00",
    "0200f8077800010050003c0004000c000600120003000c0013000000000801000000080014000300020004001c001900",
    "23000000000000000000000000000000000001410000001d001e00000000000000000000000000000000010300000000",
    "00000000060021004000080014000200000006001d000100080028000101000022002900010000000000000000000000",
    "00000000000000000000000000000000000008002b000000020015002a0001ffffffffffffffffffffffff0000000016",
    "002c000100ffffffffffffffffffffffff0100000022002d00010002000c000100000000000000000000000200000000",
    "000000000000000c002e00010000000000000016003000010000000000000000000000000000000000",
].joined()

func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

@Test func parsesLiveInitRequest() throws {
    let packet = bytes(hex: liveInitRequestHex)
    #expect(packet.count == 521)
    var parser = WDStreamParser()
    let (packets, _) = parser.feed(packet)
    #expect(packets.count == 1)
    #expect(packets[0].type == 0x00)
    let request = try WDInitRequest(payload: packets[0].payload)
    #expect(request.level == 7)
    #expect(request.capabilities.count == 32)
    #expect(request.capabilities.prefix(4).map(\.id) == [0x02, 0x06, 0x10, 0x19])
    #expect(request.capability(0x02)?.body == [0x07, 0x00])
    #expect(request.capability(0x21)?.body == [0x40, 0x00])
    #expect(request.extendedMouse)
    #expect(request.hostOS == 1)
    #expect(request.capability(0x31) == nil)
}

@Test func negotiatesMinimalCapabilities() throws {
    var parser = WDStreamParser()
    let payload = parser.feed(bytes(hex: liveInitRequestHex)).packets[0].payload
    let request = try WDInitRequest(payload: payload)
    let negotiated = WDCapabilityPolicy().negotiate(server: request.capabilities)
    #expect(WDCapabilityBlock.serialize(negotiated) == [
        0x00, 0x06, 0x04, 0x00,
        0x06, 0x00, 0x02, 0x00, 0x04, 0x00,              // reducer: server 0x07 & ours 0x0C = V3
        0x04, 0x00, 0x09, 0x00,                          // long credentials
        0x05, 0x00, 0x12, 0x00, 0x00,                    // credential request v0
        0x08, 0x00, 0x14, 0x00, 0x01, 0x00, 0x01, 0x00,  // unicode keyboard v1 mode 1 (first of two server entries)
        0x06, 0x00, 0x21, 0x00, 0x40, 0x00,              // 64 channels
        0x04, 0x00, 0x05, 0x00,                          // VC priority, appended
    ])
    #expect(WDCapabilityPolicy.reducerVersion(negotiated) == 3)
    var noCred = WDCapabilityPolicy()
    noCred.credentialRequest = false
    #expect(!noCred.negotiate(server: request.capabilities).contains { $0.id == 0x12 })
}

@Test func basicCipherRoundTripAndChaining() {
    var a = WDBasicCipher(key: 0x5A)
    var b = WDBasicCipher(key: 0x5A)
    var m1: [UInt8] = Array("hello world".utf8)
    var m2: [UInt8] = [0, 1, 2, 3, 0xff]
    a.encrypt(&m1)
    a.encrypt(&m2)
    // First byte: m ^ (k|0x43) ^ k.
    #expect(m1[0] == UInt8(ascii: "h") ^ (0x5A | 0x43) ^ 0x5A)
    b.decrypt(&m1)
    b.decrypt(&m2)
    #expect(m1 == Array("hello world".utf8))
    #expect(m2 == [0, 1, 2, 3, 0xff])
}

@Test func obfuscationRoundTrip() {
    var pool: [UInt8] = Array(0..<40).map { UInt8($0 * 7 & 0xff) }
    let original = pool
    WDObfuscation.obfuscate(&pool, seed: 0x9C)
    #expect(pool[0] == original[0] ^ (0x9C | 0x43))
    #expect(pool[1] == original[1] ^ pool[0] ^ 0x9C)
    WDObfuscation.deobfuscate(&pool, seed: 0x9C)
    #expect(pool == original)
}

@Test func encryptionHandshake() throws {
    var client = WDEncryptionPD(key: 0x21)
    #expect(client.send([0xAA]) == [0x00, 0xAA])
    #expect(try client.receive([0x02]) == [.reply([0x04, 0x00, 0x21])])
    var server = WDBasicCipher(key: 0x21)
    // After 0x02 the client encrypts with header 0x01.
    let sent = client.send([0x10, 0x20])
    #expect(sent[0] == 0x01)
    var echo = Array(sent.dropFirst())
    server.decrypt(&echo)
    #expect(echo == [0x10, 0x20])
    // Challenge: server encrypts "xyzPermCrypt" with its send state.
    var challenge = Array("xyzPermCrypt".utf8)
    server.encrypt(&challenge)
    let outputs = try client.receive([0x07] + challenge)
    #expect(outputs.count == 2)
    guard case .reply(let reply) = outputs[0] else { Issue.record("no reply"); return }
    #expect(reply[0] == 0x07)
    var back = Array(reply.dropFirst())
    server.decrypt(&back)
    #expect(back == Array("xyzPermCrypt".utf8))
    #expect(client.mode == .permanent)
    // Permanent: no header, encrypted both ways.
    var data: [UInt8] = [0x30, 0x02, 0x09, 0x90]
    server.encrypt(&data)
    #expect(try client.receive(data) == [.data([0x30, 0x02, 0x09, 0x90])])
    #expect(client.send([1, 2, 3]).count == 3)
    #expect(throws: WDEncryptionPD.Failure.self) { var c = WDEncryptionPD(key: 1); _ = try c.receive([0x09]) }
}

@Test func streamParserHandlesSplitsAndTypes() {
    var parser = WDStreamParser()
    let stream: [UInt8] = [0x35, 0x00] + [0x3B, 0x03, 0x00, 0x41, 0x42, 0x43] + [0x30, 0x04, 0x09, 0xAA, 0xBB, 0xCC]
        + [0x2F, 0x0C, 0x55] + [0x31, 0x03, 0x00, 0x0C, 0x01, 0x02] + [0x1C, 1, 0, 2, 0] + [0x3F, 0x09, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    var packets: [WDPacket] = []
    for byte in stream { packets += parser.feed([byte]).packets }
    #expect(packets.map(\.type) == [0x3B, 0x30, 0x2F, 0x31, 0x1C, 0x3F])
    #expect(packets[0].payload == [0x41, 0x42, 0x43])
    #expect(packets[1].channel == 9 && packets[1].payload == [0xAA, 0xBB, 0xCC])
    #expect(packets[2].channel == 12 && packets[2].payload == [0x55])
    #expect(packets[3].channel == 12 && packets[3].payload == [0x01, 0x02])
    #expect(packets[4].payload == [1, 0, 2, 0])
    // A bad type drops the rest of the chunk; parsing resumes with the next chunk.
    let result = parser.feed([0x32, 0x09, 0x01, 0x02])
    #expect(result.packets.isEmpty)
    #expect(parser.feed([0x37, 0x40]).packets == [WDPacket(type: 0x37, channel: nil, payload: [0x40])])
}

@Test func frameAssemblerReassembles() {
    var assembler = WDFrameAssembler()
    let frames = WDFraming.frame([1, 2, 3], priority: 2) + WDFraming.frame(Array(repeating: 7, count: 300))
    #expect(frames[1] == 0x80)
    var out: [[UInt8]] = []
    out += assembler.feed(Array(frames.prefix(4)))
    out += assembler.feed(Array(frames.dropFirst(4)))
    #expect(out == [[1, 2, 3], Array(repeating: 7, count: 300)])
}

@Test func packetBuilders() {
    #expect(WDBuild.virtualWrite(channel: 9, [1]) == [0x2F, 9, 1])
    #expect(WDBuild.virtualWrite(channel: 9, [1, 2]) == [0x30, 3, 9, 1, 2])
    let long = WDBuild.virtualWrite(channel: 12, Array(repeating: 0, count: 300))
    #expect(Array(long.prefix(4)) == [0x31, 0x2D, 0x01, 12])
    #expect(WDBuild.virtualAck(channel: 1, value: 0x1234) == [0x32, 1, 0x34, 0x12])
    #expect(WDBuild.scancode(0x1E, up: true) == [0x0A, 0x9E])
    #expect(WDBuild.multiScancode([0xE0, 0x4B], up: true) == [0x0B, 2, 0xE0, 0xCB])
    #expect(WDBuild.unicodeKey(0x20AC, flags: .insert) == [0x3C, 3, 0, 4, 0xAC, 0x20])
    #expect(WDBuild.redraw(left: 0, top: 0, right: 1920, bottom: 1080) == [0x06, 0x06, 0x00, 0, 0, 0, 0x80, 0x87, 0x43])
    #expect(WDBuild.normalise(x: 960, y: 540, width: 1920, height: 1080) == (32769, 32769))
    #expect(WDBuild.mouse([.init(x: 1, y: 2, state: .moved)]) == [0x0D, 1, 0, 2, 0, 1])
    #expect(WDBuild.mouse([.init(x: 1, y: 2, state: .leftDown), .init(x: 1, y: 2, state: .leftUp)]).prefix(2) == [0x0E, 10])
    #expect(WDBuild.wheel(x: 5, y: 6, delta: -120) == [0x3D, 8, 8, 5, 0, 6, 0, 0x20, 0x88, 0xFF])
    let cred = WDBuild.credentials(username: "", domain: "D", password: "pw")
    // 44 len16 02 01 | offsets 12, 14, 18 | "" "D" "pw"
    #expect(cred == [0x44, 0x1A, 0x00, 0x02, 0x01, 12, 0, 0, 0, 14, 0, 0, 0, 18, 0, 0, 0,
                     0, 0, 0x44, 0, 0, 0, 0x70, 0, 0x77, 0, 0, 0])
    #expect(WDBuild.thinwire(sub: 0x15, [1, 2, 3, 4]) == [0x3A, 5, 0, 0x15, 1, 2, 3, 4])
}

@Test func thinwireModuleLayout() {
    #expect(WDModules.largeCacheSize(width: 1920, height: 1080) == 0x1FA000)
    #expect(WDModules.largeCacheSize(width: 5120, height: 4096) == 0x1400000)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let m = WDModules.thinwire(display: WDDisplay(width: 1920, height: 1080), channel: 9, date: date)
    #expect(m[3] == 3 && m[4] == 1 && m[5] == 5)
    #expect(Array(m[19..<25]) == Array("VDTW30".utf8))
    #expect(Array(m[36..<40]) == [9, 0, 0, 0])
    // Block A at 48: version 2, small cache 0x8000, large cache, caps 0x1909, colour 8, res offset 20, count 1, 1920x1080.
    #expect(Array(m[48..<72]) == [2, 0, 0x00, 0x80, 0x00, 0xA0, 0x1F, 0x00, 0x09, 0x19, 0, 0, 8, 0, 0, 0,
                                  20, 0, 1, 0, 0x80, 0x07, 0x38, 0x04])
    // Block C at 96: bits 22, 0x0E, 2^22/12.
    #expect(m[96 + 68] == 22 && m[96 + 70] == 0x0E)
    #expect(Array(m[(96 + 72)..<(96 + 76)]) == [0x55, 0x55, 0x05, 0x00])
    // Caps blob: length/offset at 176, blob at 180 = end of the fixed part.
    let blobLength = Int(m[176]) | Int(m[177]) << 8
    let blobOffset = Int(m[178]) | Int(m[179]) << 8
    #expect(blobOffset == 180 && m.count == 180 + blobLength)
    #expect(Array(m[180..<184]) == [0x00, 0x0F, 0x04, 0x00])
}

@Test func uiModuleLayoutAndPool() throws {
    var logon = WDLogon()
    logon.domain = "\\TESTDOMAIN"
    logon.password = "notapassword"
    logon.initialProgram = "#Calculator"
    logon.launchReference = "REF"
    let m = try WDModules.ui(logon: logon, credentialsInModule: true, longCredentials: false, seed: 0x33)
    #expect(m[3] == 0 && m[5] == 8 && Array(m[6..<18]) == Array("UIModule.cla".utf8))
    #expect(Array(m[36..<40]) == [0x15, 0, 0, 0])
    #expect(m[44] == 1 && m[45] == 0x33)
    #expect(Int(m[70]) | Int(m[71]) << 8 == 97)
    let poolLength = Int(m[72]) | Int(m[73]) << 8
    #expect(m.count == 97 + poolLength)
    var pool = Array(m[97...])
    WDObfuscation.deobfuscate(&pool, seed: 0x33)
    var plain = Array(m[..<97]) + pool
    func string(at field: Int) -> String {
        let offset = Int(plain[field]) | Int(plain[field + 1]) << 8
        var units: [UInt16] = []
        var i = offset
        while plain[i] != 0 || plain[i + 1] != 0 { units.append(UInt16(plain[i]) | UInt16(plain[i + 1]) << 8); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }
    #expect(string(at: 46) == "\\TESTDOMAIN")
    #expect(string(at: 48) == "")
    #expect(string(at: 50) == "notapassword")
    #expect(string(at: 52) == "none")
    #expect(string(at: 56) == "#Calculator")
    #expect(string(at: 68) == "MAC-ICA")
    #expect(string(at: 88) == "ReceiverWeb")
    #expect(string(at: 93) == "REF")
    let font = Int(plain[95]) | Int(plain[96]) << 8
    #expect(Array(plain[font..<(font + 6)]) == [6, 0, 1, 0, 2, 0])
    plain[0] = 0
    #expect(throws: WDModules.Failure.self) {
        var bad = logon
        bad.initialProgram = "#"
        _ = try WDModules.ui(logon: bad, credentialsInModule: true, longCredentials: false, seed: 1)
    }
    #expect(throws: WDModules.Failure.self) {
        var bad = logon
        bad.password = String(repeating: "x", count: 15)
        _ = try WDModules.ui(logon: bad, credentialsInModule: true, longCredentials: false, seed: 1)
    }
}

@Test func wdModuleLayout() {
    let caps = [WDCapability(id: 0x02, body: [0, 0]), WDCapability(id: 0x05)]
    let m = WDModules.wd(capabilities: caps, channels: [("CTXTW  ", 9), ("CTXTWI\0", 12)])
    #expect(m[3] == 2 && m[4] == 1 && m[5] == 9 && Array(m[19..<24]) == Array("WDICA".utf8))
    #expect(Array(m[36..<40]) == [0xF5, 0x97, 0x9A, 0x14])
    #expect(Array(m[48..<52]) == [0x0F, 0, 0, 0])
    #expect(Array(m[56..<58]) == [0x88, 0x13])
    #expect(Array(m[72..<76]) == [2, 0, 86, 0])
    #expect(Array(m[86..<106]) == Array("CTXTW  ".utf8) + [0, 9, 0] + Array("CTXTWI".utf8) + [0, 0, 12, 0])
    let capLength = Int(m[82]) | Int(m[83]) << 8
    let capOffset = Int(m[84]) | Int(m[85]) << 8
    #expect(capOffset == 106 && capLength == 14 && m.count == 120)
    #expect(Array(m[106...]) == [0, 2, 4, 0, 6, 0, 2, 0, 0, 0, 4, 0, 5, 0])
}

/// Records what an engine receives.
final class RecordingEngine: VirtualChannelEngine {
    let channelName: String
    var output: ((ChannelOutput) -> Void)?
    var received: [Data] = []
    init(_ name: String) { channelName = name }
    func receive(_ data: Data) { received.append(data) }
}

@Test func handshakeAndFramedTraffic() throws {
    var config = WinstationDriver.Configuration()
    config.logon.initialProgram = "#Calculator"
    config.logon.domain = "\\DOM"
    config.logon.password = "pw"
    let wd = WinstationDriver(configuration: config, encryptionKey: 0x42, obfuscationSeed: 0x11)
    let tw = RecordingEngine("CTXTW  ")
    let twi = RecordingEngine("CTXTWI\0")
    #expect(wd.register(tw) == 9)
    #expect(wd.register(twi) == 12)
    var sent: [[UInt8]] = []
    wd.transmit = { sent.append($0) }
    var events: [String] = []
    wd.onEvent = { event in
        if case .failure(let text) = event { events.append("failure: " + text) }
        if case .connected = event { events.append("connected") }
    }

    wd.receive(Data(bytes(hex: liveInitRequestHex)))
    #expect(sent.count == 7)
    #expect(sent.map { $0[0] } == Array(repeating: 0x01, count: 7))
    #expect(sent.map { $0[5] } == [6, 5, 4, 3, 2, 1, 0])  // modules remaining
    #expect(sent.map { $0[6] } == [2, 5, 4, 4, 3, 3, 0])  // classes WD TD PD PD VD VD UI
    for packet in sent { #expect(Int(packet[1]) | Int(packet[2]) << 8 == packet.count - 3) }

    // Server INIT_CONNECTs: PD (encryption), then WD with remaining 0; framed data follows in the same chunk.
    var pd = [UInt8](repeating: 0, count: 12)
    pd[2] = 1; pd[3] = 4; pd[8] = 0x0B
    var wdConnect = [UInt8](repeating: 0, count: 40)
    wdConnect[2] = 0; wdConnect[3] = 2
    wdConnect[32] = 4; wdConnect[34] = 36  // empty capability block at 36
    wdConnect[36] = 0; wdConnect[37] = 0; wdConnect[38] = 4; wdConnect[39] = 0
    sent = []
    let framedRequest = WDFraming.frame([0x02])
    wd.receive(Data([0x02, 12, 0] + pd + [0x02, 40, 0] + wdConnect + framedRequest))
    #expect(events == ["connected"])
    #expect(sent.first == [0x04, 0x00, 0x00])
    #expect(sent.dropFirst().first == WDFraming.frame([0x04, 0x00, 0x42]))

    // Encrypted VC write on channel 9 under header 0x01, split over two chunks.
    var server = WDBasicCipher(key: 0x42)
    var vc: [UInt8] = [0x30, 0x04, 0x09, 0x90, 0x03, 0x00]
    server.encrypt(&vc)
    let frame = WDFraming.frame([0x01] + vc)
    wd.receive(Data(frame.prefix(3)))
    wd.receive(Data(frame.dropFirst(3)))
    #expect(tw.received == [Data([0x90, 0x03, 0x00])])

    // Engine output goes out framed with the 0x01 header and encrypted.
    sent = []
    tw.output?(.channel(Data([0xAB, 0xCD])))
    #expect(sent.count == 1)
    var out = sent[0]
    #expect(Int(out[0]) | Int(out[1] & 0x3F) << 8 == out.count - 2)
    #expect(out[2] == 0x01)
    out = Array(out.dropFirst(3))
    server.decrypt(&out)
    #expect(out == [0x30, 0x03, 0x09, 0xAB, 0xCD])

    // Credential request is answered.
    sent = []
    var request: [UInt8] = [0x44, 0x02, 0x00, 0x01, 0x01]
    server.encrypt(&request)
    wd.receive(Data(WDFraming.frame([0x01] + request)))
    #expect(sent.count == 1)
    var reply = Array(sent[0].dropFirst(3))
    server.decrypt(&reply)
    #expect(Array(reply.prefix(5)) == [0x44, UInt8(reply.count - 3), 0x00, 0x02, 0x01])

    // TERMINATE 1 is acked and closes the driver.
    sent = []
    var terminate: [UInt8] = [0x05, 0x01, 0x01]
    server.encrypt(&terminate)
    wd.receive(Data(WDFraming.frame([0x01] + terminate)))
    var ack = Array(sent[0].dropFirst(3))
    server.decrypt(&ack)
    #expect(ack == [0x05, 0x01, 0x02])
    #expect(wd.phase == .closed)
}

@Test func cgpKeepaliveWithExtensionBlock() throws {
    // Live server keepalive: flags 0x09 → extension block [02 05] holding the reliability header (ack 5).
    let session = CGPSession()
    let events = try session.feed(CGPSession.signature + Data([0x05, 0x05, 0x09, 0x02, 0x02, 0x05]))
    #expect(events.count == 2)
    if case .keepalive(let raw) = events.last { #expect(raw == Data([0x09, 0x02, 0x02, 0x05])) } else { Issue.record("no keepalive") }
    #expect(session.peerAcked == 5)
    #expect(session.parseFailures == 0)
    #expect(session.keepalive() == Data([0x03, 0x05, 0x08, 0x00]))
}

@Test func v3ReducerAndExpanderRoundTrip() throws {
    // A WD command (pseudo-channel 0x3F), a short VC write and a long VC write that spans frames.
    let long = (0..<3000).map { UInt8($0 & 0xff) }
    let packets: [[UInt8]] = [[0x3F, 0x01, 0x02], WDBuild.virtualWrite(channel: 12, [1, 2, 3]),
                              WDBuild.virtualWrite(channel: 9, long)]
    let frames = WDV3Reducer.frames(packets, budget: 1449)
    #expect(frames.count == 3)
    #expect(frames.allSatisfy { $0.count <= 1449 })
    // First frame: data "3F 01 02" + "01 02 03" + part of the long write; trailer reversed.
    #expect(Array(frames[0].prefix(6)) == [0x3F, 0x01, 0x02, 0x01, 0x02, 0x03])
    #expect(Array(frames[0].suffix(4)) == [0x06, 0x32, 0x06, 0xFE])  // ..., ch12 complete len 3, ch63 complete len 3
    var expander = WDV3Expander()
    var stream: [UInt8] = []
    for frame in frames { stream += try expander.expand(frame) }
    #expect(stream == [0x3F, 0x01, 0x02] + WDBuild.virtualWrite(channel: 12, [1, 2, 3]) + WDBuild.virtualWrite(channel: 9, long))
}

@Test func v3ExpanderRejectsCompressionAndSkipsSpecials() throws {
    var expander = WDV3Expander()
    // Special DEFINE NUMBER OF CODERS (cmd 0, 1 arg) followed by a complete ch 0x3F segment "37 40".
    // Wire: data | trailer reversed. Read backwards: control 0xFE, varint 4 (len 2); control 0xF8, n 1, cmd 0, arg 4.
    let readOrder: [UInt8] = [0xFE, 0x04, 0xF8, 0x01, 0x00, 0x04]
    let wire: [UInt8] = [0x37, 0x40] + readOrder.reversed()
    #expect(try expander.expand(wire) == [0x37, 0x40])
    #expect(expander.specialCommands[0] == 1)
    let compressed: [UInt8] = [0xAA, 0xBB] + [UInt8]([0x27, 0x04]).reversed()  // ch 9, compressed bit
    #expect(throws: WDV3Expander.Failure.self) { _ = try expander.expand(compressed) }
}

@Test func multiRecordMouseUsesOneCountedPacket() {
    let p = WDBuild.mouse([WDBuild.MouseRecord(x: 1, y: 2, state: .moved), WDBuild.MouseRecord(x: 1, y: 2, state: .leftDown)])
    #expect(p == [0x0E, 10, 1, 0, 2, 0, 0x01, 1, 0, 2, 0, 0x02])
}

@Test func sessionRegistersThinwireAndSeamlessEngines() throws {
    let text = "[ApplicationServers]\nX=\n[X]\nSSLProxyHost=gw.example:443\nAddress=ticket\nCGPSecurityTicket=On\nTWIMode=On\nInitialProgram=#Test\n"
    let ica = try #require(ICAFile(text: text))
    var config = WinstationDriver.Configuration()
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1800, height: 1169)
    let session = try ICASession(ica: ica, configuration: config)
    #expect(session.wd.channelNumber("CTXTW  ") == 9)
    #expect(session.wd.channelNumber("CTXTWI\0") == 12)
    #expect(session.seamless.config.sessionWidth == 1800 && session.seamless.config.sessionHeight == 1169)
    #expect(session.seamless.config.seamless)
}

@Test func thinwireCapsCarryMonitorLayoutAndH264Toggle() {
    let mons = [WDMonitor(left: 0, top: 271, right: 1800, bottom: 1440, workLeft: 0, workTop: 338, workRight: 1800, workBottom: 1440, scalePercent: 200),
                WDMonitor(left: 1800, top: 0, right: 4360, bottom: 1440, workLeft: 1800, workTop: 28, workRight: 4360, workBottom: 1440, scalePercent: 200)]
    let single = WDModules.thinwireCapabilities(scalePercent: 100)
    #expect(single == WDModules.thinwireCapabilities(scalePercent: 100, monitors: [], h264: true))
    let multi = WDModules.thinwireCapabilities(scalePercent: 100, monitors: mons, h264: true)
    #expect(multi[1] == single[1] + 1)                                    // one more entry: 0x11
    // DPI entry first: flags 2, n = 2, then two scales of 200.
    #expect(Array(multi[4..<16]) == [0x0C, 0x00, 0x20, 0x00, 0x02, 0x00, 0x02, 0x00, 0xC8, 0x00, 0xC8, 0x00])
    // Cap 0x11: len 4 + 8 + 32, u32 total 40, n 2, primary 0.
    #expect(Array(multi[16..<28]) == [44, 0, 0x11, 0x00, 40, 0, 0, 0, 2, 0, 0, 0])
    #expect(Array(multi[28..<32]) == [0, 0, 0x0F, 0x01])                  // first monitor left 0, top 271
    let compat = WDModules.thinwireCapabilities(scalePercent: 100, monitors: [], h264: false)
    #expect(compat[1] == 9)
    let update = WDModules.thinwireMonitorUpdate(mons)
    #expect(Array(update[0..<6]) == [0x3A, 43, 0, 0x1D, 40, 0])          // 3A len16 1D u16 n
    #expect(update[6] == 8 && update.count == 6 + 40)
}
