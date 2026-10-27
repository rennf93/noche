#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// M1.5 final fix 5: the bar's keys against a late RequestFocus, the validity of the card's undo.
extension SelfTest {
    // MARK: cb-reopen-reqlate

    /// Only the engine's Views RequestFocus lands 1 s late; SetFocus (and whatever it reports) lands at once. A bar reopened right after the close keeps the keys
    /// when the late request comes, however the engine's reports were ordered before it.
    func cbReopenReqLate() async {
        guard await ready(), let ctl else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        setenv("NOCHE_TEST_REQFOCUS_DELAY_MS", "1000", 1)
        defer { unsetenv("NOCHE_TEST_REQFOCUS_DELAY_MS") }
        let w: NCWindow = ctl.window
        for round in 1...2 {
            guard await openBar() else { return finish(false, "round \(round): no bar") }
            let req0 = w.testRequestFocusCalls, set0 = w.testSetFocusCalls
            press(.escape)
            guard await until(5, { !barOpen() && inPage() }) else { return finish(false, "round \(round): Escape did not close the bar and give the page the keys") }
            cmdL()
            guard await until(5, { barOpen() && ctl.nsWindow?.firstResponder === barEditor }) else { return finish(false, "round \(round): the bar did not open with the keys") }
            // The seam delays the right call: SetFocus landed, RequestFocus has not.
            guard w.testSetFocusCalls == set0 + 1, w.testRequestFocusCalls == req0 else { return finish(false, "round \(round): the seam delayed the wrong call (SetFocus calls \(w.testSetFocusCalls - set0), RequestFocus calls \(w.testRequestFocusCalls - req0), want 1 and 0)") }
            try? await Task.sleep(for: .milliseconds(1600))
            guard w.testRequestFocusCalls == req0 + 1 else { return finish(false, "round \(round): the late RequestFocus never landed (calls \(w.testRequestFocusCalls - req0))") }
            guard barOpen(), barEditor != nil, ctl.nsWindow?.firstResponder === barEditor, !inPage() else {
                return finish(false, "round \(round): the late RequestFocus took the keys from the bar (bar open \(barOpen()), in page \(inPage()), editor \(barEditor != nil), got-focus report \(Int((w.lastGotFocus - w.lastFocusHandback) * 1000)) ms after the hand-back)")
            }
        }
        typeText("zq")
        guard await until(3, { barText.hasSuffix("zq") || barText == "zq" }) else { return finish(false, "typing after the late request did not land in the bar: text '\(barText)', in page \(inPage())") }
        finish(violations.isEmpty, "Escape then Cmd+L twice with only RequestFocus 1 s late: SetFocus landed at once, the late request landed and the bar kept the keys, typing landed in it \(violations)")
    }

    // MARK: bm-undo-valid

    /// Edit > Undo reads disabled in a fresh window, enabled after the card's Remove, and disabled again (restoring nothing) once the tree changed by any other
    /// path: a re-bookmark, a rename, a move, a new folder, a folder delete.
    func bmUndoValid() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store, let ed = editor, let bar = barRoot(), let other = otherRoot() else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        let page = ctl.shownURL(tab), key = pageKey(page)
        func copies() -> [Bookmark] { ((try? store.urlBookmarks()) ?? []).filter { pageKey($0.url ?? "") == key } }
        func menu(_ sel: String) -> NSMenuItem { NSMenuItem(title: sel, action: NSSelectorFromString(sel), keyEquivalent: "") }
        func enabled(_ sel: String) -> Bool { ctl.validateUserInterfaceItem(menu(sel)) }
        func undo() { _ = NSApp.sendAction(NSSelectorFromString("undo:"), to: ctl, from: nil) }
        guard !enabled("undo:"), !enabled("redo:") else { return finish(false, "in a fresh window Undo reads enabled \(enabled("undo:")), Redo \(enabled("redo:"))") }
        guard let keep = addMark("Keep", fixture("a.html")), let folder = try? store.addFolder(title: "Fold", parentId: bar.id) else { return finish(false, "no setup bookmarks") }
        app.bookmarksChanged()
        let paths: [(String, () -> Void)] = [
            ("a re-bookmark", { self.addMark("Again", page, in: other) }),
            ("a rename", { self.app.renameBookmark(keep.id, to: "Kept") }),
            ("a move", { _ = try? store.moveBookmark(id: keep.id, toParent: folder.id, index: nil); self.app.bookmarksChanged() }),
            ("a new folder", { self.app.addBookmarkFolder(title: "New", parentId: bar.id) }),
            ("a folder delete", { self.app.deleteBookmark(folder.id) }),
        ]
        for (i, (name, change)) in paths.enumerated() {
            guard cmdD(), await until(5, { !ed.isHidden && copies().count == 1 }) else { return finish(false, "\(name): Cmd+D did not add the page (copies \(copies().count))") }
            ed.remove.performClick(nil)
            guard await until(3, { copies().isEmpty }) else { return finish(false, "\(name): Remove left \(copies().count) copies") }
            guard enabled("undo:") else { return finish(false, "\(name): Undo reads disabled right after Remove") }
            change()
            let before = copies().count
            guard !enabled("undo:") else { return finish(false, "after \(name) the card's Undo still reads enabled") }
            undo()
            guard copies().count == before else { return finish(false, "after \(name) Undo restored \(copies().count - before) bookmark(s) of the page") }
            if i == 0 { for c in copies() { app.deleteBookmark(c.id) } }
        }
        // A later Remove registers its own entry and Undo takes it (once).
        guard cmdD(), await until(5, { !ed.isHidden && copies().isEmpty == false }) else { return finish(false, "last: Cmd+D did not add the page") }
        ed.remove.performClick(nil)
        guard await until(3, { copies().isEmpty }), enabled("undo:") else { return finish(false, "last: Remove did not leave a valid entry") }
        undo()
        guard await until(3, { copies().count == 1 }), !enabled("undo:") else { return finish(false, "last: Undo restored \(copies().count) copies, Undo then reads enabled \(enabled("undo:"))") }
        finish(violations.isEmpty, "Undo read disabled in a fresh window, enabled after Remove, and disabled with nothing restored after a re-bookmark, a rename, a move, a new folder and a folder delete; a later Remove undone once \(violations)")
    }
}
#endif
