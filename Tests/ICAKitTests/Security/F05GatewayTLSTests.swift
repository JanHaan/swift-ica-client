import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-05: a gateway account never connects a session in
// plain TCP; a direct StoreFront account still follows the server's ICA file. Offline (no connect is started).

@Suite struct F05GatewayTLSTests {
    private func ica(_ lines: [String]) -> ICAFile {
        ICAFile(text: "[WFClient]\nVersion=2\n[ApplicationServers]\nNotepad=\n[Notepad]\n" + lines.joined(separator: "\n") + "\n")!
    }
    private let gatewayFile = ["Address=;40;STA1234567890ABCDEF;0123456789ABCDEF0123456789ABCDEF", "SSLEnable=On",
                               "SSLProxyHost=gw.example:443", "CGPSecurityTicket=On"]
    private let plainFile = ["Address=192.0.2.12", "SSLEnable=Off", "CGPAddress=*:2598"]

    @Test func planRefusalOnlyForPlainRoutesWhenTLSIsRequired() throws {
        let gateway = try ICAConnectPlan(ica: ica(gatewayFile), environment: [:])
        let plain = try ICAConnectPlan(ica: ica(plainFile), environment: [:])
        let directTLS = try ICAConnectPlan(ica: ica(["Address=192.0.2.12", "SSLEnable=On"]), environment: [:])
        #expect(gateway.refusal(requireTLS: true) == nil)
        #expect(directTLS.refusal(requireTLS: true) == nil)
        #expect(plain.refusal(requireTLS: false) == nil)
        #expect(plain.refusal(requireTLS: true)?.contains("unencrypted") == true)
    }

    @Test func sessionOnAGatewayAccountRefusesAPlainFile() throws {
        #expect(throws: ICASession.Failure.self) { _ = try ICASession(ica: self.ica(self.plainFile), configuration: .init(), requireTLS: true) }
        let direct = try ICASession(ica: ica(plainFile), configuration: .init())        // direct store account: as before
        #expect(!direct.plan.tls)
        let gateway = try ICASession(ica: ica(gatewayFile), configuration: .init(), requireTLS: true)
        #expect(gateway.plan.tls && gateway.plan.route == .gateway)
    }
}
