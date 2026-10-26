import AppKit
import CefBridge
import NocheCore
import NocheStore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let smoke = SmokeOptions.parse(CommandLine.arguments)
#if NOCHE_TESTHOOKS
    private let selfTestOptions = SelfTest.parse(CommandLine.arguments)
    private(set) var selfTest: SelfTest?
    /// Set by the self-test when its verdict is only known at exit.
    var exitCodeOverride: Int32?
#endif
    private(set) var controllers: [BrowserWindowController] = []
    let downloads = DownloadsController()
    var writer: StoreWriter?
    private(set) var restored: [WindowSnapshot] = []
    private(set) var storeURL: URL?
    private(set) var storeFallback: String?
    var windows: [NCWindow] { controllers.map(\.window) }
    var searchTemplate = AddressInput.defaultSearchTemplate
    /// View > Show Full URL: the toolbar address shows the whole address instead of the host.
    var showFullURL = false
    private var finished = false
    private var exitCode: Int32 = 0
    private var status: Int?
    private var title: String?

    /// Smoke and self-test runs share the owner's Mac: hidden windows, no Dock icon, never frontmost.
    var hidden: Bool {
#if NOCHE_TESTHOOKS
        if selfTestOptions != nil { return true }
#endif
        return smoke != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if hidden { NCWindow.installHiddenGuards() }
        // Pinch and Cmd+scroll zoom the page inside the engine: the zoom pill reads the level again after each such event.
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] e in
            if e.type == .magnify || e.modifierFlags.contains(.command) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.active?.syncZoomSoon() } } }
            return e
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.noche.browser")
        if others.contains(where: { $0.processIdentifier != me }) {
            finish(.alreadyRunning, closeBrowser: false)
            return
        }

        var profile = "Library/Application Support/Noche"
        var url = smoke?.url.absoluteString ?? "about:blank"
        var storeSettings: [(String, String)] = []
        var frame = Self.defaultFrame(size: NSSize(width: 1280, height: 800))
#if NOCHE_TESTHOOKS
        if let options = selfTestOptions {
            profile = "Library/Application Support/Noche Test"  // never the dev profile
            url = options.url
            frame = SelfTest.windowFrame
            selfTest = SelfTest(options, app: self)
            if options.phase == 2 { url = "about:blank" }  // a relaunch with nothing to restore shows a blank tab, not the fixture
            // --selftest-setting key=value: a setting stored before the restore, until Settings (M1.8) can set it.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--selftest-setting"), i + 1 < args.count, let eq = args[i + 1].firstIndex(of: "=") {
                storeSettings.append((String(args[i + 1][..<eq]), String(args[i + 1][args[i + 1].index(after: eq)...])))
            }
            searchTemplate = options.url + "search?q=%s"  // no self-test touches the network
        }
#endif
        openStore(profile: profile, settings: storeSettings)
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(profile + "/Cache")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try NCEngine.start(withCachePath: cache.path)
        } catch {
            FileHandle.standardError.write(Data("NOCHE engine start failed: \(error.localizedDescription)\n".utf8))
            exit(4)
        }

        // Downloads go to ~/Downloads with no save dialog (Chrome's default); M1.8 Settings will store a user choice and call this again.
        var downloadFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
#if NOCHE_TESTHOOKS
        // A test run never writes to the owner's Downloads: its files go to a folder of the wiped test profile.
        if selfTestOptions != nil {
            downloadFolder = SelfTest.downloadFolder
            try? FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        }
#endif
        do { try NCEngine.setDownloadDirectory(downloadFolder.path) } catch {
            FileHandle.standardError.write(Data("NOCHE download folder: \(error.localizedDescription)\n".utf8))
        }
        // The profile's download handler goes in before any window or session is restored: downloads whose tab closed, and downloads restored
        // from the last session, report to the Downloads window, and the quit can pause them.
        if !BarHook.on("DL_NOSTART") { NCDownloads.shared.start(observer: downloads) }
        ChromeCommand.resolve()
        restoreWindows(startupURL: url, startupFrame: frame)

        if let smoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + smoke.timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(.timeout) }
            }
        }
#if NOCHE_TESTHOOKS
        selfTest?.start()
#endif
    }

    /// One window with one tab at |url|.
    @discardableResult
    func newWindow(url: String = "about:blank", frame: NSRect? = nil, id: UUID = UUID(), restore: BrowserWindowController.Restore? = nil) -> NCWindow {
        let controller = BrowserWindowController(app: self, id: id, url: url, frame: frame ?? Self.defaultFrame(size: NSSize(width: 1280, height: 800)), restore: restore)
        controllers.append(controller)
        return controller.window
    }

    // MARK: store

    /// The store lives in the profile directory. A smoke run shares the owner's profile and must not touch its windows: in memory.
    /// Any open error other than a corrupt file (which the store quarantines itself) runs this session on an in-memory store.
    private func openStore(profile: String, settings: [(String, String)]) {
        var store: Store?
        if smoke == nil {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(profile + "/Store/noche.sqlite")
            storeURL = url
            do { store = try Store.open(at: url) } catch {
                storeFallback = "\(error)"
                FileHandle.standardError.write(Data("NOCHE store unavailable: \(error)\n".utf8))
            }
        }
        guard let store = store ?? (try? Store.inMemory()) else { return }
        for (k, v) in settings where (k == "quitBehavior" && ["preserve", "close"].contains(v)) || (k == "suggestRemote" && ["0", "1"].contains(v)) {
            try? store.setSetting(k, v)
        }
        let w = StoreWriter(store: store)
        w.snapshot = { [weak self] id in
            guard let self, let i = self.controllers.firstIndex(where: { $0.id == id }) else { return nil }
            return self.controllers[i].snapshot(zOrder: i)
        }
        w.windowIDs = { [weak self] in self?.controllers.map(\.id) ?? [] }
        writer = w
        restored = (try? store.loadWindows()) ?? []
    }

    /// Restore runs before the first window: each saved window comes back with fresh engine browsers at its saved addresses (no history);
    /// an empty store gives the startup window.
    private func restoreWindows(startupURL: String, startupFrame: NSRect) {
        guard !restored.isEmpty else { newWindow(url: startupURL, frame: startupFrame); return }
        for s in restored {
            let tabs = s.tabs.map { (id: $0.id, url: $0.url.isEmpty ? "about:blank" : $0.url) }
            let ok = s.frame.width >= 200 && s.frame.height >= 150
            let restore = tabs.isEmpty ? nil : BrowserWindowController.Restore(
                tabs: tabs, selected: s.selectedTabID, sidebarHidden: s.sidebarMode == "hidden", fullScreen: s.isFullScreen,
                isZoomed: s.isZoomed, lastActive: s.tabMeta.mapValues(\.lastActiveAt),
                favicons: s.tabMeta.compactMapValues(\.faviconURL))
            newWindow(url: tabs.first?.url ?? "about:blank", frame: ok ? Self.onScreen(s.frame) : startupFrame, id: s.id, restore: restore)
        }
    }

    /// A saved frame that meets no screen now (a display was unplugged) moves onto the main screen, keeping its size (cut to fit).
    static func onScreen(_ f: NSRect) -> NSRect {
        NSScreen.screens.contains { $0.visibleFrame.intersects(f) } ? f : defaultFrame(size: f.size)
    }

    /// File > New Window: same size as the window it is opened from, 22 pt down and right of it (back to the corner at the screen's edge).
    func newWindowAction() {
        BrowserWindowController.note("newWindow")
        guard let base = active?.nsWindow?.frame else { newWindow(); return }
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = base.offsetBy(dx: 22, dy: -22)
        if f.maxX > area.maxX || f.minY < area.minY { f = Self.defaultFrame(size: base.size) }
        newWindow(frame: f)
    }

    /// File > Reopen Closed Tab: the newest closed tab goes back to its window at its index (clamped), else the front window, appended.
    @objc func reopenClosedTab(_ s: Any?) {
        guard !closing, let closed = writer?.peekClosed() else { return }
        // The tab stays on the closed list until it is back in a window: a crash in between loses nothing.
        if let c = controllers.first(where: { $0.id == closed.windowID }) ?? active {
            if c.reopen(closed.tab, at: c.id == closed.windowID ? closed.index : Int.max) { writer?.reopened(closed.tab.id) }
        } else {
            let url = closed.tab.url
            newWindow(url: url, id: closed.windowID, restore: .init(tabs: [(closed.tab.id, url)], selected: closed.tab.id, sidebarHidden: false, fullScreen: false, lastActive: [:]))
            writer?.reopened(closed.tab.id)
        }
    }

    /// AppKit frame of a window of |size| 100 pt from the top-left corner of the main screen's visible area (cut to fit).
    static func defaultFrame(size: NSSize) -> NSRect {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(size.width, area.width - 100), h = min(size.height, area.height - 100)
        return NSRect(x: area.minX + 100, y: area.maxY - 100 - h, width: w, height: h)
    }

    var zoomMonitor: Any?

    /// The window menu actions apply to: the key window's, else the newest (hidden windows are never key).
    var active: BrowserWindowController? { controllers.first { $0.nsWindow?.isKeyWindow == true } ?? controllers.last }

    /// A Dock click with no window open makes one. The app never quits when its last window closes, so this is the way back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !closing, controllers.isEmpty else { return true }
        newWindow()
        return false  // handled: AppKit must not also try to open an untitled document
    }

    // MARK: menu actions

    /// With no window open, a window is the new tab: it opens with one tab.
    @objc func newTab(_ s: Any?) { if let a = active { a.newTab() } else if !closing { newWindow() } }
    @objc func newWindowMenu(_ s: Any?) { newWindowAction() }
    @objc func openCommandBar(_ s: Any?) { if let a = active { a.focusAddress() } else if !closing { newWindow(); active?.focusAddress() } }
    @objc func closeWindowMenu(_ s: Any?) { active?.close() }
    @objc func closeTab(_ s: Any?) { active?.closeActiveTab() }
    @objc func copyURL(_ s: Any?) { active?.copyURL() }
    @objc func refresh(_ s: Any?) { active?.reload() }
    @objc func forceRefresh(_ s: Any?) { active?.forceReload() }
    @objc func toggleSidebar(_ s: Any?) { active?.toggleSidebar() }
    @objc func zoomActual(_ s: Any?) { active?.zoom(0) }
    @objc func zoomIn(_ s: Any?) { active?.zoom(1) }
    @objc func zoomOut(_ s: Any?) { active?.zoom(-1) }
    @objc func find(_ s: Any?) { active?.openFind() }
    @objc func findNext(_ s: Any?) { active?.findStep(forward: true) }
    @objc func findPrevious(_ s: Any?) { active?.findStep(forward: false) }
    @objc func useSelectionForFind(_ s: Any?) { active?.useSelectionForFind() }
    @objc func developerTools(_ s: Any?) { active?.showDevTools() }
    @objc func goBack(_ s: Any?) { active?.goBack() }
    @objc func goForward(_ s: Any?) { active?.goForward() }
    @objc func nextTab(_ s: Any?) { active?.selectNextTab() }
    @objc func previousTab(_ s: Any?) { active?.selectPreviousTab() }
    @objc func closeAllTabs(_ s: Any?) { active?.closeAllTabs() }
    @objc func copyURLMarkdown(_ s: Any?) { active?.copyURLMarkdown() }
    @objc func printPage(_ s: Any?) { active?.printPage() }
    @objc func inspectElements(_ s: Any?) { active?.chromeCommand("IDC_DEV_TOOLS_INSPECT", note: "inspectElements") }
    @objc func javaScriptConsole(_ s: Any?) { active?.chromeCommand("IDC_DEV_TOOLS_CONSOLE", note: "javaScriptConsole") }
    @objc func duplicateTab(_ s: Any?) { active?.duplicateTab() }
    /// History is Chromium's own page in a new tab until M1.5 has Noche's; Downloads is Noche's own window.
    @objc func showHistory(_ s: Any?) { openPage("chrome://history", note: "showHistory") }
    @objc func showDownloads(_ s: Any?) { if !closing { downloads.show() } }
    private func openPage(_ url: String, note: String) {
        if let a = active { a.openInNewTab(url, note: note) } else if !closing { BrowserWindowController.note(note); newWindow(url: url) }
    }
    @objc func share(_ s: Any?) { active?.share() }
    @objc func taskManager(_ s: Any?) { active?.chromeCommand("IDC_TASK_MANAGER", note: "taskManager") }
    @objc func copyDiagnostics(_ s: Any?) { BrowserWindowController.copyDiagnostics() }
    @objc func arrangeWindowsInFront(_ s: Any?) { NSApp.arrangeInFront(s) }
    @objc func toggleFullURL(_ s: Any?) { showFullURL.toggle(); controllers.forEach { $0.refresh() } }
    /// Automatic, Light and Dark by tag. Dark is the only captured theme; light uses the system's colors until it is captured.
    @objc func setAppearance(_ s: NSMenuItem) { NSApp.appearance = [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][s.tag] }

    /// The rule of the item's table row decides (MenuTable); items that are not table rows (AppKit's own) stay enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let rule = (item.representedObject as? MainMenu.Rule)?.entry else { return true }
        let ctx = MenuContext(app: self, window: active)
        if let state = rule.state { item.state = state(ctx) ? .on : .off }
        return rule.enabled(ctx)
    }

    /// Called by NCApplication.terminate (Cmd+Q).
    @objc func tryToTerminateApplication(_ sender: Any?) {
        beginShutdown()
    }

    // MARK: events from the window controllers

    func tabAdded(_ tab: NCTab) {
#if NOCHE_TESTHOOKS
        selfTest?.didAddTab(tab)
#endif
    }

    func tabActivated(_ tab: NCTab) {
#if NOCHE_TESTHOOKS
        selfTest?.didActivateTab(tab)
#endif
    }

    func tabClosed(_ tab: NCTab) {
        closeProgressed()
#if NOCHE_TESTHOOKS
        selfTest?.didCloseTab(tab)
#endif
    }

    func tabUpdated(_ tab: NCTab) {
        if !tab.title.isEmpty { title = tab.title }
        checkLoaded()
    }

    func tabLoaded(_ tab: NCTab, status: Int) {
        self.status = status
        if !tab.title.isEmpty { title = tab.title }
        checkLoaded()
#if NOCHE_TESTHOOKS
        selfTest?.didFinishLoad()
#endif
    }

    func tabLoadFailed(code: Int) {
#if NOCHE_TESTHOOKS
        selfTest?.didFailLoad()
#endif
        finish(.loadError(code: code))
    }

    func controllerClosed(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        if !closing { writer?.windowClosed(controller.id) }
        closeProgressed()
#if NOCHE_TESTHOOKS
        selfTest?.windowDidClose()
#endif
        if closing && controllers.isEmpty { exitNow() }
        // Otherwise the app keeps running with no window.
    }

    // MARK: smoke and shutdown

    private func checkLoaded() {
        if let status, let title { finish(.loadEnd(status: status, title: title)) }
    }

    private func finish(_ event: SmokeEvent, closeBrowser: Bool = true) {
        guard !finished, smoke != nil || event == .alreadyRunning else { return }
        print(event.line)
        fflush(stdout)
        exitCode = event.exitCode
        if closeBrowser { beginShutdown() } else { exit(exitCode) }
    }

#if NOCHE_TESTHOOKS
    func selfTestFinished(ok: Bool) {
        exitCode = ok ? 0 : 1
        beginShutdown()
    }
#endif

    /// Seconds without progress (a tab or a window closing) before the quit gives up and exits anyway, and the overall cap:
    /// a base plus a share per tab that was open when the quit started.
    private static let stallLimit: TimeInterval = 5
    private static let capBase: TimeInterval = 10, capPerTab: TimeInterval = 0.5

    private(set) var closing = false
    private var exiting = false
    private var watchdogFired = false
    private var watchdogGeneration = 0
    private var shutdownCap: TimeInterval = 0   // uptime at which the overall cap ends
    private var shutdownTabs = 0

    private func beginShutdown() {
        guard !closing else { return }
        closing = true
        finished = true
        writer?.quit()
        // A paused download survives the quit and resumes at the next launch (engine patch 0008); a running one would be canceled. The engine applies
        // the pause on its own turn and the shutdown below would end the process first, so the windows close once every pause landed (3 s at most).
        downloads.pauseAllForQuit(timeout: 3) { [self] in closeWindowsForQuit() }
    }

    private func closeWindowsForQuit() {
        shutdownTabs = windows.reduce(0) { $0 + $1.tabs.count }
        shutdownCap = ProcessInfo.processInfo.systemUptime + Self.capBase + Self.capPerTab * Double(shutdownTabs)
        armWatchdog()
#if NOCHE_TESTHOOKS
        // Test-only: never ask CEF to close, so the watchdog path above is the only way out.
        if ProcessInfo.processInfo.environment["NOCHE_TEST_SKIP_CLOSE"] == "1" { return }
#endif
        if windows.isEmpty { exitNow() } else { windows.forEach { $0.close() } }
    }

    /// (Re)starts the stall timer; the overall cap bounds it. A closing tab or window calls this again, so only a quit that
    /// stops making progress, or one that outlasts the cap, ends with the engine shut down under live browsers.
    private func armWatchdog() {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        let wait = min(Self.stallLimit, max(0, shutdownCap - ProcessInfo.processInfo.systemUptime))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.exiting, generation == self.watchdogGeneration else { return }
                let capped = ProcessInfo.processInfo.systemUptime >= self.shutdownCap
                let tabs = self.windows.reduce(0) { $0 + $1.tabs.count }
                FileHandle.standardError.write(Data("NOCHE shutdown watchdog: browser did not close (\(capped ? "overall cap reached" : "no progress for \(Int(Self.stallLimit)) s"), \(self.windows.count) windows and \(tabs) of \(self.shutdownTabs) tabs left)\n".utf8))
                self.watchdogFired = true
                self.exitNow()
            }
        }
    }

    private func closeProgressed() {
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_FIXED_WATCHDOG"] == "1" { return }  // negative control: the old fixed timer
#endif
        if closing && !exiting { armWatchdog() }
    }

    private func exitNow() {
        guard !exiting else { return }
        exiting = true
        // OnBeforeClose runs inside CEF teardown; shut down from a clean stack.
        DispatchQueue.main.async { [self] in
#if NOCHE_TESTHOOKS
            selfTest?.beforeExit(watchdogFired: watchdogFired)
            let code = exitCodeOverride ?? exitCode
#else
            let code = exitCode
#endif
            NCEngine.shutdown()
            exit(code)
        }
    }
}
