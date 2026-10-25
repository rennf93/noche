#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Command bar checks (M1.3, research note section 6). Typing goes through the field editor's insertText, special keys are key events
/// handed to the first responder, clicks are mouse events sent through NSApp (so the bar's local monitor sees them).
extension SelfTest {
    enum Special { case escape, down, up, tab, enter, backspace }

    var bar: CommandBarController? { ctl?.commandBar }
    var barField: NSTextField? { ctl?.view(withIdentifier: "commandBar.input") as? NSTextField }
    var barEditor: NSText? { barField?.currentEditor() }
    var barText: String { barEditor?.string ?? barField?.stringValue ?? "" }
    func rowValue(_ i: Int) -> String? { ctl?.view(withIdentifier: "commandBar.row.\(i)")?.accessibilityValue() as? String }
    var rowValues: [String] { (0..<8).compactMap { rowValue($0) } }
    func barFrame() -> CGRect? { ctl?.frame(ofIdentifier: "commandBar") }
    func barOpen() -> Bool { bar?.isOpen == true && barFrame() != nil }
    func inPage() -> Bool {
        guard let ns = ctl?.nsWindow, let page = win?.webView, let r = ns.firstResponder as? NSView else { return false }
        return r === page || r.isDescendant(of: page)
    }

    func barType(_ s: String) { for ch in s { barEditor?.insertText(String(ch)) } }

    func press(_ k: Special, _ mods: NSEvent.ModifierFlags = []) {
        guard let ns = ctl?.nsWindow else { return }
        let (chars, code): (String, UInt16) = switch k {
        case .escape: ("\u{1b}", 53)
        case .down: (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        case .up: (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126)
        case .tab: ("\t", 48)
        case .enter: ("\r", 36)
        case .backspace: ("\u{7f}", 51)
        }
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: ns.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) else { return }
        ns.firstResponder?.keyDown(with: ev)
    }

    /// Cmd+L, then the bar is open with its field being edited.
    func openBar() async -> Bool {
        cmdL()
        return await until(5, { barOpen() && barEditor != nil && (ctl?.nsWindow?.firstResponder === barEditor) })
    }

    func closeBarNow() { bar?.close() }

    func seed(_ url: String, _ title: String, typed: Bool = false, ago: TimeInterval = 0) {
        try? app.writer?.store.recordVisit(url: url, title: title, typed: typed, at: Date().addingTimeInterval(-ago))
    }

    func fixtureTitleReady() async -> Bool {
        await until(10, { ctl?.list.items.first?.title == "Noche App Fixture" })
    }

    // MARK: cb-layout

    /// The note's tables 1a and 1c at this window size, from the formulas written out here (not from CommandBarLayout).
    func expectedCard(overlay: Bool, rows: Int, hidden: Bool, W: CGFloat, H: CGFloat) -> CGRect {
        let cx: CGFloat = hidden ? 6 : 197
        let header: CGFloat = overlay ? 55 : 60
        let pill = rows == 0 ? 60 : header + 40 * CGFloat(rows) + 13
        if overlay { return CGRect(x: cx + 106, y: 0, width: W - 265 - (cx + 106), height: pill + 47) }
        return CGRect(x: cx + (W - 6 - cx - 774) / 2, y: H / 2 - 78, width: 774, height: pill + 47)
    }

    func layoutOf(_ label: String, overlay: Bool, rows: Int, hidden: Bool) -> String? {
        guard let host = ctl?.window.chromeHost else { return "\(label): no window" }
        let want = expectedCard(overlay: overlay, rows: rows, hidden: hidden, W: host.bounds.width, H: host.bounds.height)
        guard let f = barFrame() else { return "\(label): no commandBar" }
        // Width of the overlay differs by 0.5 between the sidebar states in the note's two numbers.
        if abs(f.minX - want.minX) > 1 || abs(f.minY - want.minY) > 1 || abs(f.width - want.width) > 1 || abs(f.height - want.height) > 1 {
            return "\(label): \(f) want \(want)"
        }
        return nil
    }

    func cbLayout() async {
        guard await ready(), let ctl else { return }
        for i in 1...5 { seed("http://wx-\(i).test/page", "Weather \(i)", ago: Double(i)) }
        var bad: [String] = []
        func settle(_ cond: @escaping () -> Bool) async { _ = await until(2, cond) }
        // Overlay on the loaded page: empty, then 6 rows.
        guard await openBar() else { return finish(false, "Cmd+L opened no bar") }
        await settle { self.layoutOf("", overlay: true, rows: 0, hidden: false) == nil }
        if let m = layoutOf("overlay empty, sidebar shown", overlay: true, rows: 0, hidden: false) { bad.append(m) }
        barType("wx")
        guard await until(2, { rowValues.count == 6 }) else { return finish(false, "wx gave \(rowValues.count) rows: \(rowValues)") }
        if let m = layoutOf("overlay 6 rows, sidebar shown", overlay: true, rows: 6, hidden: false) { bad.append(m) }
        // Pixels drawn by AppKit: fill, border, the selected row.
        if let b = bar?.view {
            var samples: [String] = []
            let w = b.bounds.width
            for (name, p, literal) in [("fill", CGPoint(x: w - 200, y: 6), UInt32(0x282828)), ("border", CGPoint(x: 0, y: 150), UInt32(0x3E4042)),
                                       ("selected row", CGPoint(x: w - 60, y: 66), UInt32(0x464747))] {
                let got = pixel(b, p)
                guard let spec = swatchPixel(b, color: NSColor(hex: literal), at: CGPoint(x: w - 120, y: 300)) else { bad.append("no swatch for \(name)"); continue }
                samples.append("\(name)=\(got.map { "\($0)" } ?? "nil")")
                if !close(got, spec) { bad.append("pixel \(name) \(got.map { "\($0)" } ?? "nil"), the literal #\(String(literal, radix: 16)) renders as \(spec)") }
            }
            line("info", "pixels \(samples.joined(separator: " "))")
        }
        cmdS()
        guard await until(2, { ctl.sidebarHidden && ctl.cardX == 6 }) else { return finish(false, "sidebar did not hide: \(bad)") }
        await settle { self.layoutOf("", overlay: true, rows: 6, hidden: true) == nil }
        if let m = layoutOf("overlay 6 rows, sidebar hidden", overlay: true, rows: 6, hidden: true) { bad.append(m) }
        press(.escape)  // text and rows go: 0 rows, the bar stays open
        guard await until(2, { rowValues.isEmpty && barOpen() }) else { return finish(false, "Escape left rows \(rowValues) (\(bad))") }
        await settle { self.layoutOf("", overlay: true, rows: 0, hidden: true) == nil }
        if let m = layoutOf("overlay 0 rows, sidebar hidden", overlay: true, rows: 0, hidden: true) { bad.append(m) }
        barType("zzq")  // matches nothing: the literal query row only
        guard await until(2, { rowValues.count == 1 }) else { return finish(false, "zzq gave \(rowValues.count) rows: \(rowValues) (\(bad))") }
        if let m = layoutOf("overlay 1 row, sidebar hidden", overlay: true, rows: 1, hidden: true) { bad.append(m) }
        press(.escape); press(.escape)
        guard await until(2, { !barOpen() }) else { return finish(false, "the bar stayed open after two Escapes: \(bad)") }
        cmdS()
        guard await until(2, { !ctl.sidebarHidden && ctl.cardX == 197 }) else { return finish(false, "sidebar did not show: \(bad)") }
        // New Tab card: three starter rows when empty, 6 rows when typed, both sidebar states.
        cmdT()
        guard await until(10, { ctl.newTabShown && barOpen() && barEditor != nil }) else { return finish(false, "Cmd+T showed no New Tab card (\(bad))") }
        await settle { self.layoutOf("", overlay: false, rows: 3, hidden: false) == nil }
        if let m = layoutOf("card empty (3 starter rows), sidebar shown", overlay: false, rows: 3, hidden: false) { bad.append(m) }
        if rowValues.count != 3 || !rowValues.allSatisfy({ $0.hasPrefix("starter|") }) { bad.append("empty card rows \(rowValues)") }
        barType("wx")
        guard await until(2, { rowValues.count == 6 }) else { return finish(false, "card: wx gave \(rowValues.count) rows (\(bad))") }
        if let m = layoutOf("card 6 rows, sidebar shown", overlay: false, rows: 6, hidden: false) { bad.append(m) }
        if let b = bar?.view {
            let got = pixel(b, CGPoint(x: b.bounds.width - 60, y: 82))   // the selected row on the card starts at 62
            if let spec = swatchPixel(b, color: NSColor(hex: 0x464747), at: CGPoint(x: b.bounds.width - 120, y: 300)), !close(got, spec) { bad.append("card selected row pixel \(got.map { "\($0)" } ?? "nil") want \(spec)") }
        }
        cmdS()
        guard await until(2, { ctl.sidebarHidden && ctl.cardX == 6 }) else { return finish(false, "sidebar did not hide on the card: \(bad)") }
        await settle { self.layoutOf("", overlay: false, rows: 6, hidden: true) == nil }
        if let m = layoutOf("card 6 rows, sidebar hidden", overlay: false, rows: 6, hidden: true) { bad.append(m) }
        press(.escape)  // empty again: the 3 starter rows (a card never has 0 rows)
        guard await until(2, { rowValues.count == 3 }) else { return finish(false, "card Escape left \(rowValues) (\(bad))") }
        await settle { self.layoutOf("", overlay: false, rows: 3, hidden: true) == nil }
        if let m = layoutOf("card 3 starter rows, sidebar hidden", overlay: false, rows: 3, hidden: true) { bad.append(m) }
        barType("zzq")
        guard await until(2, { rowValues.count == 1 }) else { return finish(false, "card: zzq gave \(rowValues.count) rows (\(bad))") }
        if let m = layoutOf("card 1 row, sidebar hidden", overlay: false, rows: 1, hidden: true) { bad.append(m) }
        finish(bad.isEmpty && violations.isEmpty, "bar frames within 1 pt of notes tables 1a and 1c at \(Int(ctl.overlay.bounds.width))x\(Int(ctl.overlay.bounds.height)) (overlay empty and 6 rows, card empty and 6 rows, sidebar shown and hidden), fill, border and selected row pixels within 3 per channel \(bad) \(violations)")
    }

    // MARK: cb-open

    func cbOpen() async {
        guard await ready(), let ctl, let win, let ns = ctl.nsWindow else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        let want = String(url.dropLast())  // the page's URL without its trailing "/" (https:// would be dropped too; the fixture is http)
        guard await openBar() else { return finish(false, "Cmd+L: bar open=\(barOpen()) editor=\(barEditor != nil) first responder \(String(describing: ns.firstResponder))") }
        let sel = barEditor?.selectedRange ?? NSRange()
        let ok1 = bar?.placement == .overlay && barText == want && sel == NSRange(location: 0, length: (want as NSString).length) && !inPage()
        guard ok1 else { return finish(false, "Cmd+L on a loaded page: placement \(String(describing: bar?.placement)) text '\(barText)' (want '\(want)') selection \(sel) in page \(inPage())") }
        barType("x")
        guard barText == "x" else { return finish(false, "typing did not reach the field editor: '\(barText)'") }
        press(.escape); press(.escape)
        guard await until(5, { !barOpen() && inPage() }) else { return finish(false, "Escape twice did not close the bar and give the page typing back (open=\(barOpen()) in page \(inPage()))") }
        // The Chrome command Cmd+L would raise when the page view has focus is answered by Noche and opens the bar.
        // The engine's focus-location command, delivered to Noche's delegate exactly as the bridge's OnChromeCommand does: Noche must answer YES and open the bar.
        guard ChromeCommand.focusLocation >= 0 else { return finish(false, "IDC_FOCUS_LOCATION did not resolve in the engine") }
        guard ctl.window(win, shouldHandleChromeCommand: ChromeCommand.focusLocation) else { return finish(false, "IDC_FOCUS_LOCATION was not answered YES by Noche (the engine would handle it itself)") }
        guard await until(5, { barOpen() && barEditor != nil }) else { return finish(false, "IDC_FOCUS_LOCATION was answered YES but opened no bar") }
        closeBarNow()
        // Whether the engine itself runs the command on a tab is its own enablement (CanExecuteChromeCommand); when it does, it must reach the bar too.
        if let tab = win.activeTab, tab.testExecuteChromeCommandNamed("IDC_FOCUS_LOCATION") {
            guard await until(5, { barOpen() && barEditor != nil }) else { return finish(false, "the engine ran IDC_FOCUS_LOCATION and no bar opened") }
            closeBarNow()
            line("info", "engine CanExecuteChromeCommand(IDC_FOCUS_LOCATION)=yes, reached the bar")
        } else {
            line("info", "engine CanExecuteChromeCommand(IDC_FOCUS_LOCATION)=no (hidden runs cannot raise it through the engine; the accelerator is an owner check)")
        }
        // A New Tab: the card, not an overlay; its field is focused; the page surface is hidden and stays hidden.
        cmdT()
        guard await until(10, { ctl.newTabShown && barOpen() && barEditor != nil && ns.firstResponder === barEditor }) else {
            return finish(false, "Cmd+T: card shown=\(ctl.newTabShown) open=\(barOpen()) editor=\(barEditor != nil)")
        }
        try? await Task.sleep(for: .seconds(1))  // the engine's later active-tab report must not clear the hidden surface (ruling R14)
        guard bar?.placement == .newTab, win.webContentHidden, ctl.view(withIdentifier: "newTabPage") != nil, win.webView == nil else {
            return finish(false, "New Tab: placement \(String(describing: bar?.placement)) hidden \(win.webContentHidden) newTabPage \(ctl.view(withIdentifier: "newTabPage") != nil) page view \(win.webView != nil)")
        }
        press(.escape)  // empty text: the card loses focus
        guard await until(5, { barEditor == nil && barOpen() }) else { return finish(false, "Escape on the empty card did not unfocus it") }
        cmdL()
        guard await until(5, { barEditor != nil && bar?.placement == .newTab }) else { return finish(false, "Cmd+L on the New Tab did not focus the card") }
        finish(violations.isEmpty, "Cmd+L on a loaded page: overlay, text '\(want)' fully selected, the field editor (not the page) is first responder and takes typing; Escape twice closes it and the page view is first responder again; IDC_FOCUS_LOCATION opens it; Cmd+T shows the focused card over a hidden page surface (stays hidden for 1 s), Cmd+L on it refocuses \(violations)")
    }

    // MARK: cb-motion

    func cbMotion() async {
        guard await ready(), let bar = bar else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        bar.motionLog = []
        guard await openBar() else { return finish(false, "no bar") }
        let t0 = bar.motionStart
        _ = await until(1, { (self.barFrame()?.height ?? 0) >= 107 && ProcessInfo.processInfo.systemUptime - t0 > 0.127 })
        let log = bar.motionLog
        var bad: [String] = []
        var last: CGFloat = 0
        for (t, h) in log {
            let fit = OverlayMotion.height(at: t - t0)
            if abs(h - fit) > 2 { bad.append("t=\(Int((t - t0) * 1000)) ms height \(h) fit \(fit)") }
            if h < last { bad.append("height fell \(last) to \(h)") }
            if h > 107.01 { bad.append("overshoot \(h)") }
            last = h
        }
        if log.count < 4 { bad.append("only \(log.count) frames, no motion") }
        if let first = log.first, first.h > 100 { bad.append("first frame already \(first.h)") }
        let finalHeight = barFrame()?.height ?? 0
        if abs(finalHeight - 107) > 0.5 { bad.append("final height \(finalHeight)") }
        // The captured curve (note section 1c) at its sample times, from the same fit: 41 at 0, 107 at 107 ms.
        if abs(OverlayMotion.height(at: 0) - 41) > 0.01 || abs(OverlayMotion.height(at: 0.107) - 107) > 0.01 { bad.append("curve ends are not 41 and 107") }
        press(.escape); press(.escape)
        let closedAtOnce = !barOpen()  // no waiting: close is instant
        if !closedAtOnce { bad.append("Escape did not close within the run-loop turn") }
        finish(bad.isEmpty && violations.isEmpty, "Cmd+L: \(log.count) frames, monotonic, each within 2 pt of the 107 ms ease-out fit, none above 107, final 107, Escape closed at once \(bad) \(violations)")
    }

    // MARK: cb-go

    func cbGo() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let port = URL(string: url)?.port, let store = app.writer?.store else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        let host = "127.0.0.1:\(port)"
        func go(_ text: String) async -> Bool {
            let before = loads
            guard await openBar() else { return false }
            barType(text)
            press(.enter)
            return await until(15, { loads > before })
        }
        guard await go("\(host)/b.html") else { return finish(false, "typed host and path did not load") }
        guard await until(5, { ctl.list.displayTitle(of: ctl.list.items[0].id) == "B Page" && tab.url.hasSuffix("/b.html") }) else {
            return finish(false, "after load: title \(ctl.list.displayTitle(of: ctl.list.items[0].id)) url \(tab.url)")
        }
        guard await until(5, { inPage() && !barOpen() }) else { return finish(false, "Return did not close the bar and return typing to the page (open \(barOpen()) in page \(inPage()))") }
        guard await until(5, { self.page(store, host: host, path: "/b.html")?.typedCount == 1 }) else {
            return finish(false, "history has no typed page row for b.html: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        guard await go("two words") else { return finish(false, "search did not load") }
        guard tab.url.contains("/search?q=two%20words") else { return finish(false, "search went to \(tab.url)") }
        // Typed javascript: and data: text searches, it never navigates.
        let title0 = await evaluate(tab, "document.title")
        for text in ["javascript:document.title='pwned'", "data:text/html,pwned"] {
            guard await go(text) else { return finish(false, "\(text) did not load a search") }
            guard tab.url.hasPrefix(url + "search?q=") else { return finish(false, "\(text) went to \(tab.url)") }
        }
        // A stored row with such a URL is refused: no load, no script.
        guard await go("\(host)/b.html") else { return finish(false, "back to b.html did not load") }
        let title1 = await evaluate(tab, "document.title")
        let urlBefore = tab.url
        for bad in ["javascript:document.title='pwned'", "data:text/html,pwned", "ftp://x.test/"] {
            guard await openBar(), let ctl = self.ctl else { return finish(false, "no bar for the stored row \(bad): open=\(barOpen()) editor=\(barEditor != nil) first responder \(String(describing: self.ctl?.nsWindow?.firstResponder)) placement \(String(describing: bar?.placement)) tab url \(tab.url) blank=\(self.ctl?.newTabShown ?? false)") }
            ctl.commandBar.run(Suggestion(kind: .page, title: bad, url: bad, tabID: nil, frecency: 1), newTab: false)
            try? await Task.sleep(for: .milliseconds(400))
            if tab.url != urlBefore { return finish(false, "a stored row with \(bad) navigated to \(tab.url)") }
        }
        let title2 = await evaluate(tab, "document.title")
        guard title1 == "\"B Page\"", title2 == title1, title0 != nil else { return finish(false, "page title after the refused rows: \(title2 ?? "nil") (was \(title1 ?? "nil"))") }
        finish(violations.isEmpty, "typed host/path and 'two words' load, Return gives the page typing back and the typed visit is in history; typed javascript: and data: text searches; stored rows with javascript:, data: and ftp: URLs load nothing and run nothing \(violations)")
    }

    // MARK: cb-escape

    func cbEscape() async {
        guard await ready(), let ctl, let win else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        seed("http://wx-1.test/page", "Weather 1")
        guard await openBar() else { return finish(false, "no bar") }
        barType("wx")
        guard await until(2, { !rowValues.isEmpty }) else { return finish(false, "no rows for wx") }
        press(.escape)
        guard await until(2, { barText.isEmpty && rowValues.isEmpty && barOpen() }) else {
            return finish(false, "Escape 1: text '\(barText)' rows \(rowValues.count) open \(barOpen())")
        }
        press(.escape)
        guard await until(5, { !barOpen() && inPage() }) else { return finish(false, "Escape 2 on a loaded page: open \(barOpen()) in page \(inPage())") }
        // New Tab: Escape clears, a second Escape unfocuses; the page surface stays hidden under the card.
        cmdT()
        guard await until(10, { ctl.newTabShown && barEditor != nil }) else { return finish(false, "no New Tab card") }
        barType("wx")
        guard await until(2, { !rowValues.isEmpty && rowValues[0].hasPrefix("page|") || rowValues.contains { $0.hasPrefix("query|") } }) else { return finish(false, "no rows on the card") }
        press(.escape)
        guard await until(2, { barText.isEmpty && rowValues.count == 3 && barEditor != nil }) else {
            return finish(false, "card Escape 1: text '\(barText)' rows \(rowValues) editor \(barEditor != nil)")
        }
        press(.escape)
        guard await until(5, { barEditor == nil && barOpen() && win.webContentHidden }) else { return finish(false, "card Escape 2: editor \(barEditor != nil) open \(barOpen()) hidden \(win.webContentHidden)") }
        finish(violations.isEmpty, "loaded page: Escape clears text and rows with the bar still open, a second Escape closes it and the page view is first responder; New Tab: Escape clears to the 3 starter rows, a second Escape unfocuses the card \(violations)")
    }

    // MARK: cb-arrows

    func cbArrows() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let port = URL(string: url)?.port else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        let host = "127.0.0.1:\(port)"
        for (i, ago) in [(1, 30.0), (2, 20.0), (3, 10.0)] { seed("http://\(host)/b.html?n=\(i)", "Arrows \(i)", ago: ago) }
        guard await openBar() else { return finish(false, "no bar") }
        let typed = "\(host)/b.html?n"
        barType(typed)
        guard await until(2, { rowValues.count >= 5 }) else { return finish(false, "rows for the prefix: \(rowValues)") }
        guard let rows = bar?.state.rows, rows.count >= 3, rows[0].kind == .page, let top = rows[0].url else { return finish(false, "no page top hit: \(rowValues)") }
        let full = urlDisplay(top)
        let remainder = (full as NSString).substring(from: (typed as NSString).length)
        guard barText == full, barEditor?.selectedRange == NSRange(location: (typed as NSString).length, length: (remainder as NSString).length) else {
            return finish(false, "inline: text '\(barText)' selection \(String(describing: barEditor?.selectedRange)) want '\(full)' remainder '\(remainder)'")
        }
        press(.down); press(.down)
        let third = bar?.state.rows[2]
        let want3 = third.map { $0.kind == .query ? $0.title : urlDisplay($0.url ?? $0.title) } ?? "?"
        guard bar?.state.selected == 2, barText == want3, barEditor?.selectedRange.length == 0 else {
            return finish(false, "Down twice: selected \(String(describing: bar?.state.selected)) text '\(barText)' want '\(want3)' selection \(String(describing: barEditor?.selectedRange))")
        }
        press(.down); press(.down); press(.down); press(.down); press(.down); press(.down); press(.down)
        let lastIndex = (bar?.state.rows.count ?? 1) - 1
        guard bar?.state.selected == lastIndex else { return finish(false, "Down past the end wrapped: selected \(String(describing: bar?.state.selected)) of \(lastIndex)") }
        for _ in 0..<(lastIndex + 3) { press(.up) }
        guard bar?.state.selected == 0, barText == full, barEditor?.selectedRange == NSRange(location: (typed as NSString).length, length: (remainder as NSString).length) else {
            return finish(false, "Up to the top: selected \(String(describing: bar?.state.selected)) text '\(barText)' selection \(String(describing: barEditor?.selectedRange))")
        }
        press(.tab)
        guard barText == full, barEditor?.selectedRange == NSRange(location: (full as NSString).length, length: 0) else {
            return finish(false, "Tab: text '\(barText)' selection \(String(describing: barEditor?.selectedRange)), want the remainder accepted with the caret at the end")
        }
        // Tab with no remainder acts like Down.
        press(.tab)
        guard bar?.state.selected == 1 else { return finish(false, "Tab without a remainder left selected at \(String(describing: bar?.state.selected))") }
        press(.up)
        let before = loads
        press(.enter)
        guard await until(15, { loads > before && tab.url == top }) else { return finish(false, "Return on the top row went to \(tab.url), want \(top)") }
        _ = ctl
        finish(violations.isEmpty, "prefix of 3 stored pages: inline remainder selected, Down twice follows row 3 (field text '\(want3)'), no wrap at the ends, Up returns to the typed text with the remainder, Tab accepts it (caret at the end), Tab then moves down, Return runs the selected row \(violations)")
    }

    // MARK: cb-inline

    func cbInline() async {
        guard await ready() else { return }
        let u = "https://weathercrave.com/weather-forecast-italy/country-89/weather-forecast-italy-next-sunday"
        seed(u, "Italy Weather Forecast : free 15 day weather forecasts - Weather Crave")
        guard await openBar() else { return finish(false, "no bar") }
        let full = urlDisplay(u)
        func state() -> String { "text '\(barText)' selection \(String(describing: barEditor?.selectedRange))" }
        barType("weather")
        let rem = (full as NSString).substring(from: 7)
        guard await until(2, { barText == full && barEditor?.selectedRange == NSRange(location: 7, length: (rem as NSString).length) }) else {
            return finish(false, "typing 'weather': \(state()), want '\(full)' with '\(rem)' selected")
        }
        press(.backspace)
        guard barText == "weather", barEditor?.selectedRange.length == 0, barEditor?.selectedRange.location == 7 else {
            return finish(false, "Backspace after the completion: \(state()), want the completion deleted ('weather', caret 7)")
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard barText == "weather" else { return finish(false, "the bar completed again after Backspace: \(state())") }
        press(.backspace)
        guard barText == "weathe", barEditor?.selectedRange.length == 0 else { return finish(false, "second Backspace: \(state())") }
        barType("r")
        guard await until(2, { barText == full }) else { return finish(false, "typing after a delete did not complete again: \(state())") }
        // Case as typed stays; a title-only match and a space never complete.
        press(.escape)
        barType("Weather")
        guard barText == "Weather" + rem else { return finish(false, "case: \(state()), want 'Weather' + the lowercase remainder") }
        // A delete that changes nothing (empty field) must not leave "just deleted" armed for the next character.
        press(.escape)
        press(.backspace)
        barType("w")
        guard await until(2, { barText == full }) else { return finish(false, "after a Backspace on an empty field the next character did not complete: \(state())") }
        press(.escape)
        barType("weather forecast")
        guard barText == "weather forecast" else { return finish(false, "a space completed: \(state())") }
        press(.escape)
        barType("italy")
        guard barText == "italy" else { return finish(false, "a title-only match completed: \(state())") }
        finish(violations.isEmpty, "'weather' completes to the stored page's URL with the remainder selected; Backspace deletes the completion and nothing completes again (also after a second Backspace); typing again completes; case as typed; no completion with a space or for a title-only match \(violations)")
    }

    // MARK: cb-switch-tab

    func cbSwitchTab() async {
        guard await ready(), let ctl, let win, let a = win.activeTab else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        let before = loads
        guard let b = win.addTab(withURL: fixture("b.html"), activate: false) else { return finish(false, "no tab B") }
        guard await until(15, { loads > before && ctl.list.items.count == 2 && b.url.hasSuffix("b.html") }) else { return finish(false, "tab B did not load") }
        cmdT()
        guard await until(10, { rowCount == 3 && ctl.newTabShown && barEditor != nil }) else { return finish(false, "no blank New Tab (rows \(rowCount))") }
        let blank = win.activeTab
        let engineTabs = win.tabs.count
        barType("noche app")
        guard await until(2, { bar?.state.rows.contains { $0.tabID != nil } == true }) else { return finish(false, "no row for the open tab A: \(rowValues)") }
        while let s = bar?.state, s.rows[s.selected].tabID == nil { press(.down) }
        press(.enter)
        guard await until(10, { win.activeTab === a && !barOpen() }) else { return finish(false, "Return on the tab row left the active tab at \(win.activeTab?.url ?? "nil")") }
        try? await Task.sleep(for: .milliseconds(500))
        let ok = win.tabs.count == engineTabs && rowCount == engineTabs && ctl.list.items.count == engineTabs && win.tabs.contains { $0 === blank }
            && !ctl.newTabShown && ctl.sidebar.rows.count == win.tabs.count && !win.webContentHidden
        finish(ok && violations.isEmpty, "a row for the open tab A switched to it: engine tabs \(win.tabs.count) (was \(engineTabs)), sidebar rows \(ctl.sidebar.rows.count), list \(ctl.list.items.count), the blank tab stays, page surface visible again \(violations)")
        _ = b
    }

    // MARK: cb-outside

    /// A left mouse-down through NSApp (so the bar's local monitor sees it); the event, for the caller to deliver to its target.
    func mouseDown(at p: NSPoint) -> NSEvent? {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                  windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        NSApp.sendEvent(ev)
        return ev
    }

    func cbOutside() async {
        guard await ready(), let ctl, let barView = bar?.view else { return }
        guard await openBar() else { return finish(false, "no bar") }
        // Inside the card (a free spot): nothing closes.
        let inside = mouseDown(at: barView.convert(NSPoint(x: barView.bounds.width - 8, y: 20), to: nil))
        try? await Task.sleep(for: .milliseconds(200))
        guard let inside, bar?.mouseSeen === inside else { return finish(false, "the bar's click monitor did not see the click on the card") }
        guard barOpen() else { return finish(false, "a click on the card closed the bar") }
        // Outside: on the sidebar toggle. The bar closes and the toggle still gets its click.
        let before = BrowserWindowController.actionCounts["toggleSidebar"] ?? 0
        let t = ctl.toolbar.toggle
        let outside = mouseDown(at: t.convert(NSPoint(x: t.bounds.midX, y: t.bounds.midY), to: nil))
        guard await until(3, { !barOpen() }) else { return finish(false, "a click outside left the bar open") }
        // The monitor handed the event back untouched; a hidden window never delivers synthesized mouse events itself, so the click goes to its target here.
        guard let outside, bar?.mouseSeen === outside else { return finish(false, "the monitor did not return the click it handled") }
        click(t)
        let reached = await until(3, { (BrowserWindowController.actionCounts["toggleSidebar"] ?? 0) == before + 1 })
        finish(reached && violations.isEmpty, "a click on the card kept the bar open; a click on the sidebar toggle closed it (the monitor returned the event untouched) and the toggle took its click (toggleSidebar \(BrowserWindowController.actionCounts["toggleSidebar"] ?? 0), was \(before)) \(violations)")
    }

    // MARK: cb-nonet

    func serverSuggestRequests() -> Int {
        guard let path = ProcessInfo.processInfo.environment["NOCHE_TEST_SERVER_LOG"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return -1 }
        return text.split(separator: "\n").filter { $0.contains("GET /suggest.json") }.count
    }

    func cbNonet() async {
        guard await ready(), let ctl, let store = app.writer?.store else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        guard (try? store.setting("suggestRemote")) == "1" else { return finish(false, "suggestRemote is not 1 (the script passes --selftest-setting)") }
        let s0 = serverSuggestRequests(), a0 = RemoteSuggest.requests.count
        guard s0 >= 0 else { return finish(false, "no NOCHE_TEST_SERVER_LOG from the script") }
        guard await openBar() else { return finish(false, "no bar") }
        // 7 characters in one turn, then 7 more a little apart (30 ms): the debounce sends at most one request per 100 ms window.
        barType("weather")
        guard await until(3, { RemoteSuggest.requests.count > a0 }) else { return finish(false, "no request after typing with the setting on") }
        try? await Task.sleep(for: .milliseconds(600))
        let first = RemoteSuggest.requests.count - a0
        press(.escape)
        for ch in "forecast" { barType(String(ch)); try? await Task.sleep(for: .milliseconds(30)) }
        try? await Task.sleep(for: .milliseconds(700))
        let all = Array(RemoteSuggest.requests.dropFirst(a0))
        let gaps = zip(all, all.dropFirst()).map { $1.time - $0.time }
        let sent = serverSuggestRequests() - s0
        guard first <= 2, all.count <= 3, (gaps.min() ?? 1) >= 0.099, sent == all.count else {
            return finish(false, "7 fast keystrokes sent \(first) requests, 14 keystrokes sent \(all.count) (server saw \(sent)), smallest gap \(gaps.min().map { "\($0)" } ?? "none") s; want at most 2 and 3, gaps of 100 ms or more, server equal to the app")
        }
        guard all.allSatisfy({ $0.host == "127.0.0.1" }), RemoteSuggest.foreign == 0 else { return finish(false, "request hosts \(all.map(\.host)) foreign \(RemoteSuggest.foreign)") }
        // URL-like text and a single character send nothing.
        let mark = RemoteSuggest.requests.count
        for text in ["example.com", "http://x.test/a", "1234", "a"] {
            press(.escape); barType(text)
            try? await Task.sleep(for: .milliseconds(350))
        }
        guard RemoteSuggest.requests.count == mark else { return finish(false, "URL-like or short text sent \(RemoteSuggest.requests.count - mark) requests") }
        // The answer shows as query rows after the query row.
        press(.escape); barType("weather")
        guard await until(3, { bar?.state.rows.contains { $0.kind == .remoteQuery && $0.title == "weather today" } == true }) else { return finish(false, "no remote query rows: \(rowValues)") }
        // The setting off: nothing is sent, read at each keystroke.
        try? store.setSetting("suggestRemote", "0")
        let s1 = serverSuggestRequests(), a1 = RemoteSuggest.requests.count
        press(.escape); barType("weather map")
        try? await Task.sleep(for: .milliseconds(700))
        guard serverSuggestRequests() == s1, RemoteSuggest.requests.count == a1 else { return finish(false, "with the setting 0 the server saw \(serverSuggestRequests() - s1) requests") }
        _ = ctl
        finish(violations.isEmpty, "setting 1: 7 keystrokes in one turn sent \(first) request, 14 spaced keystrokes sent \(all.count) (server saw \(sent), gaps >= 100 ms), all to 127.0.0.1 with no foreign host; URL-like and 1-character text sent none; rows show the answer; setting 0 sent none \(violations)")
    }

    /// No `suggestRemote` setting at all (the default): typing sends nothing, though an endpoint is configured.
    func cbNonetDefault() async {
        guard await ready(), let store = app.writer?.store else { return }
        guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
        guard ((try? store.setting("suggestRemote")) ?? nil) == nil else { return finish(false, "a suggestRemote setting exists in a fresh profile") }
        guard CommandLine.arguments.contains("--selftest-suggest-url") else { return finish(false, "no suggest endpoint configured: the check would prove nothing") }
        let s0 = serverSuggestRequests(), a0 = RemoteSuggest.requests.count
        guard s0 >= 0, await openBar() else { return finish(false, "no bar or no server log") }
        barType("weather")
        try? await Task.sleep(for: .milliseconds(700))
        press(.escape); barType("forecast")
        try? await Task.sleep(for: .milliseconds(700))
        finish(RemoteSuggest.requests.count == a0 && serverSuggestRequests() == s0 && RemoteSuggest.foreign == 0 && violations.isEmpty,
               "no suggestRemote setting: typing 15 characters sent \(RemoteSuggest.requests.count - a0) requests (server saw \(serverSuggestRequests() - s0)), none \(violations)")
    }

    // MARK: cb-history (two-phase)

    func cbHistory() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let port = URL(string: url)?.port, let store = app.writer?.store else { return }
        let host = "127.0.0.1:\(port)"
        if phase == 1 {
            guard await fixtureTitleReady() else { return finish(false, "no fixture title") }
            let before = loads
            guard await openBar() else { return finish(false, "no bar") }
            barType("\(host)/b.html")
            press(.enter)
            guard await until(15, { loads > before && tab.url.hasSuffix("/b.html") }) else { return finish(false, "typed navigation did not load b.html (\(tab.url))") }
            guard await until(10, { self.page(store, host: host, path: "/b.html").map { $0.typedCount == 1 && $0.title == "B Page" } ?? false }) else {
                return finish(false, "phase 1: the typed visit is not in history: \((try? store.pageCandidates(prefix: host)) ?? [])")
            }
            return finish(true, "phase 1: a typed navigation through the bar left a page row (typed 1, title B Page)")
        }
        guard await openBar() else { return finish(false, "phase 2: no bar") }
        barType("B Pa")
        let ok = await until(3, { bar?.state.rows.contains { $0.kind == .page && ($0.url ?? "").hasSuffix("/b.html") } == true })
        finish(ok && violations.isEmpty, "phase 2 (relaunch): typing 'B Pa' shows the stored b.html page as a row (\(rowValues)) \(violations)")
        _ = ctl
    }
}
#endif
