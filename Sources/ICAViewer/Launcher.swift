import AppKit
import ICAKit

/// Launcher: resource list with a search field; double-click launches.
final class LauncherWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onLaunch: ((StoreClient.Resource) -> Void)?
    private var all: [StoreClient.Resource] = []
    private var shown: [StoreClient.Resource] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")

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
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        search.placeholderString = "Search"
        search.delegate = self
        search.target = self
        search.action = #selector(launchSelected)   // Return in the search field launches the first match
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [search, scroll, status])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.spacing = 8
        stack.alignment = .leading
        for v in [search, scroll, status] { v.translatesAutoresizingMaskIntoConstraints = false }
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

    func setResources(_ list: [StoreClient.Resource]) {
        all = list.filter { $0.disabled != true }
        applyFilter()
    }

    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    @objc private func launchSelected() {
        let row = table.selectedRow >= 0 ? table.selectedRow : (shown.isEmpty ? -1 : 0)
        guard row >= 0, row < shown.count else { return }
        onLaunch?(shown[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(text)
            c.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = shown[row].name
        return cell
    }
}
