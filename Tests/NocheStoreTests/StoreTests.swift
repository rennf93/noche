import XCTest
import GRDB
import NocheCore
@testable import NocheStore

final class StoreTests: XCTestCase {
    /// A clock that moves one second per call, so "newest first" never ties.
    private final class Clock: @unchecked Sendable {
        private var t = 1_000_000.0
        func tick() -> Date { t += 1; return Date(timeIntervalSince1970: t) }
    }

    private func makeStore() throws -> Store { let c = Clock(); return try Store.inMemory(now: { c.tick() }) }

    private func tab(_ url: String = "https://example.com", title: String = "T") -> TabItem {
        TabItem(id: TabID(), engineID: 0, url: url, title: title, isLoading: false)
    }

    private func snapshot(_ tabs: [TabItem], id: UUID = UUID(), selected: TabID? = nil) -> WindowSnapshot {
        WindowSnapshot(id: id, frame: CGRect(x: 10, y: 20, width: 800, height: 600), isFullScreen: false, isZoomed: true,
                       sidebarWidth: 240, sidebarMode: "shown", tabs: tabs, selectedTabID: selected, zOrder: 0, tabMeta: [:])
    }

    private func positions(_ store: Store, window: UUID) throws -> [Int] {
        try store.db.read { db in
            try Int.fetchAll(db, sql: "SELECT position FROM tab WHERE windowId = ? AND deletedAt IS NULL AND closedAt IS NULL ORDER BY position",
                             arguments: [window.uuidString])
        }
    }

    // 1
    func testMigrationCreatesTablesAndIsIdempotent() throws {
        let store = try makeStore()
        try Schema.migrator.migrate(store.db)
        try store.db.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            for t in ["profile", "space", "window", "tabGroup", "tab", "setting", "grdb_migrations"] { XCTAssertTrue(tables.contains(t), t) }
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"), ["v1", "v2", "v3"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM profile"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM space"), 1)
        }
    }

    // 2
    func testRoundTripWithFiveTabsAndMeta() throws {
        let store = try makeStore()
        let tabs = (0..<5).map { tab("https://e\($0).com", title: "t\($0)") }
        var snap = snapshot(tabs, selected: tabs[3].id)
        snap.zOrder = 2
        snap.tabMeta = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($1.id, TabMeta(faviconURL: $0 % 2 == 0 ? "https://e\($0).com/f.ico" : nil, lastActiveAt: Date(timeIntervalSince1970: 5_000 + Double($0))))
        })
        try store.save(snap)
        XCTAssertEqual(try store.loadWindows(), [snap])
        let list = TabList(items: tabs, activeID: tabs[3].id)
        let loaded = try store.loadWindows()[0]
        XCTAssertEqual(TabList(items: loaded.tabs, activeID: loaded.selectedTabID), list)
    }

    func testMissingTabMetaDefaultsToSaveTime() throws {
        let store = try makeStore()
        let t = tab()
        try store.save(snapshot([t]))
        let meta = try store.loadWindows()[0].tabMeta[t.id]
        XCTAssertNil(meta?.faviconURL)
        XCTAssertGreaterThan(meta?.lastActiveAt.timeIntervalSince1970 ?? 0, 1_000_000)
    }

    func testWindowsLoadByZOrder() throws {
        let store = try makeStore()
        var a = snapshot([tab()]); a.zOrder = 1
        var b = snapshot([tab()]); b.zOrder = 0
        try store.save(a); try store.save(b)
        XCTAssertEqual(try store.loadWindows().map(\.id), [b.id, a.id])
    }

    // 3
    func testTombstonesAreHiddenButKept() throws {
        let store = try makeStore()
        let tabs = (0..<3).map { _ in tab() }
        let snap = snapshot(tabs)
        try store.save(snap)
        try store.save(snapshot(Array(tabs[0..<2]), id: snap.id))
        XCTAssertEqual(try store.loadWindows()[0].tabs.count, 2)
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tab"), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE id = ? AND deletedAt IS NOT NULL", arguments: [tabs[2].id.raw.uuidString]), 1)
        }
        try store.removeWindow(snap.id)
        XCTAssertEqual(try store.loadWindows(), [])
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM window WHERE deletedAt IS NOT NULL"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE deletedAt IS NULL"), 0)
        }
    }

    func testTombstonedClosedTabIsNotPoppableAndRecordClosedRevivesIt() throws {
        let store = try makeStore()
        let tabs = (0..<3).map { _ in tab() }
        let snap = snapshot(tabs)
        try store.save(snap)
        try store.save(snapshot(Array(tabs[0..<2]), id: snap.id))   // tab 2 tombstoned by the save
        XCTAssertFalse(try store.hasClosedTabs())
        try store.recordClosed(tabs[2], windowID: snap.id, index: 2)  // arrives after the save
        XCTAssertTrue(try store.hasClosedTabs())
        XCTAssertEqual(try store.popLastClosed()?.tab.id, tabs[2].id)
    }

    func testLiveHelperFiltersTombstones() throws {
        let store = try makeStore()
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value, updatedAt, deletedAt) VALUES ('a','1',0,NULL),('b','2',0,5)")
            XCTAssertEqual(try SettingRow.all().live().fetchCount(db), 1)
            XCTAssertEqual(try SettingRow.all().fetchCount(db), 2)
        }
        XCTAssertNil(try store.setting("b"))
        XCTAssertEqual(try store.setting("a"), "1")
    }

    // 4
    func testRecordClosedPopsNewestFirstAndClears() throws {
        let store = try makeStore()
        let tabs = (0..<3).map { tab("https://e\($0).com") }
        let snap = snapshot(tabs)
        try store.save(snap)
        try store.recordClosed(tabs[0], windowID: snap.id, index: 0)
        try store.recordClosed(tabs[1], windowID: snap.id, index: 1)
        let first = try XCTUnwrap(store.popLastClosed())
        XCTAssertEqual(first.tab.id, tabs[1].id)
        XCTAssertEqual(first.windowID, snap.id)
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.tab.engineID, 0)
        XCTAssertEqual(try store.popLastClosed()?.tab.id, tabs[0].id)
        XCTAssertNil(try store.popLastClosed())
        XCTAssertFalse(try store.hasClosedTabs())
    }

    func testClosedListCapsAtTwentyFive() throws {
        let store = try makeStore()
        let snap = snapshot([tab()])
        try store.save(snap)
        let closed = (0..<26).map { tab("https://e\($0).com") }
        for (i, t) in closed.enumerated() { try store.recordClosed(t, windowID: snap.id, index: i) }
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE closedAt IS NOT NULL AND deletedAt IS NULL"), 25)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM tab WHERE id = ?", arguments: [closed[0].id.raw.uuidString]), 1)
        }
    }

    func testBlankAndEmptyAreNotRecorded() throws {
        let store = try makeStore()
        let snap = snapshot([tab()])
        try store.save(snap)
        try store.recordClosed(tab("about:blank"), windowID: snap.id, index: 0)
        try store.recordClosed(tab(""), windowID: snap.id, index: 0)
        XCTAssertFalse(try store.hasClosedTabs())
    }

    // 5
    func testPositionsStayContiguous() throws {
        let store = try makeStore()
        var list = TabList()
        let a = tab(), b = tab(), c = tab(), d = tab()
        for t in [a, b, c] { list.insert(t, after: nil, activate: false) }
        let win = UUID()
        try store.save(snapshot(list.items, id: win))
        list.insert(d, after: a.id, activate: true)
        try store.save(snapshot(list.items, id: win, selected: d.id))
        XCTAssertEqual(try positions(store, window: win), [0, 1, 2, 3])
        XCTAssertEqual(try store.loadWindows()[0].tabs.map(\.id), [a.id, d.id, b.id, c.id])
        _ = list.remove(b.id)
        try store.save(snapshot(list.items, id: win))
        XCTAssertEqual(try positions(store, window: win), [0, 1, 2])
        XCTAssertEqual(try store.loadWindows()[0].tabs.map(\.id), [a.id, d.id, c.id])
    }

    func testSettings() throws {
        let store = try makeStore()
        XCTAssertNil(try store.setting("quitBehavior"))
        try store.setSetting("quitBehavior", "preserve")
        try store.setSetting("quitBehavior", "close")
        XCTAssertEqual(try store.setting("quitBehavior"), "close")
    }

    // 6
    func testDebouncerCoalescesAndCaps() {
        var t = Date(timeIntervalSince1970: 0)
        var d = Debouncer(now: { t })
        XCTAssertFalse(d.due())
        for _ in 0..<20 { d.event(); t += 0.01 }
        XCTAssertFalse(d.due())
        t += 0.25
        XCTAssertTrue(d.due())
        d.fired()
        XCTAssertFalse(d.due())
        // constant events every 100 ms never go quiet, so only the cap fires
        t = Date(timeIntervalSince1970: 100)
        var fired = 0.0
        for _ in 0..<30 {
            d.event()
            if d.due() { fired = t.timeIntervalSince1970 - 100; break }
            t += 0.1
        }
        XCTAssertEqual(fired, 2.0, accuracy: 0.11)
    }

    // 7
    func testCorruptFileIsQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noche-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("noche.sqlite")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: file)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("noche.sqlite-wal"))
        let store = try Store.open(at: file)
        XCTAssertEqual(try store.loadWindows(), [])
        try store.save(snapshot([tab()]))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let main = try XCTUnwrap(names.first { $0.hasPrefix("noche.sqlite.corrupt-") })
        let suffix = String(main.dropFirst("noche.sqlite".count))
        XCTAssertTrue(names.contains("noche.sqlite-wal" + suffix), "the stale -wal moves with the same suffix")
        // SQLite itself may empty a stale -wal while failing to open the garbage db, so only the move is asserted here
        // (the same-second test checks that quarantined bytes are preserved); the new store's own -wal is not the stale one
        let wal = dir.appendingPathComponent("noche.sqlite-wal")
        XCTAssertNotEqual(try? Data(contentsOf: wal), Data("junk".utf8))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noche-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTwoQuarantinesInTheSameSecondBothSucceed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("noche.sqlite")
        for round in 0..<2 {
            for ext in ["", "-wal", "-shm"] { try Data("r\(round)".utf8).write(to: URL(fileURLWithPath: file.path + ext)) }
            try Store.quarantine(file)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("noche.sqlite.corrupt-") }.count, 2)
        XCTAssertEqual(names.count, 6)
        XCTAssertFalse(names.contains("noche.sqlite"))
        let wals = try names.filter { $0.hasPrefix("noche.sqlite-wal.corrupt-") }.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        XCTAssertEqual(Set(wals), [Data("r0".utf8), Data("r1".utf8)])
    }

    func testQuarantineMoveFailureIsThrown() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("noche.sqlite")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try Store.quarantine(file)) { XCTAssertTrue($0 is Store.QuarantineError) }
    }

    func testClassifier() {
        XCTAssertTrue(Store.isCorruption(DatabaseError(resultCode: .SQLITE_NOTADB)))
        XCTAssertTrue(Store.isCorruption(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        XCTAssertTrue(Store.isCorruption(DatabaseError(resultCode: ResultCode(rawValue: 11 | (1 << 8)))))  // CORRUPT_VTAB, extended
        for code in [ResultCode.SQLITE_BUSY, .SQLITE_FULL, .SQLITE_READONLY, .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_ERROR] {
            XCTAssertFalse(Store.isCorruption(DatabaseError(resultCode: code)), "\(code)")
        }
        XCTAssertFalse(Store.isCorruption(CocoaError(.fileReadNoPermission)))
    }

    func testFailedQuickCheckIsQuarantined() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("noche.sqlite")
        do {
            let store = try Store.open(at: file)
            for i in 0..<300 {
                try store.save(snapshot((0..<5).map { tab("https://example.com/\(i)/\($0)", title: String(repeating: "t", count: 200)) }))
            }
        }
        var bytes = try Data(contentsOf: file)
        XCTAssertGreaterThan(bytes.count, 4096 * 6)
        // wreck a page body in the middle (the header stays intact, so the file still opens)
        let mid = (bytes.count / 4096 / 2) * 4096
        for i in (mid + 100)..<(mid + 3000) { bytes[i] = 0xFF }
        try bytes.write(to: file)
        let store = try Store.open(at: file)
        XCTAssertEqual(try store.loadWindows(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("noche.sqlite.corrupt-") }.count, 1)
    }

    func testNonCorruptionOpenErrorIsRethrownAndFileUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("noche.sqlite")
        try Store.open(at: file).save(snapshot([tab()]))
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try Store.open(at: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("corrupt") }, [])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testPopSkipsAndTombstonesMalformedClosedRow() throws {
        let store = try makeStore()
        let good = tab("https://good.com")
        let snap = snapshot([tab()])
        try store.save(snap)
        try store.recordClosed(good, windowID: snap.id, index: 0)
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO tab (id, windowId, url, position, lastActiveAt, closedAt, closedIndex, closedWindowId, createdAt, updatedAt) VALUES ('not-a-uuid', ?, 'https://bad.com', 0, 0, 9999999999, 0, NULL, 0, 0)",
                           arguments: [snap.id.uuidString])
        }
        XCTAssertEqual(try store.popLastClosed()?.tab.id, good.id)
        XCTAssertFalse(try store.hasClosedTabs())
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM tab WHERE id = 'not-a-uuid'"), 1)
        }
    }

    func testSaveRevivesATabItStillHoldsAfterRecordClosed() throws {
        let store = try makeStore()
        let t = tab()
        let snap = snapshot([t])
        try store.save(snap)
        try store.recordClosed(t, windowID: snap.id, index: 0)
        XCTAssertTrue(try store.hasClosedTabs())
        try store.save(snap)   // stale snapshot: the contract says callers drop the tab first
        XCTAssertFalse(try store.hasClosedTabs())
        XCTAssertEqual(try store.loadWindows()[0].tabs.map(\.id), [t.id])
    }

    func testRecordClosedForUnsavedWindowThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.recordClosed(tab(), windowID: UUID(), index: 0))
    }

    func testFileStoreSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noche-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Store/noche.sqlite")
        let t = tab()
        var snap = snapshot([t], selected: t.id)
        snap.tabMeta = [t.id: TabMeta(faviconURL: nil, lastActiveAt: Date(timeIntervalSince1970: 7_000))]
        try Store.open(at: file).save(snap)
        XCTAssertEqual(try Store.open(at: file).loadWindows(), [snap])
    }
}
