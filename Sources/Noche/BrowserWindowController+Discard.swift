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

    /// How long one whole media question (every session and frame of the page) may take (B: README builder calls); past it the answer is nil,
    /// so a sweep takes at most this per tab. 5 s: a page with about 20 frames answers in well under a second (about 3 calls of some
    /// milliseconds per frame), a single frame may use up to |mediaQueryTimeout|, and the deadline is the larger part of two of those.
    static let mediaQuestionDeadline: TimeInterval = 5

    /// The setting's value in seconds (default 120 minutes; a stored value outside the key's range is the default).
    var discardAfter: TimeInterval {
        let stored = (try? app.writer?.store.setting("discardAfterMinutes")).flatMap { $0 }
        return TimeInterval(SettingKeys.discardAfterMinutes(stored: stored)) * 60
    }

    /// One DevTools call bounded by |mediaQueryTimeout| and by |end|, the question's deadline: the whole `result` object, or the error
    /// ("timed out" on a timeout, "deadline" when |end| has passed).
    private func cdp(_ tab: NCTab, _ method: String, _ params: [String: Any] = [:], session: String? = nil, until end: Date = .distantFuture) async -> (result: [String: Any]?, error: String?) {
        let budget = BarHook.on("DISCARD_NODEADLINE") ? Self.mediaQueryTimeout : min(Self.mediaQueryTimeout, end.timeIntervalSinceNow)
        if budget <= 0 { return (nil, "deadline") }
#if NOCHE_TESTHOOKS
        if Self.testFailTree && method == "Page.getFrameTree" && session != nil { return (nil, "injected error") }
#endif
        let text = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let (json, error): (String?, String?) = await withCheckedContinuation { c in
            tab.callDevToolsMethod(method, paramsJSON: text, sessionId: session, timeout: budget) { json, error in DispatchQueue.main.async { c.resume(returning: (json, error)) } }
        }
        let obj = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if let error, let session, error.contains("not found") { logStaleSession(tab, session) }
        return (obj, error)
    }

    /// A child session id the engine no longer knows is said once per tab and id (the set lives and dies with the tab), not on every later question.
    private func logStaleSession(_ tab: NCTab, _ id: String) {
        guard !tab.loggedStaleSessions.contains(id) else { return }
        tab.loggedStaleSessions.add(id)
        FileHandle.standardError.write(Data("NOCHE media question: tab \(tab.url) has no child session \(id) any more (not asked again)\n".utf8))
    }

    /// The page script's answer ("playing", "none" or "frames") in the top frame of |session| (nil: the tab's page), or in the isolated world
    /// |context| of one of its frames; nil when it could not answer (timeout, deadline, error). userGesture false: asking must never count as
    /// the user's activation of the page.
    private func scan(_ tab: NCTab, _ js: String, session: String? = nil, context: Int? = nil, until end: Date) async -> String? {
        var params: [String: Any] = ["expression": js, "returnByValue": true, "awaitPromise": true, "userGesture": false]
        if let context { params["contextId"] = context }
#if NOCHE_TESTHOOKS
        // A frame's answer takes a fixed time from a timer (not from a busy page), so the deadline check does not depend on machine speed.
        if Self.testFrameDelay > 0, session != nil || context != nil { params["expression"] = "new Promise(r => setTimeout(() => r(\(js)), \(Int(Self.testFrameDelay * 1000))))" }
#endif
        let r = await cdp(tab, "Runtime.evaluate", params, session: session, until: end)
        guard r.result?["exceptionDetails"] == nil, let v = (r.result?["result"] as? [String: Any])?["value"] as? String, ["playing", "none", "frames"].contains(v) else { return nil }
        return v
    }

    /// Whether an audio or video element of the page is playing and not muted (CDP, through the DevTools channel): the top document, open
    /// shadow roots and same-origin frames are walked by the page script; every other frame is asked through its own execution context
    /// (|Page.getFrameTree|, |Page.createIsolatedWorld|, |Runtime.evaluate| with |contextId|) on the session that owns it: the top session for a
    /// same-process frame, a child session (auto attached, nested ones too) for an out-of-process one. Every session is a unit that must be
    /// walked. Whatever was attached is detached before this returns. A page sounding only through Web Audio is not seen (README known
    /// limit). Nil when a frame or session did not answer, or the question passed |mediaQuestionDeadline|, or the sessions could not be
    /// detached. T7.2's archiving asks the same question.
    func isPlayingMedia(_ tab: NCTab) async -> Bool? {
        let end = Date().addingTimeInterval(Self.mediaQuestionDeadline)
#if NOCHE_TESTHOOKS
        Self.mediaQuestions += 1
#endif
        // The hooks (negative controls) switch off the shadow root walk, the same-origin frame walk (the page script's only), or the frame walks below.
        let shadow = BarHook.on("DISCARD_NOSHADOW") ? "false" : "true", same = BarHook.on("DISCARD_NOSAME") ? "false" : "true"
        let js = "(() => { let blocked = false; const walk = (root) => { for (const m of root.querySelectorAll('audio,video')) if (!m.paused && !m.ended && !m.muted && m.volume > 0) return true; for (const el of root.querySelectorAll('*')) { if (\(shadow) && el.shadowRoot && walk(el.shadowRoot)) return true; if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { let d = null; try { d = \(same) ? el.contentDocument : null } catch (e) {} if (!d) blocked = true; else if (walk(d)) return true; } } return false; }; return walk(document) ? 'playing' : blocked ? 'frames' : 'none'; })()"
        guard let top = await scan(tab, js, until: end) else { return nil }
        if top == "playing" {
#if NOCHE_TESTHOOKS
            Self.lastPlayingPath = "script"
#endif
            return true
        }
        if top == "none" { return false }
        if BarHook.on("DISCARD_NOATTACH") { return false }
        var attached: [String] = []
        let answer = await askFrames(tab, js, until: end, attached: &attached)
#if NOCHE_TESTHOOKS
        if answer == true { Self.lastPlayingPath = "frame" }
#endif
        // The detach is awaited: discard() must not reach the engine with sessions still attached (T7.11).
        let detached = await detachChildTargets(tab, attached)
        return answer == false && !detached ? nil : answer
    }

    /// The answer of every session of the page, the top one and each child session (a unit each), and of every frame in their trees: true when
    /// one plays, false when all answered and none plays, nil when a session or a frame got no answer.
    private func askFrames(_ tab: NCTab, _ js: String, until end: Date, attached known: inout [String]) async -> Bool? {
        func unknown() -> Bool? { BarHook.on("DISCARD_UNASKEDNONE") ? false : nil }  // the old behavior: what nobody asked counts as not playing
        let (topIDs, topError): ([String], String?) = await withCheckedContinuation { c in
            tab.attachChildTargets(true, timeout: max(0.1, min(Self.mediaQueryTimeout, end.timeIntervalSinceNow))) { ids, error in
#if NOCHE_TESTHOOKS
                if Self.testFailAttach { DispatchQueue.main.async { c.resume(returning: ([], "injected error")) }; return }  // an injected error (the real attach ran)
#endif
                DispatchQueue.main.async { c.resume(returning: (ids, error)) }
            }
        }
        if topError != nil && !BarHook.on("DISCARD_ATTACHERRORCONT") { return unknown() }  // the old behavior: the sessions the attach did not list are left out
        known = topIDs
        // A child session auto attaches its own out-of-process frames (a cross-origin frame nested in a cross-origin frame); |nested| is how many were done.
        var nested = 0
        func attachNested() async -> Bool {
            while nested < known.count && !BarHook.on("DISCARD_NONESTED") {
                let sid = known[nested]
                nested += 1
                if await cdp(tab, "Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], session: sid, until: end).error != nil { return false }
                for id in tab.childSessionIds where !known.contains(id) { known.append(id) }
            }
            return true
        }
        guard await attachNested() else { return unknown() }
#if NOCHE_TESTHOOKS
        if Self.testHideLate { known.removeAll(); nested = 0 }  // every session attaches after the first walk
#endif
        var all = Set<String>(), answered = Set<String>(), walked = Set<String>(), topDone = false
        let walkTrees = !BarHook.on("DISCARD_NOTREE")
        var rounds = 0
        while true {
            rounds += 1
            let todo: [String?] = (topDone ? [] : [nil]) + known.filter { !walked.contains($0) }.map { Optional($0) }
            for sid in todo {
                if let sid { walked.insert(sid) } else { topDone = true }
                if sid == nil && !walkTrees { continue }
                if let sid, BarHook.on("DISCARD_CHILDFRAMESNONE") {  // the old behavior: a child's own "frames" answer counted as none
                    if await scan(tab, js, session: sid, until: end) == "playing" { return true }
                    continue
                }
                let tree = await cdp(tab, "Page.getFrameTree", session: sid, until: end)
                guard let root = tree.result?["frameTree"] as? [String: Any] else {
                    if BarHook.on("DISCARD_TREEERRORCONT") { continue }  // the old behavior: a session whose tree could not be read is left out
                    return unknown()
                }
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
                        verdict = sid == nil ? "none" : await scan(tab, js, session: sid, until: end)  // the top frame was answered before
                        if verdict == nil { return unknown() }
                    } else {
                        let world = await cdp(tab, "Page.createIsolatedWorld", ["frameId": f.id, "worldName": "noche-media"], session: sid, until: end)
                        if world.error == "timed out" || world.error == "deadline" { return unknown() }
                        // No world: the frame is not this session's (an out-of-process frame is answered by its own session).
                        guard let ctx = world.result?["executionContextId"] as? Int else { continue }
#if NOCHE_TESTHOOKS
                        Self.isolatedContexts[f.id, default: []].insert(ctx)
#endif
                        verdict = await scan(tab, js, session: sid, context: ctx, until: end)
                        if verdict == nil { return unknown() }
                    }
                    if verdict == "playing" { return true }
                    answered.insert(f.id)
                }
            }
            // A session that attached after the list was read is walked too; one still unwalked when the walk ends makes the answer unknown.
            if BarHook.on("DISCARD_NOLATE") { break }
            let late = tab.childSessionIds.filter { !known.contains($0) }
            known += late
            guard await attachNested() else { return unknown() }
            if known.allSatisfy({ walked.contains($0) }) { break }
            if rounds >= 4 { return unknown() }
        }
        if BarHook.on("DISCARD_UNASKEDNONE") { return false }
        return all.isSubset(of: answered) ? false : nil
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
            let stamp = max(t.lastActiveAt, leftAt[t.id] ?? .distantPast)
            if !BarHook.on("DISCARD_MEDIA") {
                let playing = await isPlayingMedia(tab)
                if BarHook.on("DISCARD_CLOSEDSTOP"), item(withID: t.id) == nil { break }  // the old behavior: a tab that went away while asked ends the sweep
                if playing != false { continue }
            }
            // The tab may have been selected (and left again) or started loading while the page answered: the idle time is read again.
            guard let cur = item(withID: t.id), discardable(cur), engineTab(cur) === tab else { continue }
            if !BarHook.on("DISCARD_NORECHECKIDLE"), max(cur.lastActiveAt, leftAt[cur.id] ?? .distantPast) != stamp { continue }
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
