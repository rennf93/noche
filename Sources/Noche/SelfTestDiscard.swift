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
        guard await until(20, { win.tabs.count == 2 && c.list.items.count == 2 && c.list.items.first { $0.url == bURL }.map({ !$0.isLoading }) == true }) else { return finish(false, "tab B never loaded (\(c.list.items.count) items)") }
        guard let b = c.list.items.first(where: { $0.url == bURL }) else { return finish(false, "no row for B") }  // the list is newest first: found by address
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
        // Reset to Pinned Page on a discarded pinned tile: the pinned address loads in the same engine tab and the tab is no longer discarded.
        guard await discardNow(c, b.id) else { return finish(false, "the pinned B was not reported discarded before Reset") }
        c.resetToPinned(b.id)
        guard let bTab = c.engineTab(entry(c, b.id)!), await until(15, { self.entry(c, b.id)?.isDiscarded == false && bTab.url == bURL && !bTab.isLoading }) else {
            return finish(false, "Reset to Pinned Page on a discarded pinned tab left discarded \(String(describing: entry(c, b.id)?.isDiscarded)), url \(c.engineTab(entry(c, b.id)!)?.url ?? "nil")")
        }
        guard entry(c, b.id)?.engineID == engine, win.tabs.count == 2 else { return finish(false, "Reset on the discarded pinned tab changed the engine tab: \(String(describing: entry(c, b.id)?.engineID)) want \(engine), \(win.tabs.count) engine tabs") }
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
        guard await until(25, { win.tabs.count == 4 && c.list.items.count == 4 && c.list.items.contains { $0.url == idleURL } && c.list.items.contains { $0.url == audioURL } && c.list.items.contains { $0.url.hasPrefix("http://127.0.0.1:\(slow.port)/") } }) else { return finish(false, "the tabs did not arrive (\(c.list.items.map(\.url)))") }
        let idle = c.list.items.first { $0.url == idleURL }!, audio = c.list.items.first { $0.url == audioURL }!, loading = c.list.items.first { $0.url.hasPrefix("http://127.0.0.1:\(slow.port)/") }!  // the list is newest first: found by address
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

    /// `discard-hang`: a background page that never answers (a spinning main thread) must not hold the sweep: it returns within a few seconds,
    /// the spinning tab is not discarded (it cannot say whether it plays media), and the idle tab after it in the list (newest first) is. A second sweep
    /// started while one runs does nothing.
    func discardHang() async {
        guard await ready(), let c = ctl, let win else { return }
        let active = c.list.items[0]
        let spinURL = fixture("b.html").replacingOccurrences(of: "127.0.0.1", with: "localhost")  // another site, so another renderer process
        let idleURL = fixture("b.html")
        // The list is newest first: the idle tab opens first so that it comes after the spinning one in the list, as the sweep must still reach it.
        _ = win.addTab(withURL: idleURL, activate: false)
        guard await until(20, { win.tabs.count == 2 && c.list.items.count == 2 && c.list.items.first { $0.url == idleURL }.map({ !$0.isLoading }) == true }) else { return finish(false, "the idle tab did not load (\(c.list.items.map(\.url)))") }
        _ = win.addTab(withURL: spinURL, activate: false)
        guard await until(20, { win.tabs.count == 3 && c.list.items.count == 3 && c.list.items.first { $0.url == spinURL }.map({ !$0.isLoading }) == true }) else { return finish(false, "the spin tab did not load") }
        let spin = c.list.items.first { $0.url == spinURL }!, idle = c.list.items.first { $0.url == idleURL }!  // the list is newest first: found by address
        // 15 s of a busy main thread, so the page frees itself before the app quits.
        _ = await evaluate(c.engineTab(spin)!, "setTimeout(() => { const t = Date.now(); while (Date.now() - t < 15000) {} }, 0); 1")
        BrowserWindowController.discardCalls = []
        let box = SweepBox()
        let later = Date().addingTimeInterval(3 * 3600)
        Task { @MainActor in box.n = await c.discardIdleTabs(now: later); box.done = true }
        try? await Task.sleep(for: .milliseconds(300))
        let second = await c.discardIdleTabs(now: later)   // started while the first still waits on the spinning page: does nothing
        guard second == 0, !box.done else { return finish(false, "a second sweep started while one was running did not return at once (discarded \(second), the first is done \(box.done))") }
        guard await until(8, { box.done }) else { return finish(false, "the sweep did not return within 8 s with a page that never answers") }
        let tried = BrowserWindowController.discardCalls
        guard !tried.contains(spin.id), entry(c, spin.id)?.isDiscarded == false else { return finish(false, "the page that never answered was discarded") }
        guard box.n == 1, tried == [idle.id], await until(10, { self.entry(c, idle.id)?.isDiscarded == true }) else { return finish(false, "the idle tab after the spinning one was not discarded: \(box.n) discarded, attempts \(tried.count)") }
        guard entry(c, active.id)?.isDiscarded == false else { return finish(false, "the active tab was discarded") }
        finish(true, "a background page that never answers: the sweep returned in time, did not discard it, and discarded the idle tab after it")
    }

    /// `discard-media`: the media question sees a playing, unmuted element inside an open shadow root, in a same-origin frame and in a
    /// cross-origin (out-of-process) frame, and says no before it plays.
    func discardMedia() async {
        guard await ready(), let c = ctl, let win else { return }
        let cross = fixture("audio.html").replacingOccurrences(of: "127.0.0.1", with: "localhost")
        let cases: [(String, String, String, Bool)] = [
            ("an open shadow root", fixture("audio.html?shadow=1"), "document.getElementById('h').shadowRoot.getElementById('a').play().catch(e => 0); 1", false),
            ("a same-origin frame", fixture("media-host.html?src=audio.html"), "document.getElementById('f').contentDocument.getElementById('a').play().catch(e => 0); 1", false),
            ("a cross-origin frame", fixture("media-host.html?src=" + cross), "document.getElementById('a').play().catch(e => 0); 1", true),
        ]
        for (label, url, play, inChild) in cases {
            _ = win.addTab(withURL: url, activate: false)
            let n = c.list.items.count + 1
            guard await until(20, { win.tabs.count == n && c.list.items.count == n && c.list.items.first { $0.url == url }.map({ !$0.isLoading }) == true }) else { return finish(false, "\(label): the page did not load") }
            let item = c.list.items.first { $0.url == url }!, tab = c.engineTab(item)!  // the list is newest first: found by address
            try? await Task.sleep(for: .milliseconds(1500))  // the frame's own load
            guard await c.isPlayingMedia(tab) == false else { return finish(false, "\(label): reads as playing before anything plays") }
            if inChild {
                let ids: [String] = await withCheckedContinuation { k in tab.attachChildTargets(true, timeout: 5) { ids, _ in DispatchQueue.main.async { k.resume(returning: ids) } } }
                guard let sid = ids.first else { return finish(false, "\(label): the DevTools channel attached no child session") }
                let started: String? = await withCheckedContinuation { k in tab.evaluateJavaScript(play, sessionId: sid, userGesture: true, timeout: 5) { j, _ in DispatchQueue.main.async { k.resume(returning: j) } } }
                tab.attachChildTargets(false, timeout: 5) { _, _ in }
                guard started != nil else { return finish(false, "\(label): the frame's script did not run") }
            } else {
                guard await evaluate(tab, play) != nil else { return finish(false, "\(label): the page script did not run") }
            }
            var playing = false
            for _ in 0..<50 where !playing { playing = await c.isPlayingMedia(tab) == true; if !playing { try? await Task.sleep(for: .milliseconds(100)) } }
            guard playing else { return finish(false, "\(label): a playing unmuted element is not seen as playing") }
        }
        finish(true, "a playing unmuted element is seen in an open shadow root, a same-origin frame and a cross-origin frame, and not before it plays")
    }
}

final class SweepBox: @unchecked Sendable { var n = 0, done = false }
#endif
