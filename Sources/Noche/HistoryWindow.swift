import AppKit
import NocheCore
import NocheStore

/// One row of the History window: a day header or a visit.
enum HistoryEntry: Equatable {
    case day(String)
    case visit(HistoryVisit)
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
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let app: AppDelegate
    let window: NSWindow
    let search = NSSearchField()
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let table = HistoryTableView()
    private(set) var entries: [HistoryEntry] = []
    /// Visits loaded at most (newest first).
    static let limit = 500

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "History"
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
        let scroll = NSScrollView()
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
    }

    func show() {
        BrowserWindowController.note("showHistory")
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    private static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: day)
    }

    @objc func reload() {
        let q = BarHook.on("HIST_NOSEARCH") ? "" : search.stringValue.trimmingCharacters(in: .whitespaces)
        let days = (try? app.writer?.store.historyDays(calendar: .current, search: q, limit: Self.limit)) ?? []
        entries = days.flatMap { d in
            let visits = BarHook.on("HIST_OLDEST") ? d.visits.reversed() : d.visits  // negative control: oldest first
            return [HistoryEntry.day(Self.dayTitle(d.day))] + visits.map(HistoryEntry.visit)
        }
        table.reloadData()
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

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        switch entries[row] {
        case .day(let t):
            text = t
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
