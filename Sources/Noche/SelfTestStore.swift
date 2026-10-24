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
            c1.window.activateTab(c1.window.tabs[active[0]]); second.activateTab(second.tabs[active[1]])
            guard await until(10, { self.activeIndex(c1) == active[0] && self.activeIndex(c2) == active[1] }) else {
                return finish(false, "phase 1: active tabs \(String(describing: activeIndex(c1))) and \(String(describing: activeIndex(c2)))")
            }
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
        finish(bad.isEmpty && violations.isEmpty, "phase 2: 2 windows with frames within 1 pt, tab urls in order, active tabs 2 and 4, engine tabs equal rows (7, no extra NSWindow) \(bad) \(violations)")
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
        finish(urls(c) == [a, b, l] && win.tabs.count == 3 && violations.isEmpty, "A B C, Cmd+W on B, Shift+Cmd+T restores B at index 1 and active with its id; disabled and inert with an empty list, blank tabs never recorded \(violations)")
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
}
#endif
