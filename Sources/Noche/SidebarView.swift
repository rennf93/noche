import AppKit
import NocheCore

/// A window control drawn as a plain circle (the window is frameless, so there are no system buttons).
final class TrafficLightView: NSView {
    override var isFlipped: Bool { true }
    var color = NSColor.gray
    var onClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func mouseDown(with event: NSEvent) {}
}

/// What a realized row shows; the controller builds it for the entries on screen only.
enum SidebarContent {
    case tab(title: String, favicon: NSImage?, selected: Bool, dormant: Bool, canReset: Bool)
    case tile(title: String, favicon: NSImage?, selected: Bool, dormant: Bool, loading: Bool, canReset: Bool)
    case group(name: String, icon: String?, colorIndex: Int, collapsed: Bool, hasActive: Bool)
}

/// Draws the outline around each expanded group (the header and its children), under the rows, in the group's color.
final class GroupBoxesView: NSView {
    override var isFlipped: Bool { true }
    struct Box: Equatable { var frame: CGRect; var colorIndex: Int }
    private static let neutral = BarHook.on("GRP_NOTINT")  // negative control: every outline stays neutral
    var boxes: [Box] = [] { didSet { if boxes != oldValue { needsDisplay = true } } }
    /// The outline color of each box, in order.
    var strokes: [NSColor] { boxes.map { ChromeStyle.groupOutline(colorIndex: $0.colorIndex) } }
    override func draw(_ dirtyRect: NSRect) {
        for box in boxes where box.frame.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: box.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.rowRadius, yRadius: ChromeStyle.rowRadius)
            ChromeStyle.groupFill.setFill()
            path.fill()
            (Self.neutral ? ChromeStyle.groupOutline : ChromeStyle.groupOutline(colorIndex: box.colorIndex)).setStroke()
            path.stroke()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The sidebar (live-ui.md section 3, note 1.1): traffic lights on top, then a scrolling list in three zones (the pinned grid, the
/// persistent rows and groups, then below the divider the New Tab row and the day's tabs), and the bottom bar.
/// The vibrancy behind it is the backdrop, so this view draws no background. The list is virtualized: `SidebarLayout` places every
/// entry, and only the entries on screen plus an overscan have a view (taken from and given back to a pool).
final class SidebarView: DragView {
    static let strip: CGFloat = 48
    // Negative controls, read once: the environment is a dictionary built on every read.
    private static let recycleCommits = BarHook.on("GRP_RECYCLECOMMIT"), groupsUnvirtual = BarHook.on("SB_GROUPSUNVIRTUAL")  // the hooks: a recycled row commits its rename; every row has a view while a group is open
    private static let fixedWidth = BarHook.on("SB_FIXEDWIDTH"), unvirtual = BarHook.on("SB_UNVIRTUAL"), lowRows = BarHook.on("SB_GEOMETRY"), noReveal = BarHook.on("SB_NOREVEAL")
    let lights: [TrafficLightView] = ChromeStyle.trafficColors.map { color in
        let v = TrafficLightView(frame: .zero)
        v.color = color
        return v
    }
    let scroll = NSScrollView()
    let document = DragView()
    let boxesView = GroupBoxesView()
    let newTabRow = NewTabRowView(frame: .zero)
    let divider = NSView()
    let bottomBar = SidebarBottomBar(frame: .zero)
    var downloadButton: DownloadButtonView { bottomBar.downloadButton }
    private(set) var layout = SidebarLayout()
    private var entries: [SidebarEntry] = []
    private var layoutWidth: CGFloat = -1
    private var realized: [SidebarEntry: NSView] = [:]
    private var spareTabs: [TabRowView] = [], spareTiles: [PinnedTileView] = [], spareGroups: [GroupRowView] = []
    private var lastSelected: TabID?
    var content: (SidebarEntry) -> SidebarContent? = { _ in nil }
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onTabMenu: ((TabID, NSPoint) -> Void)?      // the tab, click in window coordinates
    var onReset: ((TabID) -> Void)?                 // the return glyph of a pinned tab off its pinned page
    var onToggleGroup: ((GroupID) -> Void)?
    var onGroupMenu: ((GroupID, NSPoint) -> Void)?  // the group, click in window coordinates
    var onRenameTab: ((TabID, String) -> Void)?
    var onRenameGroup: ((GroupID, String) -> Void)?
    var groupColor: (GroupID) -> Int = { _ in 0 }   // a group's colorIndex, for its outline
    var onEmptyMenu: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("sidebar")
        for (i, light) in lights.enumerated() {
            light.frame = NSRect(x: ChromeStyle.trafficX[i], y: ChromeStyle.trafficY, width: ChromeStyle.trafficSize, height: ChromeStyle.trafficSize)
            light.setAccessibilityIdentifier(["window.close", "window.minimize", "window.zoom"][i])
            light.setAccessibilityElement(true)
            light.setAccessibilityRole(.button)
            light.setAccessibilityLabel(["Close", "Minimize", "Zoom"][i])
            addSubview(light)
        }
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        // Selector-based: AppKit drops this observer when the view is deallocated.
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        document.addSubview(boxesView)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ChromeStyle.sidebarDivider.cgColor
        divider.setAccessibilityIdentifier("sidebar.divider")
        document.addSubview(divider)
        newTabRow.setAccessibilityIdentifier("sidebar.newTab")
        document.addSubview(newTabRow)
        addSubview(scroll)
        addSubview(bottomBar)
        setEntries([.divider, .newTab], selected: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func scrolled(_ note: Notification) { realize(reconfigure: false) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A slide moves the sidebar without resizing it: only a new width lays out again, a new height only shows more or fewer rows.
        if layoutWidth != bounds.width, !entries.isEmpty { setEntries(entries, selected: lastSelected) } else { updateScroll(); realize(reconfigure: false) }
    }

    private func updateScroll() {
        // Frames are set only when they change: a refresh with nothing new moves nothing (every set makes AppKit lay out the scroll view).
        func put(_ v: NSView, _ f: NSRect) { if v.frame != f { v.frame = f } }
        put(scroll, NSRect(x: 0, y: Self.strip, width: bounds.width, height: max(0, bounds.height - Self.strip - ChromeStyle.sidebarBottom)))
        put(bottomBar, NSRect(x: 0, y: bounds.height - ChromeStyle.sidebarBottom, width: bounds.width, height: ChromeStyle.sidebarBottom))
        let content = layout.contentBottom - Self.strip + SidebarMetrics.bottomPad
        put(document, NSRect(x: 0, y: 0, width: bounds.width, height: max(content, scroll.bounds.height)))
        put(boxesView, document.bounds)
    }

    /// The realized view of |entry| after scrolling it into view; nil when the entry is not in the layout.
    private func reveal(_ match: (SidebarEntry) -> Bool) -> NSView? {
        guard let p = layout.placements.first(where: { match($0.entry) }) else { return nil }
        document.scrollToVisible(p.frame.offsetBy(dx: 0, dy: -Self.strip).insetBy(dx: 0, dy: -6))
        realize(reconfigure: true)
        return realized[p.entry]
    }

    /// The row's name becomes an inline field. False when the group is not in the layout.
    @discardableResult
    func beginRename(group g: GroupID) -> Bool {
        guard let v = reveal({ $0 == .group(g) }) as? GroupRowView else { return false }
        v.beginRename()
        return true
    }

    /// A tab row's title becomes an inline field (a grid tile has no title to edit: false, the caller asks another way).
    @discardableResult
    func beginRename(tab id: TabID) -> Bool {
        guard let v = reveal({ if case .tab(id, _) = $0 { true } else { false } }) as? TabRowView else { return false }
        v.beginRename()
        return true
    }

    /// The realized view of a tab or tile (an anchor for popovers), scrolled into view.
    func anchor(tab id: TabID) -> NSView? { reveal({ if case .tab(id, _) = $0 { true } else if case .gridTile(id) = $0 { true } else { false } }) }
    func anchor(group g: GroupID) -> NSView? { reveal({ $0 == .group(g) }) }
    /// The realized group row views (checks read their icon tint and name).
    func groupRow(_ g: GroupID) -> GroupRowView? { realized[.group(g)] as? GroupRowView }

    /// A right click on no row (the rows take their own): the sidebar's menu.
    override func rightMouseDown(with event: NSEvent) { onEmptyMenu?(event.locationInWindow) }

    func setTrafficLightsHidden(_ hidden: Bool) { lights.forEach { $0.isHidden = hidden } }

    /// The tab rows with a view now, in layout order.
    var rows: [TabRowView] { realized.values.compactMap { $0 as? TabRowView }.sorted { $0.frame.minY < $1.frame.minY } }
    /// How many tab rows the layout holds, with or without a view.
    var tabRowCount: Int { layout.placements.reduce(0) { if case .tab = $1.entry { $0 + 1 } else { $0 } } }
    /// How many entries have a view (tiles, group rows and tab rows), and how many of them are grid tiles (bounded by the pin count, not by the window).
    var realizedCount: Int { realized.count }
    var realizedTileCount: Int { realized.keys.filter { if case .gridTile = $0 { true } else { false } }.count }

    /// The layout's frame of the N-th tab row (window points, scrolled to the top).
    func tabFrame(_ ordinal: Int) -> CGRect? {
        layout.placements.first { if case .tab = $0.entry { $0.ordinal == ordinal } else { false } }?.frame
    }

    /// The entries in order; a view is kept for every entry still there (by tab or group id), so only a changed list lays out again.
    /// A changed selection is scrolled into view.
    func setEntries(_ new: [SidebarEntry], selected: TabID?) {
        if new != entries || layoutWidth != bounds.width {
            entries = new
            layoutWidth = bounds.width
            layout = SidebarLayout(entries: new, width: Self.fixedWidth ? ChromeStyle.sidebarWidth : bounds.width)  // negative control: a resize does not reflow the grid
            for p in layout.placements {
                switch p.entry {
                case .divider: divider.frame = p.frame.offsetBy(dx: 0, dy: -Self.strip)
                case .newTab: newTabRow.frame = p.frame.offsetBy(dx: 0, dy: -Self.strip)
                default: break
                }
            }
        }
        boxesView.boxes = layout.boxes.map { .init(frame: $0.frame.offsetBy(dx: 0, dy: -Self.strip), colorIndex: groupColor($0.group)) }  // a color change moves no entry
        updateScroll()
        if let selected, selected != lastSelected, !Self.noReveal,
           let p = layout.placements.first(where: {
               switch $0.entry { case .tab(let t, _), .gridTile(let t): t == selected; default: false }
           }) {
            document.scrollToVisible(p.frame.offsetBy(dx: 0, dy: -Self.strip).insetBy(dx: 0, dy: -6))
        }
        lastSelected = selected
        realize(reconfigure: true)
    }

    /// Gives a view to every entry that should have one and takes the views of the others back. |reconfigure|: the content may have
    /// changed (a refresh); a scroll only moves views.
    private func realize(reconfigure: Bool) {
        let clip = scroll.contentView.bounds
        let want = Self.unvirtual || (Self.groupsUnvirtual && !layout.boxes.isEmpty) ? layout.placements.indices.filter { !([.divider, .newTab].contains(layout.placements[$0].entry)) }  // negative control: every entry has a view
            : layout.realized(minY: clip.minY + Self.strip, maxY: clip.maxY + Self.strip)
        let keys = Set(want.map { layout.placements[$0].entry })
        for (key, view) in realized where !keys.contains(key) {
            realized[key] = nil
            // A rename in progress on a row that scrolls out is cancelled (the old name stays), not committed by the view leaving the window.
            if !Self.recycleCommits { (view as? GroupRowView)?.renameField.cancel(); (view as? TabRowView)?.renameField.cancel() }
            view.removeFromSuperview()
            switch view {
            case let v as TabRowView: spareTabs.append(v)
            case let v as PinnedTileView: spareTiles.append(v)
            case let v as GroupRowView: spareGroups.append(v)
            default: break
            }
        }
        for i in want {
            let p = layout.placements[i]
            let fresh = realized[p.entry] == nil
            let view = realized[p.entry] ?? makeView(for: p.entry)
            realized[p.entry] = view
            if fresh || reconfigure { view.isHidden = !configure(view, p) }
            let f = p.frame.offsetBy(dx: 0, dy: Self.lowRows ? 3 - Self.strip : -Self.strip)  // negative control: every row 3 pt low
            if view.frame != f { view.frame = f }
        }
    }

    private func makeView(for entry: SidebarEntry) -> NSView {
        let view: NSView
        switch entry {
        case .gridTile:
            let v = spareTiles.popLast() ?? PinnedTileView(frame: .zero)
            v.clearHover()
            v.onSelect = { [weak self, weak v] in if let id = v?.tabID { self?.onSelect?(id) } }
            v.onClose = { [weak self, weak v] in if let id = v?.tabID { self?.onClose?(id) } }
            v.onContextMenu = { [weak self, weak v] p in if let id = v?.tabID { self?.onTabMenu?(id, p) } }
            v.onReset = { [weak self, weak v] in if let id = v?.tabID { self?.onReset?(id) } }
            view = v
        case .group:
            let v = spareGroups.popLast() ?? GroupRowView(frame: .zero)
            v.clearHover()
            v.onClick = { [weak self, weak v] in if let g = v?.groupID { self?.onToggleGroup?(g) } }
            v.onContextMenu = { [weak self, weak v] p in if let g = v?.groupID { self?.onGroupMenu?(g, p) } }
            v.onRename = { [weak self, weak v] text in if let g = v?.groupID { self?.onRenameGroup?(g, text) } }
            view = v
        default:
            let v = spareTabs.popLast() ?? TabRowView(frame: .zero)
            v.clearHover()
            v.onSelect = { [weak self, weak v] in if let id = v?.tabID { self?.onSelect?(id) } }
            v.onClose = { [weak self, weak v] in if let id = v?.tabID { self?.onClose?(id) } }
            v.onContextMenu = { [weak self, weak v] p in if let id = v?.tabID { self?.onTabMenu?(id, p) } }
            v.onReset = { [weak self, weak v] in if let id = v?.tabID { self?.onReset?(id) } }
            v.onRename = { [weak self, weak v] text in if let id = v?.tabID { self?.onRenameTab?(id, text) } }
            view = v
        }
        document.addSubview(view)
        return view
    }

    /// False when the entry's tab or group is gone (a scroll can realize it before the queued refresh drops it): the view is cleared and hidden.
    @discardableResult
    private func configure(_ view: NSView, _ p: SidebarPlacement) -> Bool {
        guard let c = content(p.entry) else {
            (view as? TabRowView)?.tabID = nil
            (view as? PinnedTileView)?.tabID = nil
            (view as? GroupRowView)?.groupID = nil
            return false
        }
        switch (view, p.entry, c) {
        case (let v as TabRowView, .tab(let id, let level), .tab(let title, let favicon, let selected, let dormant, let canReset)):
            v.tabID = id
            v.setAccessibilityIdentifier("sidebar.tab.\(p.ordinal)")
            v.configure(title: title, favicon: favicon, selected: selected, level: level, dormant: dormant, canReset: canReset)
        case (let v as PinnedTileView, .gridTile(let id), .tile(let title, let favicon, let selected, let dormant, let loading, let canReset)):
            v.tabID = id
            v.setAccessibilityIdentifier("sidebar.pin.\(p.ordinal)")
            v.configure(title: title, favicon: favicon, selected: selected, dormant: dormant, loading: loading, canReset: canReset)
        case (let v as GroupRowView, .group(let g), .group(let name, let icon, let colorIndex, let collapsed, let hasActive)):
            v.groupID = g
            v.setAccessibilityIdentifier("sidebar.group.\(p.ordinal)")
            v.configure(name: name, icon: icon, colorIndex: colorIndex, collapsed: collapsed, hasActive: hasActive)
        default: break
        }
        return true
    }
}
