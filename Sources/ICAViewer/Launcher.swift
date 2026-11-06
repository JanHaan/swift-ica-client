import AppKit
import ICAKit

/// Launcher: resource list with a search field; double-click launches.
final class LauncherWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onLaunch: ((StoreClient.Resource) -> Void)?
    var onConnectionCenter: (() -> Void)?
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
        var disconnect: () -> Void
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
        table.doubleAction = #selector(launchClicked)
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)   // the last row is not flush
        table.rowHeight = 24

        search.placeholderString = "Search"
        // Typing only filters. NSSearchField sends its action on every change, so it has none; Return
        // (insertNewline, below) launches the first match.
        search.delegate = self
        search.sendsWholeSearchString = true
        search.sendsSearchStringImmediately = false
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 4
        let centerButton = NSButton(title: loc("Connection Center…", "Verbindungscenter…"), target: self, action: #selector(openConnectionCenter))
        centerButton.bezelStyle = .rounded
        centerButton.controlSize = .small
        let footer = NSStackView(views: [status, centerButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [search, scroll, sessionsStack, footer])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.spacing = 8
        stack.alignment = .leading
        for v in [search, scroll, sessionsStack, footer] { v.translatesAutoresizingMaskIntoConstraints = false }
        window.contentView = stack
        NSLayoutConstraint.activate([
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        window.center()
        NotificationCenter.default.addObserver(forName: .storeIconsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateVisibleIcons()
        }
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
            views.append(button("Disconnect", row.disconnect))
            views.append(button("Log off", row.logoff))
            let line = NSStackView(views: views)
            line.orientation = .horizontal
            line.spacing = 6
            sessionsStack.addArrangedSubview(line)
        }
    }

    @objc private func rowButton(_ sender: NSButton) { rowActions[sender.tag]?() }

    @objc private func openConnectionCenter() { onConnectionCenter?() }

    func setResources(_ list: [StoreClient.Resource]) {
        all = list.filter { $0.disabled != true }
        applyFilter()
        fitWindowToContent()
    }

    /// Once, with the first list: the window is as tall as its rows need (260 to 520 pt), so a short
    /// list leaves no empty striped rows and no scroller. Measured, not estimated: the rows' real
    /// extent (`rect(ofRow:)`, with row and intercell spacing), the scroll view's border and a small
    /// bottom inset. The top edge stays where it is.
    private func fitWindowToContent() {
        guard !sized, let window, !all.isEmpty, let content = window.contentView else { return }
        sized = true
        table.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let tableHeight = table.rect(ofRow: all.count - 1).maxY
        let border = scroll.frame.height - scroll.contentSize.height + scroll.contentInsets.top + scroll.contentInsets.bottom
        let needed = tableHeight + border
        let old = window.frame
        func apply(_ scrollHeight: CGFloat) {
            let chrome = content.frame.height - scroll.frame.height
            let height = min(max(chrome + scrollHeight, 260), 520)
            window.setContentSize(NSSize(width: content.frame.width, height: height))
            window.setFrameOrigin(NSPoint(x: old.minX, y: old.maxY - window.frame.height))
            content.layoutSubtreeIfNeeded()
        }
        apply(needed)
        // Verify on the laid-out result and grow once if the rows still do not fit (up to the maximum).
        let visible = scroll.contentSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        let shortfall = tableHeight - visible
        if shortfall > 0.5 { apply(scroll.frame.height + shortfall) }
        let after = scroll.contentSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        vlog(String(format: "launcher: %d rows need %.1f pt, visible %.1f pt, window content %.0f pt",
                    all.count, tableHeight, after, content.frame.height))
    }

    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) || displayName($0.name).localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    /// Return in the search field launches the first visible match; other keys keep their meaning.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let first = shown.first { start(first) }
        return true
    }

    /// Double-click: the clicked row.
    @objc private func launchClicked() {
        let row = table.clickedRow
        guard row >= 0, row < shown.count else { return }
        start(shown[row])
    }

    /// Resource being started; a second launch of it is ignored until `launchEnded()`.
    private var starting: String?

    private func start(_ resource: StoreClient.Resource) {
        if let starting {
            vlog("launcher: \(resource.name) not launched; \(starting) is still starting")
            setStatus("Starting \(displayName(starting))…")
            return
        }
        starting = resource.name
        setStatus("Starting \(displayName(resource.name))…")
        onLaunch?(resource)
    }

    /// The app delegate's launch finished (connected or failed).
    func launchEnded() { starting = nil }

    /// Placeholder until a resource's own icon is loaded (and for resources without one, and in demo mode).
    private static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    /// Row icon size in points; the images are rendered at 4x, so they stay sharp on Retina.
    private static let iconSide: CGFloat = 18
    private var rowIcons: [String: NSImage] = [:]   // iconurl → rendered row icon

    /// The resource's own icon if it is loaded. Asking starts the fetch (StoreIconCache, shared with the
    /// Dock icon), so only rows that are laid out ask: a view-based table makes cells for visible rows only.
    private func rowIcon(for resource: StoreClient.Resource) -> NSImage? {
        guard let url = resource.iconurl, !url.isEmpty else { return nil }
        if let icon = rowIcons[url] { return icon }
        guard let image = StoreIconCache.shared.image(forIconURL: url),
              let canvas = IconCanvas.render(image, side: Int(Self.iconSide * 4), inset: 0) else { return nil }
        let icon = NSImage(cgImage: canvas, size: NSSize(width: Self.iconSide, height: Self.iconSide))
        rowIcons[url] = icon
        return icon
    }

    /// An icon arrived (or the store changed): swap it into the visible cells in place, no reload.
    private func updateVisibleIcons() {
        guard window?.isVisible == true else { return }
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) where row < shown.count {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let icon = rowIcon(for: shown[row]) else { continue }
            cell.imageView?.image = icon
        }
    }

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
        cell.imageView?.image = rowIcon(for: shown[row]) ?? Self.genericIcon
        return cell
    }
}
