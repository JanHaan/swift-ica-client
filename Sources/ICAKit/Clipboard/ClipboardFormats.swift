import Foundation

/// Standard and registered format ids we convert (docs/70 §4.1, §4.2).
public enum ClipboardFormat {
    /// CF_BITMAP; on this channel the payload is a packed DIB, both ways (§4.5).
    public static let bitmap: UInt16 = 2
    /// CF_UNICODETEXT (§4.3).
    public static let unicodeText: UInt16 = 13
    /// Registered names; their ids are host-assigned per session (§3.2.3).
    public static let htmlName = "HTML Format"
    public static let rtfName = "Rich Text Format"

    /// Short label for logs (no contents).
    public static func label(_ id: UInt16, names: [UInt16: String] = [:]) -> String {
        switch id {
        case 1: return "CF_TEXT"
        case 2: return "CF_BITMAP"
        case 3: return "CF_METAFILEPICT"
        case 7: return "CF_OEMTEXT"
        case 8: return "CF_DIB"
        case 9: return "CF_PALETTE"
        case 13: return "CF_UNICODETEXT"
        case 14: return "CF_ENHMETAFILE"
        case 15: return "CF_HDROP"
        case 16: return "CF_LOCALE"
        case 17: return "CF_DIBV5"
        default:
            if let name = names[id] { return String(format: "0x%04X \"%@\"", id, name) }
            return String(format: "0x%04X", id)
        }
    }
}

/// An image on the clipboard: RGBA8, not premultiplied, rows top-down. The pixels may be produced
/// lazily (Mac → host: only when the host asks); `rgba()` may then run on the session queue.
public struct ClipboardImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let render: () -> Data?

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        render = { rgba }
    }

    public init(width: Int, height: Int, render: @escaping () -> Data?) {
        self.width = width
        self.height = height
        self.render = render
    }

    public func rgba() -> Data? { render() }
}

/// What one side's clipboard holds, in Mac terms. Never log the contents; use `summary`.
public struct ClipboardContent: @unchecked Sendable {
    /// Plain text with LF line ends.
    public var text: String?
    /// An HTML document (Mac `public.html`).
    public var html: String?
    /// RTF bytes without a trailing NUL (Mac `public.rtf`).
    public var rtf: Data?
    public var image: ClipboardImage?
    /// Mac files offered as FileGroupDescriptorW + FileContents (experimental, `Config.files`; docs/75 §7).
    public var files: [ClipboardLocalFile]?

    public init(text: String? = nil, html: String? = nil, rtf: Data? = nil, image: ClipboardImage? = nil,
                files: [ClipboardLocalFile]? = nil) {
        self.text = text
        self.html = html
        self.rtf = rtf
        self.image = image
        self.files = files
    }

    public var isEmpty: Bool {
        (text?.isEmpty ?? true) && (html?.isEmpty ?? true) && (rtf?.isEmpty ?? true) && image == nil && (files?.isEmpty ?? true)
    }

    /// Sizes and kinds only.
    public var summary: String {
        var parts: [String] = []
        if let text { parts.append("text \(text.utf16.count) units") }
        if let html { parts.append("html \(html.utf8.count) B") }
        if let rtf { parts.append("rtf \(rtf.count) B") }
        if let image { parts.append("image \(image.width)x\(image.height)") }
        if let files { parts.append("files \(files.count) (\(files.reduce(0) { $0 + $1.entry.size }) B)") }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }
}

// MARK: - CF_UNICODETEXT (§4.3)

public enum ClipboardText {
    /// Host → Mac: UTF-16LE, cut at the first U+0000, CRLF → LF. Lone surrogates become U+FFFD.
    public static func decodeHost(_ data: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var i = data.startIndex
        while i + 1 < data.endIndex {
            let unit = UInt16(data[i]) | UInt16(data[i + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { continue }
            out.append(unit)
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Mac → host: lone LF and lone CR become CRLF, UTF-16LE (surrogate pairs as they are), one U+0000.
    public static func encodeForHost(_ text: String) -> Data {
        let units = Array(text.utf16)
        var out = Data()
        out.reserveCapacity(units.count * 2 + 8)
        func put(_ u: UInt16) { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0D {
                put(0x0D); put(0x0A)
                if index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
            } else if unit == 0x0A {
                put(0x0D); put(0x0A)
            } else {
                put(unit)
            }
            index += 1
        }
        put(0)
        return out
    }
}

// MARK: - "HTML Format" / CF_HTML (§4.4)

public enum ClipboardHTML {
    static let startMarker = Array("<!--StartFragment-->".utf8)
    static let endMarker = Array("<!--EndFragment-->".utf8)
    /// Header size: five LF-terminated lines with 10-digit offsets.
    public static let headerLength = 100

    /// Mac → host: 100-byte ASCII header + UTF-8 body. A body without `<html` is wrapped with the
    /// fragment markers; a full document without markers gets them after `<body…>` and before
    /// `</body>` ([P], the reference does not say). Offsets are true byte offsets (§4.4 [P]).
    public static func build(_ html: String) -> Data {
        let body = Array(withMarkers(html).utf8)
        let start = (find(startMarker, in: body).map { $0 + startMarker.count }) ?? 0
        let end = findLast(endMarker, in: body) ?? body.count
        let (s, e) = start <= end ? (start, end) : (0, body.count)
        func digits(_ n: Int) -> String { String(format: "%010d", n) }
        let header = "Version:0.9\n"
            + "StartHTML:\(digits(headerLength))\n"
            + "EndHTML:\(digits(headerLength + body.count))\n"
            + "StartFragment:\(digits(headerLength + s))\n"
            + "EndFragment:\(digits(headerLength + e))\n"
        precondition(header.utf8.count == headerLength)
        return Data(header.utf8) + Data(body)
    }

    static func withMarkers(_ html: String) -> String {
        guard html.range(of: "<html", options: .caseInsensitive) != nil else {
            return "<html><body><!--StartFragment-->" + html + "<!--EndFragment--></body></html>"
        }
        if html.range(of: "<!--StartFragment-->") != nil, html.range(of: "<!--EndFragment-->") != nil { return html }
        var out = html
        if let close = out.range(of: "</body", options: [.caseInsensitive, .backwards])
            ?? out.range(of: "</html", options: [.caseInsensitive, .backwards]) {
            out.insert(contentsOf: "<!--EndFragment-->", at: close.lowerBound)
        } else {
            out += "<!--EndFragment-->"
        }
        if let open = out.range(of: "<body", options: .caseInsensitive) ?? out.range(of: "<html", options: .caseInsensitive),
           let gt = out[open.upperBound...].firstIndex(of: ">") {
            out.insert(contentsOf: "<!--StartFragment-->", at: out.index(after: gt))
        } else {
            out = "<!--StartFragment-->" + out
        }
        return out
    }

    /// Host → Mac: the fragment, from the header offsets (Microsoft's CF_HTML description), else from
    /// the markers, else the document between StartHTML/EndHTML (or from the first `<`). Nil if no HTML.
    public static func fragment(_ data: Data) -> String? {
        var bytes = [UInt8](data)
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        let header = parseHeader(bytes)
        if let s = header["StartFragment"], let e = header["EndFragment"], s >= 0, s <= e, e <= bytes.count {
            return String(decoding: bytes[s..<e], as: UTF8.self)
        }
        if let open = findInsensitive(Array("<!--StartFragment".utf8), in: bytes),
           let openEnd = find(Array("-->".utf8), in: bytes, from: open).map({ $0 + 3 }),
           let close = findInsensitive(Array("<!--EndFragment".utf8), in: bytes, from: openEnd) {
            return String(decoding: bytes[openEnd..<close], as: UTF8.self)
        }
        var s = header["StartHTML"] ?? -1
        var e = header["EndHTML"] ?? -1
        if s < 0 || s > bytes.count { s = bytes.firstIndex(of: UInt8(ascii: "<")) ?? bytes.count }
        if e < s || e > bytes.count { e = bytes.count }
        guard s < e else { return nil }
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }

    /// The fragment as a Mac `public.html` document.
    public static func macDocument(fragment: String) -> String {
        "<html><head><meta charset=\"utf-8\"></head><body>" + fragment + "</body></html>"
    }

    /// `Key:value` lines before the first `<` (at most 1 KiB), integer values only.
    static func parseHeader(_ bytes: [UInt8]) -> [String: Int] {
        let limit = min(bytes.count, bytes.firstIndex(of: UInt8(ascii: "<")) ?? bytes.count, 1024)
        let text = String(decoding: bytes[0..<limit], as: UTF8.self)
        var out: [String: Int] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if let value = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) { out[key] = value }
        }
        return out
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    static func findLast(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i }
            i -= 1
        }
        return nil
    }

    static func findInsensitive(_ needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        func lower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b + 0x20 : b }
        let n = needle.map(lower)
        guard !n.isEmpty, hay.count >= n.count, from <= hay.count - n.count else { return nil }
        var i = from
        while i <= hay.count - n.count {
            var match = true
            for j in 0..<n.count where lower(hay[i + j]) != n[j] { match = false; break }
            if match { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - "Rich Text Format" (§7 phase 2)

public enum ClipboardRTF {
    /// Host → Mac: trailing NULs removed [I].
    public static func decodeHost(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.last == 0 { bytes.removeLast() }
        return Data(bytes)
    }

    /// Mac → host: one NUL appended [I].
    public static func encodeForHost(_ rtf: Data) -> Data {
        var bytes = [UInt8](rtf)
        while bytes.last == 0 { bytes.removeLast() }
        return Data(bytes + [0])
    }
}

// MARK: - CF_BITMAP as a packed DIB (§4.5)

public enum ClipboardDIB {
    public enum Failure: Error, Equatable {
        case truncated, header(UInt32), size(Int, Int), bitCount(UInt16), compression(UInt32), masks
    }

    /// Host → Mac. Accepts BITMAPINFOHEADER (40) and, as an extension, the V4/V5 headers (108/124);
    /// 24 bpp BI_RGB and 32 bpp BI_RGB or BI_BITFIELDS with byte-aligned masks. Bottom-up as the
    /// reference requires; top-down (negative height) is accepted too ([P]). 32 bpp with every alpha
    /// byte 0 is opaque (§4.5 [P]).
    public static func decode(_ data: Data, maxSide: Int = 16384) throws -> ClipboardImage {
        let b = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        guard b.count >= 40 else { throw Failure.truncated }
        let headerSize = u32(0)
        guard headerSize == 40 || headerSize == 108 || headerSize == 124 else { throw Failure.header(headerSize) }
        guard b.count >= Int(headerSize) else { throw Failure.truncated }
        let width = Int(Int32(bitPattern: u32(4)))
        let rawHeight = Int(Int32(bitPattern: u32(8)))
        let height = abs(rawHeight)
        guard width > 0, height > 0, width <= maxSide, height <= maxSide else { throw Failure.size(width, rawHeight) }
        let bitCount = u16(14)
        let compression = u32(16)
        guard bitCount == 24 || bitCount == 32 else { throw Failure.bitCount(bitCount) }
        var masks: (r: UInt32, g: UInt32, b: UInt32) = (0x00FF_0000, 0x0000_FF00, 0x0000_00FF)
        var pixelOffset = Int(headerSize)
        switch compression {
        case 0:
            break
        case 3:
            guard bitCount == 32 else { throw Failure.compression(compression) }
            if headerSize == 40 {
                guard b.count >= 52 else { throw Failure.truncated }
                masks = (u32(40), u32(44), u32(48))
                pixelOffset = 52
            } else {
                masks = (u32(40), u32(44), u32(48))
            }
        default:
            throw Failure.compression(compression)
        }
        func shift(_ mask: UInt32) -> Int? {
            switch mask {
            case 0x0000_00FF: return 0
            case 0x0000_FF00: return 8
            case 0x00FF_0000: return 16
            case 0xFF00_0000: return 24
            default: return nil
            }
        }
        guard let rs = shift(masks.r), let gs = shift(masks.g), let bs = shift(masks.b), Set([rs, gs, bs]).count == 3 else {
            throw Failure.masks
        }
        let alphaShift = [0, 8, 16, 24].first { ![rs, gs, bs].contains($0) }!
        let bytesPerPixel = Int(bitCount) / 8
        let rowBytes = (width * bytesPerPixel + 3) & ~3
        guard b.count - pixelOffset >= rowBytes * height else { throw Failure.truncated }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var anyAlpha = false
        for row in 0..<height {
            let source = pixelOffset + (rawHeight > 0 ? height - 1 - row : row) * rowBytes
            let target = row * width * 4
            for x in 0..<width {
                let p = source + x * bytesPerPixel
                if bytesPerPixel == 3 {
                    out[target + x * 4] = b[p + 2]
                    out[target + x * 4 + 1] = b[p + 1]
                    out[target + x * 4 + 2] = b[p]
                    out[target + x * 4 + 3] = 0xFF
                } else {
                    let v = u32(p)
                    out[target + x * 4] = UInt8((v >> UInt32(rs)) & 0xFF)
                    out[target + x * 4 + 1] = UInt8((v >> UInt32(gs)) & 0xFF)
                    out[target + x * 4 + 2] = UInt8((v >> UInt32(bs)) & 0xFF)
                    let a = UInt8((v >> UInt32(alphaShift)) & 0xFF)
                    out[target + x * 4 + 3] = a
                    if a != 0 { anyAlpha = true }
                }
            }
        }
        if bytesPerPixel == 4, !anyAlpha {
            for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF }
        }
        return ClipboardImage(width: width, height: height, rgba: Data(out))
    }

    /// Mac → host, as the reference builds it: 40-byte header, BI_BITFIELDS with masks R 0x00FF0000,
    /// G 0x0000FF00, B 0x000000FF, 32 bpp, bottom-up B G R A (alpha in byte 4, no alpha mask).
    /// Total 52 + 4·w·h bytes. `rgba` is RGBA8, not premultiplied, top-down.
    public static func encode(width: Int, height: Int, rgba: Data) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var w = ByteWriter()
        w.u32(40)
        w.u32(UInt32(width))
        w.u32(UInt32(height))
        w.u16(1)
        w.u16(32)
        w.u32(3)
        w.u32(UInt32(4 * width * height))
        w.raw([UInt8](repeating: 0, count: 16))
        w.u32(0x00FF_0000)
        w.u32(0x0000_FF00)
        w.u32(0x0000_00FF)
        let src = [UInt8](rgba)
        var pixels = [UInt8](repeating: 0, count: 4 * width * height)
        for row in 0..<height {
            let s = (height - 1 - row) * width * 4
            let t = row * width * 4
            for x in 0..<width {
                pixels[t + x * 4] = src[s + x * 4 + 2]
                pixels[t + x * 4 + 1] = src[s + x * 4 + 1]
                pixels[t + x * 4 + 2] = src[s + x * 4]
                pixels[t + x * 4 + 3] = src[s + x * 4 + 3]
            }
        }
        w.raw(pixels)
        return w.data
    }
}
