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
        // A second origin (another host name for the same server) still asks.
        let beforeLoads = loads
        tab.loadURL("http://localhost:\(port)/")
        guard await until(15, { loads > beforeLoads }) else { return finish(false, "the second origin never loaded") }
        await askGeolocation(tab)
        guard await waitCard(), let card else { return finish(false, "the second origin \(otherOrigin) showed no card (requests \(permissionRequests.map(\.origin)))") }
        let second = card.site.stringValue
        card.close.onClick?()  // a one-time dismiss: nothing stored for it
        let ok = second == "localhost:\(port)" && storedPermissions() == ["\(origin) geolocation block"] && violations.isEmpty
        finish(ok, "\(relaunch ? "after the relaunch" : "Block stored and kept over a reload"): no card, the page sees denied, the store answered a direct request; the second origin showed the card for \(second); stored \(storedPermissions()) \(violations)")
    }

    /// A window of this process that is not in |known| (window numbers, any layer), apart from macOS's own text-input window.
    func ownWindowNumbers() -> Set<Int> {
        let pid = ProcessInfo.processInfo.processIdentifier
        let textInput = Set(NSApp.windows.filter { NSStringFromClass(type(of: $0)).hasPrefix("TUI") }.map { Int($0.windowNumber) })
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.compactMap { $0[kCGWindowNumber as String] as? Int }.filter { !textInput.contains($0) })
    }

    func permNoBubble() async {
        guard await ready(), let tab = win?.activeTab else { return }
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
        let wantMasks = [NCPermissionMask.other, .microphone, .camera, [.camera, .microphone], .other, .other, .other].map(\.rawValue)
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
        let ok = NCWindow.permissionPromptsClosedWithTab() == closedBefore + 1 && storedPermissions().isEmpty && violations.isEmpty
        finish(ok, "media masks \(masks) (0 and unknown bits give Other), a request dismissed before the hop never reached the host, a request open at its tab's close was answered once (closed with tab \(NCWindow.permissionPromptsClosedWithTab())), stored \(storedPermissions()) \(violations)")
    }
}
#endif
