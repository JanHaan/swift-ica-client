import Testing
import Foundation
@testable import ICAKit

@Test func rfc6238SHA1Vectors() {
    // RFC 6238 appendix B, secret "12345678901234567890", 8 digits.
    let totp = TOTP(base32Secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", digits: 8)!
    #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
    #expect(totp.code(at: Date(timeIntervalSince1970: 1111111109)) == "07081804")
    #expect(totp.code(at: Date(timeIntervalSince1970: 20000000000)) == "65353130")
}

@Test func icaFileAppSectionOverridesDefaults() {
    let text = "[WFClient]\nTWIMode=Off\nKey=a=b\n[ApplicationServers]\nApp=\n[App]\nTWIMode=On\nAddress=XYZ\n"
    let ica = ICAFile(text: text)!
    #expect(ica["TWIMode"] == "On")
    #expect(ica["Key"] == "a=b")
    #expect(ica.redactedDescription.contains("Address=<3 chars>"))
}
