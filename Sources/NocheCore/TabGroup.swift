import Foundation

/// A tab group's stable id (the `tabGroup` row id).
public struct GroupID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// A group (folder). |isPinned| names its container: the persistent area (true) or the day list (false).
public struct TabGroup: Equatable, Sendable {
    public let id: GroupID
    public var name: String
    public var colorIndex: Int
    public var icon: String?
    public var isCollapsed: Bool
    public var isPinned: Bool

    public init(id: GroupID, name: String, colorIndex: Int, icon: String?, isCollapsed: Bool, isPinned: Bool) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.icon = icon
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
    }
}

/// One entry of a container that mixes loose tabs and groups (the persistent area and the day list).
public enum TopRef: Hashable, Sendable {
    case tab(TabID)
    case group(GroupID)
}

/// Where a drop lands: a position (clamped) in the pinned grid, the persistent area, the day list or one group's children.
public enum DropTarget: Equatable, Sendable {
    case grid(Int)
    case persistent(Int)
    case day(Int)
    case group(GroupID, Int)
}

/// The sidebar's rows in order: grid tiles, the persistent area, the divider, the New Tab row, the day list.
public enum SidebarEntry: Equatable, Sendable {
    case gridTile(TabID)
    case tab(TabID, level: Int)
    case group(GroupID)
    case divider
    case newTab
}

/// Search Tabs matching: case-insensitive on the title and the host. 0 prefix, 1 substring, 2 subsequence, nil no match.
public enum TabSearch {
    public static func rank(_ query: String, title: String, url: String) -> Int? {
        let q = query.lowercased()
        if q.isEmpty { return 0 }
        let fields = [title.lowercased(), AddressInput.displayHost(url).lowercased()]
        if fields.contains(where: { $0.hasPrefix(q) }) { return 0 }
        if fields.contains(where: { $0.contains(q) }) { return 1 }
        if fields.contains(where: { isSubsequence(q, of: $0) }) { return 2 }
        return nil
    }

    private static func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        return q.allSatisfy { c in
            while let x = it.next() { if x == c { return true } }
            return false
        }
    }
}

/// The composition of the reference capture (table 1.1): 12 grid pins, 2 loose pinned rows, 11 collapsed groups, 5 loose pinned rows,
/// the divider, the New Tab row and |dayTabs| day tabs (the capture's day tabs are not counted; 3 is a builder choice).
public enum SidebarComposition {
    public static func capture(dayTabs: Int = 3) -> TabList {
        func tab(_ n: Int) -> TabItem {
            TabItem(id: TabID(), engineID: n, url: "https://site\(n).example/", title: "Tab \(n)", isLoading: false)
        }
        var items: [TabItem] = []
        func make(pinned: Bool, grid: Bool = false, group: GroupID? = nil) -> TabID {
            var t = tab(items.count)
            t.isPinned = pinned
            t.inGrid = grid
            t.pinnedURL = pinned ? t.url : nil
            t.groupID = group
            items.append(t)
            return t.id
        }
        let grid = (0..<12).map { _ in make(pinned: true, grid: true) }
        let before = (0..<2).map { _ in make(pinned: true) }
        let groups = (0..<11).map { i in TabGroup(id: GroupID(), name: "Group \(i)", colorIndex: i % 8, icon: nil, isCollapsed: true, isPinned: true) }
        for g in groups { _ = make(pinned: false, group: g.id) }
        let after = (0..<5).map { _ in make(pinned: true) }
        let day = (0..<dayTabs).map { _ in make(pinned: false) }
        let top: [TopRef] = (before.map(TopRef.tab) + groups.map { .group($0.id) } + after.map(TopRef.tab))
        return TabList(items: items, groups: groups, topOrder: top, dayOrder: day.map(TopRef.tab), activeID: day.first ?? grid.first)!
    }
}
