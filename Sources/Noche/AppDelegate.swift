import AppKit
import CefBridge
import NocheCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let smoke = SmokeOptions.parse(CommandLine.arguments)
    private var window: NSWindow?
    private var browser: NCBrowserView?
    private var finished = false
    private var exitCode: Int32 = 0
    private var status: Int?
    private var title: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.noche.browser")
        if others.contains(where: { $0.processIdentifier != me }) {
            finish(.alreadyRunning, closeBrowser: false)
            return
        }

        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Noche/Cache")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try NCEngine.start(withCachePath: cache.path)
        } catch {
            FileHandle.standardError.write(Data("NOCHE engine start failed: \(error.localizedDescription)\n".utf8))
            exit(4)
        }

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let view = NCBrowserView(frame: frame, url: smoke?.url.absoluteString ?? "https://example.com")
        view.autoresizingMask = [.width, .height]
        view.onLoadEnd = { [weak self] code in MainActor.assumeIsolated { self?.status = code; self?.checkLoaded() } }
        view.onTitleChange = { [weak self] t in MainActor.assumeIsolated { self?.title = t; self?.checkLoaded() } }
        view.onLoadError = { [weak self] code in MainActor.assumeIsolated { self?.finish(.loadError(code: code)) } }
        view.onClosed = { [weak self] in MainActor.assumeIsolated { self?.browserClosed() } }
        browser = view

        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Noche"
        w.delegate = self
        w.contentView = view
        w.center()
        window = w
        if smoke == nil {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            // On screen so the page renders, but invisible, click-through and never key or active.
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.orderFrontRegardless()
        }

        if let smoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + smoke.timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(.timeout) }
            }
        }
    }

    /// Called by NCApplication.terminate (Cmd+Q).
    @objc func tryToTerminateApplication(_ sender: Any?) {
        beginShutdown()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The window may close only after CEF called DoClose (its performClose: re-send lands here again).
        if let browser, !browser.mayClose {
            beginShutdown()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Window closed without a browser to wait for, or by a CEF initiated close: make sure we exit.
        beginShutdown()
    }

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

    /// Seconds to wait for OnBeforeClose after CloseBrowser before exiting anyway.
    private static let shutdownWatchdog: TimeInterval = 5

    private var closing = false
    private func beginShutdown() {
        guard !closing else { return }
        closing = true
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownWatchdog) { [weak self] in
            MainActor.assumeIsolated {
                FileHandle.standardError.write(Data("NOCHE shutdown watchdog: browser did not close\n".utf8))
                self?.browserClosed()
            }
        }
#if NOCHE_TESTHOOKS
        // Test-only: never ask CEF to close, so the watchdog path above is the only way out.
        if ProcessInfo.processInfo.environment["NOCHE_TEST_SKIP_CLOSE"] == "1" { return }
#endif
        if let browser { browser.close() } else { browserClosed() }
    }

    private func browserClosed() {
        // OnBeforeClose runs inside CEF teardown; shut down from a clean stack.
        DispatchQueue.main.async { [exitCode] in
            NCEngine.shutdown()
            exit(exitCode)
        }
    }
}
