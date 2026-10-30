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

    /// One DevTools call bounded by |mediaQueryTimeout|: the whole `result` object, or the error ("timed out" on a timeout).
    private func cdp(_ tab: NCTab, _ method: String, _ params: [String: Any] = [:], session: String? = nil) async -> (result: [String: Any]?, error: String?) {
        let text = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let (json, error): (String?, String?) = await withCheckedContinuation { c in
            tab.callDevToolsMethod(method, paramsJSON: text, sessionId: session, timeout: Self.mediaQueryTimeout) { json, error in DispatchQueue.main.async { c.resume(returning: (json, error)) } }
        }
        let obj = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if let error, session != nil, error.contains("not found") { logStaleSession(tab, session!) }
        return (obj, error)
    }

    /// A child session id the engine no longer knows is said once per tab and id, not on every later question.
    private func logStaleSession(_ tab: NCTab, _ id: String) {
        let key = "\(ObjectIdentifier(tab).hashValue)/\(id)"
        guard staleSessionsLogged.insert(key).inserted else { return }
        FileHandle.standardError.write(Data("NOCHE media question: tab \(tab.url) has no child session \(id) any more (not asked again)\n".utf8))
    }

    /// The page script's answer ("playing", "none" or "frames") in the top frame of |session| (nil: the tab's page), or in the isolated world
    /// |context| of one of its frames. userGesture false: asking must never count as the user's activation of the page.
    private func scan(_ tab: NCTab, _ js: String, session: String? = nil, context: Int? = nil) async -> String? {
        var params: [String: Any] = ["expression": js, "returnByValue": true, "awaitPromise": true, "userGesture": false]
        if let context { params["contextId"] = context }
        let r = await cdp(tab, "Runtime.evaluate", params, session: session)
        guard r.result?["exceptionDetails"] == nil, let v = (r.result?["result"] as? [String: Any])?["value"] as? String, ["playing", "none", "frames"].contains(v) else { return nil }
        return v
    }

    /// Whether an audio or video element of the page is playing and not muted (CDP, through the DevTools channel): the top document, open
    /// shadow roots and same-origin frames are walked by the page script; every other frame is asked through its own execution context
    /// (|Page.getFrameTree|, |Page.createIsolatedWorld|, |Runtime.evaluate| with |contextId|) on the session that owns it: the top session for a
    /// same-process frame, a child session (auto attached, nested ones too) for an out-of-process one. Whatever was attached is detached before
    /// this returns. A page sounding only through Web Audio is not seen (README known limit). Nil when a frame of the page did not answer
    /// within |mediaQueryTimeout| or the sessions could not be detached. T7.2's archiving asks the same question.
    func isPlayingMedia(_ tab: NCTab) async -> Bool? {
        // The hooks (negative controls) switch off the shadow root walk, the same-origin frame walk, or the frame walks below.
        let shadow = BarHook.on("DISCARD_NOSHADOW") ? "false" : "true", same = BarHook.on("DISCARD_NOSAME") ? "false" : "true"
        let js = "(() => { let blocked = false; const walk = (root) => { for (const m of root.querySelectorAll('audio,video')) if (!m.paused && !m.ended && !m.muted && m.volume > 0) return true; for (const el of root.querySelectorAll('*')) { if (\(shadow) && el.shadowRoot && walk(el.shadowRoot)) return true; if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { let d = null; try { d = \(same) ? el.contentDocument : null } catch (e) {} if (!d) blocked = true; else if (walk(d)) return true; } } return false; }; return walk(document) ? 'playing' : blocked ? 'frames' : 'none'; })()"
        guard let top = await scan(tab, js) else { return nil }
        if top == "playing" { return true }
        if top == "none" { return false }
        if BarHook.on("DISCARD_NOATTACH") { return false }
        var attached: [String] = []
        let answer = await askFrames(tab, js, attached: &attached)
        // The detach is awaited: discard() must not reach the engine with sessions still attached (T7.11).
        let detached = await detachChildTargets(tab, attached)
        return answer == false && !detached ? nil : answer
    }

    /// The answer of every frame the top session's page has, through the sessions that own them: true when one plays, false when all answered
    /// and none plays, nil when a frame in a frame tree got no answer.
    private func askFrames(_ tab: NCTab, _ js: String, attached known: inout [String]) async -> Bool? {
        let topIDs: [String] = await withCheckedContinuation { c in
            tab.attachChildTargets(true, timeout: Self.mediaQueryTimeout) { ids, _ in DispatchQueue.main.async { c.resume(returning: ids) } }
        }
        known = topIDs
        var next = 0, timedOut = false
        // A child session auto attaches its own out-of-process frames (a cross-origin frame nested in a cross-origin frame).
        while next < known.count && !timedOut && !BarHook.on("DISCARD_NONESTED") {
            let sid = known[next]
            next += 1
            timedOut = await cdp(tab, "Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], session: sid).error == "timed out"
            for id in tab.childSessionIds where !known.contains(id) { known.append(id) }
        }
        var all = Set<String>(), answered = Set<String>()
        let walkTrees = !BarHook.on("DISCARD_NOTREE") && !BarHook.on("DISCARD_NOSAME")
        if timedOut { return BarHook.on("DISCARD_UNASKEDNONE") ? false : nil }  // a session that could not even attach its own frames: unknown
        sessions: for sid in [nil] + known.map({ Optional($0) }) {
            if sid == nil && !walkTrees { continue }
            if let sid, BarHook.on("DISCARD_CHILDFRAMESNONE") {  // the old behavior: a child's own "frames" answer counted as none
                if await scan(tab, js, session: sid) == "playing" { return true }
                continue
            }
            let tree = await cdp(tab, "Page.getFrameTree", session: sid)
            if tree.error == "timed out" { timedOut = true; break }
            guard let root = (tree.result?["frameTree"] as? [String: Any]) else { continue }
            var frames: [(id: String, isRoot: Bool)] = []
            func flatten(_ node: [String: Any], _ isRoot: Bool) {
                if let id = (node["frame"] as? [String: Any])?["id"] as? String { frames.append((id, isRoot)) }
                for child in node["childFrames"] as? [[String: Any]] ?? [] { flatten(child, false) }
            }
            flatten(root, true)
            for f in frames {
                all.insert(f.id)
                var verdict: String?
                if f.isRoot {
                    verdict = sid == nil ? "none" : await scan(tab, js, session: sid)  // the top frame was answered before
                } else {
                    let world = await cdp(tab, "Page.createIsolatedWorld", ["frameId": f.id, "worldName": "noche-media"], session: sid)
                    if world.error == "timed out" { timedOut = true; break sessions }
                    // No world: the frame is not this session's (an out-of-process frame is answered by its own session).
                    guard let ctx = world.result?["executionContextId"] as? Int else { continue }
                    verdict = await scan(tab, js, session: sid, context: ctx)
                }
                if verdict == "playing" { return true }
                if verdict != nil { answered.insert(f.id) }
            }
        }
        if BarHook.on("DISCARD_UNASKEDNONE") { return false }  // the old behavior: a frame nobody asked counts as not playing
        return !timedOut && all.isSubset(of: answered) ? false : nil
    }

    /// Detaches every child session this question attached, nested ones first, and says whether none is left.
    private func detachChildTargets(_ tab: NCTab, _ attached: [String]) async -> Bool {
        if BarHook.on("DISCARD_NODETACHWAIT") {  // the old behavior: posted, not awaited
            tab.attachChildTargets(false, timeout: Self.mediaQueryTimeout) { _, _ in }
            return true
        }
        for sid in attached.reversed() where tab.childSessionIds.contains(sid) {
            _ = await cdp(tab, "Target.setAutoAttach", ["autoAttach": false, "waitForDebuggerOnStart": false, "flatten": true], session: sid)
        }
        await withCheckedContinuation { c in
            tab.attachChildTargets(false, timeout: Self.mediaQueryTimeout) { _, _ in DispatchQueue.main.async { c.resume() } }
        }
        return tab.childSessionIds.isEmpty
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
        Self.discardSessions.append(tab.childSessionIds.count)
#endif
        return tab.discard()
    }

    func startDiscardTimer() {
        discardTimer = Timer.scheduledTimer(withTimeInterval: Self.discardSweepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.discardIdleTabs() }
        }
    }
}
