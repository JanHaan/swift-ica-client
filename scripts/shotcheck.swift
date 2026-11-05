// Checks and composes README screenshots. Build: swiftc -O scripts/shotcheck.swift -o <out>
//
//   shotcheck check <png>...                      OCR + corner/edge checks; exit 1 on any failure
//   shotcheck composite <out.png> <in1.png> <in2.png>...
//                                                 in1 on a flat #E5E5EA background with 48 px padding,
//                                                 every further image centred over in1 (HUD over a window)
//   shotcheck selftest <dir>                      writes synthetic PNGs to <dir> and checks them
//
// check (1): Vision OCR (accurate, en + de) must not recognise any forbidden word (case-insensitive regexes
//            from env ICA_SHOT_FORBIDDEN, one per line or separated by ";", and from the git-ignored file
//            .shotcheck-forbidden, one per line, in the package root; none built in, a warning if none);
//            all recognised strings are printed for review.
// check (2): the four corner pixels must be fully transparent, or the image is a composite: opaque and
//            equal to the flat background. The outer 3 px ring is summarised.
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

let background: (r: UInt8, g: UInt8, b: UInt8) = (0xE5, 0xE5, 0xEA)
let padding = 48

/// Forbidden-word regexes (case-insensitive) from the environment and the package root's file.
func loadForbidden() -> [NSRegularExpression] {
    var patterns: [String] = []
    if let env = ProcessInfo.processInfo.environment["ICA_SHOT_FORBIDDEN"] {
        patterns += env.split(whereSeparator: { $0 == "\n" || $0 == ";" }).map(String.init)
    }
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while true {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            if let text = try? String(contentsOf: dir.appendingPathComponent(".shotcheck-forbidden"), encoding: .utf8) {
                patterns += text.split(separator: "\n").map(String.init)
            }
            break
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    return patterns.map {
        guard let regex = try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) else { fail("bad forbidden regex: \($0)") }
        return regex
    }
}

var forbidden: [NSRegularExpression] = []

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
    return image
}

func writePNG(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(path)") }
}

/// RGBA8, premultiplied, top row first.
struct Pixels {
    let width: Int, height: Int
    var data: [UInt8]
    init(_ image: CGImage) {
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    func at(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }
}

// MARK: OCR

func recognise(_ image: CGImage) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "de-DE"]
    request.usesLanguageCorrection = true
    // Text on a transparent background: recognise on a flat white copy so alpha does not hide it.
    let handler = VNImageRequestHandler(cgImage: flattened(image, on: (255, 255, 255)), options: [:])
    do { try handler.perform([request]) } catch { fail("OCR failed: \(error)") }
    return (request.results ?? []).flatMap { $0.topCandidates(1).map(\.string) }
}

func flattened(_ image: CGImage, on bg: (UInt8, UInt8, UInt8)) -> CGImage {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: CGFloat(bg.0) / 255, green: CGFloat(bg.1) / 255, blue: CGFloat(bg.2) / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

// MARK: Edge check

func near(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) <= 2 }

/// Returns problems (empty if fine) and prints the ring summary.
func edgeCheck(_ image: CGImage, name: String) -> [String] {
    let px = Pixels(image)
    let w = px.width, h = px.height
    var problems: [String] = []
    let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].map { px.at($0.0, $0.1) }
    let transparent = corners.allSatisfy { $0.a == 0 }
    let flat = corners.allSatisfy { $0.a == 255 && near($0.r, background.r) && near($0.g, background.g) && near($0.b, background.b) }
    let kind = transparent ? "transparent corners" : flat ? "composite on #E5E5EA" : "UNKNOWN corners"
    if !transparent && !flat {
        let list = corners.map { String(format: "%02x%02x%02x/a%d", $0.r, $0.g, $0.b, $0.a) }.joined(separator: " ")
        problems.append("corners are neither fully transparent nor the flat background (\(list))")
    }
    // Outer 3 px ring: alpha histogram and the average colour of its opaque pixels.
    var clear = 0, partial = 0, opaque = 0, r = 0, g = 0, b = 0
    for y in 0..<h {
        for x in 0..<w where x < 3 || y < 3 || x >= w - 3 || y >= h - 3 {
            let p = px.at(x, y)
            if p.a == 0 { clear += 1 } else if p.a == 255 { opaque += 1; r += Int(p.r); g += Int(p.g); b += Int(p.b) } else { partial += 1 }
        }
    }
    let avg = opaque > 0 ? String(format: "#%02x%02x%02x", r / opaque, g / opaque, b / opaque) : "-"
    print("  \(w)x\(h) px, \(kind); 3-px ring: \(clear) clear, \(partial) partial, \(opaque) opaque (avg \(avg))")
    return problems
}

// MARK: Commands

func check(_ paths: [String]) -> Bool {
    var ok = true
    for path in paths {
        print((path as NSString).lastPathComponent)
        let image = loadImage(path)
        var problems = edgeCheck(image, name: path)
        let strings = recognise(image)
        print("  OCR (\(strings.count) strings): " + strings.map { "\"\($0)\"" }.joined(separator: ", "))
        for s in strings where forbidden.contains(where: { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }) {
            problems.append("OCR found forbidden text: \"\(s)\"")
        }
        for p in problems { print("  FAIL: \(p)") }
        if problems.isEmpty { print("  ok") } else { ok = false }
    }
    return ok
}

func composite(out: String, inputs: [String]) {
    let images = inputs.map(loadImage)
    guard let base = images.first else { fail("composite needs at least one input") }
    // Rects in a bottom-left coordinate system; overlays are centred over the base.
    var rects = [CGRect(x: 0, y: 0, width: base.width, height: base.height)]
    for image in images.dropFirst() {
        rects.append(CGRect(x: (base.width - image.width) / 2, y: (base.height - image.height) / 2, width: image.width, height: image.height))
    }
    let bounds = rects.reduce(rects[0]) { $0.union($1) }
    let width = Int(bounds.width) + 2 * padding, height = Int(bounds.height) + 2 * padding
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255,
                             blue: CGFloat(background.b) / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .none
    for (image, rect) in zip(images, rects) {
        ctx.draw(image, in: rect.offsetBy(dx: CGFloat(padding) - bounds.minX, dy: CGFloat(padding) - bounds.minY))
    }
    writePNG(ctx.makeImage()!, to: out)
    print("composite \(out): \(width)x\(height) px from \(inputs.count) image(s)")
}

/// Synthetic images: a rounded window with text, a leaky one, and one with square opaque corners.
func selftest(dir: String) -> Bool {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func make(_ name: String, text: [String], rounded: Bool, size: CGSize = CGSize(width: 440, height: 260)) -> String {
        let w = Int(size.width), h = Int(size.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill(using: .copy)
        NSColor(white: 0.97, alpha: 1).setFill()
        (rounded ? NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 12, yRadius: 12)
                 : NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h))).fill()
        for (i, line) in text.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 24, y: CGFloat(h - 60 - i * 44)),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let path = dir + "/" + name
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        return path
    }
    let good = make("good.png", text: ["Calculator", "Sign In demo"], rounded: true)
    let hud = make("hud.png", text: ["Calculator", "Reconnecting 2:54"], rounded: true, size: CGSize(width: 300, height: 110))
    forbidden = ["SECRETCORP", "Tool QRS"].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    let leakyTag = make("leak-tag.png", text: ["Tool QRS"], rounded: true)
    let leakyName = make("leak-name.png", text: ["Welcome to SECRETCORP"], rounded: true)
    let square = make("square.png", text: ["Calculator"], rounded: false)
    let comp = dir + "/composite.png"
    composite(out: comp, inputs: [good, hud])

    var failures: [String] = []
    func expect(_ name: String, passes: Bool, _ path: String) {
        print("--- expecting \(passes ? "pass" : "FAIL") for \(name)")
        if check([path]) != passes { failures.append(name) }
    }
    expect("good window", passes: true, good)
    expect("hud", passes: true, hud)
    expect("composite", passes: true, comp)
    expect("forbidden tag text", passes: false, leakyTag)
    expect("forbidden name text", passes: false, leakyName)
    expect("square opaque corners", passes: false, square)
    print(failures.isEmpty ? "selftest ok" : "selftest FAILED: \(failures.joined(separator: ", "))")
    return failures.isEmpty
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "check" where args.count > 1:
    forbidden = loadForbidden()
    if forbidden.isEmpty {
        print("WARNING: no forbidden words configured (ICA_SHOT_FORBIDDEN or .shotcheck-forbidden); only the corner check is meaningful")
    }
    exit(check(Array(args.dropFirst())) ? 0 : 1)
case "composite" where args.count >= 3:
    composite(out: args[1], inputs: Array(args.dropFirst(2)))
case "selftest" where args.count == 2:
    exit(selftest(dir: args[1]) ? 0 : 1)
default:
    fail("usage: shotcheck check <png>... | composite <out.png> <in1.png> <in2.png>... | selftest <dir>")
}
