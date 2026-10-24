#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Persistence checks. Names ending in `-relaunch` run twice on one profile (scripts/app-test.sh: phase 1 on a wiped profile,
/// phase 2 on the same one); each phase prints its own `pass` line and the check passes only if both did.
extension SelfTest {
    /// Phase 1 opens 3 tabs; chromium-restore-relaunch then quits normally, chromium-restore-crash-relaunch prints phase1-ready
    /// and waits for scripts/app-test.sh to SIGKILL it. Phase 2 counts what the engine brought back by itself, before Noche
    /// restores anything. Since the store restores windows (M1.2) phase 2 expects the 3 tabs phase 1 left, each exactly once (a Chromium
    /// restore on top of Noche's would make 6). NOCHE_TEST_RESTORE_EXPECT=N (negative control) expects N tabs instead of 3.
    func chromiumRestoreRelaunch() async {
        if phase == 1 {
            guard await ready(), await openTabs(3) else { return finish(false, "phase 1: 3 tabs did not load (rows=\(rowCount))") }
            try? await Task.sleep(for: .seconds(2))  // let the engine's session writer see them
            if check.hasSuffix("-crash-relaunch") { return line("info", "phase1-ready: 3 tabs loaded, waiting to be killed") }
            return finish(violations.isEmpty, "phase 1: 3 tabs open, quitting normally \(violations)")
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Noche Test/Cache")
        // The profile phase 1 left: phase 2 on a wiped profile would pass for the wrong reason.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        guard left.contains("Default") || left.contains("Local State") else { return finish(false, "phase 2: no profile left by phase 1 (\(left))") }
        // Restored tabs and windows arrive after the first load: wait until the counts hold still for 3 s (cap 15 s).
        let (tabs, windows) = await settledCounts()
        let want = Int(ProcessInfo.processInfo.environment["NOCHE_TEST_RESTORE_EXPECT"] ?? "") ?? 3
        let detail = "phase 2: engine tabs=\(tabs) NSWindows=\(windows) controllers=\(app.controllers.count) profile=\(left.count) entries"
        guard tabs == want, windows == 1, app.controllers.count == 1 else { return finish(false, "\(detail), want \(want) tabs, 1, 1") }
        finish(violations.isEmpty, "\(detail) \(violations)")
    }

    // MARK: M1.2 persistence checks

    /// The frames persist-relaunch asks for, x >= 300 on the primary screen (macOS moves windows that start under about 240 pt).
    static let persistFrames = [NSRect(x: 300, y: 200, width: 900, height: 700), NSRect(x: 520, y: 260, width: 1000, height: 600)]

    /// (engine tabs, own NSWindows) once both hold still for |quiet| s (cap 15 s): a late restore by the engine would show up here.
    func settledCounts(quiet: Double = 3) async -> (tabs: Int, windows: Int) {
        func counts() -> (Int, Int) { (app.windows.reduce(0) { $0 + $1.tabs.count }, ownWindows()) }
        var last = counts(), since = Date()
        let end = Date().addingTimeInterval(15)
        while Date() < end, Date().timeIntervalSince(since) < quiet {
            try? await Task.sleep(for: .milliseconds(100))
            let now = counts()
            if now != last { last = now; since = Date() }
        }
        return last
    }

    func urls(_ c: BrowserWindowController) -> [String] { c.list.items.map(\.url) }
    func activeIndex(_ c: BrowserWindowController) -> Int? { c.list.items.firstIndex { $0.id == c.list.activeID } }
    var storeDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Noche Test/Store") }

    /// File > Reopen Closed Tab as the live menu has it, and whether it is enabled after the menu validated it.
    func reopenItem() -> NSMenuItem? {
        func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items { if i.title == "Reopen Closed Tab" { return i }; if let s = i.submenu, let f = find(s) { return f } }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }
    var reopenEnabled: Bool { reopenItem().map { $0.menu?.update(); return $0.isEnabled } ?? false }
    /// One query against the live store file through the sqlite3 CLI (read only), the way scripts/app-test.sh checks it.
    func sqlite(_ sql: String) -> String {
        guard let url = app.storeURL else { return "" }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", url.path, sql]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var lastActiveFile: URL { storeDir.deletingLastPathComponent().appendingPathComponent("lastactive.txt") }
    func shiftCmdT() { key("t", code: 17, [.command, .shift]) }

    /// Controllers restored, each with its window up and every saved tab added.
    func restoredUp(_ n: Int) -> Bool { app.controllers.count == n && app.controllers.allSatisfy { !$0.restoring && $0.nsWindow != nil } }

    func persistRelaunch() async {
        let a = fixture(""), b = fixture("b.html"), l = fixture("link.html"), f = fixture("favicon.html")
        let want = [[a, b, l], [b, a, l, f]], active = [1, 3]
        if phase == 1 {
            guard await ready(), let c1 = ctl else { return }
            _ = c1.window.addTab(withURL: b, activate: false); _ = c1.window.addTab(withURL: l, activate: false)
            let second = app.newWindow(url: b, frame: SelfTest.persistFrames[1])
            guard let c2 = app.controllers.last, c2.window === second else { return finish(false, "no second window") }
            guard await until(20, { c2.nsWindow != nil && c2.list.items.count == 1 }) else { return finish(false, "second window has no tab") }
            for u in [a, l, f] { _ = second.addTab(withURL: u, activate: false) }
            guard await until(20, { self.urls(c1) == want[0] && self.urls(c2) == want[1] }) else {
                return finish(false, "phase 1: tab urls \(urls(c1)) and \(urls(c2)), want \(want)")
            }
            // The favicon address and the sidebar width reach the store (the favicon page is tab 4 of window 2).
            guard await until(15, { second.tabs[safe: 3]?.faviconURL != nil }), let writer = app.writer else { return finish(false, "phase 1: no favicon address for favicon.html") }
            writer.flush()
            let icons = sqlite("SELECT count(*) FROM tab WHERE url LIKE '%favicon.html' AND faviconURL IS NOT NULL"), widths = sqlite("SELECT count(*) FROM window WHERE sidebarWidth IS NOT NULL")
            guard icons == "1", widths == "2" else { return finish(false, "phase 1: stored favicon rows \(icons) (want 1), windows with a sidebarWidth \(widths) (want 2)") }
            c1.window.activateTab(c1.window.tabs[active[0]]); second.activateTab(second.tabs[active[1]])
            guard await until(10, { self.activeIndex(c1) == active[0] && self.activeIndex(c2) == active[1] }) else {
                return finish(false, "phase 1: active tabs \(String(describing: activeIndex(c1))) and \(String(describing: activeIndex(c2)))")
            }
            // The lastActiveAt values phase 2 must read back unchanged (a restore is not a use of the tab): taken from the store file itself.
            writer.flush()
            let stamps = sqlite("SELECT id || '=' || lastActiveAt FROM tab WHERE closedAt IS NULL AND deletedAt IS NULL ORDER BY id")
            guard stamps.split(separator: "\n").count == 7 else { return finish(false, "phase 1: the store holds \(stamps.split(separator: "\n").count) tab stamps, want 7") }
            try? stamps.write(to: lastActiveFile, atomically: true, encoding: .utf8)
            // The last change, then the quit at once: the debounced save is still pending and the quit flush must write it.
            c1.nsWindow?.setFrame(SelfTest.persistFrames[0], display: false); c2.nsWindow?.setFrame(SelfTest.persistFrames[1], display: false)
            return finish(violations.isEmpty, "phase 1: 2 windows with 3 and 4 tabs, active 2 and 4, frames set, quitting at once \(violations)")
        }
        guard await until(20, { self.restoredUp(2) }) else { return finish(false, "phase 2: \(app.controllers.count) windows restored, want 2 (restored rows \(app.restored.count))") }
        let (tabs, windows) = await settledCounts()
        var bad: [String] = []
        if windows != 2 || app.controllers.count != 2 { bad.append("NSWindows=\(windows) controllers=\(app.controllers.count), want 2 (extra window)") }
        if tabs != 7 { bad.append("engine tabs=\(tabs), want 7 (double restore?)") }
        for (i, c) in app.controllers.enumerated() {
            let ns = c.nsWindow, r = SelfTest.persistFrames[i]
            _ = await until(5, { self.near(ns?.frame, r.minX, r.minY, r.width, r.height) })
            if !near(ns?.frame, r.minX, r.minY, r.width, r.height) { bad.append("window \(i + 1) frame \(String(describing: ns?.frame)), want \(r)") }
            if urls(c) != want[i] { bad.append("window \(i + 1) urls \(urls(c))") }
            if activeIndex(c) != active[i] { bad.append("window \(i + 1) active \(String(describing: activeIndex(c))), want \(active[i])") }
            if c.window.tabs.count != want[i].count || c.sidebar.rows.count != want[i].count { bad.append("window \(i + 1) engine tabs \(c.window.tabs.count) rows \(c.sidebar.rows.count), want \(want[i].count)") }
            if app.restored[safe: i]?.tabs.count != want[i].count || app.restored[safe: i]?.isFullScreen != false { bad.append("window \(i + 1) stored \(String(describing: app.restored[safe: i]?.tabs.count)) tabs, full screen \(String(describing: app.restored[safe: i]?.isFullScreen))") }
            if ns?.styleMask.contains(.fullScreen) == true { bad.append("window \(i + 1) is in full screen") }  // a hidden window must never take a Space
        }
        // A save after the restore must keep the saved lastActiveAt, favicon address and sidebar width.
        app.writer?.flush()
        let saved = ((try? String(contentsOf: lastActiveFile, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: "=") }
        let now = Dictionary(uniqueKeysWithValues: sqlite("SELECT id || '=' || lastActiveAt FROM tab WHERE closedAt IS NULL AND deletedAt IS NULL").split(separator: "\n").compactMap { l -> (String, Double)? in
            let p = l.split(separator: "="); return p.count == 2 ? (String(p[0]), Double(p[1]) ?? 0) : nil })
        if saved.count != 7 { bad.append("phase 1 left \(saved.count) lastActiveAt values, want 7") }
        for p in saved where p.count == 2 {
            if abs((now[String(p[0])] ?? 0) - (Double(p[1]) ?? -1)) > 1 { bad.append("lastActiveAt of \(p[0]) is \(now[String(p[0])] ?? 0), saved \(p[1])") }
        }
        if sqlite("SELECT count(*) FROM tab WHERE url LIKE '%favicon.html' AND faviconURL IS NOT NULL") != "1" { bad.append("favicon address lost across the relaunch") }
        if sqlite("SELECT count(*) FROM window WHERE sidebarWidth IS NOT NULL") != "2" { bad.append("sidebarWidth lost across the relaunch") }
        finish(bad.isEmpty && violations.isEmpty, "phase 2: 2 windows with frames within 1 pt, tab urls in order, active tabs 2 and 4, engine tabs equal rows (7, no extra NSWindow), lastActiveAt, favicon address and sidebarWidth kept \(bad) \(violations)")
    }

    func quitCloseRelaunch() async {
        if phase == 1 {
            guard await ready(), await openTabs(2) else { return }
            let setting = (try? app.writer?.store.setting("quitBehavior")) ?? nil
            return finish(setting == "close" && violations.isEmpty, "phase 1: 2 tabs open, quitBehavior=\(setting ?? "nil") (--selftest-setting), quitting \(violations)")
        }
        guard await until(15, { self.app.controllers.count == 1 && self.ctl?.nsWindow != nil && self.rowCount == 1 }) else {
            return finish(false, "phase 2: \(app.controllers.count) windows, \(rowCount) rows, want 1 and 1")
        }
        let (tabs, windows) = await settledCounts()
        let blank = ctl.map { urls($0) == ["about:blank"] } ?? false
        finish(tabs == 1 && windows == 1 && app.controllers.count == 1 && blank && app.restored.isEmpty && violations.isEmpty,
               "phase 2: quitBehavior=close left one window with one blank tab (engine tabs=\(tabs) NSWindows=\(windows) urls=\(ctl.map { urls($0) } ?? []) restored rows=\(app.restored.count)) \(violations)")
    }

    func reopenClosed() async {
        guard await ready(), let c = ctl, let win else { return }
        let a = fixture(""), b = fixture("b.html"), l = fixture("link.html")
        guard let item = reopenItem() else { return finish(false, "no Reopen Closed Tab menu item") }
        guard item.keyEquivalent == "t", item.keyEquivalentModifierMask == [.command, .shift] else { return finish(false, "wrong shortcut \(item.keyEquivalent) \(item.keyEquivalentModifierMask)") }
        _ = win.addTab(withURL: b, activate: false); _ = win.addTab(withURL: l, activate: false)
        guard await until(20, { self.urls(c) == [a, b, l] }) else { return finish(false, "urls \(urls(c))") }
        guard !reopenEnabled else { return finish(false, "item enabled with an empty closed list") }
        shiftCmdT()
        try? await Task.sleep(for: .milliseconds(500))
        guard urls(c) == [a, b, l], win.tabs.count == 3, app.controllers.count == 1 else { return finish(false, "the shortcut did something with an empty list: \(urls(c)) \(win.tabs.count)") }
        // A blank tab is never recorded as closed.
        cmdT()
        guard await until(10, { win.tabs.count == 4 && self.rowCount == 4 }) else { return finish(false, "Cmd+T made no tab") }
        cmdW()
        guard await until(10, { win.tabs.count == 3 && self.rowCount == 3 }) else { return finish(false, "Cmd+W closed no blank tab") }
        guard !reopenEnabled else { return finish(false, "a closed blank tab enabled Reopen Closed Tab") }
        win.activateTab(win.tabs[1])
        guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "tab B did not activate") }
        let idB = c.list.items[1].id
        cmdW()
        guard await until(10, { self.urls(c) == [a, l] && win.tabs.count == 2 }) else { return finish(false, "Cmd+W on B left \(urls(c))") }
        guard reopenEnabled else { return finish(false, "item disabled after closing B") }
        shiftCmdT()
        guard await until(15, { self.urls(c) == [a, b, l] && self.activeIndex(c) == 1 && win.tabs.count == 3 }) else {
            return finish(false, "Shift+Cmd+T gave \(urls(c)) active \(String(describing: activeIndex(c))) tabs \(win.tabs.count), want [A, B, C] with B active")
        }
        guard c.list.items[1].id == idB else { return finish(false, "B came back with a new tab id") }
        guard !reopenEnabled else { return finish(false, "item enabled after the only closed tab was reopened") }
        shiftCmdT()
        try? await Task.sleep(for: .milliseconds(500))
        guard urls(c) == [a, b, l], win.tabs.count == 3 else { return finish(false, "the shortcut did something with an empty list: \(urls(c))") }
        // The list is the order of record: the engine's strip is now [A, C, B], the list [A, B, C].
        win.activateTab(win.tabs[0])
        guard await until(10, { self.activeIndex(c) == 0 }) else { return finish(false, "A did not activate") }
        nextTab()
        guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "Next Tab from A selected row \(String(describing: activeIndex(c))), want B (row 2)") }
        win.activateTab(win.tabs[0])
        guard await until(10, { self.activeIndex(c) == 0 }) else { return finish(false, "A did not activate again") }
        cmdW()
        guard await until(10, { self.urls(c) == [b, l] && win.tabs.count == 2 && self.activeIndex(c) == 0 }) else { return finish(false, "Cmd+W on A left \(urls(c)) active \(String(describing: activeIndex(c))), want B active in [B, C]") }
        cmdW()
        guard await until(10, { self.urls(c) == [l] && win.tabs.count == 1 && self.activeIndex(c) == 0 }) else { return finish(false, "Cmd+W on B left \(urls(c)), want C active in [C]") }
        finish(violations.isEmpty, "A B C, Cmd+W on B, Shift+Cmd+T restores B at index 1 and active with its id; disabled and inert with an empty list, blank tabs never recorded; Next Tab and the Cmd+W successor follow the list order, not the engine strip \(violations)")
    }

    func reopenClosedRelaunch() async {
        let a = fixture(""), b = fixture("b.html"), l = fixture("link.html")
        if phase == 1 {
            guard await ready(), let c = ctl, let win else { return }
            _ = win.addTab(withURL: b, activate: false); _ = win.addTab(withURL: l, activate: false)
            guard await until(20, { self.urls(c) == [a, b, l] }) else { return finish(false, "urls \(urls(c))") }
            win.activateTab(win.tabs[1])
            guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "B did not activate") }
            cmdW()
            guard await until(10, { self.urls(c) == [a, l] && win.tabs.count == 2 }) else { return finish(false, "Cmd+W on B left \(urls(c))") }
            return finish(violations.isEmpty, "phase 1: B closed, quitting \(violations)")
        }
        guard await until(20, { self.restoredUp(1) }), let c = ctl, let win else { return finish(false, "phase 2: no restored window") }
        let (tabs, windows) = await settledCounts()
        guard urls(c) == [a, l], tabs == 2, windows == 1 else { return finish(false, "phase 2: urls \(urls(c)) engine tabs \(tabs) NSWindows \(windows)") }
        guard reopenEnabled else { return finish(false, "phase 2: Reopen Closed Tab disabled after a relaunch") }
        shiftCmdT()
        guard await until(15, { self.urls(c) == [a, b, l] && self.activeIndex(c) == 1 && win.tabs.count == 3 }) else {
            return finish(false, "phase 2: Shift+Cmd+T gave \(urls(c)) active \(String(describing: activeIndex(c)))")
        }
        finish(app.controllers.count == 1 && app.restored.first?.id == c.id && violations.isEmpty, "phase 2: after a relaunch Shift+Cmd+T restores B at index 1 in its original window, active \(violations)")
    }

    /// Phase 1 writes snapshot 1 (2 tabs, the first selected), arms the kill hook (NOCHE_TEST_KILL_AT=pending or in-transaction, set by
    /// scripts/app-test.sh) and makes the change that would be snapshot 2 (3 tabs, the third selected): the app SIGKILLs itself.
    func crashMidWrite() async {
        if phase == 1 {
            guard let kill = ProcessInfo.processInfo.environment["NOCHE_TEST_KILL_AT"], ["pending", "in-transaction"].contains(kill) else { return finish(false, "NOCHE_TEST_KILL_AT is not pending or in-transaction") }
            guard await ready(), await openTabs(2), let c = ctl, let win, let writer = app.writer else { return finish(false, "phase 1: no writer or window") }
            guard activeIndex(c) == 0 else { return finish(false, "phase 1: active tab is \(String(describing: activeIndex(c)))") }
            writer.flush()  // snapshot 1, synchronous and durable
            line("info", "phase1-ready: snapshot 1 written (2 tabs, first selected), killing at \(kill)")
            writer.armKill()
            _ = win.addTab(withURL: fixture("b.html"), activate: true)
            try? await Task.sleep(for: .seconds(10))
            return finish(false, "phase 1: the app was not killed at \(kill)")
        }
        guard await until(20, { self.restoredUp(1) }), let c = ctl, let snap = app.restored.first else { return finish(false, "phase 2: nothing restored") }
        let n = snap.tabs.count
        let sel = snap.selectedTabID.flatMap { id in snap.tabs.firstIndex { $0.id == id } }
        let which = n == 2 && sel == 0 ? "previous" : n == 3 && sel == 2 ? "new" : nil
        guard let which else { return finish(false, "phase 2: a mixed snapshot: \(n) tabs, selected index \(String(describing: sel))") }
        let (tabs, windows) = await settledCounts()
        guard tabs == n, windows == 1, urls(c).count == n, activeIndex(c) == sel else {
            return finish(false, "phase 2: restored \(which) snapshot but the window has engine tabs \(tabs), rows \(urls(c).count), active \(String(describing: activeIndex(c)))")
        }
        finish(violations.isEmpty, "phase 2: restored the \(which) snapshot whole (\(n) tabs, selected index \(sel ?? -1)) \(violations)")
    }

    /// Phase 2 runs after scripts/app-test.sh wrote garbage over the store file.
    func corruptStore() async {
        if phase == 1 {
            guard await ready(), await openTabs(2) else { return }
            return finish(violations.isEmpty, "phase 1: 2 tabs open, quitting \(violations)")
        }
        guard await until(15, { self.app.controllers.count == 1 && self.ctl?.nsWindow != nil && self.rowCount == 1 }) else {
            return finish(false, "phase 2: \(app.controllers.count) windows, \(rowCount) rows, want 1 and 1")
        }
        let (tabs, windows) = await settledCounts()
        let kept = ((try? FileManager.default.contentsOfDirectory(atPath: storeDir.path)) ?? []).filter { $0.hasPrefix("noche.sqlite.corrupt-") }
        finish(tabs == 1 && windows == 1 && !kept.isEmpty && app.restored.isEmpty && app.storeFallback == nil && violations.isEmpty,
               "phase 2: corrupt store quarantined (\(kept)), one window with one tab (engine tabs=\(tabs) NSWindows=\(windows)), real store reopened empty (fallback=\(app.storeFallback ?? "none")) \(violations)")
    }

    /// Shift+Cmd+T then Cmd+T in one run-loop turn, and a popup the page opens right after the reopen: the reopened row keeps its id and
    /// address, the other new tabs are not given them. B is favicon.html so it differs from the popup (b.html) and from the blank tab.
    func reopenIdentity() async {
        guard await ready(), let c = ctl, let win else { return }
        let a = fixture(""), f = fixture("favicon.html"), l = fixture("link.html"), b = fixture("b.html")
        _ = win.addTab(withURL: f, activate: false); _ = win.addTab(withURL: l, activate: false)
        guard await until(20, { self.urls(c) == [a, f, l] }) else { return finish(false, "urls \(urls(c))") }
        let idB = c.list.items[1].id
        win.activateTab(win.tabs[1])
        guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "B did not activate") }
        cmdW()
        guard await until(10, { self.urls(c) == [a, l] }) else { return finish(false, "Cmd+W on B left \(urls(c))") }
        shiftCmdT(); cmdT()   // one turn: the reopened tab and a Chrome-style new tab
        guard await until(15, { self.urls(c).count == 4 && win.tabs.count == 4 }) else { return finish(false, "after reopen and Cmd+T: \(urls(c))") }
        let row = c.list.items.first { $0.id == idB }
        let blank = c.list.items.filter { $0.id != idB && $0.url == "about:blank" }.count
        guard row?.url == f, urls(c) == [a, f, l, "about:blank"], blank == 1 else { return finish(false, "reopen and Cmd+T in one turn: \(urls(c)), reopened row \(String(describing: row?.url))") }
        // Now a popup between: close B again, reopen it, and let the page of C open b.html in a new tab.
        win.activateTab(win.tabs.first { $0.url == f } ?? win.tabs[1])
        guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "B did not activate again") }
        cmdW()
        guard await until(10, { self.urls(c) == [a, l, "about:blank"] }) else { return finish(false, "second Cmd+W on B left \(urls(c))") }
        guard let cTab = win.tabs.first(where: { $0.url == l }) else { return finish(false, "no tab on link.html") }
        shiftCmdT()
        _ = await evaluate(cTab, "document.getElementById('l').click()")
        guard await until(15, { self.urls(c).count == 5 && win.tabs.count == 5 }) else { return finish(false, "after reopen and popup: \(urls(c))") }
        let reopened = c.list.items.first { $0.id == idB }, popups = c.list.items.filter { $0.url == b }.count
        finish(reopened?.url == f && popups == 1 && violations.isEmpty, "reopened tab keeps its id and address with a Cmd+T and a popup around it (urls \(urls(c)), popups \(popups)) \(violations)")
    }

    /// 50 setFrame calls change the window row only: the tab rows stay byte for byte as they were.
    func frameStorm() async {
        guard await ready(), await openTabs(3), let ns = ctl?.nsWindow, let writer = app.writer else { return finish(false, "no window or writer") }
        writer.flush()
        try? await Task.sleep(for: .seconds(1))
        let tabsQuery = "SELECT id, updatedAt, position, url, title, lastActiveAt FROM tab ORDER BY id"
        let before = sqlite(tabsQuery), windowBefore = sqlite("SELECT updatedAt FROM window")
        guard before.split(separator: "\n").count == 3, !windowBefore.isEmpty else { return finish(false, "store holds \(before.split(separator: "\n").count) tab rows before the storm") }
        for i in 0..<50 { ns.setFrame(NSRect(x: 300, y: 200, width: 800 + CGFloat(i), height: 600), display: false) }
        guard await until(8, { Double(self.sqlite("SELECT w FROM window")) == 849 }) else { return finish(false, "window w is \(sqlite("SELECT w FROM window")) after the storm, want 849") }
        let after = sqlite(tabsQuery)
        finish(after == before && sqlite("SELECT updatedAt FROM window") != windowBefore && violations.isEmpty, "50 resizes updated the window row (w 849) and left the 3 tab rows untouched \(after == before ? "" : "tab rows changed: \(before) -> \(after)") \(violations)")
    }

    /// scripts/app-test.sh put a plain file where the Store directory belongs: the app opens one window on an in-memory store, logs it, and leaves the file alone.
    /// (also the unwritable variant: the Store directory is mode 555 around an existing store file, and nothing in it changes.)
    func storeUnavailable() async {
        guard await ready() else { return }
        app.writer?.flush()
        finish(app.storeFallback != nil && app.writer != nil && app.controllers.count == 1 && app.restored.isEmpty && violations.isEmpty,
               "store unavailable (\(app.storeFallback ?? "no fallback")): one window on an in-memory store, launch not blocked \(violations)")
    }

    /// Cmd+1 to Cmd+8 and Cmd+9 select by position in the list. After a reopen the list is [A, B, C] and the engine strip [A, C, B]:
    /// Cmd+2 and Cmd+3 differ between the two, and so does Cmd+9 (C in the list, B in the strip).
    func tabChords() async {
        guard await ready(), let c = ctl, let win else { return }
        let a = fixture(""), b = fixture("b.html"), l = fixture("link.html")
        _ = win.addTab(withURL: b, activate: false); _ = win.addTab(withURL: l, activate: false)
        guard await until(20, { self.urls(c) == [a, b, l] }) else { return finish(false, "urls \(urls(c))") }
        win.activateTab(win.tabs[1])
        guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "B did not activate") }
        cmdW()
        guard await until(10, { self.urls(c) == [a, l] && win.tabs.count == 2 }) else { return finish(false, "Cmd+W on B left \(urls(c))") }
        shiftCmdT()
        guard await until(15, { self.urls(c) == [a, b, l] && win.tabs.count == 3 }) else { return finish(false, "reopen gave \(urls(c))") }
        guard win.tabs[1].url != b else { return finish(false, "the strip is in list order, the check proves nothing: \(win.tabs.map(\.url))") }
        // The engine disables its own tab commands in this window, so the chords are Tabs menu items answered from the list; the key event goes to the main menu (menuOnly).
        let chords: [(String, UInt16, Int)] = [("1", 18, 0), ("2", 19, 1), ("3", 20, 2), ("9", 25, 2), ("2", 19, 1), ("1", 18, 0), ("9", 25, 2)]
        var trail: [Int] = []
        for (ch, code, want) in chords {
            guard key(ch, code: code, menuOnly: true) else { return finish(false, "Cmd+\(ch) was not handled by the window or the menu") }
            guard await until(5, { self.activeIndex(c) == want }) else {
                return finish(false, "Cmd+\(ch) selected list index \(String(describing: activeIndex(c))), want \(want) (list \(urls(c)), engine strip \(win.tabs.map(\.url)), after \(trail)) keys \(keyLog.suffix(2))")
            }
            trail.append(want)
        }
        finish(violations.isEmpty, "list [A, B, C] over engine strip [A, C, B]: Cmd+1, 2, 3 and Cmd+9 select list positions \(trail) \(violations)")
    }

    /// Ctrl+Shift+Page Down and Page Up (Chromium's own chords for IDC_MOVE_TAB_NEXT and _PREVIOUS on Linux and Windows; the engine disables the
    /// commands here, so Noche answers the keys): one step in the list, nothing at the ends, the sidebar and the store follow.
    func moveTabRelaunch() async {
        let a = fixture(""), b = fixture("b.html"), l = fixture("link.html")
        let titles = ["Noche App Fixture", "Link Page", "B Page"]
        if phase == 1 {
            guard await ready(), let c = ctl, let win else { return }
            _ = win.addTab(withURL: b, activate: false); _ = win.addTab(withURL: l, activate: false)
            guard await until(20, { self.urls(c) == [a, b, l] }) else { return finish(false, "urls \(urls(c))") }
            let down = "\u{F72D}", up = "\u{F72C}"
            func run(_ forward: Bool, select: Int, want: [String]) async -> String? {
                guard let pick = win.tabs.first(where: { $0.identifier == c.list.items[select].engineID }) else { return "no engine tab for list index \(select)" }
                win.activateTab(pick)
                guard await until(10, { self.activeIndex(c) == select }) else { return "tab \(select) did not activate" }
                guard key(forward ? down : up, code: forward ? 121 : 116, [.control, .shift], menuOnly: true) else { return "the chord was not handled" }
                guard await until(5, { self.urls(c) == want }) else { return "\(forward ? "next" : "previous") from \(select) gave \(urls(c)), want \(want)" }
                try? await Task.sleep(for: .milliseconds(300))  // a second move would show now
                return urls(c) == want ? nil : "\(forward ? "next" : "previous") from \(select) moved again: \(urls(c))"
            }
            let steps: [(Bool, Int, [String])] = [
                (false, 0, [a, b, l]), (true, 2, [a, b, l]),                         // at the ends: nothing
                (true, 1, [a, l, b]),                                                // B after C
                (true, 2, [a, l, b]),                                                // B is last now
                (false, 2, [a, b, l]), (true, 1, [a, l, b])]
            for (forward, select, want) in steps { if let bad = await run(forward, select: select, want: want) { return finish(false, "phase 1: \(bad)") } }
            win.activateTab(win.tabs.first { $0.url == b } ?? win.tabs[2])
            guard await until(10, { self.activeIndex(c) == 2 }) else { return finish(false, "phase 1: B not active at the end") }
            guard await until(5, { c.sidebar.rows.map(\.titleField.stringValue) == titles }) else { return finish(false, "phase 1: sidebar shows \(c.sidebar.rows.map(\.titleField.stringValue)), want \(titles)") }
            guard BrowserWindowController.actionCounts["moveTab"] == steps.count else { return finish(false, "phase 1: moveTab acted \(BrowserWindowController.actionCounts["moveTab"] ?? 0) times, want \(steps.count)") }
            return finish(violations.isEmpty, "phase 1: B moved after C by Ctrl+Shift+Page Down, ends are no-ops, sidebar [A, C, B], quitting at once \(violations)")
        }
        guard await until(20, { self.restoredUp(1) }), let c = ctl else { return finish(false, "phase 2: no restored window") }
        let (tabs, windows) = await settledCounts()
        guard urls(c) == [a, l, b], activeIndex(c) == 2, tabs == 3, windows == 1 else { return finish(false, "phase 2: urls \(urls(c)) active \(String(describing: activeIndex(c))) engine tabs \(tabs) NSWindows \(windows), want [A, C, B], 2, 3, 1") }
        guard await until(5, { c.sidebar.rows.map(\.titleField.stringValue) == titles }) else { return finish(false, "phase 2: sidebar shows \(c.sidebar.rows.map(\.titleField.stringValue)), want \(titles)") }
        finish(violations.isEmpty, "phase 2: the order [A, C, B] and B active survived the relaunch, sidebar shows it \(violations)")
    }
}
#endif
