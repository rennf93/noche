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
    var separator = false
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
    static func env(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }
#endif

    /// The menu whose tracking loop is running (test builds: the one held in `pending`), nil when none is.
    private(set) static var tracked: NSMenu?
    static var tracking: Bool { tracked != nil }
    /// Ends an open menu as a click outside would; the tracking loop returns on its own turn, so a caller that must run clear of it waits for `tracking` to end.
    static func cancelOpen() {
#if NOCHE_TESTHOOKS
        if env("NOCHE_TEST_QUIT_KEEPMENU") { return }  // negative control: the quit leaves the menu open
        dismiss(choosing: nil)
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
            if e.submenu {
                item.submenu = NSMenu(title: e.title)
                item.action = nil
            }
            var run = e.run
#if NOCHE_TESTHOOKS
            if run == nil, env("NOCHE_TEST_CTX_TABENABLE") { run = {} }  // negative control: a later-milestone item is enabled
#endif
            if let run { item.representedObject = Run { run() } }
            item.isEnabled = run != nil && e.enabled && !e.submenu
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
        guard i < list.items.count, let tab = engineTab(list.items[i]) else { return }
        ContextMenus.present(ContextMenus.menu(tabMenuEntries(for: tab)), kind: "tab", in: self, at: point) {}
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

    func tabMenuEntries(for tab: NCTab) -> [CtxEntry] {
        typealias E = CtxEntry
        let duplicate = E(title: "Duplicate", id: "tabs.duplicateTab") { [weak self, weak tab] in self?.duplicateTab(of: tab) }
        let copyLink = E(title: "Copy Link", id: "edit.copyURL") { [weak self, weak tab] in self?.copyURL(of: tab) }
        let close = E(title: "Close", id: "file.closeTab") { [weak self, weak tab] in if let tab { self?.closeTab(tab) } }
        // Every tab is unpinned until M1.6, so the first row is Pin (Unpin takes its place on a pinned tab).
        var middle: [E] = [duplicate, .later("New Group with Tab", "M1.6", id: "tabs.newGroupWithTabs"), .later("Move to Group", "M1.6", submenu: true),
                           .later("Move to Profile", "M1.7", submenu: true), .sep, copyLink]
#if NOCHE_TESTHOOKS
        if ContextMenus.env("NOCHE_TEST_CTX_TABORDER") { middle[0] = copyLink; middle[5] = duplicate }  // negative control: Copy Link and Duplicate trade places
#endif
        return [.later("Pin", "M1.6"), .sep, .later("Chat With This Tab", "M2"), .later("Open as Split", "M1.10"), .sep] + middle
            + [.sep, .later("Rename...", "M1.6"), .later("Change Icon...", "M1.6"), .later("Edit Pinned Page", "M1.6", submenu: true), .sep, close]
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
                .later("New Group", "M1.6"), .later("New Live Group", "M1.6", submenu: true), .later("New Profile...", "M1.7"), .sep,
                bookmarkAll, .sep,
                .later("Show Tabs in Sidebar", "M1.6", id: "view.showTabsInSidebar", checked: true),
                tableRow("view.autoHideTabs") { [weak self] in self?.toggleSidebar() }, .sep, closeAll]
    }
}
