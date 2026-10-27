#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// M1.5 final fix 3: duplicate bookmarks, the Downloads list, the Bookmarks menu built when a folder opens.
extension SelfTest {
    // MARK: bm-dupes

    /// Cmd+D then Remove leaves no bookmark of the page anywhere: one on the bar, one spelled without the trailing slash and one in a folder the bar does not show
    /// (inside Other Bookmarks), and one made by Bookmark All Tabs, which saves one bookmark for two tabs of the same page.
    func bmDupes() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store, let ed = editor, let other = otherRoot() else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        let page = ctl.shownURL(tab), key = pageKey(page)
        func copies() -> [Bookmark] { ((try? store.urlBookmarks()) ?? []).filter { pageKey($0.url ?? "") == key } }
        guard cmdD(), await until(5, { !ed.isHidden && copies().count == 1 }) else { return finish(false, "Cmd+D did not add the page (copies \(copies().count))") }
        ed.done.performClick(nil)
        let variant = page.hasSuffix("/") ? String(page.dropLast()) : page + "/"
        addMark("Variant spelling", variant, in: other)
        guard let deep = try? store.addFolder(title: "Deep", parentId: other.id) else { return finish(false, "no folder in Other Bookmarks") }
        addMark("Deep copy", page, in: deep)
        guard (try? store.bookmark(forURL: page))?.title == "Deep copy" else { return finish(false, "the newest exact copy is \(String(describing: try? store.bookmark(forURL: page)?.title)), want the one in Deep") }
        _ = win.addTab(withURL: page, activate: false)
        guard await until(15, { ctl.list.items.filter { pageKey($0.url) == key }.count == 2 }) else { return finish(false, "no second tab on the page: \(ctl.list.items.map(\.url))") }
        // Bookmark All Tabs: two tabs on one page make one bookmark in the new folder.
        ctl.bookmarkAllTabs()
        guard await until(3, { !ed.isHidden && ed.isFolderMode }) else { return finish(false, "Bookmark All Tabs showed no folder card") }
        ed.name.stringValue = "All"
        ed.done.performClick(nil)
        let all = ((try? barRoot().map { try store.bookmarkChildren(of: $0.id) }) ?? nil)?.first { $0.title == "All" }
        let held = all.flatMap { try? store.bookmarkChildren(of: $0.id) } ?? []
        guard held.count == 1 else { return finish(false, "the folder All holds \(held.count) bookmarks for two tabs of one page, want 1") }
        guard copies().count == 4 else { return finish(false, "before Remove: \(copies().count) copies (\(copies().map { $0.title })), want 4 (bar, Variant spelling, Deep copy, All)") }
        ctl.selectRow(0)
        guard await until(5, { win.activeTab === tab }) else { return finish(false, "the first tab is not active") }
        guard cmdD(), await until(5, { !ed.isHidden && { if case .edit = ed.mode { return true } else { return false } }() }) else { return finish(false, "the second Cmd+D showed no edit card (mode \(ed.mode))") }
        ed.remove.performClick(nil)
        guard await until(3, { copies().isEmpty }) else {
            return finish(false, "Remove left \(copies().count) bookmarks of the page: \(copies().map { "\($0.title) \($0.url ?? "")" })")
        }
        guard (try? store.bookmark(forURL: page)) == nil, !chipTitles().contains("Noche App Fixture") else { return finish(false, "the page is still bookmarked (exact \(String(describing: try? store.bookmark(forURL: page))), chips \(chipTitles()))") }
        finish(violations.isEmpty, "four bookmarks of one page (bar, the other spelling, a folder the bar does not show, Bookmark All Tabs with two tabs of the page saved once): Cmd+D then Remove left none \(violations)")
    }

    // MARK: bm-menu-lazy

    /// The Bookmarks menu reads no folder when it opens: each folder's submenu fills when it opens, through its own delegate (which answers false to a key search).
    func bmMenuLazy() async {
        guard await ready(), let store, let bar = barRoot(), let m = bookmarksMenu() else { return }
        guard let alpha = try? store.addFolder(title: "Alpha", parentId: bar.id), let beta = try? store.addFolder(title: "Beta", parentId: alpha.id) else { return finish(false, "no folders") }
        addMark("In Alpha", fixture("a.html"), in: alpha)
        addMark("Deep Page", fixture("b.html"), in: beta)
        BookmarkMenus.fills = 0
        opened(m)
        guard BookmarkMenus.fills == 0 else { return finish(false, "opening the Bookmarks menu filled \(BookmarkMenus.fills) folders, want 0") }
        guard let root = m.items.first(where: { $0.title == "Bookmarks Bar" && $0.identifier == MenuTable.mark })?.submenu else { return finish(false, "no Bookmarks Bar submenu") }
        openedSub(root)
        guard BookmarkMenus.fills == 1, root.items.map(\.title) == ["Alpha"], root.items.first?.submenu?.items.isEmpty == true else {
            return finish(false, "Bookmarks Bar opened: fills \(BookmarkMenus.fills), rows \(root.items.map(\.title)), Alpha already holds \(root.items.first?.submenu?.items.count ?? -1)")
        }
        guard let alphaMenu = root.items.first?.submenu else { return finish(false, "no Alpha submenu") }
        openedSub(alphaMenu)
        guard BookmarkMenus.fills == 2, alphaMenu.items.map(\.title) == ["Beta", "In Alpha"], alphaMenu.items.first?.submenu?.items.isEmpty == true else {
            return finish(false, "Alpha opened: fills \(BookmarkMenus.fills), rows \(alphaMenu.items.map(\.title)), Beta already holds \(alphaMenu.items.first?.submenu?.items.count ?? -1)")
        }
        // The tree changes after Alpha's rows were built and before Beta opens: Beta shows what the store holds when it opens.
        addMark("Late", fixture("link.html"), in: beta)
        guard let betaMenu = alphaMenu.items.first?.submenu else { return finish(false, "no Beta submenu") }
        openedSub(betaMenu)
        guard betaMenu.items.map(\.title) == ["Late", "Deep Page"] || betaMenu.items.map(\.title) == ["Deep Page", "Late"], BookmarkMenus.fills == 3 else {
            return finish(false, "Beta opened after a change: fills \(BookmarkMenus.fills), rows \(betaMenu.items.map(\.title))")
        }
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ctl?.nsWindow?.windowNumber ?? 0,
                                        context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2), let del = betaMenu.delegate else { return finish(false, "no key event or delegate on Beta") }
        var t: AnyObject?, a: Selector?
        let before = BookmarkMenus.fills
        guard del.menuHasKeyEquivalent?(betaMenu, for: ev, target: &t, action: &a) == false, BookmarkMenus.fills == before else { return finish(false, "a key equivalent search on Beta answered true or refilled it") }
        finish(violations.isEmpty, "opening the Bookmarks menu filled 0 folders, each submenu filled when opened (3 fills for Bookmarks Bar, Alpha, Beta), a change before Beta opened showed, a key search refills nothing \(violations)")
    }

    // MARK: downloads

    func downloadCount() -> Int { dc.items.filter { $0.state == .complete }.count }

    /// One store write per Clear, a failed write counted (and logged), the in-memory set trimmed like the stored list.
    func dlClearWrite() async {
        guard await ready(), let win, let tab = win.activeTab, let store else { return }
        DownloadsController.removedLimit = 2
        for n in 1...3 {
            tab.loadURL(fixture("download.bin"))
            guard await until(20, { downloadCount() == n }) else { return finish(false, "download \(n) never completed") }
        }
        let ids = dc.items.map { "\($0.identifier)|\($0.url)" }
        let w0 = DownloadsController.removedWrites
        dc.clearFinished()
        let writes = DownloadsController.removedWrites - w0
        let stored = ((try? store.setting("downloadsRemoved")) ?? nil)?.split(separator: "\n").map(String.init) ?? []
        guard dc.items.isEmpty, writes == 1 else { return finish(false, "Clear of 3 rows wrote the list \(writes) times (rows left \(dc.items.count)), want 1") }
        guard stored.count == 2, stored == Array(ids.reversed().suffix(2)) else { return finish(false, "the stored list is \(stored), want the 2 newest of \(Array(ids.reversed()))") }
        guard dc.removed.count == 2 else { return finish(false, "the in-memory set holds \(dc.removed.count) keys, the stored list 2") }
        // A failed write is counted (and logged), and the removal still holds in this run.
        tab.loadURL(fixture("download.bin"))
        guard await until(20, { downloadCount() == 1 }), let one = dc.items.first else { return finish(false, "no fourth download") }
        DownloadsController.failWrites = true
        DownloadsController.removedFailures = 0
        dc.remove(one)
        DownloadsController.failWrites = false
        guard DownloadsController.removedFailures == 1, dc.items.isEmpty, dc.removed.contains(DownloadsController.key(one)) else {
            return finish(false, "a failed write: failures \(DownloadsController.removedFailures), rows \(dc.items.count), removed in memory \(dc.removed.contains(DownloadsController.key(one)))")
        }
        finish(violations.isEmpty, "Clear of 3 rows wrote the removed list once (limit 2 kept the 2 newest, stored and in memory), a failed write was counted and the row stayed removed \(violations)")
    }

    /// An in-progress update for a removed key is a new download with a reused id and address: its end lists. (The engine cannot be made to reuse an id, so the
    /// removal of the earlier download is seeded for the live download's own key.)
    func dlReuse() async {
        guard await ready(), let win, let tab = win.activeTab, let store, let server = await startSlowServer(size: Self.slowSize) else { return }
        defer { server.stop() }
        guard let started = await startSlow(tab, server: server) else { return }
        let id = started.identifier, key = DownloadsController.key(started)
        dc.rememberRemovedForTest(key)
        guard dc.removed.contains(key) else { return finish(false, "the test could not seed the key") }
        guard await until(30, { item(id)?.state == .complete }) else {
            return finish(false, "the reused download never ended listed (state \(item(id)?.state.rawValue ?? -1), items \(dc.items.map { "\($0.identifier):\($0.state.rawValue)" }))")
        }
        let stored = ((try? store.setting("downloadsRemoved")) ?? nil) ?? ""
        guard !dc.removed.contains(key), !stored.contains(key) else { return finish(false, "the key stayed removed (memory \(dc.removed.contains(key)), stored \(stored.contains(key)))") }
        app.showDownloads(nil)
        guard await until(5, { dc.windowController.rows.contains { $0.nameField.stringValue == "slow.bin" && $0.detailField.stringValue.hasPrefix("Complete") } }) else { return finish(false, "no Complete row for the reused download") }
        finish(violations.isEmpty, "a download whose id and address were marked removed, seen in progress, was forgotten and listed Complete (the key left memory and the store) \(violations)")
    }

    /// A complete row whose file was moved, renamed or deleted says so and offers Remove only; a stale row that is pressed finds out.
    func dlFileMissing() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        for n in 1...3 {
            tab.loadURL(fixture("download.bin"))
            guard await until(20, { downloadCount() == n }) else { return finish(false, "download \(n) never completed") }
        }
        let paths = dc.items.map(\.fullPath)  // newest first
        guard paths.count == 3, paths.allSatisfy({ $0.hasPrefix(Self.downloadFolder.path + "/") }) else { return finish(false, "the files are not in the test folder: \(paths)") }
        DownloadsController.workspaceLog = []
        app.showDownloads(nil)
        guard await until(5, { dc.windowController.rows.count == 3 }), dc.windowController.rows.allSatisfy({ $0.visibleButtons == ["Open", "Show in Finder", "Remove"] }) else { return finish(false, "the rows before: \(dc.windowController.rows.map(\.visibleButtons))") }
        // The oldest row's file goes after the row was drawn; pressing Open finds out and does nothing else.
        try? FileManager.default.removeItem(atPath: paths[2])
        dc.windowController.rows[2].button("Open")?.performClick(nil)
        let log = DownloadsController.workspaceLog.count
        let r2 = dc.windowController.rows[2]
        guard log == 0, r2.fileMissing, r2.detailField.stringValue == "File not found", r2.visibleButtons == ["Remove"] else {
            return finish(false, "pressing Open on a deleted file: NSWorkspace calls \(log), detail \(r2.detailField.stringValue), buttons \(r2.visibleButtons)")
        }
        // Deleted and renamed files show when the window comes back.
        try? FileManager.default.removeItem(atPath: paths[0])
        try? FileManager.default.moveItem(atPath: paths[1], toPath: paths[1] + ".moved")
        dc.windowController.show()
        let rows = dc.windowController.rows
        guard rows.allSatisfy({ $0.detailField.stringValue == "File not found" && $0.visibleButtons == ["Remove"] }) else {
            return finish(false, "after a delete and a rename: details \(rows.map(\.detailField.stringValue)), buttons \(rows.map(\.visibleButtons))")
        }
        rows[0].button("Remove")?.performClick(nil)
        guard dc.items.count == 2, dc.windowController.rows.count == 2 else { return finish(false, "Remove on a missing row left \(dc.items.count) items and \(dc.windowController.rows.count) rows") }
        finish(violations.isEmpty, "a deleted file (found by pressing Open) and a deleted and a renamed file (found when the window came back) read File not found with Remove only, no NSWorkspace call, and Remove works \(violations)")
    }

    /// An update rebuilds only the row it changed, and a burst of changes reloads once or twice.
    func dlRows() async {
        guard await ready(), let win, let tab = win.activeTab, let server = await startSlowServer(size: Self.slowSize) else { return }
        defer { server.stop() }
        for n in 1...2 {
            tab.loadURL(fixture("download.bin"))
            guard await until(20, { downloadCount() == n }) else { return finish(false, "download \(n) never completed") }
        }
        app.showDownloads(nil)
        let wc = dc.windowController
        guard await until(5, { wc.rows.count == 2 }) else { return finish(false, "no 2 rows") }
        var updates = 0
        let token = NotificationCenter.default.addObserver(forName: DownloadsController.changed, object: dc, queue: .main) { _ in updates += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let done = wc.rows.map { ObjectIdentifier($0) }
        let doneBefore = wc.rows.map(\.configured), totalBefore = DownloadRowView.configuredTotal, reloadsBefore = wc.reloads
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let running = await startSlow(tab, server: server, minBytes: 200_000) else { return }
        try? await Task.sleep(for: .seconds(2))
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        let rowsNow = wc.rows
        guard rowsNow.count == 3, Set(done) == Set(rowsNow.dropFirst().map { ObjectIdentifier($0) }) else { return finish(false, "the complete rows lost their views (rows \(rowsNow.count))") }
        let doneDelta = rowsNow.dropFirst().enumerated().map { $1.configured - doneBefore[$0] }
        let totalDelta = DownloadRowView.configuredTotal - totalBefore, reloads = wc.reloads - reloadsBefore
        line("info", "one running download for \(String(format: "%.1f", elapsed)) s: \(updates) updates, \(reloads) reloads, \(totalDelta) row configurations (the 2 complete rows: \(doneDelta))")
        guard doneDelta.allSatisfy({ $0 == 0 }) else { return finish(false, "the 2 complete rows were configured \(doneDelta) times while another download ran (\(updates) updates, \(totalDelta) configurations in all)") }
        guard totalDelta <= reloads + 1, reloads <= Int(elapsed / DownloadsWindowController.reloadInterval) + 2 else { return finish(false, "\(totalDelta) configurations and \(reloads) reloads for \(updates) updates in \(elapsed) s") }
        // A burst of changes in one run loop turn: the first reloads at once, the rest once at the end of the interval.
        try? await Task.sleep(for: .milliseconds(300))
        item(running.identifier).map { _ in dc.cancel(running) }
        guard await until(10, { item(running.identifier)?.state == .canceled }) else { return finish(false, "the running download did not cancel") }
        try? await Task.sleep(for: .milliseconds(400))
        let r0 = wc.reloads
        for _ in 0..<50 { NotificationCenter.default.post(name: DownloadsController.changed, object: dc) }
        try? await Task.sleep(for: .milliseconds(350))
        let burst = wc.reloads - r0
        guard burst >= 1, burst <= 2 else { return finish(false, "50 changes in one turn reloaded the list \(burst) times, want 1 or 2") }
        // Clear during a pending reload: the list ends with what the controller holds.
        NotificationCenter.default.post(name: DownloadsController.changed, object: dc)
        NotificationCenter.default.post(name: DownloadsController.changed, object: dc)
        dc.clearFinished()
        try? await Task.sleep(for: .milliseconds(350))
        guard wc.rows.count == dc.items.count, dc.items.count == 0 else { return finish(false, "after Clear during a pending reload: \(wc.rows.count) rows, \(dc.items.count) items") }
        finish(violations.isEmpty, "a running download for \(String(format: "%.1f", elapsed)) s (\(updates) updates) made \(reloads) reloads and \(totalDelta) row configurations, none on the 2 complete rows; 50 changes in one turn reloaded \(burst) times; Clear during a pending reload left the list empty \(violations)")
    }
}
#endif
