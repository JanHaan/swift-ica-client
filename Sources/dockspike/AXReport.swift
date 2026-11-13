import AppKit
import ApplicationServices

/// Who owns which window, from three independent sources (docs/99 §8): LaunchServices
/// (`NSRunningApplication`: name, bundle id), the window server (`CGWindowList`: owner pid, window
/// number) and Accessibility (`AXApplication` → `AXWindows`). AX needs the terminal app to be
/// trusted (System Settings → Privacy & Security → Accessibility).
enum AXReport {
    struct Expectation {
        var pid: pid_t
        var name: String
        var windowTitles: [String]
    }

    /// Prints the report; returns true when every expectation holds (or AX is unavailable and the
    /// window-server part holds).
    @discardableResult
    static func run(_ expected: [Expectation]) -> Bool {
        let trusted = AXIsProcessTrusted()
        var ok = true
        print("── ownership report ──")
        if !trusted {
            print("  AX: this process is not trusted. Allow the terminal app in System Settings → Privacy & Security → Accessibility for the AX part.")
        }
        for e in expected {
            let app = NSRunningApplication(processIdentifier: e.pid)
            print("  pid \(e.pid) \"\(app?.localizedName ?? "?")\" bundle=\(app?.bundleIdentifier ?? "?") policy=\(policy(app?.activationPolicy)) active=\(app?.isActive ?? false) file=\(app?.bundleURL?.lastPathComponent ?? "?")")
            if app?.localizedName != e.name { print("    FAIL localizedName != \"\(e.name)\""); ok = false }
            let ws = windowServerWindows(pid: e.pid)
            print("    window server: \(ws.count) window(s) at layer 0: " + ws.map { "#\($0.number)\($0.onScreen ? "" : " (off-screen)")" }.joined(separator: ", "))
            if ws.count != e.windowTitles.count { print("    FAIL expected \(e.windowTitles.count) window(s)"); ok = false }
            guard trusted else { continue }
            let element = AXUIElementCreateApplication(e.pid)
            let title: String? = attribute(element, kAXTitleAttribute)
            let frontmost: Bool? = attribute(element, kAXFrontmostAttribute)
            let focused: AXUIElement? = attribute(element, kAXFocusedWindowAttribute)
            let focusedTitle: String? = focused.flatMap { attribute($0, kAXTitleAttribute) }
            print("    AX: AXTitle=\"\(title ?? "?")\" AXFrontmost=\(frontmost.map(String.init) ?? "?") AXFocusedWindow=\"\(focusedTitle ?? "none")\"")
            if title != e.name { print("    FAIL AXTitle != \"\(e.name)\""); ok = false }
            let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
            var titles: [String] = []
            for w in windows {
                let t: String = attribute(w, kAXTitleAttribute) ?? "?"
                let role: String = attribute(w, kAXRoleAttribute) ?? "?"
                let subrole: String = attribute(w, kAXSubroleAttribute) ?? "?"
                let minimized: Bool = attribute(w, kAXMinimizedAttribute) ?? false
                let main: Bool = attribute(w, kAXMainAttribute) ?? false
                let minButton: AXUIElement? = attribute(w, kAXMinimizeButtonAttribute)
                let closeButton: AXUIElement? = attribute(w, kAXCloseButtonAttribute)
                let minEnabled: Bool = minButton.flatMap { attribute($0, kAXEnabledAttribute) } ?? false
                let closeEnabled: Bool = closeButton.flatMap { attribute($0, kAXEnabledAttribute) } ?? false
                print("      \"\(t)\" \(role)/\(subrole) minimized=\(minimized) main=\(main) minimize=\(minEnabled ? "enabled" : "DISABLED") close=\(closeEnabled ? "enabled" : "DISABLED")")
                titles.append(t)
                if subrole != kAXStandardWindowSubrole as String || !minEnabled { print("      FAIL not a standard window with an enabled minimize button"); ok = false }
            }
            if titles.sorted() != e.windowTitles.sorted() { print("    FAIL AXWindows \(titles) != expected \(e.windowTitles)"); ok = false }
        }
        print("── \(ok ? "PASS" : "FAIL")\(trusted ? "" : " (window server and LaunchServices only)") ──")
        return ok
    }

    /// Prints whatever AX says about arbitrary pids (dockspike ax <pid>...).
    static func dump(pids: [pid_t]) {
        run(pids.map { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            return Expectation(pid: pid, name: app?.localizedName ?? "?", windowTitles: [])
        })
    }

    struct WSWindow { var number: Int; var onScreen: Bool }

    static func windowServerWindows(pid: pid_t) -> [WSWindow] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == pid, w[kCGWindowLayer as String] as? Int == 0,
                  let number = w[kCGWindowNumber as String] as? Int else { return nil }
            // Zero-size utility windows some AppKit processes keep are not app windows.
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) <= 1 { return nil }
            return WSWindow(number: number, onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    private static func policy(_ p: NSApplication.ActivationPolicy?) -> String {
        switch p {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        default: "?"
        }
    }
}
