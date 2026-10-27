#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore

/// Context menu checks. A hidden window is never key and must never raise a menu, so test builds hold the NSMenu in `ContextMenus.pending`
/// instead of showing it, and a check chooses an item (or dismisses the menu, a click outside) the way the tracking loop would. The right
/// clicks themselves are real: a DevTools mouse event for the page, a `rightMouseDown` sent to the view under the point for the sidebar.
extension SelfTest {
    func ctxMenu(_ kind: String, seconds: Double = 8) async -> ContextMenus.Pending? {
        guard await until(seconds, { ContextMenus.pending?.kind == kind }) else { return nil }
        return ContextMenus.pending
    }

    /// The first right click after a load is sometimes not answered (engine probe R12): retry.
    func pageRightClick(_ tab: NCTab) async -> ContextMenus.Pending? {
        for _ in 0..<3 {
            tab.testRightClickX(120, y: 120)
            if let p = await ctxMenu("page", seconds: 6) { return p }
        }
        return nil
    }

    /// A right click on |v| (or on |at|, a point of |v|): the view the window would hit gets `rightMouseDown`, as AppKit's `sendEvent` does.
    @discardableResult
    func rightClick(_ v: NSView, at point: NSPoint? = nil, control: Bool = false) -> NSView? {
        guard let ns = ctl?.nsWindow, let host = ctl?.window.chromeHost else { return nil }
        let p = v.convert(point ?? NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        guard let hit = host.hitTest(host.convert(p, from: nil)),
              let ev = NSEvent.mouseEvent(with: control ? .leftMouseDown : .rightMouseDown, location: p, modifierFlags: control ? .control : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        if control { hit.mouseDown(with: ev) } else { hit.rightMouseDown(with: ev) }
        return hit
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "---" : $0.title } }
    func enabledTitles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) }
    func sameKey(_ a: NSMenuItem?, _ b: NSMenuItem?) -> Bool {
        guard let a, let b else { return false }
        return !a.keyEquivalent.isEmpty && a.keyEquivalent == b.keyEquivalent && a.keyEquivalentModifierMask == b.keyEquivalentModifierMask
    }
    func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }

    func ctxPage() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        ContextMenus.dismiss(choosing: nil)  // a menu still held is ended first, never dropped
        // The probe extension (its worker makes the item) may come up after the first page: ask until its content script answers, then
        // right click until the model carries its item.
        guard await extensionTabCount(tab) != nil else { return finish(false, "the probe extension never answered: \(lastExtensionReply)") }
        var shownFirst: ContextMenus.Pending?
        for _ in 0..<10 {
            guard let p = await pageRightClick(tab) else { return finish(false, "no page context menu after three right clicks") }
            if p.model?.contains(where: { $0.commandId == 49000 }) == true { shownFirst = p; break }
            ContextMenus.dismiss(choosing: nil)
            try? await Task.sleep(for: .milliseconds(1000))
        }
        guard let first = shownFirst, let model = first.model else { return finish(false, "the probe extension's item 49000 never reached Chromium's model") }
        // Chromium's model, read independently: visible rows, separators leading, trailing or doubled dropped.
        var want: [(title: String, id: Int, enabled: Bool)] = []
        for m in model where m.visible {
            if m.type == .separator { if let l = want.last, l.title != "---" { want.append(("---", -1, false)) }; continue }
            want.append((m.label, m.commandId, m.enabled))
        }
        if want.last?.title == "---" { want.removeLast() }
        let got = first.menu.items.map { (title: $0.isSeparatorItem ? "---" : $0.title, id: $0.isSeparatorItem ? -1 : $0.tag, enabled: !$0.isSeparatorItem && $0.isEnabled) }
        line("info", "model \(model.count) rows, menu \(got.map { "\($0.title)(\($0.id)\($0.enabled ? "" : " off"))" })")
        guard got.count == want.count, zip(got, want).allSatisfy({ $0.title == $1.title && $0.id == $1.id && $0.enabled == $1.enabled }) else {
            return finish(false, "the NSMenu differs from Chromium's model: menu \(got) vs model \(want)")
        }
        let t = titles(first.menu)
        guard t.count > 3, Array(t.prefix(3)) == ["Back", "Forward", "Reload"] else { return finish(false, "first labels \(t.prefix(3)), want Back, Forward, Reload") }
        guard item(first.menu, "Back")?.isEnabled == false, item(first.menu, "Forward")?.isEnabled == false, item(first.menu, "Reload")?.isEnabled == true else {
            return finish(false, "Back/Forward/Reload enabled states \(got.prefix(3)): a fresh page has no history")
        }
        guard t.contains(where: { $0.hasPrefix("View Page Source") }), t.contains("Inspect") else { return finish(false, "no View Page Source or Inspect in \(t)") }
        guard let probe = item(first.menu, "Noche probe item"), probe.tag == 49000, probe.isEnabled else { return finish(false, "the probe extension's item 49000 is missing from \(t)") }
        // Reload runs in the engine: the load end fires again.
        let loadsBefore = loads
        ContextMenus.dismiss(choosing: item(first.menu, "Reload"))
        guard await until(10, { loads > loadsBefore }) else { return finish(false, "choosing Reload did not reload (loads \(loads), was \(loadsBefore))") }
        // The extension item runs its onClicked with the tab that was right clicked (the active one).
        guard let second = await pageRightClick(tab), let probe2 = item(second.menu, "Noche probe item") else { return finish(false, "no second page menu with the probe item") }
        ContextMenus.dismiss(choosing: probe2)
        var reply: [String: Any]?
        for _ in 0..<40 {
            reply = await extension_(tab, #"{"what":"ctx"}"#)
            if (reply?["clicks"] as? [[String: Any]])?.isEmpty == false { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let clicks = reply?["clicks"] as? [[String: Any]], let last = clicks.last, let tabs = reply?["tabs"] as? [[String: Any]] else {
            return finish(false, "the extension saw no chrome.contextMenus.onClicked: \(String(describing: reply))")
        }
        let activeID = tabs.first { ($0["active"] as? Bool) == true }?["id"] as? Int
        guard last["menuItemId"] as? String == "noche-probe", let clicked = last["tabId"] as? Int, clicked == activeID else {
            return finish(false, "onClicked \(last) but the active chrome.tabs id is \(String(describing: activeID))")
        }
        // A click outside cancels (the menu ends with nothing chosen), and the next right click still opens a menu.
        guard let third = await pageRightClick(tab) else { return finish(false, "no third page menu") }
        _ = third
        ContextMenus.dismiss(choosing: nil)
        let shownBefore = ContextMenus.shown
        guard await pageRightClick(tab) != nil, ContextMenus.shown > shownBefore else { return finish(false, "no menu after a cancelled one") }
        ContextMenus.dismiss(choosing: nil)
        // The engine's callback was answered exactly once per menu shown: two Continues (Reload, the extension item) and a Cancel for each other.
        let continues = Int(NCWindow.testContextMenuContinues()), cancels = Int(NCWindow.testContextMenuCancels())
        guard continues == 2, cancels == ContextMenus.shown - 2 else { return finish(false, "\(ContextMenus.shown) menus shown but the engine's callbacks got \(continues) Continue and \(cancels) Cancel calls, want 2 and \(ContextMenus.shown - 2)") }
        finish(violations.isEmpty && ownWindows() == 1, "page menu equals Chromium's model (\(want.count) rows, labels Back, Forward, Reload ...), Reload reloaded, probe item 49000 ran onClicked with active tab \(clicked), and across \(ContextMenus.shown) menus shown the engine's callback got exactly one answer each (\(continues) Continue, \(cancels) Cancel, counted in the bridge) \(violations)")
    }

    /// A quit that arrives while a page menu is open (Dock Quit, logout): the menu ends first and the engine shutdown starts with no tracking.
    func quitWithContextMenu() async {
        guard await ready(), let tab = win?.activeTab else { return }
        guard let p = await pageRightClick(tab), ContextMenus.tracking, p.kind == "page" else { return finish(false, "no page menu open to quit under") }
        menuOpenedAtQuit = true
        ContextMenus.testCancel = check == "quit-menu-late" ? .late : check == "quit-menu-stuck" ? .never : .now
        quitSentAt = ProcessInfo.processInfo.systemUptime
        line("info", "page menu open (tracking=\(ContextMenus.tracking)), sending the Quit menu action")
        quitViaMenu()
    }

    func ctxTab() async {
        guard await ready(), let ctl, let win else { return }
        guard await openTabs(3) else { return finish(false, "extra tabs never appeared") }
        guard let t1 = ctl.engineTab(ctl.list.items[1]) else { return finish(false, "no tab at row 1") }
        t1.loadURL(fixture("b.html"))
        guard await until(10, { ctl.list.items[1].url.hasSuffix("/b.html") }) else { return finish(false, "row 1 never showed b.html") }
        let active = win.activeTab
        BrowserWindowController.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.noche.selftest"))
        BrowserWindowController.pasteboard.clearContents()
        func row() -> Int { ctl.list.items.firstIndex { $0.engineID == t1.identifier } ?? -1 }
        func open() async -> ContextMenus.Pending? {
            ContextMenus.dismiss(choosing: nil)  // a menu still held is ended first, never dropped
            guard row() >= 0, rightClick(ctl.sidebar.rows[row()]) != nil else { return nil }
            return await ctxMenu("tab", seconds: 3)
        }
        guard let m = await open() else { return finish(false, "no tab menu from a right click on row 1") }
        let want = ["Pin", "---", "Chat With This Tab", "Open as Split", "---", "Duplicate", "New Group with Tab", "Move to Group", "Move to Profile", "---",
                    "Copy Link", "---", "Rename...", "Change Icon...", "Edit Pinned Page", "---", "Close"]
        guard titles(m.menu) == want else { return finish(false, "tab menu \(titles(m.menu)), want \(want)") }
        guard enabledTitles(m.menu) == ["Duplicate", "Copy Link", "Close"] else { return finish(false, "enabled items \(enabledTitles(m.menu)), want Duplicate, Copy Link, Close") }
        guard sameKey(item(m.menu, "Copy Link"), menuItem("Copy URL")), sameKey(item(m.menu, "Close"), menuItem("Close Tab")),
              sameKey(item(m.menu, "New Group with Tab"), menuItem("New Group with Tab")) else { return finish(false, "key equivalents differ from the menu bar's") }
        guard win.activeTab === active else { return finish(false, "a right click changed the selection") }
        BrowserWindowController.actionCounts = [:]
        ContextMenus.dismiss(choosing: item(m.menu, "Pin"))  // a disabled item does nothing
        guard BrowserWindowController.actionCounts.isEmpty, rowCount == 3 else { return finish(false, "a disabled item acted: \(BrowserWindowController.actionCounts)") }
        // Control-click on a row is a right click: the menu is requested and the tab is not selected.
        ContextMenus.dismiss(choosing: nil)
        guard row() >= 0, rightClick(ctl.sidebar.rows[row()], control: true) != nil, await ctxMenu("tab", seconds: 3) != nil else { return finish(false, "a Control-click on row 1 did not request the tab menu") }
        guard win.activeTab === active else { return finish(false, "a Control-click selected the tab") }
        // Copy Link copies the right-clicked tab's address (b.html), not the active tab's.
        guard let c = await open() else { return finish(false, "no menu for Copy Link") }
        ContextMenus.dismiss(choosing: item(c.menu, "Copy Link"))
        guard BrowserWindowController.pasteboard.string(forType: .string) == t1.url, t1.url.hasSuffix("/b.html"), BrowserWindowController.actionCounts == ["copyURL": 1] else {
            return finish(false, "Copy Link wrote \(BrowserWindowController.pasteboard.string(forType: .string) ?? "nil") (acted \(BrowserWindowController.actionCounts)), want \(t1.url)")
        }
        // Duplicate makes a second b.html tab (the right-clicked one's address, the active tab is index.html), active.
        BrowserWindowController.actionCounts = [:]
        guard let d = await open() else { return finish(false, "no menu for Duplicate") }
        ContextMenus.dismiss(choosing: item(d.menu, "Duplicate"))
        guard await until(10, { rowCount == 4 && win.tabs.count == 4 && ctl.list.items.filter { $0.url.hasSuffix("/b.html") }.count == 2 }) else {
            return finish(false, "Duplicate left \(rowCount) rows with addresses \(ctl.list.items.map(\.url))")
        }
        guard BrowserWindowController.actionCounts == ["duplicateTab": 1] else { return finish(false, "Duplicate acted \(BrowserWindowController.actionCounts)") }
        // Close closes the right-clicked tab, not the active one (the duplicate).
        let activeNow = win.activeTab
        guard let x = await open() else { return finish(false, "no menu for Close") }
        ContextMenus.dismiss(choosing: item(x.menu, "Close"))
        guard await until(10, { rowCount == 3 && !win.tabs.contains { $0 === t1 } }) else { return finish(false, "Close left \(rowCount) rows, tab still there: \(win.tabs.contains { $0 === t1 })") }
        guard win.activeTab === activeNow, violations.isEmpty else { return finish(false, "Close changed the selection or \(violations)") }
        finish(true, "tab row menu in the section 3 order with Duplicate, Copy Link and Close enabled and the rest disabled, keys equal the menu bar's, a right click does not select, Copy Link and Duplicate and Close act on the right-clicked tab \(violations)")
    }

    func ctxSidebar() async {
        guard await ready(), let ctl, let win else { return }
        let want = ["New Tab", "Reopen Closed Tab", "---", "New Group", "New Live Group", "New Profile...", "---", "Bookmark All Tabs", "---",
                    "Show Tabs in Sidebar", "Auto-Hide Tabs", "---", "Close All Tabs"]
        func open() async -> ContextMenus.Pending? {
            ContextMenus.dismiss(choosing: nil)  // a menu still held is ended first, never dropped
            let sidebar = ctl.sidebar
            guard let hit = rightClick(sidebar, at: NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.height - 60)), !(hit is TabRowView), hit.isDescendant(of: sidebar) else { return nil }
            return await ctxMenu("sidebar", seconds: 3)
        }
        guard let a = await open() else { return finish(false, "no sidebar menu from a right click on empty space") }
        guard titles(a.menu) == want else { return finish(false, "sidebar menu \(titles(a.menu)), want \(want)") }
        guard enabledTitles(a.menu) == ["New Tab", "Bookmark All Tabs", "Auto-Hide Tabs", "Close All Tabs"] else { return finish(false, "enabled items \(enabledTitles(a.menu)) with a page loaded and nothing closed yet") }
        for t in ["New Tab", "Reopen Closed Tab", "Show Tabs in Sidebar", "Auto-Hide Tabs", "Close All Tabs"] where !sameKey(item(a.menu, t), menuItem(t)) { return finish(false, "\(t) key differs from the menu bar's") }
        guard item(a.menu, "Show Tabs in Sidebar")?.state == .on, item(a.menu, "Auto-Hide Tabs")?.state == .off else { return finish(false, "check marks: Show Tabs in Sidebar on, Auto-Hide Tabs off") }
        BrowserWindowController.actionCounts = [:]
        ContextMenus.dismiss(choosing: item(a.menu, "New Group"))
        guard BrowserWindowController.actionCounts.isEmpty, rowCount == 1 else { return finish(false, "a disabled item acted: \(BrowserWindowController.actionCounts)") }
        // New Tab
        guard let b = await open() else { return finish(false, "no menu for New Tab") }
        ContextMenus.dismiss(choosing: item(b.menu, "New Tab"))
        guard await until(10, { rowCount == 2 && win.tabs.count == 2 }) else { return finish(false, "New Tab left \(rowCount) rows") }
        // Close All Tabs: one blank tab is left, the closed ones go on the reopen list.
        guard let c = await open() else { return finish(false, "no menu for Close All Tabs") }
        guard item(c.menu, "Close All Tabs")?.isEnabled == true else { return finish(false, "Close All Tabs disabled with 2 tabs") }
        ContextMenus.dismiss(choosing: item(c.menu, "Close All Tabs"))
        guard await until(15, { rowCount == 1 && win.tabs.count == 1 && ctl.list.items[0].url == "about:blank" && app.writer?.hasClosed == true }) else {
            return finish(false, "Close All Tabs left \(rowCount) rows \(ctl.list.items.map(\.url)), closed list \(String(describing: app.writer?.hasClosed))")
        }
        // With one blank tab it is disabled; Reopen Closed Tab is enabled now and brings a tab back.
        guard let d = await open() else { return finish(false, "no menu after Close All Tabs") }
        guard item(d.menu, "Close All Tabs")?.isEnabled == false else { return finish(false, "Close All Tabs is enabled with one blank tab") }
        guard item(d.menu, "Reopen Closed Tab")?.isEnabled == true else { return finish(false, "Reopen Closed Tab is disabled with closed tabs on the list") }
        ContextMenus.dismiss(choosing: item(d.menu, "Reopen Closed Tab"))
        guard await until(10, { rowCount == 2 && win.tabs.count == 2 }) else { return finish(false, "Reopen Closed Tab left \(rowCount) rows") }
        // Auto-Hide Tabs is the sidebar toggle and shows its checkmark.
        guard let e = await open() else { return finish(false, "no menu for Auto-Hide Tabs") }
        ContextMenus.dismiss(choosing: item(e.menu, "Auto-Hide Tabs"))
        guard ctl.sidebarHidden, ctl.sidebarMenuEntries().first(where: { $0.title == "Auto-Hide Tabs" })?.checked == true else { return finish(false, "Auto-Hide Tabs did not hide the sidebar (hidden \(ctl.sidebarHidden))") }
        finish(violations.isEmpty, "empty-space menu in the section 3 order, New Tab, Close All Tabs (then disabled on one blank tab), Reopen Closed Tab and Auto-Hide Tabs work, the rest disabled, keys equal the menu bar's \(violations)")
    }
}
#endif
