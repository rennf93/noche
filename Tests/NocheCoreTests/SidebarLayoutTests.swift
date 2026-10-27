import XCTest
@testable import NocheCore

final class SidebarLayoutTests: XCTestCase {
    private func frames(_ list: TabList, width: CGFloat = 197) -> [SidebarPlacement] { SidebarLayout(entries: list.layout(), width: width).placements }

    /// Note 5.1 "order": table 1.1's y positions for the capture composition, exactly (pure integers).
    func testCaptureCompositionMatchesTable11() {
        let p = frames(SidebarComposition.capture())
        func of(_ kind: (SidebarEntry) -> Bool) -> [CGRect] { p.filter { kind($0.entry) }.map(\.frame) }
        let tiles = of { if case .gridTile = $0 { true } else { false } }
        XCTAssertEqual(tiles.count, 12)
        for (i, f) in tiles.enumerated() { XCTAssertEqual(f, CGRect(x: 6 + 48 * CGFloat(i % 4), y: 54 + 47 * CGFloat(i / 4), width: 41, height: 41), "tile \(i)") }
        let groups = of { if case .group = $0 { true } else { false } }
        XCTAssertEqual(groups.map(\.minY), (0..<11).map { 269 + 40 * CGFloat($0) })
        XCTAssertTrue(groups.allSatisfy { $0.height == 39 && $0.minX == 6 && $0.width == 185 })
        let tabs = of { if case .tab = $0 { true } else { false } }
        XCTAssertEqual(tabs.map(\.minY), [192, 229] + (0..<5).map { 709 + 37 * CGFloat($0) } + [944, 981, 1018])
        XCTAssertTrue(tabs.allSatisfy { $0.height == 37 && $0.minX == 6 && $0.width == 185 })
        XCTAssertEqual(of { $0 == .divider }, [CGRect(x: 12, y: 900, width: 175, height: 1)])
        XCTAssertEqual(of { $0 == .newTab }, [CGRect(x: 6, y: 905, width: 185, height: 39)])
        XCTAssertEqual(SidebarLayout(entries: SidebarComposition.capture().layout(), width: 197).contentBottom, 1055)
    }

    func testOrdinalsCountEachKindInLayoutOrder() {
        let p = frames(SidebarComposition.capture())
        func ordinals(_ kind: (SidebarEntry) -> Bool) -> [Int] { p.filter { kind($0.entry) }.map(\.ordinal) }
        XCTAssertEqual(ordinals { if case .gridTile = $0 { true } else { false } }, Array(0..<12))
        XCTAssertEqual(ordinals { if case .group = $0 { true } else { false } }, Array(0..<11))
        XCTAssertEqual(ordinals { if case .tab = $0 { true } else { false } }, Array(0..<10))
    }

    /// A group follows a tab row 3 pt lower; a tab row follows a group header or a child at 37 (a header is 40 apart from what follows).
    func testSpacingBetweenMixedEntries() {
        func t(_ n: Int, pinned: Bool, group: GroupID? = nil) -> TabItem {
            TabItem(id: TabID(), engineID: n, url: "https://s\(n).example/", title: "t", isLoading: false, isPinned: pinned, groupID: group)
        }
        let g = TabGroup(id: GroupID(), name: "g", colorIndex: 0, icon: nil, isCollapsed: false, isPinned: true)
        let (a, kid, c) = (t(0, pinned: true), t(1, pinned: false, group: g.id), t(2, pinned: true))
        let list = TabList(items: [a, kid, c], groups: [g], topOrder: [.tab(a.id), .group(g.id), .tab(c.id)], activeID: nil)!
        let ys = frames(list).filter { $0.entry != .divider && $0.entry != .newTab }.map(\.frame.minY)
        XCTAssertEqual(ys, [54, 54 + 37 + 3, 94 + 40, 134 + 37])
    }

    func testExpandedGroupHasABoxAroundHeaderAndChildren() {
        var list = SidebarComposition.capture()
        let g = list.groups[0].id
        list.collapse(g, false)
        let layout = SidebarLayout(entries: list.layout(), width: 197)
        XCTAssertEqual(layout.boxes.count, 1)
        XCTAssertEqual(layout.boxes[0].group, g)
        XCTAssertEqual(layout.boxes[0].frame, CGRect(x: 6, y: 269, width: 185, height: 77))
        let after = layout.placements.first { if case .group(let x) = $0.entry { x == list.groups[1].id } else { false } }!
        XCTAssertEqual(after.frame.minY, 269 + 40 + 37 + 3)  // the next group follows a tab row
    }

    func testEmptySidebarPutsTheDividerBelowTheListTop() {
        let p = frames(TabList())
        XCTAssertEqual(p.map(\.frame), [CGRect(x: 12, y: 60, width: 175, height: 1), CGRect(x: 6, y: 65, width: 185, height: 39)])
    }

    func testRealizedKeepsVisibleRowsPlusOverscanAndNeverMoreThanBudgetAtTheTestHeight() {
        let items = (0..<500).map { TabItem(id: TabID(), engineID: $0, url: "https://s\($0).example/", title: "t", isLoading: false) }
        let layout = SidebarLayout(entries: TabList(items: items, activeID: nil)!.layout(), width: 197)
        let list: CGFloat = 1436 - 48 - 42  // the scroll area's height
        for offset in stride(from: 0, to: 18_000, by: 13) {
            let top = 48 + CGFloat(offset)  // window y of the visible top
            let r = layout.realized(minY: top, maxY: top + list)
            XCTAssertLessThanOrEqual(r.count, 40, "offset \(offset)")
            XCTAssertEqual(r, r.sorted())
            let visible = layout.placements.indices.filter { layout.placements[$0].frame.maxY > top && layout.placements[$0].frame.minY < top + list && r.contains($0) == false }
            XCTAssertTrue(visible.filter { if case .tab = layout.placements[$0].entry { true } else { false } }.isEmpty, "a visible row is not realized at \(offset)")
        }
    }

    /// Ruling M72: with the capture's pins above 500 day tabs, tab rows and group rows stay at 40 at every offset; tiles are extra (12).
    func testRowViewsStayAtFortyWithThePinsAbove() {
        let layout = SidebarLayout(entries: SidebarComposition.capture(dayTabs: 500).layout(), width: 197)
        let list: CGFloat = 1436 - 48 - 42
        var most = 0
        for offset in stride(from: 0, to: Int(layout.contentBottom), by: 7) {
            let top = 48 + CGFloat(offset)
            let r = layout.realized(minY: top, maxY: top + list)
            let tiles = r.filter { if case .gridTile = layout.placements[$0].entry { true } else { false } }.count
            most = max(most, r.count - tiles)
            XCTAssertLessThanOrEqual(r.count - tiles, 40, "offset \(offset)")
            XCTAssertLessThanOrEqual(r.count, 40 + 12, "offset \(offset)")
        }
        XCTAssertGreaterThan(most, 30)
    }

    func testRealizedOfAShortListIsEverything() {
        let layout = SidebarLayout(entries: SidebarComposition.capture().layout(), width: 197)
        XCTAssertEqual(layout.realized(minY: 48, maxY: 1394).count, 12 + 2 + 11 + 5 + 3)
    }
}

final class PinnedGridTests: XCTestCase {
    /// Note 5.1 "grid": 4 columns at 197, 3 at 150, 5 at 245.
    func testColumns() {
        XCTAssertEqual(PinnedGrid.columns(197), 4)
        XCTAssertEqual(PinnedGrid.columns(150), 3)
        XCTAssertEqual(PinnedGrid.columns(245), 5)
        XCTAssertEqual(PinnedGrid.columns(0), 1)
    }

    func testFramesAndRows() {
        XCTAssertEqual(PinnedGrid.frame(index: 5, width: 197), CGRect(x: 54, y: 47, width: 41, height: 41))
        XCTAssertEqual(PinnedGrid.frame(index: 3, width: 150), CGRect(x: 6, y: 47, width: 41, height: 41))
        XCTAssertEqual(PinnedGrid.rows(count: 12, width: 197), 3)
        XCTAssertEqual(PinnedGrid.rows(count: 13, width: 197), 4)
        XCTAssertEqual(PinnedGrid.rows(count: 0, width: 197), 0)
    }

    func testSlotFromPoint() {
        XCTAssertEqual(PinnedGrid.slot(at: CGPoint(x: 10, y: 10), count: 12, width: 197), 0)
        XCTAssertEqual(PinnedGrid.slot(at: CGPoint(x: 60, y: 50), count: 12, width: 197), 5)
        XCTAssertEqual(PinnedGrid.slot(at: CGPoint(x: 190, y: 50), count: 12, width: 197), 7)
        XCTAssertEqual(PinnedGrid.slot(at: CGPoint(x: 100, y: 900), count: 12, width: 197), 12)  // past the last tile: the end
        XCTAssertEqual(PinnedGrid.slot(at: CGPoint(x: -5, y: -5), count: 12, width: 197), 0)
    }
}
