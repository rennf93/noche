#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore

/// The three-zone sidebar (M1.6 Task 2): table 1.1's geometry, the pinned grid's columns, 500 tabs and the window's minimum width.
/// The composition is seeded through `testSeed`: no pin or group can be made from the UI yet.
extension SelfTest {
    private func nearID(_ id: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ bad: inout [String]) {
        let f = ctl?.frame(ofIdentifier: id)
        if !near(f, x, y, w, h) { bad.append("\(id) \(f.map { "\($0)" } ?? "missing") want (\(x), \(y), \(w), \(h))") }
    }

    /// Note 5.2 `sidebar-geometry`: every row of the capture composition within 1 pt of table 1.1 (grid tiles, loose rows, groups, divider,
    /// New Tab row, day tabs) and of the bottom bar, at width 197.
    func sidebarGeometry() async {
        guard await ready(), let ctl, let host = ctl.window.chromeHost else { return }
        let H = host.bounds.height
        guard H >= 1100 else { return finish(false, "the window is \(H) pt high, the composition needs 1100") }
        ctl.testSeed(SidebarComposition.capture())
        var bad: [String] = []
        for i in 0..<12 { nearID("sidebar.pin.\(i)", 6 + 48 * CGFloat(i % 4), 54 + 47 * CGFloat(i / 4), 41, 41, &bad) }
        nearID("sidebar.tab.0", 6, 192, 185, 37, &bad)
        nearID("sidebar.tab.1", 6, 229, 185, 37, &bad)
        for n in 0..<11 { nearID("sidebar.group.\(n)", 6, 269 + 40 * CGFloat(n), 185, 39, &bad) }
        for n in 0..<5 { nearID("sidebar.tab.\(2 + n)", 6, 709 + 37 * CGFloat(n), 185, 37, &bad) }
        nearID("sidebar.divider", 12, 900, 175, 1, &bad)
        nearID("sidebar.newTab", 6, 905, 185, 39, &bad)
        for n in 0..<3 { nearID("sidebar.tab.\(7 + n)", 6, 944 + 37 * CGFloat(n), 185, 37, &bad) }
        // The bottom bar: the download button's box is 42 pt above the bottom (live-ui.md section 3), the list stops there.
        if let f = ctl.frame(ofIdentifier: "sidebar.downloads"), abs(f.minY - (H - ChromeStyle.sidebarBottom)) > 1 { bad.append("sidebar.downloads at \(f.minY), want \(H - ChromeStyle.sidebarBottom)") }
        // Note 1.4 (B: the one Space takes the first dot's place): dot x 90..96 (center 93), chevron center x 174, both centered 18 pt into the row.
        let bar = ctl.sidebar.bottomBar, barY = H - ChromeStyle.sidebarBottom
        let box = bar.spaceDotFrame.offsetBy(dx: 0, dy: barY)
        if !near(box, 90, barY + 15, 6, 6) { bad.append("space dot \(box), want (90, \(barY + 15), 6, 6)") }
        if abs(bar.chevronCenter.x - 174) > 1 || abs(bar.chevronCenter.y - 18) > 1 { bad.append("chevron center \(bar.chevronCenter), want (174, 18)") }
        if ctl.frame(ofIdentifier: "sidebar.tab.10") != nil { bad.append("sidebar.tab.10 exists: the composition has 10 tab rows") }
        let views = ctl.sidebar.realizedCount
        if views != 12 + 10 + 11 { bad.append("\(views) views for 33 entries") }
        finish(bad.isEmpty && violations.isEmpty, "capture composition (12 pins, 2 loose rows, 11 groups, 5 loose rows, divider, New Tab, 3 day tabs) within 1 pt of table 1.1 at height \(Int(H)) \(bad) \(violations)")
    }

    /// Note 5.2 `sidebar-columns`: 4 columns at 197, 3 at width 150, 4 again at 197.
    func sidebarColumns() async {
        guard await ready(), let ctl else { return }
        ctl.testSeed(SidebarComposition.capture())
        let full = ctl.sidebar.frame.width
        func pins(_ cols: Int, _ label: String) -> [String] {
            var bad: [String] = []
            for i in 0..<12 { nearID("sidebar.pin.\(i)", 6 + 48 * CGFloat(i % cols), 54 + 47 * CGFloat(i / cols), 41, 41, &bad) }
            return bad.map { "\(label): " + $0 }
        }
        var bad = pins(4, "width \(Int(full))")
        // No await between the resize and the read: the window's own layout would put the width back.
        ctl.sidebar.setFrameSize(NSSize(width: 150, height: ctl.sidebar.frame.height))
        bad += pins(3, "width 150")
        nearID("sidebar.divider", 12, 947, 128, 1, &bad)  // 4 grid rows end at 236, then 3 + 2 rows + 3 + 11 groups + 5 rows + 6
        ctl.sidebar.setFrameSize(NSSize(width: full, height: ctl.sidebar.frame.height))
        bad += pins(4, "back at width \(Int(full))")
        finish(bad.isEmpty && PinnedGrid.columns(150) == 3 && violations.isEmpty, "12 pins in 4 columns at \(Int(full)), 3 columns at width 150, 4 again \(bad) \(violations)")
    }

    /// Note 5.2 `sidebar-scale`: 500 tabs. A refresh (a title update, a tab added, a tab removed) takes under 4 ms at the 95th percentile,
    /// at most 40 entries have a view at every scroll position, and a scrolled-to row is where the layout says.
    func sidebarScale() async {
        guard await ready(), let ctl, let host = ctl.window.chromeHost else { return }
        let H = host.bounds.height
        guard H >= 1400 else { return finish(false, "the window is \(H) pt high, the 40 view bound is for 1436") }
        let items = (0..<500).map { TabItem(id: TabID(), engineID: $0, url: "https://site\($0).example/", title: "Tab \($0)", isLoading: false) }
        ctl.testSeed(TabList(items: items, activeID: items[0].id)!)
        var bad: [String] = []
        if ctl.sidebar.tabRowCount != 500 { bad.append("\(ctl.sidebar.tabRowCount) rows in the layout, want 500") }
        // Refreshes as the engine causes them: a title changes, a tab arrives, a tab leaves.
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        func ms(_ ticks: UInt64) -> Double { Double(ticks) * Double(base.numer) / Double(base.denom) / 1e6 }
        var times: [Double] = [], added: [TabID] = []
        for i in 0..<120 {
            switch i % 4 {
            case 0, 2: ctl.list.update(items[(i * 7) % 500].id, url: "https://site.example/", title: "Title \(i)", isLoading: i % 3 == 0)
            case 1:
                let t = TabItem(id: TabID(), engineID: 1000 + i, url: "https://new\(i).example/", title: "New \(i)", isLoading: false)
                ctl.list.insertNew(t, opener: nil, addToTop: true, activate: false)
                added.append(t.id)
            default: if let id = added.popLast() { _ = ctl.list.remove(id) }
            }
            let t0 = mach_absolute_time()
            ctl.refreshNow()
            times.append(ms(mach_absolute_time() - t0))
        }
        times.sort()
        let p95 = times[Int(Double(times.count) * 0.95)]
        if p95 >= 4 { bad.append("refresh p95 \(String(format: "%.2f", p95)) ms, want under 4 (median \(String(format: "%.2f", times[times.count / 2])), max \(String(format: "%.2f", times.last ?? 0)))") }
        // Scrolling: row k at the top of the list is in place, and no position has more than 40 views.
        let scroll = ctl.sidebar.scroll
        var most = 0
        let rows = ctl.sidebar.tabRowCount
        for k in Array(stride(from: 0, to: rows, by: 31)) + [rows - 1] {
            let want = SidebarMetrics.tabPitch * CGFloat(k)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(want, max(0, ctl.sidebar.document.frame.height - scroll.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            most = max(most, ctl.sidebar.realizedCount)
            guard let layoutFrame = ctl.sidebar.tabFrame(k) else { bad.append("no layout frame for row \(k)"); continue }
            let y = layoutFrame.minY - (scroll.contentView.bounds.minY)
            if let f = ctl.frame(ofIdentifier: "sidebar.tab.\(k)") {
                if abs(f.minY - y) > 1 { bad.append("row \(k) is at \(f.minY), the layout and the scroll say \(y)") }
            } else if y > 48 - 37, y < H - ChromeStyle.sidebarBottom { bad.append("row \(k) is on screen (y \(y)) and has no view") }
        }
        if most > 40 { bad.append("too many views: \(most) at one scroll position, want at most 40") }
        let pooled = ctl.sidebar.document.subviews.count
        if pooled > 40 + 3 { bad.append("the sidebar document holds \(pooled) views after scrolling through 500 rows") }
        // Ruling M72: with the capture's 12 pins above 500 day tabs, row views (tab and group rows) stay at 40; tiles are bounded by the pin count.
        ctl.testSeed(SidebarComposition.capture(dayTabs: 500))
        let total = ctl.sidebar.document.frame.height, maxOffset = max(0, total - scroll.bounds.height)
        var rowsMost = 0, viewsMost = 0
        for (name, offset) in [("top", CGFloat(0)), ("middle", (maxOffset / 2).rounded()), ("end", maxOffset)] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            let tiles = ctl.sidebar.realizedTileCount, rowViews = ctl.sidebar.realizedCount - tiles
            rowsMost = max(rowsMost, rowViews); viewsMost = max(viewsMost, ctl.sidebar.realizedCount)
            if rowViews > 40 { bad.append("capture + 500 at the \(name): \(rowViews) row views, want at most 40") }
            if ctl.sidebar.realizedCount > 40 + 12 { bad.append("capture + 500 at the \(name): \(ctl.sidebar.realizedCount) views, want at most 40 plus 12 tiles") }
            if name == "top", ctl.frame(ofIdentifier: "sidebar.tab.400") != nil { bad.append("sidebar.tab.400 has a view at the top of the list: an unrealized row must have none") }
            if name == "end", ctl.frame(ofIdentifier: "sidebar.tab.0") != nil { bad.append("sidebar.tab.0 has a view at the end of the list") }
        }
        finish(bad.isEmpty && violations.isEmpty, "500 tabs at height \(Int(H)): refresh p95 \(String(format: "%.2f", p95)) ms, at most \(most) views at any scroll position, \(pooled) in the document after a full scroll; with the capture's 12 pins above 500 day tabs at most \(rowsMost) row views and \(viewsMost) views in all (tiles extra) \(bad) \(violations)")
    }

    /// T2.5 `min-width`: the window's minimum content width is the sidebar (197) plus a card of 284 (the find pill's 260 floor and its two
    /// 12 pt margins) plus the right inset (6): what a drag on the window's edge stops at. A program's own `setFrame` is not clamped by
    /// AppKit, so the check reads the NSWindow's `contentMinSize` and `minSize`. (The Views window's own minimum is not readable: `CefWindow::GetMinimumSize`
    /// answers 0 whatever the delegate says; the delegate answer is the bridge's way of keeping Views from resetting the NSWindow's.) The restore of a narrow saved frame is `min-width-relaunch`.
    func minWidth() async {
        guard await ready(), let ctl, let ns = ctl.nsWindow, let host = ctl.window.chromeHost else { return }
        let want = ChromeStyle.minimumWindowWidth
        _ = await until(3, { ns.contentMinSize.width == want })
        let layout = ChromeLayout(size: CGSize(width: want, height: host.bounds.height), cardX: ChromeStyle.sidebarWidth)
        let found = (content: ns.contentMinSize.width, frame: ns.minSize.width)
        finish(found.content >= want && found.frame >= want && layout.card.width >= 284 && violations.isEmpty,
               "the window's minimum width is \(found.content) (content) and \(found.frame) (frame), want \(want); at that width the card is \(layout.card.width) wide, at least 284 \(violations)")
    }

    /// A saved frame 400 wide (a program's `setFrame` is not clamped, so one can be stored) opens at 487 or wider with a card of 284 or more.
    func minWidthRelaunch() async {
        if phase == 1 {
            guard await ready(), let ctl, let ns = ctl.nsWindow, let writer = app.writer else { return }
            ns.setFrame(NSRect(x: 300, y: 200, width: 400, height: 700), display: false)
            guard await until(5, { abs(ns.frame.width - 400) <= 1 }) else { return finish(false, "phase 1: the window did not take a 400 pt frame (\(ns.frame.width))") }
            writer.flush()
            return finish(violations.isEmpty, "phase 1: a window of 400 pt saved, quitting \(violations)")
        }
        guard await until(20, { self.restoredUp(1) }), let ctl, let ns = ctl.nsWindow, let host = ctl.window.chromeHost else { return finish(false, "phase 2: no restored window") }
        let saved = app.restored.first?.frame.width ?? 0
        _ = await until(5, { ns.frame.width >= ChromeStyle.minimumWindowWidth })
        _ = await until(3, { ctl.frame(ofIdentifier: "card") != nil })
        let card = ctl.frame(ofIdentifier: "card")?.width ?? 0
        finish(saved > 0 && saved < 487 && ns.frame.width >= ChromeStyle.minimumWindowWidth && host.bounds.width >= ChromeStyle.minimumWindowWidth && card >= 284 && violations.isEmpty,
               "the store holds a window \(saved) wide; it opened \(ns.frame.width) wide (at least \(ChromeStyle.minimumWindowWidth)) with a card \(card) wide (at least 284) \(violations)")
    }
}
#endif
