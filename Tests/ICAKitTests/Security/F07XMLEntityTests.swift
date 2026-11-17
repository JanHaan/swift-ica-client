import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-07: server XML (gateway nFactor, StoreFront, native
// store) never expands entities: no local file is read into a logon form, no entity bomb is expanded. Offline.

@Suite struct F07XMLEntityTests {
    private func canary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macf-f07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("canary.txt")
        try Data("F07-CANARY".utf8).write(to: file)
        return file
    }

    @Test func externalEntitiesAreNeverRead() throws {
        let file = try canary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE AuthenticateResponse [ <!ENTITY e SYSTEM "\(file.absoluteString)"> ]>
        <AuthenticateResponse xmlns="http://citrix.com/authentication/response/1"><Status>success</Status>\
        <Result>more-info</Result><StateContext/><AuthenticationRequirements><PostBack>/nf/auth/doAuthentication.do</PostBack>\
        <Requirements><Requirement><Credential><ID>login</ID><Type>username</Type></Credential>\
        <Input><Text><ReadOnly>true</ReadOnly><InitialValue>&e;</InitialValue></Text></Input></Requirement></Requirements>\
        </AuthenticationRequirements></AuthenticateResponse>
        """
        #expect(SafeXML.document(Data(xml.utf8)) == nil)
        #expect(NativeStoreClient.document(Data(xml.utf8)) == nil)
        let response = HTTPClient.Response(status: 200, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8),
                                           url: URL(string: "https://gw.example/nf/auth/getAuthenticationRequirements.do")!)
        #expect(throws: GatewayLogon.Failure.self) { _ = try FormResponse(response) }
        let methods = "<?xml version=\"1.0\"?><!DOCTYPE m [<!ENTITY e SYSTEM \"\(file.absoluteString)\">]>"
            + "<authMethods><method name=\"&e;\" url=\"ExplicitAuth/Login\"/></authMethods>"
        #expect(StoreFrontLogon.parseAuthMethods(Data(methods.utf8)).isEmpty)
    }

    @Test func entityBombsAreRefusedBeforeParsing() {
        var dtd = "<!ENTITY a0 \"lollollollol\">"
        for i in 1...10 { dtd += "<!ENTITY a\(i) \"" + String(repeating: "&a\(i - 1);", count: 10) + "\">" }
        let start = Date()
        #expect(SafeXML.document(Data("<?xml version=\"1.0\"?><!doctype r [\(dtd)]><r>&a10;</r>".utf8)) == nil)
        #expect(SafeXML.document(Data("<r>\(dtd)</r>".utf8)) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func utf16DocumentsAreRefused() {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for b in "<r>x</r>".utf8 { bytes += [b, 0] }
        #expect(SafeXML.document(Data(bytes)) == nil)
    }

    @Test func ordinaryServerDocumentsStillParse() {
        let plain = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><authMethods xmlns=\"http://citrix.com/authentication/1\">"
            + "<method name=\"ExplicitForms\" url=\"ExplicitAuth/Login\"/></authMethods>"
        #expect(StoreFrontLogon.parseAuthMethods(Data(plain.utf8)).map(\.name) == ["ExplicitForms"])
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("<r a=\"&amp;\">ok</r>".utf8)
        #expect(SafeXML.document(bom)?.rootElement()?.stringValue == "ok")
    }
}
