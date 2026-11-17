import Foundation
import Network
import Security

/// `ICA_EXTRA_CA_FILE=<pem or der file>` (backlog 1.12, D144): certificate authorities trusted **in addition to** the
/// system trust store, for a test lab with its own CA (StoreFront over HTTPS, TLS straight to the VDA), without touching
/// the user's keychain or the system store. The host name is still checked; expiry and the chain are still evaluated;
/// only the extra anchors are added. A Developer ID build removes the variable before anything reads it
/// (`TestSwitches`), so shipped apps never honour it.
public enum ExtraTrust {
    public static let environmentVariable = "ICA_EXTRA_CA_FILE"

    /// The extra anchors from the environment; empty when unset or unreadable.
    public static let anchors: [SecCertificate] = {
        guard let path = ProcessInfo.processInfo.environment[environmentVariable], !path.isEmpty,
              let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { return [] }
        return certificates(from: data)
    }()

    /// Every certificate of a PEM file (one or more `BEGIN CERTIFICATE` blocks) or a single DER certificate.
    public static func certificates(from data: Data) -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            var out: [SecCertificate] = []
            var rest = Substring(text)
            while let begin = rest.range(of: "-----BEGIN CERTIFICATE-----"),
                  let end = rest.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<rest.endIndex) {
                let body = rest[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
                if let der = Data(base64Encoded: String(body)), let cert = SecCertificateCreateWithData(nil, der as CFData) {
                    out.append(cert)
                }
                rest = rest[end.upperBound...]
            }
            return out
        }
        return SecCertificateCreateWithData(nil, data as CFData).map { [$0] } ?? []
    }

    /// Evaluates `trust` (which already carries the SSL policy with the host name) with the extra anchors added to the
    /// system ones. True only for a valid chain to a system or extra anchor.
    public static func evaluate(_ trust: SecTrust, anchors: [SecCertificate] = anchors) -> Bool {
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Adds the extra anchors to an NWConnection's TLS options (no change when there are none).
    public static func apply(to options: NWProtocolTLS.Options, anchors: [SecCertificate] = anchors) {
        guard !anchors.isEmpty else { return }
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            complete(evaluate(trust, anchors: anchors))
        }, DispatchQueue(label: "ica.extra-trust"))
    }
}
