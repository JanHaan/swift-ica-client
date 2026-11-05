import AppKit
import ICAKit

/// Launcher: resource list with a search field; double-click launches.
final class LauncherWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onLaunch: ((StoreClient.Resource) -> Void)?
    private var all: [StoreClient.Resource] = []
    private var shown: [StoreClient.Resource] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var sized = false
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let sessionsStack = NSStackView()

    /// One running session in the launcher.
    struct SessionRow {
        var title: String
        var detail: String
        var canShow: Bool
        var show: () -> Void
        var logoff: () -> Void
    }
    private var rowActions: [Int: () -> Void] = [:]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ICA Viewer"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Resource"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(launchSelected)
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        search.placeholderString = "Search"
        search.delegate = self
        search.target = self
        search.action = #selector(launchSelected)   // Return in the search field launches the first match
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 4
        let stack = NSStackView(views: [search, scroll, sessionsStack, status])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.spacing = 8
        stack.alignment = .leading
        for v in [search, scroll, sessionsStack, status] { v.translatesAutoresizingMaskIntoConstraints = false }
        window.contentView = stack
        NSLayoutConstraint.activate([
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ text: String) { status.stringValue = text }

    /// Running sessions, each with Show (when it has no visible window) and Log off.
    func setSessions(_ rows: [SessionRow]) {
        sessionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowActions.removeAll()
        var tag = 0
        func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
            tag += 1
            rowActions[tag] = action
            let b = NSButton(title: title, target: self, action: #selector(rowButton(_:)))
            b.tag = tag
            b.bezelStyle = .rounded
            b.controlSize = .small
            return b
        }
        for row in rows {
            let label = NSTextField(labelWithString: "\(row.title): \(row.detail)")
            label.lineBreakMode = .byTruncatingTail
            var views: [NSView] = [label]
            if row.canShow { views.append(button("Show", row.show)) }
            views.append(button("Log off", row.logoff))
            let line = NSStackView(views: views)
            line.orientation = .horizontal
            line.spacing = 6
            sessionsStack.addArrangedSubview(line)
        }
    }

    @objc private func rowButton(_ sender: NSButton) { rowActions[sender.tag]?() }

    func setResources(_ list: [StoreClient.Resource]) {
        all = list.filter { $0.disabled != true }
        applyFilter()
        fitWindowToContent()
    }

    /// Once, with the first list: the window is as tall as its rows need (260 to 520 pt), so a short
    /// list leaves no empty striped rows below it. The top edge stays where it is.
    private func fitWindowToContent() {
        guard !sized, let window, !all.isEmpty, let content = window.contentView else { return }
        sized = true
        content.layoutSubtreeIfNeeded()
        let chrome = content.frame.height - scroll.frame.height
        let rows = CGFloat(all.count) * (table.rowHeight + table.intercellSpacing.height)
        let height = min(max(chrome + rows + 2, 260), 520)
        let old = window.frame
        window.setContentSize(NSSize(width: content.frame.width, height: height))
        window.setFrameOrigin(NSPoint(x: old.minX, y: old.maxY - window.frame.height))
    }

    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) || displayName($0.name).localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    @objc private func launchSelected() {
        let row = table.selectedRow >= 0 ? table.selectedRow : (shown.isEmpty ? -1 : 0)
        guard row >= 0, row < shown.count else { return }
        onLaunch?(shown[row])
    }

    /// The store sends no icons we use; every resource gets the system's generic application icon.
    private static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView(image: Self.genericIcon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(icon)
            c.addSubview(text)
            c.imageView = icon
            c.textField = text
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = displayName(shown[row].name)
        return cell
    }
}
