import Foundation
import GRDB
import NocheCore

public final class Store: Sendable {
    let db: any DatabaseWriter
    let now: @Sendable () -> Date
    static let closedCap = 25
#if NOCHE_TESTHOOKS
    /// Test only (compiled with NOCHE_TESTHOOKS): called inside `save`'s transaction after the writes, before the commit.
    nonisolated(unsafe) public static var inTransactionHook: (() -> Void)?
#endif

    private init(_ db: any DatabaseWriter, now: @escaping @Sendable () -> Date) throws {
        self.db = db
        self.now = now
        try Schema.migrator.migrate(db)
        try db.write { db in
            let t = now().timeIntervalSince1970
            try db.execute(sql: "INSERT OR IGNORE INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt) VALUES (?, 'Default', 'Default', 1, ?, ?)",
                           arguments: [Schema.defaultProfileID, t, t])
            try db.execute(sql: "INSERT OR IGNORE INTO space (id, profileId, name, createdAt, updatedAt) VALUES (?, ?, 'Default', ?, ?)",
                           arguments: [Schema.defaultSpaceID, Schema.defaultProfileID, t, t])
            try Schema.ensureBookmarkRoots(db, profileId: Schema.defaultProfileID, at: t)
        }
    }

    private static func configuration() -> Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        c.prepareDatabase { db in
            db.add(function: .lowercase)
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return c
    }

    public static func inMemory() throws -> Store { try inMemory(now: { Date() }) }

    static func inMemory(now: @escaping @Sendable () -> Date) throws -> Store {
        try Store(DatabaseQueue(configuration: configuration()), now: now)
    }

    /// Thrown when a corrupt store cannot be moved aside; never swallowed, so the caller sees why launch cannot continue.
    public struct QuarantineError: Error { public let path: String; public let underlying: any Error }

    private struct QuickCheckFailed: Error {}

    /// Migrates the file at |url|. Only a corrupt file (SQLITE_NOTADB, SQLITE_CORRUPT or a failed quick_check) is moved aside,
    /// with its -wal and -shm, as `<name>.corrupt-<yyyyMMdd-HHmmss-SSS>[-n]`, and an empty store is opened. Every other error
    /// (busy, full disk, permissions, a migration bug) is rethrown unchanged and leaves the files alone.
    public static func open(at url: URL) throws -> Store {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return try openFile(url)
        } catch where isCorruption(error) {
            try quarantine(url)
            return try openFile(url)
        }
    }

    static func isCorruption(_ error: any Error) -> Bool {
        if error is QuickCheckFailed { return true }
        guard let e = error as? DatabaseError else { return false }
        return e.resultCode.primaryResultCode == .SQLITE_NOTADB || e.resultCode.primaryResultCode == .SQLITE_CORRUPT
    }

    private static func openFile(_ url: URL) throws -> Store {
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        let check = try pool.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
        guard check == "ok" else { throw QuickCheckFailed() }
        return try Store(pool, now: { Date() })
    }

    /// Moves the db, -wal and -shm to one shared unique suffix (a counter is appended until all three destinations are free).
    static func quarantine(_ url: URL) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = ".corrupt-" + f.string(from: Date())
        let fm = FileManager.default
        var suffix = base, n = 1
        while ["", "-wal", "-shm"].contains(where: { fm.fileExists(atPath: url.path + $0 + suffix) }) {
            suffix = base + "-\(n)"
            n += 1
        }
        for ext in ["", "-wal", "-shm"] {
            let from = url.path + ext
            guard fm.fileExists(atPath: from) else { continue }
            do { try fm.moveItem(atPath: from, toPath: from + suffix) } catch { throw QuarantineError(path: from, underlying: error) }
        }
    }

    // MARK: Windows and tabs

    /// Contract: the caller removes a closed tab from its list before the next snapshot. A snapshot that still holds a tab
    /// revives it (live, no longer in the closed list), because the snapshot is the truth for live tabs.
    /// One transaction: upserts the window and its tabs (positions renumbered 0..n-1) and tombstones live tabs of the
    /// window that are not in the snapshot. Closed-list rows are never touched.
    public func save(_ w: WindowSnapshot) throws {
        let t = now().timeIntervalSince1970
        try db.write { try Self.write(w, $0, at: t) }
    }

    /// The same transaction on GRDB's writer queue, for debounced saves (a 100-tab window takes about 8 ms, too long for the main
    /// thread). GRDB serializes writers, so a later synchronous `save` still lands after it. |onError| runs on the writer queue.
    public func saveAsync(_ w: WindowSnapshot, onError: @escaping @Sendable (any Error) -> Void) {
        let t = now().timeIntervalSince1970
        db.asyncWrite({ try Self.write(w, $0, at: t) }, completion: { _, result in
            if case .failure(let error) = result { onError(error) }
        })
    }

    private static func write(_ w: WindowSnapshot, _ db: Database, at t: Double) throws {
        try db.execute(sql: """
            INSERT INTO window (id, profileId, x, y, w, h, isFullScreen, isZoomed, sidebarWidth, sidebarMode, selectedTabId, zOrder, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET x = excluded.x, y = excluded.y, w = excluded.w, h = excluded.h,
              isFullScreen = excluded.isFullScreen, isZoomed = excluded.isZoomed, sidebarWidth = excluded.sidebarWidth,
              sidebarMode = excluded.sidebarMode, selectedTabId = excluded.selectedTabId, zOrder = excluded.zOrder,
              updatedAt = excluded.updatedAt, deletedAt = NULL
            """, arguments: [w.id.uuidString, Schema.defaultProfileID, Double(w.frame.origin.x), Double(w.frame.origin.y),
                             Double(w.frame.width), Double(w.frame.height), w.isFullScreen, w.isZoomed, w.sidebarWidth,
                             w.sidebarMode, w.selectedTabID?.raw.uuidString, w.zOrder, t, t])
        for (i, tab) in w.tabs.enumerated() {
            let meta = w.tabMeta[tab.id]
            try db.execute(sql: """
                INSERT INTO tab (id, windowId, url, title, faviconURL, position, lastActiveAt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET windowId = excluded.windowId, url = excluded.url, title = excluded.title,
                  faviconURL = excluded.faviconURL, position = excluded.position, lastActiveAt = excluded.lastActiveAt,
                  closedAt = NULL, closedIndex = NULL, closedWindowId = NULL, updatedAt = excluded.updatedAt, deletedAt = NULL
                """, arguments: [tab.id.raw.uuidString, w.id.uuidString, tab.url, tab.title, meta?.faviconURL, i,
                                 meta?.lastActiveAt.timeIntervalSince1970 ?? t, t, t])
        }
        try Self.tombstoneLiveTabs(db, window: w.id, except: w.tabs.map { $0.id.raw.uuidString }, at: t)
#if NOCHE_TESTHOOKS
        Self.inTransactionHook?()
#endif
    }

    /// Geometry only: one UPDATE of the window row (a move or resize storm must not rewrite tab rows). A window never saved is left alone.
    public func saveFrame(_ window: UUID, frame: CGRect, isFullScreen: Bool, isZoomed: Bool) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: "UPDATE window SET x = ?, y = ?, w = ?, h = ?, isFullScreen = ?, isZoomed = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                           arguments: [Double(frame.origin.x), Double(frame.origin.y), Double(frame.width), Double(frame.height), isFullScreen, isZoomed, t, window.uuidString])
        }
    }

    public func loadWindows() throws -> [WindowSnapshot] {
        try db.read { db in
            try WindowRow.all().live().order(Column("zOrder"), Column("rowid")).fetchAll(db).compactMap { row in
                guard let id = UUID(uuidString: row.id) else { return nil }
                let tabRows = try TabRow.all().live()
                    .filter(Column("windowId") == row.id && Column("closedAt") == nil && Column("archivedAt") == nil)
                    .order(Column("position")).fetchAll(db)
                var tabs: [TabItem] = [], meta: [TabID: TabMeta] = [:]
                for r in tabRows {
                    guard let item = r.item else { continue }
                    tabs.append(item)
                    meta[item.id] = TabMeta(faviconURL: r.faviconURL, lastActiveAt: Date(timeIntervalSince1970: r.lastActiveAt))
                }
                return WindowSnapshot(
                    id: id, frame: CGRect(x: row.x ?? 0, y: row.y ?? 0, width: row.w ?? 0, height: row.h ?? 0),
                    isFullScreen: row.isFullScreen, isZoomed: row.isZoomed, sidebarWidth: row.sidebarWidth,
                    sidebarMode: row.sidebarMode, tabs: tabs,
                    selectedTabID: row.selectedTabId.flatMap(UUID.init(uuidString:)).map { TabID(raw: $0) },
                    zOrder: row.zOrder, tabMeta: meta)
            }
        }
    }

    /// Tombstones the window and its live tabs; its closed-list rows stay poppable.
    public func removeWindow(_ id: UUID) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: "UPDATE window SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL", arguments: [t, t, id.uuidString])
            try Self.tombstoneLiveTabs(db, window: id, except: [], at: t)
        }
    }

    private static func tombstoneLiveTabs(_ db: Database, window: UUID, except keep: [String], at t: Double) throws {
        try TabRow.all().live()
            .filter(Column("windowId") == window.uuidString && Column("closedAt") == nil && Column("archivedAt") == nil)
            .filter(!keep.contains(Column("id")))
            .updateAll(db, Column("deletedAt").set(to: t), Column("updatedAt").set(to: t))
    }

    // MARK: Closed tabs

    /// Upserts the row as recently closed (also revives it if a save tombstoned it first), then keeps the newest 25.
    /// Throws a foreign-key error if |windowID| was never saved; save the window first. See |save| for the ordering contract.
    public func recordClosed(_ tab: TabItem, windowID: UUID, index: Int) throws {
        guard !tab.url.isEmpty, tab.url != "about:blank" else { return }
        let t = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO tab (id, windowId, url, title, position, lastActiveAt, closedAt, closedIndex, closedWindowId, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET url = excluded.url, title = excluded.title, closedAt = excluded.closedAt,
                  closedIndex = excluded.closedIndex, closedWindowId = excluded.closedWindowId, updatedAt = excluded.updatedAt, deletedAt = NULL
                """, arguments: [tab.id.raw.uuidString, windowID.uuidString, tab.url, tab.title, index, t, t, index, windowID.uuidString, t, t])
            let keep = Self.closedRequest().select(Column("id")).limit(Self.closedCap)
            try TabRow.all().live().filter(Column("closedAt") != nil).filter(!keep.contains(Column("id")))
                .updateAll(db, Column("deletedAt").set(to: t), Column("updatedAt").set(to: t))
        }
    }

    private static func closedRequest() -> QueryInterfaceRequest<TabRow> {
        TabRow.all().live().filter(Column("closedAt") != nil).order(Column("closedAt").desc, Column("rowid").desc)
    }

    /// Newest closed tab first. Returns the stored window id and index; clamping is the caller's job.
    public func popLastClosed() throws -> ClosedTab? {
        let t = now().timeIntervalSince1970
        return try db.write { db in
            // A malformed row (bad id or window id) is tombstoned so it cannot block the older rows behind it.
            while let r = try Self.closedRequest().fetchOne(db) {
                guard let item = r.item, let closedAt = r.closedAt, let wid = r.closedWindowId.flatMap(UUID.init(uuidString:)) else {
                    try db.execute(sql: "UPDATE tab SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [t, t, r.id])
                    continue
                }
                try db.execute(sql: "UPDATE tab SET closedAt = NULL, closedIndex = NULL, closedWindowId = NULL, updatedAt = ? WHERE id = ?",
                               arguments: [t, r.id])
                return ClosedTab(tab: item, windowID: wid, index: r.closedIndex ?? r.position, closedAt: Date(timeIntervalSince1970: closedAt))
            }
            return nil
        }
    }

    public func hasClosedTabs() throws -> Bool {
        try db.read { try Self.closedRequest().isEmpty($0) == false }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try db.read { try SettingRow.all().live().filter(Column("key") == key).fetchOne($0)?.value }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        let t = now().timeIntervalSince1970
        try db.write {
            try $0.execute(sql: """
                INSERT INTO setting (key, value, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt, deletedAt = NULL
                """, arguments: [key, value, t])
        }
    }
}
