#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Sidebar drag and drop (M1.6 Task 5, notes 2.1 and 5.2). A real `NSDraggingSession` does not run on synthesized events, so these checks
/// drive the sidebar's own destination (`SidebarDocumentView`: pasteboard payload, pointer to layout coordinates, indicator, tap, drop) with a
/// stand-in for `NSDraggingInfo`, and the source side (`dragBegan`, `dragEnded`) the way the session's callbacks do. The real mouse is owner check 25.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let location: NSPoint
    let board: NSPasteboard
    init(location: NSPoint, board: NSPasteboard) { self.location = location; self.board = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

/// 3 tiles, a loose pinned row, a closed and an open pinned folder, and a day list of two tabs, a closed folder and a tab.
struct DragFixture {
    let list: TabList
    let g: [TabID], p0: TabID, c: [TabID], e: [TabID], d: [TabID], k0: TabID
    let C: GroupID, E: GroupID, D: GroupID

    init() {
        let (C, E, D) = (GroupID(), GroupID(), GroupID())
        func tab(_ n: Int, pinned: Bool = false, grid: Bool = false, group: GroupID? = nil) -> TabItem {
            TabItem(id: TabID(), engineID: n, url: "https://s\(n).example/", title: "t\(n)", isLoading: false, isPinned: pinned, inGrid: grid, groupID: group)
        }
        let gs = (0..<3).map { tab($0, pinned: true, grid: true) }
        let p0 = tab(3, pinned: true)
        let cs = (4..<6).map { tab($0, group: C) }
        let es = (6..<9).map { tab($0, group: E) }
        let ds = (9..<12).map { tab($0) }
        let k0 = tab(12, group: D)
        let groups = [TabGroup(id: C, name: "C", colorIndex: 0, icon: nil, isCollapsed: true, isPinned: true),
                      TabGroup(id: E, name: "E", colorIndex: 1, icon: nil, isCollapsed: false, isPinned: true),
                      TabGroup(id: D, name: "D", colorIndex: 2, icon: nil, isCollapsed: true, isPinned: false)]
        list = TabList(items: gs + [p0] + cs + es + ds + [k0], groups: groups, topOrder: [.tab(p0.id), .group(C), .group(E)],
                       dayOrder: [.tab(ds[0].id), .tab(ds[1].id), .group(D), .tab(ds[2].id)], activeID: ds[0].id)!
        (g, self.p0, c, e, d, self.k0) = (gs.map(\.id), p0.id, cs.map(\.id), es.map(\.id), ds.map(\.id), k0.id)
        (self.C, self.E, self.D) = (C, E, D)
    }
}

extension SelfTest {
    private var board: NSPasteboard { NSPasteboard(name: NSPasteboard.Name("dev.noche.selftest.drag")) }

    private func info(_ item: DragItem, _ p: CGPoint, window: UUID?) -> FakeDraggingInfo? {
        guard let c = ctl, let data = DragPayload(item, window: window ?? c.id).data else { return nil }
        let b = board
        b.clearContents()
        b.setData(data, forType: NSPasteboard.PasteboardType(DragPayload.pasteboardType))
        return FakeDraggingInfo(location: c.sidebar.document.convert(NSPoint(x: p.x, y: p.y - SidebarView.strip), to: nil), board: b)
    }

    /// The pointer of a drag of |item| at |p| (layout coordinates): the operation the destination answers.
    @discardableResult
    private func over(_ item: DragItem, _ p: CGPoint, window: UUID? = nil) -> NSDragOperation {
        guard let c = ctl, let i = info(item, p, window: window) else { return [] }
        return c.sidebar.document.draggingUpdated(i)
    }

    private func release(_ item: DragItem, _ p: CGPoint, window: UUID? = nil) -> Bool {
        guard let c = ctl, let i = info(item, p, window: window) else { return false }
        return c.sidebar.document.performDragOperation(i)
    }

    /// A drag of |item| (begun the way the source does) over |points| and, with |drop|, released on the last one; the layout is refreshed after.
    @discardableResult
    private func drag(_ item: DragItem, _ points: [CGPoint], drop: Bool = true) -> Bool {
        guard let c = ctl else { return false }
        c.sidebar.dragBegan(item)
        for p in points { over(item, p) }
        let accepted = drop && points.last.map { release(item, $0) } == true
        c.sidebar.dragEnded(dropped: accepted)
        c.refreshNow()
        return accepted
    }

    private func frame(_ e: SidebarEntry) -> CGRect { ctl?.sidebar.layout.placements.first { $0.entry == e }?.frame ?? CGRect(x: -999, y: -999, width: 0, height: 0) }
    private func at(_ r: CGRect, _ dy: CGFloat) -> CGPoint { CGPoint(x: 100, y: r.minY + dy) }
    private func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func members(_ c: BrowserWindowController, _ g: GroupID) -> [TabID] { c.list.items.filter { $0.groupID == g }.map(\.id) }
    private func grid(_ c: BrowserWindowController) -> [TabID] { c.list.items.filter { $0.isPinned && $0.inGrid }.map(\.id) }

    // MARK: drag-reorder

    /// Notes 2.1 and 5.2: every gesture row through the sidebar's destination, then the list it leaves: a row reordered inside its zone,
    /// a tab joined to a folder at its end (the middle half) and at a child's place, a folder tab dropped out to the loose list, a tab dropped
    /// into the grid and a tile out under the divider, a folder moved with its tabs, the refusals, the indicators (insertion line, folder
    /// outline, 41 x 41 ghost) and a tap for every slot change but the first.
    func dragReorder() async {
        guard await ready(), let c = ctl, let host = c.window.chromeHost else { return }
        guard host.bounds.height >= 700 else { return finish(false, "the window is \(host.bounds.height) pt high, the composition needs 700") }
        let fx = DragFixture()
        let sb = c.sidebar
        func seed() { c.testSeed(fx.list) }
        guard (try? app.writer?.store.setting("hapticReorder")).flatMap({ $0 }) == nil else { return finish(false, "hapticReorder is set: this check runs with the default (on)") }

        line("info", "step: a day tab dragged over the day list: slots change, the line sits between rows, each change after the first taps")
        seed()
        let d0 = frame(.tab(fx.d[0], level: 0)), d1 = frame(.tab(fx.d[1], level: 0))
        let taps0 = Haptic.taps
        sb.dragBegan(.tab(fx.d[2]))
        guard sb.rows.contains(where: { $0.tabID == fx.d[2] }) else { return finish(false, "the dragged row has no view") }
        over(.tab(fx.d[2]), mid(frame(.tab(fx.d[2], level: 0))))
        guard Haptic.taps == taps0 else { return finish(false, "the first slot of a drag tapped (\(Haptic.taps - taps0))") }
        over(.tab(fx.d[2]), at(d0, 4))
        guard case .line(let l)? = sb.dropIndicator, l.height == DropResolver.lineHeight, abs(l.midY - d0.minY) <= 1, l.minX == 6, l.width == d0.width else {
            return finish(false, "over the top quarter of the first day row the indicator is \(String(describing: sb.dropIndicator)), want a 2 pt line at y \(d0.minY) from x 6, \(d0.width) wide")
        }
        guard sb.indicatorView.superview === sb.document, sb.indicatorView.frame == l.offsetBy(dx: 0, dy: -SidebarView.strip) else { return finish(false, "the line is not drawn where the indicator says: \(sb.indicatorView.frame)") }
        over(.tab(fx.d[2]), at(d0, 6))
        over(.tab(fx.d[2]), at(d1, d1.height - 4))
        over(.tab(fx.d[2]), at(d0, 4))
        guard Haptic.taps - taps0 == 3 else { return finish(false, "the slot changed 3 times (own, first, second, first again: own does not tap), taps \(Haptic.taps - taps0)") }
        guard release(.tab(fx.d[2]), at(d0, 4)) else { return finish(false, "the drop on the first day row was refused") }
        sb.dragEnded(dropped: true)
        c.refreshNow()
        guard c.list.dayOrder == [.tab(fx.d[2]), .tab(fx.d[0]), .tab(fx.d[1]), .group(fx.D)] else { return finish(false, "the day list is \(c.list.dayOrder), want the dragged tab first") }
        guard sb.dropIndicator == nil, sb.indicatorView.superview == nil, sb.drag == nil else { return finish(false, "the indicator or the drag state outlived the drop") }

        line("info", "step: the middle of a closed folder joins it at its end and opens it; the outline is the folder's header")
        seed()
        let cHeader = frame(.group(fx.C))
        sb.dragBegan(.tab(fx.d[0]))
        over(.tab(fx.d[0]), mid(cHeader))
        guard sb.dropIndicator == .folder(cHeader), sb.indicatorView.frame == cHeader.offsetBy(dx: 0, dy: -SidebarView.strip) else { return finish(false, "over a closed folder the indicator is \(String(describing: sb.dropIndicator)), want its header outlined \(cHeader)") }
        guard release(.tab(fx.d[0]), mid(cHeader)) else { return finish(false, "the drop on a folder was refused") }
        sb.dragEnded(dropped: true)
        c.refreshNow()
        guard members(c, fx.C) == [fx.c[0], fx.c[1], fx.d[0]], c.list.groups.first(where: { $0.id == fx.C })?.isCollapsed == false, c.item(withID: fx.d[0])?.isPinned == false else {
            return finish(false, "the folder holds \(members(c, fx.C).count), collapsed \(String(describing: c.list.groups.first { $0.id == fx.C }?.isCollapsed)): want c0, c1 and the dropped tab, open")
        }
        guard !c.list.dayOrder.contains(.tab(fx.d[0])) else { return finish(false, "the joined tab is still in the day list") }

        line("info", "step: the middle of an open folder outlines the whole box; a child's top half joins at its place")
        seed()
        let box = sb.layout.boxes.first { $0.group == fx.E }?.frame ?? .zero
        sb.dragBegan(.tab(fx.d[1]))
        over(.tab(fx.d[1]), mid(frame(.group(fx.E))))
        guard sb.dropIndicator == .folder(box), box.height == 40 + 3 * 37 else { return finish(false, "over an open folder the indicator is \(String(describing: sb.dropIndicator)), want its box \(box)") }
        over(.tab(fx.d[1]), at(frame(.tab(fx.e[1], level: 1)), 4))
        guard case .line(let cl)? = sb.dropIndicator, cl.minX == 6 + SidebarMetrics.groupIndent else { return finish(false, "over a child row the indicator is \(String(describing: sb.dropIndicator)), want a line indented like the children") }
        guard release(.tab(fx.d[1]), at(frame(.tab(fx.e[1], level: 1)), 4)) else { return finish(false, "the drop on a child row was refused") }
        sb.dragEnded(dropped: true)
        c.refreshNow()
        guard members(c, fx.E) == [fx.e[0], fx.d[1], fx.e[1], fx.e[2]] else { return finish(false, "the open folder holds \(members(c, fx.E).count) tabs in the order \(members(c, fx.E).map { c.item(withID: $0)?.title ?? "?" }), want t6 t10 t7 t8") }

        line("info", "step: a folder tab dropped on a loose day row leaves its folder")
        seed()
        guard drag(.tab(fx.e[2]), [mid(frame(.tab(fx.e[2], level: 1))), at(frame(.tab(fx.d[0], level: 0)), 33)]) else { return finish(false, "the drop below the first day row was refused") }
        guard c.item(withID: fx.e[2])?.groupID == nil, c.list.dayOrder.prefix(2) == [.tab(fx.d[0]), .tab(fx.e[2])] else {
            return finish(false, "the folder tab is in \(String(describing: c.item(withID: fx.e[2])?.groupID)), day list \(c.list.dayOrder)")
        }

        line("info", "step: a tab dropped into the grid pins as a tile at the nearest slot, the ghost is 41 x 41")
        seed()
        let tile1 = frame(.gridTile(fx.g[1]))
        sb.dragBegan(.tab(fx.d[1]))
        over(.tab(fx.d[1]), mid(tile1))
        let ghost = PinnedGrid.frame(index: 1, width: sb.layout.width).offsetBy(dx: 0, dy: SidebarMetrics.listTop)
        guard sb.dropIndicator == .ghost(ghost), ghost.size == CGSize(width: 41, height: 41), sb.indicatorView.frame == ghost.offsetBy(dx: 0, dy: -SidebarView.strip) else {
            return finish(false, "over the second tile the indicator is \(String(describing: sb.dropIndicator)), want a 41 x 41 ghost at \(ghost)")
        }
        guard release(.tab(fx.d[1]), mid(tile1)) else { return finish(false, "the drop on the grid was refused") }
        sb.dragEnded(dropped: true)
        c.refreshNow()
        guard grid(c) == [fx.g[0], fx.d[1], fx.g[1], fx.g[2]], let pinned = c.item(withID: fx.d[1]), pinned.isPinned, pinned.inGrid, pinned.pinnedURL == pinned.url else {
            return finish(false, "the grid holds \(grid(c).count) tiles, the dropped tab is \(String(describing: c.item(withID: fx.d[1])))")
        }

        line("info", "step: a tile dragged under the divider unpins; a tile dragged into the list is a loose pinned row")
        seed()
        guard drag(.tab(fx.g[0]), [mid(frame(.gridTile(fx.g[0]))), mid(frame(.newTab))]) else { return finish(false, "the drop under the divider was refused") }
        guard let out = c.item(withID: fx.g[0]), !out.isPinned, out.pinnedURL == nil, c.list.dayOrder.first == .tab(fx.g[0]) else { return finish(false, "the tile dragged under the divider is \(String(describing: c.item(withID: fx.g[0]))), want unpinned at the top of the day list") }
        seed()
        guard drag(.tab(fx.g[1]), [at(frame(.tab(fx.p0, level: 0)), 4)]) else { return finish(false, "the drop on the persistent area was refused") }
        guard let loose = c.item(withID: fx.g[1]), loose.isPinned, !loose.inGrid, c.list.topOrder.first == .tab(fx.g[1]) else { return finish(false, "the tile dragged into the list is \(String(describing: c.item(withID: fx.g[1]))), want a loose pinned row at the top") }

        line("info", "step: a folder moves with its tabs between the day list and the persistent area; it is refused in a folder and on the grid")
        seed()
        guard drag(.group(fx.D), [at(frame(.tab(fx.p0, level: 0)), 4)]) else { return finish(false, "the drop of a folder at the top was refused") }
        guard c.list.topOrder == [.group(fx.D), .tab(fx.p0), .group(fx.C), .group(fx.E)], c.list.groups.first(where: { $0.id == fx.D })?.isPinned == true, members(c, fx.D) == [fx.k0] else {
            return finish(false, "after the folder moved the persistent area is \(c.list.topOrder) and the folder holds \(members(c, fx.D).count)")
        }
        seed()
        guard drag(.group(fx.C), [at(frame(.tab(fx.d[0], level: 0)), 4)]) else { return finish(false, "the drop of a pinned folder in the day list was refused") }
        guard c.list.dayOrder.first == .group(fx.C), c.list.groups.first(where: { $0.id == fx.C })?.isPinned == false, members(c, fx.C) == fx.c else { return finish(false, "the pinned folder moved to the day list: \(c.list.dayOrder), pinned \(String(describing: c.list.groups.first { $0.id == fx.C }?.isPinned))") }
        seed()
        let before = c.list
        for (label, p) in [("the middle of a folder", mid(frame(.group(fx.E)))), ("a child of an open folder", mid(frame(.tab(fx.e[1], level: 1)))), ("the grid", mid(frame(.gridTile(fx.g[0]))))] {
            sb.dragBegan(.group(fx.D))
            let op = over(.group(fx.D), p)
            let took = release(.group(fx.D), p)
            sb.dragEnded(dropped: took)
            guard op == [], !took, sb.dropIndicator == nil, c.list == before else { return finish(false, "a folder dropped on \(label) was answered \(op) and \(took): it must snap back and change nothing") }
        }

        line("info", "step: Close on an unpinned row with no engine tab (a dormant tile dragged under the divider) removes it like a closed tab; a pinned dormant tile stays")
        var dormant = fx.list
        for t in fx.g { dormant.setEngineID(t, nil) }
        c.testSeed(dormant)
        c.restoring = false  // the window saves again, so the close below is written to the store (it is the seeded list that is saved, in a profile every check wipes)
        defer { c.restoring = true }
        app.writer?.flush()
        func storedIDs() -> Set<TabID> { Set(((try? app.writer?.store.loadWindows()) ?? []).first { $0.id == c.id }?.tabs.map(\.id) ?? []) }
        for t in [fx.g[0], fx.g[1]] {
            guard drag(.tab(t), [mid(frame(.gridTile(t))), mid(frame(.newTab))]) else { return finish(false, "the drop of a dormant tile under the divider was refused") }
        }
        guard let out0 = c.item(withID: fx.g[0]), let out1 = c.item(withID: fx.g[1]), out0.engineID == nil, out1.engineID == nil, !out0.isPinned, !out1.isPinned,
              let row0 = sb.rows.first(where: { $0.tabID == fx.g[0] }) else { return finish(false, "no unpinned dormant rows under the divider") }
        guard storedIDs().contains(fx.g[0]) else { return finish(false, "the dormant row is not in the store before it is closed") }
        row0.onClose?()  // the row's close button
        guard c.item(withID: fx.g[0]) == nil, !storedIDs().contains(fx.g[0]), app.writer?.peekClosed()?.tab.id == fx.g[0] else {
            return finish(false, "the close button of an unpinned dormant row left it in the list (\(c.item(withID: fx.g[0]) != nil)), in the store (\(storedIDs().contains(fx.g[0]))) or off the reopen list (\(String(describing: app.writer?.peekClosed()?.tab.title)))")
        }
        guard let menu = await tabMenu(c, fx.g[1]), item(menu.menu, "Close")?.isEnabled == true else { return finish(false, "Close is not enabled in the menu of an unpinned dormant row") }
        choose(menu.menu, "Close")
        guard c.item(withID: fx.g[1]) == nil, !storedIDs().contains(fx.g[1]), app.writer?.peekClosed()?.tab.id == fx.g[1], !c.list.dayOrder.contains(.tab(fx.g[1])) else {
            return finish(false, "the menu's Close on an unpinned dormant row left it in the list (\(c.item(withID: fx.g[1]) != nil)), in the store (\(storedIDs().contains(fx.g[1]))) or off the reopen list")
        }
        c.closeRow(c.list.items.firstIndex { $0.id == fx.g[2] }!)
        guard c.item(withID: fx.g[2])?.isPinned == true, storedIDs().contains(fx.g[2]) else { return finish(false, "Close removed a pinned dormant tile") }
        guard let tileClose = c.item(withID: fx.g[2]).flatMap({ c.tabMenuEntries(for: $0) })?.first(where: { $0.title == "Close" }), !tileClose.enabled else { return finish(false, "Close is enabled in the menu of a pinned dormant tile") }
        finish(violations.isEmpty, "every 2.1 gesture through the destination: reorder in the day list with a 2 pt line and 3 taps for 3 slot changes (the first slot silent), the middle of a closed folder joins at its end and opens it (header outlined), an open folder outlined whole, a child row joins at its place (indented line), a folder tab out to the day list, a tab into the grid (41 x 41 ghost, pinned with its address), a tile under the divider unpinned and into the list a loose row, a folder moved both ways with its tabs, and refused on a folder, a child and the grid; Close on an unpinned dormant row (button and menu) removes it and puts it on the reopen list, a pinned dormant tile stays \(violations)")
    }

    // MARK: drag-autoexpand

    /// Note 2.1: hovering a closed folder for 600 ms while dragging opens it; it closes again when the drag is cancelled or dropped
    /// elsewhere, and stays open when the tab joined it; moving off in time opens nothing.
    func dragAutoexpand() async {
        guard await ready(), let c = ctl else { return }
        let fx = DragFixture()
        let sb = c.sidebar
        func seed() { c.testSeed(fx.list) }
        func closed() -> Bool { c.list.groups.first { $0.id == fx.C }?.isCollapsed == true }
        let item = DragItem.tab(fx.d[0])

        line("info", "step: 600 ms over a closed folder opens it")
        seed()
        sb.dragBegan(item)
        over(item, mid(frame(.group(fx.C))))
        try? await Task.sleep(for: .milliseconds(300))
        guard closed() else { return finish(false, "the folder opened after 300 ms") }
        guard await until(3, { !closed() }) else { return finish(false, "the folder stayed closed after hovering its middle for 3 s") }
        guard frame(.tab(fx.c[0], level: 1)).minY > 0, sb.layout.boxes.contains(where: { $0.group == fx.C }) else { return finish(false, "the opened folder shows no children in the layout") }
        guard sb.rows.contains(where: { $0.tabID == fx.d[0] }) else { return finish(false, "the dragged row lost its view when the layout changed") }
        guard sb.dropIndicator != nil, sb.document.subviews.last === sb.indicatorView else {
            return finish(false, "after the folder opened the rows realized for its children are above the drop indicator: the top view is \(String(describing: sb.document.subviews.last)), the indicator \(String(describing: sb.dropIndicator))")
        }

        line("info", "step: cancelling the drag closes it again")
        sb.dragEnded(dropped: false)
        guard closed(), frame(.tab(fx.c[0], level: 1)).minY < 0 else { return finish(false, "after the cancel the folder is closed: \(closed()), its children are \(frame(.tab(fx.c[0], level: 1)))") }

        line("info", "step: dropped elsewhere after it opened: closed again, the tab where it was dropped")
        seed()
        sb.dragBegan(item)
        over(item, mid(frame(.group(fx.C))))
        guard await until(3, { !closed() }) else { return finish(false, "the folder did not open") }
        let d1 = frame(.tab(fx.d[1], level: 0))
        over(item, at(d1, d1.height - 4))
        guard release(item, at(d1, d1.height - 4)) else { return finish(false, "the drop on a day row was refused") }
        sb.dragEnded(dropped: true)
        guard closed(), c.list.dayOrder.prefix(2) == [.tab(fx.d[1]), .tab(fx.d[0])] else { return finish(false, "the folder is closed: \(closed()), the day list \(c.list.dayOrder)") }

        line("info", "step: dropped into the folder it opened: it stays open")
        seed()
        sb.dragBegan(item)
        over(item, mid(frame(.group(fx.C))))
        guard await until(3, { !closed() }) else { return finish(false, "the folder did not open") }
        over(item, mid(frame(.group(fx.C))))
        guard release(item, mid(frame(.group(fx.C)))) else { return finish(false, "the drop on the opened folder was refused") }
        sb.dragEnded(dropped: true)
        guard !closed(), members(c, fx.C).last == fx.d[0] else { return finish(false, "the folder the tab joined is closed: \(closed()), holds \(members(c, fx.C).count)") }

        line("info", "step: moving off before 600 ms opens nothing")
        seed()
        sb.dragBegan(item)
        over(item, mid(frame(.group(fx.C))))
        try? await Task.sleep(for: .milliseconds(300))
        over(item, at(frame(.tab(fx.d[1], level: 0)), 4))
        try? await Task.sleep(for: .milliseconds(700))
        guard closed() else { return finish(false, "the folder opened after the pointer left it") }
        sb.dragEnded(dropped: false)
        finish(violations.isEmpty, "600 ms over a closed folder opens it (the dragged row keeps its view), a cancel and a drop elsewhere close it again, a drop into it keeps it open, leaving in time opens nothing \(violations)")
    }

    // MARK: drag-cancel

    /// Notes 2.1 and T5.1: Escape and a drop outside change nothing and clear the indicator; another window's drag is refused; the dragged row
    /// keeps its view while it scrolls out (and the realized rows stay within 40); a press that moves 3 pt starts a drag and a group's click lands on release.
    func dragCancel() async {
        guard await ready(), let c = ctl, let host = c.window.chromeHost else { return }
        let sb = c.sidebar
        guard await openTabs(3) else { return finish(false, "extra tabs never appeared") }

        line("info", "step: the 3 pt threshold on a real row")
        guard let row = sb.rows.first(where: { $0.tabID == c.list.items[1].id }), let ns = c.nsWindow else { return finish(false, "no row for the second tab") }
        var started = 0
        let original = row.onDragStart, select = row.onSelect
        row.onDragStart = { _ in started += 1 }
        row.onSelect = nil
        let origin = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        func ev(_ t: NSEvent.EventType, _ dx: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: origin.x + dx, y: origin.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = ev(.leftMouseDown, 0) { row.mouseDown(with: e) }
        if let e = ev(.leftMouseDragged, 2.5) { row.mouseDragged(with: e) }
        guard started == 0 else { return finish(false, "a press that moved 2.5 pt started a drag") }
        if let e = ev(.leftMouseDragged, 3.5) { row.mouseDragged(with: e) }
        if let e = ev(.leftMouseDragged, 20) { row.mouseDragged(with: e) }
        if let e = ev(.leftMouseUp, 20) { row.mouseUp(with: e) }
        guard started == 1 else { return finish(false, "a press that moved 3.5 pt, then 20 pt, started \(started) drags, want 1") }
        row.onDragStart = original
        row.onSelect = select

        let fx = DragFixture()
        func seed() { c.testSeed(fx.list) }
        seed()
        guard let groupRow = sb.groupRow(fx.D) else { return finish(false, "no row for the day folder") }
        var clicks = 0
        let groupClick = groupRow.onClick, groupDrag = groupRow.onDragStart
        groupRow.onClick = { clicks += 1 }
        var groupDrags = 0
        groupRow.onDragStart = { _ in groupDrags += 1 }
        let go = groupRow.convert(NSPoint(x: groupRow.bounds.midX, y: groupRow.bounds.midY), to: nil)
        func gev(_ t: NSEvent.EventType, _ dx: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: go.x + dx, y: go.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = gev(.leftMouseDown, 0) { groupRow.mouseDown(with: e) }
        guard clicks == 0 else { return finish(false, "a press on a group row clicked before the release") }
        if let e = gev(.leftMouseDragged, 5) { groupRow.mouseDragged(with: e) }
        if let e = gev(.leftMouseUp, 5) { groupRow.mouseUp(with: e) }
        guard groupDrags == 1, clicks == 0 else { return finish(false, "a press on a group row that moved 5 pt made \(groupDrags) drags and \(clicks) clicks, want 1 and 0") }
        if let e = gev(.leftMouseDown, 0) { groupRow.mouseDown(with: e) }
        if let e = gev(.leftMouseUp, 0) { groupRow.mouseUp(with: e) }
        guard clicks == 1 else { return finish(false, "a click on a group row made \(clicks) clicks, want 1") }
        groupRow.onClick = groupClick
        groupRow.onDragStart = groupDrag

        line("info", "step: Escape and a drop outside change nothing")
        seed()
        let before = c.list
        let item = DragItem.tab(fx.d[2])
        let d0 = frame(.tab(fx.d[0], level: 0))
        sb.dragBegan(item)
        over(item, at(d0, 4))
        guard sb.dropIndicator != nil else { return finish(false, "no indicator over the first day row") }
        sb.dragEnded(dropped: false)  // Escape: the session ends with no operation
        c.refreshNow()
        guard c.list == before, sb.dropIndicator == nil, sb.indicatorView.superview == nil, sb.drag == nil else { return finish(false, "after Escape the list changed: \(c.list != before), the indicator is \(String(describing: sb.dropIndicator))") }
        sb.dragBegan(item)
        over(item, at(d0, 4))
        sb.dragLeft()  // the pointer leaves the list
        guard sb.dropIndicator == nil else { return finish(false, "the indicator stayed after the pointer left the list") }
        sb.dragEnded(dropped: false)  // let go outside: no drop was sent
        c.refreshNow()
        guard c.list == before, sb.drag == nil else { return finish(false, "letting go outside changed the list") }

        line("info", "step: another window's drag is refused")
        sb.dragBegan(item)
        let foreign = UUID()
        let op = over(item, at(d0, 4), window: foreign)
        let took = release(item, at(d0, 4), window: foreign)
        guard op == [], !took, sb.dropIndicator == nil, c.list == before else { return finish(false, "a drag from another window was answered \(op) and \(took), indicator \(String(describing: sb.dropIndicator)): it must be refused") }
        let own = over(item, at(d0, 4))
        guard own == .move else { return finish(false, "the same drag from this window is answered \(own), want move") }
        sb.dragEnded(dropped: false)
        c.refreshNow()
        guard c.list == before else { return finish(false, "the refused drops changed the list") }

        line("info", "step: a payload naming a tab or group that is not in the list is refused")
        for ghost in [DragItem.tab(TabID()), .group(GroupID())] {
            sb.dragBegan(item)
            let gop = over(ghost, at(d0, 4))
            let gtook = release(ghost, at(d0, 4))
            guard gop == [], !gtook, sb.dropIndicator == nil, c.list == before else { return finish(false, "a payload for \(ghost) (same window, not in the list) was answered \(gop) and \(gtook), indicator \(String(describing: sb.dropIndicator)): it must be refused") }
            sb.dragEnded(dropped: false)
        }

        line("info", "step: a scrolled-out dragged row keeps its view and the realized rows stay within 40 (500 tabs)")
        guard host.bounds.height >= 1400 else { return finish(false, "the window is \(host.bounds.height) pt high, the 40 view bound is for 1436") }
        let items = (0..<500).map { TabItem(id: TabID(), engineID: $0, url: "https://site\($0).example/", title: "Tab \($0)", isLoading: false) }
        c.testSeed(TabList(items: items, activeID: items[0].id)!)
        let scroll = sb.scroll
        let dragged = items[250].id
        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, sb.document.frame.height - scroll.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scrollTo(SidebarMetrics.tabPitch * 250 - 300)
        guard sb.rows.contains(where: { $0.tabID == dragged }) else { return finish(false, "row 250 has no view where the list is scrolled to it") }
        sb.dragBegan(.tab(dragged))
        var most = 0, missing: [String] = []
        for (name, y) in [("top", CGFloat(0)), ("row 100", SidebarMetrics.tabPitch * 100), ("the end", .greatestFiniteMagnitude), ("row 250", SidebarMetrics.tabPitch * 250 - 300), ("the end again", .greatestFiniteMagnitude)] {
            scrollTo(y)
            let rowViews = sb.realizedCount - sb.realizedTileCount
            most = max(most, rowViews)
            if rowViews > 40 { missing.append("\(name): \(rowViews) row views") }
            if !sb.rows.contains(where: { $0.tabID == dragged }) { missing.append("\(name): the dragged row has no view") }
        }
        sb.dragEnded(dropped: false)
        guard missing.isEmpty else { return finish(false, "while dragging a row scrolled out: \(missing)") }
        scrollTo(0)
        guard !sb.rows.contains(where: { $0.tabID == dragged }) else { return finish(false, "after the drag the row far from the screen still has a view") }
        finish(violations.isEmpty, "a press moving under 3 pt starts no drag, one moving 3 pt starts one (a group's click lands on release, a drag makes none); Escape and a drop outside leave the list and clear the indicator, another window's drag and a payload for a tab or group that is gone are refused (no indicator, no drop, the same drag from this window answered move); with 500 tabs the dragged row keeps its view through scrolls to the top, the end and back with at most \(most) row views (bound 40), and loses it after the drag \(violations)")
    }

    // MARK: drag-property

    /// The list after a drop, against the one before: nothing created or lost, the item in the container and at the index the resolver named.
    private func landing(_ item: DragItem, _ target: DropTarget, _ before: TabList, _ after: TabList) -> String? {
        guard after.items.count == before.items.count, Set(after.items.map(\.id)) == Set(before.items.map(\.id)), after.groups.count == before.groups.count else {
            return "tabs \(before.items.count) to \(after.items.count), groups \(before.groups.count) to \(after.groups.count)"
        }
        switch item {
        case .tab(let id):
            guard let t = after.items.first(where: { $0.id == id }), let index = after.containerIndex(of: id) else { return "the tab is gone" }
            switch target {
            case .grid(let i):
                let n = after.items.filter { $0.isPinned && $0.inGrid }.count
                return t.isPinned && t.inGrid && t.groupID == nil && index == min(i, n - 1) ? nil : "in the grid: pinned \(t.isPinned), tile \(t.inGrid), index \(index) for \(i)"
            case .persistent(let i):
                return t.isPinned && !t.inGrid && t.groupID == nil && index == min(i, after.topOrder.count - 1) ? nil : "in the persistent area: pinned \(t.isPinned), tile \(t.inGrid), index \(index) for \(i)"
            case .day(let i):
                return !t.isPinned && t.groupID == nil && index == min(i, after.dayOrder.count - 1) ? nil : "in the day list: pinned \(t.isPinned), group \(String(describing: t.groupID)), index \(index) for \(i)"
            case .group(let g, let i):
                let n = after.items.filter { $0.groupID == g }.count
                return t.groupID == g && !t.isPinned && index == min(i, n - 1) ? nil : "in a folder: group \(String(describing: t.groupID)), index \(index) for \(i) of \(n)"
            }
        case .group(let g):
            switch target {
            case .persistent(let i):
                return after.topOrder.firstIndex(of: .group(g)) == min(i, after.topOrder.count - 1) && after.groups.first(where: { $0.id == g })?.isPinned == true ? nil : "the folder is at \(String(describing: after.topOrder.firstIndex(of: .group(g)))) for \(i)"
            case .day(let i):
                return after.dayOrder.firstIndex(of: .group(g)) == min(i, after.dayOrder.count - 1) && after.groups.first(where: { $0.id == g })?.isPinned == false ? nil : "the folder is at \(String(describing: after.dayOrder.firstIndex(of: .group(g)))) for \(i)"
            default: return "a folder was sent to \(target)"
            }
        }
    }

    /// Review Focus 3: the pointer swept over the whole list for every tab and every folder. Wherever a drop is accepted, no tab or group is
    /// created or lost and the item lands in the container and at the index the resolver named; every row of note 2.1 is reached.
    func dragProperty() async {
        guard await ready(), let c = ctl else { return }
        let fx = DragFixture()
        c.testSeed(fx.list)
        let base = fx.list, sb = c.sidebar
        let items: [DragItem] = base.items.map { .tab($0.id) } + base.groups.map { .group($0.id) }
        var seen: [String: Int] = [:], bad: [String] = []
        func tally(_ item: DragItem, _ target: DropTarget?) {
            guard let target else { seen["refused", default: 0] += 1; return }
            switch (item, target) {
            case (.tab(let id), .grid):
                seen[base.items.first { $0.id == id }?.inGrid == true ? "tile reordered in the grid" : "tab pinned into the grid", default: 0] += 1
            case (.tab(let id), .day):
                let t = base.items.first { $0.id == id }!
                seen[t.inGrid ? "tile unpinned under the divider" : t.groupID != nil ? "folder tab out to the day list" : "day row reordered", default: 0] += 1
            case (.tab(let id), .persistent):
                let t = base.items.first { $0.id == id }!
                seen[t.inGrid ? "tile into the list as a loose row" : t.groupID != nil ? "folder tab out to the persistent area" : t.isPinned ? "loose row reordered" : "tab pinned as a loose row", default: 0] += 1
            case (.tab, .group(_, let i)): seen[i == Int.max ? "joined a folder at its end" : "joined a folder at a child's place", default: 0] += 1
            case (.group, _): seen["folder moved as one item", default: 0] += 1
            }
        }
        line("info", "step: the resolver and the drop over the whole list")
        for item in items {
            for y in stride(from: CGFloat(46), to: 600, by: 3) {
                for x in [CGFloat(8), 60, 120, 188] {
                    let r = DropResolver.resolve(CGPoint(x: x, y: y), layout: sb.layout, dragged: item, isCollapsed: { g in base.groups.first { $0.id == g }?.isCollapsed ?? false })
                    tally(item, r.target)
                    guard let target = r.target else { continue }
                    c.list = base
                    guard c.performDrop(item, to: target) else { bad.append("\(item) to \(target) at (\(x), \(y)) was refused by the drop"); continue }
                    if let why = landing(item, target, base, c.list) { bad.append("\(item) to \(target) at (\(x), \(y)): \(why)") }
                    if bad.count >= 5 { break }
                }
                if bad.count >= 5 { break }
            }
            if bad.count >= 5 { break }
        }
        c.testSeed(base)
        guard bad.isEmpty else { return finish(false, "a drop broke the list: \(bad)") }
        let rows = ["tile reordered in the grid", "tab pinned into the grid", "tile unpinned under the divider", "tile into the list as a loose row", "day row reordered", "loose row reordered",
                    "tab pinned as a loose row", "joined a folder at its end", "joined a folder at a child's place", "folder tab out to the day list", "folder tab out to the persistent area", "folder moved as one item", "refused"]
        guard let miss = rows.first(where: { (seen[$0] ?? 0) == 0 }) else {
            line("info", "step: a drop with the pointer on the middle half of the item's own row leaves the list unchanged (no oracle but the list itself)")
            var own = 0
            for p in sb.layout.placements {
                let item: DragItem
                switch p.entry {
                case .tab(let t, _), .gridTile(let t): item = .tab(t)
                case .group(let g): item = .group(g)
                default: continue
                }
                for dy in [-p.frame.height / 4, 0, p.frame.height / 4 - 0.5] {
                    c.testSeed(base)
                    let at = CGPoint(x: p.frame.midX, y: p.frame.midY + dy)
                    sb.dragBegan(item)
                    let op = over(item, at)
                    let took = release(item, at)
                    sb.dragEnded(dropped: took)
                    c.refreshNow()
                    guard c.list == base else { return finish(false, "dropping \(p.entry) on the middle of its own row (\(dy) from the middle, answered \(op) and \(took)) changed the list") }
                    own += 1
                }
            }
            c.testSeed(base)
            line("info", "step: the same through the destination (pasteboard, pointer, indicator, drop), every item at a coarser grid")
            var through = 0
            for item in items {
                for y in stride(from: CGFloat(50.37), to: 560, by: 11.9) {
                    c.testSeed(base)
                    let p = CGPoint(x: 100.3, y: y)
                    let want = DropResolver.resolve(p, layout: sb.layout, dragged: item, isCollapsed: { g in base.groups.first { $0.id == g }?.isCollapsed ?? false }).target
                    sb.dragBegan(item)
                    let op = over(item, p)
                    let took = release(item, p)
                    sb.dragEnded(dropped: took)
                    if (want != nil) != (op == .move) || took != (want != nil) { bad.append("\(item) at y \(y): resolver \(String(describing: want)), destination answered \(op) and \(took)"); break }
                    if let want { if let why = landing(item, want, base, c.list) { bad.append("\(item) at y \(y) to \(want): \(why)"); break }; through += 1 }
                }
                if !bad.isEmpty { break }
            }
            guard bad.isEmpty else { return finish(false, "through the destination: \(bad)") }
            return finish(through > 100 && violations.isEmpty, "the tab and group counts are unchanged and the item lands where the resolver said for \(seen.values.reduce(0, +)) pointer positions over \(items.count) items (every 2.1 row reached: \(seen.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })), and \(through) more through the destination; \(own) drops on the middle of the item's own row left the list unchanged \(violations)")
        }
        finish(false, "the sweep never reached the row \"\(miss)\" (\(seen))")
    }

    // MARK: drag-relaunch

    private func label(_ url: String) -> String { url.firstIndex(of: "?").map { String(url[url.index(after: $0)...]) } ?? "a" }

    /// The list's shape as one string: the grid tiles, the persistent area and the day list (a pinned item ends in ^, a group shows ^ when pinned, - when
    /// closed and + when open, then its tabs).
    private func shape(_ items: [TabItem], _ groups: [TabGroup], _ top: [TopRef], _ day: [TopRef]) -> String {
        func name(_ t: TabItem) -> String { label(t.url) + (t.isPinned ? "^" : "") }
        func ref(_ r: TopRef) -> String {
            switch r {
            case .tab(let id): return items.first { $0.id == id }.map(name) ?? "?"
            case .group(let g):
                let grp = groups.first { $0.id == g }
                return "G" + (grp?.isPinned == true ? "^" : "") + (grp?.isCollapsed == true ? "-" : "+") + "[" + items.filter { $0.groupID == g }.map(name).joined(separator: " ") + "]"
            }
        }
        return "grid=[\(items.filter { $0.isPinned && $0.inGrid }.map(name).joined(separator: " "))] top=[\(top.map(ref).joined(separator: " "))] day=[\(day.map(ref).joined(separator: " "))]"
    }

    private func listShape(_ c: BrowserWindowController) -> String { shape(c.list.items, c.list.groups, c.list.topOrder, c.list.dayOrder) }

    /// The shape of what the store holds for the window now, with no flush: what the debounced save wrote.
    private func storedShape(_ c: BrowserWindowController) -> String? {
        ((try? app.writer?.store.loadWindows()) ?? []).first { $0.id == c.id }.map { shape($0.tabs, $0.groups, $0.topOrder, $0.dayOrder) }
    }

    private func storedOpen(_ c: BrowserWindowController, _ g: GroupID) -> Bool? {
        ((try? app.writer?.store.loadWindows()) ?? []).first { $0.id == c.id }?.groups.first { $0.id == g }.map { !$0.isCollapsed }
    }

    /// Review Important 2 and Minor 1: a drop is saved. A real window (not `testSeed`, which stops saving) with a tile, loose tabs and a folder takes one
    /// `performDrop` each of a reorder, a join, a pin into the grid, a tile unpinned under the divider and a folder moved to the persistent area; after each
    /// one the store (read with no flush, so only the debounced save counts) holds the list, then a folder opened by the hover and closed by a drop elsewhere,
    /// and one closed by a cancel after another change saved it open. Phase 2, after the relaunch: the same shape in the list and in the store.
    func dragRelaunch() async {
        let want = "grid=[b^] top=[G^-[d e c]] day=[a f]"
        if phase == 2 {
            guard await until(30, { self.restoredUp(1) }), let c = ctl else { return finish(false, "phase 2: no restored window") }
            guard await until(20, { c.list.items.count == 6 }) else { return finish(false, "phase 2: \(c.list.items.count) tabs, want 6") }
            guard await until(20, { self.listShape(c) == want }) else { return finish(false, "phase 2: the restored list is \(listShape(c)), want \(want)") }  // the pages report their own addresses as they load
            guard storedShape(c) == want else { return finish(false, "phase 2: the store holds \(String(describing: storedShape(c))), want \(want)") }
            return finish(violations.isEmpty, "phase 2: \(want) survived the relaunch, in the list and in the store \(violations)")
        }
        guard await ready(), let c = ctl, let win else { return }
        let sb = c.sidebar
        for n in ["b", "c", "d", "e", "f"] { _ = win.addTab(withURL: fixture("b.html?\(n)"), activate: false) }
        guard await until(20, { c.list.items.count == 6 && c.list.items.allSatisfy { !$0.isLoading && !$0.title.isEmpty } }) else { return finish(false, "phase 1: the tabs never loaded: \(c.list.items.map { "\($0.url) \($0.isLoading)" })") }
        func id(_ l: String) -> TabID { c.list.items.first { label($0.url) == l }!.id }
        let (a, b, cc, d, e, f) = (id("a"), id("b"), id("c"), id("d"), id("e"), id("f"))
        c.togglePin(of: a)
        c.newGroupWithTab(d)
        guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id, c.sidebar.groupRow(g).map({ $0.renameField.cancel(); return true }) == true else { return finish(false, "phase 1: no group") }
        c.moveToGroup(e, g)
        let start = "grid=[a^] top=[] day=[b c G+[d e] f]"
        guard listShape(c) == start else { return finish(false, "phase 1: the starting list is \(listShape(c)), want \(start)") }
        try? await Task.sleep(for: .seconds(1))  // the setup's own saves and the pages' last updates are over: only a drop can change the store now
        guard await until(5, { self.storedShape(c) == start }) else { return finish(false, "phase 1: the store holds \(String(describing: storedShape(c))) for the starting list \(start)") }
        let ops: [(String, DragItem, DropTarget, String)] = [
            ("a reorder (f to the top of the day list)", .tab(f), .day(0), "grid=[a^] top=[] day=[f b c G+[d e]]"),
            ("a join (c to the end of the folder)", .tab(cc), .group(g, Int.max), "grid=[a^] top=[] day=[f b G+[d e c]]"),
            ("a pin into the grid (b at slot 1)", .tab(b), .grid(1), "grid=[a^ b^] top=[] day=[f G+[d e c]]"),
            ("a tile unpinned under the divider (a at day 1)", .tab(a), .day(1), "grid=[b^] top=[] day=[f a G+[d e c]]"),
            ("a folder moved to the persistent area", .group(g), .persistent(0), "grid=[b^] top=[G^+[d e c]] day=[f a]")]
        for (name, item, target, shapeWanted) in ops {
            line("info", "step: \(name)")
            guard c.performDrop(item, to: target) else { return finish(false, "phase 1: \(name) was refused") }
            guard listShape(c) == shapeWanted else { return finish(false, "phase 1: after \(name) the list is \(listShape(c)), want \(shapeWanted)") }
            guard await until(5, { self.storedShape(c) == shapeWanted }) else { return finish(false, "phase 1: after \(name) the store holds \(String(describing: storedShape(c))) 5 s later, want \(shapeWanted)") }
        }
        c.toggleGroup(g)
        let closedShape = "grid=[b^] top=[G^-[d e c]] day=[f a]"
        guard await until(5, { self.storedShape(c) == closedShape }) else { return finish(false, "phase 1: the closed folder is stored as \(String(describing: storedShape(c))), want \(closedShape)") }
        func frame(_ e: SidebarEntry) -> CGRect { sb.layout.placements.first { $0.entry == e }?.frame ?? CGRect(x: -999, y: -999, width: 0, height: 0) }
        func isOpen() -> Bool { c.list.groups.first { $0.id == g }?.isCollapsed == false }

        line("info", "step: a folder opened by the hover and a drop elsewhere: closed in the list and the store")
        sb.dragBegan(.tab(a))
        over(.tab(a), CGPoint(x: 100, y: frame(.group(g)).midY))
        guard await until(3, { isOpen() }) else { return finish(false, "phase 1: the folder did not open under the hover") }
        let dropAt = CGPoint(x: 100, y: frame(.tab(f, level: 0)).minY + 4)
        over(.tab(a), dropAt)
        guard release(.tab(a), dropAt) else { return finish(false, "phase 1: the drop on the first day row was refused") }
        sb.dragEnded(dropped: true)
        c.refreshNow()
        let afterDrop = "grid=[b^] top=[G^-[d e c]] day=[a f]"
        guard listShape(c) == afterDrop, await until(5, { self.storedShape(c) == afterDrop }) else { return finish(false, "phase 1: after the hover and the drop elsewhere the list is \(listShape(c)) and the store \(String(describing: storedShape(c))), want \(afterDrop)") }

        line("info", "step: a folder opened by the hover, saved open by another change, then closed by a cancel: the close is saved")
        sb.dragBegan(.tab(f))
        over(.tab(f), CGPoint(x: 100, y: frame(.group(g)).midY))
        guard await until(3, { isOpen() }) else { return finish(false, "phase 1: the folder did not open under the second hover") }
        c.changed()  // a title update, a favicon: something saves the window while the folder is open
        guard await until(5, { self.storedOpen(c, g) == true }) else { return finish(false, "phase 1: the store never saw the folder open") }
        sb.dragEnded(dropped: false)
        c.refreshNow()
        guard !isOpen(), await until(5, { self.storedOpen(c, g) == false }) else { return finish(false, "phase 1: after the cancel the folder is open in the list \(isOpen()) and in the store \(String(describing: storedOpen(c, g))), want closed in both") }
        guard listShape(c) == want, await until(5, { self.storedShape(c) == want }) else { return finish(false, "phase 1: the final list is \(listShape(c)) and the store \(String(describing: storedShape(c))), want \(want)") }
        finish(violations.isEmpty, "phase 1: a reorder, a join, a pin into the grid, a tile unpinned, a folder moved, a folder opened by the hover and closed by a drop elsewhere, and one closed by a cancel are each in the store by the debounced save, quitting at once \(violations)")
    }

    // MARK: drag-haptic

    /// Setting `hapticReorder` (the script passes 0): a drag that changes slots taps nothing; with the setting on again the same drag taps once per change.
    func dragHaptic() async {
        guard await ready(), let c = ctl, let store = app.writer?.store else { return }
        guard (try? store.setting("hapticReorder")) == "0" else { return finish(false, "hapticReorder is \(String(describing: try? store.setting("hapticReorder"))): the script passes --selftest-setting hapticReorder=0") }
        let fx = DragFixture()
        c.testSeed(fx.list)
        let item = DragItem.tab(fx.d[2])
        let d0 = frame(.tab(fx.d[0], level: 0)), d1 = frame(.tab(fx.d[1], level: 0))
        func run() -> Int {
            let t0 = Haptic.taps
            c.sidebar.dragBegan(item)
            over(item, mid(frame(.tab(fx.d[2], level: 0))))
            over(item, at(d0, 4))
            over(item, at(d1, d1.height - 4))
            over(item, at(d0, 4))
            c.sidebar.dragEnded(dropped: false)
            return Haptic.taps - t0
        }
        let off = run()
        guard off == 0 else { return finish(false, "with hapticReorder=0 a drag with 3 slot changes tapped \(off) times, want none") }
        guard SettingKeys.hapticReorder(stored: "0") == false, SettingKeys.hapticReorder(stored: nil) else { return finish(false, "the setting's reader is wrong") }
        do { try store.setSetting("hapticReorder", "1") } catch { return finish(false, "could not store hapticReorder=1: \(error)") }
        let on = run()
        guard on == 3 else { return finish(false, "with hapticReorder=1 the same drag tapped \(on) times, want 3 (a tap for each slot change, none for the first)") }
        let direct = Haptic.taps
        c.sidebar.dragBegan(item)
        over(item, at(d0, 4))  // the first move goes straight to another slot: one tap, for the slot changed from the row's own
        let straight = Haptic.taps - direct
        c.sidebar.dragEnded(dropped: false)
        guard straight == 1 else { return finish(false, "a drag whose first move went straight to another slot tapped \(straight) times, want 1 (the origin is the row's own slot)") }
        finish(violations.isEmpty, "hapticReorder=0 (--selftest-setting): a drag with 3 slot changes taps 0 times; after the setting is stored as 1 the same drag taps 3 times, read again when each drag starts, and a first move straight to another slot taps once \(violations)")
    }
}
#endif
