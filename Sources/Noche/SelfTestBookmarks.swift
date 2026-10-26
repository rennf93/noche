#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Checks of M1.5 Task 6: bookmarks. The Cmd+D card, the bar, the Bookmarks menu, the manager window and the command bar rows. Windows stay hidden
/// like every test window (alpha 0, never key, the app never active); the card is a view of the browser window, the manager a window of its own.
extension SelfTest {
    var store: Store? { app.writer?.store }
    var bmBar: BookmarksBarView? { ctl?.bookmarksBar }
    var editor: BookmarkEditView? { ctl?.bookmarkEditor }
    var manager: BookmarksWindowController { app.bookmarksWindow }

    @discardableResult func cmdD() -> Bool { key("d", code: 2) }
    func cmdShiftB() { key("b", code: 11, [.command, .shift]) }

    /// "Bookmarks Bar" and "Other Bookmarks" roots.
    func barRoot() -> Bookmark? { (try? store?.bookmarkRoots())?.first }
    func otherRoot() -> Bookmark? { (try? store?.bookmarkRoots())?.last }
    func barTitles() -> [String] { guard let r = barRoot() else { return [] }; return ((try? store?.bookmarkChildren(of: r.id)) ?? []).map(\.title) }
    func chipTitles() -> [String] { bmBar?.chips.compactMap { $0.bookmark?.title } ?? [] }

    @discardableResult
    func addMark(_ title: String, _ url: String, in parent: Bookmark? = nil) -> Bookmark? {
        guard let p = parent ?? barRoot() else { return nil }
        let b = try? store?.addBookmark(title: title, url: url, parentId: p.id)
        app.bookmarksChanged()
        return b
    }

    func bookmarksMenu() -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == "Bookmarks" && $0.identifier == MenuTable.mark }?.submenu }

    /// AppKit asks the delegate for the rows just before it shows the menu (NSMenu.update() does not).
    func opened(_ m: NSMenu) { m.update(); (m.delegate as? BookmarksMenuDelegate)?.menuNeedsUpdate(m) }

    /// The rows Recent Bookmarks lists in the live menu (opened the way a click opens it: update first), and whether its header is there.
    func recentRows() -> (header: Bool, rows: [String]) {
        guard let m = bookmarksMenu() else { return (false, []) }
        opened(m)
        guard let h = m.items.firstIndex(where: { $0.title == "Recent Bookmarks" }) else { return (false, []) }
        return (true, m.items[(h + 1)...].prefix { !$0.isSeparatorItem }.map(\.title))
    }

    func treeTitles(_ name: String) -> [String] {
        guard let m = bookmarksMenu() else { return [] }
        opened(m)
        return m.items.first { $0.title == name && $0.identifier == MenuTable.mark }?.submenu?.items.map { $0.isSeparatorItem ? "---" : $0.title } ?? []
    }

    /// A window of the hidden run shows on the same terms as every test window: alpha 0, not key, floating, mouse ignored, the app not active.
    func hiddenTerms(_ w: NSWindow) -> (ok: Bool, text: String) {
        let t = "alpha \(w.alphaValue), key \(w.isKeyWindow), level \(w.level.rawValue), mouse ignored \(w.ignoresMouseEvents), app active \(NSApp.isActive)"
        return (w.alphaValue == 0 && !w.isKeyWindow && w.level == .floating && w.ignoresMouseEvents && !NSApp.isActive, t)
    }

    func mouseUp(_ v: NSView, command: Bool = false) {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.mouseEvent(with: .leftMouseUp, location: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil),
                                                                   modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                   windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        v.mouseUp(with: ev)
    }

    func chip(_ title: String) -> BookmarkChipView? { bmBar?.chips.first { $0.bookmark?.title == title } }

    /// Cmd+D on a page: the page joins the bar, the card says so, the menu lists it under Recent Bookmarks; Cmd+D again is the same bookmark, edited, with Remove.
    func bmAdd() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store, let ed = editor, let bar = barRoot() else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        guard barTitles().isEmpty, !recentRows().header else { return finish(false, "a fresh profile already has bookmarks: \(barTitles()) \(recentRows())") }
        guard bookmarksMenu()?.delegate === app.bookmarksMenuDelegate else { return finish(false, "the Bookmarks menu has no delegate, so its rows are never built") }
        // A key equivalent search must not rebuild the dynamic rows (menuNeedsUpdate would read the whole tree on every Cmd chord).
        if let menu = bookmarksMenu(), let del = menu.delegate, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                                         windowNumber: ctl.nsWindow?.windowNumber ?? 0, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2) {
            var t: AnyObject?, a: Selector?
            guard del.menuHasKeyEquivalent?(menu, for: ev, target: &t, action: &a) == false else { return finish(false, "the Bookmarks menu delegate does not answer false to a key equivalent search, so each Cmd chord rebuilds the tree") }
        }
        guard cmdD() else { return finish(false, "Cmd+D reached no menu item (\(keyLog.last ?? ""))") }
        guard await until(5, { (try? store.bookmark(forURL: tab.url)) != nil }), let first = try? store.bookmark(forURL: tab.url) else {
            return finish(false, "Cmd+D did not add \(tab.url) to the bookmarks (bar: \(barTitles()))")
        }
        guard first.parentId == bar.id, first.title == "Noche App Fixture", first.kind == .url else { return finish(false, "the new bookmark is \(first), want a page titled Noche App Fixture in Bookmarks Bar") }
        guard !ed.isHidden, ed.mode == .added(first.id), ed.heading.stringValue == "Bookmark added", ed.remove.title == "Remove", ed.done.title == "Done",
              ed.name.stringValue == "Noche App Fixture", ed.folders.titleOfSelectedItem == "Bookmarks Bar" else {
            return finish(false, "the card after Cmd+D: hidden \(ed.isHidden), mode \(ed.mode), heading \(ed.heading.stringValue), buttons \(ed.remove.title) and \(ed.done.title), name \(ed.name.stringValue), folder \(ed.folders.titleOfSelectedItem ?? "nil")")
        }
        let layout = ChromeLayout(size: ctl.overlay.bounds.size, cardX: ctl.cardX, barShown: ctl.barVisible)
        guard near(ed.frame, layout.bookmarkEditor.minX, layout.bookmarkEditor.minY, layout.bookmarkEditor.width, layout.bookmarkEditor.height), ed.frame.minY >= ChromeStyle.webTop, ed.window === ctl.nsWindow else {
            return finish(false, "the card sits at \(ed.frame), want \(layout.bookmarkEditor) inside the browser window")
        }
        let terms = hiddenTerms(ctl.nsWindow!)
        guard terms.ok else { return finish(false, "the card's window can show: \(terms.text)") }
        let recent = recentRows()
        guard recent.header, recent.rows == ["Noche App Fixture"] else { return finish(false, "Recent Bookmarks is \(recent), want the header and Noche App Fixture") }
        // Cmd+D again: the same bookmark, in edit mode, Remove shown; nothing is added twice.
        ed.hide()
        guard cmdD(), await until(5, { !ed.isHidden }) else { return finish(false, "the second Cmd+D showed no card") }
        guard ed.mode == .edit(first.id), ed.heading.stringValue == "Edit bookmark", ed.remove.title == "Remove", !ed.remove.isHidden, (try? store.urlBookmarks().count) == 1 else {
            return finish(false, "the second Cmd+D: mode \(ed.mode), heading \(ed.heading.stringValue), Remove \(ed.remove.title), bookmarks \((try? store.urlBookmarks().count) ?? -1)")
        }
        // Escape cancels the card (the bookmark stays) and the page takes the keys back.
        ed.hide()
        guard cmdD(), await until(5, { !ed.isHidden }), (ed.name.currentEditor() as? NSTextView) != nil else { return finish(false, "no card with the name field being edited for Escape") }
        press(.escape)
        guard await until(3, { ed.isHidden && inPage() }), (try? store.bookmark(forURL: tab.url)) != nil else {
            return finish(false, "Escape: card hidden \(ed.isHidden), page has focus \(inPage()), bookmark kept \((try? store.bookmark(forURL: tab.url)) != nil)")
        }
        // Remove deletes it and the menu forgets it.
        ed.hide()
        guard cmdD(), await until(5, { !ed.isHidden }) else { return finish(false, "no card before Remove") }
        ed.remove.performClick(nil)
        guard await until(3, { (try? store.bookmark(forURL: tab.url)) == nil && ed.isHidden && !recentRows().header }) else {
            return finish(false, "Remove left the bookmark \(String(describing: try? store.bookmark(forURL: tab.url))), card hidden \(ed.isHidden), recent \(recentRows())")
        }
        guard await until(3, { inPage() }) else { return finish(false, "after Remove the page did not take the keys back") }
        // Add again, rename and Done: the title and the folder choice are saved.
        guard cmdD(), await until(5, { !ed.isHidden && ed.mode != .folder }) else { return finish(false, "Cmd+D after Remove showed no card") }
        ed.name.stringValue = "Fixture Home"
        if let other = ed.folders.itemTitles.firstIndex(of: "Other Bookmarks") { ed.folders.selectItem(at: other) }
        ed.done.performClick(nil)
        guard await until(3, { (try? store.bookmark(forURL: tab.url))?.title == "Fixture Home" && ed.isHidden }), let saved = try? store.bookmark(forURL: tab.url), saved.parentId == otherRoot()?.id else {
            return finish(false, "Done saved \(String(describing: try? store.bookmark(forURL: tab.url))), want Fixture Home in Other Bookmarks")
        }
        guard await until(3, { inPage() }) else { return finish(false, "after Done the page did not take the keys back") }
        guard recentRows().rows == ["Fixture Home"], barTitles().isEmpty, treeTitles("Other Bookmarks") == ["Fixture Home"] else {
            return finish(false, "after Done: recent \(recentRows()), bar \(barTitles()), Other Bookmarks \(treeTitles("Other Bookmarks"))")
        }
        finish(violations.isEmpty, "Cmd+D added Noche App Fixture to Bookmarks Bar with the card (Bookmark added, Remove, Done, hidden terms: \(terms.text)), the menu lists it under Recent Bookmarks, Cmd+D again edits the same bookmark, Remove deletes it, Done saved a new title in Other Bookmarks \(violations)")
    }

    func barState(_ ctl: BrowserWindowController) -> String {
        "visible \(!(bmBar?.isHidden ?? true)), insets top \(win?.webInsets.top ?? -1), mode \(app.barMode.rawValue), new tab \(ctl.newTabShown)"
    }

    /// The bar follows the three modes (on a page, on the New Tab surface) and the toggle; the mode is stored; the chips sit where live-ui.md section 2 puts them.
    func bmBar_() async {
        guard await ready(), let ctl, let win, let store, let bar = bmBar else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        addMark("Alpha", fixture("b.html"))
        addMark("Beta", fixture("link.html"))
        if let mine = try? store.addFolder(title: "Mine", parentId: barRoot()!.id) { addMark("Child", fixture(""), in: mine) }
        func onPage() async -> Bool { ctl.selectRow(0); return await until(10, { !ctl.newTabShown && win.activeTab === win.tabs.first }) }
        func onNewTab() async -> Bool {
            if rowCount < 2 { ctl.newTab() }
            ctl.selectRow(1)
            return await until(15, { ctl.newTabShown && rowCount == 2 })
        }
        guard app.barMode == .newTabOnly, (try? store.setting(BookmarksBarMode.settingKey)) == nil else { return finish(false, "the default is \(app.barMode), stored \(String(describing: try? store.setting(BookmarksBarMode.settingKey)))") }
        // On New Tab Only (the default): hidden on a page, shown on the New Tab surface without pushing anything.
        guard bar.isHidden, win.webInsets.top == ChromeStyle.webTop else { return finish(false, "On New Tab Only on a page: \(barState(ctl))") }
        guard await onNewTab() else { return finish(false, "no New Tab surface") }
        guard !bar.isHidden, win.webInsets.top == ChromeStyle.webTop else { return finish(false, "On New Tab Only on the New Tab surface: \(barState(ctl))") }
        // The find pill and the permission card sit below the bar on every surface the bar shows on.
        func clears() -> String? {
            let below = (ctl.frame(ofIdentifier: "bookmarks.bar")?.maxY ?? 0) - 0.5
            return ctl.findBar.frame.minY >= below && ctl.permissionPrompt.frame.minY >= below ? nil : "find pill at y \(ctl.findBar.frame.minY), permission card at y \(ctl.permissionPrompt.frame.minY), bar bottom \(below + 0.5)"
        }
        if let bad = clears() { return finish(false, "over the New Tab surface the bar is overlapped: \(bad)") }
        // Geometry (live-ui.md section 2): the bar is the card's row under the divider, 42 high; the first chip is at x 12 of the card, y 54, 30 high.
        let layout = ChromeLayout(size: ctl.overlay.bounds.size, cardX: ctl.cardX)
        let barFrame = ctl.frame(ofIdentifier: "bookmarks.bar")
        guard near(barFrame, layout.card.minX, 48, layout.card.width, 42), chipTitles() == ["Alpha", "Beta", "Mine"], let first = bar.chips.first else {
            return finish(false, "the bar is at \(String(describing: barFrame)) with chips \(chipTitles()), want \(layout.card.minX),48 \(layout.card.width)x42 and Alpha, Beta, Mine")
        }
        let chipFrame = first.convert(first.bounds, to: ctl.overlay)
        guard abs(chipFrame.minX - (layout.card.minX + 12)) <= 1, abs(chipFrame.minY - 54) <= 1, abs(chipFrame.height - 30) <= 1 else {
            return finish(false, "the first chip is at \(chipFrame), want x \(layout.card.minX + 12) (12 inside the card), y 54, 30 high")
        }
        // The menu says which mode is on.
        func checks() -> [String] { ["Always", "On New Tab Only", "Never"].map { t in menuItem(t).map { i in i.menu?.update(); return i.state == .on ? "on" : "off" } ?? "missing" } }
        guard checks() == ["off", "on", "off"] else { return finish(false, "menu marks \(checks()), want On New Tab Only on") }
        // Always: on a page the bar shows and pushes the page down by its height.
        guard fire("Always"), await onPage() else { return finish(false, "Always did not run") }
        guard await until(3, { !bar.isHidden && win.webInsets.top == ChromeStyle.webTop + 42 }) else { return finish(false, "Always on a page: \(barState(ctl))") }
        let pageBar = ctl.frame(ofIdentifier: "bookmarks.bar")
        if let bad = clears() { return finish(false, "on a page with Always the bar is overlapped: \(bad)") }
        guard near(pageBar, layout.card.minX, 48, layout.card.width, 42), checks() == ["on", "off", "off"], (try? store.setting(BookmarksBarMode.settingKey)) == "always" else {
            return finish(false, "Always: bar \(String(describing: pageBar)), marks \(checks()), stored \(String(describing: try? store.setting(BookmarksBarMode.settingKey)))")
        }
        // Never: hidden on a page and on the New Tab surface.
        guard fire("Never"), await until(3, { bar.isHidden && win.webInsets.top == ChromeStyle.webTop }) else { return finish(false, "Never on a page: \(barState(ctl))") }
        guard await onNewTab(), bar.isHidden, checks() == ["off", "off", "on"], (try? store.setting(BookmarksBarMode.settingKey)) == "never" else {
            return finish(false, "Never on the New Tab surface: \(barState(ctl)), marks \(checks()), stored \(String(describing: try? store.setting(BookmarksBarMode.settingKey)))")
        }
        // Toggle (Shift+Cmd+B): a hidden bar shows on every page (Always), a shown one goes (Never).
        cmdShiftB()
        guard await until(3, { app.barMode == .always && !bar.isHidden }) else { return finish(false, "Toggle from Never: \(barState(ctl))") }
        cmdShiftB()
        guard await until(3, { app.barMode == .never && bar.isHidden }), (try? store.setting(BookmarksBarMode.settingKey)) == "never" else { return finish(false, "Toggle from Always: \(barState(ctl))") }
        guard fire("On New Tab Only"), await until(3, { !bar.isHidden }), await onPage(), await until(3, { bar.isHidden && win.webInsets.top == ChromeStyle.webTop }) else {
            return finish(false, "On New Tab Only again: \(barState(ctl))")
        }
        cmdShiftB()  // hidden on a page: the toggle shows it everywhere
        guard await until(3, { app.barMode == .always && !bar.isHidden }) else { return finish(false, "Toggle on a page under On New Tab Only: \(barState(ctl))") }
        // The mode is read back from the store the way a launch reads it.
        guard BookmarksBarMode(stored: try? store.setting(BookmarksBarMode.settingKey)) == app.barMode else { return finish(false, "the stored mode does not read back as \(app.barMode)") }
        finish(violations.isEmpty, "On New Tab Only (default), Always, Never and the toggle show and hide the bar on a page and on the New Tab surface, Always pushes the page down 42 pt, the mode is stored, chips at x 12 y 54 h 30 of the card \(violations)")
    }

    /// A bar item navigates the current tab, Cmd+click and a middle click open background tabs, a folder chip shows its tree, an address off the allowlist opens nothing.
    func bmOpen() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        addMark("Alpha", fixture("b.html"))
        addMark("Beta", fixture("link.html"))
        addMark("Script", "javascript:window.__bmGate = 1")
        addMark("Hosts", "file:///etc/hosts")
        if let mine = try? store.addFolder(title: "Mine", parentId: barRoot()!.id) { addMark("Child", fixture("b.html?child"), in: mine) }
        app.setBarMode(.always)
        guard await until(3, { chipTitles() == ["Alpha", "Beta", "Script", "Hosts", "Mine"] }), let alpha = chip("Alpha"), let beta = chip("Beta"), let script = chip("Script"), let hosts = chip("Hosts"), let mine = chip("Mine") else {
            return finish(false, "the bar shows \(chipTitles())")
        }
        // A click on a page's chip loads it in this tab: no new tab.
        let before = loads
        guard click(alpha) else { return finish(false, "the Alpha chip is not what is under its middle point") }
        guard await until(15, { win.activeTab === tab && tab.url.hasSuffix("/b.html") && loads > before && win.tabs.count == 1 }) else {
            return finish(false, "a click on Alpha: tab \(tab.url), tabs \(win.tabs.count), active is the same tab \(win.activeTab === tab)")
        }
        // Cmd+click: a background tab, the selection stays.
        mouseUp(beta, command: true)
        guard await until(15, { win.tabs.count == 2 && win.tabs.contains { $0.url.hasSuffix("/link.html") } }) else { return finish(false, "Cmd+click on Beta left \(win.tabs.map(\.url))") }
        try? await Task.sleep(for: .milliseconds(500))
        guard win.activeTab === tab, tab.url.hasSuffix("/b.html") else { return finish(false, "Cmd+click on Beta took the selection (active \(win.activeTab?.url ?? "nil"))") }
        // A middle click does the same.
        guard click(alpha, middle: true), await until(15, { win.tabs.count == 3 }) else { return finish(false, "a middle click on Alpha left \(win.tabs.count) tabs") }
        try? await Task.sleep(for: .milliseconds(500))
        guard win.activeTab === tab else { return finish(false, "a middle click on Alpha took the selection") }
        // An address off the allowlist is stored but never opened: a javascript: bookmark never runs in the page (a page-side marker stays 0; the page is the fixture), a file: one never loads.
        guard await evaluate(tab, "window.__bmGate = 0") == "0" else { return finish(false, "no marker in the page") }
        mouseUp(script)
        try? await Task.sleep(for: .milliseconds(800))
        let marker = await evaluate(tab, "window.__bmGate")
        guard marker == "0" else { return finish(false, "the javascript: bookmark ran in the page (marker \(marker ?? "nil"))") }
        let tabsNow = win.tabs.count, urlNow = tab.url
        mouseUp(hosts)
        try? await Task.sleep(for: .milliseconds(800))
        guard win.tabs.count == tabsNow, tab.url == urlNow else { return finish(false, "the file: bookmark opened (tabs \(win.tabs.count), url \(tab.url))") }
        // A folder chip shows its tree; choosing its page loads it here.
        ContextMenus.dismiss(choosing: nil)
        guard click(mine), let menu = await ctxMenu("bookmarks", seconds: 3)?.menu, titles(menu) == ["Child"] else { return finish(false, "the folder chip's menu is \(String(describing: ContextMenus.pending.map { titles($0.menu) }))") }
        let loadsNow = loads
        ContextMenus.dismiss(choosing: item(menu, "Child"))
        guard await until(15, { tab.url.hasSuffix("/b.html?child") && loads > loadsNow }) else { return finish(false, "choosing Child from the folder menu left the tab at \(tab.url)") }
        // The Bookmarks menu's tree does the same.
        guard treeTitles("Bookmarks Bar").contains("Beta"), let sub = menuItem("Bookmarks Bar")?.submenu, let betaRow = item(sub, "Beta"), let i = sub.items.firstIndex(of: betaRow) else {
            return finish(false, "Bookmarks Bar menu rows \(treeTitles("Bookmarks Bar"))")
        }
        sub.performActionForItem(at: i)
        guard await until(15, { tab.url.hasSuffix("/link.html") }) else { return finish(false, "the Bookmarks Bar menu row Beta left the tab at \(tab.url)") }
        // On the New Tab surface a click leaves it and loads in that tab.
        ctl.newTab()
        guard await until(15, { ctl.newTabShown }), let active = win.activeTab else { return finish(false, "no New Tab surface") }
        app.setBarMode(.newTabOnly)
        guard await until(3, { chip("Alpha") != nil && !(bmBar?.isHidden ?? true) }), let alpha2 = chip("Alpha") else { return finish(false, "no bar on the New Tab surface") }
        guard click(alpha2), await until(15, { active.url.hasSuffix("/b.html") && !ctl.newTabShown }) else { return finish(false, "a click on the New Tab bar left the new tab at \(active.url) (surface shown \(ctl.newTabShown))") }
        finish(violations.isEmpty, "a click loads the bookmark in the current tab, Cmd+click and a middle click open background tabs, a folder chip and the Bookmarks menu list and open their pages, a file: bookmark opens nothing, a click on the New Tab bar leaves the surface \(violations)")
    }

    /// Rename and delete in the manager reach the bar and the menu; a double click opens a page in a new tab; Delete and the Delete key work; roots stay.
    func bmManager() async {
        guard await ready(), let ctl, let win, let store else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        addMark("Alpha", fixture("b.html"))
        addMark("Beta", fixture("link.html"))
        if let mine = try? store.addFolder(title: "Mine", parentId: barRoot()!.id) { addMark("Child", fixture(""), in: mine) }
        app.setBarMode(.always)
        let tabsBefore = win.tabs.count
        guard fire("Manage Bookmarks") else { return finish(false, "Manage Bookmarks is not an enabled menu item") }
        let m = manager
        guard await until(5, { m.window.isVisible }) else { return finish(false, "Manage Bookmarks did not show the Bookmarks window") }
        try? await Task.sleep(for: .milliseconds(300))
        let terms = hiddenTerms(m.window)
        guard terms.ok else { return finish(false, "the Bookmarks window can show: \(terms.text)") }
        guard win.tabs.count == tabsBefore else { return finish(false, "Manage Bookmarks opened a tab") }
        let want = ["Bookmarks Bar", "  Alpha", "  Beta", "  Mine", "    Child", "Other Bookmarks"]
        guard m.visibleTitles == want else { return finish(false, "the window lists \(m.visibleTitles), want \(want)") }
        // A double click on Alpha opens it in a new tab.
        guard let alphaNode = m.node(titled: "Alpha") else { return finish(false, "no Alpha row") }
        m.select(alphaNode)
        _ = m.outline.sendAction(m.outline.doubleAction, to: m.outline.target)
        guard await until(15, { win.tabs.count == tabsBefore + 1 && win.tabs.contains { $0.url.hasSuffix("/b.html") } }) else { return finish(false, "a double click on Alpha opened \(win.tabs.map(\.url))") }
        // A double click never starts editing the title (the hidden window ignores the mouse, so what is asserted is that no title cell is editable until Return asks for it).
        let alphaRow = m.outline.row(forItem: alphaNode)
        guard let alphaCell = m.outline.view(atColumn: 0, row: alphaRow, makeIfNecessary: true) as? NSTextField, !alphaCell.isEditable, (m.window.firstResponder as? NSTextView)?.delegate !== alphaCell else {
            return finish(false, "after the double click the Alpha title cell is editable or being edited")
        }
        // Rename Alpha in the window: the bar, the menu and the store follow.
        func rename(_ old: String, to new: String) -> Bool {
            guard let n = m.node(titled: old) else { return false }
            m.select(n)
            let r = m.outline.row(forItem: n)
            guard r >= 0, let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
                                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return false }
            m.outline.keyDown(with: ret)  // Return asks for the rename
            guard let field = m.outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTextField, field.isEditable, let action = field.action else { return false }
            field.stringValue = new
            return field.sendAction(action, to: field.target)
        }
        guard rename("Alpha", to: "Alpha Renamed") else {
            let r = m.outline.selectedRow, f = m.outline.view(atColumn: 0, row: max(r, 0), makeIfNecessary: true) as? NSTextField
            return finish(false, "the Alpha title cell cannot be edited by Return (selected row \(r), cell \(String(describing: f.map { "editable \($0.isEditable) action \(String(describing: $0.action))" })))")
        }
        guard await until(3, { chipTitles().contains("Alpha Renamed") && !chipTitles().contains("Alpha") }), treeTitles("Bookmarks Bar").contains("Alpha Renamed"), recentRows().rows.contains("Alpha Renamed"),
              (try? store.bookmark(forURL: fixture("b.html")))?.title == "Alpha Renamed", m.visibleTitles.contains("  Alpha Renamed") else {
            return finish(false, "after the rename: chips \(chipTitles()), tree \(treeTitles("Bookmarks Bar")), recent \(recentRows().rows), window \(m.visibleTitles)")
        }
        // Delete Beta with the button: gone from the window, the bar, the menu and the store (tombstoned).
        guard let beta = m.node(titled: "Beta") else { return finish(false, "no Beta row") }
        m.select(beta)
        m.deleteButton.performClick(nil)
        guard await until(3, { !chipTitles().contains("Beta") }), !m.visibleTitles.contains("  Beta"), !treeTitles("Bookmarks Bar").contains("Beta"), !recentRows().rows.contains("Beta"),
              (try? store.bookmark(forURL: fixture("link.html"))) == nil else {
            return finish(false, "after Delete: chips \(chipTitles()), window \(m.visibleTitles), tree \(treeTitles("Bookmarks Bar")), recent \(recentRows().rows)")
        }
        // The Delete key removes Child (a key event handed to the table).
        guard let child = m.node(titled: "Child") else { return finish(false, "no Child row") }
        m.select(child)
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
                                         context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) else { return finish(false, "no key event") }
        m.outline.keyDown(with: key)
        guard m.node(titled: "Child") == nil, (try? store.bookmark(forURL: fixture(""))) == nil else { return finish(false, "the Delete key left Child (\(m.visibleTitles))") }
        // A root cannot be deleted; New Folder adds a folder under the selected root; deleting a folder takes its chip off the bar.
        if let root = m.node(titled: "Other Bookmarks") {
            m.select(root)
            m.deleteButton.performClick(nil)
            m.folderButton.performClick(nil)
        }
        guard (try? store.bookmarkRoots().count) == 2, m.visibleTitles.last == "  New Folder" else { return finish(false, "roots \(String(describing: try? store.bookmarkRoots().count)), window \(m.visibleTitles)") }
        guard let mine = m.node(titled: "Mine") else { return finish(false, "no Mine row") }
        m.select(mine)
        m.deleteButton.performClick(nil)
        guard await until(3, { !chipTitles().contains("Mine") }), m.node(titled: "Mine") == nil, chipTitles() == ["Alpha Renamed"] else { return finish(false, "after deleting Mine the bar shows \(chipTitles())") }
        // New Folder with nothing selected adds the folder to Bookmarks Bar.
        m.outline.deselectAll(nil)
        m.folderButton.performClick(nil)
        guard await until(3, { chipTitles() == ["Alpha Renamed", "New Folder"] }), barTitles() == ["Alpha Renamed", "New Folder"] else { return finish(false, "New Folder with no selection left the bar as \(barTitles())") }
        _ = ctl
        m.window.close()
        finish(violations.isEmpty, "the window is hidden (\(terms.text)), lists both roots and their rows, a double click opened a tab, a rename and a delete (button and Delete key) reached the bar, the Bookmarks menu and the store, roots stayed, New Folder added a folder \(violations)")
    }

    /// A bookmarked page is a command bar row, also one never visited; a deleted bookmark stops appearing at once; a bookmark outranks an equal page without one.
    func bmSuggest() async {
        guard await ready(), let ctl else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        func zebra() async -> Bool {
            guard await openBar() else { return false }
            barType("zebra")
            let got = await until(3, { bar?.state.rows.contains { $0.kind == .page && ($0.url ?? "").hasSuffix("/zebra-never-visited.html") } == true })
            press(.escape); press(.escape)
            _ = await until(2, { !barOpen() })
            return got
        }
        guard !(await zebra()) else { return finish(false, "a page nobody bookmarked or visited is already a row (\(rowValues))") }
        guard let b = addMark("Zebra Notes", fixture("zebra-never-visited.html")) else { return finish(false, "no bookmark added") }
        guard await zebra() else { return finish(false, "the bookmarked page is not a command bar row (\(rowValues))") }
        // Deleted: gone from the next keystroke.
        app.deleteBookmark(b.id)
        guard !(await zebra()) else { return finish(false, "a deleted bookmark is still a row") }
        // Equal pages: the bookmarked one ranks first.
        seed("http://one.example/note", "Note One", ago: 3600)
        seed("http://two.example/note", "Note Two", ago: 60)
        func noteRows() async -> [String]? {
            guard await openBar() else { return nil }
            barType("note")
            _ = await until(3, { bar?.state.rows.contains { $0.kind == .page } == true })
            let rows = bar?.state.rows.filter { $0.kind == .page }.compactMap(\.url) ?? []
            press(.escape); press(.escape)
            _ = await until(2, { !barOpen() })
            return rows
        }
        let plain = await noteRows()
        guard plain?.first == "http://two.example/note" else { return finish(false, "without a bookmark the newer page should lead, got \(plain ?? [])") }
        // The bookmark's address differs by a trailing slash: still the same page, one row, and it leads.
        addMark("Note One", "http://one.example/note/")
        let marked = await noteRows()
        guard marked?.first == "http://one.example/note" else { return finish(false, "the bookmarked page should lead, got \(marked ?? [])") }
        guard marked?.filter({ $0.contains("one.example") }).count == 1 else { return finish(false, "a page both bookmarked and visited gave \(marked?.filter { $0.contains("one.example") } ?? []), want one row") }
        _ = ctl
        finish(violations.isEmpty, "a bookmarked page that was never visited is a command bar row, a deleted bookmark is gone at the next keystroke, a bookmarked page outranks an equal one \(violations)")
    }

    /// Bookmark All Tabs (tab list menu): the card in folder mode with "New Folder" selected under Bookmarks Bar; Cancel saves nothing; Save adds the folder with one bookmark per tab, in order.
    func bmAllTabs() async {
        guard await ready(), let ctl, let win, let store, let ed = editor else { return }
        guard await openTabs(3) else { return finish(false, "no 3 tabs") }
        let targets = [fixture(""), fixture("b.html"), fixture("link.html")]
        for (t, u) in zip(win.tabs, targets) {
            let before = loads
            t.loadURL(u)
            _ = await until(15, { loads > before })
        }
        guard await until(15, { ctl.list.items.map(\.title) == ["Noche App Fixture", "B Page", "Link Page"] }) else { return finish(false, "tab titles \(ctl.list.items.map(\.title))") }
        func openMenu() async -> ContextMenus.Pending? {
            ContextMenus.dismiss(choosing: nil)
            let sidebar = ctl.sidebar
            guard let hit = rightClick(sidebar, at: NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.height - 60)), !(hit is TabRowView) else { return nil }
            return await ctxMenu("sidebar", seconds: 3)
        }
        func folders() -> [Bookmark] { ((try? barRoot().map { try store.bookmarkChildren(of: $0.id) }) ?? nil)?.filter { $0.kind == .folder } ?? [] }
        guard let a = await openMenu(), item(a.menu, "Bookmark All Tabs")?.isEnabled == true else { return finish(false, "no enabled Bookmark All Tabs row in the tab list menu") }
        ContextMenus.dismiss(choosing: item(a.menu, "Bookmark All Tabs"))
        guard await until(3, { !ed.isHidden }), ed.isFolderMode else { return finish(false, "Bookmark All Tabs showed no folder card (hidden \(ed.isHidden), mode \(ed.mode))") }
        let selection = (ed.name.currentEditor() as? NSTextView)?.selectedRange
        guard ed.name.stringValue == "New Folder", selection == NSRange(location: 0, length: 10), ed.folders.titleOfSelectedItem == "Bookmarks Bar", ed.done.title == "Save", ed.remove.title == "Cancel", ed.heading.stringValue == "New folder" else {
            return finish(false, "the folder card: name \(ed.name.stringValue), selection \(String(describing: selection)), parent \(ed.folders.titleOfSelectedItem ?? "nil"), buttons \(ed.remove.title) and \(ed.done.title)")
        }
        guard folders().isEmpty else { return finish(false, "a folder exists before Save: \(folders().map(\.title))") }
        let terms = hiddenTerms(ctl.nsWindow!)
        guard terms.ok, ed.window === ctl.nsWindow else { return finish(false, "the card's window can show: \(terms.text)") }
        // Cancel adds nothing.
        ed.remove.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard await until(3, { inPage() }) else { return finish(false, "after Cancel the page did not take the keys back") }
        guard ed.isHidden, folders().isEmpty, (try? store.urlBookmarks().count) == 0 else { return finish(false, "Cancel left the card \(!ed.isHidden) or saved \(folders().map(\.title)) \(String(describing: try? store.urlBookmarks().count))") }
        // Save with a new name.
        guard let b = await openMenu() else { return finish(false, "no tab list menu the second time") }
        ContextMenus.dismiss(choosing: item(b.menu, "Bookmark All Tabs"))
        guard await until(3, { !ed.isHidden }) else { return finish(false, "no folder card the second time") }
        ed.name.stringValue = "Trip"
        ed.done.performClick(nil)
        guard await until(3, { folders().map(\.title) == ["Trip"] }), let trip = folders().first else { return finish(false, "Save added \(folders().map(\.title)), want Trip") }
        let kids = (try? store.bookmarkChildren(of: trip.id)) ?? []
        guard kids.map(\.url) == targets.map { Optional($0) }, kids.map(\.title) == ["Noche App Fixture", "B Page", "Link Page"], kids.map(\.position) == [0, 1, 2], ed.isHidden else {
            return finish(false, "the folder holds \(kids.map { "\($0.title) \($0.url ?? "nil") @\($0.position)" }), card hidden \(ed.isHidden)")
        }
        guard await until(3, { chipTitles() == ["Trip"] }) else { return finish(false, "the bar (\(chipTitles())) does not show Trip") }
        finish(violations.isEmpty, "Bookmark All Tabs opened the folder card (New Folder selected, parent Bookmarks Bar, hidden terms \(terms.text)), Cancel saved nothing, Save added Trip with the 3 tabs in order \(violations)")
    }
}
#endif
