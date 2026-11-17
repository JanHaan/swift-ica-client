import Testing
import Foundation
@testable import ICAKit

// Clipboard ordering (mac-C's VM scenario): a Mac copy the poll has not seen yet when the host's list arrives is
// older than the host's copy and must not override it; a Mac copy made while the host data is being fetched is newer
// and wins, as before.

private final class Board: ClipboardPasteboard {
    var changeCount = 1
    var text = "start"
    func readContent() -> ClipboardContent? { ClipboardContent(text: text) }
    func writeContent(_ content: ClipboardContent) -> Int { text = content.text ?? ""; changeCount += 1; return changeCount }
    func macCopy(_ t: String) { text = t; changeCount += 1 }
}

@Suite struct ClipboardOrderingTests {
    private func ready() -> (ClipboardSync, Board, () -> [String]) {
        let board = Board()
        let sync = ClipboardSync(pasteboard: board)
        var announced: [String] = []
        sync.announce = { announced.append($0.content?.text ?? "") }
        sync.channelReady()
        return (sync, board, { announced })
    }

    @Test func aMacCopyBeforeTheHostListLosesToTheHostCopy() {
        let (sync, board, announced) = ready()
        board.macCopy("mac, copied first")                         // not yet seen by the 500 ms poll
        sync.hostListed()                                          // then the remote copy's list arrives
        #expect(sync.hostContent(ClipboardContent(text: "host, copied second")))
        #expect(board.text == "host, copied second")
        #expect(!sync.check("poll"))                               // the older Mac copy is not announced afterwards
        #expect(announced() == ["start"])
    }

    @Test func aMacCopyDuringTheHostFetchStillWins() {
        let (sync, board, announced) = ready()
        sync.hostListed()
        board.macCopy("mac, copied while the host data was fetched")
        #expect(!sync.hostContent(ClipboardContent(text: "host")))
        #expect(board.text == "mac, copied while the host data was fetched")
        #expect(announced().last == "mac, copied while the host data was fetched")
    }

    @Test func withoutAHostListMarkTheOldRuleHolds() {
        let (sync, board, _) = ready()
        board.macCopy("mac")
        #expect(!sync.hostContent(ClipboardContent(text: "host")))  // e.g. a caller that never reports the list
        #expect(board.text == "mac")
    }
}
