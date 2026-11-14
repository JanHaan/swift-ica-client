import Foundation
import Testing
@testable import ICAKit

/// D83: server → client V3 compression offered in the WD module.
@Suite struct CompressionOfferTests {
    @Test func wdModuleCarriesTheExpanderPowerAtOffset77() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let off = WDModules.wd(capabilities: [], channels: [], reducerVersion: 3, date: date)
        let on = WDModules.wd(capabilities: [], channels: [], reducerVersion: 3, expanderPower: 19, date: date)
        #expect(off[76] == 0 && off[77] == 0)
        #expect(on[76] == 0 && on[77] == 19)
        var same = on
        same[77] = 0
        #expect(same == off)
    }

    @Test func environmentSwitch() {
        typealias C = WinstationDriver.Configuration
        #expect(C().expanderPowerOffer == 0)
        #expect(C.expanderPowerOffer(environment: [:]) == 19)
        #expect(C.expanderPowerOffer(environment: ["ICA_COMPRESSION": "0"]) == 0)
        #expect(C.expanderPowerOffer(environment: ["ICA_COMPRESSION": "17"]) == 17)
        #expect(C.expanderPowerOffer(environment: ["ICA_COMPRESSION": "99"]) == 19)
        #expect(C.expanderPowerOffer(environment: ["ICA_COMPRESSION": "x"]) == 19)
    }
}
