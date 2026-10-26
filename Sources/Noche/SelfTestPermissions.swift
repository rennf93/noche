#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheStore

/// Checks of M1.5 Task 4: the site permission prompt and the remembered decisions. A named kind (geolocation, camera, microphone, notifications) is never
/// answered Allow in a test run, because macOS could ask the owner for location, camera, microphone or notification access (ruling M36); a request is
/// answered Block, or dismissed. "Allow resolves the page's request" is proven on MIDI with sysex: Chromium's MIDI sysex request reaches CEF's permission
/// prompt as kMidiSysex (cef/libcef/browser/permission_prompt.cc:224, CEF_PERMISSION_TYPE_MIDI_SYSEX, cef_types.h) and macOS's MIDI layer is CoreMIDI
/// alone (media/midi/midi_manager_mac.cc has no TCC authorization call), so no macOS dialog exists for it; the page reads only its own `sysexEnabled`.
extension SelfTest {
    var origin: String { "http://127.0.0.1:\(URL(string: url)?.port ?? 0)" }
    var otherOrigin: String { "http://localhost:\(URL(string: url)?.port ?? 0)" }
    var card: PermissionPromptView? { ctl?.permissionPrompt }
    var cardShown: Bool { card.map { !$0.isHidden } ?? false }

    func askGeolocation(_ tab: NCTab) async {
        _ = await evaluate(tab, "window.__geo = undefined; navigator.geolocation.getCurrentPosition(() => { window.__geo = 'allowed' }, e => { window.__geo = 'error ' + e.code }); 1")
    }
    func askMidi(_ tab: NCTab) async {
        _ = await evaluate(tab, "window.__midi = undefined; navigator.requestMIDIAccess({ sysex: true }).then(a => { window.__midi = 'granted sysex=' + a.sysexEnabled }, e => { window.__midi = 'denied ' + e.name }); 1")
    }
    func geoState(_ tab: NCTab) async -> String? {
        await evaluate(tab, "navigator.permissions.query({name: 'geolocation'}).then(s => s.state)")
    }
    func storedPermissions() -> [String] {
        ((try? app.writer?.store.permissions()) ?? []).map { "\($0.origin) \($0.kind) \($0.decision.rawValue)" }
    }
    func waitCard(_ seconds: Double = 15) async -> Bool { await until(seconds, { cardShown }) }
    func press(_ b: NSButton) { b.performClick(nil) }

    /// The origin's stored Block answers a request without the card: the host method called directly with the engine's callback replaced by a recorder.
    func storedBlockAnswers(_ tab: NCTab, origin: String) -> String {
        guard let ctl, let win else { return "no window" }
        let shownBefore = card?.shownCount ?? 0
        var answers: [String] = []
        ctl.window(win, tab: tab, requestsPermissions: .geolocation, origin: origin) { allow, remember in answers.append("\(allow),\(remember)") }
        return answers == ["false,true"] && card?.shownCount == shownBefore && ctl.permissionQueue.isEmpty ? "ok" : "answers \(answers) card shown \((card?.shownCount ?? 0) - shownBefore) times, queue \(ctl.permissionQueue.count)"
    }

    /// Loads |to| (the fixture by default) in |tab| and waits for the load.
    func reloadFixture(_ tab: NCTab, to target: String? = nil) async -> Bool {
        let before = loads
        tab.loadURL(target ?? fixture(""))
        return await until(15, { loads > before })
    }

    func permPrompt() async {
        guard await ready(), let ctl, let tab = win?.activeTab else { return }
        await askGeolocation(tab)
        guard await waitCard(), let card else { return finish(false, "the geolocation request showed no card (requests \(permissionRequests))") }
        let layout = ChromeLayout(size: ctl.overlay.bounds.size, cardX: ctl.cardX)
        let host = origin.replacingOccurrences(of: "http://", with: "")
        let geoCard = "site \(card.site.stringValue), text \(card.text.stringValue), buttons \(card.block.title) and \(card.allow.title), frame \(card.frame)"
        guard card.site.stringValue == host, card.text.stringValue.contains("location"), card.block.title == "Block", card.allow.title == "Allow",
              near(card.frame, layout.permissionPrompt.minX, layout.permissionPrompt.minY, layout.permissionPrompt.width, layout.permissionPrompt.height),
              card.frame.minX > layout.card.minX, card.frame.minY >= ChromeStyle.webTop, permissionRequests.last?.origin == origin, permissionRequests.last?.mask == .geolocation
        else { return finish(false, "the geolocation card is wrong: \(geoCard), want site \(host) at \(layout.permissionPrompt)") }
        let waiting = await evaluate(tab, "window.__geo === undefined")
        guard waiting == "true" else { return finish(false, "the page's request was answered before the card was used (\(waiting ?? "nil"))") }
        press(card.block)  // never Allow: a macOS location dialog could follow
        guard await until(10, { !cardShown }) else { return finish(false, "Block did not close the card") }
        let geo = await pageValue(tab, "window.__geo")
        // MIDI with sysex: no macOS permission layer, no owner data. The card shows, Allow resolves the page's request.
        await askMidi(tab)
        guard await waitCard(), card.text.stringValue.contains("browser feature") else { return finish(false, "the MIDI sysex request showed no card (requests \(permissionRequests.map { "\($0.mask.rawValue) \($0.origin)" }))") }
        let midiWaiting = await evaluate(tab, "window.__midi === undefined")
        press(card.allow)
        let midi = await pageValue(tab, "window.__midi")
        let ok = geo == "\"error 1\"" && midiWaiting == "true" && midi == "\"granted sysex=true\"" && !cardShown && violations.isEmpty
        finish(ok, "geolocation card (\(geoCard)) answered Block, the page got \(geo ?? "nil"); the MIDI sysex card answered Allow, the page got \(midi ?? "nil") (it waited: \(midiWaiting ?? "nil")); stored \(storedPermissions()) \(violations)")
    }

    /// Block remembered: the row, a reload with no card, the second origin still asking, and the store answering a direct request.
    func permRemember() async {
        guard await ready(), let win, let tab = win.activeTab, let port = URL(string: url)?.port else { return }
        let relaunch = phase == 2
        if !relaunch {
            await askGeolocation(tab)
            guard await waitCard(), let card else { return finish(false, "the geolocation request showed no card") }
            press(card.block)
            let geo = await pageValue(tab, "window.__geo")
            guard geo == "\"error 1\"", storedPermissions() == ["\(origin) geolocation block"] else {
                return finish(false, "after Block the page got \(geo ?? "nil") and the store holds \(storedPermissions())")
            }
        } else {
            guard storedPermissions() == ["\(origin) geolocation block"] else { return finish(false, "the relaunched store holds \(storedPermissions()), want the Block of \(origin)") }
            let before = loads
            tab.loadURL(fixture(""))
            guard await until(15, { loads > before }) else { return finish(false, "no fixture load after the relaunch") }
        }
        // The decision is Noche's: asked directly, the store answers Block without the card.
        let direct = storedBlockAnswers(tab, origin: origin)
        guard direct == "ok" else { return finish(false, "the stored Block did not answer a request: \(direct)") }
        // A reload: the request is answered with no card, and the page sees denied.
        let shown = card?.shownCount ?? 0
        if !relaunch {
            let before = loads
            tab.reload()
            guard await until(15, { loads > before }) else { return finish(false, "the reload never finished") }
        }
        await askGeolocation(tab)
        let geo = await pageValue(tab, "window.__geo")
        let state = await geoState(tab)
        guard geo == "\"error 1\"", state == "\"denied\"", card?.shownCount == shown else {
            return finish(false, "after the reload the page got \(geo ?? "nil"), state \(state ?? "nil"), the card showed \((card?.shownCount ?? 0) - shown) times")
        }
        // Noche's store is the one source of truth: the engine keeps its own copy of the decision, so it is cleared while the Noche row stays.
        let engineAfterBlock = NCEngine.contentSetting(forOrigin: origin, kind: "geolocation")
        NCEngine.resetContentSetting(forOrigin: origin, kind: "geolocation")
        let engineAfterReset = NCEngine.contentSetting(forOrigin: origin, kind: "geolocation")
        guard engineAfterBlock == "block", ["default", "ask"].contains(engineAfterReset) else { return finish(false, "the engine's setting was \(engineAfterBlock) after Block and \(engineAfterReset) after the reset, want block, then default or ask (geolocation's default is ask)") }
        guard await reloadFixture(tab) else { return finish(false, "no reload after the engine reset") }
        let asked = permissionRequests.count, cards = card?.shownCount ?? 0
        await askGeolocation(tab)
        let viaStore = await pageValue(tab, "window.__geo")
        guard permissionRequests.count == asked + 1, card?.shownCount == cards, viaStore == "\"error 1\"" else {
            return finish(false, "with the engine reset and the Noche row kept, the request reached the host \(permissionRequests.count - asked) times, the card showed \((card?.shownCount ?? 0) - cards) times, the page got \(viaStore ?? "nil")")
        }
        // A second origin (another host name for the same server) still asks.
        let beforeLoads = loads
        tab.loadURL("http://localhost:\(port)/")
        guard await until(15, { loads > beforeLoads }) else { return finish(false, "the second origin never loaded") }
        await askGeolocation(tab)
        guard await waitCard(), let card else { return finish(false, "the second origin \(otherOrigin) showed no card (requests \(permissionRequests.map(\.origin)))") }
        let second = card.site.stringValue
        card.close.onClick?()  // a one-time dismiss: nothing stored for it
        guard second == "localhost:\(port)", storedPermissions() == ["\(origin) geolocation block"] else { return finish(false, "second origin card \(second), stored \(storedPermissions())") }
        // Phase 1 leaves the Block for the relaunch; every other run ends by forgetting it.
        if phase == 1 { return finish(violations.isEmpty, "Block stored, the engine said \(engineAfterBlock) after it and \(engineAfterReset) after the reset, the Noche row alone kept the request denied with no card, the second origin showed the card; the Block is left for the relaunch \(violations)") }
        // Forgetting the decision (the M1.8 settings call) removes the Noche row and the engine's copy: the card shows again.
        guard await reloadFixture(tab, to: fixture("")) else { return finish(false, "no load back on the first origin") }
        ctl?.forgetPermission(origin: origin, kind: "geolocation")
        guard storedPermissions().isEmpty, ["default", "ask"].contains(NCEngine.contentSetting(forOrigin: origin, kind: "geolocation")) else {
            return finish(false, "after forgetPermission the store holds \(storedPermissions()) and the engine says \(NCEngine.contentSetting(forOrigin: origin, kind: "geolocation"))")
        }
        _ = await reloadFixture(tab)
        await askGeolocation(tab)
        let forgotten = await waitCard()
        card.close.onClick?()
        let ok = forgotten && violations.isEmpty
        finish(ok, "\(relaunch ? "after the relaunch" : "Block stored and kept over a reload"): no card, the page sees denied, the store answered a direct request; the engine said \(engineAfterBlock) after Block and \(engineAfterReset) after the reset, and with the Noche row alone the request still got no card (denied); the second origin showed the card for \(second); after forgetPermission the card showed again: \(forgotten) \(violations)")
    }

    /// A window of this process that is not in |known| (window numbers, any layer), apart from macOS's own text-input window.
    func ownWindowNumbers() -> Set<Int> {
        if BarHook.on("PERM_BLIND") { return [] }  // negative control: the detector sees nothing
        let pid = ProcessInfo.processInfo.processIdentifier
        let textInput = Set(NSApp.windows.filter { NSStringFromClass(type(of: $0)).hasPrefix("TUI") }.map { Int($0.windowNumber) })
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.compactMap { $0[kCGWindowNumber as String] as? Int }.filter { !textInput.contains($0) })
    }

    func permNoBubble() async {
        guard await ready(), let tab = win?.activeTab else { return }
        // Positive control: the detector sees a plain window, so "no new window" can fail.
        let before = ownWindowNumbers()
        let plain = NSWindow(contentRect: NSRect(x: 400, y: 400, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        plain.orderBack(nil)
        let seenPlain = ownWindowNumbers().subtracting(before)
        plain.close()
        guard !seenPlain.isEmpty else { return finish(false, "the window detector did not see a plain window (before \(before.count), after \(ownWindowNumbers().count))") }
        _ = await until(5, { ownWindowNumbers() == before })
        let known = ownWindowNumbers()
        let appWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        await askGeolocation(tab)
        // Watch for 1.5 s after the request reached the host: a Chromium bubble would be a new window by then.
        guard await until(15, { permissionRequests.count >= 1 }) else { return finish(false, "the geolocation request never reached the host (a Chromium prompt would have taken it)") }
        var extra = ownWindowNumbers().subtracting(known)
        for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(50)); extra.formUnion(ownWindowNumbers().subtracting(known)) }
        let appExtra = NSApp.windows.filter { !appWindows.contains(ObjectIdentifier($0)) && !NSStringFromClass(type(of: $0)).hasPrefix("TUI") }.map { NSStringFromClass(type(of: $0)) }
        guard let card, cardShown else { return finish(false, "the Noche card is not up") }
        press(card.block)
        await askMidi(tab)
        guard await waitCard() else { return finish(false, "no card for the MIDI sysex request") }
        card.close.onClick?()
        extra.formUnion(ownWindowNumbers().subtracting(known))
        finish(extra.isEmpty && appExtra.isEmpty && violations.isEmpty, "two requests reached Noche's card with no new window (window numbers \(extra), NSWindows \(appExtra)) \(violations)")
    }

    func permDismiss() async {
        guard await ready(), let tab = win?.activeTab else { return }
        await askGeolocation(tab)
        guard await waitCard(), let card else { return finish(false, "no card") }
        guard NCWindow.permissionPromptsOpen() == 1 else { return finish(false, "the engine waits for \(NCWindow.permissionPromptsOpen()) requests, want 1") }
        card.close.onClick?()
        guard await until(5, { NCWindow.permissionPromptsOpen() == 0 && !cardShown }) else {
            return finish(false, "the close button left \(NCWindow.permissionPromptsOpen()) requests open, card shown \(cardShown)")
        }
        let state = await geoState(tab)
        // Asking again shows the card again: nothing was remembered.
        await askGeolocation(tab)
        let again = await waitCard()
        let ok = storedPermissions().isEmpty && state == "\"prompt\"" && again && violations.isEmpty
        if again, let card = self.card { card.close.onClick?() }
        finish(ok, "closing the card answered the engine once (open 0), stored \(storedPermissions()), the page's state \(state ?? "nil") (not denied), asked again: card \(again) \(violations)")
    }

    /// The bridge's guards: unknown media bits, a request dismissed by the engine before the host hears of it, and a request open when its tab closes.
    func permGuards() async {
        guard await ready(), let win, let tab = win.activeTab, let ctl else { return }
        func mask(_ bits: UInt) -> UInt { NCWindow.mask(forMediaRequest: bits).rawValue }
        let masks = [0, 1, 2, 3, 4, 8, 0x100].map { mask(UInt($0)) }
        let wantMasks = [NCPermissionMask.other, .microphone, .camera, [.camera, .microphone], .screen, .screen, .other].map(\.rawValue)
        guard masks == wantMasks else { return finish(false, "media bits 0,1,2,3,4,8,0x100 gave masks \(masks), want \(wantMasks) (never 0)") }
        // The engine dismisses the request between its callback and the main-queue hop (the bridge's test switch does it at that point).
        let seen = permissionRequests.count
        setenv("NOCHE_TEST_PERM_RACE", "1", 1)
        await askGeolocation(tab)
        try? await Task.sleep(for: .seconds(1.5))
        unsetenv("NOCHE_TEST_PERM_RACE")
        guard permissionRequests.count == seen, ctl.permissionQueue.isEmpty, !cardShown, NCWindow.permissionPromptsOpen() == 0 else {
            return finish(false, "a request the engine dismissed first reached the host: requests \(permissionRequests.count - seen), queue \(ctl.permissionQueue.count), card \(cardShown), open \(NCWindow.permissionPromptsOpen())")
        }
        // A request still open when its tab closes is answered once (deny, not stored).
        let before = loads
        guard let second = win.addTab(withURL: fixture(""), activate: true) else { return finish(false, "no second tab") }
        guard await until(15, { loads > before && win.activeTab === second }) else { return finish(false, "no second tab") }
        await askGeolocation(second)
        guard await waitCard(), NCWindow.permissionPromptsOpen() == 1 else { return finish(false, "no open request in the second tab (open \(NCWindow.permissionPromptsOpen()))") }
        let closedBefore = NCWindow.permissionPromptsClosedWithTab()
        second.close()
        guard await until(10, { NCWindow.permissionPromptsOpen() == 0 && !cardShown && ctl.permissionQueue.isEmpty }) else {
            return finish(false, "closing the tab left \(NCWindow.permissionPromptsOpen()) requests open, queue \(ctl.permissionQueue.count), card \(cardShown)")
        }
        guard NCWindow.permissionPromptsClosedWithTab() == closedBefore + 1, storedPermissions().isEmpty else { return finish(false, "closed with tab \(NCWindow.permissionPromptsClosedWithTab()), stored \(storedPermissions())") }
        // The engine dismisses a request after the host has it: the card goes away and nothing is stored (a fresh page, so no earlier request is pending).
        let loadsThird = loads
        guard let third = win.addTab(withURL: fixture(""), activate: true), await until(15, { loads > loadsThird && win.activeTab === third }) else { return finish(false, "no third tab") }
        let seenLate = permissionRequests.count
        setenv("NOCHE_TEST_PERM_LATE", "1", 1)
        await askGeolocation(third)
        _ = await until(10, { permissionRequests.count > seenLate })
        try? await Task.sleep(for: .seconds(1))
        unsetenv("NOCHE_TEST_PERM_LATE")
        guard permissionRequests.count == seenLate + 1, ctl.permissionQueue.isEmpty, !cardShown, NCWindow.permissionPromptsOpen() == 0, storedPermissions().isEmpty else {
            return finish(false, "after the engine dismissed a delivered request: reached the host \(permissionRequests.count - seenLate) times, queue \(ctl.permissionQueue.count), card \(cardShown), open \(NCWindow.permissionPromptsOpen()), stored \(storedPermissions())")
        }
        // The M36 guard runs before the store write: a forced Allow on a named kind is a deny, stores nothing and is recorded. The engine is never asked:
        // the requests below are direct calls with a recorder in place of the engine's callback.
        guard let store = app.writer?.store else { return finish(false, "no store") }
        let forced = "http://perm-test-forced.invalid", fake = "http://perm-test.invalid"
        var forcedAnswers: [String] = []
        ctl.window(win, tab: third, requestsPermissions: .geolocation, origin: forced) { forcedAnswers.append("\($0),\($1)") }
        guard await waitCard(5), let card else { return finish(false, "no card for the direct request") }
        press(card.allow)
        let violated = violations.count == 1
        violations.removeAll()
        guard forcedAnswers == ["false,false"], violated, storedPermissions().isEmpty else { return finish(false, "a forced Allow on geolocation answered \(forcedAnswers) (violation recorded \(violated)), stored \(storedPermissions())") }
        // A stored Allow answers a named kind alone, but never a request whose mask has a bit Noche cannot name.
        try? store.setPermission(origin: fake, kind: "geolocation", decision: .allow)
        var alone: [String] = [], mixed: [String] = []
        ctl.window(win, tab: third, requestsPermissions: .geolocation, origin: fake) { alone.append("\($0),\($1)") }
        ctl.window(win, tab: third, requestsPermissions: [.geolocation, .other], origin: fake) { mixed.append("\($0),\($1)") }
        let queuedMixed = ctl.permissionQueue.count
        ctl.dropPermissionRequests(of: third)
        try? store.removePermission(origin: fake, kind: "geolocation")
        guard alone == ["true,false"], mixed == ["false,false"], queuedMixed == 1 else {
            return finish(false, "with a stored Allow: the named request answered \(alone), the one with the Other bit answered \(mixed) after being queued \(queuedMixed) (want queued, then the drop's deny)")
        }
        let ok = violations.isEmpty
        finish(ok, "media masks \(masks) (0 and unknown bits give Other, desktop capture gives Screen), a request dismissed before the hop never reached the host, a request open at its tab's close was answered once (closed with tab \(NCWindow.permissionPromptsClosedWithTab())), stored \(storedPermissions()) \(violations)")
    }

    /// forgetPermission clears everything the engine holds: the camera's pan-tilt-zoom setting too, and Chromium's embargo (three dismissals block an origin).
    func permForget() async {
        guard await ready(), let ctl, let tab = win?.activeTab else { return }
        // The camera kind covers both engine types (no page request: the settings are set to block directly, an Allow is never given).
        let ptz = "http://perm-test-ptz.invalid"
        NCEngine.testBlockContentSetting(forOrigin: ptz, kind: "camera")
        let before = ["camera", "camera-pan-tilt-zoom"].map { NCEngine.contentSetting(forOrigin: ptz, kind: $0) }
        ctl.forgetPermission(origin: ptz, kind: "camera")
        let after = ["camera", "camera-pan-tilt-zoom"].map { NCEngine.contentSetting(forOrigin: ptz, kind: $0) }
        guard before == ["block", "block"], !after.contains("block") else { return finish(false, "camera and pan-tilt-zoom engine settings were \(before) before forgetPermission and \(after) after (want both reset)") }
        // Three dismissals embargo the origin: the fourth request gets no card and the page sees denied.
        for n in 1...3 {
            await askGeolocation(tab)
            guard await waitCard(), let card else { return finish(false, "no card for dismissal \(n)") }
            card.close.onClick?()
            guard await until(5, { !cardShown && NCWindow.permissionPromptsOpen() == 0 }) else { return finish(false, "dismissal \(n) left the request open") }
        }
        let seen = permissionRequests.count, shown = card?.shownCount ?? 0
        await askGeolocation(tab)
        let embargoed = await pageValue(tab, "window.__geo")
        guard embargoed == "\"error 1\"", permissionRequests.count == seen, card?.shownCount == shown else {
            return finish(false, "after three dismissals the fourth request reached the host \(permissionRequests.count - seen) times, the card showed \((card?.shownCount ?? 0) - shown) times, the page got \(embargoed ?? "nil") (want an embargo: no card, error 1)")
        }
        ctl.forgetPermission(origin: origin, kind: "geolocation")
        await askGeolocation(tab)
        let back = await waitCard()
        card?.close.onClick?()
        finish(back && violations.isEmpty, "camera and pan-tilt-zoom \(before) became \(after) after forgetPermission; three dismissals embargoed the origin (fourth request: no card, page got \(embargoed ?? "nil")); after forgetPermission the card showed again: \(back) \(violations)")
    }

    /// An iframe from the second origin asks for geolocation. Chromium files the request under the TOP-level origin (the card names it, Noche stores it, the engine
    /// holds the Block at (top, top)); the iframe's own origin holds nothing in either form, so forgetPermission on the stored origin clears everything.
    func permIframe() async {
        guard await ready(), let ctl, let tab = win?.activeTab else { return }
        _ = await evaluate(tab, "window.__msg = undefined; window.addEventListener('message', e => { window.__msg = e.data }); var f = document.createElement('iframe'); f.allow = 'geolocation'; f.src = '\(otherOrigin)/geo-frame.html'; document.body.appendChild(f); 1")
        guard await waitCard(), let card else { return finish(false, "the iframe's request showed no card (requests \(permissionRequests.map(\.origin)))") }
        let site = card.site.stringValue, host = origin.replacingOccurrences(of: "http://", with: "")
        press(card.block)  // never Allow
        let msg = await pageValue(tab, "window.__msg")
        func engine() -> String { "(iframe,iframe) \(NCEngine.contentSetting(forOrigin: otherOrigin, kind: "geolocation")), (iframe,top) \(NCEngine.contentSetting(forOrigin: otherOrigin, kind: "geolocation", topLevelOrigin: origin)), (top,top) \(NCEngine.contentSetting(forOrigin: origin, kind: "geolocation"))" }
        let held = engine(), stored = storedPermissions()
        ctl.forgetPermission(origin: origin, kind: "geolocation")
        let after = engine()
        let ok = site == host && msg == "\"error 1\"" && stored == ["\(origin) geolocation block"] && held.hasSuffix("(top,top) block") && !held.contains("(iframe,iframe) block") && !held.contains("(iframe,top) block")
            && !after.contains("block") && violations.isEmpty
        finish(ok, "the iframe's request: card site \(site) (the top page's origin), page message \(msg ?? "nil"), stored \(stored), engine after Block \(held), after forgetPermission \(after) \(violations)")
    }
}
#endif
