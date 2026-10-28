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

/// A press on a row that then moves 3 pt starts the row's drag (note 4.1); a press that does not is a click.
struct DragTrigger {
    static let distance: CGFloat = 3
    private static let noThreshold = BarHook.on("DRAG_NOTHRESHOLD")  // the hook: any movement starts the drag
    private var origin: NSPoint?
    mutating func press(_ event: NSEvent) { origin = event.locationInWindow }
    /// True when the press ends with no drag begun: the click.
    mutating func release() -> Bool { defer { origin = nil }; return origin != nil }
    /// True once, when |event| is 3 pt or more from the press.
    mutating func moved(_ event: NSEvent) -> Bool {
        guard let o = origin, hypot(event.locationInWindow.x - o.x, event.locationInWindow.y - o.y) >= (Self.noThreshold ? 0 : Self.distance) else { return false }
        origin = nil
        return true
    }
}

/// The trackpad tap of a changed insertion slot (setting `hapticReorder`). Test builds count the taps.
enum Haptic {
#if NOCHE_TESTHOOKS
    nonisolated(unsafe) static var taps = 0
#endif
    static func tap() {
#if NOCHE_TESTHOOKS
        taps += 1
#endif
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// What a drag would drop into: the insertion line, the folder outline or the grid slot's ghost (`DropIndicator`, layout coordinates).
final class DropIndicatorView: NSView {
    override var isFlipped: Bool { true }
    var kind: DropIndicator = .line(.zero) { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .line:
            ChromeStyle.dropLine.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        case .folder:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: ChromeStyle.dropOutlineWidth / 2, dy: ChromeStyle.dropOutlineWidth / 2), xRadius: ChromeStyle.rowRadius, yRadius: ChromeStyle.rowRadius)
            path.lineWidth = ChromeStyle.dropOutlineWidth
            ChromeStyle.dropOutline.setStroke()
            path.stroke()
        case .ghost:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.tileRadius, yRadius: ChromeStyle.tileRadius)
            ChromeStyle.tileFill.setFill()
            path.fill()
            ChromeStyle.tileBorder.setStroke()
            path.stroke()
        }
    }
}

/// The list's own view: the drag destination (note 4.1; it forwards to the sidebar, which knows the layout).
final class SidebarDocumentView: DragView {
    weak var owner: SidebarView?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.dragMoved(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.dragMoved(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.dragLeft() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { owner?.dragDropped(sender) ?? false }
}

/// The sidebar (live-ui.md section 3, note 1.1): traffic lights on top, then a scrolling list in three zones (the pinned grid, the
/// persistent rows and groups, then below the divider the New Tab row and the day's tabs), and the bottom bar.
/// The vibrancy behind it is the backdrop, so this view draws no background. The list is virtualized: `SidebarLayout` places every
/// entry, and only the entries on screen plus an overscan have a view (taken from and given back to a pool).
final class SidebarView: DragView, NSDraggingSource {
    static let strip: CGFloat = 48
    // Negative controls, read once: the environment is a dictionary built on every read.
    private static let recycleCommits = BarHook.on("GRP_RECYCLECOMMIT"), groupsUnvirtual = BarHook.on("SB_GROUPSUNVIRTUAL")  // the hooks: a recycled row commits its rename; every row has a view while a group is open
    private static let noIndicator = BarHook.on("DRAG_NOINDICATOR"), noExpand = BarHook.on("DRAG_NOEXPAND"), noHaptic = BarHook.on("DRAG_NOHAPTIC")  // the hooks: no indicator, no auto-expand, no tap
    private static let hapticAlways = BarHook.on("DRAG_HAPTICIGNORE"), anyWindow = BarHook.on("DRAG_ANYWINDOW"), dragRecycles = BarHook.on("DRAG_RECYCLE"), cancelDrops = BarHook.on("DRAG_CANCELDROPS")  // the hooks: the setting is ignored, another window's drop is taken, the dragged row is recycled, a cancel drops
    private static let noOrigin = BarHook.on("DRAG_NOORIGIN"), indicatorLow = BarHook.on("DRAG_INDICATORLOW"), anyId = BarHook.on("DRAG_UNKNOWNID"), ownRowMoves = BarHook.on("DRAG_OWNROW")  // the hooks: no origin slot, the indicator is left under later rows, an unknown id is taken, a drop on the item's own row lands below it
    private static let fixedWidth = BarHook.on("SB_FIXEDWIDTH"), unvirtual = BarHook.on("SB_UNVIRTUAL"), lowRows = BarHook.on("SB_GEOMETRY"), noReveal = BarHook.on("SB_NOREVEAL")
    let lights: [TrafficLightView] = ChromeStyle.trafficColors.map { color in
        let v = TrafficLightView(frame: .zero)
        v.color = color
        return v
    }
    let scroll = NSScrollView()
    let document = SidebarDocumentView()
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
    var onReturnFocus: ((Bool) -> Void)?            // a rename ended: focus goes back to the page (true: unless a click moved it)
    var windowID = UUID()                           // the window a drag starts in: another window's drop is refused
    var isGroupCollapsed: (GroupID) -> Bool = { _ in false }
    var isKnown: (DragItem) -> Bool = { _ in true }  // the tab or group is in the window's list (a tab inside a closed folder is, with no row)
    var onDrop: ((DragItem, DropTarget) -> Bool)?   // the list change of an accepted drop
    var onOpenFolder: ((GroupID) -> Void)?          // a drag hovered a closed folder long enough
    var onDragEnd: ((DragItem, [GroupID]) -> Void)? // the drag is over; the folders it opened
    var hapticOn: () -> Bool = { true }             // setting hapticReorder, read when a drag starts

    /// The drag in progress. |entry| is the dragged row: it keeps its view and counts inside the realized budget.
    struct DragState {
        var item: DragItem
        var entry: SidebarEntry?
        var haptic: Bool
        var slot: DropTarget?
        var hover: GroupID?
        var timer: Timer?
        var opened: [GroupID] = []
    }
    private(set) var drag: DragState?
    private(set) var dropIndicator: DropIndicator?
    let indicatorView = DropIndicatorView()

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
        document.owner = self
        document.registerForDraggedTypes([NSPasteboard.PasteboardType(DragPayload.pasteboardType)])
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
        var kept = want
        // The dragged row keeps its view, and counts inside the realized budget: the realized row farthest from it goes.
        if !Self.dragRecycles, let e = drag?.entry, let di = layout.placements.firstIndex(where: { $0.entry == e }), !kept.contains(di) {
            func isTile(_ i: Int) -> Bool { if case .gridTile = layout.placements[i].entry { true } else { false } }
            if kept.filter({ !isTile($0) }).count >= SidebarMetrics.realizedBudget, let first = kept.first {
                let far = di < first ? kept.last(where: { !isTile($0) }) : kept.first(where: { !isTile($0) })
                kept.removeAll { $0 == far }
            }
            kept.append(di)
        }
        let keys = Set(kept.map { layout.placements[$0].entry })
        for (key, view) in realized where !keys.contains(key) {
            realized[key] = nil
            // A rename in progress on a row that scrolls out is cancelled (the old name stays), not committed by the view leaving the window.
            if !Self.recycleCommits { (view as? GroupRowView)?.renameField.cancel(recycled: true); (view as? TabRowView)?.renameField.cancel(recycled: true) }
            view.removeFromSuperview()
            switch view {
            case let v as TabRowView: spareTabs.append(v)
            case let v as PinnedTileView: spareTiles.append(v)
            case let v as GroupRowView: spareGroups.append(v)
            default: break
            }
        }
        for i in kept {
            let p = layout.placements[i]
            let fresh = realized[p.entry] == nil
            let view = realized[p.entry] ?? makeView(for: p.entry)
            realized[p.entry] = view
            if fresh || reconfigure { view.isHidden = !configure(view, p) }
            let f = p.frame.offsetBy(dx: 0, dy: Self.lowRows ? 3 - Self.strip : -Self.strip)  // negative control: every row 3 pt low
            if view.frame != f { view.frame = f }
        }
        // A row realized during a drag (a scroll, a folder opened by the hover) is added above the indicator: it goes back on top.
        if dropIndicator != nil, !Self.indicatorLow, indicatorView.superview === document, document.subviews.last !== indicatorView { document.addSubview(indicatorView) }
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
            v.onDragStart = { [weak self, weak v] e in if let v, let id = v.tabID { self?.beginDragging(.tab(id), from: v, event: e) } }
            view = v
        case .group:
            let v = spareGroups.popLast() ?? GroupRowView(frame: .zero)
            v.clearHover()
            v.onClick = { [weak self, weak v] in if let g = v?.groupID { self?.onToggleGroup?(g) } }
            v.onContextMenu = { [weak self, weak v] p in if let g = v?.groupID { self?.onGroupMenu?(g, p) } }
            v.onRename = { [weak self, weak v] text in if let g = v?.groupID { self?.onRenameGroup?(g, text) } }
            v.renameField.returnFocus = { [weak self] free in self?.onReturnFocus?(free) }
            v.onDragStart = { [weak self, weak v] e in if let v, let g = v.groupID { self?.beginDragging(.group(g), from: v, event: e) } }
            view = v
        default:
            let v = spareTabs.popLast() ?? TabRowView(frame: .zero)
            v.clearHover()
            v.onSelect = { [weak self, weak v] in if let id = v?.tabID { self?.onSelect?(id) } }
            v.onClose = { [weak self, weak v] in if let id = v?.tabID { self?.onClose?(id) } }
            v.onContextMenu = { [weak self, weak v] p in if let id = v?.tabID { self?.onTabMenu?(id, p) } }
            v.onReset = { [weak self, weak v] in if let id = v?.tabID { self?.onReset?(id) } }
            v.onRename = { [weak self, weak v] text in if let id = v?.tabID { self?.onRenameTab?(id, text) } }
            v.renameField.returnFocus = { [weak self] free in self?.onReturnFocus?(free) }
            v.onDragStart = { [weak self, weak v] e in if let v, let id = v.tabID { self?.beginDragging(.tab(id), from: v, event: e) } }
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

// MARK: drag and drop (M1.6 Task 5, note 4.1 and 2.1)

extension SidebarView {
    /// The row's drag starts: a snapshot of the row (alpha 0.9, at the row's place so it keeps the grab offset) and the payload keyed by id.
    func beginDragging(_ item: DragItem, from view: NSView, event: NSEvent) {
        guard drag == nil, let data = DragPayload(item, window: windowID).data else { return }
        dragBegan(item)
        let board = NSPasteboardItem()
        board.setData(data, forType: NSPasteboard.PasteboardType(DragPayload.pasteboardType))
        let dragging = NSDraggingItem(pasteboardWriter: board)
        dragging.setDraggingFrame(view.bounds, contents: Self.snapshot(of: view))
        view.beginDraggingSession(with: [dragging], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    private static func snapshot(of view: NSView) -> NSImage {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return NSImage(size: view.bounds.size) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let shown = NSImage(size: view.bounds.size)
        shown.addRepresentation(rep)
        return NSImage(size: view.bounds.size, flipped: false) { r in shown.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.9); return true }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []  // a drop in another app is not a drop
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded(dropped: operation != [])
    }

    /// The layout entry of a dragged tab (a row or a tile) or group.
    private func entry(of item: DragItem) -> SidebarEntry? {
        entries.first {
            switch ($0, item) {
            case (.tab(let a, _), .tab(let b)), (.gridTile(let a), .tab(let b)): a == b
            case (.group(let a), .group(let b)): a == b
            default: false
            }
        }
    }

    /// The drag of |item| started here: its row keeps its view until the drag ends, and the first slot it passes does not tap.
    func dragBegan(_ item: DragItem) {
        dragEnded(dropped: true)
        let entry = entry(of: item)
        // The slot a drop on the row's own place would take is where the drag starts: moving straight to another slot taps once.
        let origin = Self.noOrigin ? nil : entry.flatMap { e in layout.placements.first { $0.entry == e }?.frame }
            .flatMap { DropResolver.resolve(CGPoint(x: $0.midX, y: $0.midY), layout: layout, dragged: item, isCollapsed: isGroupCollapsed).target }
        drag = DragState(item: item, entry: entry, haptic: Self.hapticAlways || hapticOn(), slot: origin)
        realize(reconfigure: false)
    }

    private func payload(_ info: NSDraggingInfo) -> DragPayload? {
        info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(DragPayload.pasteboardType)).flatMap { DragPayload(data: $0) }
    }

    /// The pointer of |info| in layout coordinates (the list's, plus the strip above it).
    private func layoutPoint(_ info: NSDraggingInfo) -> CGPoint {
        let p = document.convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x, y: p.y + Self.strip)
    }

    func dragMoved(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let p = payload(info) else { return [] }
        return dragMoved(p, at: layoutPoint(info)) ? .move : []
    }

    func dragDropped(_ info: NSDraggingInfo) -> Bool {
        guard let p = payload(info) else { return false }
        return dragDropped(p, at: layoutPoint(info))
    }

    /// The dragged item of a payload of this window that is in the list: another window's, or one naming a tab or group that is gone, is nil.
    private func draggedItem(_ payload: DragPayload) -> DragItem? {
        guard let item = Self.anyWindow ? payload.item : payload.item(in: windowID), Self.anyId || isKnown(item) else { return nil }
        return item
    }

    /// The pointer is over the list at |point| (layout coordinates): scrolls near an edge, draws the indicator, taps when the slot
    /// changed, starts the open timer over a closed folder. True when a drop here would be accepted.
    @discardableResult
    func dragMoved(_ payload: DragPayload, at point: CGPoint) -> Bool {
        guard let item = draggedItem(payload) else { show(nil); return false }
        if drag?.item != item { dragBegan(item) }
        let at = autoscrolled(point)
        let r = DropResolver.resolve(at, layout: layout, dragged: item, isCollapsed: isGroupCollapsed)
        show(r.indicator)
        if let t = r.target {
            if let last = drag?.slot, last != t, drag?.haptic == true, !Self.noHaptic { Haptic.tap() }
            drag?.slot = t
        }
        hover(r.openFolder)
        return r.target != nil
    }

    /// The pointer left the list: nothing to drop on until it comes back.
    func dragLeft() {
        show(nil)
        hover(nil)
    }

    /// A drop at |point|: the list change when the slot there takes it. The drag ends after (`dragEnded`).
    @discardableResult
    func dragDropped(_ payload: DragPayload, at point: CGPoint) -> Bool {
        guard let item = draggedItem(payload) else { return false }
        var point = point
        if Self.ownRowMoves, let f = drag?.entry.flatMap({ e in layout.placements.first { $0.entry == e }?.frame }), f.contains(point) { point.y = f.maxY + 20 }  // the hook: a drop on the row's own place lands below it
        guard let t = DropResolver.resolve(point, layout: layout, dragged: item, isCollapsed: isGroupCollapsed).target else { return false }
        return onDrop?(item, t) ?? false
    }

    /// The drag is over (dropped, cancelled with Escape, or let go outside): the indicator and the timer go, folders it opened close again
    /// unless the tab went in (the controller decides).
    func dragEnded(dropped: Bool) {
        show(nil)
        guard let d = drag else { return }
        d.timer?.invalidate()
        drag = nil
        if !dropped, Self.cancelDrops, let t = d.slot { _ = onDrop?(d.item, t) }  // the hook: a cancel drops where the pointer was
        onDragEnd?(d.item, d.opened)
        realize(reconfigure: true)
    }

    /// The point after the list scrolled for a pointer in the 24 pt band at an edge of the visible list.
    private func autoscrolled(_ point: CGPoint) -> CGPoint {
        let clip = scroll.contentView
        let step = AutoScroll.step(y: point.y - Self.strip - clip.bounds.minY, height: clip.bounds.height)
        guard step != 0 else { return point }
        let y = min(max(clip.bounds.minY + step, 0), max(0, document.frame.height - clip.bounds.height))
        let moved = y - clip.bounds.minY
        guard moved != 0 else { return point }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        return CGPoint(x: point.x, y: point.y + moved)  // the content moved under the pointer
    }

    private func show(_ new: DropIndicator?) {
        let new = Self.noIndicator ? nil : new
        guard new != dropIndicator else { return }
        dropIndicator = new
        guard let new else { indicatorView.removeFromSuperview(); return }
        indicatorView.kind = new
        indicatorView.frame = new.frame.offsetBy(dx: 0, dy: -Self.strip)
        document.addSubview(indicatorView)  // above the rows
    }

    /// Hovering the middle of a closed folder opens it after `DropResolver.autoExpandDelay`.
    private func hover(_ g: GroupID?) {
        guard drag?.hover != g else { return }
        drag?.timer?.invalidate()
        drag?.timer = nil
        drag?.hover = g
        guard let g, !Self.noExpand else { return }
        let t = Timer(timeInterval: DropResolver.autoExpandDelay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.openFolder(g) } }
        RunLoop.main.add(t, forMode: .common)
        drag?.timer = t
    }

    private func openFolder(_ g: GroupID) {
        guard drag?.hover == g else { return }
        drag?.timer = nil
        drag?.hover = nil
        drag?.opened.append(g)
        onOpenFolder?(g)
    }
}
