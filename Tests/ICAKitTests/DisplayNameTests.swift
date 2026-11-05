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
        #expect(DisplayName.censored("Tool Abc") == "Tool Abc")                   // not all caps
        #expect(DisplayName.censored("Tool ABC Pro") == "Tool ABC Pro")           // not trailing
        #expect(DisplayName.censored("ABC") == "ABC")                             // nothing else left
        #expect(DisplayName.censored("Tool12 AB1") == "Tool12 AB1")
    }

    @Test func replacesConfiguredWordsInAnyCase() {
        let rules = [(word: "secretcorp", with: "example")]
        #expect(DisplayName.censored("SECRETCORP Tool", replacing: rules) == "example Tool")
        #expect(DisplayName.censored("Tool secretcorp", replacing: rules) == "Tool example")
        #expect(DisplayName.censored("SecretCorp Tool QRS", replacing: rules) == "example Tool")
        #expect(DisplayName.censored("SecretCorp Tool") == "SecretCorp Tool")   // no rules, no change
    }

    @Test func parsesReplacementRules() {
        let rules = DisplayName.parseReplacements("# comment\nsecretcorp=example\n\n bad line \nfoo = bar ;baz=")
        #expect(rules.map(\.word) == ["secretcorp", "foo", "baz"])
        #expect(rules.map(\.with) == ["example", "bar", ""])
    }

    @Test func demoFormHasBuiltInLabelsOnly() {
        let form = LogonForm.demo(languages: ["en"])
        #expect(form.fields.map(\.kind) == [.heading, .username, .password, .passcode, .button])
        #expect(form.fields.map(\.label).allSatisfy { !$0.isEmpty && !$0.contains("_") })
        #expect(!form.isRePrompt)
    }
}
