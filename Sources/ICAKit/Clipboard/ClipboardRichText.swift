import CoreGraphics
import Foundation
import ImageIO

// MARK: - Pictures in RTF ↔ Apple RTFD (docs/70 §4.9)
//
// Public sources:
// - Microsoft, "Rich Text Format (RTF) Specification, version 1.9.1" (2008), "Pictures": the `{\pict …}` group with a
//   format word (`\pngblip`, `\jpegblip`, `\emfblip`, `\wmetafileN`, `\dibitmapN`, `\wbitmapN`, `\macpict`), `\picwN`
//   `\pichN` (pixels for bitmaps), `\picwgoalN` `\pichgoalN` (twips), `\picscalexN` `\picscaleyN` (percent), the data as
//   hex digits or `\binN` raw bytes; "Word 97 through Word 2007 RTF for Drawing Objects": `{\*\shppict {\pict …}}`
//   carries the picture and `{\nonshppict {\pict …}}` a fallback copy (usually a WMF) for older readers.
// - Microsoft, "Standard Clipboard Formats" / "Clipboard Formats": "Rich Text Format" is a registered format name.
// - Apple, NSAttributedString / FileWrapper: RTFD is a directory (`TXT.rtf` plus one file per attachment);
//   `com.apple.flat-rtfd` (NSPasteboard.PasteboardType.rtfd) is its serialized form (FileWrapper
//   `serializedRepresentation`).
// - Observed from AppKit on this Mac (black box, our own test data): AppKit writes an attachment inside TXT.rtf as
//   `{{\NeXTGraphic <file name> \widthN \heightN \appleattachmentpadding0 \appleembedtype0 \appleaqc
//   }<0xAC>}` (\width/\height in twips), reads the same group back as an attachment, drops attachments when it writes
//   plain RTF, and ignores `\pict` when it reads RTF.
//
// So a Mac copy with an image (TextEdit, Notes) reaches Windows apps only through RTFD → RTF with `\pict`, and a Word
// copy reaches Mac apps only through RTF `\pict` → RTFD.

public enum ClipboardRichText {
    /// One `{\pict …}` group.
    public struct Picture: Equatable, Sendable {
        public enum Kind: String, Sendable { case png, jpeg, emf, wmf, dib, bitmap, other }
        public var kind: Kind
        public var data: Data
        /// As written (`\picw`, `\pich`; Word writes 0.01 mm here even for PNG).
        public var picw: Int?
        public var pich: Int?
        /// Display size in twips, scaled by `\picscalex`/`\picscaley`.
        public var widthTwips: Int?
        public var heightTwips: Int?

        /// Pixel size from the picture data itself (PNG, JPEG, DIB); nil for metafiles.
        public var pixelSize: (width: Int, height: Int)? {
            switch kind {
            case .png, .jpeg: return ClipboardRichText.imageSize(data)
            case .dib:
                guard let image = try? ClipboardDIB.decode(data) else { return nil }
                return (image.width, image.height)
            default: return nil
            }
        }

        /// PNG or JPEG bytes a Mac app can show (a DIB is re-encoded as PNG); nil for metafiles.
        public var macImage: (data: Data, ext: String)? {
            switch kind {
            case .png: return (data, "png")
            case .jpeg: return (data, "jpg")
            case .dib:
                guard let image = try? ClipboardDIB.decode(data), let rgba = image.rgba(),
                      let png = ClipboardRichText.png(width: image.width, height: image.height, rgba: rgba) else { return nil }
                return (png, "png")
            default: return nil
            }
        }
    }

    /// File name of the RTF text inside an RTFD directory.
    public static let rtfdTextName = "TXT.rtf"

    // MARK: Inspect

    /// Every `{\pict …}` group in the document (also those inside `\shppict` and `\nonshppict`), in order.
    public static func pictures(in rtf: Data) -> [Picture] {
        let s = RTFScanner([UInt8](rtf))
        var out: [Picture] = []
        var i = 0
        while i < s.count {
            let (token, next) = s.token(at: i)
            if case .open = token, case .word("pict", _) = s.token(at: next).0 {
                let (picture, end) = s.picture(at: i)
                out.append(picture)
                i = end
                continue
            }
            i = next
        }
        return out
    }

    /// The attachments of a flat RTFD (`com.apple.flat-rtfd`): file name → contents, without TXT.rtf. Nil if the data
    /// is not a serialized RTFD directory.
    public static func rtfdFiles(_ flatRTFD: Data) -> (text: Data, files: [String: Data])? {
        guard let wrapper = FileWrapper(serializedRepresentation: flatRTFD), wrapper.isDirectory,
              let children = wrapper.fileWrappers, let text = children[rtfdTextName]?.regularFileContents else { return nil }
        var files: [String: Data] = [:]
        for (name, child) in children where name != rtfdTextName && child.isRegularFile {
            if let data = child.regularFileContents { files[name] = data }
        }
        return (text, files)
    }

    // MARK: Mac → host: RTFD → RTF with \pict

    /// RTF for Windows apps from a flat RTFD: every `\NeXTGraphic` attachment that is an image becomes
    /// `{\pict\pngblip|\jpegblip\picwN\pichN\picwgoalN\pichgoalN <hex>}`; other images (TIFF, HEIC, GIF, …) are
    /// re-encoded as PNG; attachments that are not images are left out (as AppKit's own RTF does). `pictures` is the
    /// number converted. Nil if the data is not an RTFD.
    public static func rtf(fromFlatRTFD flatRTFD: Data, maxImageBytes: Int = 32 << 20) -> (rtf: Data, pictures: Int)? {
        guard let (text, files) = rtfdFiles(flatRTFD) else { return nil }
        let s = RTFScanner([UInt8](text))
        var out: [UInt8] = []
        out.reserveCapacity(text.count + files.values.reduce(0) { $0 + 2 * $1.count })
        var converted = 0
        var budget = maxImageBytes
        var i = 0
        var copied = 0
        while i < s.count {
            let (token, next) = s.token(at: i)
            guard case .open = token, let attachment = s.attachment(at: i) else {
                i = next
                continue
            }
            out += s.bytes[copied..<attachment.range.lowerBound]
            if let data = files[attachment.name], data.count <= budget,
               let pict = pictGroup(image: data, widthTwips: attachment.width, heightTwips: attachment.height) {
                out += pict
                budget -= data.count
                converted += 1
            }
            copied = attachment.range.upperBound
            i = attachment.range.upperBound
        }
        out += s.bytes[copied...]
        return (Data(out), converted)
    }

    /// `{\pict\pngblip\picw…\pich…\picwgoal…\pichgoal…` + hex + `}` for PNG or JPEG bytes (other image types are
    /// re-encoded as PNG). Goal size: the given twips, else from the image's DPI (72 when absent). Nil if not an image.
    public static func pictGroup(image data: Data, widthTwips: Int? = nil, heightTwips: Int? = nil) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { return nil }
        var bytes = data
        var word = "pngblip"
        switch type {
        case "public.png": break
        case "public.jpeg": word = "jpegblip"
        default:
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let png = png(image) else { return nil }
            bytes = png
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let dpiX = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpiY = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
        let goalW = widthTwips.flatMap { $0 > 0 ? $0 : nil } ?? Int((Double(w) * 1440 / max(dpiX, 1)).rounded())
        let goalH = heightTwips.flatMap { $0 > 0 ? $0 : nil } ?? Int((Double(h) * 1440 / max(dpiY, 1)).rounded())
        var out = Array("{\\pict\\\(word)\\picw\(w)\\pich\(h)\\picwgoal\(goalW)\\pichgoal\(goalH)\n".utf8)
        out.reserveCapacity(out.count + bytes.count * 2 + bytes.count / 64 + 4)
        let digits = Array("0123456789abcdef".utf8)
        for (n, byte) in bytes.enumerated() {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
            if n % 64 == 63 { out.append(0x0A) }
        }
        out += Array("}".utf8)
        return out
    }

    // MARK: Host → Mac: RTF with \pict → RTFD

    /// A flat RTFD (`com.apple.flat-rtfd`) for Mac apps from RTF with pictures: each `{\*\shppict …}` group, and each
    /// bare `{\pict …}`, whose picture is PNG, JPEG or a DIB becomes a `\NeXTGraphic` attachment ("Picture N.png");
    /// `{\nonshppict …}` fallback copies are dropped. Nil when no picture could be converted (the RTF alone then says
    /// as much to a Mac app).
    public static func flatRTFD(fromRTF rtf: Data) -> (rtfd: Data, pictures: Int)? {
        let s = RTFScanner([UInt8](rtf))
        guard s.contains("\\pict") else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(rtf.count / 2)
        var files: [String: FileWrapper] = [:]
        var i = 0
        var copied = 0
        func attach(_ picture: Picture) -> [UInt8]? {
            guard let image = picture.macImage else { return nil }
            let name = "Picture \(files.count + 1).\(image.ext)"
            files[name] = FileWrapper(regularFileWithContents: image.data)
            let px = imageSize(image.data)
            let w = picture.widthTwips ?? px.map { $0.width * 15 } ?? 0
            let h = picture.heightTwips ?? px.map { $0.height * 15 } ?? 0
            return Array("{{\\NeXTGraphic \(name) \\width\(w) \\height\(h) \\appleattachmentpadding0 \\appleembedtype0 \\appleaqc\n}}".utf8)
        }
        while i < s.count {
            let (token, next) = s.token(at: i)
            guard case .open = token else {
                i = next
                continue
            }
            let first = s.token(at: next)
            var replacement: [UInt8]?
            var end: Int?
            switch first.0 {
            case .symbol(UInt8(ascii: "*")) where s.isWord(at: first.1, "shppict"):
                // The Word 97+ picture: its first \pict, or nothing (a reader that skips \* destinations sees nothing).
                let groupEnd = s.groupEnd(at: i)
                replacement = s.firstPicture(in: i..<groupEnd).flatMap(attach) ?? []
                end = groupEnd
            case .word("nonshppict", _):
                replacement = []
                end = s.groupEnd(at: i)
            case .word("pict", _):
                let (picture, groupEnd) = s.picture(at: i)
                if let group = attach(picture) {
                    replacement = group
                    end = groupEnd
                }
            default: break
            }
            if let replacement, let end {
                out += s.bytes[copied..<i]
                out += replacement
                copied = end
                i = end
            } else {
                i = next
            }
        }
        guard !files.isEmpty else { return nil }
        out += s.bytes[copied...]
        files[rtfdTextName] = FileWrapper(regularFileWithContents: Data(out))
        guard let flat = FileWrapper(directoryWithFileWrappers: files).serializedRepresentation else { return nil }
        return (flat, files.count - 1)
    }

    // MARK: Image helpers

    static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (w, h)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// PNG from RGBA8 (not premultiplied, top-down).
    public static func png(width: Int, height: Int, rgba: Data) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4, let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return png(image)
    }

    /// RGBA8 (not premultiplied, top-down) of PNG/JPEG/TIFF bytes, for comparisons.
    public static func decodeImage(_ data: Data) -> ClipboardImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }
        return ClipboardImage(width: w, height: h, rgba: Data(pixels))
    }
}

// MARK: - A minimal RTF tokenizer (RTF 1.9.1, "Conventions of an RTF Reader")

struct RTFScanner {
    enum Token: Equatable {
        case open, close
        /// Control word with its optional numeric parameter.
        case word(String, Int?)
        /// Control symbol (`\*`, `\~`, `\\`, `\{`, `\}`, …).
        case symbol(UInt8)
        /// `\'hh`.
        case hex(UInt8)
        /// One plain byte (CR and LF included; readers ignore them).
        case text(UInt8)
        /// `\binN` data.
        case binary(Range<Int>)
    }

    let bytes: [UInt8]
    var count: Int { bytes.count }

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    static func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }
    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    func contains(_ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard !n.isEmpty, bytes.count >= n.count else { return false }
        var i = 0
        while i <= bytes.count - n.count {
            if bytes[i] == n[0], Array(bytes[i..<(i + n.count)]) == n { return true }
            i += 1
        }
        return false
    }

    /// The token starting at `i` and the index after it. `i` must be < count.
    func token(at i: Int) -> (Token, Int) {
        let b = bytes[i]
        switch b {
        case UInt8(ascii: "{"): return (.open, i + 1)
        case UInt8(ascii: "}"): return (.close, i + 1)
        case UInt8(ascii: "\\"):
            guard i + 1 < count else { return (.text(b), i + 1) }
            let c = bytes[i + 1]
            if Self.isLetter(c) {
                var j = i + 1
                while j < count, j - i <= 32, Self.isLetter(bytes[j]) { j += 1 }
                let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                var param: Int?
                var k = j
                if k < count, bytes[k] == UInt8(ascii: "-") || Self.isDigit(bytes[k]) {
                    let negative = bytes[k] == UInt8(ascii: "-")
                    if negative { k += 1 }
                    var value = 0
                    var digits = 0
                    while k < count, Self.isDigit(bytes[k]), digits < 10 {
                        value = value * 10 + Int(bytes[k] - 0x30)
                        k += 1
                        digits += 1
                    }
                    if digits > 0 { param = negative ? -value : value } else { k = j }
                }
                if k < count, bytes[k] == UInt8(ascii: " ") { k += 1 }
                if name == "bin", let n = param, n > 0 {
                    let end = min(count, k + n)
                    return (.binary(k..<end), end)
                }
                return (.word(name, param), k)
            }
            if c == UInt8(ascii: "'"), i + 3 < count, let hi = Self.hexValue(bytes[i + 2]), let lo = Self.hexValue(bytes[i + 3]) {
                return (.hex(hi << 4 | lo), i + 4)
            }
            return (.symbol(c), i + 2)
        default:
            return (.text(b), i + 1)
        }
    }

    func isWord(at i: Int, _ name: String) -> Bool {
        guard i < count, case .word(let w, _) = token(at: i).0 else { return false }
        return w == name
    }

    /// Index after the `}` that closes the group opened at `open` (or the end of the data).
    func groupEnd(at open: Int) -> Int {
        var depth = 0
        var i = open
        while i < count {
            let (token, next) = token(at: i)
            switch token {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth == 0 { return next }
            default: break
            }
            i = next
        }
        return count
    }

    /// The `{\pict …}` group opened at `open`: its format, size words and data (hex digits or `\bin`), and the index
    /// after it. Nested groups (`{\*\picprop …}`, `{\*\blipuid …}`) are skipped.
    func picture(at open: Int) -> (ClipboardRichText.Picture, Int) {
        var picture = ClipboardRichText.Picture(kind: .other, data: Data())
        var goalW: Int?, goalH: Int?, scaleX = 100, scaleY = 100
        var data: [UInt8] = []
        var nibble: UInt8?
        var depth = 0
        var i = open
        var end = count
        scan: while i < count {
            let (token, next) = token(at: i)
            defer { i = next }
            switch token {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth == 0 { end = next; break scan }
            case .word(let w, let p) where depth == 1:
                switch w {
                case "pngblip": picture.kind = .png
                case "jpegblip": picture.kind = .jpeg
                case "emfblip": picture.kind = .emf
                case "wmetafile": picture.kind = .wmf
                case "dibitmap": picture.kind = .dib
                case "wbitmap": picture.kind = .bitmap
                case "picw": picture.picw = p
                case "pich": picture.pich = p
                case "picwgoal": goalW = p
                case "pichgoal": goalH = p
                case "picscalex": scaleX = p ?? 100
                case "picscaley": scaleY = p ?? 100
                default: break
                }
            case .text(let b) where depth == 1:
                guard let v = Self.hexValue(b) else { continue }
                if let hi = nibble {
                    data.append(hi << 4 | v)
                    nibble = nil
                } else {
                    nibble = v
                }
            case .binary(let range) where depth == 1:
                data += bytes[range]
            default: break
            }
        }
        picture.data = Data(data)
        picture.widthTwips = goalW.map { Self.scaled($0, percent: scaleX) }
        picture.heightTwips = goalH.map { Self.scaled($0, percent: scaleY) }
        return (picture, end)
    }

    /// `goal × percent / 100`, clamped: both words come from the host with up to 10 digits each, whose product
    /// overflows Int (it used to trap and end the viewer).
    static func scaled(_ goal: Int, percent: Int) -> Int {
        let (product, overflow) = goal.multipliedReportingOverflow(by: percent)
        if overflow { return (goal < 0) != (percent < 0) ? .min : .max }
        return product / 100
    }

    /// The first `{\pict …}` group inside `range`.
    func firstPicture(in range: Range<Int>) -> ClipboardRichText.Picture? {
        var i = range.lowerBound
        while i < range.upperBound {
            let (token, next) = token(at: i)
            if case .open = token, isWord(at: next, "pict") { return picture(at: i).0 }
            i = next
        }
        return nil
    }

    /// An AppKit attachment at `open`: `{{\NeXTGraphic name \wN \hN …}<char>}` (the whole outer group) or just
    /// `{\NeXTGraphic …}` plus one attachment character after it. Name and \width/\height (twips).
    func attachment(at open: Int) -> (range: Range<Int>, name: String, width: Int?, height: Int?)? {
        let (_, afterOpen) = token(at: open)
        if afterOpen < count, case .open = token(at: afterOpen).0, isWord(at: afterOpen + 1, "NeXTGraphic") {
            // Outer group: it must hold only the inner group and the attachment character.
            guard let inner = attachment(at: afterOpen) else { return nil }
            var i = inner.range.upperBound
            while i < count, bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
            guard i < count, case .close = token(at: i).0 else { return inner }
            return (open..<(i + 1), inner.name, inner.width, inner.height)
        }
        guard isWord(at: afterOpen, "NeXTGraphic") else { return nil }
        var i = token(at: afterOpen).1
        var name: [UInt8] = []
        var width: Int?, height: Int?
        var inName = true
        var depth = 1
        while i < count {
            let (token, next) = token(at: i)
            i = next
            switch token {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth == 0 {
                    // One attachment character may follow: 0xAC as AppKit writes it, \'ac, or \uN (U+FFFC).
                    var end = i
                    if end < count {
                        let (after, afterEnd) = self.token(at: end)
                        switch after {
                        case .text(0xAC), .hex(0xAC), .word("u", 65532), .word("u", -4): end = afterEnd
                        default: break
                        }
                    }
                    let decoded = String(data: Data(name), encoding: .utf8) ?? String(data: Data(name), encoding: .windowsCP1252) ?? ""
                    return (open..<end, decoded.trimmingCharacters(in: .whitespaces), width, height)
                }
            case .word(let w, let p):
                inName = false
                if w == "width" { width = p } else if w == "height" { height = p }
            case .text(let b) where inName && depth == 1 && b != 0x0A && b != 0x0D: name.append(b)
            case .hex(let b) where inName && depth == 1: name.append(b)
            case .symbol(let b) where inName && depth == 1 && (b == UInt8(ascii: "\\") || b == UInt8(ascii: "{") || b == UInt8(ascii: "}")):
                name.append(b)
            default: break
            }
        }
        return nil
    }
}
