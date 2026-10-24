import XCTest
import GRDB
import NocheCore
@testable import NocheStore

final class PageStoreTests: XCTestCase {
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    func testV2AppliesOnV1AndKeepsData() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let pool = try DatabasePool(path: file.path)
        try Schema.migrator.migrate(pool, upTo: "v1")
        try pool.write { try $0.execute(sql: "INSERT INTO setting (key, value, updatedAt) VALUES ('k', 'v', 1)") }
        try pool.close()
        let store = try Store.open(at: file)
        XCTAssertEqual(try store.setting("k"), "v")
        try store.db.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"), ["v1", "v2", "v3"])
            XCTAssertNotNil(try Int.fetchOne(db, sql: "SELECT count(*) FROM page"))
        }
    }

    func testRepeatVisitsAndTyped() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://Example.com/a", title: "A", typed: false, at: at(1))
        try s.recordVisit(url: "https://Example.com/a", title: "A", typed: true, at: at(2))
        let p = try XCTUnwrap(s.pageCandidates(prefix: "example").first)
        XCTAssertEqual(p.visitCount, 2)
        XCTAssertEqual(p.typedCount, 1)
        XCTAssertEqual(p.lastVisitAt, at(2))
        XCTAssertEqual(p.host, "example.com")
        try s.db.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT transition FROM visit ORDER BY visitedAt"), ["link", "typed"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM page"), 1)
        }
    }

    func testWwwStrippedFromHost() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://www.Foo.org/", title: "F", typed: false, at: at(1))
        XCTAssertEqual(try s.pageCandidates(prefix: "foo").first?.host, "foo.org")
    }

    func testNonWebSchemesNeverRecorded() throws {
        let s = try Store.inMemory()
        for u in ["about:blank", "file:///tmp/x", "chrome://settings", "data:text/html,hi", "javascript:alert(1)", "view-source:https://a.com", ""] {
            try s.recordVisit(url: u, title: "x", typed: true, at: at(1))
        }
        try s.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT count(*) FROM page"), 0) }
        try s.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT count(*) FROM visit"), 0) }
    }

    func testUpdateTitleOnlyLiveRow() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/", title: "Old", typed: false, at: at(1))
        try s.updateTitle(url: "https://a.com/", title: "New")
        XCTAssertEqual(try s.pageCandidates(prefix: "a.com").first?.title, "New")
        try s.db.write { try $0.execute(sql: "UPDATE page SET deletedAt = 5") }
        try s.updateTitle(url: "https://a.com/", title: "Zombie")
        try s.db.read { XCTAssertEqual(try String.fetchOne($0, sql: "SELECT title FROM page"), "New") }
    }

    func testTombstonedExcludedAndRevisitCreatesLiveRow() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: at(1))
        try s.db.write { try $0.execute(sql: "UPDATE page SET deletedAt = 5") }
        XCTAssertTrue(try s.pageCandidates(prefix: "a").isEmpty)
        XCTAssertTrue(try s.hostCandidates(prefix: "a").isEmpty)
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: at(9))
        XCTAssertEqual(try s.pageCandidates(prefix: "a").first?.visitCount, 1)
    }

    func testMatchesHostUrlWithoutSchemeAndTitleWord() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://www.example.com/docs", title: "Guide", typed: false, at: at(1))
        try s.recordVisit(url: "https://other.net/", title: "The Swift Book", typed: false, at: at(2))
        XCTAssertEqual(try s.pageCandidates(prefix: "exam").map(\.url), ["https://www.example.com/docs"])
        XCTAssertEqual(try s.pageCandidates(prefix: "example.com/do").map(\.url), ["https://www.example.com/docs"])
        XCTAssertEqual(try s.pageCandidates(prefix: "swi").map(\.url), ["https://other.net/"])
        XCTAssertEqual(try s.pageCandidates(prefix: "gui").map(\.url), ["https://www.example.com/docs"])
        try s.recordVisit(url: "https://ovalx.com/", title: "", typed: false, at: at(3))
        XCTAssertEqual(try s.pageCandidates(prefix: "o").map(\.url), ["https://ovalx.com/", "https://other.net/"])
        XCTAssertEqual(try s.pageCandidates(prefix: "o", limit: 1).count, 1)
    }

    func testLikeWildcardsAreEscaped() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/", title: "plain", typed: false, at: at(1))
        try s.recordVisit(url: "https://b.com/", title: "%off _b", typed: false, at: at(2))
        XCTAssertTrue(try s.pageCandidates(prefix: "%").count == 1)
        XCTAssertEqual(try s.pageCandidates(prefix: "_").count, 1)
        try s.recordVisit(url: "https://axb.com/", title: "z", typed: false, at: at(3))
        XCTAssertTrue(try s.pageCandidates(prefix: "a_b").isEmpty)
        XCTAssertTrue(try s.pageCandidates(prefix: "p%n").isEmpty)
        XCTAssertTrue(try s.pageCandidates(prefix: "\\").isEmpty)
    }

    func testNonAsciiTitlesMatchCaseInsensitively() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/", title: "Élan Vital", typed: false, at: at(1))
        try s.recordVisit(url: "https://b.com/", title: "Привет мир", typed: false, at: at(2))
        for q in ["él", "ÉL", "vit"] { XCTAssertEqual(try s.pageCandidates(prefix: q).map(\.url), ["https://a.com/"], q) }
        for q in ["прив", "ПРИВ", "мир"] { XCTAssertEqual(try s.pageCandidates(prefix: q).map(\.url), ["https://b.com/"], q) }
    }

    func testHostCandidatesGroupPerHost() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/1", title: "One", typed: true, at: at(1))
        try s.recordVisit(url: "https://a.com/2", title: "Two", typed: false, at: at(3))
        try s.recordVisit(url: "https://a.com/2", title: "Two", typed: false, at: at(4))
        try s.recordVisit(url: "https://b.com/", title: "B", typed: false, at: at(2))
        let h = try s.hostCandidates(prefix: "a")
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].host, "a.com")
        XCTAssertEqual(h[0].visitCount, 3)
        XCTAssertEqual(h[0].typedCount, 1)
        XCTAssertEqual(h[0].lastVisitAt, at(4))
    }
}
