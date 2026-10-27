import AppKit
import NocheCore
import NocheStore

/// One row of the History window: a day header or a visit.
enum HistoryEntry: Equatable {
    case day(String)
    case visit(HistoryVisit)
    /// The last line of a list that stopped at the cap.
    case note(String)
}

final class HistoryTableView: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117) && !BarHook.on("HIST_NOKEY") { onDelete?() } else { super.keyDown(with: event) }  // Delete and Forward Delete
    }
}

/// The History window (History > Show History, Cmd+Y): a native window over the store's visits, grouped by local day, newest first.
/// A search field filters by title or address, a double click opens the page in a new tab, Delete removes the page and its visits.
@MainActor
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    unowned let app: AppDelegate
    let window: NSWindow
    let search = NSSearchField()
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let table = HistoryTableView()
    private(set) var entries: [HistoryEntry] = []
    private let scroll = NSScrollView()
    /// Visits loaded at most (newest first); the store's search is capped the same way (`historyDays` applies its limit to the matches).
    static let limit = 500
    /// Posted when a visit is recorded or a title is written: an open window reloads (coalesced).
    static let changed = Notification.Name("NocheHistoryChanged")
    private var refreshQueued = false

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "History"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 240)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ChromeStyle.cardFill
        window.setAccessibilityIdentifier("history.window")
        if app.hidden && !BarHook.on("HIST_NOFLOAT") { window.level = .floating }

        search.placeholderString = "Search history"
        search.target = self
        search.action = #selector(reload)
        search.setAccessibilityIdentifier("history.search")
        deleteButton.bezelStyle = .rounded
        deleteButton.toolTip = "Delete the selected page and all its visits, on every day"
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.setAccessibilityIdentifier("history.delete")
        for (id, title, width) in [("time", "Time", 70), ("title", "Title", 300), ("address", "Address", 300)] as [(String, String, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 50
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.setAccessibilityIdentifier("history.list")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier("history.scroll")

        let content = window.contentView!
        for v in [search, deleteButton, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            deleteButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            deleteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.center()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: Self.changed, object: nil)
    }

    /// A visit or a title was written behind the window: one reload after a short quiet, keeping the selection and the scroll position.
    @objc private func historyChanged() {
        guard window.isVisible, !refreshQueued, !BarHook.on("HIST_NOLIVE") else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.refreshQueued = false; self?.reload() }
        }
    }

    /// Changes made while the window sat in the Dock were skipped (`historyChanged` waits for a visible window): reload when it comes back or becomes key.
    func windowDidDeminiaturize(_ notification: Notification) { if !BarHook.on("HIST_NOWAKE") { reload() } }
    func windowDidBecomeKey(_ notification: Notification) { if !BarHook.on("HIST_NOWAKE") { reload() } }

    func show() {
        BrowserWindowController.note("showHistory")
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func reload() {
        let searching = !(BarHook.on("HIST_NOSEARCH") ? "" : search.stringValue.trimmingCharacters(in: .whitespaces)).isEmpty
        let q = BarHook.on("HIST_NOSEARCH") ? "" : search.stringValue.trimmingCharacters(in: .whitespaces)
        let keep = selectedVisit, top = scroll.contentView.bounds.origin.y
        // One visit over the cap is asked for: that is how a list that stopped at the cap is told from one that ended there.
        let days = (try? app.writer?.store.historyDays(calendar: .current, search: q, limit: Self.limit + 1)) ?? []
        let capped = days.reduce(0) { $0 + $1.visits.count } > Self.limit
        var budget = Self.limit
        let now = Date()
        entries = []
        for d in days where budget > 0 {
            let visits = Array((BarHook.on("HIST_OLDEST") ? d.visits.reversed() : d.visits).prefix(budget))  // HIST_OLDEST: negative control, oldest first
            budget -= visits.count
            entries.append(.day(HistoryDayLabel.title(for: d.day, calendar: .current, now: now)))
            entries += visits.map(HistoryEntry.visit)
        }
        if capped && !BarHook.on("HIST_NOFOOTER") {
            entries.append(.note(searching ? "Showing the \(Self.limit) most recent matches. Narrow the search to find older ones." : "Showing the \(Self.limit) most recent visits. Search to find older ones."))
        }
        table.reloadData()
        if !BarHook.on("HIST_NOKEEP") {
            if let keep, let r = entries.firstIndex(where: { if case .visit(let v) = $0 { v.url == keep.url && v.visitedAt == keep.visitedAt } else { false } }) { table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private var selectedVisit: HistoryVisit? {
        let r = table.selectedRow
        guard r >= 0, r < entries.count, case .visit(let v) = entries[r] else { return nil }
        return v
    }

    @objc func openSelected() {
        // The row that was double clicked (a day header or blank space opens nothing); the selection when the action is not from a click.
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < entries.count, case .visit(let v) = entries[r], !BarHook.on("HIST_NOOPEN") else { return }
        app.openHistoryURL(v.url)
    }

    @objc func deleteSelected() {
        guard let v = selectedVisit else { return }
        if !BarHook.on("HIST_NODELETE") { do { try app.writer?.store.deletePage(url: v.url) } catch { FileHandle.standardError.write(Data("NOCHE history delete failed: \(error)\n".utf8)) } }
        reload()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .visit = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        switch entries[row] {
        case .day(let t):
            text = t
        case .note(let t):
            text = tableColumn?.identifier.rawValue == "title" ? t : ""
        case .visit(let v):
            switch tableColumn?.identifier.rawValue {
            case "time": text = v.visitedAt.formatted(date: .omitted, time: .shortened)
            case "title": text = v.title.isEmpty ? v.url : v.title
            default: text = v.url
            }
        }
        let field = NSTextField(labelWithString: text)
        field.font = ChromeStyle.font
        field.textColor = ChromeStyle.titleColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
