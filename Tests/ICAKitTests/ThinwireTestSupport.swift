import CoreGraphics
import Foundation
@testable import ICAKit

/// Builds synthetic Thinwire command streams for tests.
struct ThinwireStreamBuilder {
    var bytes: [UInt8] = []
    /// Mirrors the decoder's current point so absolute positions can be written as deltas.
    var current = TWPoint.zero

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: Int) { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8((v >> 8) & 0xff)) }
    mutating func u16be(_ v: Int) { bytes.append(UInt8((v >> 8) & 0xff)); bytes.append(UInt8(v & 0xff)) }
    mutating func u32(_ v: Int) { for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> s) & 0xff)) } }
    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func rgb(_ c: UInt32) { raw([UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)]) }

    mutating func varint(_ v: Int) {
        var v = v
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            bytes.append(b)
        } while v != 0
    }

    static func packedSize(x: Int, y: Int) -> [UInt8] {
        if x < 8 && y < 8 { return [UInt8(y << 3 | x)] }
        if y < 64 && x < 256 { return [0x40 | UInt8(y), UInt8(x)] }
        precondition(y < 0x4000 && x < 0x10000)
        return [0x80 | UInt8(y >> 8), UInt8(y & 0xff), UInt8(x >> 8), UInt8(x & 0xff)]
    }

    mutating func packedSize(x: Int, y: Int) { raw(Self.packedSize(x: x, y: y)) }

    static func delta(dx: Int, dy: Int) -> [UInt8] {
        let s5 = -16...15
        if dy == 0 && s5.contains(dx) { return [UInt8(dx & 0x1f)] }
        if dx == 0 && s5.contains(dy) { return [0x20 | UInt8(dy & 0x1f)] }
        if s5.contains(dx) && (-128...127).contains(dy) { return [0x40 | UInt8(dx & 0x1f), UInt8(bitPattern: Int8(dy))] }
        if s5.contains(dy) && (-128...127).contains(dx) { return [0x60 | UInt8(dy & 0x1f), UInt8(bitPattern: Int8(dx))] }
        precondition((-8192...8191).contains(dy) && (-32768...32767).contains(dx))
        let x16 = UInt16(bitPattern: Int16(dx))
        return [0x80 | UInt8((dy >> 8) & 0x3f), UInt8(dy & 0xff), UInt8(x16 >> 8), UInt8(x16 & 0xff)]
    }

    /// Absolute point, written as a delta from the current point.
    mutating func point(_ x: Int, _ y: Int) {
        raw(Self.delta(dx: x - current.x, dy: y - current.y))
        current = TWPoint(x, y)
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        point(x, y)
        packedSize(x: w, y: h)
    }

    /// INIT, version 3, depth 5, with a server blob echoing profile `profile` and END_OF_FRAME.
    mutating func initCommand(width: Int, height: Int, sessionId: Int = 0x1234_5678, profile: Int = 2,
                              cacheLog2: Int = 16, handleLog2: Int = 8, maxObject: Int = 0x8000, extraCaps: [UInt16] = []) {
        u8(0x90)
        u8(3)
        u32(sessionId)
        u8(5)
        packedSize(x: width, y: height)
        varint(cacheLog2); varint(handleLog2); varint(maxObject); varint(0)
        varint(0)
        var blob: [UInt8] = [0x00, UInt8(2 + extraCaps.count), 0x04, 0x00,
                             0x08, 0x00, 0x17, 0x00, UInt8(profile), 0x00, 0x00, 0x00,
                             0x04, 0x00, 0x0E, 0x00]
        for id in extraCaps { blob += [0x04, 0x00, UInt8(id & 0xff), UInt8(id >> 8)] }
        u16(blob.count)
        u16(0)
        raw(blob)
        current = .zero
    }

    mutating func cacheObject(_ data: [UInt8]) {
        u8(0xA6)
        varint(data.count)
        raw(data)
    }

    mutating func endOfFrame() { u8(0xBE); u8(0) }

    /// Raw 24-bpp bitmap cache object.
    static func rawBitmap24(width: Int, height: Int, pixels: [UInt32]) -> [UInt8] {
        var b: [UInt8] = [0x01, 0x05] + packedSize(x: width - 1, y: height - 1)
        for p in pixels { b += [UInt8(p >> 16 & 0xff), UInt8(p >> 8 & 0xff), UInt8(p & 0xff)] }
        return b
    }
}

/// Collects engine output for assertions.
final class ThinwireTestSink {
    var outputs: [ChannelOutput] = []
    var updates: [[CGRect]] = []
    var pointers: [(CGImage?, CGPoint)] = []
    var logs: [String] = []

    func attach(_ e: ThinwireEngine) {
        e.output = { [unowned self] in outputs.append($0) }
        e.onUpdate = { [unowned self] in updates.append($0) }
        e.onPointer = { [unowned self] in pointers.append(($0, $1)) }
        e.log = { [unowned self] in logs.append($0) }
    }

    var wdPackets: [(UInt8, [UInt8])] {
        outputs.compactMap { if case let .wdPacket(t, b) = $0 { return (t, Array(b)) } else { return nil } }
    }
}

extension UInt32 {
    /// (r, g, b) of a framebuffer pixel 0xAARRGGBB.
    var rgbTriple: (Int, Int, Int) { (Int(self >> 16 & 0xff), Int(self >> 8 & 0xff), Int(self & 0xff)) }
}

/// RGBA bytes of a CGImage, row-major, straight from a premultiplied-last context.
func thinwireRGBA(_ image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}
