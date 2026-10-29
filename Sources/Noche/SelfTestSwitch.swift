#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Search Tabs, the Ctrl+Tab switcher and the sidebar-order shortcuts (M1.6 Task 6). A hidden window is never key, so the panels are driven through their
/// own entry points and the keys the way the check suite always sends them (the menu, `NSApp.sendEvent` for the bridge's claim and the flagsChanged monitor).
extension SelfTest {
    /// A flagsChanged event with no modifier held: Ctrl let go.
    func sendCtrlUp() {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: ns.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59) else { return keyLog.append("no flagsChanged event") }
        TabSwitcherController.testControl = false  // a hidden run has no real Control key: the check lets go of it
        NSApp.sendEvent(ev)
    }

    func ctrlTab(_ forward: Bool = true) {
        TabSwitcherController.testControl = true
        sendKey("\t", code: 48, forward ? [.control] : [.control, .shift])
    }

    // MARK: search-tabs

    /// Archives |id| the way cleanup will (the store marks the row, the window drops the tab without a closed record), after saving the window.
    func seedArchived(_ c: BrowserWindowController, _ id: TabID) -> Bool {
        guard let writer = app.writer, let item = entry(c, id), let tab = c.engineTab(item) else { return false }
        writer.saveNow([c.id])
        guard (try? writer.store.archive(ids: [id], at: Date())) != nil else { return false }
        _ = c.list.extract(id)
        c.closing[tab.identifier] = ProcessInfo.processInfo.systemUptime
        tab.close()
        c.refresh()
        c.changed()
        return true
    }

    /// Shift+Cmd+A opens the card; "gam" lists the open tabs by rank (prefix, substring, subsequence), Up and Down move, Return activates, Escape closes, Cmd+Delete closes an
    /// open tab; with an archived tab and a recently closed one seeded, the card lists live tabs, then Archived, then Recently Closed, and Return restores and reopens them.
    func searchTabs() async {
        guard await ready(), let c = ctl, let win, let writer = app.writer else { return }
        guard await openTabs(5, page: "b.html"), await until(20, { c.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "five tabs never appeared") }
        let t = c.list.items.map(\.id)
        for (id, name) in zip(t, ["alpha", "my game", "grand mal", "gamma ray", "zeta"]) { c.renameTab(id, to: name) }
        let card = c.searchTabsCard
        let tool = NSTextView()
        func command(_ s: Selector) -> Bool { card.control(card.view.field, textView: tool, doCommandBy: s) }
        func kinds() -> [String] { card.results.map { switch $0.source { case .live: "live"; case .archived: "archived"; case .closed: "closed" } } }
        func ids() -> [TabID] { card.results.map(\.id) }

        // Shift+Cmd+A through the menu.
        guard key("a", code: 0, [.command, .shift], menuOnly: true), await until(5, { card.isOpen }) else { return finish(false, "Shift+Cmd+A did not open Search Tabs (keys \(keyLog.suffix(1)))") }
        guard ids() == c.list.searchTabs(query: ""), ids().count == 5 else { return finish(false, "an empty query lists \(card.results.map(\.title)), want the five open tabs in recency order") }

        // The results by rank, on the command bar's card.
        card.setQuery("gam")
        guard ids() == [t[3], t[1], t[2]] else { return finish(false, "'gam' lists \(card.results.map(\.title)), want [gamma ray, my game, grand mal] (prefix, substring, subsequence)") }
        let width = min(ChromeStyle.searchWidth, c.overlay.bounds.width - 24)
        guard let f = c.frame(ofIdentifier: "searchTabs"), near(f, (c.overlay.bounds.width - width) / 2, ChromeStyle.searchTop, width, ChromeStyle.searchInputHeight + 3 * ChromeStyle.searchRowHeight + ChromeStyle.searchPad) else {
            return finish(false, "the card is at \(String(describing: c.frame(ofIdentifier: "searchTabs"))), want x \((c.overlay.bounds.width - width) / 2) y \(ChromeStyle.searchTop) \(width) by \(ChromeStyle.searchInputHeight + 3 * ChromeStyle.searchRowHeight + ChromeStyle.searchPad)")
        }
        guard (c.view(withIdentifier: "searchTabs.row.0")?.accessibilityValue() as? String)?.hasPrefix("tab|gamma ray - ") == true else {
            return finish(false, "row 0 shows \(String(describing: c.view(withIdentifier: "searchTabs.row.0")?.accessibilityValue()))")
        }

        // Up and Down (clamped), Return activates the selected result.
        for _ in 0..<5 { _ = command(#selector(NSResponder.moveDown(_:))) }
        guard card.selected == 2 else { return finish(false, "Down five times selected \(card.selected), want 2 (clamped)") }
        for _ in 0..<5 { _ = command(#selector(NSResponder.moveUp(_:))) }
        guard card.selected == 0, command(#selector(NSResponder.moveDown(_:))), card.selected == 1 else { return finish(false, "Up five times then Down selected \(card.selected), want 1") }
        guard command(#selector(NSResponder.insertNewline(_:))), await until(10, { c.list.activeID == t[1] }), !card.isOpen else {
            return finish(false, "Return on 'my game' left active \(String(describing: c.list.items.first { $0.id == c.list.activeID }?.customTitle)), card open \(card.isOpen)")
        }

        // Escape closes and leaves the active tab alone.
        card.open()
        card.setQuery("gam")
        // With the card open the engine's system focus requests are refused and the field keeps the keys; after the close they are not refused.
        let refused0 = win.testFocusRefused
        guard win.keysHeld, win.testSystemFocusRequest(), win.testFocusRefused == refused0 + 1, card.view.field.currentEditor() != nil else {
            return finish(false, "with Search Tabs open the keys are held \(win.keysHeld), an engine focus request was refused \(win.testFocusRefused - refused0) times (want 1), the field is first responder \(card.view.field.currentEditor() != nil)")
        }
        guard command(#selector(NSResponder.cancelOperation(_:))), !card.isOpen, c.list.activeID == t[1] else { return finish(false, "Escape left the card open (\(card.isOpen)) or changed the active tab") }
        guard !win.keysHeld, !win.testSystemFocusRequest() else { return finish(false, "after Escape the keys are still held (\(win.keysHeld))") }

        // Cmd+L with the card open: the command bar takes over, the card closes, and the keys follow what is open.
        card.open()
        guard win.keysHeld, await openBar() else { return finish(false, "Cmd+L with Search Tabs open did not open the command bar (card open \(card.isOpen))") }
        guard !card.isOpen, win.keysHeld else { return finish(false, "with the bar open the card is open \(card.isOpen) and the keys are held \(win.keysHeld), want the card closed and the keys held by the bar") }
        press(.escape); press(.escape)
        guard await until(3, { !self.barOpen() }), !card.isOpen, !win.keysHeld else { return finish(false, "after Escape the bar is open \(barOpen()), the card \(card.isOpen), the keys held \(win.keysHeld), want none") }

        // Cmd+Delete closes an open tab and its row goes at once.
        card.open()
        card.setQuery("alpha")
        guard ids() == [t[0]], command(#selector(NSResponder.deleteToBeginningOfLine(_:))), card.results.isEmpty, await until(10, { c.list.items.count == 4 && win.tabs.count == 4 }) else {
            return finish(false, "Cmd+Delete on 'alpha' left \(c.list.items.count) tabs and \(card.results.count) results, want 4 and 0")
        }
        card.close(restoreFocus: false)

        // Seed an archived tab ('zeta') and a recently closed one ('grand mal').
        guard seedArchived(c, t[4]), await until(10, { ((try? writer.store.archivedTabs(matching: "zeta")) ?? []).count == 1 && win.tabs.count == 3 }) else { return finish(false, "no archived tab seeded") }
        guard let grand = entry(c, t[2]).flatMap({ c.engineTab($0) }) else { return finish(false, "no tab to close") }
        c.closeTab(grand)
        guard await until(10, { ((try? writer.store.closedTabs(matching: "grand")) ?? []).count == 1 }) else { return finish(false, "'grand mal' never reached the closed list") }

        card.open()
        card.setQuery("")
        guard kinds() == ["live", "live", "archived", "closed", "closed"], card.results.map(\.title).suffix(3) == ["zeta", "grand mal", "alpha"] else { return finish(false, "an empty query lists \(kinds()) \(card.results.map(\.title)), want two open tabs, then archived 'zeta', then the closed 'grand mal' and 'alpha' (closed by Cmd+Delete, the most recently used first)") }
        guard card.lines.contains(.header("Archived")), card.lines.contains(.header("Recently Closed")) else { return finish(false, "the card's lines are \(card.lines), want both section headers") }
        
        // Return on the archived row restores it into this window; on the closed row reopens it.
        card.setQuery("zeta")
        guard kinds() == ["archived"], !command(#selector(NSResponder.deleteToBeginningOfLine(_:))), command(#selector(NSResponder.insertNewline(_:))) else { return finish(false, "'zeta' lists \(kinds()), want the archived row (Cmd+Delete on it does nothing)") }
        guard await until(15, { self.entry(c, t[4]).flatMap { c.engineTab($0) } != nil && c.list.activeID == t[4] }) else { return finish(false, "the archived tab did not come back as the active tab (list has it: \(entry(c, t[4]) != nil))") }
        guard ((try? writer.store.archivedTabs(matching: "zeta")) ?? []).isEmpty, await until(8, { self.stored(t[4])?.customTitle == "zeta" }) else { return finish(false, "after the restore the store still lists 'zeta' as archived or does not hold it in the window") }
        card.open()
        card.setQuery("grand")
        guard kinds() == ["closed"], command(#selector(NSResponder.insertNewline(_:))) else { return finish(false, "'grand' lists \(kinds()), want the closed row") }
        guard await until(15, { self.entry(c, t[2]).flatMap { c.engineTab($0) } != nil && c.list.activeID == t[2] }) else { return finish(false, "the closed tab did not reopen as the active tab") }
        guard await until(8, { ((try? writer.store.closedTabs(matching: "grand")) ?? []).isEmpty }) else { return finish(false, "the reopened tab is still on the closed list") }

        // Cmd+Delete on a dormant open row (a pinned tab whose engine tab closed, then unpinned) closes it through the sidebar's own path: it lands on the closed list.
        c.togglePin(of: t[3])
        guard await until(5, { self.entry(c, t[3])?.isPinned == true }), let pinnedTab = entry(c, t[3]).flatMap({ c.engineTab($0) }) else { return finish(false, "no pinned tab to make dormant") }
        c.closeTab(pinnedTab)
        guard await until(10, { self.entry(c, t[3])?.engineID == nil && self.entry(c, t[3]) != nil }) else { return finish(false, "'gamma ray' did not go dormant") }
        c.togglePin(of: t[3])
        guard await until(5, { self.entry(c, t[3])?.isPinned == false }) else { return finish(false, "'gamma ray' did not unpin") }
        card.open()
        card.setQuery("gamma")
        guard ids() == [t[3]], kinds() == ["live"], command(#selector(NSResponder.deleteToBeginningOfLine(_:))), card.results.isEmpty else {
            return finish(false, "Cmd+Delete on the dormant open row 'gamma ray' left \(card.results.count) results (rows \(ids().count)), want 0")
        }
        guard await until(8, { c.item(withID: t[3]) == nil && self.app.writer?.peekClosed()?.tab.id == t[3] }) else {
            return finish(false, "the dormant row is still in the list (\(c.item(withID: t[3]) != nil)) or not on the closed list (\(String(describing: self.app.writer?.peekClosed()?.tab.title)))")
        }
        card.close(restoreFocus: false)

        // The same on a New Tab page: the card gives up its hold when Search Tabs opens, Cmd+L closes Search Tabs and the card holds the keys, Escape lets them go.
        guard cmdT(), await until(10, { c.newTabShown && self.barOpen() }) else { return finish(false, "no New Tab card (shown \(c.newTabShown), bar \(barOpen()))") }
        card.open()
        guard card.isOpen, win.keysHeld, win.testSystemFocusRequest() else { return finish(false, "with Search Tabs open over the New Tab card the card is open \(card.isOpen) and the keys are held \(win.keysHeld)") }
        guard await openBar(), !card.isOpen, win.keysHeld else { return finish(false, "Cmd+L on a New Tab page with Search Tabs open left the card open \(card.isOpen), keys held \(win.keysHeld)") }
        press(.escape)
        guard await until(3, { !win.keysHeld }), !card.isOpen else { return finish(false, "after Escape on the New Tab card the keys are held \(win.keysHeld) (card open \(card.isOpen))") }
        finish(violations.isEmpty, "Shift+Cmd+A opens the card; 'gam' ranks [gamma ray, my game, grand mal]; Up and Down clamp, Return activates, Escape closes, Cmd+Delete closes an open tab (a dormant one too); the card holds the keys from open to close; an empty query lists open tabs, then Archived, then Recently Closed; Return restores the archived tab and reopens the closed one (the store clears both) \(violations)")
    }

    // MARK: ctrl-tab

    /// Ctrl+Tab and Ctrl+Shift+Tab (claimed at the bridge key hook, committed when Ctrl is let go): the previous tab, two presses reach the one before it, the strip
    /// shows after the second press or 200 ms and holds at most 8 tiles, a quick tap shows nothing, from the chrome the same handler runs, and Next Tab keeps its list order.
    func ctrlTabCheck() async {
        guard await ready(), let c = ctl, let win else { return }
        guard await openTabs(3, page: "b.html"), await until(20, { c.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "three tabs never appeared") }
        let t = c.list.items.map(\.id)
        let sw = c.tabSwitcher
        let claims0 = NCWindow.testPreemptedKeys()
        var presses = 0
        func press(_ forward: Bool = true) { presses += 1; ctrlTab(forward) }
        func active(_ id: TabID) async -> Bool { await until(10, { c.list.activeID == id }) }
        for id in [t[0], t[1], t[2]] { guard await select(c, id) else { return finish(false, "tab \(id) did not activate") } }  // recency: C, B, A

        // A quick tap: the previous tab, and the strip never showed.
        press()
        guard await until(5, { sw.isActive }) else { return finish(false, "Ctrl+Tab did not start the switcher (claims \(NCWindow.testPreemptedKeys() - claims0), keys \(keyLog.suffix(1)))") }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }), await active(t[1]), sw.shownCount == 0, !sw.isShown else { return finish(false, "a quick tap left active \(String(describing: activeIndex(c))), shown \(sw.shownCount) times, want B and none") }

        // Holding Ctrl: Tab twice reaches A (recency B, C, A), the strip shows, letting go commits.
        press(); press()
        guard await until(5, { sw.isShown }), sw.selectedID == t[0], sw.view.tiles.map(\.id) == [t[1], t[2], t[0]], sw.view.selected == 2, sw.view.superview != nil else {
            return finish(false, "after two presses the strip shows \(sw.view.tiles.count) tiles, selected \(sw.view.selected) of order \(sw.order.count), shown \(sw.isShown)")
        }
        guard c.list.activeID == t[1] else { return finish(false, "the tab changed before Ctrl was let go") }
        sendCtrlUp()
        guard await active(t[0]), !sw.isShown, sw.view.superview == nil else { return finish(false, "letting go of Ctrl left active \(String(describing: c.list.items.first { $0.id == c.list.activeID }?.title)) and the strip shown \(sw.isShown)") }

        // Backward: Ctrl+Shift+Tab goes to the oldest tab; one more Tab (forward) moves on from there.
        let mru = c.list.mru(limit: 8)  // A, B, C
        press(false)
        guard await until(5, { sw.isActive }), sw.selectedID == mru.last else { return finish(false, "Ctrl+Shift+Tab selected \(String(describing: sw.selectedID)), want the oldest tab \(String(describing: mru.last))") }
        sendCtrlUp()
        guard await active(mru.last!) else { return finish(false, "Ctrl+Shift+Tab then release did not activate the oldest tab") }

        // A single press shows the strip after 200 ms.
        press()
        guard await until(5, { sw.isActive }), !sw.isShown else { return finish(false, "the strip showed at once (shown \(sw.isShown))") }
        guard await until(3, { sw.isShown }) else { return finish(false, "the strip never showed 200 ms after the press") }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }) else { return finish(false, "no release") }

        // Next Tab still means the next tab of the list.
        guard await select(c, t[0]) else { return finish(false, "A did not activate") }
        nextTab()
        guard await active(t[1]) else { return finish(false, "Next Tab (Shift+Cmd+]) from A left \(String(describing: activeIndex(c))), want B") }

        // Focus in the chrome: the command bar open on the page, the same keys reach the same handler and the bar gives way.
        guard await openBar() else { return finish(false, "no command bar") }
        press()
        guard await until(5, { sw.isActive }), !barOpen() else { return finish(false, "with the bar open Ctrl+Tab started the switcher \(sw.isActive) and left the bar open \(barOpen())") }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }) else { return finish(false, "no release after the bar") }

        // At most 8 tiles.
        for _ in 0..<7 { _ = win.addTab(withURL: fixture("b.html"), activate: false) }
        guard await until(20, { c.list.items.count == 10 && win.tabs.count == 10 }) else { return finish(false, "ten tabs never appeared (list \(c.list.items.count), engine \(win.tabs.count))") }
        press(); press()
        guard await until(5, { sw.isShown }), sw.view.tiles.count == 8, sw.order.count == 8 else { return finish(false, "ten tabs: the strip holds \(sw.view.tiles.count) tiles, want 8") }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }) else { return finish(false, "no release after ten tabs") }
        let shown0 = sw.shownCount

        // A tap whose Ctrl release came before the session could watch for it (the key and the release in one run-loop turn) commits at once and leaves no session.
        guard let current = c.list.activeID else { return finish(false, "no active tab") }
        let before = [current] + c.list.mru(limit: 8).filter { $0 != current }
        press(); sendCtrlUp()
        guard await until(5, { !sw.isActive }), await active(before[1]), sw.shownCount == shown0 else {
            return finish(false, "the key and the Ctrl release back to back left the session active \(sw.isActive), active tab \(String(describing: activeIndex(c))), want the previous tab \(String(describing: c.list.items.firstIndex { $0.id == before[1] })) and no session")
        }

        // A tab closes during the session: the highlight stays on the tab it was on (the strip drops the gone tile) and release commits that tab.
        press(); press()
        guard await until(5, { sw.isShown }), let goneAhead = sw.order.dropFirst().first, let keep = sw.selectedID, goneAhead != keep, let aheadItem = entry(c, goneAhead), let aheadTab = c.engineTab(aheadItem) else { return finish(false, "no session to close a tab in") }
        c.closeTab(aheadTab)
        guard await until(10, { c.item(withID: goneAhead) == nil }), await until(5, { sw.view.tiles.count == 7 }) else { return finish(false, "the closed tab stayed in the strip (\(sw.view.tiles.count) tiles)") }
        guard sw.view.tiles.indices.contains(sw.view.selected), sw.view.tiles[sw.view.selected].id == keep else {
            return finish(false, "after a tab ahead of the selection closed the highlight is on tile \(sw.view.selected) (\(sw.view.tiles.indices.contains(sw.view.selected) ? String(describing: c.item(withID: sw.view.tiles[sw.view.selected].id)?.customTitle ?? c.item(withID: sw.view.tiles[sw.view.selected].id)?.title) : "none")), want the selected tab")
        }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }), await active(keep) else { return finish(false, "release after a tab closed activated \(String(describing: activeIndex(c))), want the selected tab") }

        // The selected tab itself closes: the highlight and the commit go to the next live tab of the strip.
        press(); press()
        guard await until(5, { sw.isShown }), let gone = sw.selectedID, let goneIndex = sw.order.firstIndex(of: gone), let goneTab = entry(c, gone).flatMap({ c.engineTab($0) }) else { return finish(false, "no session to close the selected tab in") }
        let next = sw.order[(goneIndex + 1) % sw.order.count]
        c.closeTab(goneTab)
        guard await until(10, { c.item(withID: gone) == nil }), await until(5, { sw.view.tiles.count == 7 }), sw.view.tiles.indices.contains(sw.view.selected), sw.view.tiles[sw.view.selected].id == next else {
            return finish(false, "after the selected tab closed the highlight is on tile \(sw.view.selected) of \(sw.view.tiles.count), want the next live tab (7 tiles)")
        }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }), await active(next) else { return finish(false, "release after the selected tab closed activated \(String(describing: activeIndex(c))), want the next live tab") }

        // A narrow window: the strip fits, every drawn tile is on screen and the selected one stays visible as Tab advances to the 8th tile (and wraps).
        guard let ns = c.nsWindow else { return finish(false, "no window") }
        let f0 = ns.frame
        ns.setFrame(NSRect(x: f0.minX, y: f0.minY, width: ChromeStyle.minimumWindowWidth, height: f0.height), display: false)
        guard await until(5, { c.overlay.bounds.width <= ChromeStyle.minimumWindowWidth + 1 }) else { return finish(false, "the window did not narrow (overlay \(c.overlay.bounds.width))") }
        func onScreen(_ r: NSRect) -> Bool { c.overlay.bounds.insetBy(dx: -0.5, dy: -0.5).contains(sw.view.convert(r, to: c.overlay)) }
        func visible(_ step: String) -> String? {
            let sel = sw.view.selected
            if !sw.view.drawnRange.contains(sel) || !onScreen(sw.view.tileFrame(sel)) { return "\(step): the selected tile \(sel) of \(sw.view.tiles.count) is at \(sw.view.convert(sw.view.tileFrame(sel), to: c.overlay)) (drawn \(sw.view.drawnRange)), outside the \(c.overlay.bounds.width) wide window" }
            if let bad = sw.view.drawnRange.first(where: { !onScreen(sw.view.tileFrame($0)) }) { return "\(step): drawn tile \(bad) is at \(sw.view.convert(sw.view.tileFrame(bad), to: c.overlay)), outside the \(c.overlay.bounds.width) wide window" }
            if sw.view.drawnRange.count > 1, sw.view.tileFrame(sw.view.drawnRange.lowerBound).width < ChromeStyle.switcherMinTileWidth - 0.5 { return "\(step): tiles are narrower than the minimum" }
            return nil
        }
        press()
        guard await until(5, { sw.isShown }), sw.view.tiles.count == 8 else { return finish(false, "narrow window: the strip shows \(sw.view.tiles.count) tiles, want 8 (isShown \(sw.isShown))") }
        if let why = visible("press 1") { return finish(false, why) }
        for n in 2...8 {
            press()
            guard sw.view.tiles.indices.contains(sw.view.selected), sw.view.tiles[sw.view.selected].id == sw.selectedID else { return finish(false, "press \(n): the highlight is not on the selected tab") }
            if let why = visible("press \(n)") { return finish(false, why) }
        }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }) else { return finish(false, "no release in the narrow window") }
        ns.setFrame(f0, display: false)

        // Shift+Tab after the selected tab closed: the order loses the gone tile, so a step back lands on the tile before the highlight.
        press(); press()
        guard await until(5, { sw.isShown }), let gone2 = sw.selectedID, let goneTab2 = entry(c, gone2).flatMap({ c.engineTab($0) }) else { return finish(false, "no session for the Shift+Tab step") }
        c.closeTab(goneTab2)
        guard await until(10, { c.item(withID: gone2) == nil }), await until(5, { !sw.view.tiles.contains { $0.id == gone2 } }), sw.view.selected > 0 else { return finish(false, "the strip after the selected tab closed: \(sw.view.tiles.count) tiles, highlight \(sw.view.selected)") }
        let ahead = sw.view.tiles[sw.view.selected - 1].id
        press(false)
        _ = await until(2, { sw.selectedID == ahead })  // the claimed key arrives on a later main-queue turn
        guard sw.selectedID == ahead, sw.view.tiles[sw.view.selected].id == ahead else { return finish(false, "Shift+Tab after the selected tab closed highlights tile \(sw.view.selected) (\(String(describing: sw.selectedID))), want the tile before the highlight") }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }), await active(ahead) else { return finish(false, "release after Shift+Tab activated \(String(describing: activeIndex(c))), want the tile before") }

        // A dormant tab closed during the session: its tile goes at once.
        guard let cur = c.list.activeID else { return finish(false, "no active tab") }
        guard let y = c.list.mru(limit: 8).first(where: { $0 != cur }) else { return finish(false, "no second tab") }
        c.togglePin(of: y)
        guard await until(5, { self.entry(c, y)?.isPinned == true }), let yTab = entry(c, y).flatMap({ c.engineTab($0) }) else { return finish(false, "no pinned tab to make dormant") }
        c.closeTab(yTab)
        guard await until(10, { self.entry(c, y)?.engineID == nil && self.entry(c, y) != nil }) else { return finish(false, "the tab did not go dormant") }
        c.togglePin(of: y)
        guard await until(5, { self.entry(c, y)?.isPinned == false }), let yItem = entry(c, y) else { return finish(false, "the dormant tab did not unpin") }
        press(); press()
        guard await until(5, { sw.isShown }), sw.view.tiles.contains(where: { $0.id == y }), let keep3 = sw.selectedID, keep3 != y else { return finish(false, "no session with the dormant tab in the strip (selected \(String(describing: sw.selectedID)))") }
        try? await Task.sleep(nanoseconds: 600_000_000)  // the 200 ms show timer has fired: only the list change can redraw the strip now
        let tiles0 = sw.view.tiles.count
        c.closeDormant(yItem)
        guard await until(5, { !sw.view.tiles.contains { $0.id == y } && sw.view.tiles.count == tiles0 - 1 }) else { return finish(false, "a dormant tab closed during the session stays drawn (\(sw.view.tiles.count) of \(tiles0) tiles)") }
        guard sw.view.tiles[sw.view.selected].id == keep3 else { return finish(false, "the highlight left the selected tab") }
        sendCtrlUp()
        guard await until(5, { !sw.isActive }), await active(keep3) else { return finish(false, "release after the dormant tab closed activated the wrong tab") }

        // Every press came through the bridge's claim.
        let claims = NCWindow.testPreemptedKeys() - claims0
        guard claims == presses else { return finish(false, "the bridge claimed \(claims) Ctrl+Tab presses, want \(presses)") }
        finish(violations.isEmpty, "a quick tap switches to the previous tab with no strip, two presses with Ctrl held reach the one before, release commits, Ctrl+Shift+Tab goes backward, the strip shows after 200 ms and holds 8 tiles, the command bar gives way, Next Tab keeps list order, a release that came before the session was watching commits at once, the highlight follows the selected tab when a tab closes, Shift+Tab steps over live tiles after the selected tab closed, a dormant tab closing during a session drops its tile, the strip fits a window of minimum width with the selected tile on screen at every press; \(claims) presses claimed by the bridge \(violations)")
    }

    // MARK: shortcuts-order

    /// Cmd+1 to Cmd+8, Cmd+9 and Next and Previous Tab count the rows the sidebar shows (tiles, the persistent area, the day list), a dormant tab included, the
    /// children of a collapsed group and the group headers not. The expected order is read from the sidebar's own row layout.
    func shortcutsOrder() async {
        guard await ready(), let c = ctl, let win else { return }
        guard await openTabs(8, page: "b.html"), await until(20, { c.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "eight tabs never appeared") }
        let t = c.list.items.map(\.id)
        for (i, id) in t.enumerated() { c.renameTab(id, to: "s\(i)") }
        // A tile (t2), a dormant day tab (t6: pinned, its engine tab gone, unpinned), and a collapsed group (t4, t5) between day tabs.
        c.togglePin(of: t[2])
        guard await until(5, { self.entry(c, t[2])?.inGrid == true }) else { return finish(false, "no tile") }
        c.togglePin(of: t[6])
        guard await until(5, { self.entry(c, t[6])?.isPinned == true }), let dormantTab = entry(c, t[6]).flatMap({ c.engineTab($0) }) else { return finish(false, "no pinned tab 6") }
        c.closeTab(dormantTab)
        guard await until(10, { self.entry(c, t[6])?.engineID == nil && c.list.items.count == 8 }) else { return finish(false, "tab 6 did not go dormant") }
        c.togglePin(of: t[6])
        guard await until(5, { self.entry(c, t[6])?.isPinned == false }) else { return finish(false, "tab 6 did not unpin") }
        guard let g = c.list.createGroup(with: t[4], name: "s-group") else { return finish(false, "no group") }
        _ = c.list.setGroup(t[5], g)
        c.list.collapse(g)
        c.refresh(); c.changed()
        func rows() -> [TabID] { c.list.layout().compactMap { e -> TabID? in
            switch e { case .gridTile(let id): id; case .tab(let id, _): id; default: nil } } }
        func press(_ n: Int) { key(String(n), code: [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25][n]!, menuOnly: true) }
        let order = rows()
        guard order.count == 6, !order.contains(t[4]), !order.contains(t[5]), order.contains(t[6]) else { return finish(false, "the sidebar shows \(order.count) rows, want 6 (8 tabs, 2 hidden in the collapsed group, the dormant one among them)") }
        guard c.list.items.count == 8, entry(c, t[6])?.engineID == nil else { return finish(false, "the dormant tab is not dormant") }
        // Cmd+1 to Cmd+6, then Cmd+9: each lands on the row at that place; a dormant row wakes.
        for n in 1...6 {
            press(n)
            guard await until(15, { c.list.activeID == order[n - 1] }) else {
                return finish(false, "Cmd+\(n) activated \(String(describing: c.list.items.first { $0.id == c.list.activeID }?.customTitle)), want \(c.list.items.first { $0.id == order[n - 1] }?.customTitle ?? "?") (rows \(order.map { id in c.list.items.first { $0.id == id }?.customTitle ?? "?" }))")
            }
        }
        guard await until(15, { self.entry(c, t[6])?.engineID != nil }) else { return finish(false, "Cmd+N on the dormant row did not wake it") }
        press(1)
        guard await until(10, { c.list.activeID == order[0] }) else { return finish(false, "Cmd+1 after the loop did not return to the first row") }
        press(9)
        guard await until(10, { c.list.activeID == order.last }) else { return finish(false, "Cmd+9 activated \(String(describing: c.list.items.first { $0.id == c.list.activeID }?.customTitle)), want the last visible row \(c.list.items.first { $0.id == order.last }?.customTitle ?? "?")") }
        // Next and Previous walk the same rows (the header and the hidden children are skipped), wrapping at the ends.
        for k in 0..<order.count {
            guard await select(c, order[k]) else { return finish(false, "row \(k) did not activate") }
            nextTab()
            guard await until(10, { c.list.activeID == order[(k + 1) % order.count] }) else { return finish(false, "Next Tab from row \(k) activated \(String(describing: activeIndex(c))), want row \((k + 1) % order.count)") }
            previousTab()
            guard await until(10, { c.list.activeID == order[k] }) else { return finish(false, "Previous Tab did not come back to row \(k)") }
        }
        // Opened again, the group's children count.
        c.list.collapse(g, false)
        c.refresh()
        let open = rows()
        guard open.count == 8 else { return finish(false, "the open group shows \(open.count) rows, want 8") }
        press(8)
        guard await until(10, { c.list.activeID == open[7] }) else { return finish(false, "Cmd+8 with the group open did not reach row 8") }
        _ = win
        finish(violations.isEmpty, "Cmd+1 to Cmd+6 and Cmd+9 follow the sidebar's rows (tile first, then the day list; the collapsed group's two children hidden, the dormant row counted as the sidebar counts it and woken by its number, a group header has no number), Next and Previous walk the same rows and wrap, and an open group's children count \(violations)")
    }
}
#endif
