import Foundation
import GRDB
import NocheCore

/// Stored beside a tab that |TabItem| does not carry. Runtime-only |TabItem| fields (|engineID|, |isLoading|) are never stored;
/// restored items get a nil |engineID| (no engine tab yet) and |isLoading| false.
public struct TabMeta: Equatable, Sendable {
    public var faviconURL: String?
    public init(faviconURL: String?) {
        self.faviconURL = faviconURL
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
    /// The structure (|TabList.groups|, |topOrder|, |dayOrder|); |tabs| is |TabList.items|. Saved with the tabs; a restore builds the list from all four.
    public var groups: [TabGroup]
    public var topOrder: [TopRef]
    public var dayOrder: [TopRef]

    public init(id: UUID, frame: CGRect, isFullScreen: Bool, isZoomed: Bool, sidebarWidth: Double?, sidebarMode: String,
                tabs: [TabItem], selectedTabID: TabID?, zOrder: Int, tabMeta: [TabID: TabMeta],
                groups: [TabGroup] = [], topOrder: [TopRef] = [], dayOrder: [TopRef] = []) {
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
        self.groups = groups
        self.topOrder = topOrder
        self.dayOrder = dayOrder
    }
}

public struct ClosedTab: Equatable, Sendable {
    public let tab: TabItem
    public let windowID: UUID
    public let index: Int
    public let closedAt: Date
}

/// A tab in the archive (|tab.archivedAt| is set), with the window it was archived from.
public struct ArchivedTab: Equatable, Sendable {
    public let tab: TabItem
    public let windowID: UUID
    public let faviconURL: String?
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
    var groupId: String?
    var isPinned: Bool
    var inGrid: Bool
    var pinnedURL: String?
    var customTitle: String?
    var customIcon: String?
    var lastActiveAt: Double
    var closedAt: Double?
    var closedIndex: Int?
    var closedWindowId: String?
    var archivedAt: Double?

    var item: TabItem? {
        UUID(uuidString: id).map {
            TabItem(id: TabID(raw: $0), engineID: nil, url: url, title: title, isLoading: false, isPinned: isPinned, inGrid: inGrid,
                    pinnedURL: pinnedURL, groupID: groupId.flatMap(UUID.init(uuidString:)).map { GroupID(raw: $0) },
                    customTitle: customTitle, customIcon: customIcon, lastActiveAt: Date(timeIntervalSince1970: lastActiveAt),
                    archivedAt: archivedAt.map { Date(timeIntervalSince1970: $0) })
        }
    }
}

struct GroupRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "tabGroup"
    var id: String
    var name: String
    var colorIndex: Int
    var icon: String?
    var isCollapsed: Bool
    var isPinned: Bool
    var position: Int

    var group: TabGroup? {
        UUID(uuidString: id).map { TabGroup(id: GroupID(raw: $0), name: name, colorIndex: colorIndex, icon: icon, isCollapsed: isCollapsed, isPinned: isPinned) }
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
