import XCTest
import GRDB
@testable import NocheStore

final class BookmarkStoreTests: XCTestCase {
    private func make() throws -> (Store, Bookmark, Bookmark) {
        let s = try Store.inMemory()
        let r = try s.bookmarkRoots()
        return (s, r[0], r[1])
    }
    private func titles(_ s: Store, _ p: Bookmark) throws -> [String] { try s.bookmarkChildren(of: p.id).map(\.title) }
    private func dense(_ s: Store, _ p: Bookmark) throws {
        XCTAssertEqual(try s.bookmarkChildren(of: p.id).map(\.position), Array(0..<(try s.bookmarkChildren(of: p.id).count)))
    }

    func testRootsExistAndIdempotent() throws {
        let (s, bar, other) = try make()
        XCTAssertEqual([bar.title, other.title], ["Bookmarks Bar", "Other Bookmarks"])
        try s.ensureBookmarkRoots(profileId: Schema.defaultProfileID)
        XCTAssertEqual(try s.bookmarkRoots().count, 2)
        try s.db.write { try $0.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, createdAt, updatedAt) VALUES ('p2', 'P', 'P', 1, 1)") }
        try s.ensureBookmarkRoots(profileId: "p2")
        try s.ensureBookmarkRoots(profileId: "p2")
        try s.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT count(*) FROM bookmark WHERE profileId = 'p2'"), 2) }
        XCTAssertEqual(try s.bookmarkRoots().count, 2)
    }

    func testRootsImmutable() throws {
        let (s, bar, other) = try make()
        XCTAssertThrowsError(try s.deleteBookmark(id: bar.id)) { XCTAssertEqual($0 as? BookmarkError, .rootImmutable) }
        XCTAssertThrowsError(try s.renameBookmark(id: bar.id, title: "X")) { XCTAssertEqual($0 as? BookmarkError, .rootImmutable) }
        XCTAssertThrowsError(try s.moveBookmark(id: bar.id, toParent: other.id, index: nil)) { XCTAssertEqual($0 as? BookmarkError, .rootImmutable) }
        XCTAssertEqual(try s.bookmarkRoots().count, 2)
    }

    func testAddAtIndexAndEnd() throws {
        let (s, bar, _) = try make()
        _ = try s.addBookmark(title: "a", url: "https://a.com", parentId: bar.id)
        _ = try s.addBookmark(title: "c", url: "https://c.com", parentId: bar.id)
        _ = try s.addBookmark(title: "b", url: "https://b.com", parentId: bar.id, index: 1)
        _ = try s.addFolder(title: "f", parentId: bar.id, index: 0)
        XCTAssertEqual(try titles(s, bar), ["f", "a", "b", "c"])
        try dense(s, bar)
        XCTAssertEqual(try s.bookmarkChildren(of: bar.id)[0].kind, .folder)
    }

    func testMoveWithinAndAcrossParents() throws {
        let (s, bar, other) = try make()
        let a = try s.addBookmark(title: "a", url: "https://a.com", parentId: bar.id)
        _ = try s.addBookmark(title: "b", url: "https://b.com", parentId: bar.id)
        _ = try s.addBookmark(title: "c", url: "https://c.com", parentId: bar.id)
        try s.moveBookmark(id: a.id, toParent: bar.id, index: 2)
        XCTAssertEqual(try titles(s, bar), ["b", "c", "a"])
        try dense(s, bar)
        try s.moveBookmark(id: a.id, toParent: other.id, index: nil)
        XCTAssertEqual(try titles(s, bar), ["b", "c"])
        XCTAssertEqual(try titles(s, other), ["a"])
        try dense(s, bar)
        try dense(s, other)
    }

    func testMoveFolderIntoOwnDescendantRefused() throws {
        let (s, bar, _) = try make()
        let f = try s.addFolder(title: "f", parentId: bar.id)
        let g = try s.addFolder(title: "g", parentId: f.id)
        XCTAssertThrowsError(try s.moveBookmark(id: f.id, toParent: g.id, index: nil)) { XCTAssertEqual($0 as? BookmarkError, .cycle) }
        XCTAssertThrowsError(try s.moveBookmark(id: f.id, toParent: f.id, index: nil)) { XCTAssertEqual($0 as? BookmarkError, .cycle) }
        XCTAssertEqual(try titles(s, bar), ["f"])
    }

    func testOrphanUnderTombstonedFolderHidden() throws {
        let (s, bar, _) = try make()
        let f = try s.addFolder(title: "f", parentId: bar.id)
        let g = try s.addFolder(title: "g", parentId: f.id)
        _ = try s.addBookmark(title: "kid", url: "https://kid.com", parentId: g.id)
        try s.db.write { try $0.execute(sql: "UPDATE bookmark SET deletedAt = 5 WHERE id = ?", arguments: [f.id]) }
        XCTAssertNil(try s.bookmark(forURL: "https://kid.com"))
        XCTAssertTrue(try s.recentBookmarks().isEmpty)
        XCTAssertThrowsError(try s.bookmarkChildren(of: f.id)) { XCTAssertEqual($0 as? BookmarkError, .notFound) }
        // delete walks through an already tombstoned intermediate folder
        try s.db.write { try $0.execute(sql: "UPDATE bookmark SET deletedAt = NULL WHERE id = ?", arguments: [f.id]) }
        let h = try s.addFolder(title: "h", parentId: bar.id)
        let i = try s.addFolder(title: "i", parentId: h.id)
        _ = try s.addBookmark(title: "deep", url: "https://deep.com", parentId: i.id)
        try s.db.write { try $0.execute(sql: "UPDATE bookmark SET deletedAt = 5 WHERE id = ?", arguments: [i.id]) }
        try s.db.write { try $0.execute(sql: "UPDATE bookmark SET deletedAt = NULL WHERE url = 'https://deep.com'") }
        try s.deleteBookmark(id: h.id)
        try s.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT count(*) FROM bookmark WHERE url = 'https://deep.com' AND deletedAt IS NOT NULL"), 1) }
    }

    func testMoveAcrossProfilesRefused() throws {
        let (s, bar, _) = try make()
        let a = try s.addBookmark(title: "a", url: "https://a.com", parentId: bar.id)
        try s.db.write { try $0.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, createdAt, updatedAt) VALUES ('p2', 'P', 'P', 1, 1)") }
        try s.ensureBookmarkRoots(profileId: "p2")
        let other = try s.db.read { try String.fetchOne($0, sql: "SELECT id FROM bookmark WHERE profileId = 'p2' AND parentId IS NULL LIMIT 1") }
        XCTAssertThrowsError(try s.moveBookmark(id: a.id, toParent: XCTUnwrap(other), index: nil)) { XCTAssertEqual($0 as? BookmarkError, .crossProfile) }
    }

    func testUrlKindRequiresURL() throws {
        let (s, bar, _) = try make()
        XCTAssertThrowsError(try s.db.write {
            try $0.execute(sql: "INSERT INTO bookmark (id, profileId, parentId, kind, title, createdAt, updatedAt) VALUES ('x', ?, ?, 'url', 't', 1, 1)",
                           arguments: [Schema.defaultProfileID, bar.id])
        })
    }

    func testRename() throws {
        let (s, bar, _) = try make()
        let a = try s.addBookmark(title: "a", url: "https://a.com", parentId: bar.id)
        try s.renameBookmark(id: a.id, title: "z")
        XCTAssertEqual(try titles(s, bar), ["z"])
    }

    func testDeleteTombstonesDescendantsAndKeepsDense() throws {
        let (s, bar, _) = try make()
        _ = try s.addBookmark(title: "a", url: "https://a.com", parentId: bar.id)
        let f = try s.addFolder(title: "f", parentId: bar.id)
        let g = try s.addFolder(title: "g", parentId: f.id)
        _ = try s.addBookmark(title: "deep", url: "https://deep.com", parentId: g.id)
        _ = try s.addBookmark(title: "c", url: "https://c.com", parentId: bar.id)
        try s.deleteBookmark(id: f.id)
        XCTAssertEqual(try titles(s, bar), ["a", "c"])
        try dense(s, bar)
        XCTAssertNil(try s.bookmark(forURL: "https://deep.com"))
        try s.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT count(*) FROM bookmark WHERE deletedAt IS NOT NULL"), 3) }
    }

    func testRecentAndForURL() throws {
        let t = LockedBox(1_000.0)
        let s = try Store.inMemory(now: { Date(timeIntervalSince1970: t.next()) })
        let bar = try s.bookmarkRoots()[0]
        for i in 0..<7 { _ = try s.addBookmark(title: "b\(i)", url: "https://\(i).com", parentId: bar.id) }
        _ = try s.addFolder(title: "folder", parentId: bar.id)
        XCTAssertEqual(try s.recentBookmarks(limit: 5).map(\.title), ["b6", "b5", "b4", "b3", "b2"])
        XCTAssertEqual(try s.bookmark(forURL: "https://3.com")?.title, "b3")
        XCTAssertNil(try s.bookmark(forURL: "https://nope.com"))
        try s.deleteBookmark(id: try XCTUnwrap(s.bookmark(forURL: "https://3.com")).id)
        XCTAssertNil(try s.bookmark(forURL: "https://3.com"))
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Double
    init(_ v: Double) { self.v = v }
    func next() -> Double { lock.lock(); defer { lock.unlock() }; v += 1; return v }
}
