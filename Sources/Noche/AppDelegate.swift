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
        var frame = NSRect(x: 100, y: 100, width: 1280, height: 800)
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
    func newWindow(url: String = "about:blank", frame: NSRect = NSRect(x: 100, y: 100, width: 1280, height: 800)) -> NCWindow {
        let controller = BrowserWindowController(app: self, url: url, frame: frame)
        controllers.append(controller)
        return controller.window
    }

    /// File > New Window: same size as the window it is opened from.
    func newWindowAction() {
        BrowserWindowController.note("newWindow")
        let frame = active.flatMap { $0.nsWindow?.frame.size }.map { NSRect(origin: NSPoint(x: 100, y: 100), size: $0) }
        newWindow(frame: frame ?? NSRect(x: 100, y: 100, width: 1280, height: 800))
    }

    /// The window menu actions apply to: the key window's, else the newest (hidden windows are never key).
    var active: BrowserWindowController? { controllers.first { $0.nsWindow?.isKeyWindow == true } ?? controllers.last }

    // MARK: menu actions

    @objc func newTab(_ s: Any?) { active?.newTab() }
    @objc func newWindowMenu(_ s: Any?) { newWindowAction() }
    @objc func openCommandBar(_ s: Any?) { active?.focusAddress() }
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
    // Edit actions go to the active window's first responder (the address field's editor or the page), key window or not.
    @objc func undo(_ s: Any?) { forwardEdit(Selector(("undo:"))) }
    @objc func redo(_ s: Any?) { forwardEdit(Selector(("redo:"))) }
    @objc func cut(_ s: Any?) { forwardEdit(#selector(NSText.cut(_:))) }
    @objc func copy(_ s: Any?) { forwardEdit(#selector(NSText.copy(_:))) }
    @objc func paste(_ s: Any?) { forwardEdit(#selector(NSText.paste(_:))) }
    @objc func selectAll(_ s: Any?) { forwardEdit(#selector(NSText.selectAll(_:))) }
    private func forwardEdit(_ action: Selector) { _ = active?.nsWindow?.firstResponder?.tryToPerform(action, with: nil) }
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

    func tabAdded() {
#if NOCHE_TESTHOOKS
        selfTest?.didAddTab()
#endif
    }

    func tabClosed() {
#if NOCHE_TESTHOOKS
        selfTest?.didCloseTab()
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

    /// Seconds to wait for every window to close after the shutdown request before exiting anyway.
    private static let shutdownWatchdog: TimeInterval = 5

    private var closing = false
    private var exiting = false
    private var watchdogFired = false
    private func beginShutdown() {
        guard !closing else { return }
        closing = true
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownWatchdog) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.exiting else { return }
                FileHandle.standardError.write(Data("NOCHE shutdown watchdog: browser did not close\n".utf8))
                self.watchdogFired = true
                self.exitNow()
            }
        }
#if NOCHE_TESTHOOKS
        // Test-only: never ask CEF to close, so the watchdog path above is the only way out.
        if ProcessInfo.processInfo.environment["NOCHE_TEST_SKIP_CLOSE"] == "1" { return }
#endif
        if windows.isEmpty { exitNow() } else { windows.forEach { $0.close() } }
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
