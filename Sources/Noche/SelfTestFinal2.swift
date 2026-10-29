#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// M1.5 final fix 2: the bar reopened at once after a close, permission origins and ids, the browser window brought forward, the quit gap.
extension SelfTest {
    /// A bar opened right after a close keeps the keys: the engine's own focus task that follows a close's hand-back to the page must not take them back
    /// (it used to, which is why three checks waited 500 ms before reopening). Escape then Cmd+L with nothing in between, twice, then typing lands in the bar.
    func cbReopen() async {
        guard await ready(), let ctl else { return }
        guard await fixtureTitleReady() else { return finish(false, "the fixture title never arrived") }
        for round in 1...2 {
            guard await openBar() else { return finish(false, "round \(round): no bar") }
            press(.escape)
            guard await until(5, { !barOpen() && inPage() }) else { return finish(false, "round \(round): Escape did not close the bar and give the page the keys") }
            cmdL()  // at once: the engine's focus task for the close above has not run yet
            guard await until(5, { barOpen() && ctl.nsWindow?.firstResponder === barEditor }) else { return finish(false, "round \(round): the bar did not open with the keys") }
            try? await Task.sleep(for: .milliseconds(900))  // the engine's task has run by now
            guard barOpen(), barEditor != nil, ctl.nsWindow?.firstResponder === barEditor, !inPage() else {
                return finish(false, "round \(round): the bar opened right after a close lost the keys to the page (bar open \(barOpen()), in page \(inPage()), editor \(barEditor != nil), first responder \(String(describing: ctl.nsWindow?.firstResponder).prefix(60)), handback \(ProcessInfo.processInfo.systemUptime - win!.lastFocusHandback) s ago)")
            }
        }
        typeText("zq")
        guard await until(3, { barText.hasSuffix("zq") || barText == "zq" }) else { return finish(false, "typing after the reopen did not land in the bar: text '\(barText)', in page \(inPage())") }
        finish(violations.isEmpty, "Escape then Cmd+L at once, twice: the bar kept the keys 900 ms later and typing landed in it (text '\(barText)') \(violations)")
    }

    // MARK: permissions (direct requests with a recorder in place of the engine's callback: no Allow ever reaches the engine, ruling M36)

    /// I2: a request from an iframe (requesting origin other than the tab's top-level one) is never answered from a stored Allow and the card names both sites;
    /// a stored Block still answers it. Parked 2 and Minor 2: a Screen or Other request is guarded like a named kind, and its Block button reads Dismiss.
    func permOrigins() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store = app.writer?.store else { return }
        let host = origin.replacingOccurrences(of: "http://", with: ""), other = otherOrigin.replacingOccurrences(of: "http://", with: "")
        try? store.setPermission(origin: otherOrigin, kind: "geolocation", decision: .allow)  // written by this check, never granted through the engine
        defer { try? store.removePermission(origin: otherOrigin, kind: "geolocation") }
        var asTop: [String] = [], asFrame: [String] = [], afterBlock: [String] = []
        ctl.window(win, tab: tab, requestsPermissions: .geolocation, origin: otherOrigin, topLevelOrigin: otherOrigin, promptId: 9101) { asTop.append("\($0),\($1)") }
        guard asTop == ["true,false"], !cardShown else { return finish(false, "the stored Allow did not answer the origin's own request silently: answers \(asTop), card \(cardShown)") }
        let shown = card?.shownCount ?? 0
        ctl.window(win, tab: tab, requestsPermissions: .geolocation, origin: otherOrigin, topLevelOrigin: origin, promptId: 9102) { asFrame.append("\($0),\($1)") }
        guard asFrame.isEmpty, card?.shownCount == shown + 1, let card else {
            return finish(false, "an iframe of \(other) on \(host) was answered from the stored Allow of \(other) (answers \(asFrame), card shown \((self.card?.shownCount ?? 0) - shown) times)")
        }
        guard card.site.stringValue == "\(other) on \(host)", card.block.title == "Block" else { return finish(false, "the iframe's card says '\(card.site.stringValue)' with button \(card.block.title), want '\(other) on \(host)' and Block") }
        let frameSite = card.site.stringValue
        press(card.block)
        guard asFrame == ["false,true"], storedPermissions().contains("\(otherOrigin) geolocation block") else { return finish(false, "Block on the iframe's card answered \(asFrame), stored \(storedPermissions())") }
        // A stored Block still answers an iframe's request without the card.
        let shownAfter = card.shownCount
        ctl.window(win, tab: tab, requestsPermissions: .geolocation, origin: otherOrigin, topLevelOrigin: origin, promptId: 9103) { afterBlock.append("\($0),\($1)") }
        guard afterBlock == ["false,true"], card.shownCount == shownAfter, ctl.permissionQueue.isEmpty else { return finish(false, "a stored Block did not answer the iframe's request: answers \(afterBlock), card shown \(card.shownCount - shownAfter) times") }
        // Screen and Other: no Allow in a test run (the whole mask is guarded), and the button that is not a Block reads Dismiss.
        for (mask, text, id) in [(NCPermissionMask.screen, "share your screen", UInt64(9104)), (.other, "browser feature", 9105)] {
            var answers: [String] = []
            ctl.window(win, tab: tab, requestsPermissions: mask, origin: origin, topLevelOrigin: origin, promptId: id) { answers.append("\($0),\($1)") }
            guard cardShown, card.text.stringValue.contains(text), card.block.title == "Dismiss" else { return finish(false, "the card for mask \(mask.rawValue) says '\(card.text.stringValue)' with button \(card.block.title), want '\(text)' and Dismiss") }
            press(card.allow)
            guard answers == ["false,false"], violations.count == 1 else { return finish(false, "Allow on a card for mask \(mask.rawValue) answered \(answers) with \(violations.count) violations recorded, want a deny and one violation") }
            violations.removeAll()
        }
        var named: [String] = []
        ctl.window(win, tab: tab, requestsPermissions: .notifications, origin: origin, topLevelOrigin: origin, promptId: 9106) { named.append("\($0),\($1)") }
        let title = card.block.title
        ctl.dropPermissionRequests(of: tab)
        guard title == "Block" else { return finish(false, "the card for a named kind has the button \(title), want Block") }
        finish(violations.isEmpty, "an iframe of \(other) on \(host) with a stored Allow for \(other) showed the card '\(frameSite)' and was not answered silently; its Block was stored and then answered silently; Screen and Other cards read Dismiss and a forced Allow on them is a recorded deny; stored \(storedPermissions()) \(violations)")
    }

    /// Parked 1: the engine's dismissal names a request by its id, so an answer given before it lands cannot shift it onto another request. Media requests have an id of their
    /// own (never 0, never twice): two microphone requests from the page are asked, never allowed (each is answered by dismissing its card).
    func permDismissId() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        var log: [UInt64: String] = [:]
        for id in [UInt64(9201), 9202, 9203] {
            ctl.window(win, tab: tab, requestsPermissions: .geolocation, origin: origin, topLevelOrigin: origin, promptId: id) { log[id] = "\($0),\($1)" }
        }
        guard let card, cardShown else { return finish(false, "no card for three requests") }
        card.close.onClick?()  // the first request is answered (a dismissal, nothing stored) ...
        ctl.window(win, tab: tab, dismissedPermissionPromptId: 9203)  // ... and then the engine's dismissal of the third arrives
        let left = ctl.permissionQueue.map(\.id)
        guard left == [9202], log[9201] == "false,false", log[9202] == nil, log[9203] == nil, cardShown else {
            return finish(false, "after answering the first and the engine dismissing the third the host holds \(left) (want [9202]); answers \(log)")
        }
        ctl.window(win, tab: tab, dismissedPermissionPromptId: 9999)
        guard ctl.permissionQueue.map(\.id) == [9202] else { return finish(false, "a dismissal of an unknown id changed the queue to \(ctl.permissionQueue.map(\.id))") }
        ctl.dropPermissionRequests(of: tab)
        let seen = permissionRequests.count
        _ = await evaluate(tab, "window.__m = []; for (let i = 0; i < 2; i++) navigator.mediaDevices.getUserMedia({ audio: true }).then(() => window.__m.push('granted'), e => window.__m.push(e.name)); 1")
        // Chromium hands the second request to the host once the first is answered (one media prompt per tab at a time).
        for n in 1...2 {
            guard await until(10, { permissionRequests.count >= seen + n }), await waitCard(), let c = self.card else { return finish(false, "microphone request \(n) did not reach the host (\(permissionRequests.count - seen) did)") }
            c.close.onClick?()
            guard await until(5, { !cardShown || n == 1 }) else { return finish(false, "the card stayed after request \(n) was dismissed") }
        }
        let ids = permissionRequests[seen...].map(\.id)
        guard ids.count == 2, ids.allSatisfy({ $0 != 0 }), Set(ids).count == ids.count else { return finish(false, "the media requests had the ids \(ids), want two different ones, never 0") }
        let answered = await until(10, { NCWindow.permissionPromptsOpen() == 0 })
        let page = await pageValue(tab, "window.__m.join(',')")
        finish(answered && page == "\"NotAllowedError,NotAllowedError\"" && violations.isEmpty, "answering the first of three requests and then dismissing the third left the second; two media requests had the ids \(ids) and both pages' promises were refused (\(page ?? "nil")) \(violations)")
    }

    // MARK: windows

    /// I4 and Minor 7: an action started from a utility window brings the browser window it acts on forward (the test seam records the call; a hidden run never orders
    /// a window front, so only the record and the absence of a key window are asserted). History row, bookmark open (new tab and this tab) and Cmd+D.
    func windowFront() async {
        guard await ready(), let a = ctl else { return }
        let before = loads
        app.newWindow(url: fixture("b.html"))
        guard await until(20, { loads > before }), app.controllers.count == 2 else { return finish(false, "no second window") }
        let b = app.controllers[1]
        func becomeKey(_ w: BrowserWindowController) { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w.nsWindow) }
        becomeKey(a); becomeKey(b)  // B was key last; no browser window is key now (a History or Bookmarks window is)
        guard app.active === b else { return finish(false, "the active window is not B") }
        func fronted(_ what: String, _ act: () -> Void) -> String? {
            app.frontLog.removeAll()
            act()
            return app.frontLog == [b.id] ? nil : "\(what) brought forward \(app.frontLog.map { $0 == a.id ? "A" : $0 == b.id ? "B" : "?" }), want [B]"
        }
        guard let mark = addMark("Front", fixture("link.html")) else { return finish(false, "no bookmark") }
        let misses = [
            fronted("a History row") { app.openHistoryURL(fixture("link.html")) },
            fronted("a bookmark opened in a new tab") { app.openBookmark(mark, newTab: true) },
            fronted("a bookmark opened in the tab") { app.openBookmark(mark, newTab: false) },
            fronted("Cmd+D") { app.bookmarkThisPage(nil) },
        ].compactMap { $0 }
        guard misses.isEmpty else { return finish(false, misses.joined(separator: "; ")) }
        guard !(b.nsWindow?.isKeyWindow ?? false), !NSApp.isActive else { return finish(false, "a hidden run ordered a window front (key \(b.nsWindow?.isKeyWindow ?? false), app active \(NSApp.isActive))") }
        finish(violations.isEmpty, "a History row, a bookmark opened in a new tab and in the tab, and Cmd+D each brought the active browser window (B, key last) forward; the hidden run ordered nothing front \(violations)")
    }

    // MARK: quit

    /// Minor 1: the quit waits for the download pauses (here held back 1.2 s) with the windows open. phase 1 closes the last window (or opens a tab) during that wait:
    /// the process must not end before the pause landed, and the tab opened in the gap is in the saved session. Phase 2: the download is paused with its bytes,
    /// and (tab variant) the window comes back with the tab.
    func quitGap(closeLast: Bool) async {
        if phase == 1 {
            guard await ready(), let c = ctl, let win, let tab = win.activeTab, let server = await startSlowServer(size: Self.slowSize) else { return }
            slowServer = server  // stopped by beforeExit on every way out
            guard let started = await startSlow(tab, server: server, minBytes: 800_000, path: "") else { return }
            relaunchID = started.identifier
            setenv("NOCHE_TEST_PAUSE_DELAY_MS", "1200", 1)
            let b = fixture("b.html")
            app.selfTestFinished(ok: true)  // the quit; beforeExit judges what it did to the download
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { if closeLast { c.close() } else { _ = win.addTab(withURL: b, activate: false) } } }
            return
        }
        guard await until(20, { self.restoredUp(1) }) else { return finish(false, "phase 2: \(app.controllers.count) windows, want 1") }
        if !closeLast { guard await until(20, { self.urls(self.ctl!) == [self.fixture("b.html"), self.fixture("")] }) else { return finish(false, "phase 2: the window came back with \(ctl.map { urls($0) } ?? []), want b.html (the tab opened during the quit wait, at the top) and the fixture") } }
        guard await until(20, { dc.items.contains { $0.suggestedName == "127.0.0.1" } }), let restored = dc.items.first(where: { $0.suggestedName == "127.0.0.1" }) else { return finish(false, "phase 2: the download did not come back") }
        finish(restored.state == .paused && restored.receivedBytes > 0 && violations.isEmpty, "phase 2: the download came back \(restored.state == .paused ? "paused" : "NOT paused (state \(restored.state.rawValue))") with \(restored.receivedBytes) bytes\(closeLast ? " after the last window was closed during the quit wait" : ", the tab opened during the quit wait was saved") \(violations)")
    }
}
#endif
