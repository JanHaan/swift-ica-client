import Testing
@testable import ICAKit

/// Edit menu items in helper apps are sent as their shortcut: the key that types the letter in the current
/// layout, searched over every key code (docs/99 §12 phase 2).
@Suite struct KeyLayoutSearchTests {
    /// Dvorak (positions as kVK codes): V is on the ANSI-period key, Z on the ANSI-slash key, C on I, X on B, A on A.
    static let dvorak: [UInt16: String] = [0x2F: "v", 0x2C: "z", 0x22: "c", 0x0B: "x", 0x00: "a", 0x09: ".", 0x06: ";"]
    /// German QWERTZ: Y and Z swapped.
    static let german: [UInt16: String] = [0x10: "z", 0x06: "y", 0x09: "v", 0x08: "c"]

    @Test func searchesEveryKeyCodeOfTheLayout() {
        #expect(KeyLayoutSearch.keyCode(typing: "v") { Self.dvorak[$0] } == 0x2F)
        #expect(KeyLayoutSearch.keyCode(typing: "z") { Self.dvorak[$0] } == 0x2C)
        #expect(KeyLayoutSearch.keyCode(typing: "c") { Self.dvorak[$0] } == 0x22)
        #expect(KeyLayoutSearch.keyCode(typing: "X") { Self.dvorak[$0] } == 0x0B)
        #expect(KeyLayoutSearch.keyCode(typing: "z") { Self.german[$0] } == 0x10)
        #expect(KeyLayoutSearch.keyCode(typing: "v") { Self.german[$0] } == 0x09)
        #expect(KeyLayoutSearch.keyCodes.contains(0x7F) && KeyLayoutSearch.keyCodes.count == 0x80)
    }

    @Test func fallsBackToTheANSIPosition() {
        #expect(KeyLayoutSearch.keyCode(typing: "v", translate: nil) == 0x09)
        #expect(KeyLayoutSearch.keyCode(typing: "z", translate: nil) == 0x06)
        // A layout without the letter (e.g. a non-Latin layout): the ANSI position.
        #expect(KeyLayoutSearch.keyCode(typing: "a") { _ in "ж" } == 0x00)
        #expect(KeyLayoutSearch.keyCode(typing: "ä", translate: nil) == nil)
    }
}
