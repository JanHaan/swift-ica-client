import Foundation

/// Readings of docs/30-winstation.md §12.3 where the text leaves a choice open. The defaults are the only
/// combination that decodes the recorded stock-client session (both directions, every frame); the
/// alternatives are kept switchable for tests and further captures.
public struct WDV3CoderOptions: Equatable, Sendable {
    /// One context table for all models of the coder (true) or one per model.
    public var sharedContextTable = true
    /// One match state (remaining length, source, pending-at-segment-end) for all models (true) or one per
    /// model. Shared: a match pending at the end of any coded segment is resolved at the start of the next
    /// coded segment, whatever its channel.
    public var sharedMatchState = true
    /// The tree build at initialisation is a full rebuild, i.e. it also halves the counts.
    public var halveAtInit = true
    /// Countdown before the first rebuild.
    public var initialCountdown = 50
    /// Rebuild period; on each rebuild it first grows ×1.5 (capped) and then becomes the new countdown,
    /// so the countdowns after rebuilds are 75, 112, 168, 252, 378, 500, 500, …
    public var initialPeriod = 50
    public var maxPeriod = 500
    /// For the word-boundary countdown, a literal coded after a prediction miss starts at its miss flag bit.
    public var missFlagInLiteral = true
    /// Leaves enter the weight-sorted list in class order 0…8 (true) or 8…0.
    public var leavesAscending = true
    public init() {}
}

public enum WDV3CoderError: Error, Equatable {
    case badPower(Int)
    case undefinedModel(Int)
    case historyOverflow(needed: Int, free: Int)
    case badLength
    case badHuffman
    case badHistoryReference
    case matchOverrun
    case segmentTooLarge(Int)
}

/// LSB-first bit reader over 16-bit LE words, which is the same as LSB-first within bytes. Reads past `end`
/// supply 0. Consumed bytes = ceil(bits / 8) (§12.3 "Bit I/O": 2 × words − unread bits / 8).
struct WDV3BitReader {
    let bytes: [UInt8]
    let start: Int
    let end: Int
    var bit = 0

    init(_ bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.start = start
        self.end = end
    }

    mutating func read1() -> UInt32 {
        let i = start + bit >> 3
        let v = i < end ? UInt32(bytes[i] >> UInt8(bit & 7)) & 1 : 0
        bit += 1
        return v
    }

    mutating func read(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<n { v |= read1() << UInt32(k) }
        return v
    }

    func peek(_ n: Int) -> UInt32 {
        var copy = self
        return copy.read(n)
    }

    var consumedBytes: Int { (bit + 7) >> 3 }
}

/// LSB-first bit writer; the last byte may be partial (§12.3: flushed byte by byte).
struct WDV3BitWriter {
    var bytes: [UInt8] = []
    var bit = 0

    mutating func write(_ value: UInt32, _ n: Int) {
        for k in 0..<n {
            if bit & 7 == 0 { bytes.append(0) }
            if (value >> UInt32(k)) & 1 != 0 { bytes[bytes.count - 1] |= UInt8(1 << (bit & 7)) }
            bit += 1
        }
    }
}

/// Per-model literal model: rank permutation, 9 rank classes with a Huffman code over their counts.
struct WDV3LiteralModel {
    var rankToByte: [UInt8] = (0...255).map { UInt8($0) }
    var byteToRank: [UInt8] = (0...255).map { UInt8($0) }
    var counts: [Int] = [1, 1, 2, 4, 8, 16, 32, 64, 128]
    /// Rotating swap target rank per class (class 0/1 → rank 0, class c ≥ 2 → a rank of class c−1).
    var targets: [Int] = (0..<9).map { $0 < 2 ? 0 : 1 << ($0 - 2) }
    var codeBits = [UInt32](repeating: 0, count: 9)
    var codeLength = [Int](repeating: 0, count: 9)
    /// Internal nodes (child for bit 0, child for bit 1); a negative child is leaf −(class + 1).
    var tree: [(Int, Int)] = []
    var root = 0
    var countdown: Int
    var period: Int

    init(_ options: WDV3CoderOptions) {
        countdown = options.initialCountdown
        period = options.initialPeriod
        build(options)
        if options.halveAtInit { halve() }
    }

    static func classOf(rank: Int) -> Int {
        rank == 0 ? 0 : Int.bitWidth - rank.leadingZeroBitCount
    }

    mutating func halve() {
        for c in 0..<9 { counts[c] = (counts[c] >> 1) + 1 }
    }

    /// Huffman tree from a weight-sorted list (§12.3 "Huffman rebuild").
    mutating func build(_ options: WDV3CoderOptions) {
        tree = []
        var list: [(weight: Int, node: Int)] = []
        func insert(_ item: (weight: Int, node: Int)) {
            if list.isEmpty || item.weight <= list[0].weight { list.insert(item, at: 0) }
            else if item.weight >= list[list.count - 1].weight { list.append(item) }
            else {
                let i = list.firstIndex { $0.weight >= item.weight } ?? list.count
                list.insert(item, at: i)
            }
        }
        let order = options.leavesAscending ? Array(0..<9) : Array((0..<9).reversed())
        for c in order { insert((counts[c], -(c + 1))) }
        while list.count > 2 {
            let a = list.removeFirst(), b = list.removeFirst()
            tree.append((a.node, b.node))
            insert((a.weight + b.weight, tree.count - 1))
        }
        tree.append((list[0].node, list[1].node))
        root = tree.count - 1
        func walk(_ node: Int, _ bits: UInt32, _ depth: Int) {
            if node < 0 {
                codeBits[-node - 1] = bits
                codeLength[-node - 1] = depth
                return
            }
            walk(tree[node].0, bits, depth + 1)
            walk(tree[node].1, bits | 1 << UInt32(depth), depth + 1)
        }
        walk(root, 0, 0)
    }

    /// One word boundary crossed while coding a literal: decrement the countdown, or rebuild when it is
    /// already 0.
    mutating func tick(_ options: WDV3CoderOptions) {
        if countdown > 0 {
            countdown -= 1
            return
        }
        build(options)
        halve()
        period = min(period * 3 / 2, options.maxPeriod)
        countdown = period
    }

    /// Model update after a literal coded in bits [start, end): one tick if a 16-bit word filled up in
    /// that span (the decoder reloads / the encoder flushes a word), then count, swap and target rotation.
    mutating func update(rank: Int, start: Int, end: Int, _ options: WDV3CoderOptions) {
        if end >> 4 != start >> 4 { tick(options) }
        let c = Self.classOf(rank: rank)
        counts[c] += 1
        let t = targets[c]
        if t != rank {
            let a = rankToByte[rank], b = rankToByte[t]
            rankToByte[rank] = b; rankToByte[t] = a
            byteToRank[Int(a)] = UInt8(t); byteToRank[Int(b)] = UInt8(rank)
        }
        if c >= 2 { targets[c] = t + 1 == 1 << (c - 1) ? 1 << (c - 2) : t + 1 }
    }

    /// `flag`: bit position of the miss flag that preceded this literal, if any.
    mutating func decode(_ reader: inout WDV3BitReader, _ options: WDV3CoderOptions, flag: Int? = nil) throws -> UInt8 {
        let startBit = options.missFlagInLiteral ? (flag ?? reader.bit) : reader.bit
        var node = root
        var cls = -1
        for _ in 0..<9 {
            let child = reader.read1() == 0 ? tree[node].0 : tree[node].1
            if child < 0 { cls = -child - 1; break }
            node = child
        }
        guard cls >= 0 else { throw WDV3CoderError.badHuffman }
        let rank = cls < 2 ? cls : (1 << (cls - 1)) + Int(reader.read(cls - 1))
        let byte = rankToByte[rank]
        update(rank: rank, start: startBit, end: reader.bit, options)
        return byte
    }

    mutating func encode(_ byte: UInt8, _ writer: inout WDV3BitWriter, _ options: WDV3CoderOptions, flag: Int? = nil) {
        let startBit = options.missFlagInLiteral ? (flag ?? writer.bit) : writer.bit
        let rank = Int(byteToRank[Int(byte)])
        let cls = Self.classOf(rank: rank)
        writer.write(codeBits[cls], codeLength[cls])
        if cls >= 2 { writer.write(UInt32(rank - (1 << (cls - 1))), cls - 1) }
        update(rank: rank, start: startBit, end: writer.bit, options)
    }
}

/// The V3 coder of one direction (docs/30-winstation.md §12.3): shared history buffer, context table and
/// per-model literal models. Decodes compressed segments and runs the encoder over "recompress" segments.
public struct WDV3Coder {
    struct MatchState {
        /// −1 = no match; 0 = a match just ended (next byte is a literal without context, or, at a
        /// segment start, the match is pending); > 0 = bytes still to copy.
        var remaining = -1
        var source = 0
    }

    public let power: Int
    public let options: WDV3CoderOptions
    var history: [UInt8]
    var position = 4
    /// End of the usable history: free space = limit − position.
    let limit: Int
    var tables: [[UInt32]]
    var models: [WDV3LiteralModel]
    var matches: [MatchState]
    let indexMask: UInt32
    let tagMask: UInt32
    let positionMask: UInt32
    let shift: UInt32

    public init(power: Int, models count: Int = 32, options: WDV3CoderOptions = WDV3CoderOptions()) throws {
        guard (8...23).contains(power) else { throw WDV3CoderError.badPower(power) }
        self.power = power
        self.options = options
        history = [UInt8](repeating: 0, count: (1 << power) - 4 + 5)
        limit = 1 << power
        indexMask = UInt32(1 << (power - 3)) - 1
        positionMask = UInt32(1 << power) - 1
        tagMask = 0xFF_FFFF ^ positionMask
        shift = UInt32((32 - (power - 3)) | 1)
        tables = []
        models = []
        matches = []
        define(count)
    }

    public var modelCount: Int { models.count }

    /// DEFINE NUMBER OF CODERS: allocates/resets `count` models.
    public mutating func define(_ count: Int) {
        let n = max(count, 1)
        models = Array(repeating: WDV3LiteralModel(options), count: n)
        let tableCount = options.sharedContextTable ? 1 : n
        if tables.count != tableCount || !options.sharedContextTable {
            tables = Array(repeating: [UInt32](repeating: 0, count: 1 << (power - 3)), count: tableCount)
        }
        if matches.count != (options.sharedMatchState ? 1 : n) {
            matches = Array(repeating: MatchState(), count: options.sharedMatchState ? 1 : n)
        }
    }

    func context(_ p: Int) -> (index: Int, tag: UInt32) {
        let c = UInt32(history[p - 1]) << 24 | UInt32(history[p - 2]) << 16 | UInt32(history[p - 3]) << 8
        return (Int(((c >> 8) ^ (c >> shift)) & indexMask), c & tagMask)
    }

    mutating func prepare(_ n: Int) throws {
        guard n <= 65536 else { throw WDV3CoderError.segmentTooLarge(n) }
        if limit - position <= 2048 { position = 4 }
        guard n <= limit - position else { throw WDV3CoderError.historyOverflow(needed: n, free: limit - position) }
    }

    static func readLength(_ r: inout WDV3BitReader) throws -> Int {
        var groups = 0, low = 0
        while r.peek(7) == 0 {
            r.bit += 7
            low |= Int(r.read(7)) << (7 * groups)
            groups += 1
            guard groups <= 3 else { throw WDV3CoderError.badLength }
        }
        var k = 0
        while r.read1() == 0 { k += 1 }
        let value = ((1 << k) | Int(r.read(k))) << (7 * groups) | low
        guard value <= 65536 else { throw WDV3CoderError.badLength }
        return value
    }

    static func writeLength(_ value: Int, _ w: inout WDV3BitWriter) {
        var v = value
        while v >= 128 {
            w.write(0, 7)
            w.write(UInt32(v & 0x7F), 7)
            v >>= 7
        }
        let k = Int.bitWidth - 1 - v.leadingZeroBitCount
        w.write(0, k)
        w.write(1, 1)
        w.write(UInt32(v - (1 << k)), k)
    }

    /// Decodes one compressed segment of `length` output bytes for `model` from `bytes[offset..<end]`.
    /// Returns the output and the number of compressed bytes consumed.
    public mutating func decode(model m: Int, length n: Int, from bytes: [UInt8], offset: Int, end: Int) throws
        -> (output: [UInt8], consumed: Int) {
        guard m >= 0, m < models.count else { throw WDV3CoderError.undefinedModel(m) }
        try prepare(n)
        let start = position
        let ti = options.sharedContextTable ? 0 : m
        let mi = options.sharedMatchState ? 0 : m
        var st = matches[mi]
        var reader = WDV3BitReader(bytes, start: offset, end: end)
        let hcount = history.count
        // A match left pending by the previous segment: 0 = it continues for L more bytes, 1 = it ends.
        if st.remaining == 0 && n > 0 && reader.read1() == 0 {
            st.remaining = try Self.readLength(&reader)
        }
        var produced = 0
        while produced < n {
            let pos = position
            if st.remaining > 0 {
                guard st.source < hcount else { throw WDV3CoderError.badHistoryReference }
                history[pos] = history[st.source]
                st.source += 1
                st.remaining -= 1
            } else if st.remaining == 0 {
                st.remaining = -1
                history[pos] = try models[m].decode(&reader, options)
            } else {
                let (index, tag) = context(pos)
                let entry = tables[ti][index]
                let flagBit = reader.bit
                let valid = entry & tagMask == tag
                if valid && reader.read1() == 0 {
                    let p = 4 + Int(entry & positionMask)
                    let q = UInt8(entry >> 24)
                    tables[ti][index] = (entry & ~positionMask) | UInt32(pos - 4)
                    if p >= hcount || history[p] != q {
                        history[pos] = q
                    } else {
                        let length = try Self.readLength(&reader)
                        guard length <= n - produced else { throw WDV3CoderError.matchOverrun }
                        history[pos] = q
                        st.source = p + 1
                        st.remaining = length - 1
                    }
                } else {
                    let byte = try models[m].decode(&reader, options, flag: valid ? flagBit : nil)
                    history[pos] = byte
                    tables[ti][index] = tag | UInt32(pos - 4) | UInt32(byte) << 24
                }
            }
            position += 1
            produced += 1
        }
        guard st.remaining <= 0 else { throw WDV3CoderError.matchOverrun }
        matches[mi] = st
        return (Array(history[start..<position]), reader.consumedBytes)
    }

    /// Greedy encoder (§12.3 "Encoder decisions"). Returns the compressed bytes; the expander discards them
    /// for "recompress" segments, which only need the model updates.
    @discardableResult
    public mutating func encode(model m: Int, _ input: [UInt8]) throws -> [UInt8] {
        guard m >= 0, m < models.count else { throw WDV3CoderError.undefinedModel(m) }
        let n = input.count
        try prepare(n)
        let ti = options.sharedContextTable ? 0 : m
        let mi = options.sharedMatchState ? 0 : m
        var st = matches[mi]
        var w = WDV3BitWriter()
        let hcount = history.count
        var i = 0

        /// Extends a match from history[src] against input[i...], writing the input into history as it goes.
        func extend(_ src: Int) -> Int {
            var k = 0
            while i + k < n, src + k < hcount, history[src + k] == input[i + k] {
                history[position + k] = input[i + k]
                k += 1
            }
            return k
        }

        if st.remaining == 0 && n > 0 {
            let k = extend(st.source)
            if k > 0 {
                w.write(0, 1)
                Self.writeLength(k, &w)
                st.source += k
                position += k
                i += k
            } else {
                w.write(1, 1)
            }
        }
        while i < n {
            let pos = position
            let byte = input[i]
            if st.remaining == 0 {
                st.remaining = -1
                models[m].encode(byte, &w, options)
                history[pos] = byte
                position += 1
                i += 1
                continue
            }
            let (index, tag) = context(pos)
            let old = tables[ti][index]
            tables[ti][index] = tag | UInt32(pos - 4) | UInt32(byte) << 24
            let valid = old & tagMask == tag
            if valid && UInt8(old >> 24) == byte {
                w.write(0, 1)
                let p = 4 + Int(old & positionMask)
                if p < hcount && history[p] == byte {
                    let k = extend(p)
                    Self.writeLength(k, &w)
                    st.source = p + k
                    st.remaining = 0
                    position += k
                    i += k
                } else {
                    history[pos] = byte
                    position += 1
                    i += 1
                }
                continue
            }
            let flagBit = w.bit
            if valid { w.write(1, 1) }
            models[m].encode(byte, &w, options, flag: valid ? flagBit : nil)
            history[pos] = byte
            position += 1
            i += 1
        }
        matches[mi] = st
        return w.bytes
    }
}
