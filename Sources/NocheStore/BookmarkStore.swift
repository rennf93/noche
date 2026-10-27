import Foundation
import GRDB

public enum BookmarkKind: String, Sendable { case folder, url }

public enum BookmarkError: Error, Equatable, Sendable { case rootImmutable, notFound, notAFolder, cycle, crossProfile }

public struct Bookmark: Equatable, Sendable {
    public let id: String
    public let parentId: String?
    public let kind: BookmarkKind
    public let title: String
    public let url: String?
    public let position: Int
    public let createdAt: Date
}

struct BookmarkRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "bookmark"
    var id: String
    var profileId: String
    var parentId: String?
    var kind: String
    var title: String
    var url: String?
    var position: Int
    var createdAt: Double

    var bookmark: Bookmark? {
        BookmarkKind(rawValue: kind).map {
            Bookmark(id: id, parentId: parentId, kind: $0, title: title, url: url, position: position,
                     createdAt: Date(timeIntervalSince1970: createdAt))
        }
    }
}

extension Store {
    public func ensureBookmarkRoots(profileId: String) throws {
        let t = now().timeIntervalSince1970
        try db.write { try Schema.ensureBookmarkRoots($0, profileId: profileId, at: t) }
    }

    /// "Bookmarks Bar" then "Other Bookmarks" of the default profile.
    public func bookmarkRoots() throws -> [Bookmark] {
        try db.read { db in
            try BookmarkRow.all().live().filter(Column("profileId") == Schema.defaultProfileID && Column("parentId") == nil)
                .order(Column("position")).fetchAll(db).compactMap(\.bookmark)
        }
    }

    public func bookmarkChildren(of parentId: String) throws -> [Bookmark] {
        try db.read { db in
            _ = try Self.folder(db, parentId)
            return try Self.children(db, parentId).compactMap(\.bookmark)
        }
    }

    @discardableResult
    public func addBookmark(title: String, url: String, parentId: String, index: Int? = nil) throws -> Bookmark {
        try add(kind: .url, title: title, url: url, parentId: parentId, index: index)
    }

    @discardableResult
    public func addFolder(title: String, parentId: String, index: Int? = nil) throws -> Bookmark {
        try add(kind: .folder, title: title, url: nil, parentId: parentId, index: index)
    }

    /// |index| is the position among the destination's siblings after removal of the moved row; nil appends.
    public func moveBookmark(id: String, toParent parentId: String, index: Int?) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            let row = try Self.row(db, id)
            guard let oldParent = row.parentId else { throw BookmarkError.rootImmutable }
            guard try Self.folder(db, parentId).profileId == row.profileId else { throw BookmarkError.crossProfile }
            var cursor: String? = parentId
            while let c = cursor {
                if c == id { throw BookmarkError.cycle }
                cursor = try String.fetchOne(db, sql: "SELECT parentId FROM bookmark WHERE id = ?", arguments: [c])
            }
            if oldParent != parentId { try Self.renumber(db, parent: oldParent, excluding: id, inserting: nil, at: 0, now: t) }
            try db.execute(sql: "UPDATE bookmark SET parentId = ?, updatedAt = ? WHERE id = ?", arguments: [parentId, t, id])
            try Self.renumber(db, parent: parentId, excluding: id, inserting: id, at: index, now: t)
        }
    }

    public func renameBookmark(id: String, title: String) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            guard try Self.row(db, id).parentId != nil else { throw BookmarkError.rootImmutable }
            try db.execute(sql: "UPDATE bookmark SET title = ?, updatedAt = ? WHERE id = ?", arguments: [title, t, id])
        }
    }

    /// What `deleteBookmark` took: enough to put the row back where it was.
    public struct Deleted: Equatable, Sendable {
        public let id: String
        public let parentId: String
        public let position: Int
        let deletedAt: Double
    }

    /// Tombstones the row and all its descendants in one transaction.
    @discardableResult
    public func deleteBookmark(id: String) throws -> Deleted {
        let t = now().timeIntervalSince1970
        return try db.write { db in
            let row = try Self.row(db, id)
            guard let parent = row.parentId else { throw BookmarkError.rootImmutable }
            try db.execute(sql: """
                WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT b.id FROM bookmark b JOIN sub ON b.parentId = sub.id)
                UPDATE bookmark SET deletedAt = ?, updatedAt = ? WHERE id IN (SELECT id FROM sub) AND deletedAt IS NULL
                """, arguments: [id, t, t])
            try Self.renumber(db, parent: parent, excluding: id, inserting: nil, at: 0, now: t)
            return Deleted(id: id, parentId: parent, position: row.position, deletedAt: t)
        }
    }

    /// Undoes `deleteBookmark`: the row and the descendants that delete took (not ones deleted earlier) come back, the row at its old position.
    /// Throws notFound when the parent folder is gone itself (restore that first).
    public func restoreBookmark(_ d: Deleted) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            _ = try Self.folder(db, d.parentId)
            try db.execute(sql: """
                WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT b.id FROM bookmark b JOIN sub ON b.parentId = sub.id)
                UPDATE bookmark SET deletedAt = NULL, updatedAt = ? WHERE id IN (SELECT id FROM sub) AND deletedAt = ?
                """, arguments: [d.id, t, d.deletedAt])
            try Self.renumber(db, parent: d.parentId, excluding: d.id, inserting: d.id, at: d.position, now: t)
        }
    }

    /// Rows reachable from a live root through live rows only, so a live row under a tombstoned ancestor never shows.
    private static let reachable = """
        WITH RECURSIVE reach(id) AS (
          SELECT id FROM bookmark WHERE parentId IS NULL AND deletedAt IS NULL
          UNION SELECT b.id FROM bookmark b JOIN reach ON b.parentId = reach.id WHERE b.deletedAt IS NULL)
        SELECT * FROM bookmark WHERE id IN (SELECT id FROM reach) AND profileId = ? AND kind = 'url'
        """

    /// Newest url bookmarks first.
    public func recentBookmarks(limit: Int = 5) throws -> [Bookmark] {
        try db.read { db in
            try BookmarkRow.fetchAll(db, sql: Self.reachable + " ORDER BY createdAt DESC, rowid DESC LIMIT ?",
                                     arguments: [Schema.defaultProfileID, limit]).compactMap(\.bookmark)
        }
    }

    /// Every reachable url bookmark, newest first, no cap (the command bar ranks them on each keystroke, so a deleted one is gone at once and an old one still ranks).
    public func urlBookmarks() throws -> [Bookmark] {
        try db.read { db in
            try BookmarkRow.fetchAll(db, sql: Self.reachable + " ORDER BY createdAt DESC, rowid DESC", arguments: [Schema.defaultProfileID]).compactMap(\.bookmark)
        }
    }

    /// One reachable url bookmark by id (existence and the card's Done), nil when it is gone.
    public func bookmark(id: String) throws -> Bookmark? {
        try db.read { db in try BookmarkRow.fetchOne(db, sql: Self.reachable + " AND id = ?", arguments: [Schema.defaultProfileID, id])?.bookmark }
    }

    /// A folder holding one url bookmark per entry, in order, in one transaction (Bookmark All Tabs).
    @discardableResult
    public func addFolder(title: String, parentId: String, bookmarks: [(title: String, url: String)]) throws -> Bookmark {
        let t = now().timeIntervalSince1970
        let folderId = UUID().uuidString
        return try db.write { db in
            let parent = try Self.folder(db, parentId)
            try db.execute(sql: """
                INSERT INTO bookmark (id, profileId, parentId, kind, title, url, position, createdAt, updatedAt) VALUES (?, ?, ?, 'folder', ?, NULL, 0, ?, ?)
                """, arguments: [folderId, parent.profileId, parentId, title, t, t])
            try Self.renumber(db, parent: parentId, excluding: folderId, inserting: folderId, at: nil, now: t)
            for (i, b) in bookmarks.enumerated() {
                try db.execute(sql: """
                    INSERT INTO bookmark (id, profileId, parentId, kind, title, url, position, createdAt, updatedAt) VALUES (?, ?, ?, 'url', ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, parent.profileId, folderId, b.title, b.url, i, t, t])
            }
            return try Self.bookmarkOrThrow(Self.row(db, folderId))
        }
    }

    public func bookmark(forURL url: String) throws -> Bookmark? {
        try db.read { db in
            try BookmarkRow.fetchOne(db, sql: Self.reachable + " AND url = ? ORDER BY createdAt DESC, rowid DESC",
                                     arguments: [Schema.defaultProfileID, url])?.bookmark
        }
    }

    private func add(kind: BookmarkKind, title: String, url: String?, parentId: String, index: Int?) throws -> Bookmark {
        let t = now().timeIntervalSince1970, id = UUID().uuidString
        return try db.write { db in
            let parent = try Self.folder(db, parentId)
            try db.execute(sql: """
                INSERT INTO bookmark (id, profileId, parentId, kind, title, url, position, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [id, parent.profileId, parentId, kind.rawValue, title, url, t, t])
            try Self.renumber(db, parent: parentId, excluding: id, inserting: id, at: index, now: t)
            return try Self.bookmarkOrThrow(Self.row(db, id))
        }
    }

    private static func bookmarkOrThrow(_ r: BookmarkRow) throws -> Bookmark {
        guard let b = r.bookmark else { throw BookmarkError.notFound }
        return b
    }

    private static func children(_ db: Database, _ parentId: String) throws -> [BookmarkRow] {
        try BookmarkRow.all().live().filter(Column("parentId") == parentId).order(Column("position"), Column("rowid")).fetchAll(db)
    }

    private static func row(_ db: Database, _ id: String) throws -> BookmarkRow {
        guard let r = try BookmarkRow.all().live().filter(Column("id") == id).fetchOne(db) else { throw BookmarkError.notFound }
        return r
    }

    private static func folder(_ db: Database, _ id: String) throws -> BookmarkRow {
        let r = try row(db, id)
        guard r.kind == BookmarkKind.folder.rawValue else { throw BookmarkError.notAFolder }
        return r
    }

    /// Rewrites live children positions of |parent| as 0..n-1, with |inserting| placed at |at| (nil appends) among the others.
    private static func renumber(_ db: Database, parent: String, excluding: String, inserting: String?, at: Int?, now t: Double) throws {
        var ids = try children(db, parent).map(\.id).filter { $0 != excluding }
        if let inserting { ids.insert(inserting, at: min(max(at ?? ids.count, 0), ids.count)) }
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE bookmark SET position = ?, updatedAt = CASE WHEN position = ? THEN updatedAt ELSE ? END WHERE id = ?",
                           arguments: [i, i, t, id])
        }
    }
}
