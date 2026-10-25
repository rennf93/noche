#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// History recording (M1.3): an http load is a page row, a typed load counts as typed, a non-http load is never stored.
extension SelfTest {
    func page(_ store: Store, host: String, path: String) -> PageCandidate? {
        ((try? store.pageCandidates(prefix: host)) ?? []).first { $0.url.hasSuffix(path) }
    }

    func historyRecord() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let store = app.writer?.store,
              let port = URL(string: url)?.port else { return }
        let host = "127.0.0.1:\(port)"
        // The startup load: a link visit with the page's own title (the title arrives with a later update).
        guard await until(10, { page(store, host: host, path: "/")?.title == "Noche App Fixture" }), let first = page(store, host: host, path: "/") else {
            return finish(false, "the startup fixture load is not a page row with its title: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        // Loads that must never be stored: about, data and a file (the status of the last two is not the point, the scheme is).
        for target in ["about:blank", "data:text/html,<title>d</title>hi", "file:///etc/hosts"] {
            let before = loads
            tab.loadURL(target)
            _ = await until(8, { loads > before })
        }
        try? await Task.sleep(for: .milliseconds(500))
        let others = ["about", "data", "file"].flatMap { (try? store.pageCandidates(prefix: $0)) ?? [] }
        guard others.isEmpty else { return finish(false, "non-http loads were stored: \(others.map(\.url))") }
        // A typed load through the address entry counts as typed; a link load does not.
        let before = loads
        guard await submitAddress("\(host)/b.html") else { return finish(false, "the address entry did not take the text") }
        guard await until(15, { loads > before && page(store, host: host, path: "/b.html")?.title == "B Page" }), let b = page(store, host: host, path: "/b.html") else {
            return finish(false, "typed b.html is not a page row with its title: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        // An aborted typed load must not leave its mark: the next link visit records typed=false. The abort is delivered the way the bridge does.
        guard let tab2 = win.activeTab else { return finish(false, "no tab") }
        let abortedURL = "http://\(host)/b.html?abort=1"
        ctl.typedLoads[tab2.identifier] = abortedURL
        ctl.window(win, tab: tab2, didFailLoadWithCode: -3, url: abortedURL)
        let linkBefore = loads
        tab2.loadURL("http://\(host)/b.html?link=1")
        guard await until(15, { loads > linkBefore && page(store, host: host, path: "?link=1") != nil }), let link = page(store, host: host, path: "?link=1") else {
            return finish(false, "the link visit after the aborted typed load is not a page row: \((try? store.pageCandidates(prefix: host)) ?? [])")
        }
        guard link.typedCount == 0 else { return finish(false, "an aborted typed load left its mark: the next link visit was recorded as typed (typedCount \(link.typedCount))") }
        finish(first.visitCount == 1 && first.typedCount == 0 && b.visitCount == 1 && b.typedCount == 1 && violations.isEmpty,
               "an aborted typed load leaves no mark (the next link visit is typed=false); http loads recorded (startup page visits=\(first.visitCount) typed=\(first.typedCount), typed b.html visits=\(b.visitCount) typed=\(b.typedCount)), about, data and file loads never stored \(violations)")
        _ = ctl
    }
}
#endif
