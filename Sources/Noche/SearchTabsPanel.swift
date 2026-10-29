import AppKit
import NocheCore
import NocheStore

/// What a Search Tabs row stands for: an open tab (activate), an archived one (restore it into this window) or a recently closed one (reopen it).
enum SearchSource {
    case live(TabID)
    case archived(ArchivedTab)
    case closed(ClosedTab)
}

struct SearchResult {
    let source: SearchSource
    let title: String
    let host: String
    var section: String {
        switch source {
        case .live: ""
        case .archived: "Archived"
        case .closed: "Recently Closed"
        }
    }
    var id: TabID {
        switch source {
        case .live(let id): id
        case .archived(let a): a.tab.id
        case .closed(let c): c.tab.id
        }
    }
}

/// The card of Shift+Cmd+A: the command bar's fill, border and radius around a search field and up to `searchMaxLines` lines of results (rows of 40 pt under
/// "Archived" and "Recently Closed" headers). The view lays itself out from the lines it is given.
final class SearchTabsView: NSView {
    override var isFlipped: Bool { true }
    enum Line: Equatable { case header(String), result(Int) }
    let field = NSTextField()
    let iconView = NSImageView()
    private var rowViews: [SuggestionRowView] = []
    private var headerViews: [NSTextField] = []
    var onRowClick: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityIdentifier("searchTabs")
        let cell = CommandBarFieldCell(textCell: "")
        cell.isEditable = true
        cell.isScrollable = true
        cell.lineBreakMode = .byClipping
        field.cell = cell
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = ChromeStyle.barInputFontNewTab
        field.maximumNumberOfLines = 1
        field.placeholderAttributedString = NSAttributedString(string: "Search tabs", attributes: [.foregroundColor: ChromeStyle.barPlaceholder, .font: ChromeStyle.barInputFontNewTab])
        field.setAccessibilityIdentifier("searchTabs.input")
        field.setAccessibilityLabel("Search tabs")
        iconView.imageScaling = .scaleNone
        iconView.image = ChromeStyle.symbol("magnifyingglass", size: 13, color: ChromeStyle.barPlaceholder)
        addSubview(iconView)
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.barRadius, yRadius: ChromeStyle.barRadius)
        ChromeStyle.barFill.setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
    }

    static func height(for lines: [Line]) -> CGFloat {
        let body = lines.reduce(CGFloat(0)) { sum, l in
            if case .header = l { return sum + ChromeStyle.searchHeaderHeight }
            return sum + ChromeStyle.searchRowHeight
        }
        return ChromeStyle.searchInputHeight + body + (lines.isEmpty ? 0 : ChromeStyle.searchPad)
    }

    /// Puts the lines in; |rows| names what each result row shows, |selected| the highlighted result.
    func apply(lines: [Line], rows: [BarRow], selected: Int?) {
        let pad = ChromeStyle.searchPad
        iconView.frame = NSRect(x: 20, y: (ChromeStyle.searchInputHeight - 16) / 2, width: 20, height: 16)
        field.frame = NSRect(x: 44, y: (ChromeStyle.searchInputHeight - 22) / 2, width: max(0, bounds.width - 44 - 16), height: 22)
        var results = 0, headers = 0, y = ChromeStyle.searchInputHeight
        for line in lines {
            switch line {
            case .header(let text):
                if headers == headerViews.count {
                    let l = NSTextField(labelWithString: "")
                    l.font = ChromeStyle.searchHeaderFont
                    l.textColor = ChromeStyle.barHost
                    headerViews.append(l)
                    addSubview(l)
                }
                let l = headerViews[headers]
                l.stringValue = text
                l.frame = NSRect(x: pad + 14, y: y + 6, width: bounds.width - 2 * pad - 28, height: 16)
                l.isHidden = false
                headers += 1
                y += ChromeStyle.searchHeaderHeight
            case .result(let i):
                if results == rowViews.count {
                    let v = SuggestionRowView(frame: .zero)
                    v.onClick = { [weak self, weak v] in if let v, let at = self?.rowViews.firstIndex(of: v) { self?.onRowClick?(at) } }
                    rowViews.append(v)
                    addSubview(v)
                }
                let v = rowViews[results]
                v.setAccessibilityIdentifier("searchTabs.row.\(i)")
                v.content = rows[i]
                v.isSelected = i == selected
                v.frame = NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: ChromeStyle.searchRowHeight)
                v.isHidden = false
                results += 1
                y += ChromeStyle.searchRowHeight
            }
        }
        for v in rowViews[results...] { v.isHidden = true }
        for v in headerViews[headers...] { v.isHidden = true }
        needsDisplay = true
    }
}

/// Search Tabs (M1.6 Task 6, spec "Search Tabs"): live tabs, then archived tabs, then recently closed ones, filtered by the matcher the list and the store share
/// (prefix, substring, subsequence on title and host, the most recent first within a rank). Up and Down move, Return acts, Escape closes, Cmd+Delete closes an open tab.
@MainActor
final class SearchTabsController: NSObject, NSTextFieldDelegate {
    unowned let owner: BrowserWindowController
    let view = SearchTabsView(frame: .zero)
    private(set) var isOpen = false
    private(set) var query = ""
    private(set) var results: [SearchResult] = []
    private(set) var selected = 0
    private(set) var lines: [SearchTabsView.Line] = []
    private var firstLine = 0   // the first line shown: the card scrolls once the lines pass `searchMaxLines`
    private var monitor: Any?

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init()
        view.field.delegate = self
        view.onRowClick = { [weak self] i in self?.select(i); self?.commit() }
    }

    // MARK: open and close

    func open() {
        owner.note("searchTabs")
        if let bar = owner.madeCommandBar, bar.isOpen {  // one card at a time owns the keys: an overlay bar closes, the New Tab card gives up its hold
            if bar.placement == .overlay { bar.close(restoreFocus: false) } else { bar.unfocusCard(restoreFocus: false) }
        }
        if !isOpen {
            isOpen = true
            owner.overlay.addSubview(view, positioned: .below, relativeTo: owner.border)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseDown(event) }
                return event
            }
        }
        setQuery("")
        if let ns = owner.nsWindow { ns.makeFirstResponder(view.field) }
        view.field.currentEditor()?.selectAll(nil)
        if !BarHook.on("SEARCH_NOKEYS") { owner.window.keysHeld = true }  // like the command bar: the engine's focus requests are refused until the close (the hook: no hold)
    }

    func close(restoreFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        owner.window.keysHeld = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let editing = view.field.currentEditor() != nil
        view.removeFromSuperview()
        if editing, let ns = owner.nsWindow { ns.makeFirstResponder(ns.contentView) }
        if restoreFocus { owner.window.focusActiveContent() }
        query = ""
        results = []
    }

    func teardown() { close(restoreFocus: false) }

    private func mouseDown(_ event: NSEvent) {
        guard isOpen, event.window === owner.nsWindow else { return }
        if !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { close(restoreFocus: false) }
    }

    // MARK: results

    /// Live tabs, then archived ones, then recently closed ones: each block as its matcher ranks it.
    func compute(_ q: String) -> [SearchResult] {
        let store = owner.app.writer?.store
        let live = Set(owner.list.items.map(\.id))
        var matched = owner.list.searchTabs(query: q)
        if BarHook.on("SEARCH_UNRANKED") { let order = owner.list.items.map(\.id); matched.sort { order.firstIndex(of: $0) ?? 0 < order.firstIndex(of: $1) ?? 0 } }  // negative control: list order, not rank
        var out: [SearchResult] = matched.compactMap { id in
            guard live.contains(id), let t = owner.item(withID: id) else { return nil }
            return SearchResult(source: .live(id), title: owner.shownTitle(t), host: AddressInput.displayHost(t.url))
        }
        for a in BarHook.on("SEARCH_NOARCHIVE") ? [] : (try? store?.archivedTabs(matching: q)) ?? [] where !live.contains(a.tab.id) {  // the hooks: no archived block, no closed block
            out.append(SearchResult(source: .archived(a), title: TabList.displayTitle(for: a.tab), host: AddressInput.displayHost(a.tab.url)))
        }
        for c in BarHook.on("SEARCH_NOCLOSED") ? [] : (try? store?.closedTabs(matching: q)) ?? [] where !live.contains(c.tab.id) {
            out.append(SearchResult(source: .closed(c), title: TabList.displayTitle(for: c.tab), host: AddressInput.displayHost(c.tab.url)))
        }
        return out
    }

    func setQuery(_ q: String) {
        view.field.stringValue = q
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    private func refresh() {
        query = view.field.currentEditor()?.string ?? view.field.stringValue
        results = compute(query)
        selected = 0
        firstLine = 0
        render()
    }

    private func render() {
        var all: [SearchTabsView.Line] = []
        var section = ""
        for (i, r) in results.enumerated() {
            if r.section != section { section = r.section; if !section.isEmpty { all.append(.header(section)) } }
            all.append(.result(i))
        }
        // Keep the selected line (and the header above it, when it is the section's first row) in the window of lines.
        let at = all.firstIndex(of: .result(selected)) ?? 0
        let max = ChromeStyle.searchMaxLines
        if at < firstLine { firstLine = at } else if at >= firstLine + max { firstLine = at - max + 1 }
        if at > 0, firstLine == at, case .header = all[at - 1] { firstLine = at - 1 }
        firstLine = Swift.max(0, Swift.min(firstLine, Swift.max(0, all.count - max)))
        lines = Array(all.dropFirst(firstLine).prefix(max))
        let overlay = owner.overlay
        let w = Swift.min(ChromeStyle.searchWidth, Swift.max(0, overlay.bounds.width - 24))
        view.frame = NSRect(x: (overlay.bounds.width - w) / 2, y: ChromeStyle.searchTop, width: w, height: SearchTabsView.height(for: lines))
        let rows = results.map { r -> BarRow in
            let hint: String? = switch r.source { case .live: nil; case .archived: "Restore"; case .closed: "Reopen" }
            return BarRow(kind: "tab", title: r.host.isEmpty ? r.title : "\(r.title) - \(r.host)", url: "", symbol: "macwindow", hint: hint)
        }
        view.apply(lines: lines, rows: rows, selected: results.isEmpty ? nil : selected)
    }

    // MARK: keys

    func select(_ i: Int) {
        guard results.indices.contains(i) else { return }
        selected = i
        render()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        select(Swift.max(0, Swift.min(results.count - 1, selected + delta)))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):  // Cmd+Delete on an open tab's row closes it; anywhere else it edits the text
            guard closeSelected() else { return false }
        default: return false
        }
        return true
    }

    /// Closes the selected result's tab when it is an open one; the row goes at once.
    @discardableResult
    func closeSelected() -> Bool {
        guard results.indices.contains(selected), case .live(let id) = results[selected].source, let item = owner.item(withID: id), let row = owner.list.items.firstIndex(where: { $0.id == id }) else { return false }
        // The sidebar's own close path: an open tab closes, a dormant one leaves like a closed tab; a pinned dormant tile stays (it wakes on a click).
        guard owner.engineTab(item) != nil || (!item.isPinned && !BarHook.on("SEARCH_NODORMANTCLOSE")) else { return false }  // the hook: only a loaded tab closes
        owner.closeRow(row)
        results.remove(at: selected)
        selected = Swift.min(selected, Swift.max(0, results.count - 1))
        render()
        return true
    }

    /// Return: an open tab comes forward, an archived one is restored into this window, a recently closed one is reopened.
    func commit() {
        guard results.indices.contains(selected) else { return }
        let r = results[selected]
        close(restoreFocus: false)
        switch r.source {
        case .live(let id):
            if let item = owner.item(withID: id), !BarHook.on("SEARCH_NOACTIVATE") { owner.activate(item) }  // the hook: Return does nothing for an open tab
        case .archived(let a):
            guard let store = owner.app.writer?.store, let restored = ((try? store.restoreArchived(id: a.tab.id)) ?? nil) else { return }
            if !owner.reopen(restored.tab, at: Int.max) { try? store.archive(ids: [a.tab.id], at: a.tab.archivedAt ?? Date()) }  // the engine could not add it: it stays archived
        case .closed(let c):
            if owner.reopen(c.tab, at: c.windowID == owner.id ? c.index : Int.max) { owner.app.writer?.reopened(c.tab.id) }
        }
    }
}

extension BrowserWindowController {
    /// Tabs > Search Tabs... (Shift+Cmd+A): opens the card, or closes it when it is open already.
    func toggleSearchTabs() {
        if let card = madeSearch, card.isOpen { card.close() } else { searchTabsCard.open() }
    }
}
