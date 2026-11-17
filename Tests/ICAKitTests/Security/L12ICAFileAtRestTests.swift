import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low finding L-12: ICA files kept by icactl carry no tickets.

@Suite struct L12ICAFileAtRestTests {
    private let text = "[WFClient]\r\nVersion=2\r\nClientName=MAC-TEST\r\n[ApplicationServers]\r\nNotepad=\r\n[Notepad]\r\n"
        + "Address=;40;STA1234;0123456789ABCDEF\r\nLogonTicket=ABCDEFGH12345678\r\nClearPassword=0123456789ABCD\r\n"
        + "SSLProxyHost=gw.example:443\r\nLaunchReference=XYZ\r\nRtmeDetail=x\r\nCGPSecurityTicket=On\r\nTWIMode=On\r\n"

    @Test func secretsAreRedactedKeysAndClientNameKept() throws {
        let red = ICAFile.redactedText(text)
        for secret in [";40;STA1234;0123456789ABCDEF", "ABCDEFGH12345678", "0123456789ABCD", "LaunchReference=XYZ"] {
            #expect(!red.contains(secret))
        }
        let file = try #require(ICAFile(text: red))
        let original = try #require(ICAFile(text: text))
        #expect(file.keys == original.keys)                              // the key diff of `icactl native keys`
        #expect(file["ClientName"] == "MAC-TEST")                        // ourClientNames()
        #expect(file["LogonTicket"] == "<16 chars>")
        #expect(file["CGPSecurityTicket"] == "<2 chars>")                 // a "ticket" key: redacted too (it is On/Off)
        #expect(file["SSLProxyHost"] == "gw.example:443" && file["TWIMode"] == "On")
        #expect(red.contains("\r\n"))                                    // line endings kept
    }
}
