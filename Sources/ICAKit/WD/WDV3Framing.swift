import Foundation

/// V3 reducer/expander frame format (docs/30-winstation.md §12.2): data segments front to back, then a
/// trailer of descriptors written in reverse. Without a coder (`power` nil, the live client) only
/// uncompressed segments are accepted; with a coder (§12.3) compressed and "recompress" segments are
/// decoded / run through the model.
public struct WDV3Expander {
    public enum Failure: Error, Equatable {
        case compressedSegment(channel: UInt8)
        case recompressRequested(channel: UInt8)
        case badVarint
        case segmentOverrun
        case virtualWriteTooLarge(Int)
        case badSpecialCommand(UInt8)
        /// Pseudo-channel 0x3D (Thinwire-aware model, §12.3) is not implemented; the rest of the frame is lost.
        case thinwireAwareSegment
        case coder(channel: UInt8, WDV3CoderError)
    }

    /// Fragments of VC writes not yet marked complete, per channel (0x3F = WD stream).
    private var pending: [UInt8: [UInt8]] = [:]
    public private(set) var specialCommands: [UInt8: Int] = [:]
    /// Special commands seen, in order: command byte and its arguments (in read order).
    public private(set) var specialLog: [(command: UInt8, arguments: [UInt8])] = []
    /// ASSIGN CODER TO CHANNEL: channel → coder (model index).
    public private(set) var assignments: [UInt8: Int] = [:]
    public private(set) var coder: WDV3Coder?
    /// Diagnostics: segments seen per kind.
    public private(set) var compressedSegments = 0
    public private(set) var recompressSegments = 0
    public private(set) var thinwireAwareSegments = 0
    /// Diagnostics: frames by number of bytes left between the data and the trailer (0…2 is normal).
    public private(set) var leftoverBytes: [Int: Int] = [:]
    /// Diagnostics hook: one line per segment.
    public var trace: ((String) -> Void)?

    /// `power` nil: no coder (compressed segments are an error). Otherwise the coder's history power (§12.3).
    public init(power: Int?, options: WDV3CoderOptions = WDV3CoderOptions()) throws {
        if let power { coder = try WDV3Coder(power: power, options: options) }
    }

    public init() {}

    private func model(for channel: UInt8) -> Int {
        assignments[channel] ?? 0
    }

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
                guard back >= 1 else { throw Failure.badSpecialCommand(0xFF) }
                let count = Int(frame[back])
                let command = frame[back - 1]
                guard back - 2 - count >= -1 else { throw Failure.badSpecialCommand(command) }
                let arguments = (0..<count).map { frame[back - 2 - $0] }
                specialCommands[command, default: 0] += 1
                specialLog.append((command, arguments))
                switch command {
                case 0 where count >= 1: coder?.define(Int(arguments[0]))
                case 1 where count >= 2: assignments[arguments[0]] = Int(arguments[1])
                default: break
                }
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
            let segment: [UInt8]
            if compressed {
                guard coder != nil else { throw Failure.compressedSegment(channel: channel) }
                if channel == 0x3D { thinwireAwareSegments += 1; throw Failure.thinwireAwareSegment }
                compressedSegments += 1
                do {
                    let (output, consumed) = try coder!.decode(model: model(for: channel), length: value,
                                                               from: frame, offset: data, end: back + 1)
                    guard data + consumed <= back + 1 else { throw Failure.segmentOverrun }
                    segment = output
                    trace?("Z ch \(channel) c\(complete ? 1 : 0) m\(model(for: channel)) len \(value) used \(consumed) at \(data)/\(back + 1): "
                           + output.prefix(32).map { String(format: "%02x", $0) }.joined())
                    data += consumed
                } catch let e as WDV3CoderError { throw Failure.coder(channel: channel, e) }
            } else {
                let length = value >> 1
                guard data + length <= back + 1 else { throw Failure.segmentOverrun }
                segment = Array(frame[data..<(data + length)])
                data += length
                trace?("\(value & 1 != 0 ? "R" : "U") ch \(channel) c\(complete ? 1 : 0) len \(length): "
                       + segment.prefix(32).map { String(format: "%02x", $0) }.joined())
                if value & 1 != 0 {
                    guard coder != nil else { throw Failure.recompressRequested(channel: channel) }
                    if channel == 0x3D { thinwireAwareSegments += 1; throw Failure.thinwireAwareSegment }
                    recompressSegments += 1
                    do { try coder!.encode(model: model(for: channel), segment) }
                    catch let e as WDV3CoderError { throw Failure.coder(channel: channel, e) }
                }
            }
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
        leftoverBytes[back - data + 1, default: 0] += 1
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
