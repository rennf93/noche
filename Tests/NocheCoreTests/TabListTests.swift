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
}
