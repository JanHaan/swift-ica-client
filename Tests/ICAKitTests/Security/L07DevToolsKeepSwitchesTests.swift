import Testing
import Foundation
@testable import ICAKit

// mac-D's question after 4e217f6: development tools (icactl, this test runner: not Developer ID signed) keep every
// switch; the lab cleanup override ICA_TEST_RESOURCES with ICA_ALLOW_ANY_RESOURCE=1 keeps working. Only a
// Developer ID-signed ICA Viewer scrubs (it calls TestSwitches.scrubProcessEnvironment in its main).

@Suite(.serialized) struct L07DevToolsKeepSwitchesTests {
    @Test func theSessionGateOverrideSurvivesTheDefaultScrubOfADevelopmentBuild() {
        let keys = ["ICA_ALLOW_ANY_RESOURCE", "ICA_TEST_RESOURCES"]
        let saved = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer { for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        setenv("ICA_ALLOW_ANY_RESOURCE", "1", 1)
        setenv("ICA_TEST_RESOURCES", "Notepad, File Explorer", 1)
        #expect(!TestSwitches.isDeveloperIDBuild)
        #expect(TestSwitches.scrubProcessEnvironment().isEmpty)          // default: release only when Developer ID
        #expect(TestSessionGate.allowedNames() == ["Notepad", "File Explorer"])
        // A Developer ID viewer would drop both, falling back to the built-in test resources.
        TestSwitches.scrubProcessEnvironment(release: true)
        #expect(TestSessionGate.allowedNames() == TestSessionGate.defaultResources)
    }
}
