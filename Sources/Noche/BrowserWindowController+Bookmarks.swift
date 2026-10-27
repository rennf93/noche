import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Bookmarks in one window (M1.5 Task 6): the bar, the Cmd+D card and Bookmark All Tabs.
extension BrowserWindowController {
    /// The bar shows by the app's mode: on every page, only on the New Tab surface, or never. It pushes the page down except over the New Tab surface.
    var barVisible: Bool { app.barMode.visible(onNewTab: newTabShown) && !BarHook.on("BM_NOBAR") }
    var barPushesPage: Bool { barVisible && !newTabShown }

    func setUpBookmarks() {
        bookmarksBar.onOpen = { [weak self] b, newTab in self?.app.openBookmark(b, newTab: newTab) }
        bookmarksBar.onMenu = { [weak self] b, chip in self?.showBookmarkMenu(b, from: chip) }
        bookmarkEditor.onDone = { [weak self] name, parent in self?.bookmarkEditorDone(name, parent) }
        bookmarkEditor.onRemove = { [weak self] in self?.bookmarkEditorRemove() }
        bookmarkEditor.onCancel = { [weak self] in self?.bookmarkEditor.hide(); self?.bookmarkEditorClosed() }
        refreshBookmarks()
    }

    /// The bar's chips from the store, and the card closed when its bookmark is gone.
    func refreshBookmarks() {
        guard installed, let store = app.writer?.store else { return }
        let bar = (try? store.bookmarkRoots().first).flatMap { $0 }
        bookmarksBar.set(bar.flatMap { try? store.bookmarkChildren(of: $0.id) } ?? [])
        if !bookmarkEditor.isHidden, case .added(let id) = bookmarkEditor.mode, !bookmarkExists(id) { bookmarkEditor.hide() }
        if !bookmarkEditor.isHidden, case .edit(let id) = bookmarkEditor.mode, !bookmarkExists(id) { bookmarkEditor.hide() }
    }

    private func bookmarkExists(_ id: String) -> Bool {
        ((try? app.writer?.store.bookmark(id: id)) ?? nil) != nil
    }

    func bookmarksBarModeChanged() {
        applyLayout()
        refreshBookmarks()
    }

    /// Cmd+D: a page not yet bookmarked is added to the bar and the card says so; a bookmarked page opens the card to edit it (and Remove it).
    func bookmarkThisPage() {
        note("bookmarkThisPage")
        guard installed, let tab = activeTab, isWeb(shownURL(tab)), let store = app.writer?.store, !BarHook.on("BM_NOADD") else { return }
        let url = shownURL(tab)
        do {
            if let b = try app.bookmarks(ofPage: url).first {
                bookmarkEditorPage = url
                showBookmarkEditor(.edit(b.id), title: b.title, parent: b.parentId ?? "")
            } else {
                guard let bar = try store.bookmarkRoots().first else { return }
                let host = URL(string: url)?.host ?? url
                let b = try store.addBookmark(title: tab.title.isEmpty ? host : tab.title, url: url, parentId: bar.id)
                app.bookmarksChanged()
                bookmarkEditorPage = url
                showBookmarkEditor(.added(b.id), title: b.title, parent: bar.id)
            }
        } catch { app.logBookmark("add", error) }
    }

    /// The tabs Bookmark All Tabs would save: this window's web pages in tab order.
    var bookmarkableTabs: [(title: String, url: String)] {
        var seen = Set<String>()  // two tabs on one page (same `pageKey`) make one bookmark
        return list.items.filter { isWeb($0.url) && (seen.insert(pageKey($0.url)).inserted || BarHook.on("BM_DUPTABS")) }
            .map { (title: $0.title.isEmpty ? (URL(string: $0.url)?.host ?? $0.url) : $0.title, url: $0.url) }
    }

    /// Bookmark All Tabs: the card in folder mode ("New Folder" selected, parent Bookmarks Bar); Save adds the folder with one bookmark per tab.
    func bookmarkAllTabs() {
        note("bookmarkAllTabs")
        guard installed, let store = app.writer?.store, let bar = (try? store.bookmarkRoots().first).flatMap({ $0 }) else { return }
        let tabs = bookmarkableTabs
        guard !tabs.isEmpty else { return }
        bookmarkTabs = tabs
        showBookmarkEditor(.folder, title: "New Folder", parent: bar.id)
    }

    private func showBookmarkEditor(_ mode: BookmarkEditView.Mode, title: String, parent: String) {
        bookmarkEditorTab = activeTab?.identifier
        bookmarkEditor.show(mode, title: title, folderList: app.bookmarkFolders(), parentId: parent)
        applyLayout()
        bookmarkEditor.layoutSubtreeIfNeeded()
        bookmarkEditor.focusName()
    }

    private func bookmarkEditorDone(_ name: String, _ parent: String) {
        guard let store = app.writer?.store else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch bookmarkEditor.mode {
            case .folder:
                guard !parent.isEmpty, !BarHook.on("BM_NOSAVE") else { break }
                try store.addFolder(title: title.isEmpty ? "New Folder" : title, parentId: parent, bookmarks: bookmarkTabs)
            case .added(let id), .edit(let id):
                guard let b = try store.bookmark(id: id) else { break }
                if !title.isEmpty, title != b.title { try store.renameBookmark(id: id, title: title) }
                if !parent.isEmpty, parent != b.parentId { try store.moveBookmark(id: id, toParent: parent, index: nil) }
            }
        } catch { app.logBookmark("save", error) }
        bookmarkEditor.hide()
        app.bookmarksChanged()
        bookmarkEditorClosed()
    }

    private func bookmarkEditorRemove() {
        switch bookmarkEditor.mode {
        case .added(let id), .edit(let id):
            // Every reachable bookmark of the page goes (Bookmark All Tabs and the manager can leave copies in other folders), one delete and one undo entry each.
            var ids = [id]
            if !BarHook.on("BM_ONEDUP") { ids += ((try? app.bookmarks(ofPage: bookmarkEditorPage)) ?? []).map(\.id).filter { $0 != id } }
            let taken = ids.compactMap { app.deleteBookmark($0) }
            bookmarkUndo.removeAllActions()  // one entry: a later Remove replaces the earlier one
            if !taken.isEmpty, !BarHook.on("BM_NOCARDUNDO") {  // negative control: nothing is registered
                bookmarkUndo.beginUndoGrouping()
                // Newest delete first: a copy deleted later was renumbered after the earlier ones, so putting them back in reverse gives every row its old position.
                bookmarkUndo.registerUndo(withTarget: self) { c in
                    for d in taken.reversed() where !c.app.restoreBookmark(d) {
                        FileHandle.standardError.write(Data("NOCHE bookmark undo restore failed for \(d.id)\n".utf8))
                    }
                }
                bookmarkUndo.setActionName("Remove Bookmark")
                bookmarkUndo.endUndoGrouping()
                bookmarkUndoRevision = app.bookmarksRevision
            }
        case .folder: break
        }
        bookmarkEditor.hide()
        bookmarkEditorClosed()
    }

    /// The card's undo is good only while the tree is as that Remove left it: any other change (an add, a delete, a move, a rename, a folder delete, an import)
    /// expires it, so Undo never restores a bookmark beside a re-added copy or into a folder deleted since.
    var bookmarkUndoValid: Bool {
        bookmarkUndo.canUndo && (bookmarkUndoRevision == app.bookmarksRevision || BarHook.on("BM_UNDOSTALE"))  // negative control: the entry never expires
    }

    /// Edit > Undo after the card's Remove puts back every bookmark it took, in their folders and positions (the same restore the Bookmarks window's Undo uses).
    @objc func undo(_ sender: Any?) {
        guard bookmarkUndoValid else { bookmarkUndo.removeAllActions(); return }
        bookmarkUndo.undo()
    }
    @objc func redo(_ sender: Any?) { bookmarkUndo.redo() }

    /// Undo reads enabled only with a valid entry (the Bookmarks window's pattern); Redo only when the manager has one (it never does: the entry registers no redo).
    @objc func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case NSSelectorFromString("undo:"): return bookmarkUndoValid
        case NSSelectorFromString("redo:"): return bookmarkUndo.canRedo
        default: return true
        }
    }

    /// Done, Remove, Cancel and Escape give the keys back to the page (the name field had them).
    private func bookmarkEditorClosed() {
        if !BarHook.on("BM_NOREFOCUS") { window.focusActiveContent() }  // negative control: focus stays nowhere
    }

    /// The card belongs to the tab it was opened on: another tab closes it.
    func syncBookmarkEditor() {
        if !bookmarkEditor.isHidden, bookmarkEditorTab != activeTab?.identifier { bookmarkEditor.hide() }
    }

    /// A bar item or a menu row: the current tab loads it (leaving the New Tab surface), or a background tab opens it.
    func openBookmark(_ url: String, newTab: Bool) {
        if newTab {
            note("bookmarkOpenTab")
            closeNext.removeAll()
            _ = window.addTab(withURL: url, activate: BarHook.on("BM_FOREGROUND"))  // negative control: the new tab takes the selection
            return
        }
        note("bookmarkOpen")
        guard let tab = activeTab else { return }
        if newTabShown { commandBar.close(restoreFocus: false); leaveNewTab() }
        failed[tab.identifier] = nil
        if !BarHook.on("BM_NOLOAD") { tab.loadURL(url) }  // negative control: the click loads nothing
        window.focusActiveContent()
    }

    /// A folder chip (or the overflow chip, |folder| nil) shows its tree as a menu under the chip.
    func showBookmarkMenu(_ folder: Bookmark?, from chip: NSView) {
        guard let store = app.writer?.store else { return }
        let menu = BookmarkMenus.menu(folder: folder, rest: bookmarksBar.overflow, store: store) { [weak self] b in
            self?.app.openBookmark(b, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        }
        ContextMenus.present(menu, kind: "bookmarks", in: self, at: chip.convert(NSPoint(x: 0, y: chip.bounds.maxY), to: nil)) {}
    }
}
