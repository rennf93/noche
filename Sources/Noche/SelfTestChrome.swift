#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Chrome and layout checks: page view insets, geometry and pixels, long titles, menu, sidebar motion and scrolling.
extension SelfTest {
    /// webInsets and webCornerRadius: the page view's rect inside the window, and the bottom-corner mask.
    func webInsets() async {
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        guard let win = app.windows.first, let ns = win.nsWindow, let content = ns.contentView else { return finish(false, "no window") }
        win.webInsets = NSEdgeInsets(top: 48, left: 198, bottom: 7, right: 7)
        // The same insets again must not rebuild the layout or the mask (they are set on every tick of the sidebar motion).
        _ = await until(5, { win.testLayoutPasses > 0 })
        let passes = (win.testLayoutPasses, win.testMaskPasses)
        for _ in 0..<5 { win.webInsets = NSEdgeInsets(top: 48, left: 198, bottom: 7, right: 7) }
        guard (win.testLayoutPasses, win.testMaskPasses) == passes else {
            return finish(false, "setting the same insets 5 times rebuilt the layout \(win.testLayoutPasses - passes.0) times and the mask \(win.testMaskPasses - passes.1) times")
        }
        // Window base coordinates have the origin bottom-left, so the bottom inset is the rect's minY.
        let size = content.convert(content.bounds, to: nil).size
        let want = NSRect(x: 198, y: 7, width: size.width - 198 - 7, height: size.height - 48 - 7)
        func rect() -> NSRect? { win.webView.map { $0.convert($0.bounds, to: nil) } }
        func near(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
        }
        guard await until(10, { rect().map { near($0, want) } ?? false }) else {
            return finish(false, "page view rect \(rect().map { "\($0)" } ?? "nil") != expected \(want) (window \(size))")
        }
        let r = rect()!
        win.webCornerRadius = 10
        guard await until(10, { win.webMaskExists }) else { return finish(false, "no mask after webCornerRadius = 10") }
        func inside(_ x: CGFloat, _ y: CGFloat) -> Bool { win.webMaskContains(NSPoint(x: x, y: y)) }
        let e: CGFloat = 0.5
        let covered = inside(r.midX, r.midY) && inside(r.midX, r.minY + e) && inside(r.midX, r.maxY - e)
            && inside(r.minX + e, r.midY) && inside(r.maxX - e, r.midY)
        let topSquare = inside(r.minX + e, r.maxY - e) && inside(r.maxX - e, r.maxY - e)
        let bottomRound = !inside(r.minX + e, r.minY + e) && !inside(r.maxX - e, r.minY + e)
        finish(covered && topSquare && bottomRound, "view \(r) window \(size): covers bounds=\(covered) top corners square=\(topSquare) bottom corners rounded=\(bottomRound)")
    }

    /// The color of a window point drawn by AppKit (cacheDisplay), origin top-left.
    /// The color AppKit rendered at |p| of |view| (cacheDisplay of the view, origin top-left), as sRGB bytes.
    func pixel(_ view: NSView, _ p: CGPoint) -> (Int, Int, Int)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / view.bounds.width
        guard let c = rep.colorAt(x: Int(p.x * k), y: Int(p.y * k))?.usingColorSpace(.sRGB) else { return nil }
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    /// Inside a window AppKit converts by the display profile, so the expected value is what the same pipeline gives for a
    /// swatch of exactly the wanted color, laid over |view| at |at| (a 6x6 point area).
    func swatchPixel(_ view: NSView, color: NSColor, at: CGPoint) -> (Int, Int, Int)? {
        final class Swatch: NSView {
            override var isFlipped: Bool { true }
            var color = NSColor.black
            override func draw(_ r: NSRect) { color.setFill(); bounds.fill() }
        }
        let sw = Swatch(frame: NSRect(x: at.x, y: at.y, width: 6, height: 6))
        sw.color = color
        view.addSubview(sw)
        defer { sw.removeFromSuperview() }
        return pixel(view, CGPoint(x: at.x + 3, y: at.y + 3))
    }
    func hex(_ v: UInt32) -> (Int, Int, Int) { (Int(v >> 16 & 255), Int(v >> 8 & 255), Int(v & 255)) }
    func close(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)) -> Bool {
        guard let a else { return false }
        return abs(a.0 - b.0) <= 3 && abs(a.1 - b.1) <= 3 && abs(a.2 - b.2) <= 3
    }

    /// Every identified view against live-ui.md sections 2 to 4, for the sidebar state it is in now. Returns the failures.
    func layoutFailures(hiddenSidebar: Bool, tabs: Int) -> [String] {
        guard let ctl, let host = ctl.window.chromeHost else { return ["no window"] }
        let W = host.bounds.width, H = host.bounds.height
        var bad: [String] = []
        func expect(_ id: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            let f = ctl.frame(ofIdentifier: id)
            if !near(f, x, y, w, h) { bad.append("\(id) \(f.map { "\($0)" } ?? "missing") want (\(x), \(y), \(w), \(h))") }
        }
        let cx: CGFloat = hiddenSidebar ? 6 : 197, cw = W - 6 - cx
        let d: CGFloat = hiddenSidebar ? -191 : 0  // toolbar items sit at the same offset from the card either way
        if hiddenSidebar {
            if let f = ctl.frame(ofIdentifier: "sidebar"), f.maxX > 0 { bad.append("sidebar on screen \(f)") }
            if ctl.sidebar.lights.contains(where: { !$0.isHidden }) { bad.append("traffic lights visible") }
        } else {
            expect("sidebar", 0, 0, 197, H)
            for (i, id) in ["window.close", "window.minimize", "window.zoom"].enumerated() { expect(id, [17, 40, 63][i], 19, 16, 16) }
            expect("sidebar.newTab", 6, 54, 185, 39)
            for i in 0..<tabs { expect("sidebar.tab.\(i)", 6, 93 + 37 * CGFloat(i), 185, 37) }
        }
        expect("card", cx, 6, cw, H - 12)
        expect("toolbar", cx, 6, cw, 42)
        for (i, id) in ["toolbar.sidebarToggle", "toolbar.back", "toolbar.forward", "toolbar.reload"].enumerated() {
            expect(id, 202 + d + 35 * CGFloat(i), 11, 32, 32)
        }
        if let f = ctl.frame(ofIdentifier: "toolbar.address") {
            if abs(f.minX - (350 + d)) > 1 || abs(f.minY - 12) > 1 || abs(f.height - 30) > 1 { bad.append("toolbar.address \(f) want x \(350 + d) y 12 h 30") }
        } else { bad.append("toolbar.address missing") }
        expect("toolbar.divider", cx, 47, cw, 1)
        if let web = win?.webView.map({ $0.convert($0.bounds, to: nil) }) {
            let want = NSRect(x: cx + 1, y: 7, width: W - cx - 1 - 7, height: H - 48 - 7)
            if abs(web.minX - want.minX) > 1 || abs(web.minY - want.minY) > 1 || abs(web.width - want.width) > 1 || abs(web.height - want.height) > 1 {
                bad.append("web view \(web) want \(want)")
            }
        } else { bad.append("no web view") }
        if win?.webMaskExists != true { bad.append("no bottom corner mask") }
        return bad
    }

    func layout() async {
        guard await ready(), let ctl, let win, let ns = ctl.nsWindow, let host = win.chromeHost else { return }
        guard await openTabs(3) else { return finish(false, "3 rows never appeared (rows=\(rowCount))") }
        let W = host.bounds.width, H = host.bounds.height
        line("info", "window \(W)x\(H) frame \(ns.frame) screen \(ns.screen.map { "\($0.frame) visible \($0.visibleFrame)" } ?? "nil") screens \(NSScreen.screens.map { "\($0.frame)" })")
        _ = await until(5, { layoutFailures(hiddenSidebar: false, tabs: 3).isEmpty })
        var bad = layoutFailures(hiddenSidebar: false, tabs: 3).map { "shown: " + $0 }
        // Pixels drawn by AppKit, sidebar shown.
        let selectedRow = ctl.sidebar.rows[safe: selected ?? 0]
        var samples: [String] = []
        // (name, view drawn by AppKit, sample point, the color it must be, a free spot of the view for the swatch)
        for (name, view, p, color, free, literal) in [("divider", ctl.toolbar as NSView, CGPoint(x: 100, y: 41), ChromeStyle.dividerColor, CGPoint(x: 400, y: 20), UInt32(0x252525)),
                                             ("toolbar", ctl.view(withIdentifier: "card") ?? host, CGPoint(x: 600, y: 14), ChromeStyle.cardFill, CGPoint(x: 800, y: 20), UInt32(0x1F1F1F)),
                                             ("selected row", (selectedRow ?? host) as NSView, CGPoint(x: 100, y: 3), ChromeStyle.rowSelectedFill, CGPoint(x: 120, y: 20), UInt32(0x1B1D21))] {
            let got = pixel(view, p), want = swatchPixel(view, color: color, at: free)
            samples.append("\(name)=\(got.map { "\($0)" } ?? "nil") swatch=\(want.map { "\($0)" } ?? "nil")")
            guard let want, let spec = swatchPixel(view, color: NSColor(hex: literal), at: free) else { bad.append("no swatch for \(name)"); continue }
            if !close(got, spec) { bad.append("pixel \(name) is \(got.map { "\($0)" } ?? "nil"), the literal #\(String(literal, radix: 16)) renders as \(spec)") }
            if !close(got, want) { bad.append("pixel \(name) at \(p) is \(got.map { "\($0)" } ?? "nil"), the same color through the same pipeline is \(want)") }
        }
        line("info", "pixels \(samples.joined(separator: " "))")
        cmdS()
        guard await until(2, { ctl.sidebarHidden && ctl.cardX == 6 }) else { return finish(false, "sidebar did not hide: \(bad)") }
        _ = await until(5, { layoutFailures(hiddenSidebar: true, tabs: 3).isEmpty })
        bad += layoutFailures(hiddenSidebar: true, tabs: 3).map { "hidden: " + $0 }
        finish(bad.isEmpty && violations.isEmpty, "window \(W)x\(H), 3 rows, both sidebar states within 1 pt, 3 pixel samples within 3 per channel \(bad) \(violations)")
    }

    func longTitle() async {
        guard await ready(), let ctl, let win else { return }
        guard await openTabs(4) else { return finish(false, "4 rows never appeared") }
        let titles = [String(repeating: "W", count: 300), String(repeating: "مرحبا بالعالم ", count: 22) + "!", String(repeating: "😀🎉", count: 150), "short"]
        for (i, t) in titles.enumerated() {
            let js = "document.title = \(String(data: (try? JSONSerialization.data(withJSONObject: [t])) ?? Data(), encoding: .utf8) ?? "[]")[0]"
            _ = await evaluate(win.tabs[i], js)
        }
        guard await until(10, { (0..<4).allSatisfy { ctl.sidebar.rows[safe: $0]?.titleField.stringValue == titles[$0] } }) else {
            return finish(false, "row titles never updated: \((0..<4).map { ctl.sidebar.rows[safe: $0]?.titleField.stringValue.count ?? -1 })")
        }
        var bad: [String] = []
        for (i, row) in ctl.sidebar.rows.enumerated() {
            let f = row.titleField
            if !row.bounds.contains(f.frame) { bad.append("row \(i) title frame \(f.frame) outside \(row.bounds)") }
            if f.stringValue.contains("…") { bad.append("row \(i) has an ellipsis") }
            if f.layer?.mask == nil { bad.append("row \(i) title has no fade mask") }
            if f.frame.width <= 100 { bad.append("row \(i) title view is only \(f.frame.width) wide") }
            let w = Double(f.bounds.width)
            if let stop = row.fade.locations?[safe: 1]?.doubleValue, abs(stop - (w - 20) / w) > 0.001 { bad.append("row \(i) fade starts at \(stop), want \((w - 20) / w)") }
            else if row.fade.locations?[safe: 1] == nil { bad.append("row \(i) has no fade stops") }
            let want = CGRect(x: 6, y: 93 + 37 * CGFloat(i), width: 185, height: 37)
            if ctl.frame(ofIdentifier: "sidebar.tab.\(i)").map({ !near($0, want.minX, want.minY, want.width, want.height) }) ?? true { bad.append("row \(i) frame is not \(want)") }
            if !row.showsPlaceholder { bad.append("row \(i) has no placeholder although the page has no favicon") }
        }
        finish(bad.isEmpty && violations.isEmpty, "titles of 300 W, Arabic and emoji stay inside rows of pitch 37, no ellipsis, fade mask, placeholder favicon \(bad) \(violations)")
    }

    static let expectedMenu = [
        "Noche||", "About Noche||", "Hide Noche|h|cmd", "Hide Others|h|opt+cmd", "Show All||", "Quit Noche|q|cmd",
        "File||", "New Tab|t|cmd", "New Window|n|cmd", "Open Command Bar|l|cmd", "Close Window|w|shift+cmd", "Close Tab|w|cmd",
        "Edit||", "Undo|z|cmd", "Redo|z|shift+cmd", "Cut|x|cmd", "Copy|c|cmd", "Copy URL|c|shift+cmd", "Paste|v|cmd", "Select All|a|cmd",
        "View||", "Refresh|r|cmd", "Force Refresh the Page|r|shift+cmd", "Auto-Hide Tabs|s|cmd", "Zoom to Actual Size|0|cmd",
        "Zoom In|+|cmd", "Zoom Out|-|cmd", "Developer||", "Developer Tools|i|opt+cmd",
        "Tabs||", "Go Back|[|cmd", "Go Forward|]|cmd", "Next Tab|]|shift+cmd", "Previous Tab|[|shift+cmd",
        "Window||", "Minimize|m|cmd",
    ]

    func menu() async {
        guard let menu = NSApp.mainMenu else { return finish(false, "no main menu") }
        // AppKit adds an AutoFill group to the Edit menu itself.
        let injected: Set<String> = ["AutoFill||", "Contact…||", "Passwords…||", "Credit Card…||"]
        let got = MainMenu.dump(menu).filter { !injected.contains($0) }
        if got != Self.expectedMenu {
            let diff = zip(got, Self.expectedMenu).enumerated().first { $0.element.0 != $0.element.1 }
            return finish(false, "menu differs: \(got.count) lines vs \(Self.expectedMenu.count), first difference \(String(describing: diff)); live menu \(got)")
        }
        // The edit actions have no target: AppKit sends them to the key window's first responder.
        let editTitles: Set<String> = ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"]
        let edit = menu.items.first { $0.title == "Edit" }?.submenu?.items.filter { editTitles.contains($0.title) } ?? []
        guard edit.count == 6, edit.allSatisfy({ $0.target == nil }) else { return finish(false, "edit items with a target: \(edit.filter { $0.target != nil }.map(\.title))") }
        finish(true, "\(got.count) menu lines equal the M1.1 list, the 6 edit actions are nil-targeted")
    }

    func sidebarToggle() async {
        guard await ready(), let ctl else { return }
        /// Milliseconds from the synthesized key event (or click) to the settled frame: cmdS is synchronous, so this is exact.
        func run(viaButton: Bool = false) async -> (ms: Double, max: CGFloat) {
            ctl.cardLog = []
            let t0 = ProcessInfo.processInfo.systemUptime
            if viaButton { click(ctl.toolbar.toggle) } else { cmdS() }
            _ = await until(1, { ctl.toggleEnd > 0 })
            let ms = ctl.toggleEnd > 0 ? (ctl.toggleEnd - t0) * 1000 : .infinity
            return (ms, ctl.cardLog.map(\.x).max() ?? 0)
        }
        let hide = await run()
        let lightsHidden = ctl.sidebar.lights.allSatisfy(\.isHidden)
        let hiddenAt = ctl.frame(ofIdentifier: "card")?.minX
        let show = await run()
        let shownAt = ctl.frame(ofIdentifier: "card")?.minX
        let overshoot = show.max - 197
        let hideAgain = await run(viaButton: true)
        func f(_ v: Double) -> String { String(format: "%.0f", v) }
        line("info", "hide \(f(hide.ms)) ms (limit 145), show \(f(show.ms)) ms (limit 125), overshoot \(String(format: "%.2f", overshoot)) pt, button hide \(f(hideAgain.ms)) ms")
        let ok = hide.ms <= 145 && lightsHidden && hiddenAt == 6 && show.ms <= 125 && shownAt == 197 && overshoot > 0.3 && overshoot <= 2.5
            && BrowserWindowController.actionCounts["toggleSidebar"] == 3 && hideAgain.ms <= 145
        finish(ok && violations.isEmpty, "Cmd+S hides in \(f(hide.ms)) ms with the lights hidden, shows in \(f(show.ms)) ms with \(String(format: "%.2f", overshoot)) pt overshoot ending at 197; the toggle button hides again in \(f(hideAgain.ms)) ms; actions \(BrowserWindowController.actionCounts) \(violations)")
    }

    func sidebarScroll() async {
        guard await ready(), let ctl, let win, let ns = ctl.nsWindow else { return }
        let scroll = ctl.sidebar.scroll
        func toTop() { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        var bad: [String] = []
        var seen: [String] = []
        for height in [1436.0, 800.0] {
            ns.setFrame(NSRect(x: ns.frame.minX, y: ns.frame.maxY - height, width: ns.frame.width, height: height), display: false)
            guard await until(5, { Double(ctl.window.chromeHost?.bounds.height ?? 0) == height }) else { return finish(false, "window never got height \(height)") }
            if rowCount < 40 {
                for _ in 0..<(40 - rowCount) { _ = win.addTab(withURL: "about:blank", activate: false) }
                guard await until(30, { rowCount == 40 && win.tabs.count == 40 }) else { return finish(false, "40 rows never appeared (rows=\(rowCount))") }
            }
            toTop()
            guard await until(5, { ctl.frame(ofIdentifier: "sidebar.tab.0")?.minY == 93 }) else { return finish(false, "list not at the top: \(String(describing: ctl.frame(ofIdentifier: "sidebar.tab.0")))") }
            // Select tab 1 by clicking its row (it is on screen), then Shift+Cmd+[ wraps to tab 40.
            guard click(ctl.sidebar.rows[0]), await until(5, { selected == 0 }) else { return finish(false, "could not click row 0 at height \(height)") }
            previousTab()
            guard await until(5, { selected == 39 }) else { return finish(false, "Shift+Cmd+[ from tab 1 selected \(selected.map(String.init) ?? "nil") at height \(height)") }
            let r39 = ctl.frame(ofIdentifier: "sidebar.tab.39")
            let visible = ctl.frame(ofIdentifier: "sidebar")
            let inside = r39.map { $0.minY >= 48 && $0.maxY <= (visible?.maxY ?? 0) } ?? false
            if !inside { bad.append("h\(Int(height)): row 40 at \(String(describing: r39)) is not inside the sidebar \(String(describing: visible))") }
            // The pitch holds in the scrolled list.
            let p = zip(ctl.sidebar.rows, ctl.sidebar.rows.dropFirst()).allSatisfy { abs($1.frame.minY - $0.frame.minY - 37) < 0.01 }
            if !p { bad.append("h\(Int(height)): row pitch is not 37") }
            // Row 39 (tab 39) is out of reach at the top, and a click reaches it once scrolled to.
            toTop()
            let hiddenAtTop = (ctl.frame(ofIdentifier: "sidebar.tab.38")?.maxY ?? 0) > height - 0.5
            if !hiddenAtTop { bad.append("h\(Int(height)): row 39 is not out of reach at the top") }
            ctl.sidebar.document.scrollToVisible(ctl.sidebar.rows[39].frame)
            let clicked = click(ctl.sidebar.rows[38])
            let ok = clicked ? await until(5, { selected == 38 }) : false
            if !ok { bad.append("h\(Int(height)): clicking row 39 after scrolling to it: hit=\(clicked) selected=\(selected.map(String.init) ?? "nil")") }
            seen.append("h\(Int(height)): row 40 at y \(r39.map { "\($0.minY)-\($0.maxY)" } ?? "nil") of \(Int(visible?.maxY ?? 0))")
        }
        finish(bad.isEmpty && violations.isEmpty, "40 tabs at 1436 and 800 pt: Shift+Cmd+[ wraps to tab 40 and its row is fully visible (\(seen.joined(separator: "; "))), pitch 37, a scrolled-to row takes the click \(bad) \(violations)")
    }

    /// The frame a window is asked for is the frame it gets (AppKit global coordinates, origin bottom-left), with no setFrame repair:
    /// the first window, a window on the primary screen and one on the second screen when there is one.
    /// The frames start 300 pt or more from a screen's left edge: with macOS Stage Manager on, the system moves any window that
    /// starts inside its strip (240 pt on a 2560x1440 screen, 112 pt on the 1440x2560 one) to the strip's edge, whatever the app
    /// asked for. That is outside Noche's control; the info line shows what AppKit's own constrainFrameRect makes of the request.
    func windowFrame() async {
        guard await until(15, { loads >= 1 && ctl?.nsWindow != nil }) else { return finish(false, "first window never appeared") }
        var cases: [(String, NSWindow?, NSRect)] = [("first window", ctl?.nsWindow, SelfTest.windowFrame)]
        func open(_ name: String, _ frame: NSRect) async {
            let w = app.newWindow(url: url, frame: frame)
            _ = await until(15, { w.nsWindow != nil })
            cases.append((name, w.nsWindow, frame))
        }
        let primary = NSScreen.screens[0].frame
        await open("primary screen", NSRect(x: primary.minX + 400, y: primary.minY + 200, width: 1200, height: 800))
        if NSScreen.screens.count > 1 {
            let s = NSScreen.screens[1].frame
            await open("second screen", NSRect(x: s.minX + 400, y: s.minY + 100, width: min(900, s.width - 500), height: min(1200, s.height - 200)))
        }
        var bad: [String] = [], seen: [String] = []
        for (name, ns, want) in cases {
            guard let ns else { bad.append("\(name): no window"); continue }
            func close(_ f: NSRect) -> Bool { abs(f.minX - want.minX) <= 1 && abs(f.minY - want.minY) <= 1 && abs(f.width - want.width) <= 1 && abs(f.height - want.height) <= 1 }
            _ = await until(5, { close(ns.frame) })  // the engine places the window a moment after it exists
            seen.append("\(name) \(ns.frame)")
            line("info", "\(name): asked \(want), constrainFrameRect gives \(ns.constrainFrameRect(want, to: ns.screen))")
            if !close(ns.frame) { bad.append("\(name): asked \(want), got \(ns.frame)") }
        }
        // Stage Manager's strip is drawn by the WindowManager process: its windows, when it has any, show where the strip is.
        let strip = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerName as String] as? String) == "WindowManager" && ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { $0.width > 50 && $0.width < 400 } == true }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        line("info", "WindowManager windows 50 to 400 pt wide: \(strip.prefix(6))")
        line("info", "screens \(NSScreen.screens.map { "\($0.frame) visible \($0.visibleFrame)" })")
        finish(bad.isEmpty && violations.isEmpty, "\(cases.count) windows opened with the frame asked for (within 1 pt, no setFrame): \(seen.joined(separator: "; ")) \(bad) \(violations)")
    }

    /// VoiceOver sees the chrome: tab rows, the New Tab row and the toolbar buttons are buttons with labels, rows carry the selection.
    /// Also here: a row's favicon goes back to the placeholder when the next page has none.
    func a11yLabels() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        guard await openTabs(2) else { return finish(false, "2 rows never appeared") }
        var bad: [String] = []
        func expect(_ name: String, _ v: NSView, _ label: String) {
            if v.accessibilityRole() != .button { bad.append("\(name) role \(v.accessibilityRole()?.rawValue ?? "nil")") }
            if v.accessibilityLabel() != label { bad.append("\(name) label \(v.accessibilityLabel() ?? "nil"), want \(label)") }
            if !v.isAccessibilityElement() { bad.append("\(name) is not an accessibility element") }
        }
        let rows = ctl.sidebar.rows
        for (i, row) in rows.enumerated() {
            expect("row \(i)", row, ctl.list.displayTitle(of: ctl.list.items[i].id))
            if row.isAccessibilitySelected() != (i == selected) { bad.append("row \(i) selected=\(row.isAccessibilitySelected()), the list says \(selected.map(String.init) ?? "nil")") }
        }
        click(rows[1])
        _ = await until(5, { selected == 1 })
        if !rows[1].isAccessibilitySelected() || rows[0].isAccessibilitySelected() { bad.append("after selecting row 1: selected states \(rows.map { $0.isAccessibilitySelected() })") }
        expect("New Tab row", ctl.sidebar.newTabRow, "New Tab")
        expect("toggle", ctl.toolbar.toggle, "Toggle Sidebar")
        expect("back", ctl.toolbar.back, "Back")
        expect("forward", ctl.toolbar.forward, "Forward")
        expect("reload", ctl.toolbar.reload, "Reload")
        for (i, name) in ["Close", "Minimize", "Zoom"].enumerated() { expect("window button \(name)", ctl.sidebar.lights[i], name) }
        // Favicon: a page with one shows it, the next page without one brings the placeholder back.
        click(rows[0])
        _ = await until(5, { selected == 0 })
        var before = loads
        tab.loadURL(fixture("favicon.html"))
        guard await until(15, { loads > before && !rows[0].showsPlaceholder }) else { return finish(false, "the favicon of favicon.html never reached its row \(bad)") }
        before = loads
        tab.loadURL(fixture("b.html"))
        guard await until(15, { loads > before && rows[0].showsPlaceholder }) else { return finish(false, "the row kept the previous favicon after a page without one \(bad)") }
        finish(bad.isEmpty && violations.isEmpty, "rows (button, title label, selected state), New Tab row and 4 toolbar buttons and 3 window buttons labelled; the row favicon returns to the placeholder \(bad) \(violations)")
    }
}
#endif
