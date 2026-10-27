import XCTest
@testable import NocheCore

final class TabListTests: XCTestCase {
    private func tab(_ n: Int, url: String = "https://example.com", title: String = "T") -> TabItem {
        TabItem(id: TabID(raw: UUID()), engineID: n, url: url, title: title, isLoading: false)
    }
    private func list(_ count: Int) -> (TabList, [TabItem]) {
        var l = TabList()
        let ts = (0..<count).map { tab($0) }
        for t in ts { l.insert(t, after: nil, activate: t.engineID == 0) }
        return (l, ts)
    }

    func testInsertAppendsAndActivates() {
        var l = TabList()
        let a = tab(1), b = tab(2)
        l.insert(a, after: nil, activate: true)
        l.insert(b, after: nil, activate: false)
        XCTAssertEqual(l.items.map(\.id), [a.id, b.id])
        XCTAssertEqual(l.activeID, a.id)
    }
    func testDiscardedKeepsTheEngineTabAndIsRuntimeOnly() {
        var (l, ts) = list(2)
        l.setDiscarded(ts[1].id, true)
        XCTAssertTrue(l.items[1].isDiscarded)
        XCTAssertEqual(l.items[1].engineID, 1, "a discarded tab keeps its engine tab")
        XCTAssertFalse(l.items[0].isDiscarded)
        l.setDiscarded(ts[1].id, false)
        XCTAssertFalse(l.items[1].isDiscarded)
        l.setDiscarded(ts[1].id, true)
        l.setEngineID(ts[1].id, nil)   // it went dormant: that is another state
        XCTAssertFalse(l.items[1].isDiscarded)
        l.setDiscarded(TabID(), true)  // unknown id: no change
        XCTAssertEqual(l.items.filter(\.isDiscarded).count, 0)
    }
    func testAnItemWithNoEngineTabIsNeverDiscarded() {
        var t = tab(1)
        t.isDiscarded = true
        t.engineID = nil   // a dormant copy, wherever it is made
        XCTAssertFalse(t.isDiscarded)
        t.engineID = 4
        XCTAssertFalse(t.isDiscarded, "an engine tab given back does not bring the flag back")
    }
    func testUpdateChangesTitleAndURL() {
        var (l, ts) = list(2)
        l.update(ts[1].id, url: "https://b.example/", title: "B", isLoading: true)
        XCTAssertEqual(l.items[1].title, "B")
        XCTAssertEqual(l.displayTitle(of: ts[1].id), "B")
        XCTAssertTrue(l.items[1].isLoading)
        l.update(TabID(), url: "x", title: "x", isLoading: false)  // unknown id: no change
        XCTAssertEqual(l.items.count, 2)
    }
    func testInsertAfterOpener() {
        var (l, ts) = list(3)
        let c = tab(9)
        l.insert(c, after: ts[0].id, activate: true)
        XCTAssertEqual(l.items.map(\.id), [ts[0].id, c.id, ts[1].id, ts[2].id])
        XCTAssertEqual(l.activeID, c.id)
    }
    func testRemoveActiveActivatesBelow() {
        var (l, ts) = list(3)
        XCTAssertEqual(l.remove(ts[0].id), ts[1].id)
        XCTAssertEqual(l.activeID, ts[1].id)
    }
    func testRemoveLastActiveActivatesAbove() {
        var (l, ts) = list(3)
        l.activate(ts[2].id)
        XCTAssertEqual(l.remove(ts[2].id), ts[1].id)
        XCTAssertEqual(l.activeID, ts[1].id)
    }
    func testRemoveBackgroundKeepsActive() {
        var (l, ts) = list(3)
        XCTAssertNil(l.remove(ts[1].id))
        XCTAssertEqual(l.activeID, ts[0].id)
        XCTAssertEqual(l.items.count, 2)
    }
    func testRemoveOnlyTab() {
        var (l, ts) = list(1)
        XCTAssertNil(l.remove(ts[0].id))
        XCTAssertTrue(l.items.isEmpty)
        XCTAssertNil(l.activeID)
    }
    func testNextPreviousWrap() {
        let (l, ts) = list(3)
        XCTAssertEqual(l.next(after: ts[0].id), ts[1].id)
        XCTAssertEqual(l.next(after: ts[2].id), ts[0].id)
        XCTAssertEqual(l.previous(before: ts[1].id), ts[0].id)
        XCTAssertEqual(l.previous(before: ts[0].id), ts[2].id)
        XCTAssertNil(l.next(after: TabID(raw: UUID())))
    }
    func testDisplayTitle() {
        var l = TabList()
        let blank = tab(1, url: "about:blank", title: "ignored")
        let empty = tab(2, url: "", title: "")
        let titled = tab(3, url: "https://www.example.com/a", title: "Hello")
        let hostOnly = tab(4, url: "https://www.example.com/a", title: "")
        for t in [blank, empty, titled, hostOnly] { l.insert(t, after: nil, activate: false) }
        XCTAssertEqual(l.displayTitle(of: blank.id), "New Tab")
        XCTAssertEqual(l.displayTitle(of: empty.id), "New Tab")
        XCTAssertEqual(l.displayTitle(of: titled.id), "Hello")
        XCTAssertEqual(l.displayTitle(of: hostOnly.id), "example.com")
    }

    func testInsertRejectsDuplicateID() {
        var (l, ts) = list(2)
        let dup = TabItem(id: ts[0].id, engineID: 99, url: "x", title: "x", isLoading: false)
        XCTAssertFalse(l.insert(dup, after: nil, activate: true))
        XCTAssertEqual(l.items.map(\.engineID), [0, 1])
        XCTAssertEqual(l.activeID, ts[0].id)  // the rejected insert did not activate
        XCTAssertTrue(l.insert(tab(7), after: nil, activate: false))
    }
    func testRestoreInitRoundTrip() {
        let (l, ts) = list(3)
        let back = TabList(items: l.items, activeID: ts[2].id)
        XCTAssertEqual(back?.items, l.items)
        XCTAssertEqual(back?.activeID, ts[2].id)
        XCTAssertNil(TabList(items: [], activeID: nil)?.activeID)
        XCTAssertEqual(TabList(items: l.items, activeID: nil)?.activeID, nil)
    }
    func testRestoreInitRejectsBadInput() {
        let (l, _) = list(2)
        XCTAssertNil(TabList(items: l.items, activeID: TabID()))          // active id not in the items
        XCTAssertNil(TabList(items: [], activeID: TabID()))
        XCTAssertNil(TabList(items: l.items + [l.items[0]], activeID: nil))  // duplicate id
    }
    func testMove() {
        var (l, ts) = list(4)
        l.move(ts[0].id, to: 2)
        XCTAssertEqual(l.items.map(\.id), [ts[1].id, ts[2].id, ts[0].id, ts[3].id])
        l.move(ts[3].id, to: 0)
        XCTAssertEqual(l.items.map(\.id), [ts[3].id, ts[1].id, ts[2].id, ts[0].id])
        l.move(ts[1].id, to: 99)  // clamped to the end
        XCTAssertEqual(l.items.last?.id, ts[1].id)
        l.move(ts[1].id, to: -5)  // clamped to the start
        XCTAssertEqual(l.items.first?.id, ts[1].id)
        XCTAssertEqual(l.activeID, ts[0].id)  // moving never changes the active tab
        let before = l
        l.move(TabID(), to: 0)  // unknown id: no change
        XCTAssertEqual(l, before)
    }
    func testUnknownOpenerAppends() {
        var (l, ts) = list(2)
        let c = tab(5)
        XCTAssertTrue(l.insert(c, after: TabID(), activate: false))
        XCTAssertEqual(l.items.map(\.id), [ts[0].id, ts[1].id, c.id])
    }
    func testActivateUnknownIsNoOp() {
        var (l, ts) = list(2)
        l.activate(TabID())
        XCTAssertEqual(l.activeID, ts[0].id)
    }
    func testRemoveUnknownIsNoOp() {
        var (l, _) = list(2)
        let before = l
        XCTAssertNil(l.remove(TabID()))
        XCTAssertEqual(l, before)
    }
}
