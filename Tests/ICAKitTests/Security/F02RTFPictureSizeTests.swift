import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md, mac-F), finding F-02: host RTF picture size words (\picwgoal x \picscalex) must not trap the viewer. Offline.

@Suite struct F02RTFPictureSizeTests {
    @Test func rtfPictureSizeWordsThatOverflowDoNotTrap() {
        let png = ClipboardRichText.png(width: 1, height: 1, rgba: Data([255, 0, 0, 255]))!
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let rtf = "{\\rtf1 {\\pict\\pngblip\\picwgoal9999999999\\pichgoal-9999999999\\picscalex9999999999\\picscaley9999999999 \(hex)}}"
        let converted = ClipboardRichText.flatRTFD(fromRTF: Data(rtf.utf8))
        #expect(converted?.pictures == 1)
        let picture = ClipboardRichText.pictures(in: Data(rtf.utf8)).first
        #expect(picture?.widthTwips == Int.max)
        #expect(picture?.heightTwips == Int.min)
    }

    @Test func rtfPictureScalingStaysExactForOrdinaryValues() {
        let rtf = "{\\rtf1 {\\pict\\pngblip\\picwgoal1440\\pichgoal720\\picscalex50\\picscaley200 00}}"
        let picture = ClipboardRichText.pictures(in: Data(rtf.utf8)).first
        #expect(picture?.widthTwips == 720)
        #expect(picture?.heightTwips == 1440)
    }
}
