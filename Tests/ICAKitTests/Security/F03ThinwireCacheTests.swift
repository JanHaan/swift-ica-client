import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-03a: Thinwire cache geometry and decoded-bitmap memory from the host. Offline.

@Suite struct F03ThinwireCacheTests {
    @Test func thinwireCacheExtendOnATinyRingKeepsTheObjectIntact() throws {
        let cache = TWCache()
        try cache.configure(log2Bytes: 2, handleLog2: 1, maxObjectSize: 16)
        func with(_ bytes: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> Void) { bytes.withUnsafeBufferPointer(body) }
        with([]) { cache.newObject($0) }
        with([0xFF, 0xFF, 0xFF, 0xFF]) { cache.extendLast($0) }   // used to overwrite the object's own length word
        with([0x00]) { cache.extendLast($0) }                     // then sliced 4 GiB out of the ring: trap
        #expect(cache.object(0) == [0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        with(Array(repeating: 7, count: 20)) { cache.extendLast($0) }   // over the maximum: kept aside, not trapped
        #expect(cache.object(0)?.count == 25)
    }

    @Test func thinwireCacheExtendOnAnOrdinaryRingIsUnchanged() throws {
        let cache = TWCache()
        try cache.configure(log2Bytes: 10, handleLog2: 4, maxObjectSize: 512)
        // Six 200-byte objects in a 1 KiB ring: the sixth starts past the ring's end and lands at offset 96.
        for n in 0..<6 { [UInt8](repeating: UInt8(n), count: 200).withUnsafeBufferPointer { cache.newObject($0) } }
        [UInt8](repeating: 9, count: 100).withUnsafeBufferPointer { cache.extendLast($0) }
        #expect(cache.object(5) == [UInt8](repeating: 5, count: 200) + [UInt8](repeating: 9, count: 100))
        #expect(cache.object(3) == [UInt8](repeating: 3, count: 200))
    }

    @Test func decodedThinwireBitmapsStayWithinTheByteBudget() throws {
        let cache = TWCache()
        try cache.configure(log2Bytes: 10, handleLog2: 10, maxObjectSize: 64)
        let side = 4096                                              // 64 MiB each at 4 B per pixel
        for handle in 0..<40 {
            cache.storeDecoded(TWBitmap(width: side, height: side, pixels: .rgb([])), for: handle)
            #expect(cache.decodedBytes <= TWCache.decodedByteBudget)
        }
    }
}
