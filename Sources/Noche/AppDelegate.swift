import AppKit
import CefBridge
import NocheCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let smoke = SmokeOptions.parse(CommandLine.arguments)
#if NOCHE_TESTHOOKS
    private let selfTestOptions = SelfTest.parse(CommandLine.arguments)
    private var selfTest: SelfTest?
    /// Set by the self-test when its verdict is only known at exit.
    var exitCodeOverride: Int32?
#endif
    private(set) var controllers: [BrowserWindowController] = []
    var windows: [NCWindow] { controllers.map(\.window) }
    var searchTemplate = AddressInput.defaultSearchTemplate
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
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.noche.browser")
        if others.contains(where: { $0.processIdentifier != me }) {
            finish(.alreadyRunning, closeBrowser: false)
            return
        }

        var profile = "Library/Application Support/Noche"
        var url = smoke?.url.absoluteString ?? "about:blank"
        var frame = Self.defaultFrame(size: NSSize(width: 1280, height: 800))
#if NOCHE_TESTHOOKS
        if let options = selfTestOptions {
            profile = "Library/Application Support/Noche Test"  // never the dev profile
            url = options.url
            frame = SelfTest.windowFrame
            selfTest = SelfTest(options, app: self)
            searchTemplate = options.url + "search?q=%s"  // no self-test touches the network
        }
#endif
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(profile + "/Cache")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try NCEngine.start(withCachePath: cache.path)
        } catch {
            FileHandle.standardError.write(Data("NOCHE engine start failed: \(error.localizedDescription)\n".utf8))
            exit(4)
        }

        newWindow(url: url, frame: frame)

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
    func newWindow(url: String = "about:blank", frame: NSRect? = nil) -> NCWindow {
        let controller = BrowserWindowController(app: self, url: url, frame: frame ?? Self.defaultFrame(size: NSSize(width: 1280, height: 800)))
        controllers.append(controller)
        return controller.window
    }

    /// File > New Window: same size as the window it is opened from.
    func newWindowAction() {
        BrowserWindowController.note("newWindow")
        newWindow(frame: Self.defaultFrame(size: active?.nsWindow?.frame.size ?? NSSize(width: 1280, height: 800)))
    }

    /// AppKit frame of a window of |size| 100 pt from the top-left corner of the main screen's visible area (cut to fit).
    static func defaultFrame(size: NSSize) -> NSRect {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(size.width, area.width - 100), h = min(size.height, area.height - 100)
        return NSRect(x: area.minX + 100, y: area.maxY - 100 - h, width: w, height: h)
    }

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
    @objc func zoomActual(_ s: Any?) { active?.zoom(nil) }
    @objc func zoomIn(_ s: Any?) { active?.zoom(0.5) }
    @objc func zoomOut(_ s: Any?) { active?.zoom(-0.5) }
    @objc func developerTools(_ s: Any?) { active?.showDevTools() }
    @objc func goBack(_ s: Any?) { active?.goBack() }
    @objc func goForward(_ s: Any?) { active?.goForward() }
    @objc func nextTab(_ s: Any?) { active?.selectNextTab() }
    @objc func previousTab(_ s: Any?) { active?.selectPreviousTab() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar(_:)): item.state = active?.sidebarHidden == true ? .on : .off
        case #selector(goBack(_:)): return active?.window.activeTab?.canGoBack ?? false
        case #selector(goForward(_:)): return active?.window.activeTab?.canGoForward ?? false
        default: break
        }
        return true
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

    private var closing = false
    private var exiting = false
    private var watchdogFired = false
    private var watchdogGeneration = 0
    private var shutdownCap: TimeInterval = 0   // uptime at which the overall cap ends
    private var shutdownTabs = 0

    private func beginShutdown() {
        guard !closing else { return }
        closing = true
        finished = true
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
