import Foundation

/// Thinwire object cache: a byte-exact ring with implicit sequential handles
/// (docs/40-thinwire.md §3.4 and §9.2).
final class TWCache {
    private(set) var isConfigured = false
    private var ring: [UInt8] = []
    private var ringSize = 0
    private var ringMask = 0
    private var maxObject = 0
    /// Ring offset (already masked) of each slot's object.
    private var slots: [Int] = []
    private var slotValid: [Bool] = []
    private var handleMask = 0
    private var writePos = 0
    private var nextHandle = 0
    private var walkCounter = 0
    /// Objects that exceeded `maxObject` (a protocol error); kept so the handle sequence holds.
    private var oversized: [Int: [UInt8]] = [:]
    /// Decoded copies keyed by slot.
    private var decoded: [Int: TWBitmap] = [:]
    /// Nominal size of `decoded` (4 bytes per pixel).
    private(set) var decodedBytes = 0
    /// At most this much decoded bitmap data is kept: a few bytes of RLE decode to up to 256 MiB, and 256 of those
    /// would pin 64 GiB (security review F-03). A miss only costs a decode.
    static let decodedByteBudget = 512 << 20

    var log: ((String) -> Void)?

    /// Cache geometry from INIT: 2^log2Bytes ring bytes, 2^handleLog2 slots.
    func configure(log2Bytes: Int, handleLog2: Int, maxObjectSize: Int) throws {
        guard (2...28).contains(log2Bytes), (1...20).contains(handleLog2), maxObjectSize >= 0, maxObjectSize <= 1 << 26 else {
            throw TWError.invalid("cache geometry out of range: 2^\(log2Bytes) bytes, 2^\(handleLog2) handles, max \(maxObjectSize)")
        }
        ringSize = 1 << log2Bytes
        ringMask = ringSize - 1
        maxObject = maxObjectSize
        ring = [UInt8](repeating: 0, count: ringSize + maxObjectSize + 100)
        let handles = 1 << handleLog2
        slots = [Int](repeating: 0, count: handles)
        slotValid = [Bool](repeating: false, count: handles)
        handleMask = handles - 1
        writePos = 0
        nextHandle = 0
        walkCounter = 0
        oversized = [:]
        decoded = [:]
        decodedBytes = 0
        isConfigured = true
    }

    private func writeU32(_ v: UInt32, at off: Int) {
        ring[off] = UInt8(v & 0xff)
        ring[off + 1] = UInt8((v >> 8) & 0xff)
        ring[off + 2] = UInt8((v >> 16) & 0xff)
        ring[off + 3] = UInt8(v >> 24)
    }

    private func copyIn(_ bytes: UnsafeBufferPointer<UInt8>, at off: Int) {
        guard let src = bytes.baseAddress, !bytes.isEmpty else { return }
        ring.withUnsafeMutableBufferPointer { dst in
            precondition(off + bytes.count <= dst.count)
            memcpy(dst.baseAddress! + off, src, bytes.count)
        }
    }

    private func readU32(at off: Int) -> Int {
        Int(ring[off]) | Int(ring[off + 1]) << 8 | Int(ring[off + 2]) << 16 | Int(ring[off + 3]) << 24
    }

    /// Allocates the next handle for `bytes` (CACHE_NEW_OBJECT, 0xA6/0xA7).
    func newObject(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard isConfigured else { log?("Thinwire: cache object before INIT"); return }
        let start = (writePos + 3) & ~3
        let slot = nextHandle & handleMask
        nextHandle += 1
        let off = start & ringMask
        slots[slot] = off
        slotValid[slot] = true
        dropDecoded(slot)
        oversized[slot] = nil
        writePos = start + 4 + bytes.count
        if bytes.count > maxObject {
            log?("Thinwire: cache object of \(bytes.count) bytes exceeds the maximum \(maxObject)")
            oversized[slot] = Array(bytes)
            writeU32(0, at: off)
            return
        }
        writeU32(UInt32(bytes.count), at: off)
        copyIn(bytes, at: off + 4)
    }

    /// Appends to the most recently created object (CACHE_EXTEND_OBJECT, 0xA8/0xA9).
    func extendLast(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard isConfigured, nextHandle > 0 else { log?("Thinwire: cache extend without an object"); return }
        let slot = (nextHandle - 1) & handleMask
        dropDecoded(slot)
        if var big = oversized[slot] {
            big.append(contentsOf: bytes)
            oversized[slot] = big
            writePos += bytes.count
            return
        }
        let start = slots[slot]
        let oldLength = readU32(at: start)
        let newLength = oldLength + bytes.count
        // An object is contiguous from its slot (the ring keeps maxObject + 100 bytes of slack past its end), so the
        // append goes right after it. The masked write position said the same for objects shorter than the ring, but
        // with a host-chosen ring smaller than an object it pointed back into the object's own length word.
        let at = start + 4 + oldLength
        writePos += bytes.count
        if newLength > maxObject || at + bytes.count > ring.count {
            log?("Thinwire: cache extend to \(newLength) bytes exceeds the maximum \(maxObject)")
            var big = at <= ring.count ? Array(ring[(start + 4)..<at]) : []
            big.append(contentsOf: bytes)
            oversized[slot] = big
            return
        }
        writeU32(UInt32(newLength), at: start)
        copyIn(bytes, at: at)
    }

    /// CACHE_PURGE_MEMORY_CACHE (0xAD): `count` bits, LSB first.
    func purge(bits: [UInt8], count: Int) {
        guard isConfigured else { return }
        for i in 0..<count {
            let bit = (bits[i >> 3] >> UInt8(i & 7)) & 1
            let slot = walkCounter & handleMask
            if bit == 1 {
                if let data = object(walkCounter) {
                    data.withUnsafeBufferPointer { newObject($0) }
                }
            } else {
                dropDecoded(slot)
            }
            walkCounter += 1
        }
    }

    /// Bytes of the object referenced by a u16 handle from the stream.
    func object(_ handle: Int) -> [UInt8]? {
        guard isConfigured else { return nil }
        let slot = handle & handleMask
        guard slotValid[slot] else { return nil }
        if let big = oversized[slot] { return big }
        let off = slots[slot]
        let length = readU32(at: off)
        guard off + 4 + length <= ring.count else { return nil }
        return Array(ring[(off + 4)..<(off + 4 + length)])
    }

    private func dropDecoded(_ slot: Int) {
        if let old = decoded.removeValue(forKey: slot) { decodedBytes -= old.width * old.height * 4 }
    }

    func decodedBitmap(_ handle: Int) -> TWBitmap? {
        guard isConfigured else { return nil }
        return decoded[handle & handleMask]
    }

    func storeDecoded(_ bitmap: TWBitmap, for handle: Int) {
        guard isConfigured else { return }
        let size = bitmap.width * bitmap.height * 4
        guard size <= Self.decodedByteBudget else { return }
        if let old = decoded[handle & handleMask] { decodedBytes -= old.width * old.height * 4 }
        if decoded.count >= 256 || decodedBytes + size > Self.decodedByteBudget {
            decoded.removeAll(keepingCapacity: true)
            decodedBytes = 0
        }
        decoded[handle & handleMask] = bitmap
        decodedBytes += size
    }
}
