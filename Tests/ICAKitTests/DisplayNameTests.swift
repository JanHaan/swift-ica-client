import Testing
@testable import ICAKit

@Suite struct DisplayNameTests {
    @Test func stripsTrailingCapsTag() {
        #expect(DisplayName.censored("Word ABC") == "Word")
        #expect(DisplayName.censored("Excel XYZ") == "Excel")
        #expect(DisplayName.censored("Paint ABCD") == "Paint")
        #expect(DisplayName.censored("Remote Desktop Connection XY") == "Remote Desktop Connection")
    }

    @Test func keepsOtherNames() {
        #expect(DisplayName.censored("Calculator") == "Calculator")
        #expect(DisplayName.censored("Command Prompt") == "Command Prompt")
        #expect(DisplayName.censored("Notepad PLUSPLUS") == "Notepad PLUSPLUS")   // 8 letters
        #expect(DisplayName.censored("Tool X") == "Tool X")                       // 1 letter
        #expect(DisplayName.censored("Tool Ekm") == "Tool Ekm")                   // not all caps
        #expect(DisplayName.censored("Tool ABC Pro") == "Tool ABC Pro")           // not trailing
        #expect(DisplayName.censored("ABC") == "ABC")                             // nothing else left
        #expect(DisplayName.censored("Tool12 EK1") == "Tool12 EK1")
    }

    @Test func replacesOrganisationNameInAnyCase() {
        #expect(DisplayName.censored("example Tool") == "example Tool")
        #expect(DisplayName.censored("Tool example") == "Tool example")
        #expect(DisplayName.censored("example Tool ABC") == "example Tool")
    }

    @Test func demoFormHasBuiltInLabelsOnly() {
        let form = LogonForm.demo(languages: ["en"])
        #expect(form.fields.map(\.kind) == [.heading, .username, .password, .passcode, .button])
        #expect(form.fields.map(\.label).allSatisfy { !$0.isEmpty && !$0.contains("_") })
        #expect(!form.isRePrompt)
    }
}
