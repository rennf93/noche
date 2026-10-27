import XCTest
import GRDB
@testable import NocheStore

final class PermissionStoreTests: XCTestCase {
    func testV3OnV2KeepsDataAndAddsRoots() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("v2-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let pool = try DatabasePool(path: file.path)
        try Schema.migrator.migrate(pool, upTo: "v2")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt) VALUES (?, 'Default', 'Default', 1, 1, 1)",
                           arguments: [Schema.defaultProfileID])
            try db.execute(sql: "INSERT INTO page (id, profileId, url, host, lastVisitAt, createdAt, updatedAt) VALUES ('p', ?, 'https://a.com/', 'a.com', 1, 1, 1)",
                           arguments: [Schema.defaultProfileID])
        }
        try pool.close()
        let store = try Store.open(at: file)
        try store.db.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"), ["v1", "v2", "v3", "v4", "v5-page-title-folded", "v6-sidebar-depth"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM page"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sitePermission"), 0)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT title FROM bookmark WHERE profileId = ? AND parentId IS NULL ORDER BY position",
                                               arguments: [Schema.defaultProfileID]), ["Bookmarks Bar", "Other Bookmarks"])
        }
    }

    func testDecisionsPerOriginAndKind() throws {
        let s = try Store.inMemory()
        XCTAssertNil(try s.permission(origin: "https://a.com", kind: "geolocation"))
        try s.setPermission(origin: "https://a.com", kind: "geolocation", decision: .allow)
        try s.setPermission(origin: "https://a.com:8443", kind: "geolocation", decision: .block)
        try s.setPermission(origin: "http://a.com", kind: "geolocation", decision: .block)
        try s.setPermission(origin: "https://a.com", kind: "camera", decision: .block)
        XCTAssertEqual(try s.permission(origin: "https://a.com", kind: "geolocation"), .allow)
        XCTAssertEqual(try s.permission(origin: "https://a.com:8443", kind: "geolocation"), .block)
        XCTAssertEqual(try s.permission(origin: "http://a.com", kind: "geolocation"), .block)
        XCTAssertEqual(try s.permission(origin: "https://a.com", kind: "camera"), .block)
        XCTAssertEqual(try s.permissions().count, 4)
    }

    func testReplaceTombstonesOldRow() throws {
        let s = try Store.inMemory()
        try s.setPermission(origin: "https://a.com", kind: "geolocation", decision: .allow)
        try s.setPermission(origin: "https://a.com", kind: "geolocation", decision: .block)
        XCTAssertEqual(try s.permission(origin: "https://a.com", kind: "geolocation"), .block)
        XCTAssertEqual(try s.permissions().count, 1)
        try s.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sitePermission"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sitePermission WHERE deletedAt IS NOT NULL"), 1)
        }
    }

    func testRemoveTombstonedDecisionIgnored() throws {
        let s = try Store.inMemory()
        try s.setPermission(origin: "https://a.com", kind: "geolocation", decision: .allow)
        try s.removePermission(origin: "https://a.com", kind: "geolocation")
        XCTAssertNil(try s.permission(origin: "https://a.com", kind: "geolocation"))
        XCTAssertTrue(try s.permissions().isEmpty)
        try s.setPermission(origin: "https://a.com", kind: "geolocation", decision: .block)
        XCTAssertEqual(try s.permission(origin: "https://a.com", kind: "geolocation"), .block)
    }
}
