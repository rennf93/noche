#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Tab checks: shortcuts, rapid open and close, extension view of the tabs, navigation, links and load errors.
extension SelfTest {
    func closeLast() async {
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        guard let tab = app.windows.first?.tabs.first else { return finish(false, "no tab") }
        tab.close()
        guard await until(15, { windowsClosed == 1 }) else { return finish(false, "window did not close with its last tab") }
        guard closedTabs == 1, app.windows.isEmpty else {
            return finish(false, "closedTabs=\(closedTabs) windowsLeft=\(app.windows.count)")
        }
        try? await Task.sleep(for: .seconds(2))  // the app must stay alive with no window
        let addedBefore = added
        let fresh = app.newWindow(url: url)
        guard await until(15, { added == addedBefore + 1 && fresh.tabs.count == 1 }) else {
            return finish(false, "New Window made no tab (added=\(added - addedBefore) tabs=\(fresh.tabs.count))")
        }
        finish(violations.isEmpty, "last tab closed its window, app alive 2 s later, new window has \(fresh.tabs.count) tab \(violations)")
    }

    func loadErrorLink() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        var before = loads
        tab.loadURL(fixture("err.html"))
        guard await until(10, { loads > before && tab.url.hasSuffix("err.html") }) else { return finish(false, "err.html did not load (\(tab.url))") }
        let failures = loadFailures
        before = loads
        _ = await evaluate(tab, "document.getElementById('l').click()")  // a click on the link, not the address field
        guard await until(15, { loadFailures > failures }) else { return finish(false, "no load error for the link to a closed port") }
        _ = await until(5, { ctl.list.displayTitle(of: ctl.list.items[0].id) == "localhost" && ctl.toolbar.address.stringValue == "localhost" })
        let title = ctl.list.displayTitle(of: ctl.list.items[0].id)
        let address = ctl.toolbar.address.stringValue
        guard title == "localhost", address == "localhost" else { return finish(false, "link to a closed port: row title \(title) address \(address) (tab url \(tab.url))") }
        // Cmd+L seeds the command bar with the URL the tab shows, the failed one (the trailing "/" is dropped).
        cmdL()
        _ = await until(5, { barEditor != nil })
        let seeded = barText
        closeBarNow()
        guard seeded == "http://localhost:1" else { return finish(false, "Cmd+L seeded \(seeded), want http://localhost:1") }
        guard await until(10, { tab.canGoBack }) else { return finish(false, "Back is not available after the error") }
        shortcut("Go Back")
        // The next committed navigation, whatever caused it, ends the failed state.
        guard await until(10, { ctl.toolbar.address.stringValue == "127.0.0.1" && ctl.list.displayTitle(of: ctl.list.items[0].id) == "Error Link Page" }) else {
            return finish(false, "after Back: address \(ctl.toolbar.address.stringValue) title \(ctl.list.displayTitle(of: ctl.list.items[0].id)) tab url \(tab.url)")
        }
        finish(violations.isEmpty, "link to a closed port: row title and address show localhost, Cmd+L seeds \(seeded), Back returns to the page and clears the failure \(violations)")
    }

    /// What the probe extension's service worker sees through chrome.tabs, asked from the page |tab| shows (a content script relays it).
    func extension_(_ tab: NCTab, _ message: String) async -> [String: Any]? {
        let quoted = String(data: (try? JSONSerialization.data(withJSONObject: [message], options: [])) ?? Data(), encoding: .utf8) ?? "[]"
        let js = """
        (async () => { const d = document.documentElement; d.dataset.nocheReply = '';
          document.dispatchEvent(new CustomEvent('noche-cmd', { detail: \(quoted)[0] }));
          for (let i = 0; i < 30; i++) { if (d.dataset.nocheReply) return d.dataset.nocheReply; await new Promise(r => setTimeout(r, 50)); }
          return '{"error":"no reply in 5 s"}'; })()
        """
        guard let json = await evaluate(tab, js), let data = json.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any] else { return nil }
        return obj
    }
    /// The extension may load after the first page did, so its content script is missing then: reload once and ask again.
    func extensionTabCount(_ tab: NCTab, want: Int? = nil) async -> Int? {
        var last: [String: Any]?
        for attempt in 0..<8 {
            last = await extension_(tab, #"{"what":"tabs"}"#)
            if let c = last?["count"] as? Int, want == nil || c == want { return c }
            if attempt == 2, last?["count"] == nil {
                let before = loads
                tab.reload()
                _ = await until(10, { loads > before })
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        lastExtensionReply = "\(String(describing: last))"
        return last?["count"] as? Int
    }

    func tabsKeys() async {
        guard await ready(), let ctl, let win else { return }
        for _ in 0..<3 { cmdT() }
        guard await until(10, { rowCount == 4 && win.tabs.count == 4 && selected == 3 }) else {
            return finish(false, "3x Cmd+T: rows=\(rowCount) engine tabs=\(win.tabs.count) selected=\(selected.map(String.init) ?? "nil") actions=\(BrowserWindowController.actionCounts)")
        }
        guard win.activeTab === win.tabs.last else { return finish(false, "newest tab is not the engine's active tab") }
        try? await Task.sleep(for: .milliseconds(500))  // a second action per shortcut would add rows now
        guard rowCount == 4, win.tabs.count == 4, BrowserWindowController.actionCounts["newTab"] == 3 else {
            return finish(false, "Cmd+T acted more than once: rows=\(rowCount) engine tabs=\(win.tabs.count) actions=\(BrowserWindowController.actionCounts)")
        }
        var trail: [Int] = []
        for (step, want) in [(nextTab, 0), (nextTab, 1), (previousTab, 0), (previousTab, 3)] as [(() -> Void, Int)] {
            step()
            guard await until(5, { selected == want }) else { return finish(false, "tab keys: selected=\(selected.map(String.init) ?? "nil") engine active \(win.tabs.firstIndex { $0 === win.activeTab }.map(String.init) ?? "nil") want \(want) after \(trail) actions \(BrowserWindowController.actionCounts) chrome commands \(BrowserWindowController.commandLog) keys \(keyLog)") }
            trail.append(want)
        }
        guard BrowserWindowController.actionCounts["nextTab"] == 2, BrowserWindowController.actionCounts["previousTab"] == 2 else { return finish(false, "next/previous acted \(BrowserWindowController.actionCounts)") }
        // Cmd+W on row 1 closes that tab, the row below (old row 2) becomes active.
        click(ctl.sidebar.rows[1])
        guard await until(5, { selected == 1 }) else { return finish(false, "row click did not select row 1") }
        let below = ctl.list.items[2].id
        cmdW()
        guard await until(10, { rowCount == 3 && win.tabs.count == 3 && ctl.list.activeID == below }) else {
            return finish(false, "Cmd+W: rows=\(rowCount) engine tabs=\(win.tabs.count) selected=\(selected.map(String.init) ?? "nil") actions=\(BrowserWindowController.actionCounts)")
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard rowCount == 3, BrowserWindowController.actionCounts["closeTab"] == 1 else { return finish(false, "Cmd+W acted more than once: rows=\(rowCount) \(BrowserWindowController.actionCounts)") }
        // Mouse: New Tab row adds a tab, a middle click closes a row.
        click(ctl.sidebar.newTabRow)
        guard await until(10, { rowCount == 4 && win.tabs.count == 4 }) else { return finish(false, "New Tab row: rows=\(rowCount)") }
        click(ctl.sidebar.rows[0], middle: true)
        guard await until(10, { rowCount == 3 && win.tabs.count == 3 }) else { return finish(false, "middle click: rows=\(rowCount) engine tabs=\(win.tabs.count)") }
        finish(maxOwnWindows == 1 && violations.isEmpty, "Cmd+T x3 -> 4 rows, newest active; next/previous wrap \(trail); Cmd+W closed one, row below active; row click, New Tab row, middle click; own windows max \(maxOwnWindows); actions \(BrowserWindowController.actionCounts) \(violations)")
    }

    func tabsRapid() async {
        guard await ready(), let ctl, let win, let first = win.tabs.first else { return }
        for _ in 0..<20 { cmdT() }
        for _ in 0..<20 { cmdW() }  // 21 tabs with the first: the brief's 19 would leave two
        guard await until(30, { rowCount == 1 && win.tabs.count == 1 }) else {
            return finish(false, "rapid: rows=\(rowCount) engine tabs=\(win.tabs.count) actions=\(BrowserWindowController.actionCounts)")
        }
        guard win.tabs.first === first else { return finish(false, "the surviving tab is not the first one") }
        let count = await extensionTabCount(first, want: 1)
        finish(count == 1 && BrowserWindowController.actionCounts["newTab"] == 20 && BrowserWindowController.actionCounts["closeTab"] == 20 && maxOwnWindows == 1 && violations.isEmpty,
               "20x Cmd+T then 20x Cmd+W: 1 row, 1 engine tab, extension count \(count.map(String.init) ?? "nil"), actions \(BrowserWindowController.actionCounts), own windows max \(maxOwnWindows) \(violations)")
    }

    func extCount() async {
        guard await ready(), let ctl, let win, let first = win.tabs.first else { return }
        guard await openTabs(5) else { return finish(false, "5 rows never appeared (rows=\(rowCount))") }
        let count = await extensionTabCount(first, want: 5)
        guard count == 5, rowCount == 5 else { return finish(false, "extension sees \(count.map(String.init) ?? "nil") tabs, rows=\(rowCount), last reply \(lastExtensionReply)") }
        let created = await extension_(first, #"{"what":"create","url":"\#(fixture("b.html"))"}"#)
        guard await until(10, { rowCount == 6 && win.tabs.count == 6 }) else { return finish(false, "chrome.tabs.create: rows=\(rowCount) reply=\(String(describing: created))") }
        try? await Task.sleep(for: .milliseconds(500))
        guard rowCount == 6, await extensionTabCount(first, want: 6) == 6 else { return finish(false, "after create: rows=\(rowCount)") }
        let target = selected == 2 ? 3 : 2
        let reply = await extension_(first, #"{"what":"activate","n":\#(target)}"#)
        guard await until(10, { selected == target - 1 }) else {
            return finish(false, "chrome.tabs.update active: selected=\(selected.map(String.init) ?? "nil") want \(target - 1) reply=\(String(describing: reply))")
        }
        _ = ctl
        finish(violations.isEmpty, "5 tabs: extension count 5 equals rows; tabs.create added exactly one row (6); tabs.update(active) moved the selection to row \(target - 1) \(violations)")
    }

    func navigate() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let port = URL(string: url)?.port else { return }
        func load(_ text: String) async -> Bool {
            let before = loads
            guard await openBar() else { return false }
            barType(text)
            press(.enter)
            return await until(15, { loads > before })
        }
        let shown = String(url.dropLast())  // the bar shows the URL without its trailing "/"
        guard await openBar(), let editor = barEditor, editor.selectedRange.length == (shown as NSString).length, barText == shown else {
            return finish(false, "Cmd+L: editor \(barEditor != nil) selection \(barEditor?.selectedRange ?? NSRange()) text \(barText) want \(shown)")
        }
        closeBarNow()
        guard await load("127.0.0.1:\(port)/b.html") else { return finish(false, "typed host and path did not load") }
        guard await until(5, { ctl.list.displayTitle(of: ctl.list.items[0].id) == "B Page" && ctl.toolbar.address.stringValue == "127.0.0.1" }) else {
            return finish(false, "after load: title \(ctl.list.displayTitle(of: ctl.list.items[0].id)) address \(ctl.toolbar.address.stringValue)")
        }
        guard await load("two words") else { return finish(false, "search did not load") }
        guard tab.url.contains("/search?q=two%20words") else { return finish(false, "search went to \(tab.url)") }
        guard await until(5, { ctl.toolbar.back.isEnabled && !ctl.toolbar.forward.isEnabled }) else { return finish(false, "back/forward state after two loads") }
        let before = loads
        shortcut("Go Back")
        guard await until(10, { tab.url.hasSuffix("/b.html") && ctl.toolbar.forward.isEnabled }) else { return finish(false, "Cmd+[ left us on \(tab.url)") }
        click(ctl.toolbar.forward)  // a mouse click on Forward
        guard await until(10, { tab.url.contains("/search?q=") && !ctl.toolbar.forward.isEnabled }) else { return finish(false, "forward button left us on \(tab.url)") }
        _ = await until(10, { loads >= before + 2 })
        let reloadFrom = loads
        key("r", code: 15)
        guard await until(10, { loads > reloadFrom }) else { return finish(false, "Cmd+R did not reload (load end did not fire again)") }
        finish(violations.isEmpty, "Cmd+L selects the URL; typed path and search loaded (\(tab.url)); back (Cmd+[) and forward (button) work; Cmd+R reloaded \(violations)")
    }

    func blankLink() async {
        guard await ready(), let ctl, let win, let opener = win.activeTab else { return }
        opener.loadURL(fixture("link.html"))
        guard await until(10, { loads >= 2 }) else { return finish(false, "link page did not load") }
        guard await openTabs(3) else { return finish(false, "extra tabs never appeared") }
        click(ctl.sidebar.rows[0])
        guard await until(5, { selected == 0 }) else { return finish(false, "could not select the opener row") }
        let rows = rowCount
        // A real mouse click on the link through DevTools input (the probe extension's debugger), not element.click().
        let spot = await evaluate(opener, "JSON.stringify((() => { const r = document.getElementById('l').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })())")
        guard let spot, let raw = try? JSONSerialization.jsonObject(with: Data(spot.utf8), options: .fragmentsAllowed) as? String,
              let xy = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Double], xy.count == 2 else { return finish(false, "link position \(spot ?? "nil")") }
        let reply = await extension_(opener, #"{"what":"click","n":1,"x":\#(xy[0]),"y":\#(xy[1])}"#)
        guard reply?["ok"] as? Bool == true else { return finish(false, "extension click \(String(describing: reply))") }
        guard await until(10, { rowCount == rows + 1 }) else { return finish(false, "no new row after the click (rows=\(rowCount))") }
        try? await Task.sleep(for: .milliseconds(500))
        finish(rowCount == rows + 1 && selected == 1 && win.tabs.count == rows + 1 && ownWindows() == 1 && violations.isEmpty,
               "target=_blank click: one new row at index \(selected.map(String.init) ?? "nil") (opener 0), active; rows=\(rowCount) engine tabs=\(win.tabs.count) windows=\(ownWindows()) \(violations)")
    }

    /// Cmd+L, the text, Return: the way a person navigates. False when the command bar did not take the text.
    func submitAddress(_ text: String) async -> Bool {
        guard await openBar() else { return false }
        barType(text)
        press(.enter)
        return true
    }

    func loadError() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        let good = tab.url
        let failures = loadFailures
        // localhost, not 127.0.0.1: the fixture is on 127.0.0.1, so a failing 127.0.0.1 could not tell old from new.
        guard await submitAddress("http://localhost:1/") else { return finish(false, "command bar did not take the text") }
        guard await until(15, { loadFailures > failures }) else { return finish(false, "no load error for a closed port") }
        _ = await until(5, { ctl.list.displayTitle(of: ctl.list.items[0].id) == "localhost" && ctl.toolbar.address.stringValue == "localhost" })
        let title = ctl.list.displayTitle(of: ctl.list.items[0].id)
        let address = ctl.toolbar.address.stringValue
        line("info", "after the error: tab url \(tab.url) tab title \(tab.title) row title \(title) address \(address) back enabled \(ctl.toolbar.back.isEnabled)")
        guard title == "localhost", address == "localhost" else { return finish(false, "row title \(title) address \(address)") }
        guard await until(10, { tab.canGoBack }) else { return finish(false, "Back is not available after the error") }
        shortcut("Go Back")
        var pageTitle: String?
        for _ in 0..<40 {
            pageTitle = await evaluate(tab, "document.title")
            if pageTitle == "\"Noche App Fixture\"" { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard pageTitle == "\"Noche App Fixture\"" else { return finish(false, "Back shows the page titled \(pageTitle ?? "nil") (back enabled \(ctl.toolbar.back.isEnabled), keys \(keyLog))") }
        _ = await until(5, { ctl.toolbar.address.stringValue == "127.0.0.1" })
        finish(ctl.toolbar.address.stringValue == "127.0.0.1" && violations.isEmpty, "closed port on localhost: row title and address show localhost, Back returns to \(good) (address \(ctl.toolbar.address.stringValue)) \(violations)")
    }

    func shortcutsOnce() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        BrowserWindowController.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.noche.selftest"))
        let general = NSPasteboard.general
        let savedClipboard = general.string(forType: .string)
        defer { general.clearContents(); if let savedClipboard { general.setString(savedClipboard, forType: .string) } }
        var bad: [String] = []
        var passed: [String] = []

        // An unclaimed Cmd combo (no menu item) reaches the page as a keydown, the way AppKit falls through to the first responder.
        if let ns = ctl.nsWindow, let page = findView(ofClass: "RenderWidgetHostViewCocoa", in: win.chromeHost) ?? win.webView, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ns.windowNumber, context: nil, characters: "k",
               charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
            ns.makeFirstResponder(page)
            if !ns.performKeyEquivalent(with: ev), NSApp.mainMenu?.performKeyEquivalent(with: ev) != true { ns.firstResponder?.keyDown(with: ev) }
            var keys = ""
            for _ in 0..<20 {
                keys = await evaluate(tab, "JSON.stringify(window.__keys || [])") ?? ""
                if keys.contains("k+meta") { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if keys.contains("k+meta") { passed.append("Cmd+K reached the page") } else { bad.append("Cmd+K never reached the page (page saw \(keys))") }
        } else { bad.append("no web view for the Cmd+K case") }

        func reset() { BrowserWindowController.actionCounts = [:]; BrowserWindowController.commandLog = [] }
        func verify(_ name: String, _ action: String) {
            let counts = BrowserWindowController.actionCounts, log = BrowserWindowController.commandLog
            if counts != [action: 1] { bad.append("\(name): actions \(counts), want exactly [\(action): 1] (Chrome commands \(log))") }
            else if Set(log).count != log.count { bad.append("\(name): Chrome commands repeated \(log)") }
            else { passed.append(name) }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

        // History for Back and Forward.
        let before = loads
        tab.loadURL(fixture("b.html"))
        guard await until(10, { loads > before && tab.canGoBack }) else { return finish(false, "no history for Back (loads \(loads) before \(before) canGoBack \(tab.canGoBack) url \(tab.url) bad \(bad) passed \(passed))") }

        reset(); key("r", code: 15); await settle(); verify("Cmd+R", "reload")
        reset(); key("r", code: 15, [.command, .shift]); await settle(); verify("Shift+Cmd+R", "forceReload")
        reset(); key("=", code: 24, [.command, .shift], chars: "+"); await settle(); verify("Cmd+Shift+= (Zoom In)", "zoom")
        if tab.zoomLevel != 0.5 { bad.append("Zoom In left the zoom at \(tab.zoomLevel)") }
        reset(); key("-", code: 27); await settle(); verify("Cmd+- (Zoom Out)", "zoom")
        reset(); key("0", code: 29); await settle(); verify("Cmd+0 (Actual Size)", "zoom")
        if tab.zoomLevel != 0 { bad.append("Zoom Out and Actual Size left the zoom at \(tab.zoomLevel)") }
        reset(); key("c", code: 8, [.command, .shift], chars: "C"); await settle(); verify("Shift+Cmd+C", "copyURL")
        if BrowserWindowController.pasteboard.string(forType: .string) != tab.url { bad.append("Copy URL put \(BrowserWindowController.pasteboard.string(forType: .string) ?? "nil") on the pasteboard, want \(tab.url)") }
        reset(); shortcut("Go Back"); await settle(); verify("Cmd+[", "back")
        guard await until(10, { tab.canGoForward && !tab.url.hasSuffix("b.html") }) else { return finish(false, "Back did not go back (\(tab.url))") }
        reset(); shortcut("Go Forward"); await settle(); verify("Cmd+]", "forward")
        reset(); cmdL(); await settle(); verify("Cmd+L", "focusAddress")
        if barEditor == nil { bad.append("Cmd+L did not open the command bar with its field focused") }
        // Address editing: type, select all, copy; the clipboard holds the text.
        general.clearContents()
        barType("hello noche")
        // The Edit menu items are nil-targeted and a hidden window is never key, so deliver the actions the way the responder chain would.
        _ = ctl.nsWindow?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        _ = ctl.nsWindow?.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        if general.string(forType: .string) != "hello noche" { bad.append("address field: Cmd+A, Cmd+C left \(general.string(forType: .string) ?? "nil") on the pasteboard") } else { passed.append("address field Cmd+A, Cmd+C") }
        barEditor?.string = ""
        closeBarNow()
        reset(); cmdS(); await settle(); verify("Cmd+S", "toggleSidebar")
        reset(); cmdT(); guard await until(5, { rowCount == 2 }) else { return finish(false, "Cmd+T made no row") }; await settle(); verify("Cmd+T", "newTab")
        reset(); nextTab(); await settle(); verify("Shift+Cmd+]", "nextTab")
        reset(); previousTab(); await settle(); verify("Shift+Cmd+[", "previousTab")
        reset(); cmdW(); guard await until(5, { rowCount == 1 }) else { return finish(false, "Cmd+W closed no tab") }; await settle(); verify("Cmd+W", "closeTab")
        // The keys of the menu table (M1.4 task 2). Print, Inspect Elements and JavaScript Console are counted but not run: a hidden run must not raise their windows.
        BrowserWindowController.suppressChrome = true
        // The engine maps Opt+Cmd+C and Opt+Shift+Cmd+C to its own Inspect command; the bridge claims them before the engine's accelerator, so a key through
        // NSApplication.sendEvent (like a real press) runs Noche's item once and opens no DevTools window. Title and address carry a backslash, a bracket and a parenthesis.
        let devToolsBefore = NCWindow.devToolsCreated(), claimsBefore = NCWindow.testPreemptedKeys()
        _ = await evaluate(tab, #"document.title = "a\\b] c"; history.pushState(null, "", "/q)x"); 1"#)
        guard await until(10, { tab.title == #"a\b] c"# && tab.url.hasSuffix("/q)x") }) else { return finish(false, "the page did not take the Markdown test title and address (\(tab.title) \(tab.url))") }
        reset(); sendKey("c", code: 8, [.command, .option, .shift], chars: "C"); await settle(); verify("Opt+Shift+Cmd+C", "copyURLMarkdown")
        let markdown = BrowserWindowController.pasteboard.string(forType: .string)
        let wantMarkdown = #"[a\\b\] c]("# + fixture("") + "q%29x)"
        if markdown != wantMarkdown { bad.append("Copy URL as Markdown put \(markdown ?? "nil") on the pasteboard, want \(wantMarkdown)") }
        reset(); sendKey("c", code: 8, [.command, .option]); await settle(); verify("Opt+Cmd+C", "inspectElements")
        if NCWindow.testPreemptedKeys() - claimsBefore != 2 { bad.append("the bridge claimed \(NCWindow.testPreemptedKeys() - claimsBefore) of the 2 engine chords (the menu alone would also run them in a hidden run)") }
        if NCWindow.devToolsCreated() != devToolsBefore { bad.append("a DevTools window opened (\(NCWindow.devToolsCreated()) created, \(devToolsBefore) before)") }
        // Cmd+C is not claimed: the page sees the keydown, and no Noche action runs.
        if let ns = ctl.nsWindow, let page = findView(ofClass: "RenderWidgetHostViewCocoa", in: win.chromeHost) ?? win.webView, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ns.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
            _ = await evaluate(tab, #"window.__keys = []; document.addEventListener("keydown", (e) => { window.__keys.push(e.key + (e.metaKey ? "+meta" : "")); }); 1"#)
            ns.makeFirstResponder(page); reset()
            NSApp.sendEvent(ev)  // not claimed by Noche: no action runs
            let claimed = BrowserWindowController.actionCounts
            ns.firstResponder?.keyDown(with: ev)  // and the page gets the key, as AppKit's fall-through gives it (a hidden window is never key)
            var keys = ""
            for _ in 0..<20 {
                keys = await evaluate(tab, "JSON.stringify(window.__keys || [])") ?? ""
                if keys.contains("c+meta") { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if keys.contains("c+meta"), claimed.isEmpty, NCWindow.testPreemptedKeys() - claimsBefore == 2 { passed.append("Cmd+C reached the page") } else { bad.append("Cmd+C: page saw \(keys), Noche actions \(BrowserWindowController.actionCounts)") }
        } else { bad.append("no web view for the Cmd+C case") }
        // Shifted punctuation: the menu resolves each chord of the table that is typed with Shift (US layout: the shifted character, and the plain key ignoring modifiers).
        if let menu = NSApp.mainMenu as? ShortcutMenu, let ns = ctl.nsWindow {
            // AppKit rewrites some keys for the machine's layout once an item is in the menu (a Spanish layout turns "[" into "ñ"): a press there types the live key.
            func resolves(_ name: String, _ usPlain: String, _ usShifted: String, _ mods: NSEvent.ModifierFlags, _ title: String) {
                let plain = menuItem(title)?.keyEquivalent.replacingOccurrences(of: "+", with: "=") ?? usPlain
                let direct = plain != usPlain && plain != "="
                let shifted = direct ? plain : usShifted
                let mods = direct ? (menuItem(title)?.keyEquivalentModifierMask ?? mods) : mods
                guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ns.windowNumber,
                                                context: nil, characters: shifted, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: 0) else { return bad.append("\(name): no event") }
                let got = menu.item(for: ev)?.title
                if got == title { passed.append("\(name) is \(title)") } else { bad.append("\(name) resolved \(got ?? "nothing"), want \(title)") }
            }
            resolves("Cmd+: (Shift+Cmd+;)", ";", ":", [.command, .shift], "Show Spelling and Grammar")
            resolves("Cmd+;", ";", ";", .command, "Check Document Now")
            resolves("Cmd++ (Shift+Cmd+=)", "=", "+", [.command, .shift], "Zoom In")
            resolves("Ctrl++ (Ctrl+Shift+=)", "=", "+", [.control, .shift], "Open Split Pane")
            resolves("Ctrl+Shift+'", "'", "\"", [.control, .shift], "Focus Next Split Pane")
            resolves("Ctrl+Shift+[", "[", "{", [.control, .shift], "Focus Previous Split Pane")
            resolves("Shift+Cmd+]", "]", "}", [.command, .shift], "Next Tab")
            resolves("Shift+Cmd+[", "[", "{", [.command, .shift], "Previous Tab")
        } else { bad.append("no ShortcutMenu or window for the shifted punctuation rows") }
        reset(); key("p", code: 35); await settle(); verify("Cmd+P", "print")
        reset(); key("j", code: 38, [.command, .option]); await settle(); verify("Opt+Cmd+J", "javaScriptConsole")
        for (name, ch, code, mods, chars, scheme, action) in [("Cmd+Y", "y", UInt16(16), NSEvent.ModifierFlags.command, "y", "chrome://history", "showHistory"),
                                                             ("Shift+Cmd+J", "j", UInt16(38), [.command, .shift], "J", "chrome://downloads", "showDownloads")] as [(String, String, UInt16, NSEvent.ModifierFlags, String, String, String)] {
            reset(); key(ch, code: code, mods, chars: chars)
            guard await until(10, { rowCount == 2 && win.activeTab?.url.hasPrefix(scheme) == true }) else { return finish(false, "\(name) opened rows=\(rowCount) active \(win.activeTab?.url ?? "nil"), want a new tab at \(scheme)") }
            await settle(); verify(name, action)
            cmdW(); guard await until(5, { rowCount == 1 }) else { return finish(false, "Cmd+W did not close the \(scheme) tab") }
        }
        guard await openTabs(3) else { return finish(false, "no 3 tabs for Close All Tabs (rows=\(rowCount))") }
        reset(); key("k", code: 40, [.command, .shift], chars: "K")
        guard await until(10, { rowCount == 1 && win.tabs.count == 1 && ctl.list.items.first?.url == "about:blank" }) else {
            return finish(false, "Shift+Cmd+K left \(rowCount) rows, \(win.tabs.count) engine tabs, list \(ctl.list.items.map(\.url))")
        }
        await settle(); verify("Shift+Cmd+K", "closeAllTabs")
        let reloaded = loads
        win.activeTab?.loadURL(fixture(""))
        _ = await until(10, { loads > reloaded })
        reset(); key("n", code: 45); guard await until(15, { app.controllers.count == 2 && app.controllers[1].nsWindow != nil }) else { return finish(false, "Cmd+N opened no second window") }; await settle(); verify("Cmd+N", "newWindow")
        reset(); key("w", code: 13, [.command, .shift], chars: "W"); guard await until(15, { app.controllers.count == 1 }) else { return finish(false, "Shift+Cmd+W did not close the second window") }; await settle(); verify("Shift+Cmd+W (second window)", "closeWindow")
        reset(); key("i", code: 34, [.command, .option]); await settle(); verify("Opt+Cmd+I", "devTools")
        finish(bad.isEmpty && violations.isEmpty, "\(passed.count) shortcuts acted exactly once with no repeated Chrome command: \(passed.joined(separator: ", ")) \(bad) \(violations)")
    }

    /// A page that cancels its beforeunload dialog: Cmd+W leaves the tab open and selected, and a later Cmd+W (Leave) closes it.
    func closeBeforeUnload() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        NCWindow.testSet(beforeUnloadAnswer: 1)  // Stay
        let before = loads
        tab.loadURL(fixture("beforeunload.html"))
        guard await until(10, { loads > before && tab.url.hasSuffix("beforeunload.html") }) else { return finish(false, "beforeunload.html did not load (\(tab.url))") }
        _ = await evaluate(tab, "document.body.click(); 1")  // a user gesture: without one Chrome closes the page without asking
        guard await openTabs(2) else { return finish(false, "second tab never appeared (rows=\(rowCount))") }
        guard selected == 0, win.activeTab === tab else { return finish(false, "the page with the dialog is not selected (selected=\(selected.map(String.init) ?? "nil"))") }
        cmdW()
        guard await until(10, { NCWindow.testBeforeUnloadDialogs() == 1 }) else { return finish(false, "Cmd+W raised no beforeunload dialog (\(NCWindow.testBeforeUnloadDialogs()))") }
        try? await Task.sleep(for: .seconds(1))  // the cancellation reaches the window controller a turn later
        guard rowCount == 2, win.tabs.count == 2, selected == 0, win.activeTab === tab else {
            return finish(false, "after Stay: rows=\(rowCount) engine tabs=\(win.tabs.count) selected=\(selected.map(String.init) ?? "nil") active is the page \(win.activeTab === tab)")
        }
        NCWindow.testSet(beforeUnloadAnswer: 2)  // Leave
        cmdW()
        guard await until(10, { rowCount == 1 && win.tabs.count == 1 }) else {
            return finish(false, "second Cmd+W (Leave): rows=\(rowCount) engine tabs=\(win.tabs.count) dialogs=\(NCWindow.testBeforeUnloadDialogs()) actions=\(BrowserWindowController.actionCounts)")
        }
        guard selected == 0, NCWindow.testBeforeUnloadDialogs() == 2, BrowserWindowController.actionCounts["closeTab"] == 2 else {
            return finish(false, "after Leave: selected=\(selected.map(String.init) ?? "nil") dialogs=\(NCWindow.testBeforeUnloadDialogs()) actions=\(BrowserWindowController.actionCounts)")
        }
        _ = ctl
        finish(violations.isEmpty && zombies.isEmpty, "Cmd+W with the dialog answered Stay kept the tab and its selection; the second Cmd+W (Leave) closed it, the other tab is selected (dialogs 2, closeTab 2) \(violations) \(zombies)")
    }

    /// With no window open the app is still usable: New Tab and Open Command Bar open a window, and a Dock click (reopen) does too.
    func noWindow() async {
        guard await ready(), let first = win?.activeTab else { return }
        first.close()
        guard await until(15, { windowsClosed == 1 && app.controllers.isEmpty }) else { return finish(false, "the window did not close with its last tab") }
        try? await Task.sleep(for: .seconds(1))
        // File > New Tab through the menu's key equivalent.
        guard cmdT() else { return finish(false, "Cmd+T found no menu item with no window open") }
        guard await until(15, { app.controllers.count == 1 && rowCount == 1 }) else { return finish(false, "New Tab with no window opened \(app.controllers.count) windows, \(rowCount) rows") }
        try? await Task.sleep(for: .milliseconds(500))
        guard app.controllers.count == 1, rowCount == 1, win?.tabs.count == 1 else { return finish(false, "New Tab with no window: windows \(app.controllers.count) rows \(rowCount) tabs \(win?.tabs.count ?? -1), want one window with one tab") }
        // Open Command Bar with no window: a window opens and its command bar (the New Tab card) has its field being edited.
        win?.activeTab?.close()
        guard await until(15, { windowsClosed == 2 && app.controllers.isEmpty }) else { return finish(false, "the second window did not close") }
        guard cmdL() else { return finish(false, "Cmd+L found no menu item with no window open") }
        guard await until(15, { app.controllers.count == 1 && rowCount == 1 && barEditor != nil }) else {
            return finish(false, "Open Command Bar with no window: windows \(app.controllers.count) rows \(rowCount) editing \(barEditor != nil)")
        }
        // The Dock click: the delegate's reopen handler, called directly.
        win?.activeTab?.close()
        guard await until(15, { windowsClosed == 3 && app.controllers.isEmpty }) else { return finish(false, "the third window did not close") }
        let handled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        guard await until(15, { app.controllers.count == 1 && rowCount == 1 }) else { return finish(false, "reopen opened \(app.controllers.count) windows, \(rowCount) rows (handler returned \(handled))") }
        try? await Task.sleep(for: .milliseconds(500))
        finish(app.controllers.count == 1 && rowCount == 1 && violations.isEmpty, "no window: New Tab (menu key equivalent), Open Command Bar (command bar field editing) and reopen each opened one window with one tab \(violations)")
    }
}
#endif
