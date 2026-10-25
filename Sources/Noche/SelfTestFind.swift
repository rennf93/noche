#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Find in page and the zoom indicator (M1.4 task 4). Both are drawn by Noche; Chromium's find bar and zoom bubble must never put a window up,
/// so every step is watched for a new NSWindow (the bubble is ordered in and gone again within a moment: a poll, not a snapshot).
extension SelfTest {
    /// Windows of this process now, by window number: AppKit's own and the system's list (any size; the bubble is 320x266). macOS's own text-input windows
    /// (TUINSWindow, and SPRoundedWindow, the suggestion popup AppKit raises while a text field is edited) are not ours and not Chromium's.
    func windowNumbers() -> Set<Int> {
        let pid = ProcessInfo.processInfo.processIdentifier
        let textInput = Set(NSApp.windows.filter { let c = NSStringFromClass(type(of: $0)); return c == "TUINSWindow" || c == "SPRoundedWindow" }.map { Int($0.windowNumber) })
        var all = Set(NSApp.windows.map { Int($0.windowNumber) }).subtracting(textInput)
        for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if (w[kCGWindowOwnerPID as String] as? Int32) == pid, let n = w[kCGWindowNumber as String] as? Int, !textInput.contains(n) { all.insert(n) }
        }
        return all
    }

    /// Waits |ms| while watching for a window that was not there at |baseline|; returns the first new numbers seen.
    func watchWindows(_ baseline: Set<Int>, ms: Int = 400) async -> Set<Int> {
        var seen = Set<Int>()
        for _ in 0..<(ms / 20) {
            seen.formUnion(windowNumbers().subtracting(baseline))
            try? await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }

    /// What the system list says about these window numbers (owner name, bounds, layer), for a failure message.
    func describeWindows(_ numbers: Set<Int>) -> String {
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let ns = Dictionary(NSApp.windows.map { (Int($0.windowNumber), NSStringFromClass(type(of: $0))) }, uniquingKeysWith: { a, _ in a })
        return numbers.sorted().map { n in
            let w = all.first { ($0[kCGWindowNumber as String] as? Int) == n }
            return "#\(n) \(ns[n] ?? "not-NSWindow") \(w?[kCGWindowBounds as String] ?? "-") layer \(w?[kCGWindowLayer as String] ?? "-") on-screen \(w?[kCGWindowIsOnscreen as String] ?? "-")"
        }.joined(separator: "; ")
    }

    func findCount() -> String { ctl?.findBar.count.stringValue ?? "nil" }
    func selection(_ tab: NCTab) async -> String { await evaluate(tab, "window.getSelection().toString()") ?? "nil" }

    // MARK: find

    /// Windows that appeared (and may be gone again) within a moment of the last key, as a failure message; nil when none did.
    func stray(_ baseline: Set<Int>, _ what: String) async -> String? {
        let w = await watchWindows(baseline, ms: 200)
        return w.isEmpty ? nil : "a window appeared on \(what): \(describeWindows(w))"
    }

    func loadFind(_ tab: NCTab) async -> Bool {
        let before = loads
        tab.loadURL(fixture("find.html"))
        return await until(10, { loads > before && tab.url.hasSuffix("find.html") })
    }

    /// Types into the pill's field, a character at a time, watching for windows after each.
    func typeInPill(_ text: String, _ baseline: Set<Int>) async -> String? {
        for ch in text {
            ctl?.findBar.field.currentEditor()?.insertText(String(ch))
            if let m = await stray(baseline, "typing '\(ch)'") { return m }
        }
        return nil
    }

    func find() async {
        guard await ready(), let ctl, let win, let first = win.activeTab else { return }
        guard await loadFind(first) else { return finish(false, "find.html did not load (\(first.url))") }
        let baseline = windowNumbers()
        BrowserWindowController.actionCounts = [:]
        guard ctl.findBar.isHidden else { return finish(false, "the find pill shows before Cmd+F") }

        key("f", code: 3)
        guard await until(5, { !ctl.findBar.isHidden && ctl.findBar.field.currentEditor() != nil }) else {
            return finish(false, "Cmd+F: pill hidden \(ctl.findBar.isHidden), field focused \(ctl.findBar.field.currentEditor() != nil) (keys \(keyLog))")
        }
        if let m = await stray(baseline, "Cmd+F") { return finish(false, m) }
        if let m = await typeInPill("needle", baseline) { return finish(false, m) }
        guard await until(10, { findCount() == "1 of 3" }) else { return finish(false, "typing the word that is on the page 3 times shows '\(findCount())', want '1 of 3'") }

        key("g", code: 5)
        guard await until(10, { findCount() == "2 of 3" }) else { return finish(false, "Cmd+G shows '\(findCount())', want '2 of 3'") }
        if let m = await stray(baseline, "Cmd+G") { return finish(false, m) }
        key("g", code: 5, [.command, .shift], chars: "G")
        guard await until(10, { findCount() == "1 of 3" }) else { return finish(false, "Shift+Cmd+G shows '\(findCount())', want '1 of 3'") }
        if let m = await stray(baseline, "Shift+Cmd+G") { return finish(false, m) }

        // Another tab: the pill hides; coming back restores it with its text and a working count.
        guard let second = win.addTab(withURL: fixture(""), activate: true) else { return finish(false, "no second tab") }
        guard await until(10, { win.activeTab === second && ctl.findBar.isHidden }) else { return finish(false, "after switching tab the pill is hidden=\(ctl.findBar.isHidden), active is second \(win.activeTab === second)") }
        win.activateTab(first)
        guard await until(10, { win.activeTab === first && !ctl.findBar.isHidden && ctl.findBar.field.stringValue == "needle" && findCount() == "1 of 3" }) else {
            return finish(false, "coming back: pill hidden \(ctl.findBar.isHidden), text '\(ctl.findBar.field.stringValue)', count '\(findCount())', want 'needle' and '1 of 3'")
        }
        key("g", code: 5)
        guard await until(10, { findCount() == "2 of 3" }) else { return finish(false, "after the tab switch Cmd+G shows '\(findCount())', want '2 of 3'") }

        // Escape closes the pill and stopFinding(clear) leaves no selection: with the highlight kept (stopFinding(false)) the active match becomes the page's selection.
        key("f", code: 3)
        guard await until(5, { ctl.findBar.field.currentEditor() != nil }) else { return finish(false, "Cmd+F did not focus the field again") }
        press(.escape)
        if let m = await stray(baseline, "Escape") { return finish(false, m) }
        guard await until(5, { ctl.findBar.isHidden && ctl.finds[first.identifier] == nil }) else { return finish(false, "Escape left the pill hidden=\(ctl.findBar.isHidden), state \(String(describing: ctl.finds[first.identifier]))") }
        var left = ""
        for _ in 0..<20 {
            left = await selection(first)
            if left == "\"\"" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard left == "\"\"" else { return finish(false, "Escape left the highlight: the page's selection is \(left)") }

        let counts = BrowserWindowController.actionCounts
        guard counts["find"] == 2, counts["findNext"] == 2, counts["findPrevious"] == 1 else { return finish(false, "action counts \(counts), want find 2, findNext 2, findPrevious 1") }
        finish(violations.isEmpty, "Cmd+F opens the pill with the field focused, 'needle' shows 1 of 3, Cmd+G 2 of 3, Shift+Cmd+G 1 of 3, another tab hides the pill and coming back restores text and 1 of 3, Escape closes it and leaves no page selection, no new window \(violations)")
    }

    /// Edit > Find > Use Selection for Find: the page's selected word becomes the pill's text and is searched.
    func findSelection() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        let before = loads
        tab.loadURL(fixture("find.html"))
        guard await until(10, { loads > before && tab.url.hasSuffix("find.html") }) else { return finish(false, "find.html did not load (\(tab.url))") }
        _ = await evaluate(tab, #"var n = document.querySelector("p").firstChild, r = document.createRange(); r.setStart(n, 9); r.setEnd(n, 15); var s = getSelection(); s.removeAllRanges(); s.addRange(r); 1"#)
        guard await selection(tab) == "\"needle\"" else { return finish(false, "the page selection is not 'needle' before the item runs") }
        guard ctl.findBar.isHidden else { return finish(false, "the pill shows before the item runs") }
        let mark = MenuTable.mark
        guard let item = NSApp.mainMenu.flatMap({ m -> NSMenuItem? in
            func find(_ m: NSMenu) -> NSMenuItem? {
                for i in m.items { if i.title == "Use Selection for Find", i.identifier == mark { return i }; if let s = i.submenu, let f = find(s) { return f } }
                return nil
            }
            return find(m)
        }), let menu = item.menu, let at = menu.items.firstIndex(of: item) else { return finish(false, "no Use Selection for Find item") }
        menu.update()
        guard item.isEnabled else { return finish(false, "Use Selection for Find is disabled") }
        menu.performActionForItem(at: at)
        guard await until(10, { !ctl.findBar.isHidden && ctl.findBar.field.stringValue == "needle" && findCount() == "2 of 3" }) else {
            return finish(false, "Use Selection for Find: pill hidden \(ctl.findBar.isHidden), field '\(ctl.findBar.field.stringValue)', count '\(findCount())', want 'needle' and '2 of 3'")
        }
        finish(violations.isEmpty, "the page's selected word 'needle' fills the pill and is searched (2 of 3: the engine starts from the selected first match) \(violations)")
    }

    // MARK: zoom

    func zoom() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        let baseline = windowNumbers()
        let pill = ctl.toolbar.zoom
        func shows(_ v: String) -> Bool { !pill.isHidden && (pill.accessibilityValue() as? String) == v }
        guard pill.isHidden else { return finish(false, "the zoom pill shows at 100 percent") }
        // Chromium's own number: the renderer's devicePixelRatio scales with the page zoom factor (device scale times zoom).
        func dpr() async -> Double { Double(await evaluate(tab, "window.devicePixelRatio") ?? "") ?? 0 }
        let base = await dpr()
        guard base > 0 else { return finish(false, "no devicePixelRatio from the page") }

        func zoomIn() async -> String? {
            key("=", code: 24, [.command, .shift], chars: "+")
            let strays = await watchWindows(baseline)
            return strays.isEmpty ? nil : "a window appeared on Cmd++: \(strays.sorted())"
        }
        if let s = await zoomIn() { return finish(false, s) }
        if let s = await zoomIn() { return finish(false, s) }
        guard await until(5, { tab.zoomLevel == 1.0 }) else { return finish(false, "two Cmd++ left the level at \(tab.zoomLevel), want 1.0") }
        // The renderer applies the zoom a moment after the level changes: wait for its number to leave 100.
        var factor = 1.0
        for _ in 0..<50 {
            factor = (await dpr()) / base
            if Int((factor * 100).rounded()) != 100 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let reported = Int((factor * 100).rounded())
        guard await until(5, { shows("\(reported)%") }) else {
            return finish(false, "after two Cmd++ the pill shows hidden=\(pill.isHidden) '\(pill.accessibilityValue() ?? "nil")', Chromium's zoom factor is \(factor) (\(reported)%)")
        }
        key("0", code: 29)
        let atReset = await watchWindows(baseline)
        if !atReset.isEmpty { return finish(false, "a window appeared on Cmd+0: \(atReset.sorted())") }
        guard await until(5, { pill.isHidden && tab.zoomLevel == 0 }) else { return finish(false, "Cmd+0 left the pill hidden=\(pill.isHidden), level \(tab.zoomLevel)") }

        // The zoom is per host: a second tab on the same host shows the same zoom.
        if let s = await zoomIn() { return finish(false, s) }
        if let s = await zoomIn() { return finish(false, s) }
        guard let second = win.addTab(withURL: fixture("find.html"), activate: true) else { return finish(false, "no second tab") }
        guard await until(10, { win.activeTab === second && second.zoomLevel == 1.0 && shows("\(reported)%") }) else {
            return finish(false, "second tab on the same host: level \(second.zoomLevel), pill hidden=\(pill.isHidden) '\(pill.accessibilityValue() ?? "nil")', want 1.0 and \(reported)%")
        }
        // A click on the pill resets to 100 percent.
        guard click(pill) else { return finish(false, "the zoom pill is not what a click at its middle hits") }
        guard await until(5, { pill.isHidden && second.zoomLevel == 0 && tab.zoomLevel == 0 }) else { return finish(false, "the pill click left hidden=\(pill.isHidden), level \(second.zoomLevel)") }
        let strays = await watchWindows(baseline)
        guard strays.isEmpty else { return finish(false, "windows appeared during zoom: \(strays.sorted())") }
        finish(violations.isEmpty, "two Cmd++ show the percent Chromium reports (\(reported)%, devicePixelRatio ratio), Cmd+0 hides the pill, a second tab on the same host shows the same zoom, a click resets, no new window appeared \(violations)")
    }

    // MARK: find, more

    /// Two searches after each other: the second one's active match is the engine's, never the first one's number (a stale ordinal would show "2 of 3" with nothing active).
    func findRestart() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        guard await loadFind(tab) else { return finish(false, "find.html did not load (\(tab.url))") }
        let baseline = windowNumbers()
        key("f", code: 3)
        guard await until(5, { !ctl.findBar.isHidden && ctl.findBar.field.currentEditor() != nil }) else { return finish(false, "Cmd+F did not open the pill") }
        if let m = await typeInPill("need", baseline) { return finish(false, m) }
        guard await until(10, { findCount() == "1 of 3" }) else { return finish(false, "'need' shows '\(findCount())', want '1 of 3'") }
        key("g", code: 5)
        guard await until(10, { findCount() == "2 of 3" }) else { return finish(false, "Cmd+G on 'need' shows '\(findCount())', want '2 of 3'") }
        if let m = await typeInPill("le", baseline) { return finish(false, m) }
        // The new search ('needle') is a new session: its active match comes from the engine; the pill shows it and the state agrees.
        guard await until(10, { findCount() == "1 of 3" }) else { return finish(false, "after 'need' at 2 of 3, typing 'le' shows '\(findCount())', want '1 of 3'") }
        try? await Task.sleep(for: .milliseconds(500))
        guard findCount() == "1 of 3", ctl.finds[tab.identifier]?.active == 1 else { return finish(false, "the second search settled on '\(findCount())' (active \(String(describing: ctl.finds[tab.identifier]?.active))), want '1 of 3'") }
        // A different word: its own count (one match).
        ctl.findBar.field.currentEditor()?.selectAll(nil)
        if let m = await typeInPill("second", baseline) { return finish(false, m) }
        guard await until(10, { findCount() == "1 of 1" }) else { return finish(false, "'second' shows '\(findCount())', want '1 of 1'") }
        finish(violations.isEmpty, "a second search after 'need' at 2 of 3 shows its own active match (1 of 3), and another word shows 1 of 1")
    }

    /// Chromium's find bar closes on a main-frame navigation to another document, a reload included (find_bar_controller.cc:277-312); a same-document navigation leaves it.
    func findNavigation() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        guard await loadFind(tab) else { return finish(false, "find.html did not load (\(tab.url))") }
        let baseline = windowNumbers()
        func search() async -> String? {
            key("f", code: 3)
            guard await until(5, { !ctl.findBar.isHidden && ctl.findBar.field.currentEditor() != nil }) else { return "Cmd+F did not open the pill" }
            ctl.findBar.field.currentEditor()?.selectAll(nil)
            if let m = await typeInPill("needle", baseline) { return m }
            return await until(10, { findCount().hasSuffix(" of 3") }) ? nil : "needle shows '\(findCount())'"
        }
        if let m = await search() { return finish(false, m) }
        // Same document: a fragment change keeps the session.
        _ = await evaluate(tab, "location.hash = '#x'; 1")
        try? await Task.sleep(for: .milliseconds(600))
        guard !ctl.findBar.isHidden, ctl.finds[tab.identifier]?.text == "needle", findCount().hasSuffix(" of 3") else {
            return finish(false, "a same-document navigation changed the session: pill hidden \(ctl.findBar.isHidden), count '\(findCount())'")
        }
        // Another document: the session ends, Cmd+G opens an empty pill.
        var before = loads
        tab.loadURL(fixture(""))
        guard await until(10, { loads > before }) else { return finish(false, "the second document did not load") }
        guard await until(5, { ctl.findBar.isHidden && ctl.finds[tab.identifier] == nil }) else {
            return finish(false, "after navigating to another document the pill hidden=\(ctl.findBar.isHidden), state \(String(describing: ctl.finds[tab.identifier]))")
        }
        key("g", code: 5)
        guard await until(5, { !ctl.findBar.isHidden && ctl.findBar.field.stringValue.isEmpty && findCount().isEmpty }) else {
            return finish(false, "Cmd+G after the navigation: pill hidden \(ctl.findBar.isHidden), text '\(ctl.findBar.field.stringValue)', count '\(findCount())', want an empty pill")
        }
        press(.escape)
        // A reload is a new document too.
        guard await loadFind(tab) else { return finish(false, "find.html did not load again") }
        if let m = await search() { return finish(false, m) }
        before = loads
        tab.reload()
        guard await until(10, { loads > before }) else { return finish(false, "the reload did not finish") }
        guard await until(5, { ctl.findBar.isHidden && ctl.finds[tab.identifier] == nil }) else {
            return finish(false, "after a reload the pill hidden=\(ctl.findBar.isHidden), state \(String(describing: ctl.finds[tab.identifier]))")
        }
        if let m = await stray(baseline, "navigation") { return finish(false, m) }
        finish(violations.isEmpty, "a same-document navigation keeps the find session, another document and a reload end it (pill closed, state cleared), Cmd+G then opens an empty pill, no new window \(violations)")
    }

    /// The engine's own find accelerators (IDC_FIND, IDC_FIND_NEXT, IDC_FIND_PREVIOUS, IDC_CLOSE_FIND_OR_STOP) reach Noche's pill and never a Chromium find bar.
    func findEngine() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        guard await loadFind(tab) else { return finish(false, "find.html did not load (\(tab.url))") }
        let baseline = windowNumbers()
        var paths: [String] = []
        // The engine runs the command (ExecuteChromeCommand, which asks Noche's OnChromeCommand first); when it will not run it, the delegate is called as the bridge would.
        func command(_ name: String, _ id: Int) -> Bool {
            guard id >= 0 else { return false }
            if tab.testExecuteChromeCommandNamed(name) { paths.append("\(name) engine"); return true }
            paths.append("\(name) delegate")
            return ctl.window(win, shouldHandleChromeCommand: id)
        }
        guard command("IDC_FIND", ChromeCommand.find) else { return finish(false, "IDC_FIND was not answered by Noche") }
        guard await until(5, { !ctl.findBar.isHidden && ctl.findBar.field.currentEditor() != nil }) else { return finish(false, "IDC_FIND: pill hidden \(ctl.findBar.isHidden), field focused \(ctl.findBar.field.currentEditor() != nil)") }
        if let m = await stray(baseline, "IDC_FIND") { return finish(false, m) }
        if let m = await typeInPill("needle", baseline) { return finish(false, m) }
        guard await until(10, { findCount() == "1 of 3" }) else { return finish(false, "'needle' shows '\(findCount())', want '1 of 3'") }
        guard command("IDC_FIND_NEXT", ChromeCommand.findNext) else { return finish(false, "IDC_FIND_NEXT was not answered by Noche") }
        guard await until(10, { findCount() == "2 of 3" }) else { return finish(false, "IDC_FIND_NEXT shows '\(findCount())', want '2 of 3'") }
        if let m = await stray(baseline, "IDC_FIND_NEXT") { return finish(false, m) }
        guard command("IDC_FIND_PREVIOUS", ChromeCommand.findPrevious) else { return finish(false, "IDC_FIND_PREVIOUS was not answered by Noche") }
        guard await until(10, { findCount() == "1 of 3" }) else { return finish(false, "IDC_FIND_PREVIOUS shows '\(findCount())', want '1 of 3'") }
        if let m = await stray(baseline, "IDC_FIND_PREVIOUS") { return finish(false, m) }
        // Escape with the page focused is IDC_CLOSE_FIND_OR_STOP: with the pill showing it closes the pill.
        win.focusActiveContent()
        guard command("IDC_CLOSE_FIND_OR_STOP", ChromeCommand.closeFindOrStop) else { return finish(false, "IDC_CLOSE_FIND_OR_STOP was not answered by Noche while the pill shows") }
        guard await until(5, { ctl.findBar.isHidden && ctl.finds[tab.identifier] == nil }) else { return finish(false, "IDC_CLOSE_FIND_OR_STOP left the pill hidden=\(ctl.findBar.isHidden)") }
        // With no pill it is the engine's (it stops a load): Noche does not answer it.
        guard !ctl.window(win, shouldHandleChromeCommand: ChromeCommand.closeFindOrStop) else { return finish(false, "IDC_CLOSE_FIND_OR_STOP was answered with no pill showing") }
        if let m = await stray(baseline, "IDC_CLOSE_FIND_OR_STOP") { return finish(false, m) }
        finish(violations.isEmpty, "IDC_FIND, IDC_FIND_NEXT, IDC_FIND_PREVIOUS and IDC_CLOSE_FIND_OR_STOP reach Noche's pill (\(paths.joined(separator: ", "))), no new window")
    }

    /// Zoom changed inside the engine (not through the menu): the pill follows a Cmd+scroll event and a load.
    func zoomEngine() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        guard await loadFind(tab) else { return finish(false, "find.html did not load (\(tab.url))") }
        let pill = ctl.toolbar.zoom
        guard await until(5, { pill.isHidden }) else { return finish(false, "the zoom pill shows at 100 percent") }
        tab.zoomLevel = 1.0
        guard await until(5, { tab.zoomLevel == 1.0 }) else { return finish(false, "the engine kept level \(tab.zoomLevel)") }
        guard pill.isHidden else { return finish(false, "the pill followed before any event (hidden \(pill.isHidden))") }
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0) else { return finish(false, "no scroll event") }
        cg.flags = .maskCommand
        guard let ev = NSEvent(cgEvent: cg) else { return finish(false, "no NSEvent") }
        NSApp.sendEvent(ev)
        guard await until(5, { !pill.isHidden && (pill.accessibilityValue() as? String) == "120%" }) else {
            return finish(false, "after a Cmd+scroll event with the engine at level 1.0 the pill shows hidden=\(pill.isHidden) '\(pill.accessibilityValue() ?? "nil")', want 120%")
        }
        tab.zoomLevel = 0
        let before = loads
        tab.reload()
        guard await until(10, { loads > before }) else { return finish(false, "the reload did not finish") }
        guard await until(5, { pill.isHidden }) else { return finish(false, "after the load the pill still shows '\(pill.accessibilityValue() ?? "nil")' at level \(tab.zoomLevel)") }
        finish(violations.isEmpty, "a Cmd+scroll event makes the pill follow the engine's zoom (120%), and the pill is hidden again once a load ends at 100")
    }
}
#endif
