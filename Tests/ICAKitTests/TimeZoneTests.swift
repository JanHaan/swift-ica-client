import Foundation
import Testing
@testable import ICAKit

/// Caps 0x08/0x26, the client time zone (docs/30 §4.4).
@Suite struct TimeZoneTests {
    /// 2026-11-13 20:57 UTC, the day of the stock reference with the Mac in Europe/Berlin.
    let november = Date(timeIntervalSince1970: 1_794_603_420)
    /// 2026-07-01 12:00 UTC.
    let july = Date(timeIntervalSince1970: 1_782_907_200)

    func zone(_ id: String, _ now: Date) throws -> WDTimeZone {
        WDTimeZone(try #require(TimeZone(identifier: id)), now: now)
    }

    typealias Rule = WDTimeZone.Rule

    @Test func berlinMatchesTheStockClientsCapabilities() throws {
        let tz = try zone("Europe/Berlin", november)
        #expect(tz.bias == -60)
        #expect(tz.standardName == "W. Europe Standard Time" && tz.daylightName == tz.standardName)
        #expect(tz.standardDate == Rule(month: 10, dayOfWeek: 0, week: 5, hour: 3))
        #expect(tz.daylightDate == Rule(month: 3, dayOfWeek: 0, week: 5, hour: 2))
        #expect(tz.standardBias == 0 && tz.daylightBias == -60)
        // The stock client's own 0x08 body for this zone [B].
        #expect(tz.capability08Body == bytes(hex: """
            0100000001000000c4ffffff440000000a000000050003000000000000000000000000005c00000003000000050002000000\
            000000000000c4ffffff00000000572e204575726f7065205374616e646172642054696d6500572e204575726f706520537461\
            6e646172642054696d6500
            """))
        // Its 0x26 body, with the two padding words (uninitialised in the stock client) zeroed.
        #expect(tz.capability26Body == bytes(hex: """
            0100000001000000c4ffffff480000000a0000000500030000000000000000000000000060000000030000000500020000000000\
            00000000c4ffffff0200780000000000572e204575726f7065205374616e646172642054696d6500572e204575726f706520537461\
            6e646172642054696d65004575726f70652f4265726c696e00
            """))
        // In summer the rules and bias stay the same; body @4 says daylight time (2).
        let summer = try zone("Europe/Berlin", july)
        #expect(summer.bias == tz.bias && summer.standardDate == tz.standardDate && summer.daylightDate == tz.daylightDate)
        #expect(summer.inDaylightTime && summer.capability08Body[4] == 2 && tz.capability08Body[4] == 1)
    }

    @Test func newYork() throws {
        let tz = try zone("America/New_York", november)
        #expect(tz.bias == 300 && tz.standardName == "Eastern Standard Time")
        #expect(tz.daylightDate == Rule(month: 3, dayOfWeek: 0, week: 2, hour: 2))
        #expect(tz.standardDate == Rule(month: 11, dayOfWeek: 0, week: 1, hour: 2))
        #expect(tz.daylightBias == -60)
        #expect(try zone("America/New_York", july).daylightDate == tz.daylightDate)
    }

    @Test func kolkataHasAHalfHourOffsetAndNoDaylightTime() throws {
        let tz = try zone("Asia/Kolkata", november)
        #expect(tz.bias == -330 && tz.standardName == "India Standard Time")
        #expect(!tz.hasDaylightTime && tz.daylightBias == 0)
        let body = tz.capability08Body
        #expect(Array(body[8..<12]) == [0xB6, 0xFE, 0xFF, 0xFF])           // -330
        #expect(body[14..<30].allSatisfy { $0 == 0 } && body[38..<60].allSatisfy { $0 == 0 })
        #expect(try zone("Asia/Calcutta", july).standardName == "India Standard Time")
    }

    @Test func lordHoweHasHalfHourDaylightTime() throws {
        let tz = try zone("Australia/Lord_Howe", november)   // in daylight time (UTC+11) on that day
        #expect(tz.bias == -630 && tz.standardName == "Lord Howe Standard Time")
        #expect(tz.daylightDate == Rule(month: 10, dayOfWeek: 0, week: 1, hour: 2))
        #expect(tz.standardDate == Rule(month: 4, dayOfWeek: 0, week: 1, hour: 2))
        #expect(tz.daylightBias == -30)
        #expect(try zone("Australia/Lord_Howe", july).standardDate == tz.standardDate)
        // The stock client in the VM (Lord Howe, 2026-11-19, in daylight time) [B]: bias, rules, daylight bias and
        // body @4 = 2 as ours; its names were the abbreviations "+1030"/"+11", ours the Windows key name.
        let body = tz.capability08Body
        #expect(Array(body[0..<12]) == bytes(hex: "01000000020000008afdffff"))
        #expect(Array(body[14..<30]) == bytes(hex: "00000400000001000200000000000000"))
        #expect(Array(body[38..<60]) == bytes(hex: "00000a00000001000200000000000000" + "0000e2ffffff"))
    }

    @Test func sydneyIsASouthernHemisphereDaylightZone() throws {
        let tz = try zone("Australia/Sydney", november)   // in daylight time on that day
        #expect(tz.bias == -600 && tz.standardName == "AUS Eastern Standard Time")
        #expect(tz.daylightDate == Rule(month: 10, dayOfWeek: 0, week: 1, hour: 2))
        #expect(tz.standardDate == Rule(month: 4, dayOfWeek: 0, week: 1, hour: 3))
        #expect(tz.daylightBias == -60 && tz.capability08Body[4] == 2)
        #expect(try zone("Australia/Sydney", july).standardDate == tz.standardDate)
    }

    @Test func utcAndGMT() throws {
        for id in ["UTC", "GMT", "Etc/UTC"] {
            let tz = try zone(id, november)
            #expect(tz.bias == 0 && tz.standardName == "UTC" && !tz.hasDaylightTime, "\(id)")
        }
        #expect(try zone("GMT", november).ianaName == "GMT")
    }

    @Test func londonIsNotUTC() throws {
        let tz = try zone("Europe/London", november)
        #expect(tz.bias == 0 && tz.standardName == "GMT Standard Time")
        #expect(tz.daylightDate == Rule(month: 3, dayOfWeek: 0, week: 5, hour: 1))
        #expect(tz.standardDate == Rule(month: 10, dayOfWeek: 0, week: 5, hour: 2))
    }

    @Test func unmappedNamesFallBackToTheIANAName() throws {
        let tz = WDTimeZone(try #require(TimeZone(identifier: "Asia/Kathmandu")), now: november, windowsName: { _ in nil })
        #expect(tz.bias == -345 && tz.standardName == "Asia/Kathmandu")
    }

    @Test func layoutOffsetsPointAtTheNames() throws {
        let tz = try zone("America/New_York", november)
        let cap = WDCapability(id: WDCapability.timeZone, body: tz.capability26Body).bytes
        func u16(_ at: Int) -> Int { Int(cap[at]) | Int(cap[at + 1]) << 8 }
        func string(_ at: Int) -> String { String(decoding: cap[at...].prefix { $0 != 0 }, as: UTF8.self) }
        // Offsets count from the start of the capability (its 4-byte header included).
        #expect(string(u16(4 + 12)) == "Eastern Standard Time")
        #expect(string(u16(4 + 36)) == "Eastern Standard Time")
        #expect(u16(4 + 60) == 2 && string(u16(4 + 62)) == "America/New_York")
    }

    @Test func negotiationSendsBothCapsOnlyWhenTheServerOffersThem() throws {
        var policy = WDCapabilityPolicy()
        policy.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let server = [WDCapability(id: 0x08, body: [UInt8](repeating: 0, count: 64)),
                      WDCapability(id: 0x26, body: [UInt8](repeating: 0, count: 68))]
        let caps = policy.negotiate(server: server, now: november)
        #expect(caps.map(\.id) == [0x08, 0x26, 0x05])
        #expect(caps[0].body == (try zone("Asia/Kolkata", november)).capability08Body)
        #expect(!policy.negotiate(server: []).contains { $0.id == 0x08 || $0.id == 0x26 })
        policy.timeZone = nil
        #expect(policy.negotiate(server: server).map(\.id) == [0x05])
    }
}

/// The TLS log line (FEATURES "TLS 1.3").
@Test func tlsInfoNames() {
    #expect(TLSInfo(version: 0x0304, cipherSuite: 0x1301).description == "TLS 1.3, TLS_AES_128_GCM_SHA256")
    #expect(TLSInfo(version: .TLSv12, cipherSuite: .ECDHE_RSA_WITH_AES_256_GCM_SHA384).description
            == "TLS 1.2, TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384")
    #expect(TLSInfo(version: .DTLSv12, cipherSuite: .ECDHE_RSA_WITH_AES_128_GCM_SHA256).versionName == "DTLS 1.2")
    #expect(TLSInfo(version: 0x0305, cipherSuite: 0x0A0A).description == "version 0x0305, cipher suite 0x0A0A")
}
