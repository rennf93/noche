#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore

/// Tab behavior settings (M1.6 Task 7a): Close All Tabs, the last-tab warning and where a new tab opens. The questions go to `Confirm.asked` (a hidden
/// window is never key, so no dialog shows) and the settings are stored through the store the way `--selftest-setting` does.
extension SelfTest {
    func settle() async { try? await Task.sleep(for: .milliseconds(500)) }

    func setSetting(_ key: String, _ value: String) -> Bool { (try? app.writer?.store.setSetting(key, value)) != nil }

    /// Shift+Cmd+K closes the day tabs only (unpinned, ungrouped) and keeps the pinned tab and the group; above 5 day tabs it asks first and a refusal closes
    /// nothing; with no day tabs the menu row is disabled and its key does nothing; when nothing else is left a New Tab opens.
    func closeAll() async {
        guard await ready(), let c = ctl, let win, let writer = app.writer else { return }
        guard await openTabs(10) else { return finish(false, "10 tabs never appeared (rows \(rowCount))") }
        let ids = c.list.items.map(\.id)
        let pin = ids[0], kept = [ids[1], ids[2]], day = Array(ids[3...])
        c.togglePin(of: pin)
        guard await pinned(c, pin, true) else { return finish(false, "the first tab did not pin") }
        guard let g = c.list.createGroup(with: kept[0]) else { return finish(false, "no group") }
        _ = c.list.setGroup(kept[1], g)
        c.refresh(); c.changed()
        guard entry(c, kept[1])?.groupID == g, day.allSatisfy({ entry(c, $0)?.isPinned == false && entry(c, $0)?.groupID == nil }) else { return finish(false, "the setup is wrong: group of the second kept tab \(String(describing: entry(c, kept[1])?.groupID))") }
        guard await select(c, day[0]) else { return finish(false, "a day tab did not activate") }
        func closeAllKey() { _ = key("k", code: 40, [.command, .shift], chars: "K", menuOnly: true) }
        Confirm.asked = []; Confirm.answer = false

        // 7 day tabs: asked first; a refusal closes nothing.
        closeAllKey(); await settle()
        guard Confirm.asked.count == 1, Confirm.asked[0].message == "Close 7 tabs?" else { return finish(false, "with 7 day tabs Shift+Cmd+K asked \(Confirm.asked.map(\.message)), want one question 'Close 7 tabs?'") }
        guard win.tabs.count == 10, c.list.items.count == 10 else { return finish(false, "a refused Close All closed tabs: \(win.tabs.count) engine tabs, \(c.list.items.count) in the list, want 10") }

        // Accepted: the 7 day tabs close, the pinned tab and the group (2 tabs) stay, no blank opens, the closed ones are on the reopen list.
        Confirm.answer = true
        closeAllKey()
        guard await until(15, { win.tabs.count == 3 && c.list.items.count == 3 }) else { return finish(false, "Close All left \(win.tabs.count) engine tabs and \(c.list.items.count) in the list, want the 3 kept ones") }
        guard Confirm.asked.count == 2, Set(c.list.items.map(\.id)) == Set([pin] + kept), entry(c, pin)?.isPinned == true, c.list.groups.map(\.id) == [g], c.list.items.filter({ $0.groupID == g }).count == 2 else {
            return finish(false, "after Close All the list holds \(c.list.items.map { "\($0.isPinned ? "pin" : $0.groupID == nil ? "day" : "group")" }), groups \(c.list.groups.count), asked \(Confirm.asked.count), want the pinned tab and the group of 2")
        }
        guard let active = c.list.activeID, ([pin] + kept).contains(active) else { return finish(false, "the active tab is \(String(describing: c.list.activeID)), want one of the kept tabs") }
        guard await until(10, { writer.hasClosed }) else { return finish(false, "the closed tabs never reached the reopen list") }

        // No day tab: the menu row is disabled and its key does nothing.
        menuItem("Close All Tabs")?.menu?.update()
        guard menuItem("Close All Tabs")?.isEnabled == false else { return finish(false, "Close All Tabs is enabled with no day tab") }
        BrowserWindowController.actionCounts = [:]
        closeAllKey(); await settle()
        guard BrowserWindowController.actionCounts.isEmpty, win.tabs.count == 3 else { return finish(false, "Close All acted with no day tab: \(BrowserWindowController.actionCounts), \(win.tabs.count) tabs") }

        // 5 day tabs are not above the limit: closed with no question.
        for _ in 0..<5 { _ = win.addTab(withURL: fixture(""), activate: false) }
        guard await until(20, { win.tabs.count == 8 && c.list.items.count == 8 }) else { return finish(false, "5 more tabs never appeared (\(win.tabs.count))") }
        menuItem("Close All Tabs")?.menu?.update()
        guard menuItem("Close All Tabs")?.isEnabled == true else { return finish(false, "Close All Tabs is disabled with 5 day tabs") }
        closeAllKey()
        guard await until(15, { win.tabs.count == 3 && c.list.items.count == 3 }), Confirm.asked.count == 2 else { return finish(false, "5 day tabs: \(win.tabs.count) engine tabs left, asked \(Confirm.asked.count) times, want 3 and still 2") }

        // Nothing but day tabs: they all close and one New Tab opens.
        c.togglePin(of: pin)
        guard await pinned(c, pin, false) else { return finish(false, "the pinned tab did not unpin") }
        _ = c.list.ungroup(g)
        c.refresh(); c.changed()
        guard c.list.items.allSatisfy({ !$0.isPinned && $0.groupID == nil }) else { return finish(false, "unpin and ungroup left a pinned or grouped tab") }
        closeAllKey()
        guard await until(15, { win.tabs.count == 1 && c.list.items.count == 1 && c.list.items[0].url == "about:blank" }), c.list.activeID == c.list.items.first?.id else {
            return finish(false, "Close All on 3 day tabs left \(win.tabs.count) engine tabs, list \(c.list.items.map(\.url)), want one blank tab")
        }
        finish(violations.isEmpty, "Close All Tabs (Shift+Cmd+K): 7 day tabs asked once and a refusal closed none; accepted, it closed the 7 and kept the pinned tab and the group of 2; disabled with no day tab; 5 day tabs closed with no question; with only day tabs left it opened one blank tab \(violations)")
    }

    /// Cmd+W asks before closing the last tab of the profile: no other tab in any window, live or dormant, and a pinned last tab is not it (it stays as a
    /// dormant tile); with `warnBeforeClosingLastTab` stored as 0 it never asks.
    func warnLastTab() async {
        guard await ready(), let c1 = ctl, let w1 = win, app.writer != nil else { return }
        Confirm.asked = []; Confirm.answer = false
        _ = key("w", code: 13, menuOnly: true); await settle()
        guard Confirm.asked.count == 1, Confirm.asked[0].message == "Close the last tab?" else { return finish(false, "Cmd+W on the only tab asked \(Confirm.asked.map(\.message)), want one question 'Close the last tab?'") }
        guard w1.tabs.count == 1, c1.list.items.count == 1, app.controllers.count == 1 else { return finish(false, "a refused warning closed the tab (\(w1.tabs.count) tabs, \(app.controllers.count) windows)") }

        // Another window holds a tab: this one is not the last.
        _ = app.newWindow(url: fixture(""))
        guard await until(20, { self.app.controllers.count == 2 && self.app.controllers[1].list.items.count == 1 }) else { return finish(false, "no second window with a tab") }
        c1.closeActiveTab()
        guard await until(15, { self.app.controllers.count == 1 }) else { return finish(false, "closing the only tab of a window while another window has a tab closed no window (asked \(Confirm.asked.count))") }
        guard Confirm.asked.count == 1 else { return finish(false, "closing a tab with another window open asked: \(Confirm.asked.map(\.message))") }

        // A pinned last tab goes dormant (it stays in the profile): no question, and the window opens a blank tab.
        let c2 = app.controllers[0]
        guard await until(10, { c2.list.items.count == 1 && c2.list.activeID != nil }), let only = c2.list.activeID else { return finish(false, "the second window has \(c2.list.items.count) tabs") }
        c2.togglePin(of: only)
        guard await pinned(c2, only, true) else { return finish(false, "the second window's tab did not pin") }
        c2.closeActiveTab()
        guard await until(15, { c2.list.items.count == 2 && c2.window.tabs.count == 1 && self.entry(c2, only)?.engineID == nil }), Confirm.asked.count == 1 else {
            return finish(false, "Cmd+W on a last pinned tab: \(c2.list.items.count) tabs, \(c2.window.tabs.count) engine tabs, asked \(Confirm.asked.count) times, want a dormant tile, a blank tab and no new question")
        }

        // The blank tab is the only live tab, but the dormant tile is still a tab of the profile: no question either.
        let blank = c2.list.activeID
        c2.closeActiveTab()
        guard await until(15, { c2.list.activeID != blank && c2.list.items.count == 2 && c2.window.tabs.count == 1 }), Confirm.asked.count == 1 else {
            return finish(false, "Cmd+W on the last live tab beside a dormant one: \(c2.list.items.count) tabs, asked \(Confirm.asked.count) times, want a replacement blank tab and no new question")
        }
        c2.close()
        guard await until(15, { self.app.controllers.isEmpty }) else { return finish(false, "the second window did not close") }

        // Answered yes the last tab closes its window.
        _ = app.newWindow(url: fixture(""))
        guard await until(20, { self.app.controllers.count == 1 && self.app.controllers[0].list.items.count == 1 }) else { return finish(false, "no third window") }
        Confirm.answer = true
        app.controllers[0].closeActiveTab()
        guard Confirm.asked.count == 2, await until(15, { self.app.controllers.isEmpty }) else { return finish(false, "an accepted warning left \(app.controllers.count) windows, asked \(Confirm.asked.count) times") }

        // Setting off: no question.
        guard setSetting("warnBeforeClosingLastTab", "0") else { return finish(false, "could not store the setting") }
        _ = app.newWindow(url: fixture(""))
        guard await until(20, { self.app.controllers.count == 1 && self.app.controllers[0].list.items.count == 1 }) else { return finish(false, "no fourth window") }
        Confirm.answer = false
        app.controllers[0].closeActiveTab()
        guard await until(15, { self.app.controllers.isEmpty }), Confirm.asked.count == 2 else { return finish(false, "with warnBeforeClosingLastTab=0 the last tab asked \(Confirm.asked.count - 2) more times and \(app.controllers.count) windows are left, want none asked and the window closed") }
        finish(violations.isEmpty, "Cmd+W on the last tab asked once and a refusal kept it; no question with another window holding a tab, on a last pinned tab (it went dormant) or beside a dormant one; an accepted one closed the window; no question with the setting stored as 0 \(violations)")
    }

    /// With `addNewTabsToTop` (default on) a new tab opens at the top of the day list, under the pinned tiles; stored as 0 it opens at the end; the value is
    /// read when the tab opens.
    func newTabTop() async {
        guard await ready(), let c = ctl, let win, app.writer != nil else { return }
        guard SettingKeys.key("addNewTabsToTop")?.defaultValue == "1" else { return finish(false, "the settings table has no addNewTabsToTop key with default 1") }
        guard (try? app.writer?.store.setting("addNewTabsToTop")).flatMap({ $0 }) == nil else { return finish(false, "addNewTabsToTop is set: this check runs with the default (on)") }
        let a = c.list.items[0].id
        func add(_ n: Int) async -> TabID? {
            let before = Set(c.list.items.map(\.id))
            _ = win.addTab(withURL: fixture(""), activate: false)
            guard await until(15, { c.list.items.count == n && win.tabs.count == n }) else { return nil }
            return c.list.items.map(\.id).first { !before.contains($0) }
        }
        func order() -> String { c.list.dayOrder.map { if case .tab(let t) = $0 { return t == a ? "A" : "n\(c.list.items.firstIndex { $0.id == t } ?? -1)" } else { return "group" } }.joined(separator: " ") }
        guard let b = await add(2), let d = await add(3) else { return finish(false, "tabs never appeared") }
        guard c.list.dayOrder == [.tab(d), .tab(b), .tab(a)] else { return finish(false, "default: the day list is \(order()), want the newest first (n2 n1 A)") }
        // A pinned tile stays above; the new tab is the first day tab.
        c.togglePin(of: a)
        guard await pinned(c, a, true), let e = await add(4) else { return finish(false, "no pinned tile or fourth tab") }
        guard c.list.dayOrder.first == .tab(e), c.list.topOrder.contains(.tab(a)) || c.list.items.first(where: { $0.id == a })?.inGrid == true else { return finish(false, "with a pinned tab the day list is \(order()), want the new tab first") }
        c.togglePin(of: a)
        guard await pinned(c, a, false) else { return finish(false, "the pinned tab did not unpin") }

        guard setSetting("addNewTabsToTop", "0") else { return finish(false, "could not store the setting") }
        guard let f = await add(5), let g = await add(6) else { return finish(false, "tabs never appeared with the setting off") }
        guard c.list.dayOrder.suffix(2) == [.tab(f), .tab(g)] else { return finish(false, "with addNewTabsToTop=0 the day list is \(order()), want the new tabs at the end in opening order") }
        guard setSetting("addNewTabsToTop", "1"), let h = await add(7) else { return finish(false, "tabs never appeared with the setting on again") }
        guard c.list.dayOrder.first == .tab(h) else { return finish(false, "with the setting stored as 1 again the day list is \(order()), want the new tab first") }
        finish(violations.isEmpty, "addNewTabsToTop: default on opens new tabs at the top of the day list (under a pinned tile); stored as 0 they open at the end in opening order; stored as 1 again at the top, read when each tab opens \(violations)")
    }
}
#endif
