#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// M1.5 final fix 4: the card's Remove undone, the Downloads list's file checks off the main thread, the bar's keys against a late hand-back.
extension SelfTest {
    // MARK: bm-remove-undo

    /// Cmd+D then Remove takes every copy of the page (two in the bar, one in Other Bookmarks); Edit > Undo puts all three back in their folders and positions.
    func bmRemoveUndo() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store, let ed = editor, let bar = barRoot(), let other = otherRoot() else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        let page = ctl.shownURL(tab), key = pageKey(page)
        func copies() -> [Bookmark] { ((try? store.urlBookmarks()) ?? []).filter { pageKey($0.url ?? "") == key } }
        func layout() -> String {
            func titles(_ r: Bookmark) -> String { ((try? store.bookmarkChildren(of: r.id)) ?? []).map(\.title).joined(separator: ", ") }
            return "bar [\(titles(bar))] other [\(titles(other))]"
        }
        addMark("First", fixture("a.html"))
        guard cmdD(), await until(5, { !ed.isHidden && copies().count == 1 }) else { return finish(false, "Cmd+D did not add the page (copies \(copies().count))") }
        ed.done.performClick(nil)
        addMark("Twin", page)
        addMark("Last", fixture("b.html"))
        addMark("O1", fixture("c.html"), in: other)
        addMark("Far copy", page, in: other)
        addMark("O2", fixture("d.html"), in: other)
        let before = layout()
        guard copies().count == 3 else { return finish(false, "before Remove: \(copies().count) copies, want 3 (\(before))") }
        guard cmdD(), await until(5, { !ed.isHidden && { if case .edit = ed.mode { return true } else { return false } }() }) else { return finish(false, "the second Cmd+D showed no edit card") }
        ed.remove.performClick(nil)
        guard await until(3, { copies().isEmpty }) else { return finish(false, "Remove left \(copies().count) copies: \(layout())") }
        let removed = layout()
        guard NSApp.sendAction(NSSelectorFromString("undo:"), to: ctl, from: nil) else { return finish(false, "Edit > Undo reached nothing after Remove") }
        guard await until(3, { layout() == before }) else { return finish(false, "after Undo the folders hold \(layout()), want \(before) (after Remove: \(removed))") }
        guard !ctl.bookmarkUndo.canUndo else { return finish(false, "one Remove left more than one undo action") }
        finish(violations.isEmpty, "Remove took 3 copies of the page in two folders, one Undo brought them back in place: \(before) \(violations)")
    }

    // MARK: cb-reopen-late

    /// The engine's hand-back to the page lands 1 s after Escape (past the 0.75 s guard): a bar opened right after the close keeps the keys. What holds them
    /// is the guard (it waits for the engine's report that the page got the keys); the OnSetFocus refusal of the late system SetFocus is a counted extra.
    func cbReopenLate() async {
        guard await ready(), let ctl else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        setenv("NOCHE_TEST_HANDBACK_DELAY_MS", "1000", 1)
        defer { unsetenv("NOCHE_TEST_HANDBACK_DELAY_MS") }
        let w: NCWindow = ctl.window
        let system0 = w.testFocusSystemRequests, refused0 = w.testFocusRefused
        for round in 1...2 {
            guard await openBar() else { return finish(false, "round \(round): no bar") }
            press(.escape)
            guard await until(5, { !barOpen() && inPage() }) else { return finish(false, "round \(round): Escape did not close the bar and give the page the keys") }
            cmdL()
            guard await until(5, { barOpen() && ctl.nsWindow?.firstResponder === barEditor }) else { return finish(false, "round \(round): the bar did not open with the keys") }
            try? await Task.sleep(for: .milliseconds(1500))  // the late hand-back landed at 1000 ms
            guard barOpen(), barEditor != nil, ctl.nsWindow?.firstResponder === barEditor, !inPage() else {
                return finish(false, "round \(round): the engine's hand-back 1 s late took the keys from the bar (bar open \(barOpen()), in page \(inPage()), editor \(barEditor != nil), system focus requests \(w.testFocusSystemRequests - system0), refused \(w.testFocusRefused - refused0))")
            }
        }
        typeText("zq")
        guard await until(3, { barText.hasSuffix("zq") || barText == "zq" }) else { return finish(false, "typing after the late hand-back did not land in the bar: text '\(barText)', in page \(inPage())") }
        let system = w.testFocusSystemRequests - system0, refused = w.testFocusRefused - refused0
        guard refused >= 1 else { return finish(false, "no engine focus request was refused (system requests \(system), refused \(refused)): the keys were kept some other way") }
        // The cap (ruling M63): once the engine has reported the hand-back (a hidden window gets no report, so the check delivers it) the guard ends with its 0.75 s span,
        // and a page that takes the focus 1.3 s after the reopen is the person's page: the keys go to it. A guard that ran to its 3 s cap whatever the engine reported
        // (the pair's switch) would pull them back into the bar.
        unsetenv("NOCHE_TEST_HANDBACK_DELAY_MS")
        closeBarNow()
        guard await openBar() else { return finish(false, "cap variant: no bar") }
        press(.escape)
        guard await until(5, { !barOpen() && inPage() }) else { return finish(false, "cap variant: Escape did not close the bar and give the page the keys") }
        cmdL()
        w.testReportGotFocus()  // the engine's report of the hand-back that Escape made
        guard await until(5, { barOpen() && ctl.nsWindow?.firstResponder === barEditor }) else { return finish(false, "cap variant: the bar did not reopen with the keys") }
        try? await Task.sleep(for: .milliseconds(1300))
        w.focusActiveContent()  // the page takes the focus
        guard await until(5, { inPage() }) else { return finish(false, "cap variant: a page focus grab 1.3 s after the reopen did not get the keys (in page \(inPage()), editor \(barEditor != nil))") }
        try? await Task.sleep(for: .milliseconds(700))
        guard inPage(), ctl.nsWindow?.firstResponder !== barEditor else { return finish(false, "cap variant: the guard took the keys back from the page 0.7 s after the grab (in page \(inPage()), the hand-back was reported: \(w.lastGotFocus > 0)): it ran past the engine's report") }
        finish(violations.isEmpty, "Escape then Cmd+L twice with the hand-back 1 s late: the bar kept the keys 1.5 s on and typing landed in it; the engine asked \(system) times from the system, \(refused) refused; with a prompt hand-back a page focus grab 1.3 s after the reopen gets the keys and keeps them \(violations)")
    }

    // MARK: dl-file-stats

    /// 200 complete rows on one show: each file is checked once, off the main thread, and only the row whose file is gone says so; an item that changes
    /// checks its row once; the next show checks each row once more.
    func dlFileStats() async {
        guard await ready() else { return }
        let dir = Self.downloadFolder.appendingPathComponent("stats-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func path(_ n: Int) -> String { dir.appendingPathComponent("f\(n).bin").path }
        func item(_ n: Int) -> NCDownloadItem { NCDownloadItem.testItem(identifier: UInt32(5000 + n), name: "f\(n).bin", path: path(n), state: .complete) }
        for n in 1...200 where n != 137 { FileManager.default.createFile(atPath: path(n), contents: Data([1])) }
        for n in 1...200 { dc.downloads(NCDownloads.shared, didUpdate: item(n)) }
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        DownloadsWindowController.statCalls = 0
        DownloadsWindowController.statOffMain = 0
        app.showDownloads(nil)
        let wc = dc.windowController
        guard await until(10, { wc.rows.count == 200 && DownloadsWindowController.statCalls >= 200 }) else { return finish(false, "200 rows not shown or checked: rows \(wc.rows.count), stats \(DownloadsWindowController.statCalls)") }
        await settle()
        let first = DownloadsWindowController.statCalls, off = DownloadsWindowController.statOffMain
        line("info", "one show of 200 complete rows: \(first) stat calls, \(off) off the main thread")
        guard first == 200, off == 200 else { return finish(false, "one show of 200 complete rows made \(first) stat calls, \(off) of them off the main thread, want 200 and 200") }
        let gone = wc.rows.filter { $0.fileMissing }.map(\.nameField.stringValue)
        guard gone == ["f137.bin"], wc.rows.first(where: { $0.nameField.stringValue == "f137.bin" })?.visibleButtons == ["Remove"], wc.rows.filter({ !$0.fileMissing }).allSatisfy({ $0.visibleButtons == ["Open", "Show in Finder", "Remove"] }) else {
            return finish(false, "rows that say File not found: \(gone), want only f137.bin with Remove")
        }
        // An item that changes (a new object for the same download) checks its own row once, and a file deleted meanwhile shows.
        try? FileManager.default.removeItem(atPath: path(5))
        dc.downloads(NCDownloads.shared, didUpdate: item(5))
        guard await until(5, { wc.rows.first(where: { $0.nameField.stringValue == "f5.bin" })?.fileMissing == true }) else { return finish(false, "a changed item did not check its row: f5.bin still found") }
        await settle()
        guard DownloadsWindowController.statCalls == first + 1 else { return finish(false, "one changed item made \(DownloadsWindowController.statCalls - first) stat calls, want 1") }
        // The next show checks each row once more (a file back in place shows again).
        FileManager.default.createFile(atPath: path(137), contents: Data([1]))
        let beforeShow = DownloadsWindowController.statCalls
        wc.show()
        guard await until(10, { DownloadsWindowController.statCalls >= beforeShow + 200 }) else { return finish(false, "the second show checked \(DownloadsWindowController.statCalls - beforeShow) rows, want 200") }
        await settle()
        let second = DownloadsWindowController.statCalls - beforeShow
        guard second == 200 else { return finish(false, "the second show made \(second) stat calls, want 200") }
        guard wc.rows.filter({ $0.fileMissing }).map(\.nameField.stringValue) == ["f5.bin"] else { return finish(false, "after the second show the rows that say File not found are \(wc.rows.filter { $0.fileMissing }.map(\.nameField.stringValue)), want f5.bin only") }
        finish(violations.isEmpty, "one show of 200 complete rows made \(first) stat calls, all off the main thread; one changed item 1; the next show 200; the missing file read File not found with Remove only \(violations)")
    }
}
#endif
