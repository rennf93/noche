#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Hidden self-test harness: `Noche --selftest <check> --selftest-url <url>`, driven by scripts/app-test.sh.
/// Prints `NOCHE_TEST <check> pass|fail|info ...` lines; the process exit code is 0 only when the check passed.
/// Later tasks add checks to `run()`. Nothing here may wait for a rendered frame: the app runs hidden, and a locked
/// screen gives a hidden window none (load-end and CEF callbacks still arrive).
@MainActor
final class SelfTest {
    struct Options { let check: String; let url: String; let phase: Int? }

    /// The first window's frame (AppKit global coordinates, origin bottom-left): 1436 high from the top of the 2560x1440 screen.
    /// It starts 300 pt in because macOS Stage Manager keeps windows out of its strip at the screen's left edge (see windowFrame()).
    static let windowFrame = NSRect(x: 300, y: 4, width: 2200, height: 1436)

    /// The app's own time limit for a check, in seconds (scripts/app-test.sh allows 20 s more before it kills the app).
    static func limit(of check: String) -> TimeInterval { check == "quit-100" ? 90 : 40 }

    /// Names ending in -relaunch, and the two store checks that script their own phase 1 ending (crash-mid-write) or phase 2 start (corrupt-store).
    static func isTwoPhase(_ check: String) -> Bool { check.hasSuffix("-relaunch") || check == "cb-history" || check == "crash-mid-write" || check == "corrupt-store" || check.hasPrefix("pin-launch") || check == "move-window" || check == "merge-windows" }

    static func parse(_ args: [String]) -> Options? {
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return nil }
        var url = "about:blank"
        if let u = args.firstIndex(of: "--selftest-url"), u + 1 < args.count { url = args[u + 1] }
        // Two-phase checks (names ending in -relaunch) run twice on one profile: --selftest-phase 1, then 2. 0 stands for a present but invalid value.
        var phase: Int?
        if let p = args.firstIndex(of: "--selftest-phase") { phase = (p + 1 < args.count ? Int(args[p + 1]) : nil).flatMap { [1, 2, 3].contains($0) ? $0 : nil } ?? 0 }
        return Options(check: args[i + 1], url: url, phase: phase)
    }

    let check: String
    let url: String
    let phase: Int?
    unowned let app: AppDelegate
    private(set) var verdictPrinted = false
    var violations: [String] = []
    var added = 0, closedTabs = 0, windowsClosed = 0, loads = 0, loadFailures = 0
    var maxOwnWindows = 0
    var keyLog: [String] = []
    var lastExtensionReply = ""
    var tabsAtQuit = 0
    var menuOpenedAtQuit = false
    var quitSentAt: TimeInterval = 0
    var permissionRequests: [(mask: NCPermissionMask, origin: String, topOrigin: String, id: UInt64)] = []
    /// The MIDI sysex check may Allow a request whose mask is Other only; every other Allow of a test run is a violation.
    var allowOther = false
    /// dl-quit-relaunch: the server that must outlive the check until the quit's pause has landed, and the download it serves.
    var slowServer: SlowServer?
    var relaunchID: UInt32?

    init(_ options: Options, app: AppDelegate) {
        check = options.check
        url = options.url
        phase = options.phase
        self.app = app
        // pin-launch-held restores with its last tab withheld and the fallback at 3 s instead of 15.
        if options.check == "pin-launch-held", options.phase == 2 { BrowserWindowController.holdLastRestoreTab = true; BrowserWindowController.restoreFallback = 3 }
    }

    // MARK: events from AppDelegate

    var closedIDs = Set<Int>()
    var zombies: [String] = []
    var devToolsOpened = false
    /// A tab the delegate was told is closed must never be announced again nor listed by its window.
    func audit(_ what: String, _ tab: NCTab) {
        if closedIDs.contains(tab.identifier), zombies.count < 5 { zombies.append("\(what) \(tab.identifier) after its didCloseTab") }
        for c in app.controllers where c.window.tabs.contains(where: { closedIDs.contains($0.identifier) }) {
            if zombies.count < 5 { zombies.append("window.tabs holds a closed tab at \(what)") }
        }
    }
    func didAddTab(_ tab: NCTab) { added += 1; audit("didAddTab", tab) }
    func didActivateTab(_ tab: NCTab) { audit("didActivateTab", tab) }
    func didCloseTab(_ tab: NCTab) { closedTabs += 1; audit("didCloseTab", tab); closedIDs.insert(tab.identifier) }
    func windowDidClose() { windowsClosed += 1 }
    func didFinishLoad() { loads += 1 }
    func didFailLoad() { loadFailures += 1 }

    /// Last thing before the process exits. quit-many's verdict is the exit itself, so it is printed here.
    func beforeExit(watchdogFired: Bool) {
        if check == "quit-many", !verdictPrinted {
            let ok = tabsAtQuit == 15 && closedTabs == 15 && windowsClosed == 2 && !watchdogFired && violations.isEmpty && zombies.isEmpty
            line(ok ? "pass" : "fail", "2 windows (10 and 5 tabs), quit menu action, exit without the shutdown watchdog (tabs=\(tabsAtQuit) didCloseTab=\(closedTabs) windowDidClose=\(windowsClosed) watchdog=\(watchdogFired) \(violations) \(zombies))")
            if !ok { app.exitCodeOverride = 1 }
        }
        if check.hasPrefix("quit-menu-") || check == "quit-with-context-menu", !verdictPrinted {
            // Before NCEngine.shutdown. A shutdown inside menu tracking runs inside a Chromium task and aborts. The waits and the stderr note come from the app's own counters.
            let waited = ProcessInfo.processInfo.systemUptime - quitSentAt
            let expired = app.shutdownNotes.contains { $0.hasPrefix("NOCHE shutdown: a menu was still open") }
            let ok: Bool, what: String
            switch check {
            case "quit-menu-late":  // the menu ends 300 ms after the cancel: the shutdown waits for it
                ok = !ContextMenus.tracking && app.menuWaits >= 1 && waited >= 0.25 && !expired
                what = "the menu ends 300 ms after the quit cancels it, the shutdown waits (waits>=1) and starts with no menu tracking"
            case "quit-menu-stuck":  // the menu never ends: the bound expires with one stderr line and the quit still completes
                ok = ContextMenus.tracking && app.menuWaits >= 1 && expired && waited >= 2.5 && waited < 12
                what = "a menu that never ends: the wait expires after about 3 s with one NOCHE shutdown line on stderr and the quit completes"
            default:
                ok = !ContextMenus.tracking
                what = "a page context menu open, quit menu action, no menu tracking when the engine shutdown starts"
            }
            line(ok && menuOpenedAtQuit && !watchdogFired && violations.isEmpty && zombies.isEmpty ? "pass" : "fail", "\(what) (opened=\(menuOpenedAtQuit) tracking=\(ContextMenus.tracking) waits=\(app.menuWaits) waited=\(String(format: "%.2f", waited)) s notes=\(app.shutdownNotes.count) watchdog=\(watchdogFired) \(violations) \(zombies))")
            if !(ok && menuOpenedAtQuit && !watchdogFired && violations.isEmpty && zombies.isEmpty) { app.exitCodeOverride = 1 }
        }
        if check == "quit-100", !verdictPrinted {
            let created = NCWindow.devToolsCreated(), ended = NCWindow.devToolsClosed()
            let ok = tabsAtQuit == 100 && closedTabs == 100 && windowsClosed == 2 && created == 1 && ended == created && !watchdogFired && violations.isEmpty && zombies.isEmpty
            line(ok ? "pass" : "fail", "100 tabs in 2 windows and one DevTools, closed 100 ms apart, quit menu action, clean exit without the shutdown watchdog (tabs=\(tabsAtQuit) didCloseTab=\(closedTabs) windowDidClose=\(windowsClosed) devtools created=\(created) ended=\(ended) watchdog=\(watchdogFired) \(violations) \(zombies))")
            if !ok { app.exitCodeOverride = 1 }
        }
        if check == "devtools-quit" || check == "devtools-any-path", !verdictPrinted {
            let devTools = app.windows.reduce(0) { $0 + Int($1.devToolsCount) }
            // Before NCEngine.shutdown: every DevTools browser must already have had its OnBeforeClose.
            let created = NCWindow.devToolsCreated(), ended = NCWindow.devToolsClosed()
            let ok = devToolsOpened && created >= 1 && ended == created && !watchdogFired && windowsClosed == 1 && violations.isEmpty && zombies.isEmpty
            line(ok ? "pass" : "fail", "DevTools open (front end loaded), quit menu action, every DevTools browser ended before shutdown (created=\(created) loaded=\(NCWindow.devToolsLoaded()) ended=\(ended) opened=\(devToolsOpened) windowDidClose=\(windowsClosed) devtools left=\(devTools) watchdog=\(watchdogFired) \(violations) \(zombies))")
            if !ok { app.exitCodeOverride = 1 }
        }
        dlQuitVerdict()
        line("info", "activate-blocked=\(NCWindow.activationsBlocked())")
    }

    // MARK: running

    func start() {
        // Invariants of every hidden run: no window shows, none is key, the app never becomes active.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        let limit = SelfTest.limit(of: check)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            MainActor.assumeIsolated { self?.finish(false, "timeout (\(Int(limit)) s); look at screen lock and CPU load before suspecting the code") }
        }
        Task { @MainActor in
            if phase == 0 { return finish(false, "bad --selftest-phase (want 1, 2 or 3)") }
            if SelfTest.isTwoPhase(check), phase == nil { return finish(false, "bad --selftest-phase: a -relaunch check needs it") }
            switch check {
            case "hidden": await hidden()
            case "close-last": await closeLast()
            case "quit-many": await quitMany()
            case "quit-early": await quitEarly()
            case "quit-with-context-menu", "quit-menu-late", "quit-menu-stuck": await quitWithContextMenu()
            case "quit-100": await quit100()
            case "web-insets": await webInsets()
            case "layout": await layout()
            case "tabs-keys": await tabsKeys()
            case "tabs-rapid": await tabsRapid()
            case "ext-count": await extCount()
            case "navigate": await navigate()
            case "blank-link": await blankLink()
            case "long-title": await longTitle()
            case "load-error": await loadError()
            case "menu-diff": await menuDiff()
            case "menu-disabled": await menuDisabled()
            case "menu-actions": await menuActions()
            case "sidebar-toggle": await sidebarToggle()
            case "sidebar-scroll": await sidebarScroll()
            case "sidebar-geometry": await sidebarGeometry()
            case "sidebar-columns": await sidebarColumns()
            case "sidebar-scale": await sidebarScale()
            case "drag-reorder": await dragReorder()
            case "drag-autoexpand": await dragAutoexpand()
            case "drag-cancel": await dragCancel()
            case "drag-property": await dragProperty()
            case "drag-haptic": await dragHaptic()
            case "drag-relaunch": await dragRelaunch()
            case "search-tabs": await searchTabs()
            case "ctrl-tab": await ctrlTabCheck()
            case "shortcuts-order": await shortcutsOrder()
            case "move-window": await moveWindow()
            case "merge-windows": await mergeWindows()
            case "revive-window": await reviveWindow()
            case "groups": await groups()
            case "group-colors": await groupColors()
            case "group-menus": await groupMenus()
            case "group-icons": await groupIcons()
            case "group-restore-relaunch": await groupRestore()
            case "group-rename-scroll": await groupRenameScroll()
            case "rename-tab": await renameTab()
            case "rename-focus": await renameFocus()
            case "pin-toggle": await pinToggle()
            case "pin-dormant": await pinDormant()
            case "pin-reset": await pinReset()
            case "pin-launch": await pinLaunch(held: false)
            case "pin-launch-held": await pinLaunch(held: true)
            case "reopen-container": await reopenContainer()
            case "pin-reveal": await pinReveal()
            case "discard-click": await discardClick()
            case "discard-policy": await discardPolicy()
            case "discard-hang": await discardHang()
            case "discard-media": await discardMedia()
            case "min-width": await minWidth()
            case "min-width-relaunch": await minWidthRelaunch()
            case "shortcuts-once": await shortcutsOnce()
            case "eval-async": await evalAsync()
            case "focus-return": await focusReturn()
            case "newtab-surface": await newTabSurface()
            case "no-zombie-tab": await noZombieTab()
            case "devtools-quit": await devToolsQuit()
            case "devtools-any-path": await devToolsAnyPath()
            case "devtools-close-tab": await devToolsCloseTab()
            case "load-error-link": await loadErrorLink()
            case "window-frame": await windowFrame()
            case "a11y-labels": await a11yLabels()
            case "no-window": await noWindow()
            case "close-beforeunload": await closeBeforeUnload()
            case "chromium-restore-relaunch", "chromium-restore-crash-relaunch": await chromiumRestoreRelaunch()
            case "persist-relaunch": await persistRelaunch()
            case "quit-close-relaunch": await quitCloseRelaunch()
            case "reopen-closed": await reopenClosed()
            case "reopen-closed-relaunch": await reopenClosedRelaunch()
            case "crash-mid-write": await crashMidWrite()
            case "corrupt-store": await corruptStore()
            case "reopen-identity": await reopenIdentity()
            case "frame-storm": await frameStorm()
            case "store-unavailable": await storeUnavailable()
            case "quit-close-dirty-relaunch": if phase == 1 { await quitCloseDirty() } else { await quitCloseRelaunch() }
            case "window-close-cancel": await windowCloseCancel()
            case "tab-chords": await tabChords()
            case "move-tab-relaunch": await moveTabRelaunch()
            case "history-record": await historyRecord()
            case "title-throttle": await titleThrottle()
            case "title-flush": await titleFlush()
            case "history-window": await historyWindow()
            case "history-cap": await historyCap()
            case "history-dock": await historyDock()
            case "title-window-close": await titleWindowClose()
            case "window-recency": await windowRecency()
            case "dl-remove-relaunch": await dlRemoveRelaunch()
            case "dl-cancel-slow": await dlCancelSlow()
            case "bm-add": await bmAdd()
            case "bm-bar": await bmBar_()
            case "bm-bar-relaunch": await bmBarRelaunch()
            case "bm-open": await bmOpen()
            case "bm-manager": await bmManager()
            case "bm-suggest": await bmSuggest()
            case "cb-readpath": await cbReadPath()
            case "cb-reopen": await cbReopen()
            case "perm-origins": await permOrigins()
            case "perm-dismiss-id": await permDismissId()
            case "window-front": await windowFront()
            case "bm-dupes": await bmDupes()
            case "bm-remove-undo": await bmRemoveUndo()
            case "bm-undo-valid": await bmUndoValid()
            case "cb-reopen-reqlate": await cbReopenReqLate()
            case "cb-reopen-late": await cbReopenLate()
            case "dl-file-stats": await dlFileStats()
            case "bm-menu-lazy": await bmMenuLazy()
            case "dl-clear-write": await dlClearWrite()
            case "dl-reuse": await dlReuse()
            case "dl-file-missing": await dlFileMissing()
            case "dl-rows": await dlRows()
            case "quit-gap-close-relaunch": await quitGap(closeLast: true)
            case "quit-gap-tab-relaunch": await quitGap(closeLast: false)
            case "bm-all-tabs": await bmAllTabs()
            case "cb-layout": await cbLayout()
            case "cb-open": await cbOpen()
            case "cb-motion": await cbMotion()
            case "cb-go": await cbGo()
            case "cb-escape": await cbEscape()
            case "cb-arrows": await cbArrows()
            case "cb-inline": await cbInline()
            case "cb-switch-tab": await cbSwitchTab()
            case "cb-outside": await cbOutside()
            case "cb-nonet": await cbNonet()
            case "cb-nonet-default": await cbNonetDefault()
            case "cb-history": await cbHistory()
            case "ctx-page": await ctxPage()
            case "ctx-tab": await ctxTab()
            case "ctx-sidebar": await ctxSidebar()
            case "find": await find()
            case "zoom": await zoom()
            case "find-selection": await findSelection()
            case "find-restart": await findRestart()
            case "find-nav": await findNavigation()
            case "find-engine": await findEngine()
            case "find-escape": await findEscape()
            case "find-escape-page": await findEscapePage()
            case "find-escape-guards": await findEscapeGuards()
            case "zoom-engine": await zoomEngine()
            case "pw-on": await pwOn()
            case "bridge-dl": await bridgeDl()
            case "bridge-perm": await bridgePerm()
            case "dl-list": await dlList()
            case "dl-controls": await dlControls()
            case "dl-tab-close": await dlTabClose()
            case "dl-quit-relaunch": await dlQuitRelaunch()
            case "dl-restored-cancel-relaunch": await dlQuitRelaunch(cancelRestored: true)
            case "dl-restored-silent-relaunch": await dlQuitRelaunch(cancelRestored: true, silent: true)
            case "dl-ring": await dlRing()
            case "perm-prompt": await permPrompt()
            case "perm-remember", "perm-remember-relaunch": await permRemember()
            case "perm-no-bubble": await permNoBubble()
            case "perm-dismiss": await permDismiss()
            case "perm-guards": await permGuards()
            case "perm-forget": await permForget()
            case "perm-iframe": await permIframe()
            default: finish(false, "unknown check")
            }
        }
    }

    func sample() {
        maxOwnWindows = max(maxOwnWindows, ownWindows())
        func note(_ s: String) { if violations.count < 5, !violations.contains(s) { violations.append(s) } }
        if NSApp.isActive { note("NSApp.isActive") }
        // TUINSWindow is macOS's own text-input window (it sits at alpha 1 and is not ours); every other window counts. Our own windows at alpha 1 are caught by hidden's
        // alpha-attempt count (setAlphaValue: is clamped), see the NOCHE_TEST_NEGATIVE=alpha pair in app-test.sh.
        for w in NSApp.windows where !NSStringFromClass(type(of: w)).hasPrefix("TUI") {
            if w.alphaValue != 0 { note("alpha=\(w.alphaValue) on \(type(of: w))") }
            if w.isKeyWindow { note("key window \(type(of: w))") }
        }
    }

    // MARK: chrome checks

    var ctl: BrowserWindowController? { app.controllers.first }
    var win: NCWindow? { ctl?.window }
    var selected: Int? { ctl.flatMap { c in c.list.items.firstIndex { $0.id == c.list.activeID } } }
    var rowCount: Int { ctl?.sidebar.tabRowCount ?? 0 }
    func fixture(_ path: String) -> String { url + path }

    /// The window is up, its chrome installed and the first page loaded.
    func ready() async -> Bool {
        guard await until(15, { loads >= 1 && rowCount == 1 && ctl?.view(withIdentifier: "toolbar") != nil }) else {
            finish(false, "first tab never finished loading, or no chrome (loads=\(loads) rows=\(rowCount))")
            return false
        }
        return true
    }

    /// Opens tabs on the fixture until |n| rows exist, and waits for their pages.
    func openTabs(_ n: Int, page: String = "") async -> Bool {
        guard let win else { return false }
        let before = loads
        for _ in 0..<(n - rowCount) { _ = win.addTab(withURL: fixture(page), activate: false) }
        return await until(20, { rowCount == n && win.tabs.count == n && loads >= before + (n - 1) })
    }


    /// Windows of this process that are real windows: macOS's own text-input window (TUINSWindow, 500x500, it appears whenever a text field
    /// is being edited, as the command bar's is on every New Tab) is not one.
    func ownWindows() -> Int {
        let pid = ProcessInfo.processInfo.processIdentifier
        let textInput = Set(NSApp.windows.filter { NSStringFromClass(type(of: $0)).hasPrefix("TUI") }.map { Int($0.windowNumber) })
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), !textInput.contains((w[kCGWindowNumber as String] as? Int) ?? -1) else { return false }
            return r.width >= 400 && r.height >= 300
        }.count
    }

    /// A person who quits as soon as the first page loaded must not crash the engine (its startup tasks are still pending);
    /// the verdict is the exit and the crash-report diff in scripts/app-test.sh. The first load end is where the crash window is:
    /// quitting at the first tab (earlier) or 0.3 s or more later never hit it.
    func quitEarly() async {
        guard await until(15, { loads >= 1 }) else { return finish(false, "first tab never finished loading") }
        finish(true, "quit right after the first load")
    }

    func line(_ kind: String, _ detail: String) { print("NOCHE_TEST \(check) \(kind) \(detail)"); fflush(stdout) }

    func near(_ a: CGRect?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a.minX - x) <= 1 && abs(a.minY - y) <= 1 && abs(a.width - w) <= 1 && abs(a.height - h) <= 1
    }

    // MARK: helpers

    func until(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    func evaluate(_ tab: NCTab, _ js: String) async -> String? {
        await withCheckedContinuation { c in
            // The bridge calls back inside CEF callbacks: continue on the next main-queue turn before touching tabs.
            tab.evaluateJavaScript(js) { json, _ in DispatchQueue.main.async { c.resume(returning: json) } }
        }
    }


    func finish(_ ok: Bool, _ detail: String) {
        guard !verdictPrinted else { return }
        verdictPrinted = true
        line(ok ? "pass" : "fail", detail)
        DispatchQueue.main.async { [app] in MainActor.assumeIsolated { app.selfTestFinished(ok: ok) } }
    }
}

#endif
