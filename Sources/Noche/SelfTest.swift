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

    static let windowFrame = NSRect(x: 0, y: 0, width: 2368, height: 1436)

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
    private var added = 0, closedTabs = 0, windowsClosed = 0, loads = 0
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
            default: finish(false, "unknown check")
            }
        }
    }

    private func sample() {
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
        // CDP path every later check relies on.
        let title = await evaluate(tab, "document.title")
        try? await Task.sleep(for: .seconds(2))
        sample()
        let ok = app.windows.count == 1 && win.tabs.count == 1 && ns.alphaValue == 0 && !ns.isKeyWindow && !NSApp.isActive
            && violations.isEmpty && title == "\"Noche App Fixture\""
        finish(ok, "windows=\(app.windows.count) tabs=\(win.tabs.count) alpha=\(ns.alphaValue) key=\(ns.isKeyWindow) active=\(NSApp.isActive) title=\(title ?? "nil") violations=\(violations)")
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
            tab.evaluateJavaScript(js) { json, _ in c.resume(returning: json) }
        }
    }

    private func line(_ kind: String, _ detail: String) {
        print("NOCHE_TEST \(check) \(kind) \(detail)")
        fflush(stdout)
    }

    private func finish(_ ok: Bool, _ detail: String) {
        guard !verdictPrinted else { return }
        verdictPrinted = true
        line(ok ? "pass" : "fail", detail)
        app.selfTestFinished(ok: ok)
    }
}
#endif
