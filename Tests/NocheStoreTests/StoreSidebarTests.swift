import XCTest
import GRDB
import NocheCore
@testable import NocheStore

/// v6-sidebar-depth: pinned tabs, groups and the archive in the store (note 4.2 "store", 5.1 "store"; amendments T1.2, T1.4).
final class StoreSidebarTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var t = 2_000_000.0
        func tick() -> Date { t += 1; return Date(timeIntervalSince1970: t) }
        var now: Date { Date(timeIntervalSince1970: t) }
    }
    private let day: TimeInterval = 86_400

    private func makeStore(_ c: Clock = Clock()) throws -> Store { try Store.inMemory(now: { c.tick() }) }

    private func tab(_ n: Int, title: String = "") -> TabItem {
        TabItem(id: TabID(), engineID: nil, url: "https://e\(n).example/", title: title.isEmpty ? "t\(n)" : title, isLoading: false,
                lastActiveAt: Date(timeIntervalSince1970: 1_500_000 + Double(n)))
    }

    private func snapshot(_ l: TabList, id: UUID = UUID()) -> WindowSnapshot {
        WindowSnapshot(id: id, frame: CGRect(x: 1, y: 2, width: 800, height: 600), isFullScreen: false, isZoomed: false, sidebarWidth: 197,
                       sidebarMode: "shown", tabs: l.items, selectedTabID: l.activeID, zOrder: 0, tabMeta: [:],
                       groups: l.groups, topOrder: l.topOrder, dayOrder: l.dayOrder)
    }

    /// 2 grid pins, 1 loose pinned row, a pinned group with 2 tabs, a day group with 1 tab, 3 day tabs mixed with the day group.
    private func structured() -> TabList {
        var l = TabList()
        let ts = (0..<10).map { tab($0) }
        for t in ts { l.insertNew(t, opener: nil, addToTop: false, activate: t.id == ts[0].id) }
        let id = ts.map(\.id)
        l.pin(id[0]); l.pin(id[1])
        l.move(id[2], to: .persistent(0))
        let pg = l.createGroup(with: id[3], name: "Pinned group")!
        l.pinGroup(pg)
        l.setGroup(id[4], pg)
        l.collapse(pg)
        let dg = l.createGroup(with: id[5], name: "Day group")!
        l.setGroup(id[6], dg)
        l.move(id[8], to: .day(0))      // a day tab above the day group
        l.moveGroup(dg, to: .day(2))   // and the group between day tabs
        l.renameGroup(dg, "Day group")
        return l
    }

    func testMigrationAddsTheColumnsAndKeepsV5Rows() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("v5-restore-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + s) } }
        let pool = try DatabasePool(path: file.path)
        try Schema.migrator.migrate(pool, upTo: "v5-page-title-folded")
        let win = UUID().uuidString, t = UUID().uuidString
        try pool.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt) VALUES (?, 'Default', 'Default', 1, 1, 1)", arguments: [Schema.defaultProfileID])
            try db.execute(sql: "INSERT INTO window (id, profileId, createdAt, updatedAt) VALUES (?, ?, 1, 1)", arguments: [win, Schema.defaultProfileID])
            try db.execute(sql: "INSERT INTO tab (id, windowId, url, title, position, lastActiveAt, createdAt, updatedAt) VALUES (?, ?, 'https://old.example/', 'old', 0, 77, 1, 1)", arguments: [t, win])
            try db.execute(sql: "INSERT INTO tabGroup (id, windowId, name, position, createdAt, updatedAt) VALUES (?, ?, 'g', 0, 1, 1)", arguments: [UUID().uuidString, win])
        }
        try Schema.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last, "v6-sidebar-depth")
            let row = try Row.fetchOne(db, sql: "SELECT url, inGrid, customTitle, customIcon, isPinned, lastActiveAt FROM tab WHERE id = ?", arguments: [t])
            XCTAssertEqual(row?["url"] as String?, "https://old.example/")
            XCTAssertEqual(row?["inGrid"] as Int?, 0)
            XCTAssertNil(row?["customTitle"] as String?)
            XCTAssertNil(row?["customIcon"] as String?)
            XCTAssertEqual(row?["lastActiveAt"] as Double?, 77)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isPinned FROM tabGroup"), 0)
        }
    }

    func testRoundTripKeepsEveryPlacementField() throws {
        var l = structured()
        let any = l.items[4].id
        l.setCustomization(any, title: "Mine", icon: "star")
        let store = try makeStore()
        let snap = snapshot(l)
        try store.save(snap)
        let back = try XCTUnwrap(store.loadWindows().first)
        XCTAssertEqual(back.tabs, l.items)
        XCTAssertEqual(Set(back.groups.map(\.id)), Set(l.groups.map(\.id)))
        for g in l.groups { XCTAssertEqual(back.groups.first { $0.id == g.id }, g) }
        XCTAssertEqual(back.topOrder, l.topOrder)
        XCTAssertEqual(back.dayOrder, l.dayOrder)
        let rebuilt = TabList(items: back.tabs, groups: back.groups, topOrder: back.topOrder, dayOrder: back.dayOrder, activeID: back.selectedTabID)
        XCTAssertEqual(rebuilt?.layout(), l.layout())
        XCTAssertTrue(back.tabs.allSatisfy { $0.engineID == nil })  // runtime-only: a restored tab has no engine tab yet
    }

    func testPositionsAreWithinTheContainer() throws {
        let l = structured()
        let store = try makeStore()
        let snap = snapshot(l)
        try store.save(snap)
        try store.db.read { db in
            func pos(_ id: TabID) throws -> Int { try Int.fetchOne(db, sql: "SELECT position FROM tab WHERE id = ?", arguments: [id.raw.uuidString])! }
            func gpos(_ id: GroupID) throws -> Int { try Int.fetchOne(db, sql: "SELECT position FROM tabGroup WHERE id = ?", arguments: [id.raw.uuidString])! }
            let grid = l.items.filter { $0.isPinned && $0.inGrid }
            XCTAssertEqual(try grid.map { try pos($0.id) }, [0, 1])
            for (i, r) in l.topOrder.enumerated() {
                if case .tab(let t) = r { XCTAssertEqual(try pos(t), i) } else if case .group(let g) = r { XCTAssertEqual(try gpos(g), i) }
            }
            for (i, r) in l.dayOrder.enumerated() {
                if case .tab(let t) = r { XCTAssertEqual(try pos(t), i) } else if case .group(let g) = r { XCTAssertEqual(try gpos(g), i) }
            }
            for g in l.groups {
                let kids = l.items.filter { $0.groupID == g.id }
                XCTAssertEqual(try kids.map { try pos($0.id) }, Array(0..<kids.count))
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tabGroup WHERE isPinned = 1"), 1)
        }
    }

    func testDroppedGroupIsTombstonedAndItsTabsKeepTheirRows() throws {
        var l = structured()
        let store = try makeStore()
        let win = UUID()
        try store.save(snapshot(l, id: win))
        let g = l.groups[1].id
        l.deleteGroup(g, closeTabs: false)
        try store.save(snapshot(l, id: win))
        let back = try XCTUnwrap(store.loadWindows().first)
        XCTAssertEqual(back.groups.count, 1)
        XCTAssertEqual(back.tabs.count, 10)
        XCTAssertTrue(back.tabs.allSatisfy { $0.groupID != g })
        try store.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT count(*) FROM tabGroup WHERE deletedAt IS NOT NULL"), 1) }
    }

    func testASnapshotNamingAnUnknownGroupDoesNotBreakTheForeignKey() throws {
        var a = tab(1)
        a.groupID = GroupID()
        let store = try makeStore()
        let snap = WindowSnapshot(id: UUID(), frame: .zero, isFullScreen: false, isZoomed: false, sidebarWidth: nil, sidebarMode: "shown",
                                  tabs: [a], selectedTabID: nil, zOrder: 0, tabMeta: [:])
        XCTAssertNoThrow(try store.save(snap))
        XCTAssertNil(try store.loadWindows().first?.tabs.first?.groupID)
    }

    // MARK: archive

    func testArchiveHidesFromTheWindowAndRestoreBringsItBack() throws {
        let c = Clock()
        let store = try makeStore(c)
        var l = structured()
        let win = UUID()
        try store.save(snapshot(l, id: win))
        let victim = l.items.first { $0.groupID == l.groups[1].id }!.id
        let at = Date(timeIntervalSince1970: 1_900_000)
        try store.archive(ids: [victim], at: at)
        l.archive([victim], now: at)
        try store.save(snapshot(l, id: win))  // a later save neither revives nor tombstones it
        XCTAssertEqual(try store.loadWindows().first?.tabs.count, 9)
        let archived = try store.archivedTabs(matching: "")
        XCTAssertEqual(archived.map(\.tab.id), [victim])
        XCTAssertEqual(archived[0].tab.archivedAt, at)
        XCTAssertEqual(archived[0].tab.groupID, l.groups[1].id)  // the group is kept
        XCTAssertEqual(archived[0].windowID, win)
        try store.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT deletedAt IS NULL FROM tab WHERE id = ?", arguments: [victim.raw.uuidString]), 1) }
        let back = try XCTUnwrap(store.restoreArchived(id: victim))
        XCTAssertEqual(back.tab.id, victim)
        XCTAssertNil(back.tab.archivedAt)
        XCTAssertEqual(try store.archivedTabs(matching: ""), [])
        XCTAssertNil(try store.restoreArchived(id: victim))  // not archived any more
        XCTAssertNil(try store.restoreArchived(id: TabID()))
    }

    func testAResaveOfARestoredTabClearsArchivedAt() throws {
        let store = try makeStore()
        var l = TabList()
        let a = tab(1), b = tab(2)
        l.insertNew(a, opener: nil, addToTop: false, activate: true)
        l.insertNew(b, opener: nil, addToTop: false, activate: false)
        let win = UUID()
        try store.save(snapshot(l, id: win))
        try store.archive(ids: [b.id], at: Date(timeIntervalSince1970: 1_900_000))
        XCTAssertEqual(try store.loadWindows().first?.tabs.map(\.id), [a.id])
        try store.save(snapshot(l, id: win))  // a stale snapshot that still holds b is the truth for live tabs
        XCTAssertEqual(try store.loadWindows().first?.tabs.map(\.id), [a.id, b.id])
        XCTAssertEqual(try store.archivedTabs(matching: ""), [])
    }

    func testArchivedSearchRanksAndFiltersLikeTheList() throws {
        let store = try makeStore()
        var l = TabList()
        let a = tab(1, title: "my github notes"), b = tab(2, title: "GitHub"), c = tab(3, title: "Other")
        for t in [a, b, c] { l.insertNew(t, opener: nil, addToTop: false, activate: false) }
        try store.save(snapshot(l))
        try store.archive(ids: [a.id, b.id, c.id], at: Date(timeIntervalSince1970: 1_900_000))
        XCTAssertEqual(try store.archivedTabs(matching: "github").map(\.tab.id), [b.id, a.id])
        XCTAssertEqual(try store.archivedTabs(matching: "").count, 3)
        XCTAssertEqual(try store.archivedTabs(matching: "zzz"), [])
    }

    func testArchiveIgnoresClosedAndUnknownRows() throws {
        let store = try makeStore()
        var l = TabList()
        let a = tab(1)
        l.insertNew(a, opener: nil, addToTop: false, activate: true)
        let win = UUID()
        try store.save(snapshot(l, id: win))
        try store.recordClosed(a, windowID: win, index: 0)
        try store.archive(ids: [a.id, TabID()], at: Date())
        XCTAssertEqual(try store.archivedTabs(matching: ""), [])  // a closed-list row is not archived
        XCTAssertTrue(try store.hasClosedTabs())
    }

    func testRetentionTombstonesAfterThirtyDays() throws {
        let c = Clock()
        let store = try makeStore(c)
        var l = TabList()
        let old = tab(1), edge = tab(2), young = tab(3)
        for t in [old, edge, young] { l.insertNew(t, opener: nil, addToTop: false, activate: false) }
        try store.save(snapshot(l))
        let now = Date(timeIntervalSince1970: 3_000_000)
        c.t = now.timeIntervalSince1970
        try store.archive(ids: [old.id], at: now.addingTimeInterval(-30 * day - 10))
        try store.archive(ids: [edge.id], at: now.addingTimeInterval(-30 * day + 10))
        try store.archive(ids: [young.id], at: now.addingTimeInterval(-1 * day))
        XCTAssertEqual(try store.tombstoneExpiredArchive(), 1)
        XCTAssertEqual(Set(try store.archivedTabs(matching: "").map(\.tab.id)), [edge.id, young.id])
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE id = ? AND deletedAt IS NOT NULL", arguments: [old.id.raw.uuidString]), 1)
        }
        XCTAssertEqual(try store.tombstoneExpiredArchive(), 0)
        XCTAssertNil(try store.restoreArchived(id: old.id))  // a tombstoned row is not restorable
    }

    // MARK: closed tabs keep their placement

    func testClosedTabKeepsPinGroupAndCustomTitle() throws {
        let store = try makeStore()
        var l = structured()
        let any = l.items.first { $0.groupID == l.groups[0].id }!.id
        l.setCustomization(any, title: "Custom", icon: "bolt")
        let win = UUID()
        try store.save(snapshot(l, id: win))
        let grouped = l.items.first { $0.id == any }!
        let pinned = l.items.first { $0.isPinned && $0.inGrid }!
        try store.recordClosed(grouped, windowID: win, index: 3)
        try store.recordClosed(pinned, windowID: win, index: 0)
        let p = try XCTUnwrap(store.popLastClosed()).tab
        XCTAssertTrue(p.isPinned && p.inGrid)
        XCTAssertEqual(p.pinnedURL, pinned.pinnedURL)
        let g = try XCTUnwrap(store.popLastClosed()).tab
        XCTAssertEqual(g.groupID, grouped.groupID)
        XCTAssertEqual(g.customTitle, "Custom")
        XCTAssertEqual(g.customIcon, "bolt")
    }

    func testClosedTabWithAGroupTheStoreNeverSawStillRecords() throws {
        let store = try makeStore()
        var a = tab(1)
        a.groupID = GroupID()
        let win = UUID()
        try store.save(snapshot(TabList(), id: win))
        XCTAssertNoThrow(try store.recordClosed(a, windowID: win, index: 0))
        XCTAssertNil(try store.popLastClosed()?.tab.groupID)
    }
}
