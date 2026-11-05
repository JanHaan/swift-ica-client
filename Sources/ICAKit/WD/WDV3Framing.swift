import Foundation

/// V3 reducer/expander frame format with compression powers 0 (docs/30-winstation.md §12.2):
/// data segments front to back, then a trailer of descriptors written in reverse. Only
/// uncompressed segments are produced and accepted; a compressed segment is an error.
public struct WDV3Expander {
    public enum Failure: Error, Equatable {
        case compressedSegment(channel: UInt8)
        case recompressRequested(channel: UInt8)
        case badVarint
        case segmentOverrun
        case virtualWriteTooLarge(Int)
    }

    /// Fragments of VC writes not yet marked complete, per channel (0x3F = WD stream).
    private var pending: [UInt8: [UInt8]] = [:]
    public private(set) var specialCommands: [UInt8: Int] = [:]

    public init() {}

    /// Expands one frame payload into WD stream bytes (VC writes get their 0x30/0x31 header back).
    public mutating func expand(_ frame: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var data = 0
        var back = frame.count - 1
        while back - data >= 2 {
            let control = frame[back]; back -= 1
            let compressed = control & 0x01 != 0
            let complete = control & 0x02 != 0
            let channel = control >> 2
            if control == 0xF8 {
                // Special command: u8 argument count, u8 command, arguments (read backwards).
                let count = Int(frame[back])
                let command = frame[back - 1]
                specialCommands[command, default: 0] += 1
                back -= 2 + count
                continue
            }
            var value = Int(frame[back] & 0x7F)
            var byte = frame[back]; back -= 1
            var shift = 7
            while byte & 0x80 != 0 {
                guard shift < 21, back >= 0 else { throw Failure.badVarint }
                byte = frame[back]; back -= 1
                value |= Int(byte) << shift  // the reference ORs the whole byte (continuation bit included)
                shift += 7
            }
            if compressed { throw Failure.compressedSegment(channel: channel) }
            if value & 1 != 0 { throw Failure.recompressRequested(channel: channel) }
            let length = value >> 1
            guard data + length <= back + 1 else { throw Failure.segmentOverrun }
            let segment = Array(frame[data..<(data + length)])
            data += length
            if !complete {
                pending[channel, default: []] += segment
                continue
            }
            let payload = (pending.removeValue(forKey: channel) ?? []) + segment
            if channel == 0x3F {
                out += payload
            } else {
                let vcChannel: UInt8 = channel == 0x3D ? 9 : channel
                let n = payload.count + 1
                if n < 0x100 { out += [0x30, UInt8(n), vcChannel] }
                else if n < 0x10000 { out += [0x31, UInt8(n & 0xff), UInt8(n >> 8), vcChannel] }
                else { throw Failure.virtualWriteTooLarge(n) }
                out += payload
            }
        }
        return out
    }
}

public enum WDV3Reducer {
    /// Splits a WD packet into its V3 channel and data: VC writes lose their header.
    static func segment(_ packet: [UInt8]) -> (channel: UInt8, data: [UInt8]) {
        switch packet.first {
        case 0x2F where packet.count >= 2: return (packet[1], Array(packet.dropFirst(2)))
        case 0x30 where packet.count >= 3: return (packet[2], Array(packet.dropFirst(3)))
        case 0x31 where packet.count >= 4: return (packet[3], Array(packet.dropFirst(4)))
        default: return (0x3F, packet)
        }
    }

    static func varint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v > 0x7F {
            out.append(UInt8(0x80 | (v & 0x7F)))
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    /// Packs WD packets into V3 frames of at most `budget` bytes (max 50 segments each). A packet
    /// that does not fit continues in the next frame as an incomplete segment.
    public static func frames(_ packets: [[UInt8]], budget: Int) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var body: [UInt8] = []
        var trailer: [UInt8] = []  // descriptors in write order; reversed when the frame is closed
        var segments = 0
        func close() {
            guard segments > 0 else { return }
            frames.append(body + trailer.reversed())
            body = []
            trailer = []
            segments = 0
        }
        for packet in packets {
            let (channel, data) = segment(packet)
            var start = 0
            repeat {
                let remaining = data.count - start
                let free = budget - body.count - trailer.count
                let fullCost = remaining + 1 + varint(remaining << 1).count
                if fullCost <= free, segments < 50 {
                    body += data[start...]
                    trailer += [channel << 2 | 0x02] + varint(remaining << 1)
                    segments += 1
                    start = data.count
                } else if free >= 12, segments < 50 {
                    let take = free - 1 - varint(free << 1).count
                    body += data[start..<(start + take)]
                    trailer += [channel << 2] + varint(take << 1)
                    segments += 1
                    start += take
                    close()
                } else {
                    close()
                }
            } while start < data.count
        }
        close()
        return frames
    }
}
