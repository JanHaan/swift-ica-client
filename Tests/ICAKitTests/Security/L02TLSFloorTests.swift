import Testing
import Foundation
import Network
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-02: ICA TLS (NWConnection, outside ATS) has a
// TLS 1.2 floor. Offline: compares the options, nothing connects.

@Suite struct L02TLSFloorTests {
    @Test func icaTLSOptionsRequireTLS12() {
        let ours = TLSStream.tlsOptions().securityProtocolOptions
        let floor12 = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(floor12.securityProtocolOptions, .TLSv12)
        let floor10 = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(floor10.securityProtocolOptions, .TLSv10)
        #expect(sec_protocol_options_are_equal(ours, floor12.securityProtocolOptions))
        #expect(!sec_protocol_options_are_equal(ours, floor10.securityProtocolOptions))
    }
}
