import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-03c: Opus lost-packet silence per WRITE is bounded. Offline.

@Suite struct F03OpusConcealmentTests {
    @Test func opusLostPacketRunsAreBoundedPerWrite() throws {
        guard let decoder = OpusDecoder(AudioFormatCode(6, 0x14)) else { return }   // no Opus decoder on this Mac
        let payload = Data([UInt8](repeating: 0, count: 65534))     // 32767 zero-length packets (lost frames)
        let out = decoder.decode(payload)
        #expect(out.count <= OpusDecoder.maxConcealedFramesPerWrite(48000) * 2)
        #expect(decoder.lostPackets == 32767)
        let one = decoder.decode(Data([0, 0]))
        #expect(one.count == 480 * 2)                                // a single lost frame: 10 ms of silence as before
    }
}
