import AppKit
import CefBridge
import NocheCore

/// Discarding (M1.6 Task 3b): a background tab unused for `discardAfterMinutes` gives its page back to the engine and keeps its engine tab,
/// its |TabItem| and its place; a click reloads it in the same engine tab (|activate| finds the engine tab, so it never takes the dormant path).
extension BrowserWindowController {
    /// How often the window looks for tabs to discard (B: README builder calls).
    static let discardSweepInterval: TimeInterval = 60

    /// The setting's value in seconds (default 120 minutes).
    var discardAfter: TimeInterval {
        let minutes = (try? app.writer?.store.setting("discardAfterMinutes")).flatMap { $0 }.flatMap { Int($0) } ?? Int(SettingKeys.key("discardAfterMinutes")!.defaultValue)!
        return TimeInterval(minutes) * 60
    }

    /// Whether an audio or video element of the page is playing and not muted (CDP, through the DevTools channel). A page sounding only through
    /// Web Audio is not seen (README known limit). Nil when the page could not answer. T7.2's archiving asks the same question.
    func isPlayingMedia(_ tab: NCTab) async -> Bool? {
        let js = "[...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0)"
        let json: String? = await withCheckedContinuation { c in
            tab.evaluateJavaScript(js) { json, _ in DispatchQueue.main.async { c.resume(returning: json) } }
        }
        return json.map { $0 == "true" }
    }

    /// Discards every background tab idle for |discardAfter| at |now|, never the active tab, one still loading, a closing one, or one playing
    /// media (or one that cannot say). Returns how many were discarded. |now| is the clock seam of the checks.
    @discardableResult
    func discardIdleTabs(now: Date = Date()) async -> Int {
        var done = 0
        for t in list.items {
            guard discardable(t), now.timeIntervalSince(max(t.lastActiveAt, leftAt[t.id] ?? .distantPast)) >= discardAfter, let tab = engineTab(t) else { continue }
            if !BarHook.on("DISCARD_MEDIA"), await isPlayingMedia(tab) != false { continue }
            // The tab may have been selected or started loading while the page answered.
            guard let cur = item(withID: t.id), discardable(cur), engineTab(cur) === tab else { continue }
            if discard(tab, id: t.id) { done += 1 }
        }
        return done
    }

    /// Whether |t|'s state allows a discard (idle time and media come separately).
    func discardable(_ t: TabItem) -> Bool {
        guard let tab = engineTab(t), !t.isDiscarded, !isClosing(tab) else { return false }
        if (t.id == list.activeID || tab === window.activeTab || tab === intendedActive) && !BarHook.on("DISCARD_ACTIVE") { return false }
        if (t.isLoading || tab.isLoading) && !BarHook.on("DISCARD_LOADING") { return false }
        return true
    }

    /// Asks the engine to discard |tab|. The engine's callback sets |isDiscarded| (the same path as its own memory-pressure discards).
    func discard(_ tab: NCTab, id: TabID) -> Bool {
#if NOCHE_TESTHOOKS
        Self.discardCalls.append(id)
#endif
        return tab.discard()
    }

    func startDiscardTimer() {
        discardTimer = Timer.scheduledTimer(withTimeInterval: Self.discardSweepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.discardIdleTabs() }
        }
    }
}
