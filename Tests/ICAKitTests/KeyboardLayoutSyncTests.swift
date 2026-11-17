import Testing
@testable import ICAKit

// Keyboard layout sync (backlog 2.3, D141): Mac input source ids → Windows KLIDs.

@Test func requiredLayoutsMapToTheirWindowsKLIDs() {
    let expected: [String: UInt32] = [
        "German": 0x0000_0407, "US": 0x0000_0409, "British": 0x0000_0809, "French": 0x0000_040C,
        "SwissGerman": 0x0000_0807, "Dutch": 0x0000_0413, "Spanish": 0x0000_040A, "Italian": 0x0000_0410,
        "Dvorak": 0x0001_0409,
    ]
    for (name, klid) in expected {
        #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.\(name)") == klid, "\(name)")
    }
}

@Test func layoutVariantsShareTheNationalKLID() {
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.ABC") == 0x0000_0409)
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.British-PC") == 0x0000_0809)
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.Italian-Pro") == 0x0000_0410)
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.Austrian") == 0x0000_0407)
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.USInternational-PC") == 0x0002_0409)
}

@Test func unknownSourcesAreNotMapped() {
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.keylayout.Klingon") == nil)
    #expect(KeyboardLayoutSync.klid(forInputSource: "com.apple.inputmethod.SCIM.ITABC") == nil)
    #expect(KeyboardLayoutSync.klid(forInputSource: "German") == nil)
}

@Test func environmentOverridesTheInputSource() {
    let r = KeyboardLayoutSync.sessionLayout(environment: ["ICA_KBD_LAYOUT": "00000809"])
    #expect(r.klid == 0x0000_0809 && r.source == "ICA_KBD_LAYOUT")
}

@Test func onlyPrintableCharactersGoAsText() {
    #expect(KeyboardLayoutSync.isPrintable("ä"))
    #expect(KeyboardLayoutSync.isPrintable("€"))
    #expect(KeyboardLayoutSync.isPrintable(" "))
    #expect(!KeyboardLayoutSync.isPrintable(""))             // a dead key
    #expect(!KeyboardLayoutSync.isPrintable("\r"))           // return
    #expect(!KeyboardLayoutSync.isPrintable("\u{7f}"))       // delete
    #expect(!KeyboardLayoutSync.isPrintable("\u{F700}"))     // up arrow (AppKit function-key range)
}
