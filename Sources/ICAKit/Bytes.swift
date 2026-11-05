import Foundation

/// Little-endian byte builder.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xff)); data.append(UInt8(v >> 8)) }
    public mutating func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> UInt32(shift)) & 0xff)) } }
    public mutating func raw(_ d: Data) { data.append(d) }
    public mutating func raw(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

    /// CGP variable-length integer: 1 byte below 0x80, else 2 bytes (low 7 bits | 0x80, then v >> 7).
    public mutating func varlen(_ v: Int) {
        precondition(v >= 0 && v <= 0x7fff, "varlen out of range")
        if v < 0x80 { u8(UInt8(v)) } else { u8(UInt8(v & 0x7f) | 0x80); u8(UInt8(v >> 7)) }
    }

    /// varlen length followed by the bytes.
    public mutating func bytes(_ d: Data) { varlen(d.count); raw(d) }
}

public enum ByteError: Error { case truncated }

/// Little-endian byte reader over a Data slice.
public struct ByteReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { remaining <= 0 }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func u16() throws -> UInt16 {
        let lo = try u8(), hi = try u8()
        return UInt16(lo) | UInt16(hi) << 8
    }

    public mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) { v |= UInt32(try u8()) << UInt32(shift) }
        return v
    }

    public mutating func varlen() throws -> Int {
        let first = try u8()
        if first < 0x80 { return Int(first) }
        return Int(first & 0x7f) | Int(try u8()) << 7
    }

    public mutating func raw(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ByteError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    public mutating func bytes() throws -> Data { try raw(try varlen()) }

    public mutating func rest() -> Data { (try? raw(remaining)) ?? Data() }
}

extension Data {
    /// Hex dump, 16 bytes per line, for traces.
    public func hexDump(limit: Int = 256) -> String {
        let shown = prefix(limit)
        var lines: [String] = []
        var index = 0
        while index < shown.count {
            let row = shown.dropFirst(index).prefix(16)
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%04x  ", index) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + ascii)
            index += 16
        }
        if count > limit { lines.append("… \(count) bytes total") }
        return lines.joined(separator: "\n")
    }
}
