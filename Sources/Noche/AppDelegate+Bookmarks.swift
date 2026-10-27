import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Bookmarks (M1.5 Task 6) at the app level: the bar mode, every change to the store (so each window's bar, the Bookmarks menu, the manager and the
/// command bar follow at once), and the menu actions.
extension AppDelegate {
    /// Cmd+D from a utility window acts on the browser window it follows: that window comes forward first, so its card gets the keys.
    @objc func bookmarkThisPage(_ s: Any?) { if let a = active { bringForward(a); a.bookmarkThisPage() } }
    @objc func manageBookmarks(_ s: Any?) { if !closing && !BarHook.on("BM_NOMANAGE") { bookmarksWindow.show() } }
    /// Always, On New Tab Only and Never, by tag.
    @objc func setBookmarksBarMode(_ s: NSMenuItem) { setBarMode(BookmarksBarMode.allCases[s.tag]) }
    @objc func toggleBookmarksBar(_ s: Any?) {
        guard let a = active, !BarHook.on("BM_NOTOGGLE") else { return }
        setBarMode(barMode.toggled(onNewTab: a.newTabShown))
    }

    func setBarMode(_ mode: BookmarksBarMode) {
        BrowserWindowController.note("bookmarksBar")
        barMode = mode
        try? writer?.store.setSetting(BookmarksBarMode.settingKey, mode.rawValue)
        controllers.forEach { $0.bookmarksBarModeChanged() }
    }

    func reloadBookmarkCandidates() {
        bookmarkCandidates = ((try? writer?.store.urlBookmarks()) ?? nil)?.map { BookmarkCandidate(url: $0.url ?? "", title: $0.title, addedAt: $0.createdAt) } ?? []
    }

    func bookmarksChanged() {
        if !(BarHook.on("BM_STALECACHE") && !bookmarkCandidates.isEmpty) { reloadBookmarkCandidates() }  // negative control: a list that has entries is never rebuilt
        controllers.forEach { $0.refreshBookmarks() }
        madeBookmarksWindow?.changed()
    }

    /// Every folder with its depth, in tree order (the Cmd+D card's popup).
    func bookmarkFolders() -> [(id: String, title: String, depth: Int)] {
        guard let store = writer?.store else { return [] }
        var out: [(id: String, title: String, depth: Int)] = []
        func walk(_ b: Bookmark, _ depth: Int) {
            out.append((b.id, b.title, depth))
            for c in (try? store.bookmarkChildren(of: b.id)) ?? [] where c.kind == .folder { walk(c, depth + 1) }
        }
        for r in (try? store.bookmarkRoots()) ?? [] { walk(r, 0) }
        return out
    }

    /// A bookmark opens a stored address, so its scheme is checked again (as a History row's is).
    func openBookmark(_ b: Bookmark, newTab: Bool) {
        guard b.kind == .url, let url = b.url else { return }
        // negative control: BM_NOSCHEME skips the gate, so a stored javascript: or file: address opens
        guard BarHook.on("BM_NOSCHEME") || (["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "") && AddressInput.allowedSchemes.contains(URL(string: url)?.scheme?.lowercased() ?? "")) else { return }
        if let a = active { bringForward(a); a.openBookmark(url, newTab: newTab) } else if !closing { BrowserWindowController.note("bookmarkOpen"); newWindow(url: url) }
    }

    func renameBookmark(_ id: String, to title: String) {
        do { try writer?.store.renameBookmark(id: id, title: title) } catch { logBookmark("rename", error) }
        bookmarksChanged()
    }

    @discardableResult
    func deleteBookmark(_ id: String) -> Store.Deleted? {
        var done: Store.Deleted?
        do {
            // negative control: BM_ORPHAN deletes a folder's row only and leaves what it held on the bar
            if BarHook.on("BM_ORPHAN"), let store = writer?.store, let bar = try store.bookmarkRoots().first {
                for c in (try? store.bookmarkChildren(of: id)) ?? [] { try store.moveBookmark(id: c.id, toParent: bar.id, index: nil) }
            }
            done = try writer?.store.deleteBookmark(id: id)
        } catch { logBookmark("delete", error) }
        bookmarksChanged()
        return done
    }

    /// False when the store refused (the parent folder is gone) or there is no store.
    @discardableResult
    func restoreBookmark(_ d: Store.Deleted) -> Bool {
        var ok = false
        do { try writer?.store.restoreBookmark(d); ok = writer != nil } catch { logBookmark("restore", error) }
        bookmarksChanged()
        return ok
    }

    func addBookmarkFolder(title: String, parentId: String) {
        do { try writer?.store.addFolder(title: title, parentId: parentId) } catch { logBookmark("add folder", error) }
        bookmarksChanged()
    }

    func logBookmark(_ what: String, _ error: any Error) {
        FileHandle.standardError.write(Data("NOCHE bookmark \(what) failed: \(error)\n".utf8))
    }
}

/// The dynamic part of the Bookmarks menu, rebuilt each time it opens: Recent Bookmarks (the 5 newest) under the first separator, and the trees of
/// "Bookmarks Bar" and "Other Bookmarks". None of these rows carries the table's mark: they are not part of the menu table.
@MainActor
final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {
    unowned let app: AppDelegate
    private static let dynamic = NSUserInterfaceItemIdentifier("noche.menu.bookmarks.dynamic")
    init(app: AppDelegate) { self.app = app }

    /// AppKit asks this while it looks for a key equivalent (every Cmd chord) and rebuilds the menu first when the delegate says nothing: no row here has a key.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for i in menu.items.reversed() where i.identifier == Self.dynamic { menu.removeItem(i) }
        guard let store = app.writer?.store else { return }
        let open: @MainActor (Bookmark) -> Void = { [weak app] b in app?.openBookmark(b, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
        // Recent Bookmarks after the first separator.
        let recent = (try? store.recentBookmarks(limit: 5)) ?? []
        if let at = menu.items.firstIndex(where: \.isSeparatorItem) {
            var rows: [NSMenuItem] = []
            if !recent.isEmpty {
                let header = NSMenuItem(title: "Recent Bookmarks", action: nil, keyEquivalent: "")
                rows.append(header)
                rows += recent.map { BookmarkMenus.item($0, open: open) }
                rows.append(.separator())
            }
            for (k, r) in rows.enumerated() { r.identifier = Self.dynamic; menu.insertItem(r, at: at + 1 + k) }
        }
        let roots = (try? store.bookmarkRoots()) ?? []
        for root in roots {
            guard let sub = menu.items.first(where: { $0.title == root.title && $0.identifier == MenuTable.mark })?.submenu else { continue }
            sub.removeAllItems()
            sub.autoenablesItems = false
            BookmarkMenus.fill(sub, store: store, folder: root, open: open)
        }
    }
}

/// Menus of bookmarks: a folder is a submenu, a page an item that runs |open|.
@MainActor
enum BookmarkMenus {
    static func item(_ b: Bookmark, open: @escaping @MainActor (Bookmark) -> Void) -> NSMenuItem {
        let title = b.title.isEmpty ? (b.url ?? "") : b.title
        let item = NSMenuItem(title: title.count > 60 ? String(title.prefix(60)) + "..." : title, action: #selector(ContextMenus.Target.fire(_:)), keyEquivalent: "")
        item.target = ContextMenus.target
        item.representedObject = ContextMenus.Run { MainActor.assumeIsolated { open(b) } }
        item.toolTip = b.url
        return item
    }

    /// The children of |folder| (a folder with none shows a disabled "(Empty)").
    static func fill(_ menu: NSMenu, store: Store, folder: Bookmark, open: @escaping @MainActor (Bookmark) -> Void) {
        let children = (try? store.bookmarkChildren(of: folder.id)) ?? []
        if children.isEmpty {
            let empty = NSMenuItem(title: "(Empty)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for c in children {
            if c.kind == .folder {
                let i = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: c.title)
                sub.autoenablesItems = false
                fill(sub, store: store, folder: c, open: open)
                i.submenu = sub
                menu.addItem(i)
            } else {
                menu.addItem(item(c, open: open))
            }
        }
    }

    /// The menu a folder chip shows (or, with |folder| nil, the overflow chip: the rest of the bar's rows).
    static func menu(folder: Bookmark?, rest: [Bookmark], store: Store, open: @escaping @MainActor (Bookmark) -> Void) -> NSMenu {
        let menu = NSMenu(title: folder?.title ?? "")
        menu.autoenablesItems = false
        if let folder { fill(menu, store: store, folder: folder, open: open); return menu }
        for c in rest {
            if c.kind == .folder {
                let i = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: c.title)
                sub.autoenablesItems = false
                fill(sub, store: store, folder: c, open: open)
                i.submenu = sub
                menu.addItem(i)
            } else {
                menu.addItem(item(c, open: open))
            }
        }
        return menu
    }
}
