#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore

/// Discarding (M1.6 Task 3b): the engine gives a background tab's page back and the app keeps the tab.
extension SelfTest {
    func rowView(_ c: BrowserWindowController, _ id: TabID) -> TabRowView? { c.sidebar.rows.first { $0.tabID == id } }

    /// Discards |id|'s page the way the engine would (memory pressure takes the same callback) and waits for the app to show it.
    func discardNow(_ c: BrowserWindowController, _ id: TabID) async -> Bool {
        guard let t = entry(c, id), let tab = c.engineTab(t), tab.discard() else { return false }
        return await until(10, { self.entry(c, id)?.isDiscarded == true })
    }

    /// `discard-click`: a discarded tab keeps its engine tab and list item, draws at alpha 0.45 (row and pinned tile), and a click reloads it
    /// in the same engine tab: same engine id, the right URL, the engine tab count unchanged.
    func discardClick() async {
        guard await ready(), let c = ctl, let win else { return }
        let a = c.list.items[0]
        let bURL = fixture("b.html")
        _ = win.addTab(withURL: bURL, activate: false)
        guard await until(20, { win.tabs.count == 2 && c.list.items.count == 2 && c.list.items[1].url == bURL && !c.list.items[1].isLoading }) else { return finish(false, "tab B never loaded (\(c.list.items.count) items)") }
        let b = c.list.items[1]
        guard c.list.activeID == a.id, let engine = b.engineID else { return finish(false, "tab A is not the selection or B has no engine id") }
        for (label, pinB) in [("row", false), ("tile", true)] {
            if pinB {
                guard await select(c, b.id) else { return finish(false, "B did not activate") }
                pinKey()
                guard await pinned(c, b.id, true), await select(c, a.id) else { return finish(false, "could not pin B") }
            }
            guard await discardNow(c, b.id) else { return finish(false, "the \(label): B was not reported discarded (\(String(describing: entry(c, b.id))))") }
            guard entry(c, b.id)?.engineID == engine, win.tabs.count == 2, c.list.items.count == 2 else { return finish(false, "the \(label): a discard changed the tabs: engine \(String(describing: entry(c, b.id)?.engineID)) want \(engine), \(win.tabs.count) engine tabs, \(c.list.items.count) items") }
            let view: NSView? = pinB ? tile(0) : rowView(c, b.id)
            let dim: () -> CGFloat = { pinB ? (self.tile(0)?.faviconView.alphaValue ?? -1) : (self.rowView(c, b.id)?.alphaValue ?? -1) }
            guard await until(5, { dim() == ChromeStyle.dormantAlpha }) else { return finish(false, "the discarded \(label) draws at alpha \(dim()), want \(ChromeStyle.dormantAlpha)") }
            guard let v = view, click(v) else { return finish(false, "could not click the discarded \(label)") }
            guard await until(15, { c.list.activeID == b.id && self.entry(c, b.id)?.isDiscarded == false }) else { return finish(false, "a click on the discarded \(label) left active \(c.list.activeID == b.id), discarded \(String(describing: entry(c, b.id)?.isDiscarded))") }
            guard let now = entry(c, b.id), now.engineID == engine, win.tabs.count == 2, c.list.items.count == 2 else {
                return finish(false, "the \(label): the click gave engine \(String(describing: entry(c, b.id)?.engineID)) (was \(engine)), \(win.tabs.count) engine tabs, \(c.list.items.count) items, want the same engine id, 2 and 2")
            }
            guard let tab = c.engineTab(now), await until(15, { tab.url == bURL && !tab.isLoading }), await evaluate(tab, "document.title") == "\"B Page\"" else { return finish(false, "the \(label): the reloaded tab is at \(c.engineTab(now)?.url ?? "nil"), want \(bURL) with its page back") }
            guard await until(5, { dim() == 1 }) else { return finish(false, "the \(label) stayed dim after the click (alpha \(dim()))") }
            guard await select(c, a.id) else { return finish(false, "A did not activate again") }
        }
        finish(true, "a discarded tab keeps engine id \(engine), draws at alpha 0.45 as a row and as a pinned tile, and a click reloads it in place at \(bURL) with 2 engine tabs and 2 items")
    }

    /// `discard-policy`: with every tab idle for 3 hours (the clock seam), the sweep discards the idle background tab and never the active
    /// tab, one still loading, or one playing unmuted media. The sweep's attempts are read, not the engine's refusal.
    func discardPolicy() async {
        guard await ready(), let c = ctl, let win else { return }
        guard let slow = await startSlowServer(size: 40_000_000, contentType: "text/html") else { return finish(false, "the slow server did not start") }
        defer { slow.stop() }
        let active = c.list.items[0]
        let idleURL = fixture("b.html"), audioURL = fixture("audio.html")
        let loadingURL = "http://127.0.0.1:\(slow.port)/slow.html"
        for u in [idleURL, audioURL, loadingURL] { _ = win.addTab(withURL: u, activate: false) }
        guard await until(25, { win.tabs.count == 4 && c.list.items.count == 4 && c.list.items[1].url == idleURL && c.list.items[2].url == audioURL && c.list.items[3].url.hasPrefix("http://127.0.0.1:\(slow.port)/") }) else { return finish(false, "the tabs did not arrive (\(c.list.items.map(\.url)))") }
        let idle = c.list.items[1], audio = c.list.items[2], loading = c.list.items[3]
        guard c.list.activeID == active.id else { return finish(false, "the first tab is not the selection") }
        guard await until(10, { self.entry(c, loading.id)?.isLoading == true }) else { return finish(false, "the slow page tab never reports loading") }
        let tabAudio = c.engineTab(audio)!
        guard await until(10, { self.entry(c, audio.id)?.title == "Audio Page" }) else { return finish(false, "the audio page never loaded") }
        _ = await evaluate(tabAudio, "document.getElementById('a').play().catch(e => { window.__playErr = String(e) }); 1")
        var playing = false
        for _ in 0..<100 where !playing { playing = await c.isPlayingMedia(tabAudio) == true; if !playing { try? await Task.sleep(for: .milliseconds(100)) } }
        guard playing else { return finish(false, "an unmuted playing audio element is not seen as playing (play error \(await evaluate(tabAudio, "String(window.__playErr)") ?? "nil"))") }
        _ = await evaluate(tabAudio, "document.getElementById('a').muted = true; 1")
        guard await c.isPlayingMedia(tabAudio) == false else { return finish(false, "a muted audio element is seen as playing") }
        _ = await evaluate(tabAudio, "document.getElementById('a').muted = false; 1")
        guard await c.isPlayingMedia(c.engineTab(idle)!) == false else { return finish(false, "a page with no media is seen as playing") }
        // Not idle yet: nothing is discarded now.
        BrowserWindowController.discardCalls = []
        guard await c.discardIdleTabs(now: Date()) == 0, BrowserWindowController.discardCalls.isEmpty else { return finish(false, "tabs used a moment ago were discarded (\(BrowserWindowController.discardCalls.count) attempts)") }
        guard entry(c, loading.id)?.isLoading == true else { return finish(false, "the slow page tab stopped loading before the sweep (url \(entry(c, loading.id)?.url ?? "nil"), title \(entry(c, loading.id)?.title ?? "nil"), tab loading \(c.engineTab(loading)?.isLoading ?? false), state \(await evaluate(c.engineTab(loading)!, "document.readyState") ?? "nil"))") }
        let later = Date().addingTimeInterval(3 * 3600)
        let n = await c.discardIdleTabs(now: later)
        let tried = BrowserWindowController.discardCalls
        guard !tried.contains(active.id) else { return finish(false, "the active tab was offered to the engine to discard") }
        guard !tried.contains(loading.id), entry(c, loading.id)?.isDiscarded == false else { return finish(false, "the loading tab was offered to the engine to discard") }
        guard !tried.contains(audio.id), entry(c, audio.id)?.isDiscarded == false else { return finish(false, "the tab playing unmuted audio was offered to the engine to discard") }
        guard n == 1, tried == [idle.id], await until(10, { self.entry(c, idle.id)?.isDiscarded == true }) else { return finish(false, "the idle background tab was not the one discard: \(n) discarded, attempts \(tried.count), discarded \(String(describing: entry(c, idle.id)?.isDiscarded))") }
        guard entry(c, active.id)?.isDiscarded == false, win.tabs.count == 4 else { return finish(false, "the active tab or the tab count changed (\(win.tabs.count) engine tabs)") }
        finish(true, "3 hours idle: the idle tab is discarded; the active tab, the loading tab and the tab playing unmuted audio are never offered; a muted element and a page with no media read as not playing")
    }
}
#endif
