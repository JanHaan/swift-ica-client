import AppKit
import AppHostKit

/// The standard About panel for ICA Viewer: version and build from the Info.plist (`AppVersion`), the project
/// link, the license and the non-affiliation notice.
@MainActor
enum AboutPanel {
    static let projectURL = "https://github.com/JanHaan/swift-ica-client"

    static func show() {
        let v = AppVersion.current
        let german = loc("en", "de") == "de"
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString()
        func line(_ text: String, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]
            if let link { attributes[.link] = URL(string: link); attributes[.foregroundColor] = NSColor.linkColor }
            if credits.length > 0 { credits.append(NSAttributedString(string: "\n", attributes: [.font: small])) }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        if v.isDevelopment { line(v.displayString(german: german)) }
        line(loc("An independent, native macOS client for published applications over ICA.",
                 "Ein unabhängiger, nativer macOS-Client für veröffentlichte Anwendungen über ICA."))
        line(projectURL, link: projectURL)
        line(loc("Licensed under MIT or Apache-2.0, at your option.", "Lizenziert unter MIT oder Apache-2.0, nach Wahl."))
        line(loc("Not affiliated with Citrix. Citrix, ICA, HDX, NetScaler and StoreFront are trademarks of Cloud Software Group, Inc.",
                 "Nicht mit Citrix verbunden. Citrix, ICA, HDX, NetScaler und StoreFront sind Marken der Cloud Software Group, Inc."))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ICA Viewer", .credits: credits, .applicationIcon: NSApp.applicationIconImage as Any,
        ]
        if let version = v.version {
            options[.applicationVersion] = version
            options[.version] = v.buildLine ?? ""
        } else {
            options[.applicationVersion] = ""   // development build: the credits say so instead of a version
            options[.version] = ""
        }
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
