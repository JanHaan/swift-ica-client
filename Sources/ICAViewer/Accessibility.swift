import AppKit

/// VoiceOver helpers for our own windows (docs/ux/audit.md §4).
@MainActor
enum Access {
    /// Speaks `text` now (an error that appeared, a notice): EN 301 549 11.4.1.3, status messages.
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// A grid label ("User name:") as an accessibility label ("User name").
    static func name(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    /// Two-column grids (label, control): text fields and popups get the row's label, or the label of the last
    /// row that had one, so VoiceOver reads "User name, edit text" instead of "edit text". Checkboxes and radio
    /// buttons keep their own titles. Controls that already have a label are left alone.
    static func labelControls(in grid: NSGridView) {
        var current = ""
        for r in 0..<grid.numberOfRows {
            if let label = grid.cell(atColumnIndex: 0, rowIndex: r).contentView as? NSTextField,
               !label.isEditable, !label.stringValue.isEmpty {
                current = name(label.stringValue)
            }
            guard grid.numberOfColumns > 1, let view = grid.cell(atColumnIndex: 1, rowIndex: r).contentView else { continue }
            label(view, as: current)
        }
    }

    private static func label(_ view: NSView, as text: String) {
        if let stack = view as? NSStackView {
            for sub in stack.arrangedSubviews { label(sub, as: text) }
            return
        }
        guard !text.isEmpty, (view.accessibilityLabel() ?? "").isEmpty else { return }
        if let field = view as? NSTextField, field.isEditable {
            field.setAccessibilityLabel(text)
        } else if view is NSPopUpButton {
            view.setAccessibilityLabel(text)
        }
    }
}

extension NSColor {
    /// Secondary text that keeps WCAG AA (4.5:1) and ASR A6 (4:1): on macOS 26 `secondaryLabelColor` measures 3.06:1
    /// on the light window background (docs/ux/audit.md §4.1), so light mode uses 58 % black (about 5.2:1). Dark mode
    /// (4.86:1) and Increase Contrast keep the system colour. Not for text on the dark HUD material.
    static let secondaryText = NSColor(name: "ICAViewerSecondaryText") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .aqua?: NSColor(white: 0, alpha: 0.58)
        default: .secondaryLabelColor
        }
    }
}
