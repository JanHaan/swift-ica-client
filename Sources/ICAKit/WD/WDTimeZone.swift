import Foundation

/// The client's time zone as the WD capabilities 0x08 and 0x26 carry it (docs/30 §4.4, black box from the stock Mac
/// client's own INIT_RESPONSE). The VDA puts the session into this zone when its policy "Use local time of client" says
/// so (User\ICA\TimeZoneControl\SessionTimeZone = UseClientTimeZone); otherwise the session keeps the server's zone.
///
/// The values follow Windows' TIME_ZONE_INFORMATION: `bias` in minutes with UTC = local time + bias, the two transition
/// rules in its "recurring" form (wYear 0, wDay = week of the month 1-5, 5 = the last), and the Windows key name
/// ("W. Europe Standard Time") in both name fields, as the stock client sends it.
public struct WDTimeZone: Equatable, Sendable, CustomStringConvertible {
    /// A transition rule: on the `week`-th `dayOfWeek` (0 Sunday … 6 Saturday; week 5 = the last) of `month`, at
    /// `hour:minute:second` of the local time in force before the transition.
    public struct Rule: Equatable, Sendable, CustomStringConvertible {
        public var month: UInt16
        public var dayOfWeek: UInt16
        public var week: UInt16
        public var hour: UInt16
        public var minute: UInt16
        public var second: UInt16

        public init(month: UInt16, dayOfWeek: UInt16, week: UInt16, hour: UInt16, minute: UInt16 = 0, second: UInt16 = 0) {
            self.month = month
            self.dayOfWeek = dayOfWeek
            self.week = week
            self.hour = hour
            self.minute = minute
            self.second = second
        }

        /// SYSTEMTIME: wYear 0, wMonth, wDayOfWeek, wDay (the week), wHour, wMinute, wSecond, wMilliseconds 0.
        var systemTime: [UInt8] {
            [0, month, dayOfWeek, week, hour, minute, second, 0].flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        }

        public var description: String {
            let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let which = week >= 5 ? "last" : "#\(week)"
            return "\(which) \(days[Int(dayOfWeek) % 7]) of month \(month) at " + String(format: "%02d:%02d", hour, minute)
                + (second != 0 ? String(format: ":%02d", second) : "")
        }
    }

    /// Minutes; UTC = local standard time + bias (Berlin -60, New York 300).
    public var bias: Int32
    public var standardName: String
    /// When daylight time ends; nil for a zone without daylight saving time.
    public var standardDate: Rule?
    public var standardBias: Int32
    public var daylightName: String
    /// When daylight time starts; nil without daylight saving time.
    public var daylightDate: Rule?
    /// Added to `bias` during daylight time (-60, Lord Howe -30); 0 without daylight saving time.
    public var daylightBias: Int32
    /// The IANA name (cap 0x26 only).
    public var ianaName: String
    /// Whether daylight time is in force at the moment the caps are built (body @4: 2, else 1).
    public var inDaylightTime: Bool

    public init(bias: Int32, standardName: String, standardDate: Rule? = nil, standardBias: Int32 = 0,
                daylightName: String? = nil, daylightDate: Rule? = nil, daylightBias: Int32 = 0, ianaName: String,
                inDaylightTime: Bool = false) {
        self.bias = bias
        self.standardName = standardName
        self.standardDate = standardDate
        self.standardBias = standardBias
        self.daylightName = daylightName ?? standardName
        self.daylightDate = daylightDate
        self.daylightBias = daylightBias
        self.ianaName = ianaName
        self.inDaylightTime = inDaylightTime
    }

    /// The zone's current rules, read from its transitions in the next years. `windowsName` maps the IANA name to the
    /// Windows key name (ICU's CLDR table by default); without a mapping the IANA name goes in both name fields.
    public init(_ zone: TimeZone, now: Date = Date(), windowsName: (String) -> String? = WindowsTimeZoneName.lookup) {
        let standardOffset = zone.secondsFromGMT(for: now) - Int(zone.daylightSavingTimeOffset(for: now).rounded())
        let name = windowsName(zone.identifier) ?? zone.identifier
        var starts: [(Rule, Bool)] = [], ends: [(Rule, Bool)] = []
        var daylightDelta = 0
        var cursor = now
        let horizon = now.addingTimeInterval(3 * 366 * 86400)
        while starts.count + ends.count < 6, let t = zone.nextDaylightSavingTimeTransition(after: cursor), t < horizon {
            cursor = t
            let before = zone.secondsFromGMT(for: t.addingTimeInterval(-1))
            guard let (rule, last) = Self.rule(at: t, offset: before) else { continue }
            if zone.isDaylightSavingTime(for: t) {
                daylightDelta = max(daylightDelta, Int(zone.daylightSavingTimeOffset(for: t).rounded()))
                starts.append((rule, last))
            } else {
                ends.append((rule, last))
            }
        }
        self.init(bias: Int32(-standardOffset / 60), standardName: name, ianaName: zone.identifier,
                  inDaylightTime: zone.isDaylightSavingTime(for: now))
        // Both transitions are needed; a zone that leaves daylight time for good (one transition) has none from then on.
        if let start = Self.merge(starts), let end = Self.merge(ends), daylightDelta != 0 {
            daylightDate = start
            standardDate = end
            daylightBias = Int32(-daylightDelta / 60)
        }
    }

    /// The wall clock of `instant` at UTC offset `offset` as a rule; the flag says whether the day is the month's last
    /// such weekday.
    static func rule(at instant: Date, offset: Int) -> (Rule, Bool)? {
        guard let fixed = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fixed
        let c = calendar.dateComponents([.month, .day, .weekday, .hour, .minute, .second], from: instant)
        guard let month = c.month, let day = c.day, let weekday = c.weekday,
              let days = calendar.range(of: .day, in: .month, for: instant)?.count else { return nil }
        let rule = Rule(month: UInt16(month), dayOfWeek: UInt16(weekday - 1), week: UInt16((day - 1) / 7 + 1),
                        hour: UInt16(c.hour ?? 0), minute: UInt16(c.minute ?? 0), second: UInt16(c.second ?? 0))
        return (rule, day + 7 > days)
    }

    /// One rule from the same transition in several years: week 5 when it fell on the month's last weekday every year
    /// ("last Sunday"), else the first year's week ("second Sunday").
    static func merge(_ seen: [(Rule, Bool)]) -> Rule? {
        guard var rule = seen.first?.0 else { return nil }
        if seen.allSatisfy(\.1) { rule.week = 5 }
        return rule
    }

    public var hasDaylightTime: Bool { daylightDate != nil && standardDate != nil }

    /// The first 60 body bytes, shared by both caps; the name offsets count from the cap's start (its 4-byte header).
    private func fixedPart(standardOffset: Int, daylightOffset: Int) -> [UInt8] {
        var out: [UInt8] = []
        func u16(_ v: Int) { out += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func u32(_ v: UInt32) { out += (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        let zeroRule = [UInt8](repeating: 0, count: 16)
        u32(1)                         // @0 [B] always 1
        u32(hasDaylightTime && inDaylightTime ? 2 : 1)   // @4 [B] 2 in daylight time, else 1 (TIME_ZONE_ID_*)
        i32(bias)                      // @8
        u16(standardOffset)            // @12
        out += standardDate?.systemTime ?? zeroRule   // @14
        u16(0)                         // @30 padding
        i32(standardBias)              // @32
        u16(daylightOffset)            // @36
        out += daylightDate?.systemTime ?? zeroRule   // @38
        u16(0)                         // @54 padding
        i32(hasDaylightTime ? daylightBias : 0)       // @56
        return out
    }

    static func cString(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { $0.isASCII && $0.value != 0 ? UInt8($0.value) : UInt8(ascii: "?") } + [0]
    }

    /// Cap 0x08 body: the fixed part, u32 0, then the standard and daylight names (ASCII, NUL-terminated).
    public var capability08Body: [UInt8] {
        let std = Self.cString(standardName), dl = Self.cString(daylightName)
        let first = 4 + 64
        return fixedPart(standardOffset: first, daylightOffset: first + std.count) + [0, 0, 0, 0] + std + dl
    }

    /// Cap 0x26 body: the fixed part, u16 version 2, u16 offset of the IANA name, u32 0, then the standard, daylight and
    /// IANA names.
    public var capability26Body: [UInt8] {
        let std = Self.cString(standardName), dl = Self.cString(daylightName), iana = Self.cString(ianaName)
        let first = 4 + 68
        let ianaOffset = first + std.count + dl.count
        return fixedPart(standardOffset: first, daylightOffset: first + std.count)
            + [0x02, 0x00, UInt8(ianaOffset & 0xff), UInt8(ianaOffset >> 8), 0, 0, 0, 0] + std + dl + iana
    }

    public static let extendedCapability: UInt16 = 0x26

    public var description: String {
        let dst = hasDaylightTime ? ", daylight \(daylightDate!) to \(standardDate!), daylight bias \(daylightBias)" : ", no daylight time"
        return "\(ianaName) = \"\(standardName)\", bias \(bias)\(dst)"
    }
}

/// The Windows time zone key name for an IANA name, from the CLDR table ICU carries (macOS' libicucore,
/// `ucal_getWindowsTimeZoneID`). nil when ICU has no mapping or the function is missing.
public enum WindowsTimeZoneName {
    private typealias Lookup = @convention(c) (UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32,
                                               UnsafeMutablePointer<Int32>) -> Int32

    private static let function: Lookup? = {
        guard let handle = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "ucal_getWindowsTimeZoneID") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    public static func lookup(_ iana: String) -> String? {
        guard let function else { return nil }
        let id = Array(iana.utf16)
        var out = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let n = function(id, Int32(id.count), &out, Int32(out.count), &status)
        // U_ZERO_ERROR 0; warnings are negative, failures positive.
        guard status <= 0, n > 0, n < out.count else { return nil }
        return String(utf16CodeUnits: out, count: Int(n))
    }
}
