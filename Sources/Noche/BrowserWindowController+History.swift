import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Visit recording: an http or https main-frame load that ends with status 200 to 399 is a visit; the title follows later updates.
extension BrowserWindowController {
    func isWeb(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func recordVisit(_ tab: NCTab, status: Int) {
        flushTitle(tab.identifier)  // a navigation ended: the title held for the page before it goes to that page
        let typed = typedLoads.removeValue(forKey: tab.identifier) != nil
        guard (200..<400).contains(status), isWeb(tab.url), let store = app.writer?.store else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_RECORD"] == "1" { return }  // negative control: nothing is recorded
#endif
        do { try store.recordVisit(url: tab.url, title: tab.title, typed: typed, at: Date()) } catch {
            FileHandle.standardError.write(Data("NOCHE store record visit failed: \(error)\n".utf8))
        }
        recordedTitle[tab.identifier] = "\(tab.url)\n\(tab.title)"
    }

#if NOCHE_TESTHOOKS
    static var titleWrites = 0
#endif
    /// Minimum seconds between title writes of one tab (ruling M38).
    static let titleInterval: TimeInterval = 2

    /// The page's title often arrives after its load ends; each (address, title) pair is written once, and a tab writes at most once per `titleInterval`:
    /// a title that changes sooner is held with its address (the newest replaces it) and written when the interval ends. The held pair is also written
    /// when the tab navigates, closes, or the app quits, and a write never reads the tab: it cannot put a title on another page's address.
    func recordTitle(_ tab: NCTab) {
        if let held = titleThrottle.peek(tab.identifier), held.url != tab.url { flushTitle(tab.identifier) }  // the tab navigated: the old page's last title is the old page's
        guard !tab.title.isEmpty, isWeb(tab.url), recordedTitle[tab.identifier] != "\(tab.url)\n\(tab.title)" else { return }
        recordedTitle[tab.identifier] = "\(tab.url)\n\(tab.title)"
        let id = tab.identifier
        switch titleThrottle.offer(id, url: tab.url, title: tab.title, now: Date()) {
        case .writeNow: writeTitle(url: tab.url, title: tab.title)
        case .pending: break
        case .later(let at):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow)) { [weak self] in
                MainActor.assumeIsolated { self?.flushTitle(id, onlyIfDue: true) }
            }
        }
    }

    /// Writes the pair held for the tab (the timer passes |onlyIfDue|: a timer that an earlier flush made stale writes nothing).
    func flushTitle(_ id: Int, onlyIfDue: Bool = false) {
#if NOCHE_TESTHOOKS
        if !onlyIfDue && BarHook.on("NO_TITLE_FLUSH") { return }  // negative control: a navigation or a close drops the held title
#endif
        if let p = titleThrottle.take(id, now: Date(), onlyIfDue: onlyIfDue) { writeTitle(url: p.url, title: p.title) }
    }

    /// The quit: every held title of this window is written.
    func flushTitles() {
        for e in titleThrottle.drain(now: Date()) { writeTitle(url: e.pending.url, title: e.pending.title) }
    }

    private func writeTitle(url: String, title: String) {
        guard !title.isEmpty, isWeb(url), let store = app.writer?.store else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_RECORD"] == "1" { return }
        Self.titleWrites += 1
#endif
        do { try store.updateTitle(url: url, title: title) } catch {
            FileHandle.standardError.write(Data("NOCHE store update title failed: \(error)\n".utf8))
        }
    }
}
