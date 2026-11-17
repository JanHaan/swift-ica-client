import AppKit
import Foundation
import Testing
@testable import ICAKit

// Pictures in rich text (docs/70 §4.9): RTFD attachments ↔ RTF \pict. Synthetic data only.

private func solid(_ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) -> Data {
    var px = [UInt8]()
    px.reserveCapacity(w * h * 4)
    for _ in 0..<(w * h) { px += [rgb.0, rgb.1, rgb.2, 255] }
    return Data(px)
}

private func testPNG(_ w: Int = 64, _ h: Int = 64, _ rgb: (UInt8, UInt8, UInt8) = (20, 110, 200)) -> Data {
    ClipboardRichText.png(width: w, height: h, rgba: solid(w, h, rgb))!
}

private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// An RTFD the way AppKit writes it for a Mac copy (TextEdit): bold text, the image as an attachment, more text.
private func appKitRTFD(image: Data, name: String = "image.png") -> Data {
    let wrapper = FileWrapper(regularFileWithContents: image)
    wrapper.preferredFilename = name
    let s = NSMutableAttributedString(string: "Line before ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    s.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    s.append(NSAttributedString(string: " line after\n"))
    return s.rtfd(from: NSRange(location: 0, length: s.length), documentAttributes: [:])!
}

private func attachments(ofRTFD flat: Data) throws -> (string: String, images: [Data]) {
    let a = try NSAttributedString(data: flat, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    var images: [Data] = []
    a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length)) { value, _, _ in
        if let data = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents { images.append(data) }
    }
    return (a.string, images)
}

@Test func appKitPlainRTFHasNoPictureButRTFDHasTheAttachment() throws {
    // The gap: AppKit's public.rtf of a copy with an image carries no picture at all.
    let png = testPNG()
    let rtfd = appKitRTFD(image: png)
    let (text, files) = try #require(ClipboardRichText.rtfdFiles(rtfd))
    #expect(files.values.contains(png))
    #expect(String(decoding: text, as: UTF8.self).contains("\\NeXTGraphic"))
    let a = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    let plain = a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:])!
    #expect(!String(decoding: plain, as: UTF8.self).contains("\\pict"))
}

@Test func rtfdAttachmentBecomesPngBlip() throws {
    let png = testPNG()
    let (rtf, count) = try #require(ClipboardRichText.rtf(fromFlatRTFD: appKitRTFD(image: png)))
    #expect(count == 1)
    let s = String(decoding: rtf, as: UTF8.self)
    #expect(s.hasPrefix("{\\rtf1"))
    #expect(!s.contains("NeXTGraphic"))
    #expect(s.contains("\\pict\\pngblip\\picw64\\pich64\\picwgoal1280\\pichgoal1280"))
    #expect(s.contains("Line before") && s.contains("line after") && s.contains("\\b"))
    #expect(!rtf.contains(0xAC))   // the attachment character went with the attachment
    let pictures = ClipboardRichText.pictures(in: rtf)
    #expect(pictures.count == 1)
    let p = try #require(pictures.first)
    #expect(p.kind == .png && p.data == png && p.picw == 64 && p.pich == 64 && p.widthTwips == 1280 && p.heightTwips == 1280)
    #expect(p.pixelSize?.width == 64 && p.pixelSize?.height == 64)
    // Balanced groups: the replacement kept the document well formed.
    var depth = 0
    let scanner = RTFScanner([UInt8](rtf))
    var i = 0
    while i < scanner.count {
        let (t, next) = scanner.token(at: i)
        if t == .open { depth += 1 } else if t == .close { depth -= 1 }
        #expect(depth >= 0)
        i = next
    }
    #expect(depth == 0)
}

@Test func rtfdTiffAttachmentIsReencodedAsPNG() throws {
    let rgba = solid(10, 6, (200, 30, 40))
    let rep = NSBitmapImageRep(cgImage: try #require(ClipboardRichText.decodeImage(testPNG(10, 6, (200, 30, 40))).flatMap { img in
        CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: rgba as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }))
    let tiff = try #require(rep.tiffRepresentation)
    let (rtf, count) = try #require(ClipboardRichText.rtf(fromFlatRTFD: appKitRTFD(image: tiff, name: "Pasted Graphic.tiff")))
    #expect(count == 1)
    let p = try #require(ClipboardRichText.pictures(in: rtf).first)
    #expect(p.kind == .png)
    let decoded = try #require(ClipboardRichText.decodeImage(p.data))
    #expect(decoded.width == 10 && decoded.height == 6 && decoded.rgba() == rgba)
}

@Test func handMadeRTFDVariantsAndNonImageAttachments() throws {
    let png = testPNG(4, 3)
    func flat(_ txt: String, extra: [UInt8] = [], files: [String: Data]) -> Data {
        var wrappers = files.mapValues { FileWrapper(regularFileWithContents: $0) }
        wrappers["TXT.rtf"] = FileWrapper(regularFileWithContents: Data(txt.utf8) + Data(extra))
        return FileWrapper(directoryWithFileWrappers: wrappers).serializedRepresentation!
    }
    // Inner group only, \'ac as the attachment character, no \width: goal from 72 dpi (4 px → 80 twips).
    let a = flat("{\\rtf1\\ansi A {\\NeXTGraphic Bild 1.png}\\'ac B \\{not a group\\}}", files: ["Bild 1.png": png])
    let (rtfA, nA) = try #require(ClipboardRichText.rtf(fromFlatRTFD: a))
    #expect(nA == 1)
    #expect(String(decoding: rtfA, as: UTF8.self).hasSuffix(" B \\{not a group\\}}"))
    #expect(ClipboardRichText.pictures(in: rtfA).first?.widthTwips == 80)
    // A non-image attachment is left out, like AppKit's own RTF.
    let b = flat("{\\rtf1 x {{\\NeXTGraphic notes.txt \\width100 \\height100}", extra: [0xAC] + Array("} y}".utf8),
                 files: ["notes.txt": Data("hello".utf8)])
    let (rtfB, nB) = try #require(ClipboardRichText.rtf(fromFlatRTFD: b))
    #expect(nB == 0)
    #expect(String(decoding: rtfB, as: UTF8.self) == "{\\rtf1 x  y}")
    // Missing file: left out too.
    let (_, nC) = try #require(ClipboardRichText.rtf(fromFlatRTFD: flat("{\\rtf1 {{\\NeXTGraphic gone.png}}}", files: [:])))
    #expect(nC == 0)
    // Not an RTFD.
    #expect(ClipboardRichText.rtf(fromFlatRTFD: Data("{\\rtf1 plain}".utf8)) == nil)
}

/// The shape Word puts on the clipboard for text with a picture: `\shppict` with a PNG (plus picture properties and a
/// blip uid group), and a `\nonshppict` WMF fallback.
private func wordStyleRTF(png: Data) -> Data {
    let rtf = "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Calibri;}}{\\colortbl;\\red192\\green0\\blue0;}"
        + "\\pard\\plain\\f0\\fs22 {\\b Marker} {\\cf1 red} "
        + "{\\*\\shppict{\\pict{\\*\\picprop\\shplid1025{\\sp{\\sn shapeType}{\\sv 75}}}\\picscalex50\\picscaley50"
        + "\\piccropl0\\piccropr0\\piccropt0\\piccropb0\\picw1693\\pich1693\\picwgoal960\\pichgoal960\\pngblip"
        + "\\bliptag-12345{\\*\\blipuid 00112233445566778899aabbccddeeff}\n" + hexString(png) + "\n}}"
        + "{\\nonshppict{\\pict\\picscalex50\\picscaley50\\picw1693\\pich1693\\picwgoal960\\pichgoal960\\wmetafile8\\bliptag-12345 "
        + "0100090000035a00000000001200000000000500000009020000000005000000\n}}"
        + " after\\par}"
    return Data(rtf.utf8) + Data([0])
}

@Test func wordPicturesBecomeRTFDAttachments() throws {
    let png = testPNG()
    let rtf = ClipboardRTF.decodeHost(wordStyleRTF(png: png))
    let pictures = ClipboardRichText.pictures(in: rtf)
    #expect(pictures.map(\.kind) == [.png, .wmf])
    #expect(pictures[0].data == png && pictures[0].picw == 1693 && pictures[0].widthTwips == 480)
    #expect(pictures[0].pixelSize?.width == 64 && pictures[1].pixelSize == nil)

    let (flat, count) = try #require(ClipboardRichText.flatRTFD(fromRTF: rtf))
    #expect(count == 1)
    let (text, files) = try #require(ClipboardRichText.rtfdFiles(flat))
    #expect(files == ["Picture 1.png": png])
    let txt = String(decoding: text, as: UTF8.self)
    #expect(!txt.contains("\\pict") && !txt.contains("nonshppict") && txt.contains("\\NeXTGraphic Picture 1.png \\width480 \\height480"))
    // A Mac app reads it as text with one image attachment.
    let (string, images) = try attachments(ofRTFD: flat)
    #expect(images == [png])
    #expect(string.contains("Marker") && string.contains("red") && string.contains("after") && string.contains("\u{FFFC}"))
}

@Test func barePictJpegBinAndDibAreConverted() throws {
    // JPEG as \bin raw bytes.
    let cg = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: CGDataProvider(data: solid(8, 8, (0, 128, 0)) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let jpeg = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:]))
    var rtf = Data("{\\rtf1 J {\\pict\\jpegblip\\picw8\\pich8\\bin\(jpeg.count) ".utf8) + jpeg + Data("} D ".utf8)
    // A 2×1 24-bpp DIB as hex.
    var dib = ByteWriter()
    dib.u32(40); dib.u32(2); dib.u32(1); dib.u16(1); dib.u16(24); dib.u32(0); dib.u32(8)
    dib.raw([UInt8](repeating: 0, count: 16))
    dib.raw([255, 0, 0, 0, 0, 255, 0, 0])   // blue, red, padding
    rtf += Data("{\\pict\\dibitmap0\\picw2\\pich1\\picwgoal30\\pichgoal15 \(hexString(dib.data))} E}".utf8)
    let (flat, count) = try #require(ClipboardRichText.flatRTFD(fromRTF: rtf))
    #expect(count == 2)
    let (_, files) = try #require(ClipboardRichText.rtfdFiles(flat))
    #expect(files["Picture 1.jpg"] == jpeg)
    let dibPNG = try #require(files["Picture 2.png"])
    #expect(ClipboardRichText.decodeImage(dibPNG)?.rgba() == Data([0, 0, 255, 255, 255, 0, 0, 255]))
    let (string, images) = try attachments(ofRTFD: flat)
    #expect(images.count == 2 && string.contains("J") && string.contains("E"))
    // Only metafiles, or no picture at all: nothing to convert.
    #expect(ClipboardRichText.flatRTFD(fromRTF: Data("{\\rtf1 {\\pict\\emfblip 0102}}".utf8)) == nil)
    #expect(ClipboardRichText.flatRTFD(fromRTF: Data("{\\rtf1 \\b plain\\b0}".utf8)) == nil)
}

@Test func rtfdRoundTripKeepsEveryPixel() throws {
    let rgba = solid(64, 64, (20, 110, 200))
    let png = ClipboardRichText.png(width: 64, height: 64, rgba: rgba)!
    let (rtf, _) = try #require(ClipboardRichText.rtf(fromFlatRTFD: appKitRTFD(image: png)))
    let (flat, count) = try #require(ClipboardRichText.flatRTFD(fromRTF: rtf))
    #expect(count == 1)
    let (string, images) = try attachments(ofRTFD: flat)
    #expect(string.contains("Line before") && string.contains("line after"))
    #expect(images.count == 1)
    #expect(ClipboardRichText.decodeImage(images[0])?.rgba() == rgba)
}

// MARK: Engine (docs/70 §4.9)

private func engineHarness(_ config: ClipboardEngine.Config = .init()) -> (ClipboardEngine, () -> Data, (Data) -> Void, () -> [ClipboardEngine.Event]) {
    let engine = ClipboardEngine(config: config)
    var writes = Data()
    var events: [ClipboardEngine.Event] = []
    engine.output = { if case .channel(let d) = $0 { writes += d } }
    engine.onEvent = { events.append($0) }
    engine.scheduleAfter = { _, _ in }
    engine.now = { 10_000 }
    func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    engine.receive(Data(u16(1) + u16(0) + u16(3)))
    var names = u16(8) + u16(0)
    for (id, name) in [(UInt16(0xC00D), "HTML Format"), (UInt16(0xC010), "Rich Text Format")] {
        names += u16(id) + u32(UInt32(name.utf8.count + 1)) + Array(name.utf8) + [0]
    }
    engine.receive(Data(names + [0, 0, 0, 0, 0, 0]))
    writes = Data()
    events = []
    return (engine, { defer { writes = Data() }; return writes }, { engine.receive($0) }, { events })
}

@Test func engineServesRTFDAsRTFWithPicture() throws {
    let (engine, take, feed, _) = engineHarness()
    let png = testPNG()
    let plain = Data("{\\rtf1 Line before  line after}".utf8)
    engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(text: "Line before  line after", rtf: plain, rtfd: appKitRTFD(image: png)), takenAt: 20_000))
    let list = take()
    #expect(list.count > 4 && list.prefix(2) == Data([3, 0]))
    #expect(list.range(of: Data([0x10, 0xC0])) != nil)   // "Rich Text Format" announced
    feed(Data([4, 0, 0, 0, 0x10, 0xC0, 0, 0]))
    let served = take()
    #expect(served.prefix(6) == Data([5, 0, 0, 0, 0x10, 0xC0]))
    let body = ClipboardRTF.decodeHost(served.dropFirst(10))
    #expect(ClipboardRichText.pictures(in: body).first?.data == png)

    // Without pictures in the RTFD, the Mac's own RTF is served as it is; with images off, too.
    let empty = FileWrapper(directoryWithFileWrappers: ["TXT.rtf": FileWrapper(regularFileWithContents: Data("{\\rtf1 converted}".utf8))]).serializedRepresentation!
    engine.announceLocal(ClipboardSnapshot(content: ClipboardContent(rtf: plain, rtfd: empty), takenAt: 30_000))
    _ = take()
    feed(Data([4, 0, 0, 0, 0x10, 0xC0, 0, 0]))
    #expect(ClipboardRTF.decodeHost(take().dropFirst(10)) == plain)

    var off = ClipboardEngine.Config()
    off.images = false
    let (engine2, take2, feed2, _) = engineHarness(off)
    engine2.announceLocal(ClipboardSnapshot(content: ClipboardContent(rtf: plain, rtfd: appKitRTFD(image: png)), takenAt: 20_000))
    _ = take2()
    feed2(Data([4, 0, 0, 0, 0x10, 0xC0, 0, 0]))
    #expect(ClipboardRTF.decodeHost(take2().dropFirst(10)) == plain)
}

@Test func engineDeliversHostRTFPicturesAsRTFD() throws {
    let (_, take, feed, events) = engineHarness()
    let png = testPNG()
    let rtf = wordStyleRTF(png: png)
    // Host list: text and RTF (as Word lists them, among others).
    feed(Data([3, 0, 3, 0, 0x0D, 0, 7, 0, 0, 0, 0x10, 0xC0, 7, 0, 0, 0, 0x0E, 0, 7, 0, 0, 0, 0, 0]))
    #expect(take() == ClipboardWire.dataRequest(format: 13))
    func response(_ format: UInt16, _ data: Data) -> Data {
        Data([5, 0, 0, 0, UInt8(format & 0xFF), UInt8(format >> 8)] + withUnsafeBytes(of: UInt32(data.count).littleEndian, Array.init)) + data
    }
    feed(response(13, ClipboardText.encodeForHost("Marker red")))
    #expect(take() == ClipboardWire.dataRequest(format: 0xC010))
    feed(response(0xC010, rtf))
    let content = try #require(events().compactMap { if case .hostClipboard(let c, _, _) = $0 { return c } else { return nil } }.last)
    #expect(content.rtf == ClipboardRTF.decodeHost(rtf))
    let flat = try #require(content.rtfd)
    #expect(try attachments(ofRTFD: flat).images == [png])
    #expect(content.summary.contains("rtfd"))
}

// MARK: NSPasteboard, as the ICAViewer bridge maps it (SystemPasteboard: .rtf ↔ content.rtf, .rtfd ↔ content.rtfd)

@Test func pasteboardRoundTripThroughTheBridgeTypes() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("ica-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let png = testPNG()

    // Mac → host: a Mac app's copy of text with an image (written as AppKit apps do).
    let wrapper = FileWrapper(regularFileWithContents: png)
    wrapper.preferredFilename = "image.png"
    let s = NSMutableAttributedString(string: "Copied text ")
    s.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    board.clearContents()
    #expect(board.writeObjects([s]))
    let types = board.types ?? []
    #expect(types.contains(.rtfd) && types.contains(.rtf))
    let rtfd = try #require(board.data(forType: .rtfd))
    #expect(!String(decoding: board.data(forType: .rtf) ?? Data(), as: UTF8.self).contains("\\pict"))
    let (rtf, count) = try #require(ClipboardRichText.rtf(fromFlatRTFD: rtfd))
    #expect(count == 1 && ClipboardRichText.pictures(in: rtf).first?.data == png)

    // Host → Mac: Word's RTF becomes RTFD on the pasteboard; a Mac app reads the image from it.
    let (flat, _) = try #require(ClipboardRichText.flatRTFD(fromRTF: ClipboardRTF.decodeHost(wordStyleRTF(png: png))))
    board.clearContents()
    let item = NSPasteboardItem()
    item.setData(ClipboardRTF.decodeHost(wordStyleRTF(png: png)), forType: .rtf)
    item.setData(flat, forType: .rtfd)
    board.writeObjects([item])
    let read = try #require(board.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString]).first
    let a = try #require(read)
    var images: [Data] = []
    a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length)) { v, _, _ in
        if let d = (v as? NSTextAttachment)?.fileWrapper?.regularFileContents { images.append(d) }
    }
    #expect(images == [png])
    #expect(a.string.contains("Marker"))
}
