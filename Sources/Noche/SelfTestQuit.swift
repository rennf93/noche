#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// M1.2 final-fix checks: a pending save at a slow quit-close, and a cancelled window close.
extension SelfTest {
    /// Phase 1 (quitBehavior=close, set by scripts/app-test.sh): a navigation dirties the window, then the quit starts at once with the
    /// tab closes spread 2.5 s apart, so the debounced save (250 ms) fires while the shutdown is still running. Phase 2 is
    /// `quitCloseRelaunch`'s: one blank window and nothing restored.
    func quitCloseDirty() async {
        guard await ready(), await openTabs(2), let c = ctl, let win, let tab = win.activeTab else { return }
        let setting = (try? app.writer?.store.setting("quitBehavior")) ?? nil
        guard setting == "close" else { return finish(false, "phase 1: quitBehavior=\(setting ?? "nil"), want close") }
        let b = fixture("b.html")
        tab.loadURL(b)
        guard await until(15, { self.urls(c).contains(b) }) else { return finish(false, "phase 1: the navigation never reached the list (\(urls(c)))") }
        setenv("NOCHE_TEST_SLOW_CLOSE_MS", "2500", 1)
        finish(violations.isEmpty, "phase 1: window dirtied by a navigation, quitBehavior=close, quitting with the tab closes 2.5 s apart \(violations)")
    }

    /// A window close that did not happen leaves the window-closing flag reset: a later Cmd+W on another tab is a closed tab again, so
    /// Shift+Cmd+T reopens it. This engine's window close raises no beforeunload dialog (a run of this check with one showed that), so the
    /// cancellation is delivered to the controller's delegate method directly, after the flag was set the way `close()` sets it.
    func windowCloseCancel() async {
        guard await ready(), let c = ctl, let win, let tab = win.activeTab else { return }
        let b = fixture("b.html"), l = fixture("link.html"), a = fixture("")
        _ = win.addTab(withURL: b, activate: false); _ = win.addTab(withURL: l, activate: false)
        guard await until(20, { self.urls(c) == [a, b, l] }) else { return finish(false, "urls \(urls(c))") }
        c.testBeginWindowClose()
        c.window(win, didCancelCloseOf: tab)
        guard let pick = win.tabs.first(where: { $0.url == b }) else { return finish(false, "no tab on b.html") }
        win.activateTab(pick)
        guard await until(10, { self.activeIndex(c) == 1 }) else { return finish(false, "B did not activate") }
        cmdW()
        guard await until(10, { self.urls(c) == [a, l] }) else { return finish(false, "Cmd+W on B left \(urls(c))") }
        guard reopenEnabled else { return finish(false, "Cmd+W after a cancelled window close was not recorded as a closed tab (Reopen Closed Tab is disabled)") }
        shiftCmdT()
        guard await until(15, { self.urls(c) == [a, b, l] && self.activeIndex(c) == 1 }) else { return finish(false, "Shift+Cmd+T gave \(urls(c)) active \(String(describing: activeIndex(c)))") }
        finish(violations.isEmpty, "after a window close was cancelled, Cmd+W on B was recorded and Shift+Cmd+T put it back at index 1 \(violations)")
    }
}
#endif
