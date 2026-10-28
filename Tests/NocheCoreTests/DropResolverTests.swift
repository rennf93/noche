import XCTest
@testable import NocheCore

/// Note 2.1, row by row, on the layout of a list with every kind of container: 3 tiles, a loose pinned row, a collapsed and an open
/// pinned folder, and in the day list two tabs, a collapsed folder and a tab.
final class DropResolverTests: XCTestCase {
    private struct Fixture {
        var list: TabList
        let g: [TabID], p0: TabID, c: [TabID], e: [TabID], d: [TabID], k0: TabID
        let C: GroupID, E: GroupID, D: GroupID
        var layout: SidebarLayout { SidebarLayout(entries: list.layout(), width: 197) }

        init() {
            func tab(_ n: Int, pinned: Bool = false, grid: Bool = false, group: GroupID? = nil) -> TabItem {
                TabItem(id: TabID(), engineID: n, url: "https://s\(n).example/", title: "t\(n)", isLoading: false, isPinned: pinned, inGrid: grid, groupID: group)
            }
            let (C, E, D) = (GroupID(), GroupID(), GroupID())
            let gs = (0..<3).map { tab($0, pinned: true, grid: true) }
            let p0 = tab(3, pinned: true)
            let cs = (4..<6).map { tab($0, group: C) }
            let es = (6..<9).map { tab($0, group: E) }
            let ds = [tab(9), tab(10), tab(11)]
            let k0 = tab(12, group: D)
            let groups = [TabGroup(id: C, name: "C", colorIndex: 0, icon: nil, isCollapsed: true, isPinned: true),
                          TabGroup(id: E, name: "E", colorIndex: 1, icon: nil, isCollapsed: false, isPinned: true),
                          TabGroup(id: D, name: "D", colorIndex: 2, icon: nil, isCollapsed: true, isPinned: false)]
            list = TabList(items: gs + [p0] + cs + es + ds + [k0], groups: groups, topOrder: [.tab(p0.id), .group(C), .group(E)],
                           dayOrder: [.tab(ds[0].id), .tab(ds[1].id), .group(D), .tab(ds[2].id)], activeID: ds[0].id)!
            (g, self.p0, c, e, d, self.k0) = (gs.map(\.id), p0.id, cs.map(\.id), es.map(\.id), [ds[0].id, ds[1].id, ds[2].id], k0.id)
            self.C = C; self.E = E; self.D = D
        }

        func frame(_ entry: SidebarEntry) -> CGRect { layout.placements.first { $0.entry == entry }!.frame }
        func tab(_ id: TabID, level: Int = 0) -> CGRect { frame(.tab(id, level: level)) }
        func resolve(_ y: CGFloat, x: CGFloat = 100, _ item: DragItem) -> DropResolution {
            DropResolver.resolve(CGPoint(x: x, y: y), layout: layout, dragged: item, isCollapsed: { g in list.groups.first { $0.id == g }?.isCollapsed ?? false })
        }
    }

    func testGridSlotIsTheNearestFreeIndexWithA41PointGhost() {
        let f = Fixture()
        let tile1 = f.frame(.gridTile(f.g[1]))
        var r = f.resolve(tile1.midY, x: tile1.midX, .tab(f.d[0]))
        XCTAssertEqual(r.target, .grid(1))
        XCTAssertEqual(r.indicator, .ghost(PinnedGrid.frame(index: 1, width: 197).offsetBy(dx: 0, dy: 54)))
        XCTAssertEqual(r.indicator?.frame.size, CGSize(width: 41, height: 41))
        // A tile dragged inside the grid: the slot counts the other tiles only, so the last slot is 2, not 3.
        r = f.resolve(tile1.midY, x: 190, .tab(f.g[0]))
        XCTAssertEqual(r.target, .grid(2))
        // The gap under the last row still belongs to the grid.
        XCTAssertEqual(f.resolve(f.frame(.gridTile(f.g[0])).maxY + 2, x: 6, .tab(f.d[0])).target, .grid(0))
    }

    func testGridRefusesAGroup() {
        let f = Fixture()
        XCTAssertNil(f.resolve(70, .group(f.D)).target)
        XCTAssertNil(f.resolve(70, .group(f.D)).indicator)
    }

    func testRowsTakeTheirHalvesAndFoldersTheirQuarters() {
        let f = Fixture()
        let p = f.tab(f.p0), c = f.frame(.group(f.C))
        XCTAssertEqual(f.resolve(p.minY + 5, .tab(f.d[0])).target, .persistent(0))
        XCTAssertEqual(f.resolve(p.maxY - 5, .tab(f.d[0])).target, .persistent(1))
        XCTAssertEqual(f.resolve(c.minY + 4, .tab(f.d[0])).target, .persistent(1))  // top quarter: before the folder
        XCTAssertEqual(f.resolve(c.maxY - 4, .tab(f.d[0])).target, .persistent(2))  // bottom quarter of a closed folder: after it
        // The line sits between the rows: in the gap above the folder, at the middle of the 3 pt.
        guard case .line(let l)? = f.resolve(c.minY + 4, .tab(f.d[0])).indicator else { return XCTFail("no line") }
        XCTAssertEqual(l.midY, (p.maxY + c.minY) / 2)
        XCTAssertEqual(l.height, DropResolver.lineHeight)
        XCTAssertEqual(l.minX, 6)
        XCTAssertEqual(l.width, 185)
    }

    func testMiddleHalfJoinsTheFolderAtItsEndAndAClosedOneOpensAfterAHover() {
        let f = Fixture()
        let c = f.frame(.group(f.C))
        let r = f.resolve(c.midY, .tab(f.d[0]))
        XCTAssertEqual(r.target, .group(f.C, Int.max))
        XCTAssertEqual(r.indicator, .folder(c))
        XCTAssertEqual(r.openFolder, f.C)
        XCTAssertEqual(DropResolver.autoExpandDelay, 0.6)
        // An open folder is outlined whole and has nothing to open.
        let e = f.frame(.group(f.E)), box = e.union(f.tab(f.e[2], level: 1))
        let o = f.resolve(e.midY, .tab(f.d[0]))
        XCTAssertEqual(o.target, .group(f.E, Int.max))
        XCTAssertEqual(o.indicator, .folder(box))
        XCTAssertNil(o.openFolder)
    }

    func testAChildRowJoinsAtThatPositionAndTheHeaderBottomOfAnOpenFolderJoinsFirst() {
        let f = Fixture()
        let e = f.frame(.group(f.E)), e1 = f.tab(f.e[1], level: 1)
        XCTAssertEqual(f.resolve(e1.minY + 4, .tab(f.d[0])).target, .group(f.E, 1))
        XCTAssertEqual(f.resolve(e1.maxY - 4, .tab(f.d[0])).target, .group(f.E, 2))
        XCTAssertEqual(f.resolve(f.tab(f.e[2], level: 1).maxY - 2, .tab(f.d[0])).target, .group(f.E, 3))
        XCTAssertEqual(f.resolve(e.maxY - 2, .tab(f.d[0])).target, .group(f.E, 0))
        guard case .line(let l)? = f.resolve(e1.minY + 4, .tab(f.d[0])).indicator else { return XCTFail("no line") }
        XCTAssertEqual(l.minX, 6 + 14)  // indented like the children
        XCTAssertEqual(l.midY, e1.minY)
        // A child dragged inside its folder: indexes count the other children.
        XCTAssertEqual(f.resolve(f.tab(f.e[2], level: 1).minY + 4, .tab(f.e[1])).target, .group(f.E, 1))
        XCTAssertEqual(f.resolve(f.tab(f.e[0], level: 1).minY + 4, .tab(f.e[1])).target, .group(f.E, 0))
    }

    func testAFolderTabDroppedOnLooseRowsLeavesItsFolder() {
        var f = Fixture()
        let r = f.resolve(f.tab(f.d[1]).maxY - 4, .tab(f.e[1]))
        XCTAssertEqual(r.target, .day(2))
        f.list.move(f.e[1], to: r.target!)
        XCTAssertNil(f.list.items.first { $0.id == f.e[1] }?.groupID)
        XCTAssertEqual(f.list.dayOrder.prefix(3), [.tab(f.d[0]), .tab(f.d[1]), .tab(f.e[1])])
        // Beyond the last child of the last open folder of a container (below its box) is out of the folder too.
        let g = Fixture()
        XCTAssertEqual(g.resolve(g.tab(g.e[2], level: 1).maxY + 1, .tab(g.d[0])).target, .persistent(3))
    }

    func testAPinnedTileUnderTheDividerUnpinsAndInTheListPinsALooseRow() {
        var f = Fixture()
        let newTab = f.frame(.newTab)
        let r = f.resolve(newTab.midY, .tab(f.g[0]))
        XCTAssertEqual(r.target, .day(0))
        f.list.move(f.g[0], to: r.target!)
        let t = f.list.items.first { $0.id == f.g[0] }!
        XCTAssertFalse(t.isPinned)
        XCTAssertNil(t.pinnedURL)
        var h = Fixture()
        let loose = h.resolve(h.tab(h.p0).minY + 4, .tab(h.g[0]))
        XCTAssertEqual(loose.target, .persistent(0))
        h.list.move(h.g[0], to: loose.target!)
        let u = h.list.items.first { $0.id == h.g[0] }!
        XCTAssertTrue(u.isPinned && !u.inGrid)
    }

    func testAFolderMovesAsOneItemAndNeverIntoAFolderOrTheGrid() {
        var f = Fixture()
        let r = f.resolve(f.tab(f.p0).minY + 4, .group(f.D))
        XCTAssertEqual(r.target, .persistent(0))
        XCTAssertTrue(f.list.moveGroup(f.D, to: r.target!))
        XCTAssertTrue(f.list.groups.first { $0.id == f.D }!.isPinned)
        XCTAssertEqual(f.list.items.filter { $0.groupID == f.D }.map(\.id), [f.k0])
        // A folder over a folder's middle, over an open folder's children or over the grid is refused.
        let g = Fixture()
        XCTAssertNil(g.resolve(g.frame(.group(g.E)).midY, .group(g.D)).target)
        XCTAssertNil(g.resolve(g.tab(g.e[1], level: 1).midY, .group(g.D)).target)
        XCTAssertNil(g.resolve(g.frame(.group(g.C)).midY, .group(g.D)).target)
        XCTAssertNil(g.resolve(g.frame(.gridTile(g.g[0])).midY, .group(g.D)).target)
        // Its quarters reorder around a folder (a closed one: both; an open one: the bottom quarter is the box's).
        XCTAssertEqual(g.resolve(g.frame(.group(g.C)).minY + 3, .group(g.D)).target, .persistent(1))
        XCTAssertEqual(g.resolve(g.tab(g.e[2], level: 1).maxY - 3, .group(g.D)).target, .persistent(3))
        XCTAssertEqual(g.resolve(g.frame(.group(g.D)).minY - 1, .group(g.C)).target, .day(2))
    }

    func testTheDraggedRowIsSkippedSoDroppingWhereItIsChangesNothing() {
        let ids = Fixture()
        for pick in [ids.d[1], ids.p0] {
            var f = ids
            let id = pick
            let before = f.list
            let r = f.resolve(f.tab(id).midY, .tab(id))
            XCTAssertNotNil(r.target)
            f.list.move(id, to: r.target!)
            XCTAssertEqual(f.list.items, before.items, "\(id)")
            XCTAssertEqual(f.list.topOrder, before.topOrder)
            XCTAssertEqual(f.list.dayOrder, before.dayOrder)
        }
    }

    /// A list of one open folder with |n| children (pinned: in the persistent area between two loose pinned rows; else in the day list
    /// between two day tabs), for the drops of a child on its own row.
    private func folderList(pinned: Bool, kids n: Int) -> (list: TabList, group: GroupID, kids: [TabID]) {
        func tab(_ k: Int, pinned: Bool = false, group: GroupID? = nil) -> TabItem {
            TabItem(id: TabID(), engineID: k, url: "https://f\(k).example/", title: "f\(k)", isLoading: false, isPinned: pinned, groupID: group)
        }
        let g = GroupID()
        let kids = (0..<n).map { tab(10 + $0, group: g) }
        let (a, b) = (tab(1, pinned: pinned), tab(2, pinned: pinned)), (x, y) = (tab(3), tab(4))
        let group = TabGroup(id: g, name: "F", colorIndex: 0, icon: nil, isCollapsed: false, isPinned: pinned)
        let list = pinned
            ? TabList(items: [a, b] + kids + [x, y], groups: [group], topOrder: [.tab(a.id), .group(g), .tab(b.id)], dayOrder: [.tab(x.id), .tab(y.id)], activeID: x.id)!
            : TabList(items: [a, b] + kids + [x, y], groups: [group], topOrder: [.tab(a.id), .tab(b.id)], dayOrder: [.tab(x.id), .group(g), .tab(y.id)], activeID: x.id)!
        return (list, g, kids.map(\.id))
    }

    /// Review Important 1: a child dropped on its own row stays where it is (the first, a middle, the last and the only child, in a
    /// persistent and a day folder, with the pointer at the row's middle and 4 pt either side), with the line inside the folder's box.
    func testAChildDroppedOnItsOwnRowStaysInItsFolder() {
        for pinned in [true, false] {
            for n in [1, 2, 3, 4] {
                for c in 0..<n {
                    let (list, g, kids) = folderList(pinned: pinned, kids: n)
                    let layout = SidebarLayout(entries: list.layout(), width: 197)
                    func frame(_ e: SidebarEntry) -> CGRect { layout.placements.first { $0.entry == e }!.frame }
                    let row = frame(.tab(kids[c], level: 1)), box = frame(.group(g)).union(frame(.tab(kids[n - 1], level: 1)))
                    for dy in [CGFloat(-4), 0, 4] {
                        let at = "pinned \(pinned), \(n) kids, child \(c), dy \(dy)"
                        let r = DropResolver.resolve(CGPoint(x: 100, y: row.midY + dy), layout: layout, dragged: .tab(kids[c]), isCollapsed: { _ in false })
                        XCTAssertEqual(r.target, .group(g, c), at)
                        guard case .line(let l)? = r.indicator else { XCTFail("no line, \(at)"); continue }
                        // The line sits at the row's top edge above the middle, at its bottom edge from the middle on, indented like the children.
                        XCTAssertEqual(l.midY, dy < 0 ? row.minY : row.maxY, at)
                        XCTAssertTrue(l.midY >= box.minY && l.midY <= box.maxY, at)
                        XCTAssertEqual(l.minX, 6 + 14, at)
                        var moved = list
                        moved.move(kids[c], to: r.target!)
                        XCTAssertEqual(moved.items, list.items, at)
                        XCTAssertEqual(moved.topOrder, list.topOrder, at)
                        XCTAssertEqual(moved.dayOrder, list.dayOrder, at)
                    }
                }
            }
        }
    }

    /// Review Minor 2, an oracle that does not read the resolver's answer: with the pointer on the middle half of its own row (a tile: on
    /// its own slot) an item is dropped where it is, whatever it is.
    func testDroppingAnItemOnTheMiddleOfItsOwnRowChangesNothing() {
        let base = Fixture()
        var checked = 0
        for p in base.layout.placements {
            let item: DragItem
            switch p.entry {
            case .tab(let t, _), .gridTile(let t): item = .tab(t)
            case .group(let g): item = .group(g)
            default: continue
            }
            for dy in [-p.frame.height / 4, 0, p.frame.height / 4 - 0.5] {
                var f = base
                let r = f.resolve(p.frame.midY + dy, x: p.frame.midX, item)
                guard let target = r.target else { XCTFail("refused on its own row: \(p.entry)"); continue }
                switch item {
                case .tab(let t): f.list.move(t, to: target)
                case .group(let g): XCTAssertTrue(f.list.moveGroup(g, to: target))
                }
                XCTAssertEqual(f.list.items, base.list.items, "\(p.entry) dy \(dy)")
                XCTAssertEqual(f.list.topOrder, base.list.topOrder, "\(p.entry) dy \(dy)")
                XCTAssertEqual(f.list.dayOrder, base.list.dayOrder, "\(p.entry) dy \(dy)")
                XCTAssertEqual(f.list.groups, base.list.groups, "\(p.entry) dy \(dy)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 30)
    }

    /// Review Minor 2, literal expected values for the rows that had none.
    func testLiteralLinesAndTargetsForTheRemainingRows() {
        let f = Fixture()
        // A group over a day-list folder's quarters: D is a closed folder at y 440..., its top quarter is before, its bottom quarter after.
        let d = f.frame(.group(f.D))
        XCTAssertEqual(f.resolve(d.minY + 3, .group(f.C)).target, .day(2))
        XCTAssertEqual(f.resolve(d.maxY - 3, .group(f.C)).target, .day(3))
        XCTAssertNil(f.resolve(d.midY, .group(f.C)).target)
        // The line of the last unit: it sits under it, at its box's bottom, and the line of an empty container at its top.
        let last = f.tab(f.d[2])
        guard case .line(let after)? = f.resolve(last.maxY - 2, .tab(f.g[0])).indicator else { return XCTFail("no line after the last unit") }
        XCTAssertEqual(f.resolve(last.maxY - 2, .tab(f.g[0])).target, .day(4))
        XCTAssertEqual(after, CGRect(x: 6, y: last.maxY - 1, width: 185, height: 2))
        let one = TabItem(id: TabID(), engineID: 1, url: "https://a.example/", title: "a", isLoading: false)
        let list = TabList(items: [one], activeID: one.id)!
        let layout = SidebarLayout(entries: list.layout(), width: 197)
        let newTab = layout.placements.first { $0.entry == .newTab }!.frame, div = layout.placements.first { $0.entry == .divider }!.frame
        let below = DropResolver.resolve(CGPoint(x: 100, y: 400), layout: layout, dragged: .tab(one.id), isCollapsed: { _ in false })
        XCTAssertEqual(below.indicator, .line(CGRect(x: 6, y: newTab.maxY - 1, width: 185, height: 2)))
        let above = DropResolver.resolve(CGPoint(x: 100, y: div.minY - 3), layout: layout, dragged: .tab(one.id), isCollapsed: { _ in false })
        XCTAssertEqual(above.indicator, .line(CGRect(x: 6, y: SidebarMetrics.listTop - 1, width: 185, height: 2)))
    }

    /// A tile dropped between loose rows under a folder: the gap under an open folder's box and the gap between two loose rows below it.
    func testATileDroppedBetweenLooseRowsUnderAFolder() {
        func tab(_ k: Int, pinned: Bool = false, grid: Bool = false, group: GroupID? = nil) -> TabItem {
            TabItem(id: TabID(), engineID: k, url: "https://u\(k).example/", title: "u\(k)", isLoading: false, isPinned: pinned, inGrid: grid, groupID: group)
        }
        let g = GroupID()
        let (tile, a, b, c, x) = (tab(0, pinned: true, grid: true), tab(1, pinned: true), tab(2, pinned: true), tab(3, pinned: true), tab(4))
        let kids = [tab(5, group: g), tab(6, group: g)]
        let group = TabGroup(id: g, name: "F", colorIndex: 0, icon: nil, isCollapsed: false, isPinned: true)
        let list = TabList(items: [tile, a, b, c, x] + kids, groups: [group], topOrder: [.tab(a.id), .group(g), .tab(b.id), .tab(c.id)], dayOrder: [.tab(x.id)], activeID: x.id)!
        let layout = SidebarLayout(entries: list.layout(), width: 197)
        func frame(_ e: SidebarEntry) -> CGRect { layout.placements.first { $0.entry == e }!.frame }
        let box = frame(.group(g)).union(frame(.tab(kids[1].id, level: 1))), bRow = frame(.tab(b.id, level: 0)), cRow = frame(.tab(c.id, level: 0))
        func drop(_ y: CGFloat) -> DropResolution { DropResolver.resolve(CGPoint(x: 100, y: y), layout: layout, dragged: .tab(tile.id), isCollapsed: { _ in false }) }
        let under = drop(box.maxY + 1), between = drop(bRow.maxY + (cRow.minY - bRow.maxY) / 2 + 1)
        XCTAssertEqual(under.target, .persistent(2))
        XCTAssertEqual(under.indicator, .line(CGRect(x: 6, y: (box.maxY + bRow.minY) / 2 - 1, width: 185, height: 2)))
        XCTAssertEqual(between.target, .persistent(3))
        XCTAssertEqual(between.indicator, .line(CGRect(x: 6, y: (bRow.maxY + cRow.minY) / 2 - 1, width: 185, height: 2)))
        var moved = list
        moved.move(tile.id, to: between.target!)
        XCTAssertEqual(moved.topOrder, [.tab(a.id), .group(g), .tab(b.id), .tab(tile.id), .tab(c.id)])
        XCTAssertTrue(moved.items.first { $0.id == tile.id }.map { $0.isPinned && !$0.inGrid && $0.groupID == nil } ?? false)
    }

    func testEmptyContainersTakeADropAtTheirTop() {
        let one = TabItem(id: TabID(), engineID: 1, url: "https://a.example/", title: "a", isLoading: false)
        let list = TabList(items: [one], activeID: one.id)!
        let layout = SidebarLayout(entries: list.layout(), width: 197)
        let div = layout.placements.first { $0.entry == .divider }!.frame
        let above = DropResolver.resolve(CGPoint(x: 100, y: div.minY - 3), layout: layout, dragged: .tab(one.id), isCollapsed: { _ in false })
        XCTAssertEqual(above.target, .persistent(0))  // no tiles: the drop pins a loose row
        let below = DropResolver.resolve(CGPoint(x: 100, y: 400), layout: layout, dragged: .tab(one.id), isCollapsed: { _ in false })
        XCTAssertEqual(below.target, .day(0))
    }

    /// Note 5.2 / Review Focus 3: wherever the pointer is, for every dragged item, an accepted drop keeps every tab and group once and the
    /// item lands in the container and at the index the resolver named.
    func testEveryPointKeepsTheTabsAndLandsWhereTheResolverSaid() {
        let base = Fixture()
        let items: [DragItem] = base.list.items.map { .tab($0.id) } + base.list.groups.map { .group($0.id) }
        var accepted = 0, refused = 0
        for item in items {
            for y in stride(from: CGFloat(48), to: 640, by: 2) {
                for x in [CGFloat(8), 60, 120, 188] {
                    var f = base
                    let r = f.resolve(y, x: x, item)
                    guard let target = r.target else { refused += 1; continue }
                    accepted += 1
                    switch item {
                    case .tab(let id):
                        f.list.move(id, to: target)
                        let t = f.list.items.first { $0.id == id }!
                        let index = f.list.containerIndex(of: id)!
                        switch target {
                        case .grid(let i): XCTAssertTrue(t.isPinned && t.inGrid && t.groupID == nil); XCTAssertEqual(index, min(i, base.g.count - (base.g.contains(id) ? 1 : 0)))
                        case .persistent(let i): XCTAssertTrue(t.isPinned && !t.inGrid && t.groupID == nil); XCTAssertEqual(index, min(i, f.list.topOrder.count - 1))
                        case .day(let i): XCTAssertTrue(!t.isPinned && t.groupID == nil); XCTAssertEqual(index, min(i, f.list.dayOrder.count - 1))
                        case .group(let g, let i):
                            XCTAssertEqual(t.groupID, g)
                            XCTAssertEqual(index, min(i, f.list.items.filter { $0.groupID == g }.count - 1))
                        }
                    case .group(let g):
                        switch target { case .persistent, .day: break; default: XCTFail("a group was sent to \(target) at \(x),\(y)") }
                        XCTAssertTrue(f.list.moveGroup(g, to: target))
                        if case .persistent(let i) = target { XCTAssertEqual(f.list.topOrder.firstIndex(of: .group(g)), min(i, f.list.topOrder.count - 1)) }
                        if case .day(let i) = target { XCTAssertEqual(f.list.dayOrder.firstIndex(of: .group(g)), min(i, f.list.dayOrder.count - 1)) }
                        XCTAssertEqual(f.list.groups.first { $0.id == g }!.isPinned, f.list.topOrder.contains(.group(g)))
                    }
                    XCTAssertEqual(f.list.items.count, base.list.items.count, "\(item) to \(target) at \(x),\(y)")
                    XCTAssertEqual(Set(f.list.items.map(\.id)), Set(base.list.items.map(\.id)))
                    XCTAssertEqual(f.list.groups.count, base.list.groups.count)
                }
            }
        }
        XCTAssertGreaterThan(accepted, 1000)
        XCTAssertGreaterThan(refused, 0)  // folders over folders and the grid
    }

    func testTheListScrollsInAn24PointBandAtEitherEdge() {
        XCTAssertEqual(AutoScroll.band, 24)
        XCTAssertEqual(AutoScroll.step(y: 300, height: 600), 0)
        XCTAssertEqual(AutoScroll.step(y: 24, height: 600), 0)
        XCTAssertEqual(AutoScroll.step(y: 576, height: 600), 0)
        XCTAssertLessThan(AutoScroll.step(y: 23, height: 600), 0)
        XCTAssertGreaterThan(AutoScroll.step(y: 577, height: 600), 0)
        XCTAssertLessThan(AutoScroll.step(y: 2, height: 600), AutoScroll.step(y: 20, height: 600))  // deeper is faster (more negative)
        XCTAssertGreaterThan(AutoScroll.step(y: 598, height: 600), AutoScroll.step(y: 580, height: 600))
        XCTAssertEqual(AutoScroll.step(y: -50, height: 600), -AutoScroll.maxStep)
        XCTAssertEqual(AutoScroll.step(y: 700, height: 600), AutoScroll.maxStep)
    }

    func testThePayloadIsKeyedByIdAndNamesItsWindow() throws {
        let w = UUID(), t = TabID(), g = GroupID()
        for item in [DragItem.tab(t), .group(g)] {
            let p = DragPayload(item, window: w)
            let back = try XCTUnwrap(DragPayload(data: try XCTUnwrap(p.data)))
            XCTAssertEqual(back, p)
            XCTAssertEqual(back.item, item)
            XCTAssertEqual(back.item(in: w), item)
            XCTAssertNil(back.item(in: UUID()), "another window's drag is refused")
        }
        let json = try XCTUnwrap(String(data: try XCTUnwrap(DragPayload(.tab(t), window: w).data), encoding: .utf8))
        XCTAssertTrue(json.contains("\"kind\":\"tab\"") && json.contains("\"id\":\"\(t.raw.uuidString)\"") && json.contains("\"window\":\"\(w.uuidString)\""))
        XCTAssertNil(DragPayload(data: Data("{}".utf8)))
        XCTAssertNil(DragPayload(data: Data(#"{"kind":"row","id":"\#(UUID())","window":"\#(UUID())"}"#.utf8)))
        XCTAssertEqual(DragPayload.pasteboardType, "app.noche.sidebar-item")
    }

    func testHapticReorderIsAnOnByDefaultBoolSetting() {
        let k = SettingKeys.key("hapticReorder")
        XCTAssertEqual(k?.defaultValue, "1")
        XCTAssertTrue(SettingKeys.isValid("hapticReorder", "0") && SettingKeys.isValid("hapticReorder", "1") && !SettingKeys.isValid("hapticReorder", "yes"))
        for (stored, want) in [(nil, true), ("1", true), ("0", false), ("x", true), ("", true)] as [(String?, Bool)] {
            XCTAssertEqual(SettingKeys.hapticReorder(stored: stored), want, "stored \(stored ?? "nil")")
        }
    }
}
