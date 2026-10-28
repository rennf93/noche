import AppKit
import CefBridge
import NocheCore

/// One row of a menu Noche builds itself (tab row, empty sidebar). |run| nil: the item is present and disabled until |milestone|.
@MainActor
struct CtxEntry {
    var title: String
    var id: String?               // the ShortcutDefaults id whose key equivalent is shown
    var run: (@MainActor () -> Void)?
    var enabled = true
    var checked = false
    var milestone: String?
    var submenu = false           // a submenu header (its items arrive with the feature)
    var children: [CtxEntry]?     // a live submenu's items; the header is enabled by |enabled|
    var separator = false
    var view: NSView?             // a row drawn by a view (the group menu's color swatches)
    static let sep = CtxEntry(title: "", separator: true)
    static func later(_ title: String, _ milestone: String, id: String? = nil, submenu: Bool = false, checked: Bool = false) -> CtxEntry {
        CtxEntry(title: title, id: id, checked: checked, milestone: milestone, submenu: submenu)
    }
}

/// Context menus: the page's (Chromium's model as an NSMenu) and Noche's own for a tab row and the empty sidebar.
@MainActor
enum ContextMenus {
    /// Every item's action: runs the closure kept on the item. (NSMenuItem holds its target weakly, so the target lives here.)
    final class Target: NSObject {
        @objc func fire(_ item: NSMenuItem) { (item.representedObject as? Run)?.run() }
    }
    final class Run: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
    static let target = Target()

#if NOCHE_TESTHOOKS
    /// A hidden window is never key and must never raise a menu: test builds keep the menu here instead of showing it, and the check
    /// chooses an item (or dismisses it) the way the menu's tracking loop would.
    struct Pending {
        let kind: String
        let menu: NSMenu
        let model: [NCMenuItem]?
        let point: NSPoint
        let finish: () -> Void
    }
    static var pending: Pending?
    static var shown = 0
    /// Chooses |item| as a click would (nothing happens for a disabled item), then ends the menu; nil dismisses it (a click outside).
    static func dismiss(choosing item: NSMenuItem?) {
        guard let p = pending else { return }
        pending = nil
        if let item, item.isEnabled, let menu = item.menu, let i = menu.items.firstIndex(of: item) { menu.performActionForItem(at: i) }
        if item == nil, env("NOCHE_TEST_CTX_NOCANCEL") { return }  // negative control: a dismissed menu is dropped without its completion
        p.finish()
    }
    enum TestCancel { case now, late, never }
    static var testCancel = TestCancel.now
    private static var lateScheduled = false
    static func env(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }
#endif

    /// The menu whose tracking loop is running (test builds: the one held in `pending`), nil when none is.
    private(set) static var tracked: NSMenu?
    static var tracking: Bool { tracked != nil }
    /// Ends an open menu as a click outside would; the tracking loop returns on its own turn, so a caller that must run clear of it waits for `tracking` to end.
    static func cancelOpen() {
#if NOCHE_TESTHOOKS
        if env("NOCHE_TEST_QUIT_KEEPMENU") { return }  // negative control: the quit leaves the menu open
        switch testCancel {
        case .now: dismiss(choosing: nil)
        case .late:  // the tracking loop ends on a later turn, as AppKit's does after cancelTracking
            if !lateScheduled { lateScheduled = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dismiss(choosing: nil) } }
        case .never: break  // a menu that does not end
        }
#else
        tracked?.cancelTracking()
#endif
    }

    /// Shows |menu| at |point| (window base coordinates) and calls |done| when the tracking ends, whether an item ran or not.
    static func present(_ menu: NSMenu, kind: String, model: [NCMenuItem]? = nil, in c: BrowserWindowController, at point: NSPoint, done: @escaping () -> Void) {
#if NOCHE_TESTHOOKS
        shown += 1
        if let old = pending { pending = nil; old.finish() }  // a menu replaced by the next one ends first, never dropped
        tracked = menu
        pending = Pending(kind: kind, menu: menu, model: model, point: point, finish: { tracked = nil; done() })
        return
#else
        guard let host = c.window.chromeHost else { return done() }
        tracked = menu
        menu.popUp(positioning: nil, at: host.convert(point, from: nil), in: host)
        tracked = nil
        done()
#endif
    }

    private static func key(_ item: NSMenuItem, _ id: String?) {
        guard let chord = id.flatMap(ShortcutDefaults.chord(for:)) else { return }
        item.keyEquivalent = chord.menuKey.key
        item.keyEquivalentModifierMask = chord.menuKey.mods
    }

    // MARK: the page's menu

    /// Chromium's model as an NSMenu. Labels are Chromium's own. Hidden rows are skipped and the separators left leading, trailing or doubled are
    /// dropped, because the model is built for Chromium's own menu, which does the same. |chosen| gets the command id of the item that ran.
    static func pageMenu(_ items: [NCMenuItem], chosen: @escaping (Int) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var lastSeparator = true  // no leading separator
        for m in items where m.visible {
            if m.type == .separator {
                if !lastSeparator { menu.addItem(.separator()) }
                lastSeparator = true
                continue
            }
            lastSeparator = false
            let item = NSMenuItem(title: m.label, action: #selector(Target.fire(_:)), keyEquivalent: "")
            item.target = target
            item.tag = m.commandId
            item.isEnabled = m.enabled
#if NOCHE_TESTHOOKS
            if env("NOCHE_TEST_CTX_NOENABLE") { item.isEnabled = true }  // negative control: the model's enabled flag is ignored
#endif
            if m.type == .check || m.type == .radio { item.state = m.checked ? .on : .off }
            if m.type == .submenu {
                if let sub = m.submenu { item.submenu = pageMenu(sub, chosen: chosen) }
                item.action = nil
            } else {
                let id = m.commandId
                var run = { chosen(id) }
#if NOCHE_TESTHOOKS
                if env("NOCHE_TEST_CTX_NOCHOOSE") { run = {} }  // negative control: a chosen item is never reported back
                if env("NOCHE_TEST_CTX_NOEXT"), id >= 49000 { run = { chosen(-1) } }  // negative control: an extension item is reported as a cancel
#endif
                item.representedObject = Run(run)
            }
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    // MARK: Noche's own menus

    static func menu(_ entries: [CtxEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            if e.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: e.title, action: #selector(Target.fire(_:)), keyEquivalent: "")
            item.target = target
            key(item, e.id)
            item.state = e.checked ? .on : .off
            if let children = e.children {
                item.submenu = ContextMenus.menu(children)
                item.action = nil
            } else if e.submenu {
                item.submenu = NSMenu(title: e.title)
                item.action = nil
            }
            var run = e.run
#if NOCHE_TESTHOOKS
            if run == nil, env("NOCHE_TEST_CTX_TABENABLE") { run = {} }  // negative control: a later-milestone item is enabled
#endif
            if let run { item.representedObject = Run { run() } }
            item.isEnabled = e.children != nil ? e.enabled : run != nil && e.enabled && !e.submenu
            if let v = e.view { item.view = v; item.isEnabled = true }
            menu.addItem(item)
        }
        return menu
    }
}

extension BrowserWindowController {
    // MARK: events

    /// The page's right click: Chromium's model as a native menu; the chosen command runs in the engine.
    func window(_ window: NCWindow, tab: NCTab, showContextMenu items: [NCMenuItem], atWindowPoint point: NSPoint, completion: @escaping (Int) -> Void) {
        final class Chosen { var id = -1 }
        let chosen = Chosen()
        let menu = ContextMenus.pageMenu(items) { chosen.id = $0 }
        ContextMenus.present(menu, kind: "page", model: items, in: self, at: point) { completion(chosen.id) }
    }

    func showTabMenu(row i: Int, at point: NSPoint) {
        guard i < list.items.count else { return }
        let t = list.items[i]
        ContextMenus.present(ContextMenus.menu(tabMenuEntries(for: t)), kind: "tab", in: self, at: point) {}
    }

    func showGroupMenu(group g: GroupID, at point: NSPoint) {
        guard group(withID: g) != nil else { return }
        ContextMenus.present(ContextMenus.menu(groupMenuEntries(for: g)), kind: "group", in: self, at: point) {}
    }

    func showSidebarMenu(at point: NSPoint) {
        ContextMenus.present(ContextMenus.menu(sidebarMenuEntries()), kind: "sidebar", in: self, at: point) {}
    }

    // MARK: the menus (live-ui.md section 3; the separators are a builder call, the capture lists the items only)

    /// A menu-bar row used as a context item: its title, key, enabled rule and checkmark come from `MenuTable`, the action is |run|.
    private func tableRow(_ id: String, _ run: @escaping @MainActor () -> Void) -> CtxEntry {
        guard let e = MenuTable.entry(id: id) else { return CtxEntry(title: id) }
        let ctx = MenuContext(app: app, window: self)
        return CtxEntry(title: e.title, id: id, run: run, enabled: e.enabled(ctx), checked: e.state?(ctx) ?? false)
    }

    /// The tab row's menu. A dormant tab has no engine tab: Duplicate and Copy Link use its address, and Close is disabled (it is closed).
    func tabMenuEntries(for t: TabItem) -> [CtxEntry] {
        typealias E = CtxEntry
        let id = t.id
        let tab = engineTab(t)
        let pin = E(title: t.isPinned ? "Unpin" : "Pin", id: "tabs.pinTab") { [weak self] in self?.togglePin(of: id) }
        let duplicate = E(title: "Duplicate", id: "tabs.duplicateTab") { [weak self, weak tab] in
            if let tab { self?.duplicateTab(of: tab) } else { self?.openInNewTab(t.pinnedURL ?? t.url, note: "duplicateTab") }
        }
        let copyLink = E(title: "Copy Link", id: "edit.copyURL") { [weak self, weak tab] in
            if let tab { self?.copyURL(of: tab) } else { self?.copyText(t.url, note: "copyURL") }
        }
        let close = E(title: "Close", id: "file.closeTab", run: { [weak self, weak tab] in if let tab { self?.closeTab(tab) } }, enabled: tab != nil)
        // Edit Pinned Page (spec section 2): Use Current Page as Pinned Page and Reset to Pinned Page act only off the pinned page.
        let off = offPinnedPage(t)
        let editPinned: E = t.isPinned
            ? E(title: "Edit Pinned Page", run: {}, children: [
                E(title: "Use Current Page as Pinned Page", run: { [weak self] in self?.usePinnedPage(id) }, enabled: off),
                E(title: "Reset to Pinned Page", run: { [weak self] in self?.resetToPinned(id) }, enabled: off),
                E(title: "Copy Pinned URL", run: { [weak self] in self?.copyPinnedURL(id) })])
            : .later("Edit Pinned Page", "M1.6", submenu: true)
        // New Group with Tab and Move to Group (the groups of this window, the tab's own checked).
        let newGroup = E(title: "New Group with Tab", id: "tabs.newGroupWithTabs") { [weak self] in self?.newGroupWithTab(id) }
        let groups = list.groups
        let moveTo = E(title: "Move to Group", run: {}, enabled: !groups.isEmpty, children: groups.map { g in
            E(title: g.name, run: { [weak self] in self?.moveToGroup(id, g.id) }, checked: t.groupID == g.id)
        })
        var middle: [E] = [duplicate, newGroup, moveTo, .later("Move to Profile", "M1.7", submenu: true), .sep, copyLink]
#if NOCHE_TESTHOOKS
        if ContextMenus.env("NOCHE_TEST_CTX_TABORDER") { middle[0] = copyLink; middle[5] = duplicate }  // negative control: Copy Link and Duplicate trade places
#endif
        let rename = E(title: "Rename...") { [weak self] in self?.beginRename(tab: id) }
        let icon = E(title: "Change Icon...") { [weak self] in self?.changeIcon(tab: id) }
        return [pin, .sep, .later("Chat With This Tab", "M2"), .later("Open as Split", "M1.10"), .sep] + middle
            + [.sep, rename, icon, editPinned, .sep, close]
    }

    /// The group row's menu (live-ui.md section 3). Chat With, Move to Window and Move to Profile wait for their features (Move to Window for
    /// Task 5b); the rest is live. The separators are a builder call: Pin | New Tab in Group, Chat With | Separate Tabs ... Copy All Links |
    /// the swatches | Rename, Change Icon | Move to Bookmark Bar | Delete.
    func groupMenuEntries(for g: GroupID) -> [CtxEntry] {
        typealias E = CtxEntry
        guard let grp = group(withID: g) else { return [] }
        let kids = members(of: g)
        let pin = E(title: grp.isPinned ? "Unpin" : "Pin") { [weak self] in self?.togglePin(group: g) }
        let swatches = SwatchRowView(selected: grp.colorIndex)
        swatches.onPick = { [weak self] i in self?.setGroupColor(g, i) }
        var rename = E(title: "Rename...") { [weak self] in self?.beginRename(group: g) }
        var icon = E(title: "Change Icon...") { [weak self] in self?.changeIcon(group: g) }
#if NOCHE_TESTHOOKS
        if ContextMenus.env("NOCHE_TEST_CTX_GROUPORDER") { swap(&rename, &icon) }  // negative control: Rename and Change Icon trade places
#endif
        return [pin, .sep,
                E(title: "New Tab in Group", id: "file.newTabInGroup") { [weak self] in self?.newTabInGroup(g) },
                .later("Chat With \"\(grp.name)\"", "M2"), .sep,
                E(title: "Separate Tabs") { [weak self] in if !BarHook.on("GRP_NOSEP") { self?.separateTabs(g) } },  // the hook: the menu item does nothing
                E(title: "Duplicate") { [weak self] in self?.duplicateGroup(g) },
                .later("Move to Window", "M1.6", submenu: true),
                .later("Move to Profile", "M1.7", submenu: true),
                E(title: "Copy All Links", run: { [weak self] in self?.copyAllLinks(g) }, enabled: !kids.isEmpty),
                .sep, E(title: "Colors", view: swatches), .sep, rename, icon, .sep,
                E(title: "Move to Bookmark Bar", run: { [weak self] in self?.moveGroupToBookmarkBar(g) }, enabled: kids.contains { isWeb($0.url) }),
                E(title: "Delete") { [weak self] in self?.deleteGroup(g) }]
    }

    func sidebarMenuEntries() -> [CtxEntry] {
        var closeAll = tableRow("file.closeAllTabs") { [weak self] in self?.closeAllTabs() }  // its enable rule is the table's
#if NOCHE_TESTHOOKS
        if ContextMenus.env("NOCHE_TEST_CTX_CLOSEALLBLANK") { closeAll.enabled = true }  // negative control: enabled on a lone blank tab
#endif
        var reopen = tableRow("file.reopenClosedTab") { [weak self] in self?.app.reopenClosedTab(nil) }
#if NOCHE_TESTHOOKS
        if ContextMenus.env("NOCHE_TEST_CTX_NOREOPEN") { reopen.enabled = false }  // negative control: Reopen Closed Tab stays disabled
#endif
        let bookmarkAll = CtxEntry(title: "Bookmark All Tabs", run: { [weak self] in self?.bookmarkAllTabs() }, enabled: !bookmarkableTabs.isEmpty)
        return [tableRow("file.newTab") { [weak self] in self?.newTab() }, reopen, .sep,
                CtxEntry(title: "New Group", run: { [weak self] in self?.newGroup() }), .later("New Live Group", "M1.6", submenu: true), .later("New Profile...", "M1.7"), .sep,
                bookmarkAll, .sep,
                .later("Show Tabs in Sidebar", "M1.6", id: "view.showTabsInSidebar", checked: true),
                tableRow("view.autoHideTabs") { [weak self] in self?.toggleSidebar() }, .sep, closeAll]
    }
}
