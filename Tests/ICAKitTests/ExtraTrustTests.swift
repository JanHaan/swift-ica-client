import Foundation
import Security
import Testing
@testable import ICAKit

// D144: ICA_EXTRA_CA_FILE. A test CA ("ICA Test Lab CA") and a leaf for lab.example signed by it (both made for this
// test only; the private keys were not kept).

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func extraTrustReadsPEMAndDER() throws {
    let ca = try fixture("extra-trust-ca.pem"), leaf = try fixture("extra-trust-leaf.pem")
    #expect(ExtraTrust.certificates(from: ca).count == 1)
    #expect(ExtraTrust.certificates(from: ca + Data("\n".utf8) + leaf).count == 2)
    let der = SecCertificateCopyData(ExtraTrust.certificates(from: ca)[0]) as Data
    #expect(ExtraTrust.certificates(from: der).count == 1)
    #expect(ExtraTrust.certificates(from: Data("not a certificate".utf8)).isEmpty)
}

@Test func extraTrustAcceptsTheLabChainOnlyWithTheAnchorAndTheRightHost() throws {
    let ca = ExtraTrust.certificates(from: try fixture("extra-trust-ca.pem"))
    let leaf = ExtraTrust.certificates(from: try fixture("extra-trust-leaf.pem"))
    func trust(host: String) throws -> SecTrust {
        var t: SecTrust?
        #expect(SecTrustCreateWithCertificates(leaf as CFArray, SecPolicyCreateSSL(true, host as CFString), &t) == errSecSuccess)
        let trust = try #require(t)
        SecTrustSetVerifyDate(trust, Date(timeIntervalSince1970: 1_800_000_000) as CFDate)   // 2027-01-15, inside the validity
        return trust
    }
    #expect(ExtraTrust.evaluate(try trust(host: "lab.example"), anchors: ca))
    #expect(!ExtraTrust.evaluate(try trust(host: "lab.example"), anchors: []))      // system store alone: unknown CA
    #expect(!ExtraTrust.evaluate(try trust(host: "other.example"), anchors: ca))    // host name still checked
}
