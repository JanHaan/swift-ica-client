import CryptoKit
import Foundation

/// RFC 6238 time-based one-time passcodes.
public struct TOTP {
    public enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    public let key: Data
    public let digits: Int
    public let period: Int
    public let algorithm: Algorithm

    public init?(base32Secret: String, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        guard let key = Self.decodeBase32(base32Secret) else { return nil }
        self.key = key
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    public func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let symmetricKey = SymmetricKey(data: key)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value = (UInt32(mac[offset]) & 0x7f) << 24 | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8 | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let text = String(value % modulus)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// Seconds until the current code expires.
    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    static func decodeBase32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for ch in text.uppercased() where ch != " " && ch != "=" && ch != "-" {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            buffer = buffer << 5 | UInt32(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return out.isEmpty ? nil : out
    }
}
