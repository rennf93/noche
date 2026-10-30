#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Pinned tabs (M1.6 Task 3): Pin and Unpin, dormant pinned tabs, the pinned page, the restore, and the two carried-in sidebar checks.
extension SelfTest {
    func pinKey() { key("d", code: 2, [.command, .shift]) }
    func tile(_ n: Int) -> PinnedTileView? { ctl?.view(withIdentifier: "sidebar.pin.\(n)") as? PinnedTileView }
    func entry(_ c: BrowserWindowController, _ id: TabID) -> TabItem? { c.list.items.first { $0.id == id } }

    /// The Tabs menu's pin item as the menu validates it (title and enabled state).
    func pinMenu() -> NSMenuItem? {
        guard let tabs = NSApp.mainMenu?.items.first(where: { $0.title == "Tabs" })?.submenu else { return nil }
        tabs.update()
        return tabs.items.first { ($0.representedObject as? MainMenu.Rule)?.entry.id == "tabs.pinTab" }
    }

    /// Makes |id| the active tab and waits for it.
    func select(_ c: BrowserWindowController, _ id: TabID) async -> Bool {
        guard let t = entry(c, id).flatMap({ c.engineTab($0) }) else { return false }
        c.window.activateTab(t)
        return await until(10, { c.list.activeID == id })
    }

    func pinned(_ c: BrowserWindowController, _ id: TabID, _ on: Bool) async -> Bool {
        await until(5, { self.entry(c, id)?.isPinned == on })
    }

    /// Reads the store back: the saved row of |id|.
    func stored(_ id: TabID) -> TabItem? {
        app.writer?.flush()
        return ((try? app.writer?.store.loadWindows()) ?? []).flatMap(\.tabs).first { $0.id == id }
    }

    /// Note 5.2 `pin-toggle`: Shift+Cmd+D pins the active tab (a tile at slot 0, the pinned address, the store row), the menu then says Unpin,
    /// a second press puts the tab at the top of the day list; the tab and tile context menus do the same.
    func pinToggle() async {
        guard await ready(), let c = ctl, let win else { return }
        guard await openTabs(3) else { return finish(false, "extra tabs never appeared") }
        let b = c.list.items[1]
        guard await select(c, b.id) else { return finish(false, "tab B did not activate") }
        guard pinMenu()?.title == "Pin", pinMenu()?.isEnabled == true else { return finish(false, "the Tabs menu shows \(pinMenu()?.title ?? "nothing") enabled=\(pinMenu()?.isEnabled ?? false), want Pin enabled") }
        pinKey()
        guard await pinned(c, b.id, true) else { return finish(false, "Shift+Cmd+D did not pin the active tab") }
        let t = entry(c, b.id)!
        guard t.inGrid, t.pinnedURL == b.url, c.list.items.first?.id == b.id else { return finish(false, "pinned tab: inGrid \(t.inGrid) pinnedURL \(t.pinnedURL ?? "nil") first \(c.list.items.first?.id == b.id), want in the grid at the pinned address, first") }
        guard await until(5, { self.tile(0) != nil && c.sidebar.tabRowCount == 2 }) else { return finish(false, "no tile at slot 0 or \(c.sidebar.tabRowCount) tab rows, want a tile and 2 rows") }
        guard near(c.frame(ofIdentifier: "sidebar.pin.0"), 6, 54, 41, 41) else { return finish(false, "tile 0 at \(String(describing: c.frame(ofIdentifier: "sidebar.pin.0")))") }
        guard win.tabs.count == 3, c.list.activeID == b.id else { return finish(false, "pinning changed the engine tabs (\(win.tabs.count)) or the selection") }
        guard pinMenu()?.title == "Unpin" else { return finish(false, "the Tabs menu shows \(pinMenu()?.title ?? "nothing") on a pinned tab, want Unpin") }
        guard stored(b.id).map({ $0.isPinned && $0.inGrid && $0.pinnedURL == b.url }) == true else { return finish(false, "the store row is \(String(describing: stored(b.id)))") }
        pinKey()
        guard await pinned(c, b.id, false) else { return finish(false, "a second Shift+Cmd+D did not unpin") }
        guard entry(c, b.id)?.pinnedURL == nil, c.list.dayOrder.first == .tab(b.id) else { return finish(false, "unpinned tab: pinnedURL \(entry(c, b.id)?.pinnedURL ?? "nil"), day list \(c.list.dayOrder.prefix(2)), want no pinned address and the top of the day list") }
        guard await until(5, { self.tile(0) == nil && c.sidebar.tabRowCount == 3 }), pinMenu()?.title == "Pin" else { return finish(false, "tile still there or the menu says \(pinMenu()?.title ?? "nothing")") }
        guard stored(b.id).map({ !$0.isPinned && $0.pinnedURL == nil }) == true else { return finish(false, "the store row still pinned: \(String(describing: stored(b.id)))") }
        // The tab row's menu: Pin; then the tile's menu: Unpin.
        ContextMenus.dismiss(choosing: nil)
        guard let row = c.sidebar.rows.first(where: { $0.tabID == b.id }), rightClick(row) != nil, let m = await ctxMenu("tab", seconds: 3), m.menu.items.first?.title == "Pin", m.menu.items.first?.isEnabled == true else { return finish(false, "the row menu does not start with an enabled Pin") }
        ContextMenus.dismiss(choosing: m.menu.items.first)
        guard await pinned(c, b.id, true), await until(5, { self.tile(0) != nil }) else { return finish(false, "the context menu's Pin did not pin") }
        ContextMenus.dismiss(choosing: nil)
        guard let tl = tile(0), rightClick(tl) != nil, let u = await ctxMenu("tab", seconds: 3), u.menu.items.first?.title == "Unpin" else { return finish(false, "the tile menu does not start with Unpin") }
        ContextMenus.dismiss(choosing: u.menu.items.first)
        guard await pinned(c, b.id, false) else { return finish(false, "the context menu's Unpin did not unpin") }
        finish(violations.isEmpty, "Shift+Cmd+D pins to the grid (slot 0, pinned address, store row, menu says Unpin), again unpins to the top of the day list; the row and tile menus pin and unpin \(violations)")
    }

    /// Note 5.2 `pin-dormant`: Cmd+W on a pinned tab keeps its tile and drops the engine tab (the window keeps one engine tab: a blank
    /// day tab opens first when it was the last); a click or Cmd+1 brings the same tab back at its pinned page.
    func pinDormant() async {
        guard await ready(), let c = ctl, let win else { return }
        let a = c.list.items[0]
        pinKey()
        guard await pinned(c, a.id, true) else { return finish(false, "Shift+Cmd+D did not pin") }
        // A burst: the first close is held (the tab is closing, the engine has not closed it yet), so the second Cmd+W lands on the blank
        // tab while the pin is still closing, on every run.
        BrowserWindowController.holdNextClose = true
        cmdW(); cmdW()
        guard BrowserWindowController.heldClose != nil else { return finish(false, "the first Cmd+W was not held") }
        BrowserWindowController.releaseHeldClose()
        guard await until(10, { c.list.items.count == 2 && win.tabs.count == 1 }) else {
            return finish(false, "Cmd+W on the only (pinned) tab left \(c.list.items.count) list items and \(win.tabs.count) engine tabs, want 2 and 1 (windows \(app.controllers.count))")
        }
        try? await Task.sleep(for: .milliseconds(800))
        guard c.list.items.count == 2, win.tabs.count == 1, app.controllers.count == 1 else { return finish(false, "after a burst of Cmd+W: \(c.list.items.count) list items, \(win.tabs.count) engine tabs, \(app.controllers.count) windows, want 2, 1 and 1") }
        guard app.controllers.count == 1, let dormant = entry(c, a.id), dormant.engineID == nil, dormant.isPinned, dormant.pinnedURL == a.url else { return finish(false, "the pinned tab is \(String(describing: entry(c, a.id))), want a dormant pin") }
        guard let active = c.list.activeID.flatMap({ entry(c, $0) }), active.id != a.id, active.url == "about:blank", active.engineID != nil, !active.isPinned else { return finish(false, "no blank day tab took the selection") }
        guard await until(5, { self.tile(0)?.faviconView.alphaValue == ChromeStyle.dormantAlpha }) else { return finish(false, "the dormant tile's favicon alpha is \(tile(0)?.faviconView.alphaValue ?? -1), want \(ChromeStyle.dormantAlpha)") }
        guard let tl = tile(0), click(tl) else { return finish(false, "could not click the tile") }
        guard await until(15, { self.entry(c, a.id)?.engineID != nil && win.tabs.count == 2 && c.list.activeID == a.id }) else {
            return finish(false, "a click on the dormant tile left engine \(String(describing: entry(c, a.id)?.engineID)), \(win.tabs.count) engine tabs, active \(c.list.activeID == a.id)")
        }
        guard c.list.items.first?.id == a.id, c.list.items.count == 2, await until(10, { self.entry(c, a.id)?.url == a.url }) else { return finish(false, "the woken tab is not the same tab at its pinned page: \(String(describing: entry(c, a.id)))") }
        guard await until(5, { self.tile(0)?.faviconView.alphaValue == 1 }) else { return finish(false, "the tile stayed dim after the wake") }
        // With another engine tab open: Cmd+W on the active pinned tab drops one engine tab and keeps the list.
        _ = win.addTab(withURL: fixture("b.html"), activate: false)
        guard await until(20, { win.tabs.count == 3 && c.list.items.count == 3 }) else { return finish(false, "a third tab never appeared") }
        guard await select(c, a.id) else { return finish(false, "the pinned tab did not activate") }
        cmdW()
        guard await until(10, { win.tabs.count == 2 && c.list.items.count == 3 && self.entry(c, a.id)?.engineID == nil }) else { return finish(false, "Cmd+W on the pinned tab: \(win.tabs.count) engine tabs, \(c.list.items.count) list items") }
        guard let now = c.list.activeID, now != a.id, entry(c, now)?.engineID != nil else { return finish(false, "the selection did not move to a live tab") }
        // Cmd+1 is the first row, the pinned tile: it wakes.
        guard key("1", code: 18, menuOnly: true) else { return finish(false, "Cmd+1 was not handled") }
        guard await until(15, { self.entry(c, a.id)?.engineID != nil && c.list.activeID == a.id && win.tabs.count == 3 }) else { return finish(false, "Cmd+1 did not wake the pinned tab") }
        // Closes that do not come through Cmd+W or the menu (a page closing itself, the engine's own, a direct tab close): the engine closes the
        // window with its last tab and refuses a new one, so the window is made again with the pins dormant and a blank tab (AppDelegate.revive).
        for t in win.tabs where t !== c.engineTab(entry(c, a.id)!) { t.close() }
        guard await until(10, { win.tabs.count == 1 && c.list.items.count == 1 }) else { return finish(false, "closing the other tabs left \(c.list.items.count) items and \(win.tabs.count) engine tabs") }
        // Every close Noche starts (the tile's context menu, a middle click, File > Close Tab) keeps the window without making a new one.
        for (label, close) in [("the tile menu's Close", 0), ("a middle click on the tile", 1), ("File > Close Tab", 2)] {
            switch close {
            case 0:
                ContextMenus.dismiss(choosing: nil)
                guard let t = tile(0), rightClick(t) != nil, let m = await ctxMenu("tab", seconds: 3), item(m.menu, "Close")?.isEnabled == true else { return finish(false, "no enabled Close in the tile menu") }
                ContextMenus.dismiss(choosing: item(m.menu, "Close"))
            case 1: guard let t = tile(0), click(t, middle: true) else { return finish(false, "no middle click on the tile") }
            default: guard fire("Close Tab") else { return finish(false, "File > Close Tab did not run") }
            }
            guard await until(10, { c.list.items.count == 2 && win.tabs.count == 1 && self.entry(c, a.id)?.engineID == nil }), ctl === c, app.controllers.count == 1 else {
                return finish(false, "\(label) on the only tab: \(c.list.items.count) list items, \(win.tabs.count) engine tabs, \(app.controllers.count) windows, same controller \(ctl === c), want 2, 1, 1 and the same window")
            }
            guard let tl = tile(0), click(tl), await until(15, { win.tabs.count == 2 && self.entry(c, a.id)?.engineID != nil }) else { return finish(false, "the tile did not wake the pin after \(label)") }
            for t in win.tabs where t !== c.engineTab(entry(c, a.id)!) { t.close() }
            guard await until(10, { win.tabs.count == 1 && c.list.items.count == 1 }) else { return finish(false, "could not get back to the single pinned tab after \(label)") }
        }
        func revived(_ old: BrowserWindowController, _ label: String) async -> BrowserWindowController? {
            guard await until(20, { guard let n = self.ctl, n !== old else { return false }; return n.list.items.count == 2 && n.window.tabs.count == 1 && !n.restoring && self.app.controllers.count == 1 }), let n = ctl else {
                finish(false, "\(label): \(ctl?.list.items.count ?? -1) list items, \(ctl?.window.tabs.count ?? -1) engine tabs, \(app.controllers.count) windows, want 2, 1 and 1 in a new window"); return nil
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard n.list.items.count == 2, n.window.tabs.count == 1, app.controllers.count == 1, n.id == old.id, entry(n, a.id)?.engineID == nil, entry(n, a.id)?.isPinned == true, entry(n, a.id)?.pinnedURL == a.url,
                  n.list.activeID.flatMap({ entry(n, $0) })?.url == "about:blank" else { finish(false, "\(label): the new window is not the same window id with a dormant pin and a blank tab"); return nil }
            return n
        }
        c.engineTab(entry(c, a.id)!)?.close()   // the engine's own close of the pinned tab: Noche's close path is not involved
        guard let n1 = await revived(c, "the pinned tab closed by the engine") else { return }
        n1.window.activeTab?.close()            // a day tab closed by the engine, the dormant pin the only other item
        guard let n2 = await revived(n1, "the day tab closed by the engine") else { return }
        guard let tl3 = tile(0), click(tl3), await until(15, { n2.window.tabs.count == 2 && self.entry(n2, a.id)?.engineID != nil }) else { return finish(false, "the tile did not wake the pin") }
        for t in n2.window.tabs where t !== n2.engineTab(entry(n2, a.id)!) { t.close() }
        guard await until(10, { n2.window.tabs.count == 1 && n2.list.items.count == 1 }), let pageTab = n2.window.activeTab else { return finish(false, "no single pinned tab for the page's own close") }
        _ = await evaluate(pageTab, "window.close(); 1")   // the page closes itself (allowed for a tab with one history entry)
        guard let n3 = await revived(n2, "the pinned tab closed by its own page") else { return }
        _ = n3
        finish(violations.isEmpty, "Cmd+W on a pinned tab: the tile stays dim, the engine tab goes (a blank day tab opens first when it was the last), a click or Cmd+1 wakes the same tab at its pinned page \(violations)")
    }

    /// `pin-reset`: a pinned tab navigated away shows the return glyph (hover); Reset to Pinned Page loads the pinned address in the same engine
    /// tab; Use Current Page as Pinned Page takes the current one; Copy Pinned URL; the glyph itself resets.
    func pinReset() async {
        guard await ready(), let c = ctl, let win, let tab = win.activeTab else { return }
        let b = fixture("b.html"), l = fixture("link.html")
        let a = c.list.items[0]
        BrowserWindowController.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.noche.selftest"))
        BrowserWindowController.pasteboard.clearContents()
        pinKey()
        guard await pinned(c, a.id, true), await until(5, { self.tile(0) != nil }), let pinnedAt = entry(c, a.id)?.pinnedURL else { return finish(false, "no pinned tile") }
        func glyph() -> (can: Bool, shown: Bool) { guard let t = tile(0) else { return (false, false) }; t.hover(true); let s = t.showsResetGlyph; t.hover(false); return (t.canReset, s) }
        func menu() async -> NSMenu? {
            ContextMenus.dismiss(choosing: nil)
            guard let t = tile(0), rightClick(t) != nil, let m = await ctxMenu("tab", seconds: 3) else { return nil }
            return m.menu
        }
        func goTo(_ url: String) async -> Bool { tab.loadURL(url); return await until(10, { self.entry(c, a.id)?.url.hasSuffix(url.split(separator: "/").last.map(String.init) ?? url) == true && !(self.entry(c, a.id)?.isLoading ?? true) }) }
        guard glyph() == (false, false) else { return finish(false, "the glyph shows on the pinned page: \(glyph())") }
        guard let m0 = await menu(), let sub0 = item(m0, "Edit Pinned Page")?.submenu, sub0.items.map(\.title) == ["Use Current Page as Pinned Page", "Reset to Pinned Page", "Copy Pinned URL"],
              item(m0, "Edit Pinned Page")?.isEnabled == true, enabledTitles(sub0) == ["Copy Pinned URL"] else { return finish(false, "on the pinned page the submenu should hold three items with only Copy Pinned URL enabled") }
        guard await goTo(b) else { return finish(false, "tab never loaded b.html: \(entry(c, a.id)?.url ?? "nil")") }
        guard await until(5, { glyph() == (true, true) }) else { return finish(false, "off the pinned page the glyph shows \(glyph()), want shown on hover") }
        // Reset to Pinned Page: the same engine tab loads the pinned address.
        let engineBefore = entry(c, a.id)?.engineID, tabsBefore = win.tabs.count
        guard let m1 = await menu(), let sub1 = item(m1, "Edit Pinned Page")?.submenu, enabledTitles(sub1) == ["Use Current Page as Pinned Page", "Reset to Pinned Page", "Copy Pinned URL"] else { return finish(false, "off the pinned page all three items should be enabled") }
        ContextMenus.dismiss(choosing: item(sub1, "Reset to Pinned Page"))
        guard await until(10, { tab.url == pinnedAt && self.entry(c, a.id)?.url == pinnedAt }) else { return finish(false, "Reset to Pinned Page left the tab at \(tab.url), want \(pinnedAt)") }
        guard entry(c, a.id)?.engineID == engineBefore, win.tabs.count == tabsBefore, tab === win.activeTab else { return finish(false, "the reset did not use the same engine tab") }
        guard await until(5, { glyph() == (false, false) }) else { return finish(false, "the glyph still shows after the reset: \(glyph())") }
        // Use Current Page as Pinned Page.
        guard await goTo(l) else { return finish(false, "tab never loaded link.html") }
        guard let m2 = await menu(), let sub2 = item(m2, "Edit Pinned Page")?.submenu else { return finish(false, "no menu") }
        ContextMenus.dismiss(choosing: item(sub2, "Use Current Page as Pinned Page"))
        guard await until(5, { self.entry(c, a.id)?.pinnedURL == self.entry(c, a.id)?.url && self.entry(c, a.id)?.pinnedURL?.hasSuffix("link.html") == true }) else { return finish(false, "Use Current Page left pinnedURL \(entry(c, a.id)?.pinnedURL ?? "nil") with the tab at \(entry(c, a.id)?.url ?? "nil")") }
        guard await until(5, { glyph() == (false, false) }) else { return finish(false, "the glyph shows on the new pinned page") }
        // Copy Pinned URL, then the glyph's own click.
        guard await goTo(b), await until(5, { glyph().can }) else { return finish(false, "off the new pinned page the glyph should show") }
        guard let m3 = await menu(), let sub3 = item(m3, "Edit Pinned Page")?.submenu else { return finish(false, "no menu") }
        ContextMenus.dismiss(choosing: item(sub3, "Copy Pinned URL"))
        guard BrowserWindowController.pasteboard.string(forType: .string) == entry(c, a.id)?.pinnedURL, entry(c, a.id)?.pinnedURL?.hasSuffix("link.html") == true else { return finish(false, "Copy Pinned URL wrote \(BrowserWindowController.pasteboard.string(forType: .string) ?? "nil")") }
        guard let t = tile(0), let ns = c.nsWindow else { return finish(false, "no tile") }
        t.hover(true)
        let p = t.convert(NSPoint(x: t.resetGlyphRect.midX, y: t.resetGlyphRect.midY), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return finish(false, "no event") }
        t.mouseDown(with: down)
        guard await until(10, { tab.url.hasSuffix("link.html") && self.entry(c, a.id)?.url.hasSuffix("link.html") == true }) else { return finish(false, "a click on the glyph left the tab at \(tab.url)") }
        finish(violations.isEmpty, "off the pinned page the return glyph shows on hover and not on it; Reset to Pinned Page loads it in the same engine tab, Use Current Page takes the current one, Copy Pinned URL copies it, the glyph click resets \(violations)")
    }

    // MARK: restore

    /// Two phases. Phase 1: A and B pinned (B selected), C a day tab, F in a group. Phase 2: A restores dormant, B (selected, pinned), C and F live;
    /// engine tabs = unpinned + 1 for the selected pin. |held|: F never arrives and the fallback ends the restore: the pins and the group must
    /// survive, and F is still there, dormant.
    func pinLaunch(held: Bool) async {
        let a = fixture("favicon.html"), b = fixture("b.html"), l = fixture("link.html"), f = fixture("find.html")  // A has an icon: its dormant tile must show it
        if phase == 1 {
            guard await ready(), let c = ctl, let win, let writer = app.writer else { return }
            win.activeTab?.loadURL(a)
            guard await until(15, { c.list.items.first.flatMap { c.engineTab($0)?.favicon } != nil }) else { return finish(false, "phase 1: A never got its favicon") }
            for u in [b, l, f] { _ = win.addTab(withURL: u, activate: false) }
            guard await until(20, { self.urls(c) == [f, l, b, a] }) else { return finish(false, "phase 1: urls \(urls(c))") }
            let ids = Array(c.list.items.map(\.id).reversed())  // A B C F in opening order (the list is newest first)
            for id in ids.prefix(2) {
                guard await select(c, id) else { return finish(false, "phase 1: a tab did not activate") }
                pinKey()
                guard await pinned(c, id, true) else { return finish(false, "phase 1: Shift+Cmd+D did not pin") }
            }
            guard c.list.createGroup(with: ids[2], name: "G") != nil else { return finish(false, "phase 1: no group") }
            c.refresh(); c.changed()
            guard c.list.activeID == ids[1], c.list.groups.count == 1 else { return finish(false, "phase 1: active or groups wrong") }
            writer.flush()
            return finish(violations.isEmpty, "phase 1: A and B pinned (B selected), F a day tab, C in group G; saved \(violations)")
        }
        guard await until(held ? 25 : 30, { self.restoredUp(1) }), let c = ctl, let win else { return finish(false, "phase 2: no restored window") }
        let items = c.list.items
        guard items.count == 4 else { return finish(false, "phase 2: \(items.count) items") }
        guard items[0].isPinned, items[0].inGrid, items[1].isPinned, items[1].inGrid, items[0].pinnedURL == a, items[1].pinnedURL == b else { return finish(false, "phase 2: pins lost: \(items.map { "\($0.isPinned)/\($0.inGrid)/\($0.pinnedURL ?? "-")" })") }
        guard c.list.groups.count == 1, c.list.groups[0].name == "G", items[3].groupID == c.list.groups[0].id, items[2].groupID == nil, !items[2].isPinned else { return finish(false, "phase 2: the group or the day tab is wrong (groups \(c.list.groups.map(\.name)))") }
        guard items[0].engineID == nil else { return finish(false, "phase 2: pinned A got an engine tab") }
        guard c.list.activeID == items[1].id, items[1].engineID != nil else { return finish(false, "phase 2: the selected pinned tab B is not live and active") }
        let unpinned = items.filter { !$0.isPinned }.count, activePinned = (items.first { $0.id == c.list.activeID }?.isPinned ?? false) ? 1 : 0
        let want = held ? unpinned + activePinned - 1 : unpinned + activePinned
        guard await until(held ? 10 : 20, { win.tabs.count == want && (held ? c.list.items[3].engineID == nil : items[2...].allSatisfy { self.entry(c, $0.id)?.engineID != nil }) }) else {
            return finish(false, "phase 2: \(win.tabs.count) engine tabs, want \(want) (unpinned \(unpinned) + active pinned \(activePinned)\(held ? " - 1 held back" : "")), engines \(c.list.items.map { $0.engineID != nil })")
        }
        guard await until(5, { self.tile(0)?.faviconView.alphaValue == ChromeStyle.dormantAlpha && self.tile(1)?.faviconView.alphaValue == 1 }) else { return finish(false, "phase 2: tile alphas \(tile(0)?.faviconView.alphaValue ?? -1), \(tile(1)?.faviconView.alphaValue ?? -1)") }
        guard await until(10, { self.tile(0)?.showsPlaceholder == false }) else { return finish(false, "phase 2: the dormant tile of A shows the globe, want its saved favicon") }
        if held {
            guard c.list.items[3].engineID == nil, c.list.items[3].url == l else { return finish(false, "phase 2: the held-back tab is \(String(describing: c.list.items[3])), want dormant at \(l)") }
        }
        finish(violations.isEmpty, "phase 2: A dormant, B (selected pin), F\(held ? "" : " and C") live; \(win.tabs.count) engine tabs; pins and group G\(held ? " survive the fallback, the held-back C is a dormant child" : " back") \(violations)")
    }

    // MARK: reopen (T3.5)

    /// A day tab closed with pins and a group above it comes back between its old neighbours (the recorded index is inside its container).
    func reopenContainer() async {
        guard await ready(), let c = ctl, let win else { return }
        guard await openTabs(5) else { return finish(false, "tabs never appeared") }
        let ids = c.list.items.map(\.id)  // A B C D E
        guard await select(c, ids[0]) else { return finish(false, "A did not activate") }
        pinKey()
        guard await pinned(c, ids[0], true), c.list.createGroup(with: ids[1], name: "G") != nil else { return finish(false, "no pin or group") }
        c.refresh(); c.changed()
        let before = c.list.items.map(\.id)
        guard before == ids, c.list.containerIndex(of: ids[3]) == 2, c.list.items.firstIndex(where: { $0.id == ids[3] }) == 3 else { return finish(false, "setup: order \(before.count), D container index \(String(describing: c.list.containerIndex(of: ids[3])))") }
        guard await select(c, ids[3]) else { return finish(false, "D did not activate") }
        cmdW()
        guard await until(10, { c.list.items.count == 4 && win.tabs.count == 4 }) else { return finish(false, "Cmd+W on D left \(c.list.items.count) items") }
        shiftCmdT()
        guard await until(15, { c.list.items.count == 5 && c.list.activeID == ids[3] }) else { return finish(false, "Shift+Cmd+T gave \(c.list.items.count) items") }
        let after = c.list.items.map(\.id)
        let name = { (id: TabID) in String(Array("ABCDE")[ids.firstIndex(of: id) ?? 0]) }
        guard after == before else { return finish(false, "D came back in the wrong place: \(after.map(name)), want \(before.map(name))") }
        finish(violations.isEmpty, "D (day list position 2, flat position 3, a pin and a group above it) reopens between C and E: \(after.map(name)) \(violations)")
    }

    // MARK: carried from the Task 2 re-review

    /// Cmd+1 on a pinned tab while the grid is scrolled out of view: the tile comes back into view.
    func pinReveal() async {
        guard await ready(), let c = ctl, let win, let host = c.window.chromeHost else { return }
        guard await openTabs(2) else { return finish(false, "tab B never appeared") }
        let a = c.list.items[0], b = c.list.items[1]
        guard await select(c, a.id) else { return finish(false, "A did not activate") }
        pinKey()
        guard await pinned(c, a.id, true), await select(c, b.id) else { return finish(false, "no pin or B did not activate") }
        var items = [entry(c, a.id)!]
        items += (0..<80).map { TabItem(id: TabID(), engineID: 1000 + $0, url: "https://site\($0).example/", title: "Tab \($0)", isLoading: false) }
        items.append(entry(c, b.id)!)
        c.testSeed(TabList(items: items, activeID: b.id)!)
        let scroll = c.sidebar.scroll
        let end = max(0, c.sidebar.document.frame.height - scroll.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        guard end > 500 else { return finish(false, "the list is only \(end) pt past the window, the grid never leaves the screen") }
        let bottom = host.bounds.height - ChromeStyle.sidebarBottom
        func visible() -> Bool { c.frame(ofIdentifier: "sidebar.pin.0").map { $0.minY >= 48 && $0.maxY <= bottom } ?? false }
        guard !visible() else { return finish(false, "the tile is visible at the end of the list, the check proves nothing") }
        guard key("1", code: 18, menuOnly: true) else { return finish(false, "Cmd+1 was not handled") }
        guard await until(10, { c.list.activeID == a.id }) else { return finish(false, "Cmd+1 did not select the pinned tab") }
        guard await until(5, { visible() }) else { return finish(false, "the selected tile stayed off screen: \(String(describing: c.frame(ofIdentifier: "sidebar.pin.0"))), scroll offset \(scroll.contentView.bounds.minY) of \(end)") }
        _ = win
        finish(violations.isEmpty, "Cmd+1 on a pinned tab with the grid scrolled out of view scrolls the tile back (offset \(Int(scroll.contentView.bounds.minY))) \(violations)")
    }

    /// The bottom bar's dot and chevron as drawn: the bar is rendered into a bitmap and the pixels are measured (the geometry check reads
    /// the same constants the draw uses, so it cannot see a drawing that moved).
    func drawnBottomBar(_ bar: SidebarBottomBar) -> (dot: NSPoint?, chevron: NSPoint?) {
        guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return (nil, nil) }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / bar.bounds.width
        func center(_ x0: CGFloat, _ x1: CGFloat) -> NSPoint? {
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for py in 0..<rep.pixelsHigh { for px in Int(x0 * scale)..<min(rep.pixelsWide, Int(x1 * scale)) {
                guard (rep.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.4 else { continue }
                minX = min(minX, CGFloat(px)); maxX = max(maxX, CGFloat(px + 1)); minY = min(minY, CGFloat(py)); maxY = max(maxY, CGFloat(py + 1))
            } }
            return minX.isFinite ? NSPoint(x: (minX + maxX) / 2 / scale, y: (minY + maxY) / 2 / scale) : nil
        }
        return (center(70, 120), center(150, 197))
    }
}
#endif
