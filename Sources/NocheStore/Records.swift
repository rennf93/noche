import Foundation
import GRDB
import NocheCore

/// Runtime-only |TabItem| fields (|engineID|, |isLoading|) are never stored; restored items get |engineID| 0 and |isLoading| false.
public struct TabMeta: Equatable, Sendable {
    public var faviconURL: String?
    public var lastActiveAt: Date
    public init(faviconURL: String?, lastActiveAt: Date) {
        self.faviconURL = faviconURL
        self.lastActiveAt = lastActiveAt
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public var id: UUID
    public var frame: CGRect
    public var isFullScreen: Bool
    public var isZoomed: Bool
    public var sidebarWidth: Double?
    public var sidebarMode: String
    public var tabs: [TabItem]
    public var selectedTabID: TabID?
    public var zOrder: Int
    public var tabMeta: [TabID: TabMeta]

    public init(id: UUID, frame: CGRect, isFullScreen: Bool, isZoomed: Bool, sidebarWidth: Double?, sidebarMode: String,
                tabs: [TabItem], selectedTabID: TabID?, zOrder: Int, tabMeta: [TabID: TabMeta]) {
        self.id = id
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.isZoomed = isZoomed
        self.sidebarWidth = sidebarWidth
        self.sidebarMode = sidebarMode
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.zOrder = zOrder
        self.tabMeta = tabMeta
    }
}

public struct ClosedTab: Equatable, Sendable {
    public let tab: TabItem
    public let windowID: UUID
    public let index: Int
    public let closedAt: Date
}

// Read-side rows. Writes are SQL upserts in Store, so these only decode the columns the store reads.
struct WindowRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "window"
    var id: String
    var x: Double?, y: Double?, w: Double?, h: Double?
    var isFullScreen: Bool, isZoomed: Bool
    var sidebarWidth: Double?
    var sidebarMode: String
    var selectedTabId: String?
    var zOrder: Int
}

struct TabRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "tab"
    var id: String
    var windowId: String
    var url: String
    var title: String
    var faviconURL: String?
    var position: Int
    var lastActiveAt: Double
    var closedAt: Double?
    var closedIndex: Int?
    var closedWindowId: String?

    var item: TabItem? {
        UUID(uuidString: id).map { TabItem(id: TabID(raw: $0), engineID: 0, url: url, title: title, isLoading: false) }
    }
}

struct SettingRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "setting"
    var key: String
    var value: String
}

extension DerivableRequest {
    /// The one place that hides tombstones; every public query goes through it.
    func live() -> Self { filter(Column("deletedAt") == nil) }
}
