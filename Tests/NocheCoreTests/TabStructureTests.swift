import XCTest
@testable import NocheCore

/// Pinned tabs, groups, dormant tabs, cleanup, MRU and search (note 4.2, 4.4 and 5.1; amendments T1.1 to T1.6).
final class TabStructureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let day: TimeInterval = 86_400

    private func tab(_ n: Int, url: String? = nil, title: String? = nil, engine: Bool = true, at: TimeInterval = 0) -> TabItem {
        TabItem(id: TabID(), engineID: engine ? n : nil, url: url ?? "https://site\(n).example/", title: title ?? "T\(n)", isLoading: false,
                lastActiveAt: Date(timeIntervalSince1970: 1_000_000 + at))
    }
    /// n day tabs, the first active; ids in order.
    private func list(_ n: Int) -> (TabList, [TabID]) {
        var l = TabList()
        let ts = (0..<n).map { tab($0) }
        for t in ts { l.insertNew(t, opener: nil, addToTop: false, activate: t.engineID == 0) }
        return (l, ts.map(\.id))
    }
    private func ids(_ l: TabList) -> [TabID] { l.items.map(\.id) }
    private func item(_ l: TabList, _ id: TabID) -> TabItem { l.items.first { $0.id == id }! }
    private func visible(_ l: TabList) -> [TabID] {
        l.layout().compactMap { if case .tab(let id, _) = $0 { return id } else if case .gridTile(let id) = $0 { return id } else { return nil } }
    }

    // MARK: tree ops

    func testPinMovesToGridEndAndKeepsURL() {
        var (l, t) = list(4)
        XCTAssertEqual(l.pin(t[2]), [t[2]])
        XCTAssertEqual(l.pin(t[0]), [t[0]])
        XCTAssertEqual(Array(l.layout().prefix(2)), [.gridTile(t[2]), .gridTile(t[0])])  // first pin first, last pin last
        let p = item(l, t[2])
        XCTAssertTrue(p.isPinned && p.inGrid)
        XCTAssertEqual(p.pinnedURL, "https://site2.example/")
        XCTAssertEqual(l.dayOrder, [.tab(t[1]), .tab(t[3])])
        XCTAssertEqual(ids(l), [t[2], t[0], t[1], t[3]])  // items stay in layout order
    }
    func testPinDuplicateIsNoOp() {
        var (l, t) = list(2)
        l.pin(t[0])
        let before = l
        XCTAssertEqual(l.pin(t[0]), [])
        XCTAssertEqual(l.pin(TabID()), [])
        XCTAssertEqual(l, before)
    }
    func testPinnedURLIsFixedAtPinTime() {
        var (l, t) = list(1)
        l.pin(t[0])
        l.update(t[0], url: "https://elsewhere.example/", title: "E", isLoading: false)
        XCTAssertEqual(item(l, t[0]).pinnedURL, "https://site0.example/")
        XCTAssertEqual(l.resetToPinned(t[0]), "https://site0.example/")
        XCTAssertEqual(item(l, t[0]).url, "https://site0.example/")
        l.update(t[0], url: "https://elsewhere.example/", title: "E", isLoading: false)
        XCTAssertTrue(l.usePinnedPage(t[0]))
        XCTAssertEqual(item(l, t[0]).pinnedURL, "https://elsewhere.example/")
        let (d0, u) = list(1)
        var d = d0
        XCTAssertNil(d.resetToPinned(u[0]))  // not pinned
        XCTAssertFalse(d.usePinnedPage(u[0]))
    }
    func testUnpinReturnsToTopOfDayListAndClearsPin() {
        var (l, t) = list(4)
        l.pin(t[3])
        XCTAssertEqual(l.unpin(t[3]), [t[3]])
        XCTAssertEqual(l.dayOrder.first, .tab(t[3]))
        let u = item(l, t[3])
        XCTAssertFalse(u.isPinned || u.inGrid)
        XCTAssertNil(u.pinnedURL)
        XCTAssertEqual(l.unpin(t[3]), [])  // already unpinned
    }
    func testDragGridTileToLooseRowStaysPinnedAndUnpinsUnderDivider() {
        var (l, t) = list(3)
        l.pin(t[0])
        l.move(t[0], to: .persistent(0))
        XCTAssertTrue(item(l, t[0]).isPinned)
        XCTAssertFalse(item(l, t[0]).inGrid)
        XCTAssertEqual(l.topOrder, [.tab(t[0])])
        XCTAssertEqual(l.layout(), [.tab(t[0], level: 0), .divider, .newTab, .tab(t[1], level: 0), .tab(t[2], level: 0)])
        l.move(t[0], to: .day(1))
        XCTAssertFalse(item(l, t[0]).isPinned)
        XCTAssertNil(item(l, t[0]).pinnedURL)
        XCTAssertEqual(l.dayOrder, [.tab(t[1]), .tab(t[0]), .tab(t[2])])
    }
    func testMoveWithinDayListClampsAndNeverChangesActive() {
        var (l, t) = list(4)
        l.move(t[0], to: .day(2))
        XCTAssertEqual(ids(l), [t[1], t[2], t[0], t[3]])
        l.move(t[3], to: .day(-9))
        l.move(t[1], to: .day(99))
        XCTAssertEqual(ids(l), [t[3], t[2], t[0], t[1]])
        XCTAssertEqual(l.activeID, t[0])
        let before = l
        XCTAssertEqual(l.move(TabID(), to: .day(0)), [])
        XCTAssertEqual(l.move(t[0], to: .group(GroupID(), 0)), [])  // unknown group
        XCTAssertEqual(l, before)
    }
    func testCreateGroupPutsGroupWhereTheTabWas() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[1])!
        XCTAssertEqual(l.dayOrder, [.tab(t[0]), .group(g), .tab(t[2]), .tab(t[3])])
        XCTAssertEqual(item(l, t[1]).groupID, g)
        XCTAssertEqual(l.groups.first?.name, "Untitled")
        XCTAssertEqual(l.groups.first?.colorIndex, 0)
        XCTAssertFalse(l.groups[0].isPinned)
        XCTAssertNil(l.createGroup(with: TabID()))
        // from a loose pinned row: a pinned group at that place
        l.move(t[3], to: .persistent(0))
        let g2 = l.createGroup(with: t[3])!
        XCTAssertEqual(l.topOrder, [.group(g2)])
        XCTAssertTrue(l.groups.first { $0.id == g2 }!.isPinned)
        XCTAssertFalse(item(l, t[3]).isPinned)
        // from a grid tile: a pinned group at the top of the persistent area
        l.pin(t[0])
        let g3 = l.createGroup(with: t[0])!
        XCTAssertEqual(l.topOrder.first, .group(g3))
        XCTAssertFalse(item(l, t[0]).inGrid)
    }
    func testEmptyGroupColorAndIcon() {
        var (l, t) = list(2)
        let g = l.createEmptyGroup(name: "Reading")!
        XCTAssertEqual(l.dayOrder, [.group(g), .tab(t[0]), .tab(t[1])])
        XCTAssertEqual(l.groups.first?.name, "Reading")
        XCTAssertFalse(l.groups[0].isCollapsed)
        XCTAssertNil(l.createEmptyGroup(groupID: g))
        l.setGroupColor(g, 5)
        XCTAssertEqual(l.groups[0].colorIndex, 5)
        l.setGroupColor(g, 99)
        XCTAssertEqual(l.groups[0].colorIndex, 7)
        l.setGroupColor(g, -3)
        XCTAssertEqual(l.groups[0].colorIndex, 0)
        l.setGroupIcon(g, "star")
        XCTAssertEqual(l.groups[0].icon, "star")
        l.setGroupIcon(g, "")
        XCTAssertNil(l.groups[0].icon)
        l.setGroup(t[1], g)  // an empty group takes a tab like any other
        XCTAssertEqual(item(l, t[1]).groupID, g)
    }
    func testCreateGroupFromAGroupedTabGoesRightAfterThatGroup() {
        var (l, t) = list(3)
        let g = l.createGroup(with: t[0])!
        l.setGroup(t[1], g)
        let g2 = l.createGroup(with: t[1])!
        XCTAssertEqual(l.dayOrder, [.group(g), .group(g2), .tab(t[2])])
        XCTAssertEqual(item(l, t[1]).groupID, g2)
    }
    func testMoveTabIntoGroupAndOut() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[0])!
        XCTAssertEqual(l.setGroup(t[2], g), [t[2]])
        XCTAssertEqual(ids(l), [t[0], t[2], t[1], t[3]])  // children follow the header
        XCTAssertEqual(item(l, t[2]).groupID, g)
        l.move(t[3], to: .group(g, 1))
        XCTAssertEqual(ids(l), [t[0], t[3], t[2], t[1]])
        XCTAssertEqual(l.setGroup(t[3], nil), [t[3]])  // out: right after the group, still in the day list
        XCTAssertNil(item(l, t[3]).groupID)
        XCTAssertEqual(l.dayOrder, [.group(g), .tab(t[3]), .tab(t[1])])
        XCTAssertEqual(l.setGroup(t[1], nil), [])  // not grouped
    }
    func testPinClearsGroupAndPinnedGroupChildrenAreNotPinned() {
        var (l, t) = list(2)
        let g = l.createGroup(with: t[0])!
        l.pin(t[0])
        XCTAssertNil(item(l, t[0]).groupID)
        XCTAssertTrue(l.layout().contains(.group(g)))  // the empty group stays
        XCTAssertTrue(l.pinGroup(g))
        l.setGroup(t[1], g)
        XCTAssertFalse(item(l, t[1]).isPinned)
        XCTAssertEqual(l.topOrder, [.group(g)])
        XCTAssertTrue(l.unpinGroup(g))
        XCTAssertEqual(l.dayOrder.first, .group(g))
        XCTAssertFalse(l.groups[0].isPinned)
    }
    func testGroupIntoGroupIsRejected() {
        var (l, t) = list(3)
        let a = l.createGroup(with: t[0])!, b = l.createGroup(with: t[1])!
        let before = l
        XCTAssertFalse(l.moveGroup(a, to: .group(b, 0)))
        XCTAssertFalse(l.moveGroup(a, to: .grid(0)))
        XCTAssertEqual(l, before)
        XCTAssertTrue(l.moveGroup(a, to: .day(5)))
        XCTAssertEqual(l.dayOrder, [.group(b), .tab(t[2]), .group(a)])
        XCTAssertFalse(l.moveGroup(GroupID(), to: .day(0)))
    }
    func testMovingAGroupMovesItsChildren() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[0])!
        l.setGroup(t[1], g)
        l.moveGroup(g, to: .day(2))
        XCTAssertEqual(ids(l), [t[2], t[3], t[0], t[1]])
    }
    func testDeleteGroupClosesChildren() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[1])!
        l.setGroup(t[2], g)
        XCTAssertEqual(l.deleteGroup(g, closeTabs: true), [t[1], t[2]])
        XCTAssertEqual(ids(l), [t[0], t[3]])
        XCTAssertTrue(l.groups.isEmpty)
        XCTAssertEqual(l.dayOrder, [.tab(t[0]), .tab(t[3])])
    }
    func testDeleteGroupWithTheActiveChildHandsOverToAVisibleLiveTab() {
        var (l, t) = list(3)
        let g = l.createGroup(with: t[0])!
        l.setGroup(t[1], g)
        l.activate(t[1])
        l.deleteGroup(g, closeTabs: true)
        XCTAssertEqual(l.activeID, t[2])
    }
    func testDeleteGroupSeparateTabsAndUngroupKeepOrder() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[1])!
        l.setGroup(t[3], g)
        XCTAssertEqual(l.deleteGroup(g, closeTabs: false), [t[1], t[3]])
        XCTAssertEqual(l.dayOrder, [.tab(t[0]), .tab(t[1]), .tab(t[3]), .tab(t[2])])
        XCTAssertTrue(l.items.allSatisfy { $0.groupID == nil })
        let g2 = l.createGroup(with: t[0])!
        l.pinGroup(g2)
        l.setGroup(t[2], g2)
        XCTAssertEqual(l.ungroup(g2), [t[0], t[2]])
        XCTAssertEqual(l.topOrder, [.tab(t[0]), .tab(t[2])])  // loose pinned rows in the persistent area
        XCTAssertTrue(item(l, t[0]).isPinned && !item(l, t[0]).inGrid)
        XCTAssertEqual(l.ungroup(GroupID()), [])
    }
    func testCollapseKeepsActiveAndHidesChildrenFromLayout() {
        var (l, t) = list(3)
        let g = l.createGroup(with: t[0])!
        l.setGroup(t[1], g)
        l.activate(t[1])
        l.collapse(g)
        XCTAssertEqual(l.activeID, t[1])
        XCTAssertEqual(l.layout(), [.divider, .newTab, .group(g), .tab(t[2], level: 0)])
        l.collapse(g, false)
        XCTAssertEqual(l.layout(), [.divider, .newTab, .group(g), .tab(t[0], level: 1), .tab(t[1], level: 1), .tab(t[2], level: 0)])
        l.renameGroup(g, "Work")
        XCTAssertEqual(l.groups[0].name, "Work")
        l.renameGroup(GroupID(), "x")
        XCTAssertEqual(l.groups.count, 1)
    }

    // MARK: new tabs and close successor

    func testInsertNewTopVersusAfterOpener() {
        var (l, t) = list(3)
        let a = tab(10), b = tab(11), c = tab(12)
        l.insertNew(a, opener: t[1], addToTop: false, activate: false)
        XCTAssertEqual(l.dayOrder, [.tab(t[0]), .tab(t[1]), .tab(a.id), .tab(t[2])])
        l.insertNew(b, opener: t[1], addToTop: true, activate: true)
        XCTAssertEqual(l.dayOrder.first, .tab(b.id))
        XCTAssertEqual(l.activeID, b.id)
        l.insertNew(c, opener: nil, addToTop: false, activate: false)  // no opener appends
        XCTAssertEqual(l.dayOrder.last, .tab(c.id))
        XCTAssertFalse(l.insertNew(c, opener: nil, addToTop: true, activate: true))  // duplicate
        XCTAssertEqual(l.activeID, b.id)
    }
    func testInsertNewAfterAnOpenerInAGroupJoinsTheGroupAndAfterAPinnedOpenerGoesToTheTop() {
        var (l, t) = list(3)
        let g = l.createGroup(with: t[0])!
        let a = tab(10)
        l.insertNew(a, opener: t[0], addToTop: false, activate: false)
        XCTAssertEqual(item(l, a.id).groupID, g)
        l.pin(t[2])
        let b = tab(11)
        l.insertNew(b, opener: t[2], addToTop: false, activate: false)
        XCTAssertEqual(l.dayOrder.first, .tab(b.id))
    }
    func testInsertNewHonorsPinAndGroupOfAReopenedTab() {
        var (l, t) = list(2)
        let g = l.createGroup(with: t[0])!
        var p = tab(10); p.isPinned = true; p.inGrid = true
        var q = tab(11); q.groupID = g
        var r = tab(12); r.groupID = GroupID()  // its group is gone
        l.insertNew(p, opener: nil, addToTop: true, activate: false)
        l.insertNew(q, opener: nil, addToTop: true, activate: false)
        l.insertNew(r, opener: nil, addToTop: true, activate: false)
        XCTAssertEqual(l.layout().first, .gridTile(p.id))
        XCTAssertEqual(item(l, p.id).pinnedURL, p.url)
        XCTAssertEqual(item(l, q.id).groupID, g)
        XCTAssertNil(item(l, r.id).groupID)
        XCTAssertEqual(l.dayOrder.first, .tab(r.id))
    }
    func testCloseSuccessorIsTheVisibleLiveRowBelowThenAbove() {
        var (l, t) = list(5)
        let g = l.createGroup(with: t[1])!
        l.setGroup(t[2], g)
        l.collapse(g)
        // order: t0, group(t1,t2 hidden), t3, t4
        l.activate(t[0])
        XCTAssertEqual(l.remove(t[0]), t[3])  // below the removed row is the header's hidden kids: skipped
        XCTAssertEqual(l.activeID, t[3])
        l.activate(t[4])
        XCTAssertEqual(l.remove(t[4]), t[3])  // last row: the one above
    }
    func testDormantTabsAreNeverTheCloseSuccessor() {
        var l = TabList()
        let a = tab(0), b = tab(1, engine: false), c = tab(2), d = tab(3, engine: false)
        for x in [a, b, c, d] { l.insertNew(x, opener: nil, addToTop: false, activate: x.id == a.id) }
        XCTAssertEqual(l.remove(a.id), c.id)
        XCTAssertEqual(l.remove(c.id), nil)  // only dormant tabs left: no successor
        XCTAssertNil(l.activeID)
        XCTAssertEqual(l.items.count, 2)
    }
    func testRemoveGridTabAndPinnedRowUpdatesEveryContainer() {
        var (l, t) = list(3)
        l.pin(t[0])
        l.move(t[1], to: .persistent(0))
        l.activate(t[0])
        XCTAssertEqual(l.remove(t[0]), t[1])
        XCTAssertEqual(l.remove(t[1]), t[2])
        XCTAssertEqual(l.topOrder, [])
        XCTAssertEqual(ids(l), [t[2]])
    }
    func testNextAndPreviousVisibleSkipCollapsedChildrenAndWrap() {
        var (l, t) = list(5)
        let g = l.createGroup(with: t[1])!
        l.setGroup(t[2], g)
        l.pin(t[4])
        // layout order: grid t4, then group(t1, t2), t0, t3 (the day list: t0, g, t3)
        XCTAssertEqual(visible(l), [t[4], t[0], t[1], t[2], t[3]])
        l.collapse(g)
        XCTAssertEqual(l.nextVisible(after: t[4]), t[0])
        XCTAssertEqual(l.nextVisible(after: t[0]), t[3])
        XCTAssertEqual(l.nextVisible(after: t[3]), t[4])
        XCTAssertEqual(l.previousVisible(before: t[3]), t[0])
        XCTAssertEqual(l.previousVisible(before: t[4]), t[3])
        XCTAssertEqual(l.nextVisible(after: t[2]), t[3])  // from a hidden child: the next visible row
        XCTAssertNil(l.nextVisible(after: TabID()))
        let (one, o) = list(1)
        XCTAssertEqual(one.nextVisible(after: o[0]), o[0])
    }

    // MARK: dormant tabs

    func testDormantPinnedTabRestoresDormantAndWakesWithAnEngineID() {
        var a = tab(0), b = tab(1, engine: false)
        a.engineID = 4
        b.isPinned = true; b.inGrid = true; b.pinnedURL = b.url
        var l = TabList(items: [a, b], activeID: a.id)!
        XCTAssertEqual(l.layout().first, .gridTile(b.id))  // a pinned item passed to init lands in the grid
        XCTAssertNil(item(l, b.id).engineID)
        l.setEngineID(b.id, 9)
        XCTAssertEqual(item(l, b.id).engineID, 9)
        l.setEngineID(b.id, nil)
        XCTAssertNil(item(l, b.id).engineID)
    }
    func testRestoreInitNormalizesBrokenStructure() {
        var a = tab(0), b = tab(1), c = tab(2)
        a.groupID = GroupID()                       // unknown group
        b.isPinned = true; b.inGrid = true; b.groupID = GroupID()  // pin wins over group
        c.inGrid = true; c.pinnedURL = "x"          // not pinned: both cleared
        let g = TabGroup(id: GroupID(), name: "G", colorIndex: 2, icon: nil, isCollapsed: false, isPinned: false)
        let l = TabList(items: [a, b, c], groups: [g], topOrder: [.tab(a.id), .group(GroupID())], dayOrder: [.group(g.id), .tab(c.id), .tab(c.id)], activeID: nil)!
        XCTAssertNil(item(l, a.id).groupID)
        XCTAssertNil(item(l, b.id).groupID)
        XCTAssertEqual(item(l, b.id).pinnedURL, b.url)
        XCTAssertFalse(item(l, c.id).inGrid)
        XCTAssertNil(item(l, c.id).pinnedURL)
        XCTAssertEqual(l.topOrder, [])
        XCTAssertEqual(l.dayOrder, [.group(g.id), .tab(c.id), .tab(a.id)])
        XCTAssertEqual(l.items.count, 3)
        XCTAssertNil(TabList(items: [a], groups: [g, g], topOrder: [], dayOrder: [], activeID: nil))
        XCTAssertEqual(TabList(items: [a, b, c], groups: [g], topOrder: l.topOrder, dayOrder: l.dayOrder, activeID: c.id)?.dayOrder, l.dayOrder)
    }

    // MARK: cleanup

    func testCleanupCandidatesRule() {
        let now = t0.addingTimeInterval(30 * day)
        var l = TabList()
        let old = tab(0, at: 0), edge = tab(1, at: 23 * day), over = tab(2, at: 23 * day - 1), fresh = tab(3, at: 29 * day)
        var pinned = tab(4, at: 0); pinned.isPinned = true; pinned.inGrid = true
        var loading = tab(5, at: 0); loading.isLoading = true
        let active = tab(6, at: 0), audible = tab(7, at: 0), dormant = tab(8, engine: false, at: 0)
        for x in [old, edge, over, fresh, pinned, loading, active, audible, dormant] { l.insertNew(x, opener: nil, addToTop: false, activate: x.id == active.id) }
        let week: TimeInterval = 7 * day
        XCTAssertEqual(l.cleanupCandidates(now: now, threshold: week, excluding: [audible.id]), [old.id, over.id, dormant.id])
        XCTAssertEqual(l.cleanupCandidates(now: now, threshold: nil), [])  // Never
        XCTAssertEqual(l.cleanupCandidates(now: now, threshold: week).count, 4)  // the audible tab is a candidate unless the caller excludes it
    }
    func testCleanupIncludesGroupedTabs() {
        var (l, t) = list(3)
        l.setGroup(t[2], l.createGroup(with: t[1])!)
        let now = t0.addingTimeInterval(10 * day)
        XCTAssertEqual(l.cleanupCandidates(now: now, threshold: 7 * day), [t[1], t[2]])  // t0 is active
    }
    func testArchiveKeepsGroupAndRestoreReinsertsAtTheGroup() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[1])!
        l.setGroup(t[2], g)
        let at = t0.addingTimeInterval(9 * day)
        XCTAssertEqual(l.archive([t[1], t[2], TabID()], now: at), [t[1], t[2]])
        XCTAssertEqual(ids(l), [t[0], t[3]])
        XCTAssertEqual(l.archived.map(\.id), [t[1], t[2]])
        XCTAssertEqual(l.archived[0].archivedAt, at)
        XCTAssertEqual(l.archived[0].groupID, g)
        XCTAssertNil(l.archived[0].engineID)
        XCTAssertTrue(l.restore(t[2]))
        XCTAssertEqual(item(l, t[2]).groupID, g)
        XCTAssertNil(item(l, t[2]).archivedAt)
        XCTAssertNil(item(l, t[2]).engineID)  // restored dormant: the caller wakes it
        XCTAssertEqual(l.dayOrder, [.tab(t[0]), .group(g), .tab(t[3])])
        XCTAssertFalse(l.restore(t[2]))
        // the group went away meanwhile: back at the top of the day list
        l.deleteGroup(g, closeTabs: false)
        XCTAssertTrue(l.restore(t[1]))
        XCTAssertNil(item(l, t[1]).groupID)
        XCTAssertEqual(l.dayOrder.first, .tab(t[1]))
    }
    func testArchiveSkipsPinnedAndHandsOverTheActiveTab() {
        var (l, t) = list(3)
        l.pin(t[2])
        XCTAssertEqual(l.archive([t[2]], now: t0), [])
        XCTAssertEqual(l.archive([t[0]], now: t0), [t[0]])  // the active one
        XCTAssertEqual(l.activeID, t[1])
    }

    // MARK: MRU

    func testMRUFollowsActivationAndBreaksTiesWithTheCounter() {
        var (l, t) = list(4)
        let same = t0.addingTimeInterval(100)
        l.markActive(t[1], at: same)
        l.markActive(t[2], at: same)  // same instant: the later activation wins
        l.markActive(t[3], at: t0.addingTimeInterval(50))
        XCTAssertEqual(l.mru(limit: 8), [t[2], t[1], t[3], t[0]])
        XCTAssertEqual(l.activeID, t[3])
        _ = l.remove(t[2])
        XCTAssertEqual(l.mru(limit: 2), [t[1], t[3]])  // closed tabs drop out; the limit cuts
        XCTAssertEqual(l.mru(limit: 0), [])
        l.markActive(TabID(), at: same)  // unknown: no change
        XCTAssertEqual(l.activeID, t[3])
    }
    func testMRUDefaultLimitIsEight() {
        let (l, _) = list(12)
        XCTAssertEqual(l.mru().count, 8)
    }
    func testMRUIncludesGroupedAndPinnedButNotArchived() {
        var (l, t) = list(3)
        l.pin(t[0])
        l.createGroup(with: t[1])
        l.archive([t[2]], now: t0)
        XCTAssertEqual(Set(l.mru()), [t[0], t[1]])
    }

    // MARK: search

    func testSearchRanksPrefixThenSubstringThenSubsequenceThenRecency() {
        var l = TabList()
        let sub = tab(1, url: "https://a.example/", title: "my github notes", at: 30)
        let pre = tab(2, url: "https://b.example/", title: "GitHub", at: 10)
        let hostOnly = tab(3, url: "https://www.github.com/x", title: "Home", at: 20)
        let seq = tab(4, url: "https://c.example/", title: "go it hub", at: 40)
        let none = tab(5, url: "https://d.example/", title: "Other", at: 50)
        for x in [sub, pre, hostOnly, seq, none] { l.insertNew(x, opener: nil, addToTop: false, activate: false) }
        // prefix on the title or the host (newest first), then substring, then subsequence
        XCTAssertEqual(l.searchTabs(query: "github"), [hostOnly.id, pre.id, sub.id, seq.id])
        XCTAssertEqual(l.searchTabs(query: "gthb"), [seq.id, sub.id, hostOnly.id, pre.id])  // all subsequence matches: newest first
    }
    func testSearchMatchesTheHostAndCustomTitleAndIgnoresCase() {
        var l = TabList()
        var a = tab(1, url: "https://www.example.org/p", title: "Zebra")
        a.customTitle = "Quarterly Plan"
        l.insertNew(a, opener: nil, addToTop: false, activate: false)
        XCTAssertEqual(l.searchTabs(query: "EXAMPLE"), [a.id])
        XCTAssertEqual(l.searchTabs(query: "quarterly"), [a.id])
        XCTAssertEqual(l.searchTabs(query: "zebra"), [])  // the custom title replaces the page title
        XCTAssertEqual(l.searchTabs(query: "  qp "), [a.id])  // trimmed, subsequence
        XCTAssertEqual(l.searchTabs(query: "nomatch"), [])
    }
    func testVisibleItemsSkipCollapsedChildrenButKeepDormantAndHeadersOutOfTheCount() {
        var (l, t) = list(5)
        l.setEngineID(t[3], nil)  // a dormant tab is a row
        let g = l.createGroup(with: t[1])!
        _ = l.setGroup(t[2], g)
        XCTAssertEqual(l.visibleItems.map(\.id), l.items.map(\.id))  // an open group hides nothing
        l.collapse(g)
        XCTAssertEqual(l.visibleItems.map(\.id), l.items.map(\.id).filter { $0 != t[1] && $0 != t[2] })
        XCTAssertTrue(l.visibleItems.contains { $0.id == t[3] && $0.engineID == nil })
    }
    func testSearchArchivedComesAfterLiveAndEmptyQueryIsMRU() {
        var (l, t) = list(3)
        l.markActive(t[2], at: t0.addingTimeInterval(500))
        l.archive([t[1]], now: t0.addingTimeInterval(600))
        XCTAssertEqual(l.searchTabs(query: ""), [t[2], t[0], t[1]])
        XCTAssertEqual(l.searchTabs(query: "site"), [t[2], t[0], t[1]])  // all match; live first, then archived
        XCTAssertEqual(l.searchTabs(query: "site1"), [t[1]])
    }
    func testTabSearchRank() {
        XCTAssertEqual(TabSearch.rank("git", title: "GitHub", url: "https://x.com"), 0)
        XCTAssertEqual(TabSearch.rank("hub", title: "GitHub", url: "https://x.com"), 1)
        XCTAssertEqual(TabSearch.rank("gh", title: "GitHub", url: "https://x.com"), 2)
        XCTAssertEqual(TabSearch.rank("x.c", title: "Home", url: "https://www.x.com/a"), 0)
        XCTAssertNil(TabSearch.rank("zz", title: "GitHub", url: "https://x.com"))
        XCTAssertEqual(TabSearch.rank("", title: "a", url: "b"), 0)
    }

    // MARK: the capture composition (table 1.1, amendment T1.6)

    func testCaptureCompositionShape() {
        let l = SidebarComposition.capture()
        let e = l.layout()
        var grid = 0, i = 0
        while case .gridTile = e[i] { grid += 1; i += 1 }
        XCTAssertEqual(grid, 12)
        func tabs(_ r: Range<Int>) -> Bool { r.allSatisfy { if case .tab(_, 0) = e[$0] { true } else { false } } }
        func groups(_ r: Range<Int>) -> Bool { r.allSatisfy { if case .group = e[$0] { true } else { false } } }
        XCTAssertTrue(tabs(i..<i + 2)); i += 2        // 2 loose pinned rows
        XCTAssertTrue(groups(i..<i + 11)); i += 11    // 11 collapsed groups
        XCTAssertTrue(tabs(i..<i + 5)); i += 5        // 5 loose pinned rows
        XCTAssertEqual(e[i], .divider)
        XCTAssertEqual(e[i + 1], .newTab)
        XCTAssertEqual(e.count - (i + 2), 3)          // day tabs
        XCTAssertTrue(l.groups.allSatisfy { $0.isCollapsed && $0.isPinned })
        XCTAssertEqual(l.items.filter { $0.isPinned && $0.inGrid }.count, 12)
        XCTAssertEqual(l.items.filter { $0.isPinned && !$0.inGrid }.count, 7)
        XCTAssertNotNil(l.activeID)
        XCTAssertEqual(SidebarComposition.capture(dayTabs: 6).layout().count - e.count, 3)
    }

    // MARK: invariants

    func testEveryMutationKeepsEveryTabInExactlyOnePlace() {
        var (l, t) = list(8)
        let g = l.createGroup(with: t[1])!
        l.setGroup(t[2], g)
        l.pin(t[3])
        l.move(t[4], to: .persistent(0))
        l.moveGroup(g, to: .persistent(1))
        l.collapse(g)
        l.unpin(t[3])
        l.move(t[5], to: .group(g, 0))
        l.archive([t[6]], now: t0)
        l.restore(t[6])
        _ = l.remove(t[7])
        let live = Set(l.items.map(\.id))
        XCTAssertEqual(live.count, l.items.count)
        let placed: [TabID] = l.items.filter { $0.isPinned && $0.inGrid }.map(\.id)
            + (l.topOrder + l.dayOrder).compactMap { if case .tab(let id) = $0 { id } else { nil } }
            + l.items.filter { $0.groupID != nil }.map(\.id)
        XCTAssertEqual(Set(placed), live)
        XCTAssertEqual(placed.count, live.count)
    }

    // MARK: container-relative index (T3.5)

    func testContainerIndexIsRelativeToItsContainerNotTheFlatList() {
        var (l, t) = list(5)
        l.pin(t[0])
        let g = l.createGroup(with: t[1])!
        // items: pin, group child, then the day tabs; the day list is [group, t2, t3, t4].
        XCTAssertEqual(l.items.firstIndex { $0.id == t[3] }, 3)
        XCTAssertEqual(l.containerIndex(of: t[3]), 2)
        XCTAssertEqual(l.containerIndex(of: t[4]), 3)
        XCTAssertEqual(l.containerIndex(of: t[0]), 0)  // the grid
        XCTAssertEqual(l.containerIndex(of: t[1]), 0)  // inside the group
        XCTAssertEqual(l.containerIndex(of: TabID()), nil)
        _ = g
    }

    func testReopenAtContainerIndexPutsTheTabBackBetweenItsNeighbours() {
        var (l, t) = list(5)
        l.pin(t[0])
        l.createGroup(with: t[1])
        let before = ids(l)
        let closed = item(l, t[3]), at = l.containerIndex(of: t[3])!
        _ = l.remove(t[3])
        l.insertNew(closed, opener: nil, addToTop: false, activate: false)
        l.move(t[3], to: at)
        XCTAssertEqual(ids(l), before)
        // The flat index (3) would have put it after t4.
        var wrong = l
        _ = wrong.remove(t[3])
        wrong.insertNew(closed, opener: nil, addToTop: false, activate: false)
        wrong.move(t[3], to: 3)
        XCTAssertNotEqual(ids(wrong), before)
    }

    func testDormantTabsKeepTheirPlaceAndAreNeverTheCloseSuccessor() {
        var (l, t) = list(4)
        l.pin(t[1])
        l.setEngineID(t[1], nil)   // Cmd+W on a pinned tab
        XCTAssertEqual(item(l, t[1]).engineID, nil)
        XCTAssertTrue(item(l, t[1]).isPinned)
        l.markActive(t[0], at: t0)
        XCTAssertEqual(l.remove(t[0]), t[2])  // not the dormant pin above
        l.setEngineID(t[1], 77)               // a click wakes it, same id and place
        XCTAssertEqual(item(l, t[1]).engineID, 77)
        XCTAssertEqual(l.items.first?.id, t[1])
    }

    func testRestoredNeverDropsSavedTabs() {
        var (current, t) = list(2)
        let pin = tab(9, engine: false)
        // Two saved items share an id: the init refuses the list, and the saved pin must still be there, dormant.
        var pinned = pin; pinned.isPinned = true; pinned.inGrid = true; pinned.pinnedURL = pin.url
        let dup = item(current, t[0])
        let r = TabList.restored(items: [pinned, dup, dup], groups: [], topOrder: [], dayOrder: [], activeID: t[0], current: current)
        XCTAssertFalse(r.intact)
        XCTAssertTrue(r.list.items.contains { $0.id == pinned.id && $0.isPinned && $0.engineID == nil })
        XCTAssertEqual(Set(r.list.items.map(\.id)), Set([pinned.id] + t))
        // A good structure is intact and equal to the plain init.
        let ok = TabList.restored(items: [pinned, dup], groups: [], topOrder: [], dayOrder: [], activeID: t[0], current: current)
        XCTAssertTrue(ok.intact)
        XCTAssertEqual(ok.list.items.first?.id, pinned.id)
        current = ok.list
    }

    // MARK: moving between windows (M1.6 Task 5b)

    func testExtractTabReturnsItLooseAndHandsOverTheSelection() {
        var (l, t) = list(3)
        let g = l.createGroup(with: t[0])!
        l.setGroup(t[1], g)
        l.markActive(t[1], at: t0)
        let out = l.extract(t[1])!
        XCTAssertNil(out.item.groupID)                 // out of the group: it arrives loose
        XCTAssertEqual(out.successor, t[2])            // the active tab left: the next live row takes over, as when it closes
        XCTAssertEqual(l.activeID, t[2])
        XCTAssertNil(l.extract(t[1]))                  // gone
        XCTAssertEqual(ids(l), [t[0], t[2]])
    }
    func testExtractGroupTakesEveryChildAndItsRows() {
        var (l, t) = list(4)
        let g = l.createGroup(with: t[1], name: "Reading")!
        l.setGroup(t[2], g)
        l.setGroupColor(g, 3); l.setGroupIcon(g, "star"); l.collapse(g)
        l.markActive(t[2], at: t0)                     // the active tab is a child: the successor is outside the group
        let out = l.extract(group: g)!
        XCTAssertEqual(out.group.id, g)
        XCTAssertEqual([out.group.name, "\(out.group.colorIndex)", out.group.icon ?? "", "\(out.group.isCollapsed)"], ["Reading", "3", "star", "true"])
        XCTAssertEqual(out.items.map(\.id), [t[1], t[2]])   // in the group's order
        XCTAssertEqual(out.successor, t[3])
        XCTAssertEqual(l.activeID, t[3])
        XCTAssertTrue(l.groups.isEmpty)
        XCTAssertEqual(l.dayOrder, [.tab(t[0]), .tab(t[3])])
        XCTAssertNil(l.extract(group: g))
    }
    func testAdoptGroupGoesToTheEndOfItsAreaWithItsTabsAndState() {
        var src = list(3).0
        let ids3 = src.items.map(\.id)
        let g = src.createGroup(with: ids3[1], name: "G")!
        src.setGroup(ids3[2], g)
        src.setGroupColor(g, 5); src.collapse(g)
        let out = src.extract(group: g)!
        var dst = list(2).0
        let own = ids(dst)
        let dormant = out.items.map { var x = $0; x.engineID = nil; return x }
        XCTAssertTrue(dst.adopt(group: out.group, items: dormant))
        XCTAssertEqual(dst.dayOrder, [.tab(own[0]), .tab(own[1]), .group(g)])      // the end of the day list
        XCTAssertEqual(dst.items.map(\.id), own + [ids3[1], ids3[2]])
        XCTAssertEqual(dst.groups, [out.group])
        XCTAssertTrue(dst.items.suffix(2).allSatisfy { $0.groupID == g && $0.engineID == nil })
        XCTAssertFalse(dst.adopt(group: out.group, items: dormant))                 // an id never repeats in a window
    }
    func testAdoptPinnedGroupGoesToThePersistentArea() {
        var src = list(2).0
        let a = src.items[1].id
        let g = src.createGroup(with: a)!
        src.pinGroup(g)
        let out = src.extract(group: g)!
        XCTAssertTrue(out.group.isPinned)
        var dst = list(1).0
        XCTAssertTrue(dst.adopt(group: out.group, items: out.items))
        XCTAssertEqual(dst.topOrder, [.group(g)])
        XCTAssertEqual(dst.dayOrder.count, 1)
    }
}
