import Foundation
import Network
import Security

/// The negotiated TLS/DTLS version and cipher suite of one connection, for the session log ("TLS 1.3,
/// TLS_AES_128_GCM_SHA256"). Only these two public handshake results; never keys, tickets or certificates.
public struct TLSInfo: Equatable, Sendable, CustomStringConvertible {
    public var version: UInt16
    public var cipherSuite: UInt16

    public init(version: UInt16, cipherSuite: UInt16) {
        self.version = version
        self.cipherSuite = cipherSuite
    }

    public init(version: tls_protocol_version_t, cipherSuite: tls_ciphersuite_t) {
        self.init(version: version.rawValue, cipherSuite: cipherSuite.rawValue)
    }

    /// From an established Network.framework connection; nil without TLS or DTLS.
    public init?(_ connection: NWConnection) {
        guard let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let sec = meta.securityProtocolMetadata
        self.init(version: sec_protocol_metadata_get_negotiated_tls_protocol_version(sec),
                  cipherSuite: sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec))
    }

    public var versionName: String {
        switch version {
        case 0x0301: "TLS 1.0"
        case 0x0302: "TLS 1.1"
        case 0x0303: "TLS 1.2"
        case 0x0304: "TLS 1.3"
        case 0xFEFF: "DTLS 1.0"
        case 0xFEFD: "DTLS 1.2"
        case 0xFEFC: "DTLS 1.3"
        default: String(format: "version 0x%04X", version)
        }
    }

    /// IANA names of the suites Apple's TLS stack can negotiate; others as hex.
    public var cipherSuiteName: String {
        let names: [UInt16: String] = [
            0x1301: "TLS_AES_128_GCM_SHA256",
            0x1302: "TLS_AES_256_GCM_SHA384",
            0x1303: "TLS_CHACHA20_POLY1305_SHA256",
            0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
            0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
            0xC023: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
            0xC024: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
            0xC027: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256",
            0xC028: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384",
            0xC009: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA",
            0xC00A: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
            0xC013: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
            0xC014: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
            0x009C: "TLS_RSA_WITH_AES_128_GCM_SHA256",
            0x009D: "TLS_RSA_WITH_AES_256_GCM_SHA384",
            0x003C: "TLS_RSA_WITH_AES_128_CBC_SHA256",
            0x003D: "TLS_RSA_WITH_AES_256_CBC_SHA256",
            0x002F: "TLS_RSA_WITH_AES_128_CBC_SHA",
            0x0035: "TLS_RSA_WITH_AES_256_CBC_SHA",
        ]
        return names[cipherSuite] ?? String(format: "cipher suite 0x%04X", cipherSuite)
    }

    public var description: String { "\(versionName), \(cipherSuiteName)" }
}
