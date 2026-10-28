import Foundation

/// Noche's own stable tab id; engine browser ids map onto it.
public struct TabID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

public struct TabItem: Equatable, Sendable {
    public let id: TabID
    /// Nil: no engine tab (a dormant tab). Runtime only, never stored.
    public var engineID: Int? {
        didSet { if engineID == nil { isDiscarded = false } }  // no engine tab, nothing discarded: a dormant copy is another state
    }
    public var url: String
    public var title: String
    public var isLoading: Bool
    /// The engine discarded the page (no renderer) but the engine tab stays and reloads in place when selected. Runtime only, never stored.
    public var isDiscarded: Bool
    /// Pinned: in the grid (|inGrid|) or a loose row of the persistent area. A pinned tab is never in a group.
    public var isPinned: Bool
    public var inGrid: Bool
    public var pinnedURL: String?
    public var groupID: GroupID?
    public var customTitle: String?
    public var customIcon: String?
    /// The only source of "last used": stamped by |TabList.markActive|, stored as is, never stamped by a restore.
    public var lastActiveAt: Date
    public var archivedAt: Date?

    public init(id: TabID, engineID: Int?, url: String, title: String, isLoading: Bool, isPinned: Bool = false, inGrid: Bool = false,
                pinnedURL: String? = nil, groupID: GroupID? = nil, customTitle: String? = nil, customIcon: String? = nil,
                lastActiveAt: Date = Date(), archivedAt: Date? = nil) {
        self.id = id
        self.engineID = engineID
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.isDiscarded = false
        self.isPinned = isPinned
        self.inGrid = inGrid
        self.pinnedURL = pinnedURL
        self.groupID = groupID
        self.customTitle = customTitle
        self.customIcon = customIcon
        self.lastActiveAt = lastActiveAt
        self.archivedAt = archivedAt
    }
}

/// The window's tabs. |items| holds every live tab in sidebar order (grid tiles, the persistent area, the day list; a group's
/// children follow its header, collapsed or not). The order itself lives in |topOrder| and |dayOrder| (loose tabs and groups share
/// one sequence per container) plus the relative order of the grid tiles and of each group's children inside |items|.
/// Archived tabs are held apart in |archived| and are never in |items|.
public struct TabList: Equatable, Sendable {
    public private(set) var items: [TabItem] = []
    public private(set) var activeID: TabID?
    public private(set) var groups: [TabGroup] = []
    /// The persistent area: loose pinned rows and pinned groups.
    public private(set) var topOrder: [TopRef] = []
    /// The day list: unpinned tabs that are in no group, and unpinned groups.
    public private(set) var dayOrder: [TopRef] = []
    public private(set) var archived: [TabItem] = []
    private var activation: [TabID: Int] = [:]
    private var activationCount = 0

    public init() {}

    /// Restores a saved list. Nil when two items or two groups share an id or |activeID| is not one of the live items (a nil |activeID|
    /// is allowed). Broken structure is repaired, not rejected: an unknown group, a pin inside a group, an |inGrid| tab that is not pinned,
    /// and an order that misses, repeats or misplaces entries (missing ones go last, in |items| order).
    public init?(items: [TabItem], groups: [TabGroup] = [], topOrder: [TopRef] = [], dayOrder: [TopRef] = [], activeID: TabID?) {
        guard Set(items.map(\.id)).count == items.count, Set(groups.map(\.id)).count == groups.count else { return nil }
        let live = items.filter { $0.archivedAt == nil }
        if let activeID, !live.contains(where: { $0.id == activeID }) { return nil }
        self.groups = groups
        self.archived = items.filter { $0.archivedAt != nil }.map { var t = $0; t.engineID = nil; return t }
        self.items = live.map(normalized)
        self.activeID = activeID
        func order(_ given: [TopRef], pinned: Bool) -> [TopRef] {
            var out: [TopRef] = [], seen = Set<TopRef>()
            let tabs = self.items.filter { $0.groupID == nil && $0.isPinned == pinned && !$0.inGrid }.map { TopRef.tab($0.id) }
            let grps = groups.filter { $0.isPinned == pinned }.map { TopRef.group($0.id) }
            let valid = Set(tabs + grps)
            for r in given + tabs + grps where valid.contains(r) && seen.insert(r).inserted { out.append(r) }
            return out
        }
        var m = model()
        m.top = order(topOrder, pinned: true)
        m.day = order(dayOrder, pinned: false)
        commit(m)
    }

    /// The list a restore ends with: the saved structure over |items|, never fewer tabs than were saved. When the init refuses it
    /// (two items share an id, or |activeID| is not live) the active tab is dropped, and when that fails too |current| is kept and
    /// every saved tab it lacks is put in dormant, in order. |intact| is false when the structure could not be applied.
    public static func restored(items: [TabItem], groups: [TabGroup], topOrder: [TopRef], dayOrder: [TopRef], activeID: TabID?, current: TabList) -> (list: TabList, intact: Bool) {
        if let l = TabList(items: items, groups: groups, topOrder: topOrder, dayOrder: dayOrder, activeID: activeID) { return (l, true) }
        if activeID != nil, let l = TabList(items: items, groups: groups, topOrder: topOrder, dayOrder: dayOrder, activeID: nil) { return (l, false) }
        var l = current
        for var t in items where !l.items.contains(where: { $0.id == t.id }) {
            t.engineID = nil
            l.insertNew(t, opener: nil, addToTop: false, activate: false)
        }
        return (l, false)
    }

    /// An item as the list stores it: the group must exist, a pin has no group and a pinned address, an unpinned tab has neither.
    private func normalized(_ item: TabItem) -> TabItem {
        var t = item
        if let g = t.groupID, !groups.contains(where: { $0.id == g }) { t.groupID = nil }
        if t.isPinned {
            t.groupID = nil
            t.pinnedURL = t.pinnedURL ?? t.url
        } else {
            t.inGrid = false
            t.pinnedURL = nil
        }
        return t
    }

    // MARK: structure model

    /// The containers as plain arrays, for one mutation: detach, put, then |commit|.
    private struct Model {
        var grid: [TabID]
        var top: [TopRef]
        var day: [TopRef]
        var kids: [GroupID: [TabID]]

        func position(of id: TabID) -> DropTarget? {
            if let i = grid.firstIndex(of: id) { return .grid(i) }
            if let i = top.firstIndex(of: .tab(id)) { return .persistent(i) }
            if let i = day.firstIndex(of: .tab(id)) { return .day(i) }
            for (g, k) in kids { if let i = k.firstIndex(of: id) { return .group(g, i) } }
            return nil
        }

        func position(of group: GroupID) -> DropTarget? {
            if let i = top.firstIndex(of: .group(group)) { return .persistent(i) }
            if let i = day.firstIndex(of: .group(group)) { return .day(i) }
            return nil
        }

        mutating func detach(_ id: TabID) {
            grid.removeAll { $0 == id }
            top.removeAll { $0 == .tab(id) }
            day.removeAll { $0 == .tab(id) }
            for g in kids.keys { kids[g]?.removeAll { $0 == id } }
        }

        mutating func put(_ ref: TopRef, at target: DropTarget) {
            func clamp(_ i: Int, _ n: Int) -> Int { min(max(i, 0), n) }
            switch (target, ref) {
            case (.persistent(let i), _): top.insert(ref, at: clamp(i, top.count))
            case (.day(let i), _): day.insert(ref, at: clamp(i, day.count))
            case (.grid(let i), .tab(let t)): grid.insert(t, at: clamp(i, grid.count))
            case (.group(let g, let i), .tab(let t)): kids[g, default: []].insert(t, at: clamp(i, kids[g]?.count ?? 0))
            default: break
            }
        }
    }

    private func model() -> Model {
        var kids: [GroupID: [TabID]] = [:]
        for t in items { if let g = t.groupID { kids[g, default: []].append(t.id) } }
        return Model(grid: items.filter { $0.isPinned && $0.inGrid }.map(\.id), top: topOrder, day: dayOrder, kids: kids)
    }

    /// Rebuilds |items| in sidebar order from |m|; |m| must place every tab and every group exactly once.
    private mutating func commit(_ m: Model) {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var out: [TabItem] = []
        out.reserveCapacity(items.count)
        func flat(_ refs: [TopRef]) {
            for r in refs {
                switch r {
                case .tab(let t): if let x = byID[t] { out.append(x) }
                case .group(let g): for t in m.kids[g] ?? [] { if let x = byID[t] { out.append(x) } }
                }
            }
        }
        out += m.grid.compactMap { byID[$0] }
        flat(m.top)
        flat(m.day)
        items = out
        topOrder = m.top
        dayOrder = m.day
    }

    private func index(of id: TabID) -> Int? { items.firstIndex { $0.id == id } }
    private func groupIndex(_ id: GroupID) -> Int? { groups.firstIndex { $0.id == id } }

    private func isHidden(_ t: TabItem) -> Bool {
        t.groupID.flatMap { g in groups.first { $0.id == g }?.isCollapsed } ?? false
    }

    private mutating func bump(_ id: TabID) {
        activationCount += 1
        activation[id] = activationCount
    }

    // MARK: adding, removing, updating

    /// A nil or unknown opener appends at the end. A duplicate id changes nothing and returns false (no activation either).
    @discardableResult
    public mutating func insert(_ item: TabItem, after opener: TabID?, activate: Bool) -> Bool {
        insertNew(item, opener: opener, addToTop: false, activate: activate)
    }

    /// A new tab. One that is pinned or in a known group goes there (a reopened tab keeps its place type; a group that is gone means the
    /// day list); the others are day tabs: at the top with |addToTop|, else after |opener| (in its group if it has one; at the top when
    /// the opener is pinned), else at the end. A duplicate id changes nothing and returns false (no activation either).
    @discardableResult
    public mutating func insertNew(_ item: TabItem, opener: TabID?, addToTop: Bool, activate: Bool) -> Bool {
        guard index(of: item.id) == nil, !archived.contains(where: { $0.id == item.id }) else { return false }
        var t = normalized(item)
        t.archivedAt = nil
        var m = model()
        if t.isPinned {
            if t.inGrid { m.grid.append(t.id) } else { m.top.append(.tab(t.id)) }
        } else if let g = t.groupID {
            m.kids[g, default: []].append(t.id)
        } else if addToTop {
            m.day.insert(.tab(t.id), at: 0)
        } else if let opener, let at = m.position(of: opener) {
            switch at {
            case .day(let i): m.day.insert(.tab(t.id), at: i + 1)
            case .group(let g, let i): t.groupID = g; m.kids[g, default: []].insert(t.id, at: i + 1)
            default: m.day.insert(.tab(t.id), at: 0)
            }
        } else {
            m.day.append(.tab(t.id))
        }
        items.append(t)
        commit(m)
        if activate { activeID = t.id; bump(t.id) }
        return true
    }

    /// Removes a live tab; returns the id that became active, only when the removed tab was the active one. The successor is the next
    /// visible row with an engine tab, else the nearest one above: collapsed children and dormant tabs are never chosen (nil when
    /// none is left, and then nothing is active).
    public mutating func remove(_ id: TabID) -> TabID? {
        if let a = archived.firstIndex(where: { $0.id == id }) { archived.remove(at: a); return nil }
        return take(id)?.successor
    }

    private mutating func take(_ id: TabID) -> (item: TabItem, successor: TabID?)? {
        guard let i = index(of: id) else { return nil }
        var successor: TabID?
        if activeID == id {
            func live(_ t: TabItem) -> Bool { t.engineID != nil && !isHidden(t) }
            successor = (items[(i + 1)...].first(where: live) ?? items[..<i].last(where: live))?.id
        }
        var m = model()
        m.detach(id)
        let item = items[i]
        items.remove(at: i)
        commit(m)
        activation[id] = nil
        if activeID == id { activeID = successor }
        return (item, successor)
    }

    public mutating func update(_ id: TabID, url: String, title: String, isLoading: Bool) {
        guard let i = index(of: id) else { return }
        items[i].url = url
        items[i].title = title
        items[i].isLoading = isLoading
    }

    /// Shows a tab's own title and icon in place of the page's; nil or empty clears. An unknown id is a no-op.
    public mutating func setCustomization(_ id: TabID, title: String?, icon: String?) {
        guard let i = index(of: id) else { return }
        items[i].customTitle = title?.isEmpty == false ? title : nil
        items[i].customIcon = icon?.isEmpty == false ? icon : nil
    }

    /// A tab gets an engine tab (waking from dormant) or loses it (going dormant).
    public mutating func setEngineID(_ id: TabID, _ engineID: Int?) {
        guard let i = index(of: id) else { return }
        items[i].engineID = engineID
    }

    /// The engine reported the tab's page discarded or restored. An unknown id is a no-op.
    public mutating func setDiscarded(_ id: TabID, _ discarded: Bool) {
        if let i = index(of: id) { items[i].isDiscarded = discarded }
    }

    /// Selects a tab without stamping it (the engine re-announcing the active tab, a restore).
    public mutating func activate(_ id: TabID) {
        if index(of: id) != nil { activeID = id }
    }

    /// Selects a tab as a use of it: stamps |lastActiveAt| and the activation counter that orders equal stamps.
    public mutating func markActive(_ id: TabID, at date: Date) {
        guard let i = index(of: id) else { return }
        items[i].lastActiveAt = date
        bump(id)
        activeID = id
    }

    // MARK: pinning

    /// Moves a tab to the end of the grid; pinnedURL is its address now; its group is cleared. Pinned already or unknown: no change.
    @discardableResult
    public mutating func pin(_ id: TabID) -> [TabID] {
        guard let i = index(of: id), !items[i].isPinned else { return [] }
        return place(id, at: .grid(Int.max))
    }

    /// Back to the top of the day list; pinnedURL is dropped. Not pinned or unknown: no change.
    @discardableResult
    public mutating func unpin(_ id: TabID) -> [TabID] {
        guard let i = index(of: id), items[i].isPinned else { return [] }
        return place(id, at: .day(0))
    }

    /// Pin, unpin and group membership follow the container the tab lands in; |index| is the position after the tab left its old place
    /// (clamped). A group that does not exist, or no change at all, returns [].
    @discardableResult
    public mutating func move(_ id: TabID, to target: DropTarget) -> [TabID] {
        let before = self
        let moved = place(id, at: target)
        if self == before { return [] }
        return moved
    }

    /// Where the tab sits inside its own container (the grid, the persistent area, the day list or its group): the |index| of
    /// |move(_:to:)|, which the flat |items| position is not. Nil for an unknown id.
    public func containerIndex(of id: TabID) -> Int? {
        switch model().position(of: id) {
        case .grid(let i)?, .persistent(let i)?, .day(let i)?, .group(_, let i)?: i
        case nil: nil
        }
    }

    /// Moves a tab to |index| (clamped) inside the container it is in; the active tab does not change. An unknown id is a no-op.
    public mutating func move(_ id: TabID, to index: Int) {
        guard let at = model().position(of: id) else { return }
        switch at {
        case .grid: place(id, at: .grid(index))
        case .persistent: place(id, at: .persistent(index))
        case .day: place(id, at: .day(index))
        case .group(let g, _): place(id, at: .group(g, index))
        }
    }

    @discardableResult
    private mutating func place(_ id: TabID, at target: DropTarget) -> [TabID] {
        guard let i = index(of: id) else { return [] }
        if case .group(let g, _) = target, groupIndex(g) == nil { return [] }
        var m = model()
        m.detach(id)
        m.put(.tab(id), at: target)
        var t = items[i]
        switch target {
        case .grid, .persistent:
            t.isPinned = true
            t.inGrid = { if case .grid = target { true } else { false } }()
            t.groupID = nil
            t.pinnedURL = t.pinnedURL ?? t.url
        case .day:
            t.isPinned = false; t.inGrid = false; t.groupID = nil; t.pinnedURL = nil
        case .group(let g, _):
            t.isPinned = false; t.inGrid = false; t.pinnedURL = nil; t.groupID = g
        }
        items[i] = t
        commit(m)
        return [id]
    }

    /// The address a pinned tab goes back to (loaded by the caller); the tab's own address becomes it. Nil when not pinned.
    public mutating func resetToPinned(_ id: TabID) -> String? {
        guard let i = index(of: id), items[i].isPinned, let p = items[i].pinnedURL else { return nil }
        items[i].url = p
        return p
    }

    /// Use Current Page as Pinned Page. False when not pinned.
    @discardableResult
    public mutating func usePinnedPage(_ id: TabID) -> Bool {
        guard let i = index(of: id), items[i].isPinned else { return false }
        items[i].pinnedURL = items[i].url
        return true
    }

    // MARK: groups

    /// A new group named |name| (white) around the tab, where the tab was: in the persistent area for a pinned tab (a grid tile goes
    /// to its top), in the day list for a day tab, right after its group for a grouped one. Nil for an unknown tab.
    @discardableResult
    public mutating func createGroup(with id: TabID, name: String = "Untitled", groupID: GroupID = GroupID()) -> GroupID? {
        guard let i = index(of: id), groupIndex(groupID) == nil else { return nil }
        var m = model()
        let spot: DropTarget
        switch m.position(of: id) {
        case .grid?: spot = .persistent(0)
        case .persistent(let k)?: spot = .persistent(k)
        case .day(let k)?: spot = .day(k)
        case .group(let g, _)?:
            switch m.position(of: g) {
            case .persistent(let k)?: spot = .persistent(k + 1)
            case .day(let k)?: spot = .day(k + 1)
            default: return nil
            }
        case nil: return nil
        }
        m.detach(id)
        m.put(.group(groupID), at: spot)
        m.kids[groupID] = [id]
        var pinned = false
        if case .persistent = spot { pinned = true }
        groups.append(TabGroup(id: groupID, name: name, colorIndex: 0, icon: nil, isCollapsed: false, isPinned: pinned))
        items[i].isPinned = false; items[i].inGrid = false; items[i].pinnedURL = nil; items[i].groupID = groupID
        commit(m)
        return groupID
    }

    /// Joins a group (at its end) or, with nil, leaves it for the place right after it. Unchanged or unknown: [].
    @discardableResult
    public mutating func setGroup(_ id: TabID, _ group: GroupID?) -> [TabID] {
        guard let i = index(of: id) else { return [] }
        if let group { return move(id, to: .group(group, Int.max)) }
        guard let g = items[i].groupID, let at = model().position(of: g) else { return [] }
        switch at {
        case .persistent(let k): return move(id, to: .persistent(k + 1))
        case .day(let k): return move(id, to: .day(k + 1))
        default: return []
        }
    }

    /// A group moves with its children, into the persistent area or the day list only (a group never nests). False when rejected.
    @discardableResult
    public mutating func moveGroup(_ id: GroupID, to target: DropTarget) -> Bool {
        guard let g = groupIndex(id) else { return false }
        var m = model()
        switch target {
        case .persistent, .day: break
        default: return false
        }
        m.top.removeAll { $0 == .group(id) }
        m.day.removeAll { $0 == .group(id) }
        m.put(.group(id), at: target)
        if case .persistent = target { groups[g].isPinned = true } else { groups[g].isPinned = false }
        commit(m)
        return true
    }

    /// Pin on a group: it moves to the end of the persistent area.
    @discardableResult
    public mutating func pinGroup(_ id: GroupID) -> Bool { moveGroup(id, to: .persistent(Int.max)) }

    /// Unpin on a group: it moves to the top of the day list.
    @discardableResult
    public mutating func unpinGroup(_ id: GroupID) -> Bool { moveGroup(id, to: .day(0)) }

    /// An empty, expanded group at the top of the day list (the sidebar menu's New Group). A known id changes nothing.
    @discardableResult
    public mutating func createEmptyGroup(name: String = "Untitled", groupID: GroupID = GroupID()) -> GroupID? {
        guard groupIndex(groupID) == nil else { return nil }
        var m = model()
        m.put(.group(groupID), at: .day(0))
        groups.append(TabGroup(id: groupID, name: name, colorIndex: 0, icon: nil, isCollapsed: false, isPinned: false))
        commit(m)
        return groupID
    }

    /// The group's color, an index into the 8 swatches (out of range is clamped).
    public mutating func setGroupColor(_ id: GroupID, _ colorIndex: Int) {
        if let g = groupIndex(id) { groups[g].colorIndex = min(max(colorIndex, 0), 7) }
    }

    /// The group's icon (an emoji or a symbol name); nil or empty goes back to the default.
    public mutating func setGroupIcon(_ id: GroupID, _ icon: String?) {
        if let g = groupIndex(id) { groups[g].icon = icon?.isEmpty == false ? icon : nil }
    }

    public mutating func collapse(_ id: GroupID, _ collapsed: Bool = true) {
        if let g = groupIndex(id) { groups[g].isCollapsed = collapsed }
    }

    public mutating func renameGroup(_ id: GroupID, _ name: String) {
        if let g = groupIndex(id) { groups[g].name = name }
    }

    /// Takes the group out and leaves its children in its place, in order (loose pinned rows when the group was pinned). Returns them.
    @discardableResult
    public mutating func ungroup(_ id: GroupID) -> [TabID] {
        guard let g = groupIndex(id) else { return [] }
        var m = model()
        let kids = m.kids[id] ?? []
        let pinned = groups[g].isPinned
        let refs = kids.map(TopRef.tab)
        if pinned, let k = m.top.firstIndex(of: .group(id)) { m.top.replaceSubrange(k...k, with: refs) }
        if !pinned, let k = m.day.firstIndex(of: .group(id)) { m.day.replaceSubrange(k...k, with: refs) }
        m.kids[id] = nil
        groups.remove(at: g)
        for t in kids {
            guard let i = index(of: t) else { continue }
            items[i].groupID = nil
            items[i].isPinned = pinned
            items[i].pinnedURL = pinned ? (items[i].pinnedURL ?? items[i].url) : nil
        }
        commit(m)
        return kids
    }

    /// Deletes the group. With |closeTabs| its children leave the list too and are returned (the caller closes their engine tabs;
    /// the active one hands over as in |remove|); without, it is |ungroup|.
    @discardableResult
    public mutating func deleteGroup(_ id: GroupID, closeTabs: Bool) -> [TabID] {
        guard let g = groupIndex(id) else { return [] }
        guard closeTabs else { return ungroup(id) }
        let kids = items.filter { $0.groupID == id }.map(\.id)
        for t in kids { _ = take(t) }
        var m = model()
        m.top.removeAll { $0 == .group(id) }
        m.day.removeAll { $0 == .group(id) }
        m.kids[id] = nil
        groups.remove(at: g)
        commit(m)
        return kids
    }

    // MARK: order

    /// The sidebar's rows (collapsed groups hide their children).
    public func layout() -> [SidebarEntry] {
        var out: [SidebarEntry] = items.filter { $0.isPinned && $0.inGrid }.map { .gridTile($0.id) }
        func flat(_ refs: [TopRef]) {
            for r in refs {
                switch r {
                case .tab(let t): out.append(.tab(t, level: 0))
                case .group(let g):
                    out.append(.group(g))
                    guard groups.first(where: { $0.id == g })?.isCollapsed != true else { continue }
                    for t in items where t.groupID == g { out.append(.tab(t.id, level: 1)) }
                }
            }
        }
        flat(topOrder)
        out.append(.divider)
        out.append(.newTab)
        flat(dayOrder)
        return out
    }

    /// The next row (wrapping, hidden children skipped) after |id|, which may itself be hidden. An unknown id gives nil.
    public func nextVisible(after id: TabID) -> TabID? { neighbor(of: id, offset: 1) }
    public func previousVisible(before id: TabID) -> TabID? { neighbor(of: id, offset: -1) }
    public func next(after id: TabID) -> TabID? { nextVisible(after: id) }
    public func previous(before id: TabID) -> TabID? { previousVisible(before: id) }

    private func neighbor(of id: TabID, offset: Int) -> TabID? {
        guard let i = index(of: id) else { return nil }
        let n = items.count
        for k in 1...n {
            let t = items[((i + offset * k) % n + n) % n]
            if !isHidden(t) { return t.id }
        }
        return nil
    }

    public func displayTitle(of id: TabID) -> String {
        guard let t = items.first(where: { $0.id == id }) else { return "New Tab" }
        return Self.displayTitle(for: t)
    }

    public static func displayTitle(for t: TabItem) -> String {
        if let c = t.customTitle, !c.isEmpty { return c }
        guard t.url != "about:blank" else { return "New Tab" }
        if !t.title.isEmpty { return t.title }
        let host = AddressInput.displayHost(t.url)
        return t.url.isEmpty || host.isEmpty ? "New Tab" : host
    }

    // MARK: cleanup, archive, MRU, search

    /// Day, grouped and dormant tabs not used for longer than |threshold| seconds (strictly: a tab used exactly |threshold| ago stays).
    /// Never the pinned, the active or a loading tab, nor one in |excluding| (audible, presenting: the caller knows). Nil is Never.
    public func cleanupCandidates(now: Date, threshold: TimeInterval?, excluding: Set<TabID> = []) -> [TabID] {
        guard let threshold else { return [] }
        let cutoff = now.addingTimeInterval(-threshold)
        return items.filter { !$0.isPinned && $0.id != activeID && !$0.isLoading && !excluding.contains($0.id) && $0.lastActiveAt < cutoff }.map(\.id)
    }

    /// Moves tabs out of the list into |archived| (no engine tab, |archivedAt| = |now|, the group id kept), in list order. Pinned and
    /// unknown ids are skipped; archiving the active tab hands over as in |remove|. Returns the archived ids.
    @discardableResult
    public mutating func archive(_ ids: [TabID], now: Date) -> [TabID] {
        let wanted = Set(ids)
        var done: [TabID] = []
        for t in items where wanted.contains(t.id) && !t.isPinned {
            guard var item = take(t.id)?.item else { continue }
            item.archivedAt = now
            item.engineID = nil
            archived.append(item)
            done.append(item.id)
        }
        return done
    }

    /// An archived tab comes back dormant: at the end of its group when that still exists, else at the top of the day list.
    @discardableResult
    public mutating func restore(_ id: TabID) -> Bool {
        guard let a = archived.firstIndex(where: { $0.id == id }) else { return false }
        var t = archived.remove(at: a)
        t.archivedAt = nil
        return insertNew(t, opener: nil, addToTop: true, activate: false)
    }

    /// Live tabs, the most recently used first (equal stamps: the later activation, then list order).
    public func mru(limit: Int = 8) -> [TabID] {
        recency(items).prefix(max(limit, 0)).map(\.id)
    }

    private func recency(_ tabs: [TabItem]) -> [TabItem] {
        tabs.enumerated().sorted { a, b in
            if a.element.lastActiveAt != b.element.lastActiveAt { return a.element.lastActiveAt > b.element.lastActiveAt }
            let (x, y) = (activation[a.element.id] ?? 0, activation[b.element.id] ?? 0)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// Search Tabs: live tabs, then archived ones. Each block ranks prefix, substring, subsequence, and within a rank the most recent
    /// first. An empty query lists the live tabs in MRU order, then the archived ones newest first.
    public func searchTabs(query: String) -> [TabID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let archivedOrder = archived.sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        func ranked(_ order: [TabItem]) -> [TabID] {
            order.enumerated().compactMap { i, t -> (Int, Int, TabID)? in
                let title = (t.customTitle?.isEmpty == false ? t.customTitle : nil) ?? t.title
                return TabSearch.rank(q, title: title, url: t.url).map { ($0, i, t.id) }
            }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        }
        return ranked(recency(items)) + ranked(archivedOrder)
    }
}
