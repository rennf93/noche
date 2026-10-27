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
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"), ["v1", "v2", "v3", "v4", "v5-page-title-folded", "v6-sidebar-depth"])
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

    func testTypedSchemeAndWwwAreIgnored() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://github.com/", title: "GitHub", typed: false, at: at(1))
        for typed in ["https://git", "http://git", "www.git", "https://www.git", "HTTPS://GIT", "git"] {
            XCTAssertEqual(try s.pageCandidates(prefix: typed).map(\.url), ["https://github.com/"], typed)
        }
        XCTAssertTrue(try s.pageCandidates(prefix: "https://zzz").isEmpty)
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

    func testTitleFoldedIsBackfilledAndFollowsTitleWrites() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("v4-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + s) } }
        let pool = try DatabasePool(path: file.path, configuration: { var c = Configuration(); c.prepareDatabase { $0.add(function: .lowercase) }; return c }())
        try Schema.migrator.migrate(pool, upTo: "v4")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt) VALUES (?, 'Default', 'Default', 1, 1, 1)", arguments: [Schema.defaultProfileID])
            try db.execute(sql: "INSERT INTO page (id, profileId, url, host, title, visitCount, lastVisitAt, createdAt, updatedAt) VALUES ('p', ?, 'https://a.com/', 'a.com', 'ÉLAN Vital', 1, 1, 1, 1)", arguments: [Schema.defaultProfileID])
        }
        try pool.close()
        let s = try Store.open(at: file)
        XCTAssertEqual(try s.pageCandidates(prefix: "vit").map(\.url), ["https://a.com/"])
        try s.updateTitle(url: "https://a.com/", title: "ПРИВЕТ Мир")
        XCTAssertTrue(try s.pageCandidates(prefix: "vit").isEmpty)
        XCTAssertEqual(try s.pageCandidates(prefix: "мир").count, 1)
        try s.recordVisit(url: "https://a.com/", title: "", typed: false, at: at(5))
        XCTAssertEqual(try s.pageCandidates(prefix: "мир").count, 1)  // an empty title keeps both columns
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

final class PageCandidatesBudgetTests: XCTestCase {
    /// 200,000 live pages in a temporary database (never the owner's profile): a typed prefix is one read, newest 50 of the matches.
    func testPageCandidatesOver200kPagesStayInBudget() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + s) } }
        let store = try Store.open(at: file)
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima"]
        try store.db.write { db in
            let st = try db.makeStatement(sql: """
                INSERT INTO page (id, profileId, url, host, title, titleFolded, visitCount, typedCount, lastVisitAt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, 1, 0, ?, 1, 1)
                """)
            for i in 0..<200_000 {
                let title = "Élan \(words[i % 12]) \(words[(i / 12) % 12]) \(i)"
                try st.execute(arguments: ["id\(i)", Schema.defaultProfileID, "https://site\(i % 5000).example.com/p/\(i)", "site\(i % 5000).example.com",
                                           title, title.lowercased(), Double(i)])
            }
        }
        // Before the folded column: 0.58 s for a miss (a Swift closure per row), 0.0005 to 0.002 s for a common prefix. After: 0.097 s for a miss. Budget: about 3x that.
        var worst = 0.0
        for (q, want) in [("zq", 0), ("19999", 11), ("golf", 50), ("site42", 50), ("élan", 50)] {  // no match (full scan), rare title word, title word, host prefix, many matches
            let t0 = Date()
            let rows = try store.pageCandidates(prefix: q)
            worst = max(worst, Date().timeIntervalSince(t0))
            XCTAssertEqual(rows.count, want, q)
        }
        XCTAssertLessThan(worst, 0.3)
    }
}
