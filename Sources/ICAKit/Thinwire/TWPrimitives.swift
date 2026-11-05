import Foundation

/// Thinwire stream primitives (docs/40-thinwire.md §3.1).

/// Integer point in session coordinates.
public struct TWPoint: Equatable, Hashable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    public static let zero = TWPoint(0, 0)
}

/// Integer rect, top-left origin, exclusive right/bottom.
public struct TWRect: Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ o: TWRect) -> TWRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? TWRect(x0, y0, x1 - x0, y1 - y0) : TWRect(x0, y0, 0, 0)
    }

    public func union(_ o: TWRect) -> TWRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return TWRect(x0, y0, max(maxX, o.maxX) - x0, max(maxY, o.maxY) - y0)
    }

    public func contains(_ o: TWRect) -> Bool {
        o.x >= x && o.y >= y && o.maxX <= maxX && o.maxY <= maxY
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum TWError: Error, CustomStringConvertible {
    /// The bytes ran out mid-command; rewind and wait for more channel data.
    case underflow
    /// Opcode whose length cannot be derived; the stream position is lost.
    case unknownOpcode(UInt8)
    /// A fully consumed command whose content could not be used.
    case invalid(String)

    var description: String {
        switch self {
        case .underflow: return "underflow"
        case .unknownOpcode(let op): return String(format: "unknown opcode 0x%02X", op)
        case .invalid(let s): return s
        }
    }
}

/// Cursor over a byte buffer. Every read throws `TWError.underflow` when the bytes run out.
struct TWReader {
    let buf: UnsafeBufferPointer<UInt8>
    var pos: Int
    let end: Int

    init(_ buf: UnsafeBufferPointer<UInt8>, from start: Int = 0, to end: Int? = nil) {
        self.buf = buf
        pos = start
        self.end = end ?? buf.count
    }

    var remaining: Int { end - pos }

    @inline(__always) mutating func need(_ n: Int) throws {
        if n < 0 || end - pos < n { throw TWError.underflow }
    }

    @inline(__always) mutating func u8() throws -> UInt8 {
        guard pos < end else { throw TWError.underflow }
        defer { pos += 1 }
        return buf[pos]
    }

    mutating func i8() throws -> Int { Int(Int8(bitPattern: try u8())) }

    mutating func u16() throws -> UInt16 {
        try need(2)
        defer { pos += 2 }
        return UInt16(buf[pos]) | UInt16(buf[pos + 1]) << 8
    }

    mutating func u16be() throws -> UInt16 {
        try need(2)
        defer { pos += 2 }
        return UInt16(buf[pos]) << 8 | UInt16(buf[pos + 1])
    }

    /// 24-bit little endian: first byte in bits 0..7.
    mutating func u24le() throws -> UInt32 {
        try need(3)
        defer { pos += 3 }
        return UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16
    }

    /// 24-bit big endian: first byte in bits 16..23 (R,G,B order gives 0xRRGGBB).
    mutating func u24be() throws -> UInt32 {
        try need(3)
        defer { pos += 3 }
        return UInt32(buf[pos]) << 16 | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2])
    }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16 | UInt32(buf[pos + 3]) << 24
    }

    mutating func u32be() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(buf[pos]) << 24 | UInt32(buf[pos + 1]) << 16 | UInt32(buf[pos + 2]) << 8 | UInt32(buf[pos + 3])
    }

    /// Unsigned LEB128, truncated to 32 bits like the reference.
    mutating func varint() throws -> Int {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try u8()
            if shift < 64 { value |= UInt64(b & 0x7f) << shift }
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return Int(UInt32(truncatingIfNeeded: value))
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { pos += n }
        return Array(buf[pos..<pos + n])
    }

    mutating func skip(_ n: Int) throws {
        try need(n)
        pos += n
    }

    /// Packed size: returns (x, y) = (width-like, height-like). Y is first in the stream.
    mutating func packedSize() throws -> (x: Int, y: Int) {
        let b = try u8()
        switch b >> 6 {
        case 0:
            return (Int(b & 0x07), Int((b & 0x38) >> 3))
        case 1:
            let y = Int(b & 0x3f)
            return (Int(try u8()), y)
        case 2:
            let y = Int(b & 0x3f) << 8 | Int(try u8())
            return (Int(try u16be()), y)
        default:
            let y = Int(b & 0x3f) << 24 | Int(try u24be())
            return (Int(try u32be()), y)
        }
    }

    /// Raw delta point (dx, dy), without touching any current point.
    mutating func rawDelta() throws -> TWPoint {
        let b = try u8()
        let s5 = Int(Int8(bitPattern: (b & 0x1f) << 3)) >> 3
        let s6 = Int(Int8(bitPattern: (b & 0x3f) << 2)) >> 2
        switch b >> 5 {
        case 0: return TWPoint(s5, 0)
        case 1: return TWPoint(0, s5)
        case 2: return TWPoint(s5, try i8())
        case 3: return TWPoint(try i8(), s5)
        case 4, 5:
            let dy = (s6 << 8) | Int(try u8())
            let dx = Int(Int16(bitPattern: try u16be()))
            return TWPoint(dx, dy)
        default:
            let dy = (s6 << 24) | Int(try u24be())
            let dx = Int(Int32(bitPattern: try u32be()))
            return TWPoint(dx, dy)
        }
    }

    /// Delta point applied to `current`; the result becomes the new current point.
    mutating func point(_ current: inout TWPoint) throws -> TWPoint {
        let d = try rawDelta()
        current = TWPoint(current.x + d.x, current.y + d.y)
        return current
    }

    /// Rect: delta point (left, top) then packed size (width = X, height = Y).
    mutating func rect(_ current: inout TWPoint) throws -> TWRect {
        let p = try point(&current)
        let s = try packedSize()
        return TWRect(p.x, p.y, s.x, s.y)
    }

    /// Extended count of the RLE codecs: u8, then u16 if 0xFF, then u32 if 0xFFFF.
    mutating func extendedCount() throws -> Int {
        let a = try u8()
        if a != 0xff { return Int(a) }
        let b = try u16()
        if b != 0xffff { return Int(b) }
        return Int(try u32())
    }
}

enum TWColor {
    /// RGB555 (x1555) to 0xRRGGBB, widening each channel by replicating its top 3 bits.
    @inline(__always) static func expand555(_ v: UInt32) -> UInt32 {
        var c = ((v << 9) | (v << 3)) & 0xf800f8 | ((v << 6) & 0xf800)
        c |= (c >> 5) & 0x070707
        return c
    }
}
