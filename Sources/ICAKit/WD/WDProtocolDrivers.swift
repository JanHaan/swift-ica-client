import Foundation

/// PDRFRAME receive side: `u16 header` (bits 0-13 length, 14-15 priority, masked off) + payload.
public struct WDFrameAssembler {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer += bytes
        var frames: [[UInt8]] = []
        var start = 0
        while buffer.count - start >= 2 {
            let length = Int(buffer[start]) | Int(buffer[start + 1] & 0x3F) << 8
            guard buffer.count - start - 2 >= length else { break }
            frames.append(Array(buffer[(start + 2)..<(start + 2 + length)]))
            start += 2 + length
        }
        if start > 0 { buffer.removeFirst(start) }
        return frames
    }

    public var pendingBytes: Int { buffer.count }
}

public enum WDFraming {
    public static let maxPayload = 0x3FFF

    public static func frame(_ payload: [UInt8], priority: UInt8 = 0) -> [UInt8] {
        precondition(payload.count <= maxPayload)
        let header = UInt16(payload.count) | UInt16(priority & 0x03) << 14
        return [UInt8(header & 0xff), UInt8(header >> 8)] + payload
    }
}

/// PDCRYPT1 state machine (docs/30-winstation.md §8.2, docs/20-transport.md §5.2).
public struct WDEncryptionPD {
    public enum Mode: Equatable, Sendable {
        /// Every frame carries a 1-byte header; `encryptOutgoing` after the server's 0x02.
        case negotiating(encryptOutgoing: Bool)
        /// "OffCrypt ": no headers, plain text.
        case off
        /// "PermCrypt": no headers, everything encrypted.
        case permanent
    }

    public enum Failure: Error, Equatable { case unknownHeader(UInt8), badChallenge }

    public enum Output: Equatable {
        /// Plain WD stream bytes for the parser.
        case data([UInt8])
        /// A frame payload to send back immediately, without adding a crypt header.
        case reply([UInt8])
        case established(Mode)
    }

    public private(set) var mode = Mode.negotiating(encryptOutgoing: false)
    public private(set) var cipher: WDBasicCipher

    public init(key: UInt8) { cipher = WDBasicCipher(key: key) }

    public mutating func reset() {
        mode = .negotiating(encryptOutgoing: false)
        cipher.reset()
    }

    /// One received frame payload.
    public mutating func receive(_ frame: [UInt8]) throws -> [Output] {
        switch mode {
        case .off:
            return [.data(frame)]
        case .permanent:
            var bytes = frame
            cipher.decrypt(&bytes)
            return [.data(bytes)]
        case .negotiating:
            guard let header = frame.first else { return [] }
            var body = Array(frame.dropFirst())
            switch header {
            case 0x00:
                return [.data(body)]
            case 0x01:
                cipher.decrypt(&body)
                return [.data(body)]
            case 0x02:
                mode = .negotiating(encryptOutgoing: true)
                return [.reply([0x04, 0x00, cipher.key])]
            case 0x06, 0x07:
                cipher.decrypt(&body)
                guard body.count >= 9 else { throw Failure.badChallenge }
                let tail = String(decoding: body.suffix(9), as: UTF8.self)
                let permanent = header == 0x07
                guard tail == (permanent ? "PermCrypt" : "OffCrypt ") else { throw Failure.badChallenge }
                cipher.encrypt(&body)
                mode = permanent ? .permanent : .off
                return [.reply([header] + body), .established(mode)]
            default:
                throw Failure.unknownHeader(header)
            }
        }
    }

    /// Wraps one outgoing frame payload.
    public mutating func send(_ payload: [UInt8]) -> [UInt8] {
        switch mode {
        case .off:
            return payload
        case .permanent:
            var bytes = payload
            cipher.encrypt(&bytes)
            return bytes
        case .negotiating(let encrypt):
            guard encrypt else { return [0x00] + payload }
            var bytes = payload
            cipher.encrypt(&bytes)
            return [0x01] + bytes
        }
    }

    /// Bytes the header costs per frame in the current mode.
    public var overhead: Int {
        if case .negotiating = mode { return 1 }
        return 0
    }
}
