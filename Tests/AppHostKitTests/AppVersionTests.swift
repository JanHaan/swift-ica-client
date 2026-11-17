import Foundation
import Testing
@testable import AppHostKit

@Suite struct AppVersionTests {
    @Test func releaseInfo() {
        let v = AppVersion(info: ["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "123", "ICAGitCommit": "abc1234"])
        #expect(!v.isDevelopment)
        #expect(v.buildLine == "Build 123, abc1234")
        #expect(v.displayString() == "Version 0.6.0 (Build 123, abc1234)")
        #expect(v.reportString() == "ICAViewer 0.6.0 (Build 123, abc1234)")
        #expect(v.shortString() == "0.6.0")
    }

    @Test func dirtyCommitAndMissingCommit() {
        let dirty = AppVersion(info: ["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "7", "ICAGitCommit": "abc1234-dirty"])
        #expect(dirty.buildLine == "Build 7, abc1234-dirty")
        let noGit = AppVersion(info: ["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "1"])
        #expect(noGit.buildLine == "Build 1")
        #expect(noGit.displayString() == "Version 0.6.0 (Build 1)")
    }

    @Test func missingKeys() {
        for info in [nil, [:], ["CFBundleShortVersionString": "  "], ["CFBundleVersion": 5]] as [[String: Any]?] {
            let v = AppVersion(info: info)
            #expect(v.isDevelopment)
            #expect(v.displayString() == "Development build")
            #expect(v.shortString() == "development build")
        }
        #expect(AppVersion(info: nil).reportString() == "ICAViewer development build")
        #expect(AppVersion(info: ["ICAGitCommit": "abc"]).reportString() == "ICAViewer development build (abc)")
    }

    @Test func helperCredits() {
        let host = AppVersion(info: ["CFBundleShortVersionString": "0.6.0"])
        #expect(HelperMenu.aboutCredits(german: false, host: host) == "Remote app via ICA Viewer\nShown by ICA Viewer 0.6.0")
        #expect(HelperMenu.aboutCredits(german: true, host: AppVersion(info: nil)).hasSuffix("Entwicklungs-Build"))
    }
}
