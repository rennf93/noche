#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// M1.5 Task 7a: the review list of Tasks 3 and 5 (downloads, windows, history, titles).
extension SelfTest {
    private func rowNames() -> [String] { dc.windowController.rows.map { $0.nameField.stringValue } }

    /// Task 3 Minor 4: finished rows can be removed one by one and all at once, and a running one never goes. Two phases: phase 2 reports what the engine
    /// brings back after the relaunch (its restored items), the evidence for the README's note on what Remove can and cannot do.
    func dlRemoveRelaunch() async {
        let state = SelfTest.downloadFolder.deletingLastPathComponent().appendingPathComponent("dl-remove.txt")
        if phase == 1 {
            guard await ready(), let win, let tab = win.activeTab, let server = await startSlowServer(size: Self.slowSize) else { return }
            defer { server.stop() }
            for n in 1...2 {
                tab.loadURL(fixture("download.bin"))
                guard await until(20, { dc.items.filter { $0.state == .complete }.count == n }) else { return finish(false, "download \(n) of download.bin never completed") }
            }
            guard let first = await startSlow(tab, server: server) else { return }
            NCDownloads.shared.cancel(first.identifier)
            guard await until(10, { item(first.identifier)?.state == .canceled }) else { return finish(false, "Cancel did not end canceled") }
            app.showDownloads(nil)
            guard await until(5, { dc.windowController.rows.count == 3 }) else { return finish(false, "\(dc.windowController.rows.count) rows, want 3 (canceled slow.bin and two complete)") }
            let rows = dc.windowController.rows
            guard rows[0].visibleButtons == ["Remove"], rows[1].visibleButtons == ["Open", "Show in Finder", "Remove"], rows[2].visibleButtons == ["Open", "Show in Finder", "Remove"] else {
                return finish(false, "buttons per row \(rows.map(\.visibleButtons)), want Remove on a canceled row and Open, Show in Finder, Remove on a complete one")
            }
            // Remove on the canceled row takes that row only.
            let all = dc.items.map { "\($0.identifier):\($0.suggestedName)" }
            rows[0].button("Remove")?.performClick(nil)
            guard rowNames() == ["download (1).bin", "download.bin"] else { return finish(false, "after Remove on the canceled row the rows are \(rowNames()), want the two complete ones") }
            // A running download and Clear: only the running row stays, and with nothing finished Clear is off.
            guard let running = await startSlow(tab, server: server, minBytes: 100_000) else { return }
            guard await until(5, { dc.windowController.rows.count == 3 }), dc.windowController.clearButton.isEnabled else { return finish(false, "no third row for the running download, or Clear is off with finished rows") }
            dc.windowController.clearButton.performClick(nil)
            guard dc.windowController.rows.count == 1, dc.windowController.rows[0].visibleButtons == ["Pause", "Cancel"], item(running.identifier)?.state == .inProgress else {
                return finish(false, "after Clear the rows are \(rowNames()) \(dc.windowController.rows.map(\.visibleButtons)), want the running download only")
            }
            guard !dc.windowController.clearButton.isEnabled else { return finish(false, "Clear is on with nothing finished") }
            dc.windowController.rows[0].button("Cancel")?.performClick(nil)
            guard await until(10, { item(running.identifier)?.state == .canceled }) else { return finish(false, "Cancel did not end canceled") }
            try? await Task.sleep(for: .milliseconds(200))
            guard dc.windowController.rows.count == 1, dc.windowController.clearButton.isEnabled else { return finish(false, "the canceled row is not listed or Clear is off (rows \(rowNames()))") }
            dc.windowController.clearButton.performClick(nil)
            guard await until(3, { dc.windowController.rows.isEmpty && dc.items.isEmpty }) else { return finish(false, "Clear left \(rowNames())") }
            try? all.joined(separator: "\n").write(to: state, atomically: true, encoding: .utf8)
            finish(violations.isEmpty, "Remove took a canceled row only, Clear took the two complete rows and kept a running one (Pause, Cancel), then the canceled one; removed \(all) \(violations)")
            return
        }
        let removed = ((try? String(contentsOf: state, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        guard !removed.isEmpty else { return finish(false, "phase 1 left no state") }
        guard await ready() else { return }
        // The engine announces its restored items at startup: wait for the removed ids to be announced, so "they stay hidden" is judged on what came back.
        let ids = removed.compactMap { $0.split(separator: ":", omittingEmptySubsequences: false).first.flatMap { UInt32($0) } }
        let announced = await until(20, { Set(ids).isSubset(of: Set(NCDownloads.shared.items.map(\.identifier))) })
        let back = NCDownloads.shared.items.map { "\($0.identifier):\($0.suggestedName):\($0.state.rawValue)" }
        guard announced else { return finish(false, "the engine announced only \(back) after the relaunch, not all of the removed ids \(ids): nothing proves they stay hidden") }
        line("info", "removed in phase 1: \(removed); items the engine announced after the relaunch: \(back)")
        let again = removed.filter { r in dc.items.contains { r.hasPrefix("\($0.identifier):") } }
        try? await Task.sleep(for: .milliseconds(300))
        app.showDownloads(nil)
        guard await until(5, { dc.windowController.window.isVisible }) else { return finish(false, "no Downloads window") }
        let listed = rowNames()
        finish(again.isEmpty && listed.isEmpty && violations.isEmpty, "after the relaunch the engine announced its restored items (\(back)) and none of the \(removed.count) removed rows came back: came back \(again), the window lists \(listed) \(violations)")
    }

    /// Task 7b fix 1: a row in progress is never given up (a slow cancel is a live transfer), and a row whose end the controller drops never freezes.
    func dlCancelSlow() async {
        guard await ready(), let win, let tab = win.activeTab, let server = await startSlowServer(size: Self.slowSize) else { return }
        defer { server.stop() }
        guard let running = await startSlow(tab, server: server, minBytes: 100_000) else { return }
        app.showDownloads(nil)
        guard await until(5, { dc.windowController.rows.count == 1 }) else { return finish(false, "no row for the running download (\(rowNames()))") }
        // A Cancel the engine has not landed: after the grace the row is still listed, in progress.
        dc.holdCancel = true
        dc.windowController.rows[0].button("Cancel")?.performClick(nil)
        var vanished = false  // sampled: a row that left and came back with the next update would pass a look at the end
        let end = Date().addingTimeInterval(DownloadsController.cancelGrace + 1)
        while Date() < end { if dc.items.isEmpty { vanished = true }; try? await Task.sleep(for: .milliseconds(25)) }
        guard !vanished, dc.windowController.rows.count == 1, item(running.identifier)?.state == .inProgress, dc.windowController.rows[0].visibleButtons == ["Pause", "Cancel"] else {
            return finish(false, "a slow cancel hid or changed a live download (hidden at some point: \(vanished)): rows \(rowNames()) \(dc.windowController.rows.map(\.visibleButtons)), state \(item(running.identifier)?.state.rawValue ?? -1)")
        }
        dc.holdCancel = false
        NCDownloads.shared.cancel(running.identifier)
        guard await until(10, { item(running.identifier)?.state == .canceled }), await until(3, { dc.windowController.rows.first?.visibleButtons == ["Remove"] }) else {
            return finish(false, "the late cancel did not end the row canceled (state \(item(running.identifier)?.state.rawValue ?? -1), rows \(rowNames()))")
        }
        dc.windowController.rows[0].button("Remove")?.performClick(nil)
        guard dc.windowController.rows.isEmpty else { return finish(false, "Remove left \(rowNames())") }
        // A row given up while it runs comes back with its next progress update, and the key is forgotten: its end lists (canceled, with Remove), it is never frozen.
        guard let second = await startSlow(tab, server: server, minBytes: 100_000) else { return }
        guard await until(5, { dc.windowController.rows.count == 1 }), let live = item(second.identifier) else { return finish(false, "no row for the second download") }
        dc.giveUp(live)
        guard dc.windowController.rows.isEmpty else { return finish(false, "giveUp left the row \(rowNames())") }
        guard await until(10, { dc.windowController.rows.count == 1 }) else { return finish(false, "the running download did not show again with its next update") }
        NCDownloads.shared.cancel(second.identifier)
        guard await until(10, { NCDownloads.shared.items.first { $0.identifier == second.identifier }?.state == .canceled }) else { return finish(false, "the second cancel did not land in the engine") }
        guard await until(3, { dc.windowController.rows.first?.visibleButtons == ["Remove"] }), dc.windowController.rows.count == 1 else {
            return finish(false, "the end of a download given up while it ran did not list as canceled with Remove: rows \(rowNames()) \(dc.windowController.rows.map(\.visibleButtons))")
        }
        dc.windowController.rows[0].button("Remove")?.performClick(nil)
        guard dc.windowController.rows.isEmpty, dc.items.isEmpty else { return finish(false, "Remove left \(rowNames())") }
        finish(violations.isEmpty, "a Cancel the engine had not landed left the live row listed after the grace, the late cancel ended it canceled with Remove; a row given up while running came back with its next update and its end listed as canceled with Remove, not frozen \(violations)")
    }

    /// Task 5 Minor 3 and Task 6 Minor 10: with no browser window key (a History, Bookmarks or Downloads window is key), links open in the browser window
    /// that was key most recently, not the newest window. Hidden windows are never key, so the window notification is posted by hand.
    func windowRecency() async {
        guard await ready(), let a = ctl else { return }
        for path in ["b.html", "link.html"] {
            let before = loads
            app.newWindow(url: fixture(path))
            guard await until(20, { loads > before }) else { return finish(false, "the window at \(path) did not load") }
        }
        guard app.controllers.count == 3 else { return finish(false, "\(app.controllers.count) windows, want 3") }
        let b = app.controllers[1], c = app.controllers[2]
        func becomeKey(_ w: BrowserWindowController) { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w.nsWindow) }
        func which(_ w: BrowserWindowController?) -> String { w === a ? "A" : w === b ? "B" : w === c ? "C" : "none" }
        guard app.controllers.allSatisfy({ $0.nsWindow?.isKeyWindow != true }) else { return finish(false, "a window is key in a hidden run") }
        guard app.active === c else { return finish(false, "no window was key yet and the active window is \(which(app.active)), want the newest (C)") }
        becomeKey(c); becomeKey(a); becomeKey(b)  // B was key last; then a non-browser window takes the key, so none of A, B, C is key
        guard app.active === b else { return finish(false, "B was key last but the active window is \(which(app.active)) (the newest is C)") }
        let tabs = app.controllers.map { $0.window.tabs.count }
        app.openHistoryURL(fixture("link.html"))
        guard await until(10, { app.controllers[1].window.tabs.count == tabs[1] + 1 }) else { return finish(false, "a History link did not open in B (tabs per window \(app.controllers.map { $0.window.tabs.count }), was \(tabs))") }
        guard app.controllers[0].window.tabs.count == tabs[0], app.controllers[2].window.tabs.count == tabs[2] else { return finish(false, "the History link also opened a tab elsewhere: \(app.controllers.map { $0.window.tabs.count }), was \(tabs)") }
        // The window that was key last closes: the one before it is next (A), not the newest (C).
        b.close()
        guard await until(15, { app.controllers.count == 2 }) else { return finish(false, "window B did not close") }
        guard app.active === a else { return finish(false, "after B closed the active window is \(which(app.active)), want A (key before B; the newest is C)") }
        finish(violations.isEmpty, "with no browser window key the active window follows the last key one (B, though C is newest), a History link opened a tab in B only, and after B closed the previous one (A) is next \(violations)")
    }

    /// Task 7a Minor 2: a History window in the Dock misses the changes made meanwhile (they are skipped while it is not visible), so it reloads when it
    /// comes back and when it becomes key. A hidden run never miniaturizes (the Dock animation): the window is taken off screen and the window's own
    /// notifications are posted by hand, the way window-recency posts didBecomeKey.
    func historyDock() async {
        guard await ready() else { return }
        seed("http://dock.test/before", "Before the Dock", ago: 60)
        app.showHistory(nil)
        guard await until(5, { hist.window.isVisible }) else { return finish(false, "the History window did not show") }
        func titles() -> [String] { hist.entries.compactMap { if case .visit(let v) = $0 { v.title } else { nil } } }
        guard titles().contains("Before the Dock") else { return finish(false, "the window lacks the first visit (\(titles()))") }
        func away(_ title: String, _ url: String) async -> Bool {
            hist.window.orderOut(nil)  // what the Dock does to isVisible
            seed(url, title, ago: 1)
            NotificationCenter.default.post(name: HistoryWindowController.changed, object: nil)
            try? await Task.sleep(for: .milliseconds(600))  // longer than the 0.25 s refresh: a visible window would have reloaded by now
            return !titles().contains(title)
        }
        guard await away("Left in the Dock", "http://dock.test/dock") else { return finish(false, "a window that is not visible reloaded at once (\(titles())), so the check proves nothing") }
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: hist.window)
        guard await until(2, { titles().contains("Left in the Dock") }) else { return finish(false, "back from the Dock the window still lacks the visit made meanwhile (\(titles()))") }
        guard await away("Left behind a key change", "http://dock.test/key") else { return finish(false, "a window that is not visible reloaded at once (\(titles()))") }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hist.window)
        guard await until(2, { titles().contains("Left behind a key change") }) else { return finish(false, "when it became key the window still lacks the visit made meanwhile (\(titles()))") }
        hist.window.close()
        finish(violations.isEmpty, "changes made while the History window was off screen showed after it came back from the Dock and after it became key \(violations)")
    }

    /// Task 5 Minor 4: the 500-visit cap says so on its last line (search is capped too, and says so), a search reaches older visits, and a live refresh keeps
    /// the selection and the scroll position.
    func historyCap() async {
        guard await ready(), let win, let tab = win.activeTab, let store = app.writer?.store, let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        guard await until(10, { page(store, host: host, path: "/")?.title == "Noche App Fixture" }) else { return finish(false, "the startup page is not stored") }
        let now = Date()
        for i in 0..<520 { try? store.recordVisit(url: "http://seed.test/p\(i)", title: "Seed \(i)", typed: false, at: now.addingTimeInterval(-Double(i) - 1)) }
        app.showHistory(nil)
        guard await until(5, { hist.window.isVisible }) else { return finish(false, "the History window did not show") }
        func visits() -> [HistoryVisit] { hist.entries.compactMap { if case .visit(let v) = $0 { v } else { nil } } }
        func note() -> String? { hist.entries.compactMap { if case .note(let n) = $0 { n } else { nil } }.first }
        func find(_ q: String) { hist.search.stringValue = q; _ = hist.search.sendAction(hist.search.action, to: hist.search.target) }
        let want = "Showing the 500 most recent visits. Search to find older ones."
        guard visits().count == 500, note() == want, case .note(let last)? = hist.entries.last, last == want else {
            return finish(false, "\(visits().count) visits, last line \(String(describing: hist.entries.last)), want 500 and the note \"\(want)\"")
        }
        guard !visits().contains(where: { $0.title == "Seed 519" }), visits().contains(where: { $0.title == "Seed 0" }) else { return finish(false, "the 500 are not the newest ones") }
        // Search is capped the same way: it says so in its own words; a narrower search reaches the older visit and has no note.
        find("seed.test")
        let capped = (visits().count, note())
        find("Seed 519")
        let older = (visits().map(\.title), note())
        find("Seed 5")  // Seed 5, 50 to 59 and 500 to 519: 31 matches
        let few = (visits().count, note())
        guard capped.0 == 500, capped.1 == "Showing the 500 most recent matches. Narrow the search to find older ones.", older.0 == ["Seed 519"], older.1 == nil, few.0 == 31, few.1 == nil else {
            return finish(false, "search: \(capped), \(older), \(few)")
        }
        find("")
        // Live refresh keeps the selection and the scroll position.
        guard let row = hist.entries.firstIndex(where: { if case .visit(let v) = $0 { v.title == "Seed 300" } else { false } }) else { return finish(false, "no Seed 300 row") }
        hist.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        hist.table.scrollRowToVisible(row)
        hist.window.contentView?.layoutSubtreeIfNeeded()
        guard let clip = hist.table.enclosingScrollView?.contentView else { return finish(false, "no scroll view") }
        let topBefore = clip.bounds.origin.y
        guard topBefore > 1000 else { return finish(false, "the table did not scroll to row \(row) (offset \(topBefore))") }
        let loadsBefore = loads
        tab.loadURL(fixture("b.html"))
        guard await until(15, { loads > loadsBefore }), await until(5, { visits().first?.url.hasSuffix("/b.html") == true }) else {
            return finish(false, "the new visit did not appear behind the open window (first row \(visits().first?.url ?? "nil"))")
        }
        let r = hist.table.selectedRow
        guard r >= 0, r < hist.entries.count, case .visit(let kept) = hist.entries[r], kept.title == "Seed 300" else { return finish(false, "the live refresh lost the selection (row \(r))") }
        guard abs(clip.bounds.origin.y - topBefore) <= 1 else { return finish(false, "the live refresh moved the scroll position from \(topBefore) to \(clip.bounds.origin.y)") }
        hist.window.close()
        finish(violations.isEmpty, "520 seeded visits: the list stops at 500 newest with the last line \"\(want)\"; search is capped too (500 matches say so, \"Seed 519\" finds the oldest, 31 matches have no note); a live refresh kept Seed 300 selected at scroll offset \(Int(topBefore)) \(violations)")
    }

    /// Ruling M41 (b): a window that closes keeps the title its tab held back. Each tab's close confirmation flushes it (or the window close does).
    func titleWindowClose() async {
        guard await ready(), let store = app.writer?.store, let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        let before = loads
        app.newWindow(url: fixture("link.html"))
        guard await until(20, { loads > before && app.controllers.count == 2 }), let c = app.controllers.last, let tab = c.window.activeTab else { return finish(false, "the second window did not load") }
        guard await until(10, { page(store, host: host, path: "/link.html")?.title == "Link Page" }) else { return finish(false, "link.html was not stored with its title") }
        // A fresh throttle with an interval far past this check's length: W1 writes at once (nothing was written under it), and the timer can never write W2,
        // so only the close-time flush can have.
        c.titleThrottle = TitleThrottle(interval: 120)
        _ = await evaluate(tab, "document.title = 'W1'")
        guard await until(3, { page(store, host: host, path: "/link.html")?.title == "W1" }) else { return finish(false, "W1 was not written at once") }
        _ = await evaluate(tab, "document.title = 'W2'")
        try? await Task.sleep(for: .milliseconds(150))
        guard page(store, host: host, path: "/link.html")?.title == "W1" else { return finish(false, "W2 was not held back (stored \(page(store, host: host, path: "/link.html")?.title ?? "nil"))") }
        c.close()
        guard await until(15, { app.controllers.count == 1 }) else { return finish(false, "the second window did not close") }
        guard await until(1, { page(store, host: host, path: "/link.html")?.title == "W2" }) else {
            return finish(false, "the window closed with W2 held and the store has \(page(store, host: host, path: "/link.html")?.title ?? "nil")")
        }
        finish(violations.isEmpty, "a window closed with its tab's title W2 held back (W1 stored) and W2 was stored \(violations)")
    }
}
#endif
