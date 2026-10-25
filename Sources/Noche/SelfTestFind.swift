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
        let textInput = Set(NSApp.windows.filter { let c = NSStringFromClass(type(of: $0)); return c.hasPrefix("TUI") || c == "SPRoundedWindow" }.map { Int($0.windowNumber) })
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

    func find() async {
        guard await ready(), let ctl, let win, let first = win.activeTab else { return }
        let before = loads
        first.loadURL(fixture("find.html"))
        guard await until(10, { loads > before && first.url.hasSuffix("find.html") }) else { return finish(false, "find.html did not load (\(first.url))") }
        let baseline = windowNumbers()
        BrowserWindowController.actionCounts = [:]
        guard ctl.findBar.isHidden else { return finish(false, "the find pill shows before Cmd+F") }

        key("f", code: 3)
        guard await until(5, { !ctl.findBar.isHidden && ctl.findBar.field.currentEditor() != nil }) else {
            return finish(false, "Cmd+F: pill hidden \(ctl.findBar.isHidden), field focused \(ctl.findBar.field.currentEditor() != nil) (keys \(keyLog))")
        }
        for ch in "needle" { ctl.findBar.field.currentEditor()?.insertText(String(ch)) }
        guard await until(10, { findCount().hasSuffix(" of 3") }) else { return finish(false, "typing the word that is on the page 3 times shows '\(findCount())', want '1 of 3'") }

        key("g", code: 5)
        guard await until(10, { findCount() == "2 of 3" }) else { return finish(false, "Cmd+G shows '\(findCount())', want '2 of 3'") }
        key("g", code: 5, [.command, .shift], chars: "G")
        guard await until(10, { findCount().hasSuffix(" of 3") }) else { return finish(false, "Shift+Cmd+G shows '\(findCount())', want '1 of 3'") }

        // Another tab: the pill hides; coming back restores it with its text and a working count.
        guard let second = win.addTab(withURL: fixture(""), activate: true) else { return finish(false, "no second tab") }
        guard await until(10, { win.activeTab === second && ctl.findBar.isHidden }) else { return finish(false, "after switching tab the pill is hidden=\(ctl.findBar.isHidden), active is second \(win.activeTab === second)") }
        win.activateTab(first)
        guard await until(10, { win.activeTab === first && !ctl.findBar.isHidden && ctl.findBar.field.stringValue == "needle" && findCount().hasSuffix(" of 3") }) else {
            return finish(false, "coming back: pill hidden \(ctl.findBar.isHidden), text '\(ctl.findBar.field.stringValue)', count '\(findCount())', want 'needle' and 'N of 3' (Chromium starts from the selection, so N is its choice)")
        }
        key("g", code: 5)
        guard await until(10, { findCount() == "2 of 3" }) else { return finish(false, "after the tab switch Cmd+G shows '\(findCount())', want '2 of 3'") }

        // Escape closes the pill and stopFinding(clear) leaves no selection: with the highlight kept (stopFinding(false)) the active match becomes the page's selection.
        key("f", code: 3)
        guard await until(5, { ctl.findBar.field.currentEditor() != nil }) else { return finish(false, "Cmd+F did not focus the field again") }
        press(.escape)
        guard await until(5, { ctl.findBar.isHidden && ctl.finds[first.identifier] == nil }) else { return finish(false, "Escape left the pill hidden=\(ctl.findBar.isHidden), state \(String(describing: ctl.finds[first.identifier]))") }
        var left = ""
        for _ in 0..<20 {
            left = await selection(first)
            if left == "\"\"" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard left == "\"\"" else { return finish(false, "Escape left the highlight: the page's selection is \(left)") }

        let strays = await watchWindows(baseline)
        guard strays.isEmpty else { return finish(false, "windows appeared during find: \(describeWindows(strays))") }
        let counts = BrowserWindowController.actionCounts
        guard counts["find"] == 2, counts["findNext"] == 2, counts["findPrevious"] == 1 else { return finish(false, "action counts \(counts), want find 2, findNext 2, findPrevious 1") }
        finish(violations.isEmpty, "Cmd+F opens the pill with the field focused, 'needle' shows 1 of 3, Cmd+G 2 of 3, Shift+Cmd+G 1 of 3, another tab hides the pill and coming back restores text and count, Escape closes it and leaves no page selection, no new window \(violations)")
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
        guard await until(10, { !ctl.findBar.isHidden && ctl.findBar.field.stringValue == "needle" && findCount().hasSuffix(" of 3") }) else {
            return finish(false, "Use Selection for Find: pill hidden \(ctl.findBar.isHidden), field '\(ctl.findBar.field.stringValue)', count '\(findCount())', want 'needle' and 'N of 3' (Chromium starts from the selection, so N is its choice)")
        }
        finish(violations.isEmpty, "the page's selected word 'needle' fills the pill and is searched (N of 3) \(violations)")
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
}
#endif
