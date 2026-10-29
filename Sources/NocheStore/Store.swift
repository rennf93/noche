import Foundation
import GRDB
import NocheCore

public final class Store: Sendable {
    let db: any DatabaseWriter
    let now: @Sendable () -> Date
    static let closedCap = 25
    /// An archived tab is tombstoned this long after |archivedAt|.
    public static let archiveRetention: TimeInterval = 30 * 86_400
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
        // The list repairs what a foreign key would refuse (a tab naming a group that is not in the snapshot) and numbers the containers.
        let list = TabList(items: w.tabs, groups: w.groups, topOrder: w.topOrder, dayOrder: w.dayOrder, activeID: nil)
        let tabs = list?.items ?? w.tabs.map { var x = $0; x.groupID = nil; return x }
        let groups = list?.groups ?? []
        var tabPos: [TabID: Int] = [:], groupPos: [GroupID: Int] = [:]
        if let list {
            for (i, r) in list.topOrder.enumerated() { Self.number(r, i, &tabPos, &groupPos) }
            for (i, r) in list.dayOrder.enumerated() { Self.number(r, i, &tabPos, &groupPos) }
            var grid = 0, kids: [GroupID: Int] = [:]
            for x in tabs {
                if x.isPinned && x.inGrid { tabPos[x.id] = grid; grid += 1 } else if let g = x.groupID { tabPos[x.id] = kids[g, default: 0]; kids[g, default: 0] += 1 }
            }
        } else {
            for (i, x) in tabs.enumerated() { tabPos[x.id] = i }
        }
        for g in groups {
            try db.execute(sql: """
                INSERT INTO tabGroup (id, windowId, name, colorIndex, icon, isCollapsed, isPinned, position, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET windowId = excluded.windowId, name = excluded.name, colorIndex = excluded.colorIndex,
                  icon = excluded.icon, isCollapsed = excluded.isCollapsed, isPinned = excluded.isPinned, position = excluded.position,
                  updatedAt = excluded.updatedAt, deletedAt = NULL
                """, arguments: [g.id.raw.uuidString, w.id.uuidString, g.name, g.colorIndex, g.icon, g.isCollapsed, g.isPinned, groupPos[g.id] ?? 0, t, t])
        }
        for tab in tabs {
            let meta = w.tabMeta[tab.id]
            try db.execute(sql: """
                INSERT INTO tab (id, windowId, groupId, url, title, faviconURL, position, isPinned, pinnedURL, inGrid, customTitle, customIcon,
                                 lastActiveAt, archivedAt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET windowId = excluded.windowId, groupId = excluded.groupId, url = excluded.url, title = excluded.title,
                  faviconURL = excluded.faviconURL, position = excluded.position, isPinned = excluded.isPinned, pinnedURL = excluded.pinnedURL,
                  inGrid = excluded.inGrid, customTitle = excluded.customTitle, customIcon = excluded.customIcon,
                  lastActiveAt = excluded.lastActiveAt, archivedAt = NULL,
                  closedAt = NULL, closedIndex = NULL, closedWindowId = NULL, updatedAt = excluded.updatedAt, deletedAt = NULL
                """, arguments: [tab.id.raw.uuidString, w.id.uuidString, tab.groupID?.raw.uuidString, tab.url, tab.title, meta?.faviconURL,
                                 tabPos[tab.id] ?? 0, tab.isPinned, tab.pinnedURL, tab.inGrid, tab.customTitle, tab.customIcon,
                                 tab.lastActiveAt.timeIntervalSince1970, t, t])
        }
        try Self.tombstoneLiveTabs(db, window: w.id, except: tabs.map { $0.id.raw.uuidString }, at: t)
        try Self.tombstoneGroups(db, window: w.id, except: groups.map { $0.id.raw.uuidString }, at: t)
#if NOCHE_TESTHOOKS
        Self.inTransactionHook?()
#endif
    }

    private static func number(_ r: TopRef, _ i: Int, _ tabPos: inout [TabID: Int], _ groupPos: inout [GroupID: Int]) {
        switch r {
        case .tab(let t): tabPos[t] = i
        case .group(let g): groupPos[g] = i
        }
    }

    /// Geometry only: one UPDATE of the window row (a move or resize storm must not rewrite tab rows). A window never saved is left alone.
    public func saveFrame(_ window: UUID, frame: CGRect, isFullScreen: Bool, isZoomed: Bool) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: "UPDATE window SET x = ?, y = ?, w = ?, h = ?, isFullScreen = ?, isZoomed = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                           arguments: [Double(frame.origin.x), Double(frame.origin.y), Double(frame.width), Double(frame.height), isFullScreen, isZoomed, t, window.uuidString])
        }
    }

    /// The live windows of one profile (nil: the default profile, the only one the app writes until profiles are wired); their tabs come with them.
    public func loadWindows(profileId: String? = nil) throws -> [WindowSnapshot] {
        let profile = profileId ?? Schema.defaultProfileID
        return try db.read { db in
            try WindowRow.all().live().filter(Column("profileId") == profile).order(Column("zOrder"), Column("rowid")).fetchAll(db).compactMap { row in
                guard let id = UUID(uuidString: row.id) else { return nil }
                let tabRows = try TabRow.all().live()
                    .filter(Column("windowId") == row.id && Column("closedAt") == nil && Column("archivedAt") == nil)
                    .order(Column("position")).fetchAll(db)
                let groupRows = try GroupRow.all().live().filter(Column("windowId") == row.id).order(Column("position"), Column("rowid")).fetchAll(db)
                var tabs: [TabItem] = [], meta: [TabID: TabMeta] = [:]
                for r in tabRows {
                    guard let item = r.item else { continue }
                    tabs.append(item)
                    meta[item.id] = TabMeta(faviconURL: r.faviconURL)
                }
                let groups = groupRows.compactMap(\.group)
                // The persistent area and the day list each interleave loose tabs and groups by their stored position.
                func order(pinned: Bool) -> [TopRef] {
                    let loose = tabRows.compactMap { r -> (Int, TopRef)? in
                        guard let t = r.item, t.groupID == nil, t.isPinned == pinned, !t.inGrid else { return nil }
                        return (r.position, .tab(t.id))
                    }
                    let grouped = groupRows.compactMap { r -> (Int, TopRef)? in r.isPinned == pinned ? r.group.map { (r.position, .group($0.id)) } : nil }
                    return (loose + grouped).enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
                }
                let top = order(pinned: true), dayOrder = order(pinned: false)
                let list = TabList(items: tabs, groups: groups, topOrder: top, dayOrder: dayOrder, activeID: nil)
                return WindowSnapshot(
                    id: id, frame: CGRect(x: row.x ?? 0, y: row.y ?? 0, width: row.w ?? 0, height: row.h ?? 0),
                    isFullScreen: row.isFullScreen, isZoomed: row.isZoomed, sidebarWidth: row.sidebarWidth,
                    sidebarMode: row.sidebarMode, tabs: list?.items ?? tabs,
                    selectedTabID: row.selectedTabId.flatMap(UUID.init(uuidString:)).map { TabID(raw: $0) },
                    zOrder: row.zOrder, tabMeta: meta, groups: list?.groups ?? groups, topOrder: list?.topOrder ?? top, dayOrder: list?.dayOrder ?? dayOrder)
            }
        }
    }

    /// Tombstones the window and its live tabs; its closed-list rows stay poppable.
    public func removeWindow(_ id: UUID) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: "UPDATE window SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL", arguments: [t, t, id.uuidString])
            try Self.tombstoneLiveTabs(db, window: id, except: [], at: t)
            try Self.tombstoneGroups(db, window: id, except: [], at: t)
        }
    }

    private static func tombstoneGroups(_ db: Database, window: UUID, except keep: [String], at t: Double) throws {
        try GroupRow.all().live()
            .filter(Column("windowId") == window.uuidString)
            .filter(!keep.contains(Column("id")))
            .updateAll(db, Column("deletedAt").set(to: t), Column("updatedAt").set(to: t))
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
                INSERT INTO tab (id, windowId, groupId, url, title, position, isPinned, pinnedURL, inGrid, customTitle, customIcon,
                                 lastActiveAt, closedAt, closedIndex, closedWindowId, createdAt, updatedAt)
                VALUES (?, ?, (SELECT id FROM tabGroup WHERE id = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET groupId = excluded.groupId, url = excluded.url, title = excluded.title, isPinned = excluded.isPinned,
                  pinnedURL = excluded.pinnedURL, inGrid = excluded.inGrid, customTitle = excluded.customTitle, customIcon = excluded.customIcon,
                  closedAt = excluded.closedAt, closedIndex = excluded.closedIndex, closedWindowId = excluded.closedWindowId,
                  updatedAt = excluded.updatedAt, deletedAt = NULL
                """, arguments: [tab.id.raw.uuidString, windowID.uuidString, tab.groupID?.raw.uuidString, tab.url, tab.title, index, tab.isPinned,
                                 tab.pinnedURL, tab.inGrid, tab.customTitle, tab.customIcon, tab.lastActiveAt.timeIntervalSince1970, t, index, windowID.uuidString, t, t])  // the tab's own stamp: Search Tabs ranks by it
            let keep = Self.closedRequest().select(Column("id")).limit(Self.closedCap)
            try TabRow.all().live().filter(Column("closedAt") != nil).filter(!keep.contains(Column("id")))
                .updateAll(db, Column("deletedAt").set(to: t), Column("updatedAt").set(to: t))
        }
    }

    private static func closedRequest() -> QueryInterfaceRequest<TabRow> {
        TabRow.all().live().filter(Column("closedAt") != nil).order(Column("closedAt").desc, Column("rowid").desc)
    }

    /// The newest closed tab, left on the closed list: a reopen that dies before the tab is saved in its window loses nothing.
    /// Returns the stored window id and index; clamping is the caller's job. Malformed rows are tombstoned on the way.
    public func peekLastClosed() throws -> ClosedTab? {
        let t = now().timeIntervalSince1970
        return try db.write { try Self.lastClosed($0, at: t) }
    }

    /// Takes the tab off the closed list (the reopened tab was added). A save of the window holding it does the same.
    public func clearClosed(_ id: TabID) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: "UPDATE tab SET closedAt = NULL, closedIndex = NULL, closedWindowId = NULL, updatedAt = ? WHERE id = ? AND closedAt IS NOT NULL",
                           arguments: [t, id.raw.uuidString])
        }
    }

    /// Peek and clear in one transaction.
    public func popLastClosed() throws -> ClosedTab? {
        let t = now().timeIntervalSince1970
        return try db.write { db in
            guard let c = try Self.lastClosed(db, at: t) else { return nil }
            try db.execute(sql: "UPDATE tab SET closedAt = NULL, closedIndex = NULL, closedWindowId = NULL, updatedAt = ? WHERE id = ?",
                           arguments: [t, c.tab.id.raw.uuidString])
            return c
        }
    }

    private static func lastClosed(_ db: Database, at t: Double) throws -> ClosedTab? {
        // A malformed row (bad id or window id) is tombstoned so it cannot block the older rows behind it.
        while let r = try closedRequest().fetchOne(db) {
            guard let item = r.item, let closedAt = r.closedAt, let wid = r.closedWindowId.flatMap(UUID.init(uuidString:)) else {
                try db.execute(sql: "UPDATE tab SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [t, t, r.id])
                continue
            }
            return ClosedTab(tab: item, windowID: wid, index: r.closedIndex ?? r.position, closedAt: Date(timeIntervalSince1970: closedAt))
        }
        return nil
    }

    /// Recently closed tabs matching |query| (same matching and ranking as Search Tabs; empty: all), within a rank the most recently used first.
    public func closedTabs(matching query: String) throws -> [ClosedTab] {
        let all = try db.read { try Self.closedRequest().fetchAll($0) }.compactMap { r -> ClosedTab? in
            guard let item = r.item, let closedAt = r.closedAt, let wid = r.closedWindowId.flatMap(UUID.init(uuidString:)) else { return nil }
            return ClosedTab(tab: item, windowID: wid, index: r.closedIndex ?? r.position, closedAt: Date(timeIntervalSince1970: closedAt))
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.enumerated().compactMap { i, c -> (Int, Date, Int, ClosedTab)? in
            let title = c.tab.customTitle?.isEmpty == false ? c.tab.customTitle! : c.tab.title
            return TabSearch.rank(q, title: title, url: c.tab.url).map { ($0, c.tab.lastActiveAt, i, c) }
        }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2) }.map(\.3)
    }

    public func hasClosedTabs() throws -> Bool {
        try db.read { try Self.closedRequest().isEmpty($0) == false }
    }

    // MARK: Archive

    /// Archives live tabs (their rows keep window, group and pin); a closed-list, unknown or already archived row is left alone.
    /// The caller saves the window first and drops the tabs from its list, so the next save does not revive them.
    public func archive(ids: [TabID], at date: Date) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            _ = try TabRow.all().live().filter(ids.map { $0.raw.uuidString }.contains(Column("id")))
                .filter(Column("closedAt") == nil && Column("archivedAt") == nil)
                .updateAll(db, Column("archivedAt").set(to: date.timeIntervalSince1970), Column("updatedAt").set(to: t))
        }
    }

    /// Takes the tab out of the archive (the restored tab is added to its window, which saves it). Nil when it is not archived.
    public func restoreArchived(id: TabID) throws -> ArchivedTab? {
        let t = now().timeIntervalSince1970
        return try db.write { db in
            let rows = TabRow.all().live().filter(Column("id") == id.raw.uuidString && Column("archivedAt") != nil && Column("closedAt") == nil)
            guard let a = try rows.fetchOne(db).flatMap(Self.archivedTab) else { return nil }
            _ = try rows.updateAll(db, Column("archivedAt").set(to: nil), Column("updatedAt").set(to: t))
            var tab = a.tab
            tab.archivedAt = nil
            return ArchivedTab(tab: tab, windowID: a.windowID, faviconURL: a.faviconURL)
        }
    }

    /// Archived tabs matching |query| (same matching and ranking as Search Tabs; empty: all), newest archived first within a rank.
    public func archivedTabs(matching query: String) throws -> [ArchivedTab] {
        let all = try db.read { db in
            try TabRow.all().live().filter(Column("archivedAt") != nil && Column("closedAt") == nil)
                .order(Column("archivedAt").desc, Column("rowid").desc).fetchAll(db)
        }.compactMap(Self.archivedTab)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.enumerated().compactMap { i, a -> (Int, Int, ArchivedTab)? in
            let title = a.tab.customTitle?.isEmpty == false ? a.tab.customTitle! : a.tab.title
            return TabSearch.rank(q, title: title, url: a.tab.url).map { ($0, i, a) }
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private static func archivedTab(_ r: TabRow) -> ArchivedTab? {
        guard let item = r.item, let w = UUID(uuidString: r.windowId) else { return nil }
        return ArchivedTab(tab: item, windowID: w, faviconURL: r.faviconURL)
    }

    /// Tombstones the archived tabs older than |archiveRetention|; returns how many.
    @discardableResult
    public func tombstoneExpiredArchive() throws -> Int {
        let t = now().timeIntervalSince1970
        return try db.write { db in
            try TabRow.all().live().filter(Column("archivedAt") != nil && Column("archivedAt") < t - Self.archiveRetention)
                .updateAll(db, Column("deletedAt").set(to: t), Column("updatedAt").set(to: t))
        }
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
