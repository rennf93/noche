import AppKit
import CefBridge
import NocheCore

extension BrowserWindowController {
    /// What a realized sidebar entry shows; nil for an entry whose tab or group is gone (the next refresh drops it).
    func sidebarContent(for entry: SidebarEntry) -> SidebarContent? {
        switch entry {
        case .tab(let id, _):
            guard let t = list.items.first(where: { $0.id == id }) else { return nil }
            return .tab(title: TabList.displayTitle(for: t), favicon: icon(of: t), selected: id == list.activeID, dormant: t.engineID == nil, canReset: offPinnedPage(t))
        case .gridTile(let id):
            guard let t = list.items.first(where: { $0.id == id }) else { return nil }
            return .tile(title: TabList.displayTitle(for: t), favicon: icon(of: t), selected: id == list.activeID, dormant: t.engineID == nil, loading: t.isLoading, canReset: offPinnedPage(t))
        case .group(let g):
            guard let group = list.groups.first(where: { $0.id == g }) else { return nil }
            let hasActive = list.activeID.flatMap { a in list.items.first { $0.id == a } }?.groupID == g
            return .group(name: group.name, icon: group.icon, colorIndex: group.colorIndex, collapsed: group.isCollapsed, hasActive: hasActive)
        case .divider, .newTab: return nil
        }
    }

    private func icon(of t: TabItem) -> NSImage? { engineTab(t)?.favicon ?? dormantIcons[t.id] }

    /// A pinned tab that is not on its pinned page (the return glyph shows on hover).
    func offPinnedPage(_ t: TabItem) -> Bool { t.isPinned && (t.pinnedURL.map { $0 != t.url } == true || BarHook.on("PIN_GLYPH")) }  // the hook: the glyph always shows

    /// The row's index in the list (the order of record) for the sidebar's callbacks, which name tabs by id.
    func row(of id: TabID) -> Int? { list.items.firstIndex { $0.id == id } }

    func toggleGroup(_ g: GroupID) {
        guard let group = list.groups.first(where: { $0.id == g }) else { return }
        list.collapse(g, !group.isCollapsed)
        refresh()
        changed()
    }

#if NOCHE_TESTHOOKS
    /// Test support: the window shows |seeded| (a composition no UI can build yet) and stops saving, so the test profile never keeps it.
    func testSeed(_ seeded: TabList) {
        restoring = true
        list = seeded
        refreshNow()
    }
#endif
}
