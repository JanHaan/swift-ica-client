import Foundation

/// PDCRYPT1 "basic encryption" (docs/30-winstation.md §8.2, docs/20-transport.md §5.2).
/// A keyed XOR chain with one byte of key and a separate chaining byte per direction.
public struct WDBasicCipher: Sendable {
    public let key: UInt8
    private var sendChain: UInt8
    private var receiveChain: UInt8

    public init(key: UInt8) {
        self.key = key
        sendChain = key | 0x43
        receiveChain = key | 0x43
    }

    /// Back to the initial chain state (when the PD is re-enabled).
    public mutating func reset() {
        sendChain = key | 0x43
        receiveChain = key | 0x43
    }

    /// c[0] = m[0] ^ chain ^ k; c[i] = m[i] ^ c[i-1] ^ k; chain := last c.
    public mutating func encrypt(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes[0] ^= sendChain ^ key
        for i in 1..<bytes.count { bytes[i] ^= bytes[i - 1] ^ key }
        sendChain = bytes[bytes.count - 1]
    }

    /// Inverse of `encrypt`, with the receive-direction chain.
    public mutating func decrypt(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        let last = bytes[bytes.count - 1]
        var i = bytes.count - 1
        while i > 0 {
            bytes[i] ^= bytes[i - 1] ^ key
            i -= 1
        }
        bytes[0] ^= receiveChain ^ key
        receiveChain = last
    }
}

/// String-pool obfuscation of the UI module (docs/30-winstation.md §5.6).
public enum WDObfuscation {
    /// b[0] ^= seed | 0x43; b[i] ^= b'[i-1] ^ seed, where b' is the already transformed byte.
    public static func obfuscate(_ bytes: inout [UInt8], seed: UInt8) {
        guard !bytes.isEmpty else { return }
        bytes[0] ^= seed | 0x43
        for i in 1..<bytes.count { bytes[i] ^= bytes[i - 1] ^ seed }
    }

    public static func deobfuscate(_ bytes: inout [UInt8], seed: UInt8) {
        guard !bytes.isEmpty else { return }
        var i = bytes.count - 1
        while i > 0 {
            bytes[i] ^= bytes[i - 1] ^ seed
            i -= 1
        }
        bytes[0] ^= seed | 0x43
    }
}
