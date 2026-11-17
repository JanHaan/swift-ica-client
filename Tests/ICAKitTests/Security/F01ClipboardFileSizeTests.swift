import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-01: host clipboard file sizes (64-bit nFileSize) must not trap the viewer. Offline.

@Suite struct F01ClipboardFileSizeTests {
    @Test func hostFileSizesThatOverflowAreRefusedNotTrapped() throws {
        let huge = UInt64(1) << 63
        let entries = [ClipboardFileEntry(name: "a.bin", size: huge), ClipboardFileEntry(name: "b.bin", size: huge)]
        #expect(throws: ClipboardStagingPlan.Failure.tooLarge(.max)) { try ClipboardStagingPlan.make(entries) }
        let max = [ClipboardFileEntry(name: "a.bin", size: .max), ClipboardFileEntry(name: "b.bin", size: 1)]
        #expect(throws: ClipboardStagingPlan.Failure.tooLarge(.max)) { try ClipboardStagingPlan.make(max) }
    }

    @Test func oneMaximalHostFileStillPlansAndThePoliciesDoNotTrap() throws {
        let plan = try ClipboardStagingPlan.make([ClipboardFileEntry(name: "a.bin", size: .max)])
        #expect(plan.totalBytes == .max)
        #expect(ClipboardTransferPolicy.needed(total: .max) == .max)
        #expect(ClipboardTransferPolicy.needed(total: 1000) == 1100)
        #expect(!ClipboardTransferPolicy.enoughSpace(free: .max, total: .max))
        #expect(ClipboardTransferPolicy().decide(total: .max) == .confirm)
    }
}
