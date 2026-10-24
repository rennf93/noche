import Foundation
import GRDB

enum Schema {
    static let defaultProfileID = "00000000-0000-0000-0000-000000000001"
    static let defaultSpaceID = "00000000-0000-0000-0000-000000000002"

    /// Never edit a shipped migration; add "v2" etc. to this one registration point.
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE profile (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, colorIndex INTEGER NOT NULL DEFAULT 0,
              chromiumDirName TEXT NOT NULL, isDefault INTEGER NOT NULL DEFAULT 0,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE TABLE space (
              id TEXT PRIMARY KEY, profileId TEXT NOT NULL REFERENCES profile(id),
              name TEXT NOT NULL, colorTheme TEXT, position INTEGER NOT NULL DEFAULT 0,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE TABLE window (
              id TEXT PRIMARY KEY, profileId TEXT NOT NULL REFERENCES profile(id),
              focusedSpaceId TEXT REFERENCES space(id),
              x REAL, y REAL, w REAL, h REAL, isFullScreen INTEGER NOT NULL DEFAULT 0, isZoomed INTEGER NOT NULL DEFAULT 0,
              sidebarWidth REAL, sidebarMode TEXT NOT NULL DEFAULT 'shown',
              selectedTabId TEXT,
              zOrder INTEGER NOT NULL DEFAULT 0,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE TABLE tabGroup (
              id TEXT PRIMARY KEY, spaceId TEXT REFERENCES space(id), windowId TEXT REFERENCES window(id),
              name TEXT NOT NULL DEFAULT '', colorIndex INTEGER NOT NULL DEFAULT 0, icon TEXT,
              isCollapsed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE TABLE tab (
              id TEXT PRIMARY KEY, windowId TEXT NOT NULL REFERENCES window(id),
              spaceId TEXT REFERENCES space(id), groupId TEXT REFERENCES tabGroup(id),
              kind TEXT NOT NULL DEFAULT 'web',
              url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', faviconURL TEXT,
              position INTEGER NOT NULL, isPinned INTEGER NOT NULL DEFAULT 0, pinnedURL TEXT,
              lastActiveAt REAL NOT NULL,
              closedAt REAL, closedIndex INTEGER, closedWindowId TEXT,
              archivedAt REAL,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE INDEX tab_window_order ON tab(windowId, position) WHERE deletedAt IS NULL AND closedAt IS NULL AND archivedAt IS NULL;
            CREATE INDEX tab_closed ON tab(closedAt DESC) WHERE closedAt IS NOT NULL AND deletedAt IS NULL;
            CREATE INDEX tab_cleanup ON tab(lastActiveAt) WHERE isPinned = 0 AND deletedAt IS NULL AND closedAt IS NULL AND archivedAt IS NULL;
            CREATE INDEX window_live ON window(zOrder) WHERE deletedAt IS NULL;
            CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
            CREATE TABLE page (
              id TEXT PRIMARY KEY, profileId TEXT NOT NULL REFERENCES profile(id),
              url TEXT NOT NULL, host TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '',
              visitCount INTEGER NOT NULL DEFAULT 0, typedCount INTEGER NOT NULL DEFAULT 0,
              lastVisitAt REAL NOT NULL,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE UNIQUE INDEX page_url ON page(profileId, url) WHERE deletedAt IS NULL;
            CREATE INDEX page_host ON page(profileId, host, lastVisitAt DESC) WHERE deletedAt IS NULL;
            CREATE INDEX page_recent ON page(profileId, lastVisitAt DESC) WHERE deletedAt IS NULL;
            CREATE TABLE visit (
              id TEXT PRIMARY KEY, pageId TEXT NOT NULL REFERENCES page(id),
              visitedAt REAL NOT NULL, transition TEXT NOT NULL DEFAULT 'link',
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE INDEX visit_page ON visit(pageId, visitedAt DESC);
            """)
        }
        m.registerMigration("v3") { db in
            try db.execute(sql: """
            CREATE TABLE sitePermission (
              id TEXT PRIMARY KEY, profileId TEXT NOT NULL REFERENCES profile(id),
              origin TEXT NOT NULL, kind TEXT NOT NULL, decision TEXT NOT NULL CHECK (decision IN ('allow', 'block')),
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE UNIQUE INDEX sitePermission_key ON sitePermission(profileId, origin, kind) WHERE deletedAt IS NULL;
            CREATE TABLE bookmark (
              id TEXT PRIMARY KEY, profileId TEXT NOT NULL REFERENCES profile(id),
              parentId TEXT REFERENCES bookmark(id), kind TEXT NOT NULL CHECK (kind IN ('folder', 'url')) CHECK (kind = 'folder' OR url IS NOT NULL),
              title TEXT NOT NULL DEFAULT '', url TEXT, position INTEGER NOT NULL DEFAULT 0,
              createdAt REAL NOT NULL, updatedAt REAL NOT NULL, deletedAt REAL);
            CREATE INDEX bookmark_children ON bookmark(profileId, parentId, position) WHERE deletedAt IS NULL;
            CREATE UNIQUE INDEX bookmark_root ON bookmark(profileId, title) WHERE parentId IS NULL AND deletedAt IS NULL;
            """)
            for id in try String.fetchAll(db, sql: "SELECT id FROM profile WHERE deletedAt IS NULL") {
                try ensureBookmarkRoots(db, profileId: id, at: Date().timeIntervalSince1970)
            }
        }
        m.registerMigration("v4") { db in
            try db.execute(sql: """
            ALTER TABLE profile ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE profile ADD COLUMN shareWithProfileId TEXT REFERENCES profile(id);
            """)
            let ids = try String.fetchAll(db, sql: "SELECT id FROM profile WHERE deletedAt IS NULL ORDER BY createdAt, rowid")
            for (i, id) in ids.enumerated() { try db.execute(sql: "UPDATE profile SET position = ? WHERE id = ?", arguments: [i, id]) }
        }
        return m
    }

    static let bookmarkRootTitles = ["Bookmarks Bar", "Other Bookmarks"]

    /// Idempotent: creates the two fixed roots (parentId NULL folders) the profile lacks.
    static func ensureBookmarkRoots(_ db: Database, profileId: String, at t: Double) throws {
        for (i, title) in bookmarkRootTitles.enumerated() {
            try db.execute(sql: """
                INSERT OR IGNORE INTO bookmark (id, profileId, parentId, kind, title, position, createdAt, updatedAt)
                VALUES (?, ?, NULL, 'folder', ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, profileId, title, i, t, t])
        }
    }
}
