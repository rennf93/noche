import AppKit
import CefBridge
import NocheCore

/// Discarding (M1.6 Task 3b): a background tab unused for `discardAfterMinutes` gives its page back to the engine and keeps its engine tab,
/// its |TabItem| and its place; a click reloads it in the same engine tab (|activate| finds the engine tab, so it never takes the dormant path).
extension BrowserWindowController {
    /// How often the window looks for tabs to discard (B: README builder calls).
    static let discardSweepInterval: TimeInterval = 60

    /// How long the page may take to answer a media question (B: README builder calls); a page that cannot say is not discarded.
    static let mediaQueryTimeout: TimeInterval = 3

    /// The setting's value in seconds (default 120 minutes; a stored value outside the key's range is the default).
    var discardAfter: TimeInterval {
        let stored = (try? app.writer?.store.setting("discardAfterMinutes")).flatMap { $0 }
        return TimeInterval(SettingKeys.discardAfterMinutes(stored: stored)) * 60
    }

    private func evalBounded(_ tab: NCTab, _ js: String, session: String? = nil) async -> String? {
        await withCheckedContinuation { c in
            // userGesture false: asking must never count as the user's activation of the page.
            tab.evaluateJavaScript(js, sessionId: session, userGesture: false, timeout: Self.mediaQueryTimeout) { json, _ in DispatchQueue.main.async { c.resume(returning: json) } }
        }
    }

    /// Whether an audio or video element of the page is playing and not muted (CDP, through the DevTools channel): the top document, open
    /// shadow roots and same-origin frames are walked by the page script; out-of-process (cross-origin) frames are asked through their own
    /// flat sessions. A page sounding only through Web Audio is not seen (README known limit). Nil when the page, or one of its frames, could
    /// not answer within |mediaQueryTimeout|. T7.2's archiving asks the same question.
    func isPlayingMedia(_ tab: NCTab) async -> Bool? {
        // The hooks (negative controls) switch off the shadow root walk, the same-origin frame walk, or the cross-origin sessions.
        let shadow = BarHook.on("DISCARD_NOSHADOW") ? "false" : "true", same = BarHook.on("DISCARD_NOSAME") ? "false" : "true"
        let scan = "(() => { let blocked = false; const walk = (root) => { for (const m of root.querySelectorAll('audio,video')) if (!m.paused && !m.ended && !m.muted && m.volume > 0) return true; for (const el of root.querySelectorAll('*')) { if (\(shadow) && el.shadowRoot && walk(el.shadowRoot)) return true; if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { let d = null; try { d = \(same) ? el.contentDocument : null } catch (e) {} if (!d) blocked = true; else if (walk(d)) return true; } } return false; }; return walk(document) ? 'playing' : blocked ? 'frames' : 'none'; })()"
        guard let top = await evalBounded(tab, scan) else { return nil }
        if top == "\"playing\"" { return true }
        if top == "\"none\"" { return false }
        guard top == "\"frames\"" else { return nil }
        if BarHook.on("DISCARD_NOATTACH") { return false }
        let sessions: [String] = await withCheckedContinuation { c in
            tab.attachChildTargets(true, timeout: Self.mediaQueryTimeout) { ids, _ in DispatchQueue.main.async { c.resume(returning: ids) } }
        }
        var result: Bool? = false
        for id in sessions {
            let r = await evalBounded(tab, scan, session: id)
            if r == "\"playing\"" { result = true; break }
            if r == nil { result = nil }
        }
        tab.attachChildTargets(false, timeout: Self.mediaQueryTimeout) { _, _ in }
        return result
    }

    /// Discards every background tab idle for |discardAfter| at |now|, never the active tab, one still loading, a closing one, or one playing
    /// media (or one that cannot say). Returns how many were discarded. |now| is the clock seam of the checks.
    @discardableResult
    func discardIdleTabs(now: Date = Date()) async -> Int {
        guard !sweeping || BarHook.on("DISCARD_NOGUARD") else { return 0 }  // a tick that finds the last sweep still asking does nothing
        sweeping = true
        defer { sweeping = false }
        var done = 0
        let after = discardAfter
        for t in list.items {
            guard discardable(t), now.timeIntervalSince(max(t.lastActiveAt, leftAt[t.id] ?? .distantPast)) >= after, let tab = engineTab(t) else { continue }
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
