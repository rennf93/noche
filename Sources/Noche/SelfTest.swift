#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Hidden self-test harness: `Noche --selftest <check> --selftest-url <url>`, driven by scripts/app-test.sh.
/// Prints `NOCHE_TEST <check> pass|fail|info ...` lines; the process exit code is 0 only when the check passed.
/// Later tasks add checks to `run()`. Nothing here may wait for a rendered frame: the app runs hidden, and a locked
/// screen gives a hidden window none (load-end and CEF callbacks still arrive).
@MainActor
final class SelfTest {
    struct Options { let check: String; let url: String }

    /// 2368x1436 at the left edge of the usable area of the first screen (a Dock on the left narrows it; Chromium clamps to it).
    static var windowFrame: NSRect {
        NSRect(x: 192, y: 0, width: 2368, height: 1436)
    }

    static func parse(_ args: [String]) -> Options? {
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return nil }
        var url = "about:blank"
        if let u = args.firstIndex(of: "--selftest-url"), u + 1 < args.count { url = args[u + 1] }
        return Options(check: args[i + 1], url: url)
    }

    let check: String
    let url: String
    private unowned let app: AppDelegate
    private(set) var verdictPrinted = false
    private var violations: [String] = []
    private var added = 0, closedTabs = 0, windowsClosed = 0, loads = 0, loadFailures = 0
    private var maxOwnWindows = 0
    private var keyLog: [String] = []
    private var lastExtensionReply = ""
    private var tabsAtQuit = 0

    init(_ options: Options, app: AppDelegate) {
        check = options.check
        url = options.url
        self.app = app
    }

    // MARK: events from AppDelegate

    func didAddTab() { added += 1 }
    func didCloseTab() { closedTabs += 1 }
    func windowDidClose() { windowsClosed += 1 }
    func didFinishLoad() { loads += 1 }
    func didFailLoad() { loadFailures += 1 }

    /// Last thing before the process exits. quit-many's verdict is the exit itself, so it is printed here.
    func beforeExit(watchdogFired: Bool) {
        if check == "quit-many", !verdictPrinted {
            let ok = tabsAtQuit == 10 && !watchdogFired && violations.isEmpty
            line(ok ? "pass" : "fail", "10 tabs, quit menu action, exit without the shutdown watchdog (tabs=\(tabsAtQuit) watchdog=\(watchdogFired) \(violations))")
            if !ok { app.exitCodeOverride = 1 }
        }
        line("info", "activate-blocked=\(NCWindow.activationsBlocked())")
    }

    // MARK: running

    func start() {
        // Invariants of every hidden run: no window shows, none is key, the app never becomes active.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            MainActor.assumeIsolated { self?.finish(false, "timeout (40 s); look at screen lock and CPU load before suspecting the code") }
        }
        Task { @MainActor in
            switch check {
            case "hidden": await hidden()
            case "close-last": await closeLast()
            case "quit-many": await quitMany()
            case "web-insets": await webInsets()
            case "layout": await layout()
            case "tabs-keys": await tabsKeys()
            case "tabs-rapid": await tabsRapid()
            case "ext-count": await extCount()
            case "navigate": await navigate()
            case "blank-link": await blankLink()
            case "long-title": await longTitle()
            case "load-error": await loadError()
            case "menu": await menu()
            case "sidebar-toggle": await sidebarToggle()
            default: finish(false, "unknown check")
            }
        }
    }

    private func sample() {
        maxOwnWindows = max(maxOwnWindows, ownWindows())
        func note(_ s: String) { if violations.count < 5, !violations.contains(s) { violations.append(s) } }
        if NSApp.isActive { note("NSApp.isActive") }
        for w in NSApp.windows {
            if w.alphaValue != 0 { note("alpha=\(w.alphaValue) on \(type(of: w))") }
            if w.isKeyWindow { note("key window \(type(of: w))") }
        }
    }

    private func hidden() async {
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

    /// webInsets and webCornerRadius: the page view's rect inside the window, and the bottom-corner mask.
    private func webInsets() async {
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        guard let win = app.windows.first, let ns = win.nsWindow, let content = ns.contentView else { return finish(false, "no window") }
        win.webInsets = NSEdgeInsets(top: 48, left: 198, bottom: 7, right: 7)
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

    private func closeLast() async {
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

    private func quitMany() async {
        guard let win = app.windows.first else { return finish(false, "no window") }
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        for _ in 1..<10 { _ = win.addTab(withURL: url, activate: false) }
        guard await until(20, { win.tabs.count == 10 && added == 10 }) else {
            return finish(false, "tabs=\(win.tabs.count) added=\(added), wanted 10")
        }
        _ = await until(10, { loads >= 10 })  // info only: quitting with loaded tabs is the harder case
        tabsAtQuit = win.tabs.count
        line("info", "tabs=\(tabsAtQuit) loaded=\(loads), sending the Quit menu action")
        guard let sub = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { m in
            m.items.contains { $0.action == #selector(NSApplication.terminate(_:)) }
        }), let idx = sub.items.firstIndex(where: { $0.action == #selector(NSApplication.terminate(_:)) }) else {
            return finish(false, "no Quit menu item")
        }
        sub.performActionForItem(at: idx)  // the verdict is printed by beforeExit once the process really exits
    }

    // MARK: chrome checks

    private var ctl: BrowserWindowController? { app.controllers.first }
    private var win: NCWindow? { ctl?.window }
    private var selected: Int? { ctl.flatMap { c in c.list.items.firstIndex { $0.id == c.list.activeID } } }
    private var rowCount: Int { ctl?.sidebar.rows.count ?? 0 }
    private func fixture(_ path: String) -> String { url + path }

    /// The window is up, its chrome installed and the first page loaded.
    private func ready() async -> Bool {
        guard await until(15, { loads >= 1 && rowCount == 1 && ctl?.view(withIdentifier: "toolbar") != nil }) else {
            finish(false, "first tab never finished loading, or no chrome (loads=\(loads) rows=\(rowCount))")
            return false
        }
        // The engine opens the window 2320 wide at x 240 whatever bounds were asked for: set the reference size explicitly.
        if let ns = ctl?.nsWindow, ns.frame.size != SelfTest.windowFrame.size {
            ns.setFrame(NSRect(x: 0, y: 4, width: SelfTest.windowFrame.width, height: SelfTest.windowFrame.height), display: false)
            _ = await until(3, { ns.frame.size == SelfTest.windowFrame.size })
            line("info", "window frame after setFrame \(ns.frame)")
        }
        return true
    }

    /// Opens tabs on the fixture until |n| rows exist, and waits for their pages.
    private func openTabs(_ n: Int, page: String = "") async -> Bool {
        guard let win else { return false }
        let before = loads
        for _ in 0..<(n - rowCount) { _ = win.addTab(withURL: fixture(page), activate: false) }
        return await until(20, { rowCount == n && win.tabs.count == n && loads >= before + (n - 1) })
    }

    /// A key equivalent the way NSApplication routes it: the window first, then the main menu.
    @discardableResult
    private func key(_ ch: String, code: UInt16, _ mods: NSEvent.ModifierFlags = .command, chars: String? = nil) -> Bool {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ns.windowNumber, context: nil,
              characters: chars ?? ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return false }
        let byWindow = ns.performKeyEquivalent(with: ev)
        let byMenu = byWindow ? false : (NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false)
        keyLog.append("\(ch)\(mods.contains(.shift) ? "+shift" : ""):window=\(byWindow),menu=\(byMenu) menuClass=\(NSApp.mainMenu.map { String(describing: type(of: $0)) } ?? "nil") ig=\(ev.charactersIgnoringModifiers ?? "nil") chars=\(ev.characters ?? "nil") mods=\(ev.modifierFlags.rawValue)")
        return byWindow || byMenu
    }
    private func cmdT() { key("t", code: 17) }
    private func cmdW() { key("w", code: 13) }
    // Shifted punctuation: the shifted character, and the plain one ignoring modifiers (the matcher accepts either).
    private func nextTab() { shortcut("Next Tab") }
    private func previousTab() { shortcut("Previous Tab") }
    /// The key of the menu item as the live menu reports it (AppKit remaps "[" and "]" to the layout's keys).
    private func shortcut(_ title: String) {
        func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items { if i.title == title, !i.keyEquivalent.isEmpty { return i }; if let s = i.submenu, let f = find(s) { return f } }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap(find) else { keyLog.append("no menu item \(title)"); return }
        key(item.keyEquivalent, code: 0, item.keyEquivalentModifierMask)
    }
    private func cmdL() { key("l", code: 37) }
    private func cmdS() { key("s", code: 1) }

    /// Typed text goes to the first responder as key events.
    private func typeText(_ text: String) {
        guard let ns = ctl?.nsWindow else { return }
        for ch in text {
            let s = String(ch)
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: ns.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                         isARepeat: false, keyCode: 0) { ns.firstResponder?.keyDown(with: ev) }
        }
    }
    private func pressReturn() {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: ns.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                              isARepeat: false, keyCode: 36) else { return }
        ns.firstResponder?.keyDown(with: ev)
    }

    /// A left click (or a middle click) delivered straight to the view, the way the window would after hit testing.
    private func click(_ v: NSView, middle: Bool = false) {
        guard let ns = ctl?.nsWindow else { return }
        let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if middle {
            if let up = ev(.otherMouseUp) { v.otherMouseUp(with: up) }
        } else {
            if let down = ev(.leftMouseDown) { v.mouseDown(with: down) }
            if let up = ev(.leftMouseUp) { v.mouseUp(with: up) }
        }
    }

    private func ownWindows() -> Int {
        let pid = ProcessInfo.processInfo.processIdentifier
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { return false }
            return r.width >= 400 && r.height >= 300
        }.count
    }

    /// What the probe extension's service worker sees through chrome.tabs, asked from the page |tab| shows (a content script relays it).
    private func extension_(_ tab: NCTab, _ message: String) async -> [String: Any]? {
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
    private func extensionTabCount(_ tab: NCTab, want: Int? = nil) async -> Int? {
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

    private func line(_ kind: String, _ detail: String) { print("NOCHE_TEST \(check) \(kind) \(detail)"); fflush(stdout) }

    private func near(_ a: CGRect?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a.minX - x) <= 1 && abs(a.minY - y) <= 1 && abs(a.width - w) <= 1 && abs(a.height - h) <= 1
    }

    /// The color of a window point drawn by AppKit (cacheDisplay), origin top-left.
    /// The color AppKit rendered at |p| of |view| (cacheDisplay of the view, origin top-left), as sRGB bytes.
    private func pixel(_ view: NSView, _ p: CGPoint) -> (Int, Int, Int)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / view.bounds.width
        guard let c = rep.colorAt(x: Int(p.x * k), y: Int(p.y * k))?.usingColorSpace(.sRGB) else { return nil }
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    /// Inside a window AppKit converts by the display profile, so the expected value is what the same pipeline gives for a
    /// swatch of exactly the wanted color, laid over |view| at |at| (a 6x6 point area).
    private func swatchPixel(_ view: NSView, color: NSColor, at: CGPoint) -> (Int, Int, Int)? {
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
    private func hex(_ v: UInt32) -> (Int, Int, Int) { (Int(v >> 16 & 255), Int(v >> 8 & 255), Int(v & 255)) }
    private func close(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)) -> Bool {
        guard let a else { return false }
        return abs(a.0 - b.0) <= 3 && abs(a.1 - b.1) <= 3 && abs(a.2 - b.2) <= 3
    }

    /// Every identified view against live-ui.md sections 2 to 4, for the sidebar state it is in now. Returns the failures.
    private func layoutFailures(hiddenSidebar: Bool, tabs: Int) -> [String] {
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

    private func layout() async {
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
        for (name, view, p, color, free) in [("divider", ctl.toolbar as NSView, CGPoint(x: 100, y: 41), ChromeStyle.dividerColor, CGPoint(x: 400, y: 20)),
                                             ("toolbar", ctl.view(withIdentifier: "card") ?? host, CGPoint(x: 600, y: 14), ChromeStyle.cardFill, CGPoint(x: 800, y: 20)),
                                             ("selected row", (selectedRow ?? host) as NSView, CGPoint(x: 100, y: 3), ChromeStyle.rowSelectedFill, CGPoint(x: 120, y: 20))] {
            let got = pixel(view, p), want = swatchPixel(view, color: color, at: free)
            samples.append("\(name)=\(got.map { "\($0)" } ?? "nil") swatch=\(want.map { "\($0)" } ?? "nil")")
            guard let want else { bad.append("no swatch for \(name)"); continue }
            if !close(got, want) { bad.append("pixel \(name) at \(p) is \(got.map { "\($0)" } ?? "nil"), the same color through the same pipeline is \(want)") }
        }
        line("info", "pixels \(samples.joined(separator: " "))")
        cmdS()
        guard await until(2, { ctl.sidebarHidden && ctl.cardX == 6 }) else { return finish(false, "sidebar did not hide: \(bad)") }
        _ = await until(5, { layoutFailures(hiddenSidebar: true, tabs: 3).isEmpty })
        bad += layoutFailures(hiddenSidebar: true, tabs: 3).map { "hidden: " + $0 }
        finish(bad.isEmpty && violations.isEmpty, "window \(W)x\(H), 3 rows, both sidebar states within 1 pt, 3 pixel samples within 3 per channel \(bad) \(violations)")
    }

    private func tabsKeys() async {
        guard await ready(), let ctl, let win else { return }
        for _ in 0..<3 { cmdT() }
        guard await until(10, { rowCount == 4 && win.tabs.count == 4 && selected == 3 }) else {
            return finish(false, "3x Cmd+T: rows=\(rowCount) engine tabs=\(win.tabs.count) selected=\(selected.map(String.init) ?? "nil") actions=\(ctl.actionCounts)")
        }
        guard win.activeTab === win.tabs.last else { return finish(false, "newest tab is not the engine's active tab") }
        try? await Task.sleep(for: .milliseconds(500))  // a second action per shortcut would add rows now
        guard rowCount == 4, win.tabs.count == 4, ctl.actionCounts["newTab"] == 3 else {
            return finish(false, "Cmd+T acted more than once: rows=\(rowCount) engine tabs=\(win.tabs.count) actions=\(ctl.actionCounts)")
        }
        var trail: [Int] = []
        for (step, want) in [(nextTab, 0), (nextTab, 1), (previousTab, 0), (previousTab, 3)] as [(() -> Void, Int)] {
            step()
            guard await until(5, { selected == want }) else { return finish(false, "tab keys: selected=\(selected.map(String.init) ?? "nil") engine active \(win.tabs.firstIndex { $0 === win.activeTab }.map(String.init) ?? "nil") want \(want) after \(trail) actions \(ctl.actionCounts) chrome commands \(ctl.commandLog) keys \(keyLog)") }
            trail.append(want)
        }
        guard ctl.actionCounts["nextTab"] == 2, ctl.actionCounts["previousTab"] == 2 else { return finish(false, "next/previous acted \(ctl.actionCounts)") }
        // Cmd+W on row 1 closes that tab, the row below (old row 2) becomes active.
        click(ctl.sidebar.rows[1])
        guard await until(5, { selected == 1 }) else { return finish(false, "row click did not select row 1") }
        let below = ctl.list.items[2].id
        cmdW()
        guard await until(10, { rowCount == 3 && win.tabs.count == 3 && ctl.list.activeID == below }) else {
            return finish(false, "Cmd+W: rows=\(rowCount) engine tabs=\(win.tabs.count) selected=\(selected.map(String.init) ?? "nil") actions=\(ctl.actionCounts)")
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard rowCount == 3, ctl.actionCounts["closeTab"] == 1 else { return finish(false, "Cmd+W acted more than once: rows=\(rowCount) \(ctl.actionCounts)") }
        // Mouse: New Tab row adds a tab, a middle click closes a row.
        click(ctl.sidebar.newTabRow)
        guard await until(10, { rowCount == 4 && win.tabs.count == 4 }) else { return finish(false, "New Tab row: rows=\(rowCount)") }
        click(ctl.sidebar.rows[0], middle: true)
        guard await until(10, { rowCount == 3 && win.tabs.count == 3 }) else { return finish(false, "middle click: rows=\(rowCount) engine tabs=\(win.tabs.count)") }
        finish(maxOwnWindows == 1 && violations.isEmpty, "Cmd+T x3 -> 4 rows, newest active; next/previous wrap \(trail); Cmd+W closed one, row below active; row click, New Tab row, middle click; own windows max \(maxOwnWindows); actions \(ctl.actionCounts) \(violations)")
    }

    private func tabsRapid() async {
        guard await ready(), let ctl, let win, let first = win.tabs.first else { return }
        for _ in 0..<20 { cmdT() }
        for _ in 0..<20 { cmdW() }  // 21 tabs with the first: the brief's 19 would leave two
        guard await until(30, { rowCount == 1 && win.tabs.count == 1 }) else {
            return finish(false, "rapid: rows=\(rowCount) engine tabs=\(win.tabs.count) actions=\(ctl.actionCounts)")
        }
        guard win.tabs.first === first else { return finish(false, "the surviving tab is not the first one") }
        let count = await extensionTabCount(first, want: 1)
        finish(count == 1 && ctl.actionCounts["newTab"] == 20 && ctl.actionCounts["closeTab"] == 20 && maxOwnWindows == 1 && violations.isEmpty,
               "20x Cmd+T then 20x Cmd+W: 1 row, 1 engine tab, extension count \(count.map(String.init) ?? "nil"), actions \(ctl.actionCounts), own windows max \(maxOwnWindows) \(violations)")
    }

    private func extCount() async {
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

    private func navigate() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let port = URL(string: url)?.port else { return }
        func load(_ text: String) async -> Bool {
            let before = loads
            cmdL()
            guard ctl.toolbar.address.currentEditor() != nil else { return false }
            typeText(text)
            if ctl.toolbar.address.stringValue != text { ctl.toolbar.address.currentEditor()?.insertText(text) }
            pressReturn()
            return await until(15, { loads > before })
        }
        cmdL()
        let editor = ctl.toolbar.address.currentEditor()
        guard let editor, editor.selectedRange.length == (ctl.toolbar.address.stringValue as NSString).length, ctl.toolbar.address.stringValue == url else {
            return finish(false, "Cmd+L: editor \(editor != nil) selection \(editor?.selectedRange ?? NSRange()) text \(ctl.toolbar.address.stringValue)")
        }
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

    private func blankLink() async {
        guard await ready(), let ctl, let win, let opener = win.activeTab else { return }
        opener.loadURL(fixture("link.html"))
        guard await until(10, { loads >= 2 }) else { return finish(false, "link page did not load") }
        guard await openTabs(3) else { return finish(false, "extra tabs never appeared") }
        click(ctl.sidebar.rows[0])
        guard await until(5, { selected == 0 }) else { return finish(false, "could not select the opener row") }
        let rows = rowCount
        _ = await evaluate(opener, "document.getElementById('l').click()")
        guard await until(10, { rowCount == rows + 1 }) else { return finish(false, "no new row after the click (rows=\(rowCount))") }
        try? await Task.sleep(for: .milliseconds(500))
        finish(rowCount == rows + 1 && selected == 1 && win.tabs.count == rows + 1 && ownWindows() == 1 && violations.isEmpty,
               "target=_blank click: one new row at index \(selected.map(String.init) ?? "nil") (opener 0), active; rows=\(rowCount) engine tabs=\(win.tabs.count) windows=\(ownWindows()) \(violations)")
    }

    private func longTitle() async {
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
            let want = CGRect(x: 6, y: 93 + 37 * CGFloat(i), width: 185, height: 37)
            if ctl.frame(ofIdentifier: "sidebar.tab.\(i)").map({ !near($0, want.minX, want.minY, want.width, want.height) }) ?? true { bad.append("row \(i) frame is not \(want)") }
            if !row.showsPlaceholder { bad.append("row \(i) has no placeholder although the page has no favicon") }
        }
        finish(bad.isEmpty && violations.isEmpty, "titles of 300 W, Arabic and emoji stay inside rows of pitch 37, no ellipsis, fade mask, placeholder favicon \(bad) \(violations)")
    }

    private func loadError() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        let good = tab.url
        let failures = loadFailures
        tab.loadURL("http://127.0.0.1:1/")
        guard await until(15, { loadFailures > failures }) else { return finish(false, "no load error for a closed port") }
        _ = await until(5, { ctl.toolbar.back.isEnabled })
        line("info", "back enabled=\(ctl.toolbar.back.isEnabled) canGoBack=\(tab.canGoBack)")
        let title = ctl.list.displayTitle(of: ctl.list.items[0].id)
        let address = ctl.toolbar.address.stringValue
        line("info", "after the error: tab url \(tab.url) title \(tab.title) row title \(title) address \(address)")
        guard title == "127.0.0.1", address == "127.0.0.1" else { return finish(false, "row title \(title) address \(address)") }
        shortcut("Go Back")
        // The tab keeps the old URL while the error page shows, so the page itself is the evidence.
        var pageTitle: String?
        for _ in 0..<40 {
            pageTitle = await evaluate(tab, "document.title")
            if pageTitle == "\"Noche App Fixture\"" { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard pageTitle == "\"Noche App Fixture\"" else { return finish(false, "back enabled=\(ctl.toolbar.back.isEnabled) canGoBack=\(tab.canGoBack) keys=\(keyLog) Back shows the page titled \(pageTitle ?? "nil") (row title \(ctl.list.displayTitle(of: ctl.list.items[0].id)))") }
        finish(violations.isEmpty, "closed port: row title and address are the host, Back returns to \(good) \(violations)")
    }

    private static let expectedMenu = [
        "Noche||", "About Noche||", "Hide Noche|h|cmd", "Hide Others|h|opt+cmd", "Show All||", "Quit Noche|q|cmd",
        "File||", "New Tab|t|cmd", "New Window|n|cmd", "Open Command Bar|l|cmd", "Close Window|w|shift+cmd", "Close Tab|w|cmd",
        "Edit||", "Undo|z|cmd", "Redo|z|shift+cmd", "Cut|x|cmd", "Copy|c|cmd", "Copy URL|c|shift+cmd", "Paste|v|cmd", "Select All|a|cmd",
        "View||", "Refresh|r|cmd", "Force Refresh the Page|r|shift+cmd", "Auto-Hide Tabs|s|cmd", "Zoom to Actual Size|0|cmd",
        "Zoom In|+|cmd", "Zoom Out|-|cmd", "Developer||", "Developer Tools|i|opt+cmd",
        "Tabs||", "Go Back|[|cmd", "Go Forward|]|cmd", "Next Tab|]|shift+cmd", "Previous Tab|[|shift+cmd",
        "Window||", "Minimize|m|cmd",
    ]

    private func menu() async {
        guard let menu = NSApp.mainMenu else { return finish(false, "no main menu") }
        // AppKit adds an AutoFill group to the Edit menu itself.
        let injected: Set<String> = ["AutoFill||", "Contact…||", "Passwords…||", "Credit Card…||"]
        let got = MainMenu.dump(menu).filter { !injected.contains($0) }
        if got != Self.expectedMenu {
            let diff = zip(got, Self.expectedMenu).enumerated().first { $0.element.0 != $0.element.1 }
            return finish(false, "menu differs: \(got.count) lines vs \(Self.expectedMenu.count), first difference \(String(describing: diff)); live menu \(got)")
        }
        finish(true, "\(got.count) menu lines equal the M1.1 list")
    }

    private func sidebarToggle() async {
        guard await ready(), let ctl else { return }
        func run(hide: Bool, limit: Double, viaButton: Bool = false) async -> (ms: Double, max: CGFloat, done: Bool) {
            let target: CGFloat = hide ? 6 : 197
            ctl.cardLog = []
            let t0 = ProcessInfo.processInfo.systemUptime
            if viaButton { click(ctl.toolbar.toggle) } else { cmdS() }
            var reached: Double?
            while ProcessInfo.processInfo.systemUptime - t0 < 0.6 {
                if ctl.cardX == target { reached = (ProcessInfo.processInfo.systemUptime - t0) * 1000; break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            // From the action starting to the settled frame (the key dispatch before it is reported apart).
            let animated = ctl.toggleEnd > 0 ? (ctl.toggleEnd - ctl.toggleStart) * 1000 : .infinity
            line("info", "\(hide ? "hide" : "show") key to action \(String(format: "%.0f", (ctl.toggleStart - t0) * 1000)) ms, action to settled frame \(String(format: "%.0f", animated)) ms, seen by the poll after \(String(format: "%.0f", reached ?? -1)) ms")
            return (reached != nil ? animated : .infinity, ctl.cardLog.map(\.x).max() ?? 0, reached != nil)
        }
        let hide = await run(hide: true, limit: 145)
        let lightsHidden = ctl.sidebar.lights.allSatisfy(\.isHidden)
        let show = await run(hide: false, limit: 125)
        let overshoot = show.max - 197
        let hideAgain = await run(hide: true, limit: 145, viaButton: true)
        line("info", "hide \(String(format: "%.0f", hide.ms)) ms (limit 145), show \(String(format: "%.0f", show.ms)) ms (limit 125), overshoot \(String(format: "%.2f", overshoot)) pt, button hide \(String(format: "%.0f", hideAgain.ms)) ms")
        let ok = hide.ms <= 145 && lightsHidden && show.ms <= 125 && overshoot > 0.3 && overshoot <= 2.5 && ctl.actionCounts["toggleSidebar"] == 3 && hideAgain.ms <= 145
        finish(ok && violations.isEmpty, "Cmd+S hides in \(String(format: "%.0f", hide.ms)) ms with the lights hidden, shows in \(String(format: "%.0f", show.ms)) ms with \(String(format: "%.2f", overshoot)) pt overshoot ending at 197; the toggle button hides again in \(String(format: "%.0f", hideAgain.ms)) ms; actions \(ctl.actionCounts) \(violations)")
    }

    // MARK: helpers

    private func until(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    private func evaluate(_ tab: NCTab, _ js: String) async -> String? {
        await withCheckedContinuation { c in
            // The bridge calls back inside CEF callbacks: continue on the next main-queue turn before touching tabs.
            tab.evaluateJavaScript(js) { json, _ in DispatchQueue.main.async { c.resume(returning: json) } }
        }
    }


    private func finish(_ ok: Bool, _ detail: String) {
        guard !verdictPrinted else { return }
        verdictPrinted = true
        line(ok ? "pass" : "fail", detail)
        app.selfTestFinished(ok: ok)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
