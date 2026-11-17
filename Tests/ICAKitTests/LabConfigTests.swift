import Foundation
import Testing
@testable import ICAKit

// D110: lab/apps.conf and the test-app window matching.

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@Test func theRepositoryLabConfigParsesAndCoversTheSuite() throws {
    let config = try LabConfig.load(path: LabConfig.defaultPath(root: packageRoot, environment: [:]))
    #expect(config.resourceNames == ["Notepad", "WordPad", "Paint", "File Explorer", "Microsoft Edge", "LibreOffice Writer", "Lab Desktop"])
    #expect(config.tests.map(\.name) == ["text", "files", "image", "rich-wordpad", "rich-writer", "cdm", "policy"])
    let files = try #require(config.tests.first { $0.name == "files" })
    #expect(files.resource == "File Explorer" && files.environment == "ICA_GDT=1 ICA_CLIP_VERSION=4" && files.arguments == "cliptest-files")
    #expect(config.app("libreoffice writer")?.executables == ["soffice.bin", "soffice.exe", "swriter.exe"])
    #expect(config.app("Lab Desktop")?.executables == [])
    #expect(config.app("Lab Desktop")?.titleWord == nil)
    let writer = try #require(config.app("LibreOffice Writer"))
    #expect(writer.firstRunDialogs == ["Welcome to LibreOffice!", "Tip of the Day"])
    #expect(writer.onlyFirstRunDialogs(["Welcome to LibreOffice!"]))
    #expect(writer.onlyFirstRunDialogs(["Tip of the Day: 1/224", "Welcome to LibreOffice!"]))
    #expect(!writer.onlyFirstRunDialogs(["Tip"]))
    #expect(!writer.onlyFirstRunDialogs(["Welcome to LibreOffice!", "Save Document?"]))
    #expect(!writer.onlyFirstRunDialogs([]))
    #expect(config.app("Notepad")?.firstRunDialogs == [])
}

@Test func labConfigRejectsBrokenLines() {
    #expect(throws: LabConfig.ParseError.badLine(1, "expected app|<resource>|<executables>|<title word>[|<first-run dialogs>]")) {
        try LabConfig.parse("app|Notepad|notepad.exe")
    }
    #expect(throws: LabConfig.ParseError.unknownResource(2, "Paint")) {
        try LabConfig.parse("app|Notepad|notepad.exe|notepad\ntest|image|Paint||cliptest-rich image")
    }
    #expect(throws: LabConfig.ParseError.duplicate(2, "notepad")) {
        try LabConfig.parse("app|Notepad|notepad.exe|\napp|notepad|notepad.exe|")
    }
    #expect(throws: LabConfig.ParseError.duplicate(3, "t")) {
        try LabConfig.parse("app|A|a.exe|\ntest|t|A||x\ntest|t|A||y")
    }
    #expect(throws: LabConfig.ParseError.badLine(1, "unknown record \"apps\" (app or test)")) { try LabConfig.parse("apps|A|a.exe|") }
    #expect(throws: LabConfig.ParseError.badLine(2, "expected test|<name>|<resource>|<environment>|<icactl arguments>")) {
        try LabConfig.parse("app|A|a.exe|\ntest|t|A||")
    }
    #expect((try? LabConfig.parse("# only a comment\n\n   \n")) == LabConfig())
}

@Test func testAppMatchesByExecutableThenByAppKey() {
    let writer = TestApp(resource: "LibreOffice Writer", executables: ["soffice.bin", "Swriter.exe"], titleWord: "LibreOffice Writer")
    // A known executable decides alone, also against a matching key.
    #expect(writer.matches(executable: "C:\\Program Files\\LibreOffice\\program\\soffice.bin", appKey: nil))
    #expect(!writer.matches(executable: "C:\\Windows\\System32\\ctfmon.exe", appKey: "app:LibreOffice Writer"))
    // Unknown executable: the published app's key, or a key naming an executable's stem.
    #expect(writer.matches(executable: nil, appKey: "app:libreoffice writer"))
    #expect(writer.matches(executable: "", appKey: "exe:c:\\program files\\libreoffice\\program\\swriter"))
    #expect(!writer.matches(executable: nil, appKey: "app:Notepad"))
    #expect(!writer.matches(executable: nil, appKey: nil))
    #expect(writer.isDocumentTitle("Untitled 1 - LibreOffice Writer"))
    #expect(!writer.isDocumentTitle("LibreOffice"))
    #expect(TestApp(resource: "File Explorer", executables: ["explorer.exe"]).isDocumentTitle("This PC"))
}
