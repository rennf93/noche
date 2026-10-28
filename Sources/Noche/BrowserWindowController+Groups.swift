import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Tab groups and the rename and icon actions of tabs and groups (M1.6 Task 4). The list holds the structure (`TabList`); these are the
/// actions the menus and the sidebar call, each one a list change followed by a refresh and a save.
extension BrowserWindowController {
    func group(withID g: GroupID) -> TabGroup? { list.groups.first { $0.id == g } }
    func members(of g: GroupID) -> [TabItem] { list.items.filter { $0.groupID == g } }
    /// The group the active tab is in (File > New Tab in Group needs one).
    var activeGroup: GroupID? { list.activeID.flatMap { item(withID: $0)?.groupID } }
    static var staleIcon: TabID?
    private static let pageTitleWins = BarHook.on("RENAME_PAGEWINS")  // negative control: the page's title shows over a custom one

    // MARK: making groups

    /// Tabs > New Group with Tab: a group named Untitled around the tab, where the tab was, its name already being edited.
    func newGroupWithTab(_ target: TabID? = nil) {
        note("newGroupWithTab")
        guard let id = target ?? list.activeID, let g = list.createGroup(with: id) else { return }
        showAndRename(g)
    }

    /// The sidebar menu's New Group: an empty group at the top of the day list.
    func newGroup() {
        note("newGroup")
        guard let g = list.createEmptyGroup() else { return }
        showAndRename(g)
    }

    private func showAndRename(_ g: GroupID) {
        if (try? app.writer?.store.setting("emojiForNewGroups")).flatMap({ $0 }) == "1", !BarHook.on("GRP_NOEMOJI") {  // the hook: no emoji
            list.setGroupIcon(g, GroupEmoji.pick(list.groups.count - 1))
        }
        refreshNow()
        changed()
        if !BarHook.on("GRP_NOINLINE") { sidebar.beginRename(group: g) }  // the hook: the name is never editable
    }

    /// File > New Tab in Group, and the group menu's item: a blank tab that joins |g| (the active tab's group by default) once the engine reports it.
    func newTabInGroup(_ g: GroupID? = nil) {
        note("newTabInGroup")
        guard let g = g ?? activeGroup else { return }
        list.collapse(g, false)
        closeNext.removeAll()
        guard let tab = window.addTab(withURL: "about:blank", activate: true) else { return }
        if !BarHook.on("GRP_NOJOIN") { groupJoins[tab.identifier] = GroupJoin(group: g, template: nil) }  // the hook: the tab lands outside the group
        intendedActive = tab
        refresh()
        changed()
    }

    /// A new engine tab's list item joins its group (a group copy is made when its first tab arrives).
    func joinGroup(_ id: TabID, _ join: GroupJoin) {
        if group(withID: join.group) != nil { list.setGroup(id, join.group); return }
        guard let t = join.template, list.createGroup(with: id, name: t.name, groupID: t.id) != nil else { return }
        list.setGroupColor(t.id, t.colorIndex)
        list.setGroupIcon(t.id, t.icon)
        if t.isPinned, !BarHook.on("GRP_DUPUNPIN") { list.pinGroup(t.id) }  // a copy of a pinned group is pinned (the hook: it lands in the day list)
    }

    /// The tab menu's Move to Group: the tab goes to the end of the group, which opens.
    func moveToGroup(_ id: TabID, _ g: GroupID) {
        note("moveToGroup")
        if BarHook.on("GRP_NOMOVE") { return }  // negative control: the pick does nothing
        list.setGroup(id, g)
        list.collapse(g, false)
        refresh()
        changed()
    }

    // MARK: group menu

    /// Pin on a day group moves it to the persistent area, Unpin back to the top of the day list.
    func togglePin(group g: GroupID) {
        note("pinGroup")
        guard let grp = group(withID: g), !BarHook.on("GRP_NOPIN") else { return }  // the hook: Pin and Unpin do nothing
        if grp.isPinned { list.unpinGroup(g) } else { list.pinGroup(g) }
        refresh()
        changed()
    }

    /// Separate Tabs: the group goes, its tabs stay where it was.
    func separateTabs(_ g: GroupID) {
        note("separateTabs")
        list.ungroup(g)
        refresh()
        changed()
    }

    /// Duplicate: a copy of the group (name, color and icon) with a new tab at each member's address.
    func duplicateGroup(_ g: GroupID) {
        note("duplicateGroup")
        guard let grp = group(withID: g), !BarHook.on("GRP_NODUP") else { return }  // the hook: nothing is copied
        let copy = TabGroup(id: GroupID(), name: grp.name, colorIndex: grp.colorIndex, icon: grp.icon, isCollapsed: false, isPinned: grp.isPinned)
        closeNext.removeAll()
        for t in members(of: g) {
            guard let tab = window.addTab(withURL: t.pinnedURL ?? t.url, activate: false) else { continue }
            groupJoins[tab.identifier] = GroupJoin(group: copy.id, template: copy)
        }
    }

    func copyAllLinks(_ g: GroupID) {
        copyText(members(of: g).map(\.url).joined(separator: "\n"), note: "copyAllLinks")
    }

    func setGroupColor(_ g: GroupID, _ colorIndex: Int) {
        note("groupColor")
        list.setGroupColor(g, colorIndex)
        refresh()
        changed()
    }

    /// Move to Bookmark Bar: the group's web pages become a folder on the bar named for it; the group is separated (its tabs stay open).
    func moveGroupToBookmarkBar(_ g: GroupID) {
        note("groupToBookmarkBar")
        guard let grp = group(withID: g), let store = app.writer?.store, let bar = (try? store.bookmarkRoots().first).flatMap({ $0 }) else { return }
        let pages = members(of: g).filter { isWeb($0.url) }.map { (title: TabList.displayTitle(for: $0), url: $0.url) }
        guard !pages.isEmpty else { return }
        do { if !BarHook.on("GRP_NOBAR") { try store.addFolder(title: grp.name, parentId: bar.id, bookmarks: pages) } } catch { return app.logBookmark("group", error) }
        app.bookmarksChanged()
        separateTabs(g)
    }

    /// Delete: the group goes and its tabs close, after a confirm when it holds more than one tab (T4.2). The window keeps an engine tab;
    /// each closed tab goes on the reopen list.
    func deleteGroup(_ g: GroupID) {
        note("deleteGroup")
        guard let grp = group(withID: g) else { return }
        let kids = members(of: g)
        if kids.count > 1, !BarHook.on("GRP_NOCONFIRM"),  // the hook: no question is asked
           !Confirm.ask(.init(message: "Delete \"\(grp.name)\"?", detail: "Its \(kids.count) tabs will be closed.", button: "Delete")) { return }
        let live = kids.compactMap { engineTab($0) }
        let others = orderedTabs().filter { t in !isClosing(t) && !live.contains { $0 === t } }
        let wasActive = live.contains { $0 === (intendedActive ?? activeTab) }
        let at = kids.map { list.containerIndex(of: $0.id) ?? 0 }
        list.deleteGroup(g, closeTabs: true)
        closeNext.removeAll()
        if others.isEmpty {
            intendedActive = window.addTab(withURL: "about:blank", activate: true)
        } else if wasActive {
            let next = list.activeID.flatMap { item(withID: $0) }.flatMap { engineTab($0) } ?? others[0]
            intendedActive = next
            window.activateTab(next)
        }
        for (t, i) in zip(kids, at) where !app.closing { app.writer?.closed(tab: t, window: id, index: i) }
        let now = ProcessInfo.processInfo.systemUptime
        for tab in live { closing[tab.identifier] = now; tab.close() }
        refresh()
        changed()
    }

    // MARK: rename and icon

    /// Rename... on a tab: its title becomes an inline field (a grid tile, which shows no title, asks in a small popover).
    func beginRename(tab id: TabID) {
        note("renameBegin")
        guard let t = item(withID: id) else { return }
        if let g = t.groupID, group(withID: g)?.isCollapsed == true { list.collapse(g, false); refreshNow() }
        if sidebar.beginRename(tab: id) { return }
        guard let anchor = sidebar.anchor(tab: id) else { return }
        RenamePopover.present(from: anchor, text: TabList.displayTitle(for: t), returnFocus: { [weak self] free in self?.returnFocus(afterRename: free) }) { [weak self] text in self?.renameTab(id, to: text) }
    }

    func beginRename(group g: GroupID) {
        note("renameBegin")
        sidebar.beginRename(group: g)
    }

    /// The field committed: the text is the tab's own title, which shows in place of the page's; empty goes back to the page's. The page's
    /// own title unchanged is not a custom title (the page keeps naming the tab).
    func renameTab(_ id: TabID, to text: String) {
        note("renameTab")
        guard let t = item(withID: id) else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The page's own title is not a custom one: typing it (over a custom title) goes back to following the page. The hook compares with the shown title.
        let page = BarHook.on("RENAME_SHOWNCMP") ? TabList.displayTitle(for: t) : t.title
        if name == TabList.displayTitle(for: t), name != page || t.customTitle == nil, !BarHook.on("RENAME_NOEARLY") { return }  // the hook: an untouched field is a rename
        list.setCustomization(id, title: name == page ? "" : name, icon: t.customIcon)
        refresh()
        changed()
    }

    /// The inline field ended: the page gets focus back (Return, Escape, a row scrolled away). A click elsewhere has moved focus on its own: AppKit
    /// sets the new first responder after the field's end notification, so the next turn tells a click on a control (it keeps focus) from a click on nothing.
    func returnFocus(afterRename onlyIfFree: Bool) {
        guard onlyIfFree else { return window.focusActiveContent() }
        DispatchQueue.main.async { [weak self] in  // the hook RENAME_CLICKSTEALS: the page takes focus whatever the click chose
            guard let self, let ns = nsWindow, BarHook.on("RENAME_CLICKSTEALS") || ns.firstResponder == nil || ns.firstResponder === ns else { return }
            window.focusActiveContent()
        }
    }

    func renameGroup(_ g: GroupID, to text: String) {
        note("renameGroup")
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { list.renameGroup(g, name) }  // an empty name keeps the old one
        refresh()
        changed()
    }

    /// Change Icon... on a tab: the picked icon shows in place of its favicon; Remove Icon brings the favicon back.
    func changeIcon(tab id: TabID) {
        note("changeIcon")
        guard let anchor = sidebar.anchor(tab: id) else { return }
        IconPicker.present(from: anchor) { [weak self] icon in
            guard let self, let t = self.item(withID: id), !BarHook.on("GRP_NOICONSET") else { return }  // the hook: the pick is never written
            if icon == nil, BarHook.on("GRP_STALEICON") { Self.staleIcon = id }  // the hook: Remove Icon leaves the row on another glyph, not the favicon
            self.list.setCustomization(id, title: t.customTitle, icon: icon)
            self.refresh()
            self.changed()
        }
    }

    func changeIcon(group g: GroupID) {
        note("changeIcon")
        guard let anchor = sidebar.anchor(group: g) else { return }
        IconPicker.present(from: anchor) { [weak self] icon in
            if !BarHook.on("GRP_NOGROUPICON") { self?.list.setGroupIcon(g, icon) }  // the hook: the group's pick is never written
            self?.refresh()
            self?.changed()
        }
    }

    /// The title a row shows (a custom one over the page's).
    func shownTitle(_ t: TabItem) -> String { Self.pageTitleWins && !t.title.isEmpty ? t.title : TabList.displayTitle(for: t) }
}

extension BrowserWindowController {
    /// What both Move to Group menus list, in order: a disabled PINNED header (nil), the pinned groups, then the others (spec section 2). Nothing without a group.
    func moveToGroupChoices() -> [TabGroup?] {
        guard !list.groups.isEmpty else { return [] }
        let ordered = BarHook.on("GRP_MTGLISTORDER") ? list.groups : list.groups.filter(\.isPinned) + list.groups.filter { !$0.isPinned }  // the hook: the list's order
        let header: [TabGroup?] = BarHook.on("GRP_NOPINNEDHDR") ? [] : [nil]
        return header + ordered.map { Optional($0) }
    }
}

/// Tabs > Move to Group lists the active window's groups each time it opens (rows without the table's mark: they are not part of the table).
@MainActor
final class MoveToGroupMenuDelegate: NSObject, NSMenuDelegate {
    unowned let app: AppDelegate
    init(app: AppDelegate) { self.app = app }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = app.active, let id = c.list.activeID else { return }
        let current = c.item(withID: id)?.groupID
        for choice in c.moveToGroupChoices() {
            guard let g = choice else {
                if BarHook.on("GRP_BARNOHDR") { continue }  // the hook: only this menu lacks the header
                let header = NSMenuItem(title: "PINNED", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                continue
            }
            let i = NSMenuItem(title: g.name, action: #selector(ContextMenus.Target.fire(_:)), keyEquivalent: "")
            i.target = ContextMenus.target
            i.state = g.id == current ? .on : .off
            i.representedObject = ContextMenus.Run { [weak c] in c?.moveToGroup(id, g.id) }
            menu.addItem(i)
        }
    }
}
