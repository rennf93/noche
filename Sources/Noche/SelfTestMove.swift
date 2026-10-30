#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Moving between windows (M1.6 Task 5b): `move-window`, `merge-windows` (both two-phase: phase 2 is the relaunch) and `revive-window` (T5b.3).
extension SelfTest {
    func becomeKey(_ w: BrowserWindowController) { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w.nsWindow) }

    /// A window opened at |page| with its first tab loaded.
    func openWindow(_ page: String) async -> BrowserWindowController? {
        let before = loads, count = app.controllers.count
        app.newWindow(url: fixture(page))
        guard await until(20, { self.app.controllers.count == count + 1 && self.loads > before && self.app.controllers.last?.list.items.count == 1 && self.app.controllers.last?.installed == true }) else { return nil }
        return app.controllers.last
    }

    /// Every item of every window with the marker (its custom title), and the controller that holds it.
    func marked(_ name: String) -> [(c: BrowserWindowController, item: TabItem)] {
        app.controllers.flatMap { c in c.list.items.filter { $0.customTitle == name }.map { (c, $0) } }
    }

    func storedWindows() -> [WindowSnapshot] { (try? app.writer?.store.loadWindows()) ?? [] }

    /// The menu's rows as the check reads them: title, or "---".
    func rows(_ m: NSMenu) -> String { titles(m).joined(separator: " | ") }

    // MARK: move-window

    /// Ruling M97 items 1 to 4. Window A holds a loaded tab, a pinned tile, a dormant tab, a tab inside a group with a peer, a group of two and
    /// two more; B, C are other windows. Phase 1: the Tabs menu and the group menu list this window (checked, off), the others by title and New
    /// Window per profile; each item moves A to B with its id, B in front; the group arrives whole; a tab goes to a new window; a window left with
    /// one dormant pin gets a blank tab; A's last tab moves and A closes; Reopen Closed Tab brings nothing back; the store shows each item in
    /// one window only. Phase 2 (after the relaunch): the same, from the restored windows.
    func moveWindow() async {
        if phase == 2 { return await moveWindowRelaunch() }
        guard await ready(), let a = ctl, let win, let writer = app.writer else { return }
        guard await openTabs(9, page: "b.html") else { return finish(false, "nine tabs never appeared") }
        // The window's own first tab (the bottom row, N below) is on the fixture's root page: every tab is on b.html, as N must be when it moves out.
        let first = loads
        win.tabs.first?.loadURL(fixture("b.html"))
        guard await until(20, { self.loads > first && a.list.items.allSatisfy { $0.url.hasSuffix("b.html") && !$0.isLoading && !$0.title.isEmpty } }) else { return finish(false, "the nine tabs are not all on b.html") }
        let t = a.list.items.map(\.id)
        let (a0, l, p, d, x, y, h1, h2, n) = (t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
        for (id, name) in [(a0, "m-a0"), (l, "m-loaded"), (p, "m-tile"), (d, "m-dormant"), (x, "m-in"), (y, "m-peer"), (h1, "m-h1"), (h2, "m-h2"), (n, "m-new")] { a.renameTab(id, to: name) }
        // A tile, and a dormant day tab (pinned, closed by its engine tab going away, then unpinned).
        a.togglePin(of: p)
        guard await until(5, { self.entry(a, p)?.isPinned == true && self.entry(a, p)?.inGrid == true }) else { return finish(false, "no tile") }
        a.togglePin(of: d)
        guard await until(5, { self.entry(a, d)?.isPinned == true }), let dTab = entry(a, d).flatMap({ a.engineTab($0) }) else { return finish(false, "no pinned D") }
        a.closeTab(dTab)
        guard await until(10, { self.entry(a, d)?.engineID == nil && a.list.items.count == 9 }) else { return finish(false, "D did not go dormant") }
        a.togglePin(of: d)
        guard await until(5, { self.entry(a, d)?.isPinned == false }), entry(a, d)?.engineID == nil else { return finish(false, "D is not a dormant day tab") }
        // The groups: Gx (X and the peer Y), Gh (H1, H2, closed, pink, with an icon).
        guard let gx = a.list.createGroup(with: x, name: "m-gx"), let gh = a.list.createGroup(with: h1, name: "m-group") else { return finish(false, "no groups") }
        a.list.setGroup(y, gx); a.list.setGroup(h2, gh); a.list.setGroupColor(gh, 5); a.list.setGroupIcon(gh, "star"); a.list.collapse(gh)
        a.refresh(); a.changed()
        let groupH = a.group(withID: gh)!
        let aTabs = win.tabs.count   // 8 engine tabs: nine tabs, D dormant
        guard aTabs == 8 else { return finish(false, "A has \(aTabs) engine tabs, want 8") }
        guard let b = await openWindow("b.html"), let c = await openWindow("link.html") else { return finish(false, "windows B and C did not open") }
        c.renameTab(c.list.items[0].id, to: "m-c0")
        let c0 = c.list.items[0].id
        guard let _ = c.window.addTab(withURL: fixture("b.html"), activate: false), await until(15, { c.list.items.count == 2 && c.window.tabs.count == 2 }) else { return finish(false, "C has no second tab") }
        let cp = c.list.items.first { $0.id != c0 }!.id  // the new tab (the list is newest first)
        c.togglePin(of: cp)
        guard await until(5, { self.entry(c, cp)?.isPinned == true }), let cpTab = entry(c, cp).flatMap({ c.engineTab($0) }) else { return finish(false, "no pin in C") }
        c.closeTab(cpTab)
        guard await until(10, { self.entry(c, cp)?.engineID == nil && c.window.tabs.count == 1 }) else { return finish(false, "C's pin did not go dormant") }
        guard let work = try? writer.store.createProfile(name: "Work", colorIndex: 1), let profiles = try? writer.store.profiles(), profiles.count == 2 else { return finish(false, "no second profile") }
        let own = profiles.first { $0.isDefault }!.name
        _ = work

        // Tabs > Move to Window on the active loaded tab L: the rows, then the pick.
        line("info", "step: Tabs > Move to Window on L")
        becomeKey(a)
        guard await select(a, l), app.active === a else { return finish(false, "L is not the active tab of the active window") }
        guard let mw = menuItem("Move to Window"), let sub = mw.submenu else { return finish(false, "no Tabs > Move to Window") }
        mw.menu?.update()
        guard mw.isEnabled else { return finish(false, "Move to Window is disabled with an active tab") }
        app.moveToWindowDelegate.menuNeedsUpdate(sub)
        let want = "m-loaded | B Page | m-c0 | --- | New Window"
        guard rows(sub) == want, sub.items[0].state == .on, !sub.items[0].isEnabled, sub.items[1].isEnabled, sub.items[2].isEnabled, sub.items[1].state == .off else {
            return finish(false, "Tabs > Move to Window lists \(rows(sub)) (first on and off: \(sub.items[0].state == .on), \(sub.items[0].isEnabled)), want \(want) with the others on")
        }
        guard let newWindow = sub.items.last?.submenu, titles(newWindow) == profiles.map(\.name), enabledTitles(newWindow) == [own] else {
            return finish(false, "New Window lists \(String(describing: sub.items.last?.submenu.map(titles))) with \(String(describing: sub.items.last?.submenu.map(enabledTitles))), want \(profiles.map(\.name)) with only \(own) live")
        }
        app.frontLog = []
        sub.performActionForItem(at: 1)  // B: front to back, A first, then the others in creation order
        guard await arrived(l, in: b, loaded: true, active: true, state: "L") else { return }
        guard entry(b, l)?.customTitle == "m-loaded", entry(b, l)?.url.hasSuffix("b.html") == true else { return finish(false, "L in B is \(String(describing: entry(b, l)))") }
        guard await until(10, { win.tabs.count == aTabs - 1 }), entry(a, l) == nil else { return finish(false, "A still holds L or its engine tab (\(win.tabs.count) engine tabs)") }
        guard app.frontLog.last == b.id else { return finish(false, "B is not brought to the front (\(app.frontLog))") }
        guard a.list.activeID == x, await until(10, { a.window.activeTab === a.engineTab(self.entry(a, x)!) }) else { return finish(false, "after L left, A's active tab is \(String(describing: a.list.activeID)), want X (the next row with an engine tab)") }

        // The tile (a pinned tab in the grid), the dormant tab, the tab inside a group.
        line("info", "step: the tile, the dormant tab and the tab in a group")
        let pinnedURL = entry(a, p)?.pinnedURL
        a.move(.tab(p), to: b)
        guard await arrived(p, in: b, loaded: true, active: true, state: "P"), entry(b, p)?.isPinned == true, entry(b, p)?.inGrid == true, entry(b, p)?.pinnedURL == pinnedURL, b.list.items.first?.id == p else {
            return finish(false, "the tile in B is \(String(describing: entry(b, p))), want pinned in the grid (first) with its pinned page \(String(describing: pinnedURL))")
        }
        let bTabs = b.window.tabs.count
        // The save order (M98 item 6): the store is read after each of the move's two saves; the tab is in a window both times.
        writer.saveNow([a.id, b.id])
        guard storedWindows().first(where: { $0.id == a.id })?.tabs.contains(where: { $0.id == d }) == true else { return finish(false, "the store does not hold D in A before the move") }
        let saves = Saves()
        writer.savedHook = { id in saves.list.append((id, self.storedWindows().first { $0.tabs.contains { $0.id == d } }?.id)) }
        a.move(.tab(d), to: b)
        writer.savedHook = nil
        guard saves.list.map(\.0) == [b.id, a.id], saves.list.map(\.1) == [b.id, b.id] else {
            return finish(false, "the move saved \(saves.list.map { $0.0 == a.id ? "A" : $0.0 == b.id ? "B" : "?" }) and the store held D in \(saves.list.map { $0.1 == a.id ? "A" : $0.1 == b.id ? "B" : "no window" }) after each save, want B then A with D in B both times (never in no window)")
        }
        guard await until(10, { self.entry(b, d) != nil && self.entry(a, d) == nil }), entry(b, d)?.engineID == nil, entry(b, d)?.customTitle == "m-dormant", entry(b, d)?.isPinned == false, b.list.dayOrder.last == .tab(d) else {
            return finish(false, "the dormant tab in B is \(String(describing: entry(b, d))), want a dormant day tab at the end")
        }
        try? await Task.sleep(for: .milliseconds(1000))
        guard b.window.tabs.count == bTabs, b.pendingByTab.isEmpty, entry(b, d)?.engineID == nil, b.list.activeID == p else { return finish(false, "the dormant tab loaded (B has \(b.window.tabs.count) engine tabs, was \(bTabs); active \(String(describing: b.list.activeID)))") }
        guard entry(a, x)?.groupID == gx else { return finish(false, "X is not in its group before the move") }
        a.move(.tab(x), to: b)
        guard await arrived(x, in: b, loaded: true, active: true, state: "X"), entry(b, x)?.groupID == nil, b.list.dayOrder.last == .tab(x), entry(a, y)?.groupID == gx, a.group(withID: gx) != nil else {
            return finish(false, "X in B is \(String(describing: entry(b, x))), want a loose day tab at the end; the peer is in \(String(describing: entry(a, y)?.groupID)) of A")
        }

        // The group menu: Move to Window lists A, B, C, then New Window; the pick takes the group and its tabs.
        line("info", "step: the group menu's Move to Window")
        becomeKey(a)
        let gm = ContextMenus.menu(a.groupMenuEntries(for: gh))
        guard let gmw = item(gm, "Move to Window"), gmw.isEnabled, let gsub = gmw.submenu else { return finish(false, "the group menu has no enabled Move to Window") }
        let gwant = "\(a.windowMenuTitle) | \(b.windowMenuTitle) | \(c.windowMenuTitle) | --- | New Window"
        guard rows(gsub) == gwant, gsub.items[0].state == .on, !gsub.items[0].isEnabled, enabledTitles(gsub).count == 3 else { return finish(false, "the group menu's Move to Window lists \(rows(gsub)), want \(gwant) with this window on and off") }
        let hTabs = b.window.tabs.count
        guard gsub.items[1].isEnabled else { return finish(false, "no row for B") }
        gsub.performActionForItem(at: 1)
        guard await until(15, { b.list.items.contains { $0.id == h1 } && b.list.items.contains { $0.id == h2 } && b.window.tabs.count == hTabs + 2 && self.entry(b, h1)?.engineID != nil && self.entry(b, h2)?.engineID != nil }) else {
            return finish(false, "the group's tabs did not arrive loaded in B (\(b.list.items.count) items, \(b.window.tabs.count) engine tabs, want \(hTabs + 2))")
        }
        guard b.group(withID: gh) == groupH, b.members(of: gh).map(\.id) == [h1, h2], b.list.dayOrder.last == .group(gh), a.group(withID: gh) == nil, a.list.items.allSatisfy({ $0.groupID != gh }) else {
            return finish(false, "the group in B is \(String(describing: b.group(withID: gh))), want \(groupH) with H1 and H2, at the end of the day list; A still has it \(a.group(withID: gh) != nil)")
        }
        guard await until(10, { b.list.activeID == h1 }) else { return finish(false, "B's active tab is \(String(describing: b.list.activeID)), want H1 (the first loaded tab of the group)") }
        guard app.frontLog.last == b.id else { return finish(false, "B was not brought to the front by the group move") }
        a.move(.group(gx), to: b)
        guard await until(15, { self.entry(b, y)?.groupID == gx && b.group(withID: gx)?.name == "m-gx" && self.entry(b, y)?.engineID != nil && a.group(withID: gx) == nil }) else { return finish(false, "Gx did not arrive in B with Y") }
        guard a.list.activeID == n else { return finish(false, "after Gx left, A's active tab is \(String(describing: a.list.activeID)), want N") }

        // A new window: the tab is its first, with its id and title and nothing else (no stray blank tab).
        line("info", "step: New Window")
        let before = app.controllers.count
        a.move(.tab(n), to: nil)
        guard await until(25, { self.app.controllers.count == before + 1 && self.restoredUp(before + 1) }), let e = app.controllers.last, e !== a else { return finish(false, "no new window for N") }
        guard await until(15, { e.list.items.count == 1 && self.entry(e, n)?.engineID != nil && e.window.tabs.count == 1 && self.entry(e, n)?.url.hasSuffix("b.html") == true }), entry(e, n)?.customTitle == "m-new", entry(e, n)?.url.hasSuffix("b.html") == true, entry(a, n) == nil else {
            return finish(false, "the new window holds \(e.list.items.map(\.id.raw.uuidString)) (\(e.window.tabs.count) engine tabs), want only N (\(n.raw.uuidString)) loaded at b.html: \(String(describing: e.list.items.first))")
        }
        guard a.list.activeID == a0, await until(10, { a.window.tabs.count == 1 && a.list.items.count == 1 }) else { return finish(false, "after N left, A holds \(a.list.items.count) items, active \(String(describing: a.list.activeID)), want only A0") }

        // C holds a loaded tab and a dormant pin: the tab leaves and the window keeps its pin with a blank day tab (T3.1, the rule for a pins-only window).
        line("info", "step: a window left with a dormant pin")
        c.move(.tab(c0), to: b)
        guard await arrived(c0, in: b, loaded: true, active: true, state: "C0") else { return }
        guard await until(15, { c.list.items.count == 2 && c.window.tabs.count == 1 && c.list.activeID.flatMap { self.entry(c, $0) }?.url == "about:blank" }), app.controllers.contains(where: { $0 === c }), entry(c, cp)?.engineID == nil else {
            return finish(false, "C after its tab left: \(c.list.items.count) items, \(c.window.tabs.count) engine tabs, open \(app.controllers.contains { $0 === c }); want its dormant pin and a blank day tab")
        }
        // A's last tab: A closes.
        line("info", "step: the last tab of a window")
        let openBefore = app.controllers.count
        a.move(.tab(a0), to: b)
        guard await arrived(a0, in: b, loaded: true, active: true, state: "A0") else { return }
        guard await until(15, { self.app.controllers.count == openBefore - 1 && !self.app.controllers.contains { $0 === a } }) else { return finish(false, "A did not close with its last tab (\(app.controllers.count) windows)") }

        // Nothing moved is a closed tab.
        line("info", "step: Reopen Closed Tab and the store")
        guard writer.hasClosed == false, writer.peekClosed() == nil else { return finish(false, "the closed list holds \(String(describing: writer.peekClosed()?.tab.customTitle))") }
        let counts = app.controllers.map { $0.list.items.count }
        app.reopenClosedTab(nil)
        try? await Task.sleep(for: .milliseconds(1500))
        guard app.controllers.map({ $0.list.items.count }) == counts else { return finish(false, "Reopen Closed Tab changed the windows: \(counts) to \(app.controllers.map { $0.list.items.count })") }
        // The store after the debounce (no flush): every item in the window that holds it, once.
        let ids = [l, p, d, x, y, h1, h2, a0, c0]
        guard await until(8, { self.storeHolds(ids, in: b.id, groups: [gh, gx], elsewhere: [n: e.id, cp: c.id]) }) else {
            let s = storedWindows()
            return finish(false, "the store after the debounce: \(s.map { "\($0.id == b.id ? "B" : $0.id == c.id ? "C" : $0.id == e.id ? "E" : "?"):\($0.tabs.compactMap(\.customTitle).sorted()) groups \($0.groups.map(\.name))" })")
        }
        guard await discardedMoves(b) else { return }
        guard await groupToNewWindow() else { return }
        guard await heldSourceSteps() else { return }
        finish(violations.isEmpty, "Tabs > Move to Window and the group menu list this window (checked, off), the others by title and New Window per profile (only the own one live); a loaded tab, a tile, a dormant tab (loads nothing), a tab out of a group (loose), a group with its tabs and a tab to a new window arrive with their ids, titles and state, B in front; a window left with a pin gets a blank tab, A's last tab closes it; nothing is a closed tab; the store holds each item once after the debounce; a discarded tab moves dormant, a group goes to a new window, and a window that gave to new windows is never saved or dropped before each of them has saved (another tab closing, its own close, two moves), also when the engine closes a restoring new window and it is revived \(violations)")
    }

    final class Saves { var list: [(UUID, UUID?)] = [] }

    /// A window of |n| loaded tabs titled "<tag><i>" (its first active), the store knowing it.
    func source(_ tag: String, _ n: Int) async -> (BrowserWindowController, [TabID])? {
        guard let w = await openWindow("b.html") else { return nil }
        for _ in 1..<n { guard let _ = w.window.addTab(withURL: fixture("b.html"), activate: false) else { return nil } }
        guard await until(20, { w.list.items.count == n && w.window.tabs.count == n && w.list.items.allSatisfy { !$0.title.isEmpty } }) else { return nil }
        let ids = Array(w.list.items.map(\.id).reversed())  // opening order: t[0] is the window's first (active) tab; the list is newest first
        for (i, id) in ids.enumerated() { w.renameTab(id, to: "\(tag)\(i)") }
        return (w, ids)
    }

    func pairGroup(_ w: BrowserWindowController, _ a: TabID, _ b: TabID, _ name: String) -> GroupID? {
        guard let g = w.list.createGroup(with: a, name: name) else { return nil }
        w.list.setGroup(b, g); w.refresh(); w.changed()
        return g
    }

    func liveInStore(_ ids: [TabID]) -> Bool {
        let all = Set(storedWindows().flatMap { $0.tabs.map(\.id) })
        return ids.allSatisfy { all.contains($0) }
    }

    func closeWindows(_ ws: [BrowserWindowController]) async {
        for w in ws where app.controllers.contains(where: { $0 === w }) { w.close() }
        _ = await until(15, { ws.allSatisfy { w in !self.app.controllers.contains { $0 === w } } })
    }

    /// Task 5b fix 1 (I1): a discarded tab, loose or inside a group, moves as a dormant item and loads nothing; its engine tab still closes in the source.
    func discardedMoves(_ b: BrowserWindowController) async -> Bool {
        line("info", "step: discarded tabs")
        guard let (s, t) = await source("d-", 4), let g = pairGroup(s, t[2], t[3], "d-group") else { finish(false, "no source for the discarded tabs"); return false }
        guard await discardNow(s, t[1]), await discardNow(s, t[3]) else { finish(false, "the engine did not discard the tabs"); return false }
        let bTabs = b.window.tabs.count
        s.move(.tab(t[1]), to: b)
        guard await until(10, { self.entry(b, t[1]) != nil && self.entry(s, t[1]) == nil }), entry(b, t[1])?.engineID == nil, entry(b, t[1])?.isDiscarded == false, entry(b, t[1])?.customTitle == "d-1" else {
            finish(false, "the discarded tab in B is \(String(describing: entry(b, t[1]))), want a dormant item"); return false
        }
        s.move(.group(g), to: b)
        guard await until(15, { self.entry(b, t[2])?.engineID != nil && self.entry(b, t[3]) != nil && self.entry(s, t[3]) == nil }), entry(b, t[3])?.engineID == nil, b.group(withID: g) != nil else {
            finish(false, "the group with a discarded child in B: loaded child \(String(describing: entry(b, t[2])?.engineID)), discarded child \(String(describing: entry(b, t[3]))); want the first loaded and the discarded one dormant"); return false
        }
        try? await Task.sleep(for: .milliseconds(1000))
        guard b.window.tabs.count == bTabs + 1, b.pendingByTab.isEmpty, entry(b, t[1])?.engineID == nil, entry(b, t[3])?.engineID == nil else {
            finish(false, "a discarded tab loaded in B (\(b.window.tabs.count) engine tabs, want \(bTabs + 1): only the group's loaded child)"); return false
        }
        guard await until(10, { s.window.tabs.count == 1 }) else { finish(false, "the source still has \(s.window.tabs.count) engine tabs, want 1: the engine tabs of the discarded tabs close with the move"); return false }
        await closeWindows([s])
        return true
    }

    /// Task 5b fix 6: a group goes to a new window with its id, name, color, icon and collapsed state; its tabs load there.
    func groupToNewWindow() async -> Bool {
        line("info", "step: a group to a new window")
        guard let (s, t) = await source("g-", 4), let g = pairGroup(s, t[1], t[2], "g-group") else { finish(false, "no source for the group"); return false }
        s.list.setGroupColor(g, 5); s.list.setGroupIcon(g, "star"); s.list.collapse(g); s.refresh(); s.changed()
        let copy = s.group(withID: g)!
        let before = app.controllers.count
        s.move(.group(g), to: nil)
        guard await until(25, { self.app.controllers.count == before + 1 && self.restoredUp(before + 1) }), let e = app.controllers.last, e !== s else { finish(false, "no new window for the group"); return false }
        guard await until(15, { e.list.items.count == 2 && e.window.tabs.count == 2 && e.list.items.allSatisfy { $0.engineID != nil } }), e.group(withID: g) == copy, e.members(of: g).map(\.id) == [t[1], t[2]], entry(s, t[1]) == nil, s.group(withID: g) == nil else {
            finish(false, "the new window holds \(e.list.items.count) items, group \(String(describing: e.group(withID: g))), want \(copy) with both tabs loaded and nothing left in the source"); return false
        }
        guard await until(8, { self.storeHolds([t[1], t[2]], in: e.id, groups: [g], elsewhere: [t[0]: s.id]) }) else { finish(false, "the store after the group moved to a new window: \(storedWindows().map { "\($0.tabs.compactMap(\.customTitle).sorted())" })"); return false }
        await closeWindows([s, e])
        return true
    }

    /// Task 5b fix 2 (I2, M98 item 6): a window that gave items to a new window is not saved or dropped before that window has saved. Each new window's
    /// restore is held open (its last tab never arrives, the fallback ends it after 5 s) so the store can be read while the source waits.
    func heldSourceSteps() async -> Bool {
        guard let writer = app.writer else { return false }
        BrowserWindowController.holdLastRestoreTab = true
        BrowserWindowController.restoreFallback = 5
        defer { BrowserWindowController.holdLastRestoreTab = false; BrowserWindowController.restoreFallback = 15 }

        // 1. Another tab closes in the held source, and the debounce passes: the group's tabs stay in the store.
        line("info", "step: a held source, another tab closes")
        guard let (s, t) = await source("h1-", 4), let g = pairGroup(s, t[1], t[2], "h1-group") else { finish(false, "no held source"); return false }
        writer.saveNow([s.id])
        guard liveInStore(t) else { finish(false, "the store does not know the source's tabs"); return false }
        var n0 = app.controllers.count
        s.move(.group(g), to: nil)
        guard app.controllers.count == n0 + 1, let e = app.controllers.last, e.restoring, let closing = entry(s, t[3]).flatMap({ s.engineTab($0) }) else { finish(false, "no restoring new window for the group"); return false }
        guard writer.holds[s.id] == [e.id] else { finish(false, "the source is not held for its new window (holds \(String(describing: writer.holds[s.id])))"); return false }
        s.closeTab(closing)
        guard await until(5, { writer.peekClosed()?.tab.id == t[3] }) else { finish(false, "the closed tab was not recorded"); return false }
        guard e.restoring, liveInStore([t[1], t[2]]) else { finish(false, "after another tab closed in the source, the store holds the group's tabs in no window (new window restoring \(e.restoring))"); return false }
        try? await Task.sleep(for: .milliseconds(2600))   // past the debounce's 2 s cap
        guard e.restoring, liveInStore([t[1], t[2]]) else { finish(false, "after the debounce the store holds the group's tabs in no window (new window restoring \(e.restoring))"); return false }
        guard await until(10, { !e.restoring }), await until(8, { self.storeHolds([t[1], t[2]], in: e.id, groups: [g], elsewhere: [t[0]: s.id]) }), !liveInStore([t[3]]), writer.peekClosed()?.tab.id == t[3] else {
            finish(false, "after the new window saved: \(storedWindows().map { "\($0.tabs.compactMap(\.customTitle).sorted())" }), closed list \(String(describing: writer.peekClosed()?.tab.customTitle)); want the group in the new window, the source's rest in the source, h1-3 closed"); return false
        }
        writer.reopened(t[3])
        await closeWindows([s, e])

        // 2. The held source is closed by the user.
        line("info", "step: a held source is closed")
        guard let (s2, u) = await source("h2-", 3), let g2 = pairGroup(s2, u[1], u[2], "h2-group") else { finish(false, "no second held source"); return false }
        writer.saveNow([s2.id])
        n0 = app.controllers.count
        s2.move(.group(g2), to: nil)
        guard app.controllers.count == n0 + 1, let e2 = app.controllers.last, e2.restoring else { finish(false, "no restoring new window for the second group"); return false }
        s2.close()
        guard await until(10, { !self.app.controllers.contains { $0 === s2 } }) else { finish(false, "the held source did not close"); return false }
        guard e2.restoring, liveInStore([u[1], u[2]]) else { finish(false, "closing the held source dropped the group's tabs from the store before the new window saved (restoring \(e2.restoring))"); return false }
        guard await until(10, { !e2.restoring }), await until(8, { self.storeHolds([u[1], u[2]], in: e2.id, groups: [g2], elsewhere: [:]) && !self.storedWindows().contains { $0.id == s2.id } }) else {
            finish(false, "after the new window saved: \(storedWindows().map { "\($0.id == e2.id ? "E" : "?"):\($0.tabs.compactMap(\.customTitle).sorted())" }), the closed source still stored \(storedWindows().contains { $0.id == s2.id })"); return false
        }
        await closeWindows([e2])

        // 3. Two moves out of one source: the first new window's save does not free it.
        line("info", "step: two moves out of a held source")
        guard let (s3, v) = await source("h3-", 5), let ga = pairGroup(s3, v[1], v[2], "h3-a"), let gb = pairGroup(s3, v[3], v[4], "h3-b") else { finish(false, "no third held source"); return false }
        writer.saveNow([s3.id])
        n0 = app.controllers.count
        s3.move(.group(ga), to: nil)
        s3.move(.group(gb), to: nil)
        guard app.controllers.count == n0 + 2, let first = app.controllers.dropLast().last, let second = app.controllers.last, first.restoring, second.restoring else { finish(false, "no two restoring new windows"); return false }
        let marks = Marks()
        writer.savedHook = { id in marks.list.append((id, self.liveInStore([v[1], v[2], v[3], v[4]]))) }   // read the store after each save
        let gate = Gate(), original = second.afterRestore
        second.afterRestore = { Task { @MainActor in while !gate.open { try? await Task.sleep(for: .milliseconds(50)) }; original?() } }
        guard await until(15, { self.storeHolds([v[1], v[2]], in: first.id, groups: [ga], elsewhere: [:]) }) else { finish(false, "the first new window never saved"); return false }
        gate.open = true
        guard await until(15, { self.storeHolds([v[1], v[2]], in: first.id, groups: [ga], elsewhere: [v[0]: s3.id]) && self.storeHolds([v[3], v[4]], in: second.id, groups: [gb], elsewhere: [v[0]: s3.id]) }) else {
            finish(false, "after both saved: \(storedWindows().map { "\($0.id == s3.id ? "S" : $0.id == first.id ? "E1" : $0.id == second.id ? "E2" : "?"):\($0.tabs.compactMap(\.customTitle).sorted())" })"); return false
        }
        writer.savedHook = nil
        guard marks.list.map(\.0) == [first.id, second.id, s3.id], marks.list.allSatisfy(\.1) else {
            finish(false, "the saves were \(marks.list.map { $0.0 == s3.id ? "S" : $0.0 == first.id ? "E1" : $0.0 == second.id ? "E2" : "?" }) with the moved tabs in the store after each: \(marks.list.map(\.1)); want E1, E2, S and true each (the source waits for both)"); return false
        }
        await closeWindows([s3, first, second])

        // 4. A held window is not a destination or a merge target (ruling M102) until its new window has saved.
        line("info", "step: a held window as destination and as merge target")
        guard let (a, r) = await source("r-a", 4), let ga2 = pairGroup(a, r[1], r[2], "r-group"), let (c, q) = await source("r-c", 2) else { finish(false, "no windows for the held destination"); return false }
        writer.saveNow([a.id, c.id])
        n0 = app.controllers.count
        a.move(.group(ga2), to: nil)
        guard app.controllers.count == n0 + 1, let e4 = app.controllers.last, e4.restoring, a.isHeld else { finish(false, "the window is not held for its new window"); return false }
        // (a) its row in another window's Move to Window submenu is disabled, and a forced move changes nothing.
        let rowA = c.moveToWindowEntries(.tab(q[1])).first { $0.title == a.windowMenuTitle && $0.checked != true }
        guard let rowA, !rowA.enabled else { finish(false, "the held window's row in the Move to Window submenu is \(String(describing: c.moveToWindowEntries(.tab(q[1])).map { "\($0.title):\($0.enabled)" })), want it disabled"); return false }
        c.move(.tab(q[1]), to: a)
        try? await Task.sleep(for: .milliseconds(500))
        guard e4.restoring, c.list.items.contains(where: { $0.id == q[1] }), !a.list.items.contains(where: { $0.id == q[1] }), liveInStore([q[1]]) else {
            finish(false, "a move into the held window changed things: the tab is in C \(c.list.items.contains { $0.id == q[1] }), in A \(a.list.items.contains { $0.id == q[1] }), in the store \(liveInStore([q[1]])) (the store holds it in no window)"); return false
        }
        // (b) Merge All Windows is disabled with the held window in front, and a forced merge changes nothing.
        becomeKey(a)
        guard let merge = menuItem("Merge All Windows") else { finish(false, "no Merge All Windows"); return false }
        merge.menu?.update()
        let shape = app.controllers.map { $0.list.items.count }
        guard app.active === a, !merge.isEnabled else { finish(false, "Merge All Windows is enabled with the held window in front (enabled \(merge.isEnabled))"); return false }
        app.mergeAllWindows()
        try? await Task.sleep(for: .milliseconds(500))
        guard e4.restoring, app.controllers.map({ $0.list.items.count }) == shape, liveInStore([q[0], q[1]]) else {
            finish(false, "a forced merge into the held window changed the windows from \(shape) to \(app.controllers.map { $0.list.items.count }) (store holds C's tabs: \(liveInStore([q[0], q[1]])))"); return false
        }
        // (c) once the new window has saved, both work again.
        guard await until(15, { !e4.restoring && !a.isHeld }) else { finish(false, "the window stayed held"); return false }
        merge.menu?.update()
        guard merge.isEnabled, c.moveToWindowEntries(.tab(q[1])).first(where: { $0.title == a.windowMenuTitle && $0.checked != true })?.enabled == true else { finish(false, "after the release the held window's row or Merge All Windows is still disabled"); return false }
        c.move(.tab(q[1]), to: a)
        guard await arrived(q[1], in: a, loaded: true, active: true, state: "the tab moved into the released window") else { return false }
        await closeWindows([a, c, e4])

        // 5. The engine closes the new window while it restores and it keeps a pinned tab: the window is revived under its id and its first save frees the source (ruling M103).
        line("info", "step: the new window is closed by the engine while it restores")
        BrowserWindowController.restoreFallback = 15   // the old window's own fallback (a later turn of its restore) must not end the wait in place of the revived window
        guard let (s5, w) = await source("h5-", 4), let g5 = pairGroup(s5, w[1], w[2], "h5-group") else { finish(false, "no fifth held source"); return false }
        writer.saveNow([s5.id])
        n0 = app.controllers.count
        s5.move(.group(g5), to: nil)
        guard app.controllers.count == n0 + 1, let e5 = app.controllers.last, e5.restoring, writer.holds[s5.id] == [e5.id] else { finish(false, "no restoring new window the source waits for"); return false }
        guard await until(15, { e5.list.items.count == 1 && e5.window.tabs.count == 1 }), let first = e5.list.items.first, let engine = e5.engineTab(first) else { finish(false, "the new window's first tab never arrived"); return false }
        e5.togglePin(of: first.id)
        guard await until(5, { e5.list.items.first?.isPinned == true }), e5.restoring else { finish(false, "the first tab did not pin while the window restored (restoring \(e5.restoring))"); return false }
        s5.renameTab(w[0], to: "h5-after-move"); s5.changed()   // a change in the held source after the move
        engine.close()   // the engine's own close, as reviveWindow does
        guard await until(20, { guard let n = self.app.controllers.first(where: { $0.id == e5.id }), n !== e5 else { return false }; return !n.restoring }), let n5 = app.controllers.first(where: { $0.id == e5.id }) else {
            finish(false, "the new window was not revived and finished restoring (the source is held for \(String(describing: writer.holds[s5.id])))"); return false
        }
        guard await until(4, { writer.holds[s5.id] == nil }) else { finish(false, "the revived window's first save did not free the source: holds \(String(describing: writer.holds[s5.id])) (revived restoring \(n5.restoring))"); return false }
        guard await until(8, { self.storedWindows().first { $0.id == s5.id }?.tabs.first { $0.id == w[0] }?.customTitle == "h5-after-move" }) else {
            finish(false, "the source's change after the move is not in the store: \(storedWindows().first { $0.id == s5.id }?.tabs.compactMap(\.customTitle) ?? [])"); return false
        }
        await closeWindows([s5, n5])
        return true
    }

    final class Gate { var open = false }
    final class Marks { var list: [(UUID, Bool)] = [] }

    /// An item moved to |b|: in B's list, not in any other window's, its engine tab there when |loaded| (same id), active when |active|.
    func arrived(_ id: TabID, in b: BrowserWindowController, loaded: Bool, active: Bool, state: String) async -> Bool {
        let ok = await until(15, { b.list.items.contains { $0.id == id } && (!loaded || self.entry(b, id)?.engineID != nil) && (!active || b.list.activeID == id) && self.app.controllers.filter { $0.list.items.contains { $0.id == id } }.count == 1 })
        if !ok {
            finish(false, "\(state) did not arrive in B as the same tab: in B \(b.list.items.contains { $0.id == id }), engine tab \(String(describing: entry(b, id)?.engineID)), active \(b.list.activeID == id), held by \(app.controllers.filter { $0.list.items.contains { $0.id == id } }.count) windows")
            return false
        }
        if active, !(await until(10, { b.window.activeTab === b.engineTab(self.entry(b, id)!) })) { finish(false, "B's engine does not show \(state)"); return false }
        return true
    }

    /// The saved windows hold |ids| and |groups| in |window| and nowhere else; the |elsewhere| tabs in their own windows.
    func storeHolds(_ ids: [TabID], in window: UUID, groups: [GroupID], elsewhere: [TabID: UUID]) -> Bool {
        let s = storedWindows()
        guard let w = s.first(where: { $0.id == window }), Set(ids).isSubset(of: Set(w.tabs.map(\.id))), Set(groups).isSubset(of: Set(w.groups.map(\.id))) else { return false }
        for other in s where other.id != window { if !Set(other.tabs.map(\.id)).isDisjoint(with: Set(ids)) || !Set(other.groups.map(\.id)).isDisjoint(with: Set(groups)) { return false } }
        for (tab, win) in elsewhere { guard s.first(where: { $0.id == win })?.tabs.contains(where: { $0.id == tab }) == true else { return false } }
        let all = s.flatMap { $0.tabs.map(\.id) }
        return all.count == Set(all).count && s.flatMap({ $0.groups.map(\.id) }).count == Set(s.flatMap { $0.groups.map(\.id) }).count
    }

    func moveWindowRelaunch() async {
        guard await until(40, { self.restoredUp(3) }) else { return finish(false, "phase 2: \(app.controllers.count) windows, want 3 (B, C and the new one)") }
        let names = ["m-a0", "m-loaded", "m-tile", "m-dormant", "m-in", "m-peer", "m-h1", "m-h2", "m-new", "m-c0"]
        guard await until(30, { names.allSatisfy { self.marked($0).count == 1 } }) else {
            return finish(false, "phase 2: items held \(names.map { "\($0)x\(marked($0).count)" })")
        }
        guard let b = marked("m-loaded").first?.c, let e = marked("m-new").first?.c, b !== e else { return finish(false, "phase 2: no B or E") }
        let inB = ["m-a0", "m-loaded", "m-tile", "m-dormant", "m-in", "m-peer", "m-h1", "m-h2", "m-c0"]
        guard inB.allSatisfy({ self.marked($0).first?.c === b }) else { return finish(false, "phase 2: not all of \(inB) are in B: \(inB.map { "\($0) in \(self.marked($0).first?.c === b ? "B" : "elsewhere")" })") }
        guard let gh = b.list.groups.first(where: { $0.name == "m-group" }), gh.colorIndex == 5, gh.icon == "star", gh.isCollapsed, b.members(of: gh.id).compactMap(\.customTitle) == ["m-h1", "m-h2"] else {
            return finish(false, "phase 2: the group in B is \(String(describing: b.list.groups.first { $0.name == "m-group" })), want pink, star, closed with H1 and H2")
        }
        guard let gx = b.list.groups.first(where: { $0.name == "m-gx" }), b.members(of: gx.id).compactMap(\.customTitle) == ["m-peer"], marked("m-in").first?.item.groupID == nil, marked("m-tile").first?.item.isPinned == true, marked("m-tile").first?.item.inGrid == true else {
            return finish(false, "phase 2: Gx, the loose X or the tile in B are wrong")
        }
        guard app.controllers.flatMap({ $0.list.groups.map(\.id) }).count == Set(app.controllers.flatMap { $0.list.groups.map(\.id) }).count else { return finish(false, "phase 2: a group id repeats across windows") }
        finish(violations.isEmpty, "phase 2: after the relaunch the moved tabs, the group (pink, star, closed, H1 and H2), Gx with its peer and the tile are in B once, the tab moved to a new window is in its own window, and no group id repeats \(violations)")
    }

    // MARK: merge-windows

    /// Ruling M97 item 5. Three windows, each with a tile, a group and loose tabs (the middle one's pin is dormant and its active tab is in its group); Window >
    /// Merge All Windows from the middle one: it holds the others' items in the stated order with the same ids, only its active tab has an engine tab,
    /// the others closed, the store and the relaunch show one window. A window of another profile stays (the rule is one profile for now: README).
    func mergeWindows() async {
        if phase == 2 { return await mergeWindowsRelaunch() }
        guard await ready(), let w1 = ctl, let writer = app.writer else { return }
        // W1: day tab, tile, loose pinned row, group of two.
        guard await openTabs(5, page: "b.html"), await until(20, { w1.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "W1's tabs never appeared") }
        let u = w1.list.items.map(\.id)
        for (id, name) in [(u[0], "w1-day"), (u[1], "w1-tile"), (u[2], "w1-row"), (u[3], "w1-ka"), (u[4], "w1-kb")] { w1.renameTab(id, to: name) }
        w1.togglePin(of: u[1])
        w1.togglePin(of: u[2])
        guard await until(5, { self.entry(w1, u[1])?.inGrid == true && self.entry(w1, u[2])?.isPinned == true }) else { return finish(false, "W1's pins") }
        w1.list.move(u[2], to: .persistent(Int.max))
        guard let g1 = w1.list.createGroup(with: u[3], name: "w1-group") else { return finish(false, "no group in W1") }
        w1.list.setGroup(u[4], g1); w1.list.setGroupColor(g1, 3); w1.list.setGroupIcon(g1, "bolt")
        w1.refresh()
        guard let w2 = await openWindow("b.html") else { return finish(false, "W2 did not open") }
        // W2 (the target): a dormant tile and a group holding its active tab.
        guard let _ = w2.window.addTab(withURL: fixture("b.html"), activate: false), await until(15, { w2.list.items.count == 2 && w2.window.tabs.count == 2 && w2.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "W2's tabs never appeared") }
        let v = w2.list.items.map(\.id)
        w2.renameTab(v[0], to: "w2-active"); w2.renameTab(v[1], to: "w2-tile")
        w2.togglePin(of: v[1])
        guard await until(5, { self.entry(w2, v[1])?.inGrid == true }), let tileTab = entry(w2, v[1]).flatMap({ w2.engineTab($0) }) else { return finish(false, "W2's tile") }
        w2.closeTab(tileTab)
        guard await until(10, { self.entry(w2, v[1])?.engineID == nil && w2.window.tabs.count == 1 }), let g2 = w2.list.createGroup(with: v[0], name: "w2-group") else { return finish(false, "W2's dormant tile or group") }
        // A loaded tab that is not active: the merge leaves it as it is (ruling M100), loaded.
        guard let _ = w2.window.addTab(withURL: fixture("link.html"), activate: false), await until(15, { w2.list.items.count == 3 && w2.window.tabs.count == 2 && w2.list.items.allSatisfy { !$0.title.isEmpty } }), let extra = w2.list.items.map(\.id).first(where: { !v.contains($0) }) else { return finish(false, "W2's loaded extra tab never appeared") }
        w2.renameTab(extra, to: "w2-extra")
        w2.refresh()
        guard let w3 = await openWindow("link.html") else { return finish(false, "W3 did not open") }
        guard let _ = w3.window.addTab(withURL: fixture("b.html"), activate: false), let _ = w3.window.addTab(withURL: fixture("b.html"), activate: false), let _ = w3.window.addTab(withURL: fixture("b.html"), activate: false),
              await until(20, { w3.list.items.count == 4 && w3.window.tabs.count == 4 && w3.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "W3's tabs never appeared") }
        let x = w3.list.items.map(\.id)
        for (id, name) in [(x[0], "w3-day"), (x[1], "w3-tile"), (x[2], "w3-ka"), (x[3], "w3-kb")] { w3.renameTab(id, to: name) }
        w3.togglePin(of: x[1])
        guard await until(5, { self.entry(w3, x[1])?.inGrid == true }), let g3 = w3.list.createGroup(with: x[2], name: "w3-group") else { return finish(false, "W3's pin or group") }
        w3.list.setGroup(x[3], g3)
        w3.refresh()
        // The sources as the test knows them, before the merge.
        guard w1.list.dayOrder == [.tab(u[0]), .group(g1)], w1.list.topOrder == [.tab(u[2])], w3.list.dayOrder == [.tab(x[0]), .group(g3)], w2.list.dayOrder == [.tab(extra), .group(g2)], w2.list.activeID == v[0] else {
            return finish(false, "the windows before the merge: \(w1.list.dayOrder) \(w1.list.topOrder) \(w2.list.dayOrder) \(w3.list.dayOrder)")
        }
        let groupOne = w1.group(withID: g1)!, w2Day = w2.list.dayOrder, w2Own = Set(w2.list.items.map(\.id))
        // The middle window is the front one.
        becomeKey(w3); becomeKey(w1); becomeKey(w2)
        guard app.active === w2, app.windowsFrontToBack.map(\.id) == [w2.id, w1.id, w3.id] else { return finish(false, "the front window is not W2 (\(app.windowsFrontToBack.map(\.id)))") }
        guard let merge = menuItem("Merge All Windows") else { return finish(false, "no Window > Merge All Windows") }
        w1.restoring = true; w3.restoring = true   // two of the three are still restoring: nothing to merge
        merge.menu?.update()
        let offWhileRestoring = !merge.isEnabled && !app.canMerge(w2)
        w1.restoring = false; w3.restoring = false
        guard offWhileRestoring else { return finish(false, "Merge All Windows is enabled while the other windows are restoring (canMerge \(app.canMerge(w2)))") }
        merge.menu?.update()
        guard merge.isEnabled else { return finish(false, "Merge All Windows is disabled with three windows open") }
        app.frontLog = []
        guard fire("Merge All Windows") else { return finish(false, "Merge All Windows did not run") }
        guard await until(25, { self.app.controllers.count == 1 && w2.list.items.count == 12 }), app.controllers[0] === w2 else {
            return finish(false, "after the merge \(app.controllers.count) windows, W2 holds \(w2.list.items.count) items, want 1 and 12")
        }
        // The stated order: tiles and rows into the pinned area, groups and loose tabs to the end of the day list, front to back.
        let grid = w2.list.items.filter { $0.isPinned && $0.inGrid }.map(\.id)
        guard grid == [v[1], u[1], x[1]], w2.list.topOrder == [.tab(u[2])], w2.list.dayOrder == w2Day + [.tab(u[0]), .group(g1), .tab(x[0]), .group(g3)] else {
            return finish(false, "W2's order: grid \(grid.count) (\(grid == [v[1], u[1], x[1]])), top \(w2.list.topOrder), day \(w2.list.dayOrder), want [tile W2, tile W1, tile W3], [W1's row], \(w2Day) then [w1-day, g1, w3-day, g3]")
        }
        guard w2.members(of: g1).map(\.id) == [u[3], u[4]], w2.group(withID: g1) == groupOne, w2.members(of: g3).map(\.id) == [x[2], x[3]], w2.members(of: g2).map(\.id) == [v[0]] else { return finish(false, "the groups in W2 are not whole: \(String(describing: w2.group(withID: g1))), want \(groupOne)") }
        // No merged item has an engine tab; the target's own loaded tabs (its active one and the extra one) keep theirs.
        let live = w2.list.items.filter { $0.engineID != nil }.map(\.id)
        guard Set(live) == [v[0], extra], w2.window.tabs.count == 2, w2.list.activeID == v[0] else { return finish(false, "W2 has \(live.count) tabs with an engine tab (\(w2.window.tabs.count) engine tabs), want its own active and extra tab only") }
        guard w2.list.items.filter({ !w2Own.contains($0.id) }).allSatisfy({ $0.engineID == nil && !$0.isLoading }), w2.pendingByTab.isEmpty else { return finish(false, "a merged tab has an engine tab or is loading") }
        guard app.frontLog.last == w2.id, !app.controllers.contains(where: { $0 === w1 || $0 === w3 }) else { return finish(false, "W2 is not in front or a source window is still open") }
        guard writer.hasClosed == false else { return finish(false, "a merged tab is on the closed list") }
        let ids = w2.list.items.map(\.id)
        guard await until(8, { let s = self.storedWindows(); return s.count == 1 && s[0].id == w2.id && Set(s[0].tabs.map(\.id)) == Set(ids) && Set(s[0].groups.map(\.id)) == [g1, g2, g3] }) else {
            return finish(false, "the store after the merge: \(storedWindows().map { "\($0.tabs.count) tabs, \($0.groups.count) groups" })")
        }
        finish(violations.isEmpty, "Merge All Windows from the middle of three windows: the front window holds the other two's tiles at the end of its grid, the pinned row in its pinned area and their groups and loose tabs at the end of its day list in front to back order, groups whole, ids unchanged, no merged tab has an engine tab (the target\'s loaded tab that is not active stays loaded), the sources closed, the store holds one window with 12 tabs and 3 groups \(violations)")
    }

    func mergeWindowsRelaunch() async {
        guard await until(40, { self.restoredUp(1) }), let w = ctl else { return finish(false, "phase 2: \(app.controllers.count) windows, want 1") }
        let names = ["w2-active", "w2-extra", "w2-tile", "w1-day", "w1-tile", "w1-row", "w1-ka", "w1-kb", "w3-day", "w3-tile", "w3-ka", "w3-kb"]
        guard await until(30, { w.list.items.count == 12 }), names.allSatisfy({ self.marked($0).count == 1 }) else { return finish(false, "phase 2: \(w.list.items.count) items, held \(names.map { "\($0)x\(marked($0).count)" })") }
        let grid = w.list.items.filter { $0.isPinned && $0.inGrid }.compactMap(\.customTitle)
        guard grid == ["w2-tile", "w1-tile", "w3-tile"], w.list.items.filter({ $0.isPinned && !$0.inGrid }).compactMap(\.customTitle) == ["w1-row"] else { return finish(false, "phase 2: the pinned area is \(grid)") }
        let groups = w.list.groups.map { g in "\(g.name):\(w.members(of: g.id).compactMap(\.customTitle).joined(separator: ","))" }
        guard groups == ["w1-group:w1-ka,w1-kb", "w2-group:w2-active", "w3-group:w3-ka,w3-kb"] || Set(groups) == ["w1-group:w1-ka,w1-kb", "w2-group:w2-active", "w3-group:w3-ka,w3-kb"] else { return finish(false, "phase 2: groups \(groups)") }
        guard let g1 = w.list.groups.first(where: { $0.name == "w1-group" }), g1.colorIndex == 3, g1.icon == "bolt" else { return finish(false, "phase 2: w1-group lost its color or icon") }
        let day = w.list.dayOrder.map { r -> String in switch r { case .tab(let id): w.item(withID: id)?.customTitle ?? "?"; case .group(let g): w.group(withID: g)?.name ?? "?" } }
        guard day == ["w2-extra", "w2-group", "w1-day", "w1-group", "w3-day", "w3-group"] else { return finish(false, "phase 2: the day list is \(day)") }
        finish(violations.isEmpty, "phase 2: after the relaunch one window holds the 12 merged tabs: tiles w2, w1, w3, the pinned row, and the day list w2-extra, w2-group, w1-day, w1-group, w3-day, w3-group with their groups \(violations)")
    }

    // MARK: revive-window (T5b.3)

    /// A window the engine closes by itself while a pin waits in it is made again (AppDelegate.revive): zoomed stays zoomed and a window that was in full screen
    /// is asked to be. A hidden run cannot enter full screen, so a hook reports the old window as full screen and the check reads the `Restore` the new window
    /// is made with; the zoom is real, read from the new window.
    func near(_ a: NSRect, _ b: NSRect) -> Bool { abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2 }

    func reviveWindow() async {
        guard await ready(), let c = ctl, let win, let tab = win.activeTab, let ns = c.nsWindow else { return }
        pinKey()
        guard await until(5, { c.list.items.first?.isPinned == true }) else { return finish(false, "the tab did not pin") }
        let before = ns.frame
        ns.zoom(nil)
        guard await until(10, { ns.isZoomed && c.lastZoomed }) else { return finish(false, "the window did not zoom (isZoomed \(ns.isZoomed), recorded \(c.lastZoomed))") }
        tab.close()   // the engine's own close of the last tab: Noche's close path is not involved
        guard await until(20, { guard let n = self.ctl, n !== c else { return false }; return !n.restoring && n.window.tabs.count == 1 && n.list.items.count == 2 }), let n = ctl else {
            return finish(false, "the window was not revived (\(ctl === c ? "same controller" : "new") with \(ctl?.list.items.count ?? -1) items)")
        }
        guard let r = app.lastRevive, r.isZoomed else { return finish(false, "the revived window's Restore has isZoomed \(String(describing: app.lastRevive?.isZoomed)), want true") }
        // The new window is made at the frame from before the zoom (not the zoomed one) and zooms through the carry: only the carry can make it zoomed.
        guard let nn = n.nsWindow, await until(10, { nn.isZoomed }) else { return finish(false, "the revived window is not zoomed (isZoomed \(n.nsWindow?.isZoomed ?? false))") }
        guard app.lastReviveFrame.map({ near($0, before) }) == true else { return finish(false, "the revived window is made at \(String(describing: app.lastReviveFrame)), want the frame from before the zoom \(before)") }
        nn.zoom(nil)
        guard await until(10, { !nn.isZoomed && near(nn.frame, before) }) else { return finish(false, "un-zooming the revived window left it at \(nn.frame) (zoomed \(nn.isZoomed)), want the frame from before the zoom \(before)") }
        // Full screen: a hook reports the window as in it; the Restore of the next revival carries it.
        n.testFullScreen = true
        guard let tab2 = n.window.activeTab else { return finish(false, "the revived window has no active tab") }
        tab2.close()
        guard await until(20, { guard let m = self.ctl, m !== n else { return false }; return !m.restoring && m.window.tabs.count == 1 && m.list.items.count == 2 }) else { return finish(false, "the window was not revived a second time") }
        guard let r2 = app.lastRevive, r2.fullScreen else { return finish(false, "the revived window's Restore has fullScreen \(String(describing: app.lastRevive?.fullScreen)), want true (the old window was reported in full screen)") }
        finish(violations.isEmpty, "a revived window carries the old window's full screen into its Restore (a hook reports it: a hidden run cannot enter it) and comes back zoomed through the carry from the frame before the zoom (un-zooming it returns there), read from the new window \(violations)")
    }
}
#endif
