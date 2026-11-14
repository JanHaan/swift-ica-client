import Foundation

/// Discovery only (docs/76 §7.14, round 9): an INIT_RESPONSE module list recorded from the stock client's own session
/// (black box, D79), sent instead of ours. The UI module is never part of the file: it carries the recorded session's
/// logon ticket, so its slot is a placeholder and our own UI module goes there. Nothing of a recording belongs in the
/// repository; the file lives in `.session/` (icactl `relay-modules` writes it, `ICA_STOCK_MODULES` reads it).
///
/// File format: one module per line as hex (the module from its u16 byte count on, without the `01 len16` packet
/// header), the line `UI` for our UI module, `#` comments and blank lines ignored.
public struct WDStockReplay: Sendable, Equatable {
    public enum Slot: Sendable, Equatable {
        case ui
        case module([UInt8])
    }

    public enum Failure: Error, Equatable {
        case badLine(Int)
        case noUISlot
        case noWDModule
        case badWDModule(String)
    }

    public var slots: [Slot]

    public init(slots: [Slot]) { self.slots = slots }

    public static func parse(_ text: String) throws -> WDStockReplay {
        var slots: [Slot] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "UI" { slots.append(.ui); continue }
            guard line.count % 2 == 0, line.count >= 72 else { throw Failure.badLine(index + 1) }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(line.count / 2)
            var i = line.startIndex
            while i < line.endIndex {
                let j = line.index(i, offsetBy: 2)
                guard let b = UInt8(line[i..<j], radix: 16) else { throw Failure.badLine(index + 1) }
                bytes.append(b)
                i = j
            }
            slots.append(.module(bytes))
        }
        guard slots.contains(.ui) else { throw Failure.noUISlot }
        let replay = WDStockReplay(slots: slots)
        guard let wd = replay.wdModule else { throw Failure.noWDModule }
        _ = try WDModuleLayout(wd)
        return replay
    }

    /// The file text for a recorded module list; the UI module (class 0) is replaced by the placeholder.
    public static func fileText(modules: [[UInt8]], comment: String) -> String {
        var lines = comment.split(separator: "\n").map { "# " + $0 }
        for m in modules {
            if m.count >= 4, m[3] == WDModuleClass.ui.rawValue { lines.append("UI") }
            else { lines.append(m.map { String(format: "%02x", $0) }.joined()) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public var modules: [[UInt8]] {
        slots.compactMap { if case .module(let m) = $0 { return m } else { return nil } }
    }

    public var wdModule: [UInt8]? { modules.first { $0.count >= 4 && $0[3] == WDModuleClass.wd.rawValue } }

    public var wdLayout: WDModuleLayout? { wdModule.flatMap { try? WDModuleLayout($0) } }

    /// The key a module is matched by against ours (`WDModuleOverride.key` of our names): UI, WD, TD, PDRFRAME,
    /// PDCRYPT1, or the VC name from the WD module's bind table for a VD (by its channel number, u32 @36).
    public func key(of module: [UInt8]) -> String {
        guard module.count >= 4 else { return "?" }
        switch module[3] {
        case WDModuleClass.ui.rawValue: return "UI"
        case WDModuleClass.wd.rawValue: return "WD"
        case WDModuleClass.td.rawValue: return "TD"
        case WDModuleClass.pd.rawValue:
            let host = String(decoding: module[19..<min(28, module.count)].prefix { $0 != 0 }, as: UTF8.self)
            return host.uppercased()
        case WDModuleClass.vd.rawValue:
            guard module.count >= 40 else { return "?" }
            let channel = UInt32(module[36]) | UInt32(module[37]) << 8 | UInt32(module[38]) << 16 | UInt32(module[39]) << 24
            if let entry = wdLayout?.bindTable.first(where: { UInt32($0.number) == channel }) {
                return WDModuleOverride.key(entry.name)
            }
            return "CH\(channel)"
        default: return "?"
        }
    }
}

/// Field view of a WD module (docs/30 §5.3): the offsets our builder writes, read back from any WD module.
public struct WDModuleLayout: Sendable, Equatable {
    public var bytes: [UInt8]
    public var bindTable: [(name: String, number: UInt8)] {
        let count = Int(u16(72)), offset = Int(u16(74))
        return (0..<count).compactMap { i in
            let at = offset + 10 * i
            guard at + 10 <= bytes.count else { return nil }
            return (String(decoding: bytes[at..<(at + 7)], as: UTF8.self), bytes[at + 8])
        }
    }
    public var reducerPower: UInt8 { bytes[76] }
    public var expanderPower: UInt8 { bytes[77] }
    public var maxReducerVersion: UInt16 { u16(80) }
    public var capabilityRange: Range<Int> { Int(u16(84))..<(Int(u16(84)) + Int(u16(82))) }
    public var capabilities: [WDCapability] { (try? WDCapabilityBlock.parse(Array(bytes[capabilityRange]))) ?? [] }
    public var productID: UInt16 { u16(66) }

    public static func == (a: WDModuleLayout, b: WDModuleLayout) -> Bool { a.bytes == b.bytes }

    public init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 86, bytes[3] == WDModuleClass.wd.rawValue else { throw WDStockReplay.Failure.badWDModule("too short or not class 2") }
        self.bytes = bytes
        let caps = capabilityRange, tableEnd = Int(u16(74)) + 10 * Int(u16(72))
        guard caps.upperBound <= bytes.count, tableEnd <= bytes.count else { throw WDStockReplay.Failure.badWDModule("offsets out of range") }
        guard (try? WDCapabilityBlock.parse(Array(bytes[caps]))) != nil else { throw WDStockReplay.Failure.badWDModule("capability block") }
    }

    private func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }

    /// Reducer / expander powers (@76/@77) set to `reducer` / `expander`.
    public mutating func setPowers(reducer: UInt8, expander: UInt8) {
        bytes[76] = reducer
        bytes[77] = expander
    }

    /// Replaces the capability block (it is the last referenced data in our and the stock layout; anything after
    /// it is kept after the new block) and fixes its length and offset fields.
    public mutating func replaceCapabilities(_ caps: [WDCapability]) {
        let range = capabilityRange
        let block = WDCapabilityBlock.serialize(caps)
        bytes.replaceSubrange(range, with: block)
        bytes[82] = UInt8(block.count & 0xff)
        bytes[83] = UInt8(block.count >> 8)
        // Data referenced behind the old block moves with the size change.
        let delta = block.count - range.count
        if delta != 0, Int(u16(74)) > range.lowerBound {
            let moved = Int(u16(74)) + delta
            bytes[74] = UInt8(moved & 0xff)
            bytes[75] = UInt8(moved >> 8)
        }
        bytes[0] = UInt8(bytes.count & 0xff)
        bytes[1] = UInt8(bytes.count >> 8)
    }
}
