#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Bridge and lifetime checks: hidden mode, quit, DevTools, async evaluation, zombie tabs.
extension SelfTest {
    func hidden() async {
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        guard let win = app.windows.first, let ns = win.nsWindow, let tab = win.tabs.first else {
            return finish(false, "no window with a tab")
        }
        // Negative controls (test only): a swallowed activation, and an attempt to show our window at alpha 1.
        switch ProcessInfo.processInfo.environment["NOCHE_TEST_NEGATIVE"] {
        case "activate": NSApp.activate()
        case "alpha": ns.alphaValue = 1
        default: break
        }
        // CDP path every later check relies on.
        let title = await evaluate(tab, "document.title")
        try? await Task.sleep(for: .seconds(2))
        sample()
        // setAlphaValue: is clamped to 0, so reading alpha alone cannot fail: count the attempts instead. Attempts on other
        // windows (Chromium's popups and bubbles) are recorded as info; only an attempt on one of OUR windows fails.
        let blocked = NCWindow.activationsBlocked()
        let alphaOwn = NCWindow.alphaAttemptsOnOwnWindows()
        line("info", "activations-blocked=\(blocked) alpha-attempts-own=\(alphaOwn) alpha-attempts-other=\(NCWindow.alphaAttemptsOnOtherWindows())")
        let ok = app.windows.count == 1 && win.tabs.count == 1 && ns.alphaValue == 0 && !ns.isKeyWindow && !NSApp.isActive
            && ns.level == .floating && ns.ignoresMouseEvents && blocked == 0 && alphaOwn == 0
            && violations.isEmpty && title == "\"Noche App Fixture\""
        finish(ok, "windows=\(app.windows.count) tabs=\(win.tabs.count) alpha=\(ns.alphaValue) key=\(ns.isKeyWindow) active=\(NSApp.isActive) level=\(ns.level.rawValue) clickthrough=\(ns.ignoresMouseEvents) activations-blocked=\(blocked) alpha-attempts-own=\(alphaOwn) title=\(title ?? "nil") violations=\(violations)")
    }

    func quitMany() async {
        guard let win = app.windows.first else { return finish(false, "no window") }
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        for _ in 1..<10 { _ = win.addTab(withURL: url, activate: false) }
        guard await until(20, { win.tabs.count == 10 && added == 10 }) else {
            return finish(false, "tabs=\(win.tabs.count) added=\(added), wanted 10")
        }
        let second = app.newWindow(url: url)
        guard await until(20, { second.tabs.count == 1 }) else { return finish(false, "second window has \(second.tabs.count) tabs") }
        for _ in 1..<5 { _ = second.addTab(withURL: url, activate: false) }
        guard await until(20, { second.tabs.count == 5 && added == 15 }) else {
            return finish(false, "second window tabs=\(second.tabs.count) added=\(added), wanted 5 and 15")
        }
        _ = await until(10, { loads >= 15 })  // info only: quitting with loaded tabs is the harder case
        tabsAtQuit = win.tabs.count + second.tabs.count
        line("info", "tabs=\(tabsAtQuit) loaded=\(loads), sending the Quit menu action")
        quitViaMenu()
    }

    func quitViaMenu() {
        guard let sub = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { m in
            m.items.contains { $0.action == #selector(NSApplication.terminate(_:)) }
        }), let idx = sub.items.firstIndex(where: { $0.action == #selector(NSApplication.terminate(_:)) }) else {
            return finish(false, "no Quit menu item")
        }
        sub.performActionForItem(at: idx)  // the verdict is printed by beforeExit once the process really exits
    }

    // MARK: bridge hardening (M1.1 Task 6)

    func evalAsync() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        var inside: [String] = []
        let reply = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            tab.evaluateJavaScript("1 + 1") { json, _ in
                if NCWindow.insideCefCallback() { inside.append("normal reply") }
                c.resume(returning: json)
            }
        }
        // The tab closes before the reply: the failure comes from the bridge's own close path (OnBeforeClose).
        guard let doomed = win.addTab(withURL: fixture(""), activate: false) else { return finish(false, "no second tab") }
        guard await until(15, { doomed.url.hasPrefix("http") && !doomed.isLoading }) else { return finish(false, "second tab never loaded") }
        let closeError = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            doomed.evaluateJavaScript("new Promise(r => setTimeout(r, 20000))") { _, error in
                if NCWindow.insideCefCallback() { inside.append("tab closed (OnBeforeClose)") }
                c.resume(returning: error)
            }
            doomed.close()
        }
        // A closed tab fails later, never before evaluateJavaScript returns.
        var ranBeforeReturn = false
        let lateError = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            var returned = false
            doomed.evaluateJavaScript("1") { _, error in
                ranBeforeReturn = !returned
                if NCWindow.insideCefCallback() { inside.append("closed tab") }
                c.resume(returning: error)
            }
            returned = true
        }
        finish(inside.isEmpty && !ranBeforeReturn && reply == "2" && closeError == "tab closed" && lateError == "tab closed" && violations.isEmpty,
               "completions run on a later main-queue turn: inside a CEF callback \(inside), closed-tab call ran before returning \(ranBeforeReturn), reply \(reply ?? "nil"), close error \(closeError ?? "nil"), late error \(lateError ?? "nil") \(violations)")
    }

    func noZombieTab() async {
        setenv("NOCHE_TEST_LATE_CALLBACKS", "1", 0)  // the bridge re-delivers OnTabAdded and OnActiveTabChanged after each close
        guard await ready(), let win else { return }
        let start = added, closed = closedTabs
        for _ in 0..<20 {
            win.addTab(withURL: "about:blank", activate: true)?.close()  // closed in the turn it was opened
        }
        guard await until(30, { win.tabs.count == 1 && rowCount == 1 && closedTabs - closed >= 20 && added - start >= 20 }) else {
            return finish(false, "tabs=\(win.tabs.count) rows=\(rowCount) added=\(added - start) closed=\(closedTabs - closed) \(zombies)")
        }
        try? await Task.sleep(for: .seconds(1))  // late announcements arrive after the closes
        finish(zombies.isEmpty && win.tabs.count == 1 && rowCount == 1 && violations.isEmpty,
               "20 tabs opened and closed in the same turn: added \(added - start) closed \(closedTabs - closed), tabs \(win.tabs.count) rows \(rowCount), zombies \(zombies) \(violations)")
    }

    func openDevTools(_ win: NCWindow) async -> Bool {
        key("i", code: 34, [.command, .option])
        // The DevTools browser exists (created) and its front end reported a load end; then it stays open a while.
        guard await until(20, { NCWindow.devToolsCreated() >= 1 && NCWindow.devToolsLoaded() >= 1 }) else { return false }
        devToolsOpened = true
        try? await Task.sleep(for: .seconds(1))
        return true
    }

    func devToolsQuit() async {
        guard await ready(), let win else { return }
        guard await openDevTools(win) else { return finish(false, "Opt+Cmd+I opened no DevTools (devToolsCount \(win.devToolsCount), created \(NCWindow.devToolsCreated()) loaded \(NCWindow.devToolsLoaded()), actions \(BrowserWindowController.actionCounts))") }
        line("info", "DevTools open, sending the Quit menu action")
        quitViaMenu()  // the verdict is printed by beforeExit
    }

    /// DevTools opened by a Chrome command that Noche does not intercept (the path of Inspect and Chrome's own accelerators).
    func devToolsAnyPath() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        guard tab.testExecuteChromeCommandNamed("IDC_DEV_TOOLS_CONSOLE") else { return finish(false, "IDC_DEV_TOOLS_CONSOLE cannot run") }
        guard await until(20, { NCWindow.devToolsCreated() >= 1 && NCWindow.devToolsLoaded() >= 1 }) else {
            return finish(false, "no DevTools browser from the Chrome command (created \(NCWindow.devToolsCreated()) loaded \(NCWindow.devToolsLoaded()), actions \(BrowserWindowController.actionCounts))")
        }
        devToolsOpened = true
        try? await Task.sleep(for: .seconds(1))
        line("info", "DevTools open through a Chrome command (Noche devTools action ran \(BrowserWindowController.actionCounts["devTools"] ?? 0) times), sending the Quit menu action")
        quitViaMenu()
    }

    func devToolsCloseTab() async {
        guard await ready(), let win else { return }
        cmdT()
        guard await until(10, { rowCount == 2 }) else { return finish(false, "Cmd+T made no row") }
        guard await openDevTools(win) else { return finish(false, "Opt+Cmd+I opened no DevTools (devToolsCount \(win.devToolsCount), created \(NCWindow.devToolsCreated()) loaded \(NCWindow.devToolsLoaded()))") }
        cmdW()  // closes the tab that has DevTools
        guard await until(15, { rowCount == 1 && win.tabs.count == 1 && win.devToolsCount == 0 && NCWindow.devToolsClosed() == 1 }) else {
            return finish(false, "after Cmd+W: rows=\(rowCount) tabs=\(win.tabs.count) devtools=\(win.devToolsCount)")
        }
        try? await Task.sleep(for: .seconds(2))  // the app keeps running; the quit that follows must be clean
        let created = NCWindow.devToolsCreated(), ended = NCWindow.devToolsClosed()
        finish(violations.isEmpty && zombies.isEmpty && rowCount == 1 && created == 1 && ended == created, "DevTools open, Cmd+W closed the tab and its DevTools, app alive 2 s later, rows \(rowCount) DevTools created=\(created) ended=\(ended) \(violations) \(zombies)")
    }

    /// 100 loaded tabs in 2 windows plus one DevTools, closed one at a time 100 ms apart (so the quit outlasts a fixed 5 s watchdog
    /// while every step is quick), then Quit: the verdict is the clean exit itself (beforeExit).
    func quit100() async {
        setenv("NOCHE_TEST_SLOW_CLOSE_MS", "100", 1)
        guard await ready(), let first = win else { return }
        for _ in 1..<60 { _ = first.addTab(withURL: fixture(""), activate: false) }
        guard await until(30, { first.tabs.count == 60 && added == 60 }) else { return finish(false, "first window tabs=\(first.tabs.count) added=\(added), wanted 60") }
        let second = app.newWindow(url: fixture(""))
        guard await until(20, { second.tabs.count == 1 }) else { return finish(false, "second window has \(second.tabs.count) tabs") }
        for _ in 1..<40 { _ = second.addTab(withURL: fixture(""), activate: false) }
        guard await until(30, { second.tabs.count == 40 && added == 100 }) else { return finish(false, "second window tabs=\(second.tabs.count) added=\(added), wanted 40 and 100") }
        _ = await until(20, { loads >= 100 })  // info only
        guard await openDevTools(first) else { return finish(false, "Opt+Cmd+I opened no DevTools (created \(NCWindow.devToolsCreated()) loaded \(NCWindow.devToolsLoaded()))") }
        tabsAtQuit = first.tabs.count + second.tabs.count
        line("info", "tabs=\(tabsAtQuit) loaded=\(loads) devtools=\(NCWindow.devToolsCreated()), sending the Quit menu action")
        quitViaMenu()
    }

    // MARK: focus return and hidden page surface (M1.3 Task 3)

    /// An AppKit field takes first responder, then focusActiveContent gives it back to the page's view.
    func focusReturn() async {
        guard await ready(), let win, let ns = win.nsWindow, let host = win.chromeHost else { return }
        func inPage() -> Bool {
            guard let page = win.webView, let r = ns.firstResponder as? NSView else { return false }
            return r === page || r.isDescendant(of: page)
        }
        let field = NSTextField(frame: NSRect(x: 300, y: 300, width: 200, height: 24))
        host.addSubview(field)
        defer { field.removeFromSuperview() }
        guard ns.makeFirstResponder(field), field.currentEditor() != nil, !inPage() else {
            return finish(false, "the AppKit field did not take first responder (\(String(describing: ns.firstResponder)))")
        }
        win.focusActiveContent()
        let back = await until(5, { inPage() && field.currentEditor() == nil })
        finish(back, "field editor first responder, then focusActiveContent: page view first responder=\(inPage()) field editing=\(field.currentEditor() != nil) responder=\(String(describing: ns.firstResponder))")
    }

    /// webContentHidden hides the page view and keeps the tab alive; NO restores the view, its insets and the corner mask.
    func newTabSurface() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        win.webInsets = NSEdgeInsets(top: 48, left: 198, bottom: 7, right: 7)
        win.webCornerRadius = 10
        func rect() -> NSRect? { win.webView.map { $0.convert($0.bounds, to: nil) } }
        guard await until(10, { rect() != nil && win.webMaskExists }), let before = rect() else { return finish(false, "no page view or mask before hiding") }
        win.webContentHidden = true
        let hid = await until(5, { win.webView == nil })
        let alive = win.tabs.count == 1 && win.activeTab === tab
        let sum = await evaluate(tab, "1 + 2")
        win.webContentHidden = false
        let shown = await until(5, { rect().map { self.near($0, before.minX, before.minY, before.width, before.height) } ?? false })
        let masked = await until(5, { win.webMaskExists })
        finish(hid && alive && sum == "3" && shown && masked && win.tabs.count == 1,
               "hidden: view gone=\(hid) tabs=\(win.tabs.count) same tab=\(alive) JS in the hidden tab=\(sum ?? "nil"); shown again at \(before): \(shown) mask=\(masked)")
    }
}
#endif
