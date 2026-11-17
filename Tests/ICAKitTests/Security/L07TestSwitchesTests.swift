import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), low findings L-07/L-08: a Developer ID build drops test and
// diagnostic switches from its environment (default deny); development builds keep them. Offline.

@Suite(.serialized) struct L07TestSwitchesTests {
    @Test func securityAndAutomationSwitchesAreGated() {
        for name in ["ICA_HELPER_VERIFY", "ICA_HELPER_TEMPLATE", "ICA_HELPER_SIGN_IDENTITY", "ICA_IGNORE_ENCRYPTION_LEVEL",
                     "ICA_DIRECT_CGP", "ICA_DIRECT_TLS_SOCKS", "ICA_ALLOW_ANY_RESOURCE", "ICA_TEST_RESOURCES",
                     "ICA_TEST_DROP_AFTER", "ICA_ROOT", "ICA_ENV", "ICA_LAB_APPS", "ICA_PRINTTEST_CONFIRM", "ICA_CDM_FOLDER",
                     "ICA_GDT", "ICA_MODNAME_CTXCLIP", "ICA_EDT", "ICA_LOGOFF_IF_ONLY", "ICAVIEWER_LAUNCH", "ICAVIEWER_SELFTEST",
                     "ICAVIEWER_LOGIN_AUTOFILL", "ICAVIEWER_CAPTURE_TWI", "ICAVIEWER_TEST_RESUME_AFTER", "ICA_SOMETHING_NEW"] {
            #expect(!TestSwitches.keptInRelease(name, "1"), "\(name) must be gated")
        }
    }

    @Test func preferencesAndOffSwitchesStay() {
        for name in ["ICA_LOG_FILE", "ICA_DOCK_ICON", "ICA_FPS_IDLE", "ICA_KBD_LAYOUT", "ICA_SCALE_LIMIT", "ICAVIEWER_DEMO"] {
            #expect(TestSwitches.keptInRelease(name, "0"))
        }
        #expect(TestSwitches.keptInRelease("ICA_CDM", "off") && !TestSwitches.keptInRelease("ICA_CDM", "1"))
        #expect(TestSwitches.keptInRelease("ICA_CDM_READONLY", "1") && !TestSwitches.keptInRelease("ICA_CDM_READONLY", "0"))
        #expect(TestSwitches.keptInRelease("ICA_AUDIO_MIC", "0") && !TestSwitches.keptInRelease("ICA_AUDIO_MIC", "1"))
        #expect(TestSwitches.keptInRelease("PATH", "/usr/bin") && TestSwitches.keptInRelease("HOME", "/x"))
        #expect(TestSwitches.gated(["ICA_HELPER_VERIFY": "0", "ICA_LOG_FILE": "0", "HOME": "/x", "ICA_CDM": "1"])
                == ["ICA_CDM", "ICA_HELPER_VERIFY"])
    }

    @Test func scrubRemovesGatedSwitchesOnlyInARelease() {
        let gated = "ICA_HELPER_VERIFY", kept = "ICA_FPS_IDLE"
        let saved = [gated, kept].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer { for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        setenv(gated, "0", 1)
        setenv(kept, "5", 1)
        #expect(TestSwitches.scrubProcessEnvironment(release: false).isEmpty)
        #expect(ProcessInfo.processInfo.environment[gated] == "0")
        let removed = TestSwitches.scrubProcessEnvironment(release: true)
        #expect(removed.contains(gated))
        #expect(ProcessInfo.processInfo.environment[gated] == nil)
        #expect(ProcessInfo.processInfo.environment[kept] == "5")
    }

    @Test func developerIDDetection() throws {
        #expect(!TestSwitches.isDeveloperIDBuild)                                     // the test runner is not
        #expect(!TestSwitches.isDeveloperIDSigned(bundle: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        // Cross-check with codesign on the first installed app it reports as Developer ID (none here: skipped).
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        for name in apps.prefix(40) {
            let url = URL(fileURLWithPath: "/Applications/" + name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["-dvv", url.path]
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard text.contains("Authority=Developer ID Application") else { continue }
            #expect(TestSwitches.isDeveloperIDSigned(bundle: url), "\(name) is Developer ID signed")
            return
        }
    }
}
