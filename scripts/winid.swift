// On-screen windows of one owner (CGWindowList), for scripts/lab-gui-smoke.sh: one line per window,
// "<window number> <width> <height> <title>". Titles need the Screen Recording permission; numbers do not.
// Usage: swiftc -O -o .build/winid scripts/winid.swift && .build/winid "ICA Viewer" [owner…]
import CoreGraphics
import Foundation

let owners = Set(CommandLine.arguments.dropFirst())
guard !owners.isEmpty else {
    FileHandle.standardError.write(Data("usage: winid <owner name> [owner name…]\n".utf8))
    exit(2)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owners.contains(owner),
          (w[kCGWindowLayer as String] as? Int) == 0,
          let number = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let width = (bounds["Width"] as? NSNumber)?.intValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.intValue ?? 0
    print("\(number) \(width) \(height) \(owner)|\(w[kCGWindowName as String] as? String ?? "")")
}
