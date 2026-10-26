#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// History recording (M1.3): an http load is a page row, a typed load counts as typed, a non-http load is never stored.
extension SelfTest {
    func page(_ store: Store, host: String, path: String) -> PageCandidate? {
        ((try? store.pageCandidates(prefix: host)) ?? []).first { $0.url.hasSuffix(path) }
    }

    func historyRecord() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store = app.writer?.store,
              let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        // The startup load: a link visit with the page's own title (the title arrives with a later update).
        guard await until(10, { page(store, host: host, path: "/")?.title == "Noche App Fixture" }), let first = page(store, host: host, path: "/") else {
            return finish(false, "the startup fixture load is not a page row with its title: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        // Loads that must never be stored: about, data and a file (the status of the last two is not the point, the scheme is).
        for target in ["about:blank", "data:text/html,<title>d</title>hi", "file:///etc/hosts"] {
            let before = loads
            tab.loadURL(target)
            _ = await until(8, { loads > before })
        }
        try? await Task.sleep(for: .milliseconds(500))
        let others = ["about", "data", "file"].flatMap { (try? store.pageCandidates(prefix: $0)) ?? [] }
        guard others.isEmpty else { return finish(false, "non-http loads were stored: \(others.map(\.url))") }
        // A typed load through the address entry counts as typed; a link load does not.
        let before = loads
        guard await submitAddress("\(host)/b.html") else { return finish(false, "the address entry did not take the text") }
        guard await until(15, { loads > before && page(store, host: host, path: "/b.html")?.title == "B Page" }), let b = page(store, host: host, path: "/b.html") else {
            return finish(false, "typed b.html is not a page row with its title: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        // An aborted typed load must not leave its mark: the next link visit records typed=false. The abort is delivered the way the bridge does.
        guard let tab2 = win.activeTab else { return finish(false, "no tab") }
        let abortedURL = "http://\(host)/b.html?abort=1"
        ctl.typedLoads[tab2.identifier] = abortedURL
        ctl.window(win, tab: tab2, didFailLoadWithCode: -3, url: abortedURL)
        let linkBefore = loads
        tab2.loadURL("http://\(host)/b.html?link=1")
        guard await until(15, { loads > linkBefore && page(store, host: host, path: "?link=1") != nil }), let link = page(store, host: host, path: "?link=1") else {
            return finish(false, "the link visit after the aborted typed load is not a page row: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        guard link.typedCount == 0 else { return finish(false, "an aborted typed load left its mark: the next link visit was recorded as typed (typedCount \(link.typedCount))") }
        finish(first.visitCount == 1 && first.typedCount == 0 && b.visitCount == 1 && b.typedCount == 1 && violations.isEmpty,
               "an aborted typed load leaves no mark (the next link visit is typed=false); http loads recorded (startup page visits=\(first.visitCount) typed=\(first.typedCount), typed b.html visits=\(b.visitCount) typed=\(b.typedCount)), about, data and file loads never stored \(violations)")
        _ = ctl
    }

    var hist: HistoryWindowController { app.history }

    /// A title held back by the throttle belongs to the address it was seen at: a navigation writes it to that address (never to the new page), and a tab
    /// that closes with a title pending still stores it.
    func titleFlush() async {
        guard await ready(), let win, let tab = win.activeTab, let store = app.writer?.store, let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        guard await until(10, { page(store, host: host, path: "/")?.title == "Noche App Fixture" }) else { return finish(false, "the startup title was not stored") }
        // link.html is visited first, in a second tab, so that its row exists when the main tab navigates to it: a held title written to the new address would land on it.
        guard let second = win.addTab(withURL: fixture("link.html"), activate: false) else { return finish(false, "no second tab") }
        guard await until(15, { page(store, host: host, path: "/link.html")?.title == "Link Page" }) else { return finish(false, "link.html was not stored with its title") }
        try? await Task.sleep(for: .milliseconds(2300))  // the interval since the last write is over: the next title writes at once, the one after it waits
        _ = await evaluate(tab, "document.title = 'X1'")
        guard await until(3, { page(store, host: host, path: "/")?.title == "X1" }) else { return finish(false, "X1 was not written at once") }
        _ = await evaluate(tab, "document.title = 'X2'")
        try? await Task.sleep(for: .milliseconds(150))
        guard page(store, host: host, path: "/")?.title == "X1" else { return finish(false, "X2 was not held back (stored \(page(store, host: host, path: "/")?.title ?? "nil"))") }
        let navigated = loads
        tab.loadURL(fixture("link.html"))
        guard await until(15, { loads > navigated }) else { return finish(false, "the main tab did not load link.html") }
        // Past the timer that was armed for X2, the new address is watched: it must never carry a title of the old page.
        var seenOnNew = Set<String>(), seenOnOld = Set<String>()
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            seenOnNew.insert(page(store, host: host, path: "/link.html")?.title ?? "nil")
            seenOnOld.insert(page(store, host: host, path: "/")?.title ?? "nil")
            try? await Task.sleep(for: .milliseconds(50))
        }
        let wrote = BrowserWindowController.titleLog.filter { $0.url.hasSuffix("/link.html") && ["X1", "X2"].contains($0.title) }
        guard seenOnNew.isDisjoint(with: ["X1", "X2"]), wrote.isEmpty else { return finish(false, "the new address link.html carried the old page's title: stored titles seen \(seenOnNew.sorted()), writes \(wrote)") }
        guard seenOnOld.contains("X2"), page(store, host: host, path: "/")?.title == "X2" else {
            return finish(false, "after the navigation the old page's held title was not written to the old address (stored \(page(store, host: host, path: "/")?.title ?? "nil"))")
        }
        let b = page(store, host: host, path: "/link.html")?.title
        guard b == "Link Page" else { return finish(false, "the new page link.html carries the title \(b ?? "nil")") }
        // A tab that closes with a title held back.
        _ = await evaluate(second, "document.title = 'Y1'")
        _ = await evaluate(second, "document.title = 'Y2'")
        second.close()
        guard await until(10, { win.tabs.count == 1 }) else { return finish(false, "the second tab did not close") }
        guard await until(1, { page(store, host: host, path: "/link.html")?.title == "Y2" }) else {
            return finish(false, "the tab closed with Y2 held and the store has \(page(store, host: host, path: "/link.html")?.title ?? "nil")")
        }
        finish(violations.isEmpty, "X2 was held, a navigation wrote it to its own address (the new address link.html never carried X1 or X2, titles seen there \(seenOnNew.sorted())), a closed tab's held title Y2 was stored \(violations)")
    }

    /// M1.5 Task 5: the History window. Three fixture pages are visited; the window (opened through the menu action, hidden like every test window) lists them
    /// under Today newest first, the search filters by title and by address, a double click opens a row in a new tab, and Delete removes the row and
    /// the command bar stops suggesting the page.
    func historyWindow() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store = app.writer?.store, let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        guard await until(10, { page(store, host: host, path: "/")?.title == "Noche App Fixture" }) else { return finish(false, "the startup page is not stored with its title") }
        for (path, title) in [("b.html", "B Page"), ("link.html", "Link Page")] {
            tab.loadURL(fixture(path))
            guard await until(15, { page(store, host: host, path: "/\(path)")?.title == title }) else { return finish(false, "\(path) was not stored with its title") }
        }
        let tabsBefore = win.tabs.count
        app.showHistory(nil)
        guard await until(5, { hist.window.isVisible }) else { return finish(false, "History > Show History did not show the History window") }
        // Hidden runs: the same terms as every test window (alpha 0, not key, floating, mouse ignored, the app not active).
        let shown = hist.window
        try? await Task.sleep(for: .milliseconds(300))
        let hiddenTerms = "alpha \(shown.alphaValue), key \(shown.isKeyWindow), level \(shown.level.rawValue), mouse ignored \(shown.ignoresMouseEvents), app active \(NSApp.isActive)"
        guard shown.alphaValue == 0, !shown.isKeyWindow, shown.level == .floating, shown.ignoresMouseEvents, !NSApp.isActive else { return finish(false, "the History window can show: \(hiddenTerms)") }
        guard win.tabs.count == tabsBefore else { return finish(false, "Show History opened a tab (\(tabsBefore) to \(win.tabs.count)), want the window only") }
        func visits() -> [String] { hist.entries.compactMap { if case .visit(let v) = $0 { v.title } else { nil } } }
        func days() -> [String] { hist.entries.compactMap { if case .day(let d) = $0 { d } else { nil } } }
        guard days() == ["Today"], visits() == ["Link Page", "B Page", "Noche App Fixture"] else { return finish(false, "rows \(hist.entries), want Today and the three pages newest first") }
        func find(_ q: String) { hist.search.stringValue = q; _ = hist.search.sendAction(hist.search.action, to: hist.search.target) }
        find("b pa")
        let byTitle = visits()
        find("LINK.HTML")
        let byAddress = visits()
        find("nomatch-zzq")
        let none = hist.entries
        find("")
        guard byTitle == ["B Page"], byAddress == ["Link Page"], none.isEmpty, visits().count == 3 else {
            return finish(false, "search: by title \(byTitle), by address \(byAddress), no match \(none), cleared \(visits())")
        }
        // Double click on the B Page row: a new tab at its address.
        func select(_ title: String) -> Bool {
            guard let r = hist.entries.firstIndex(where: { if case .visit(let v) = $0 { v.title == title } else { false } }) else { return false }
            hist.table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            return true
        }
        guard select("B Page") else { return finish(false, "no B Page row") }
        _ = hist.table.sendAction(hist.table.doubleAction, to: hist.table.target)
        guard await until(15, { win.tabs.count == tabsBefore + 1 && win.activeTab?.url.hasSuffix("/b.html") == true && win.activeTab !== tab }) else {
            return finish(false, "a double click on B Page opened \(win.tabs.count) tabs (was \(tabsBefore)), active \(win.activeTab?.url ?? "nil")")
        }
        guard await until(10, { page(store, host: host, path: "/b.html")?.visitCount == 2 }) else { return finish(false, "the second visit of b.html was not recorded") }
        // The command bar suggests the page; after Delete it does not.
        func suggestsB() async -> Bool {
            guard await openBar() else { return false }
            barType("B Pa")
            let got = await until(3, { bar?.state.rows.contains { $0.kind == .page && ($0.url ?? "").hasSuffix("/b.html") } == true })
            press(.escape); press(.escape)
            _ = await until(2, { !barOpen() })
            return got
        }
        guard await suggestsB() else { return finish(false, "before Delete the command bar does not suggest b.html (\(rowValues))") }
        hist.reload()
        guard select("B Page") else { return finish(false, "no B Page row after the second visit") }
        hist.deleteButton.performClick(nil)
        let left = visits()
        guard left == ["Link Page", "Noche App Fixture"] else { return finish(false, "after Delete the rows are \(left), want Link Page and Noche App Fixture") }
        let stored = ((try? store.pageCandidates(prefix: host)) ?? []).filter { $0.url.hasSuffix("/b.html") }
        guard stored.isEmpty, !(await suggestsB()) else { return finish(false, "after Delete the store still has \(stored.map(\.url)) or the command bar still suggests b.html") }
        // The Delete key goes through the table's keyDown (a key event handed to it).
        guard select("Link Page"), let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: hist.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) else {
            return finish(false, "no Link Page row or no key event")
        }
        hist.table.keyDown(with: key)
        guard visits() == ["Noche App Fixture"], ((try? store.pageCandidates(prefix: host)) ?? []).allSatisfy({ !$0.url.hasSuffix("/link.html") }) else {
            return finish(false, "the Delete key left the rows \(visits()), want Noche App Fixture only")
        }
        // Live: a page loads behind the open window and its row appears without reopening the window; the selection stays on its row.
        guard select("Noche App Fixture") else { return finish(false, "no Noche App Fixture row to keep selected") }
        tab.loadURL(fixture("link.html"))
        guard await until(8, { visits() == ["Link Page", "Noche App Fixture"] }) else {
            return finish(false, "a page loaded behind the open History window and its row did not appear (rows \(visits()))")
        }
        let r = hist.table.selectedRow
        guard r >= 0, r < hist.entries.count, case .visit(let kept) = hist.entries[r], kept.title == "Noche App Fixture" else {
            return finish(false, "the live refresh lost the selection (selected row \(r) of \(hist.entries.count))")
        }
        hist.window.close()
        finish(violations.isEmpty, "the window is hidden (\(hiddenTerms)), three visits listed under Today newest first, search by title and by address, a double click opened a new tab at b.html, Delete removed B Page (both visits) from the list and the command bar, the Delete key removed Link Page, a page loaded behind the open window showed its row without reopening it (selection kept) \(violations)")
        _ = ctl
    }

    /// Ruling M38: a page that changes its title every 100 ms writes at most once per interval, and the last title is stored when the interval ends.
    func titleThrottle() async {
        guard await ready(), let win, let tab = win.activeTab, let store = app.writer?.store, let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        guard await until(10, { page(store, host: host, path: "/")?.title == "Noche App Fixture" }) else { return finish(false, "the startup title was not stored") }
        let before = BrowserWindowController.titleWrites, start = Date()
        for i in 1...30 {
            _ = await evaluate(tab, "document.title = 'Tick \(i)'")
            try? await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = Date().timeIntervalSince(start)
        guard await until(10, { page(store, host: host, path: "/")?.title == "Tick 30" }) else {
            return finish(false, "the last title was not stored (stored \(page(store, host: host, path: "/")?.title ?? "nil"))")
        }
        let writes = BrowserWindowController.titleWrites - before
        let limit = Int((elapsed / BrowserWindowController.titleInterval).rounded(.up)) + 1
        guard writes >= 2, writes <= limit else { return finish(false, "30 title changes in \(String(format: "%.1f", elapsed)) s were written \(writes) times, want 2 to \(limit) (one per \(BrowserWindowController.titleInterval) s and the last)") }
        finish(violations.isEmpty, "30 title changes at 100 ms were written \(writes) times (at most \(limit) for \(String(format: "%.1f", elapsed)) s at one per \(BrowserWindowController.titleInterval) s), the last title 'Tick 30' is stored \(violations)")
    }
}
#endif
