import AppKit
import CefBridge
import NocheCore
import NocheStore

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Everything the bar knows about the text in it. The view only renders it.
struct CommandBarState {
    var typed = ""
    var rows: [Suggestion] = []
    var selected = 0
    var remote: [String] = []
}

/// The command bar of one window (research note section 5): owns the state, the field editor's events, the click-outside monitor and the open motion.
/// Two placements share one view: the New Tab card (always shown on a blank tab, over `NewTabPageView`) and the overlay a loaded page gets from Cmd+L.
/// Ranking, routing, inline completion, layout and the motion curve are NocheCore's; this class only connects them to AppKit.
@MainActor
final class CommandBarController: NSObject, NSTextFieldDelegate {
    unowned let owner: BrowserWindowController
    let view = CommandBarView(frame: .zero)
    private(set) var isOpen = false
    private(set) var placement: CommandBarLayout.Placement = .overlay
    /// The tab an overlay was opened for: switching tabs closes it.
    private(set) var overlayTabID: TabID?
    var state = CommandBarState()

    /// Starter rows of the empty New Tab card: inert until M2, clicking one copies its text into the input.
    static let starters = [BarRow.starter("bubble.left", "Summarize my open tabs"), .starter("sparkles", "What changed on this page?"), .starter("list.bullet", "Plan my week")]
    /// The built-in site list (hand-written, Resources/App/Sites.json in the bundle).
    static let sites: [SiteEntry] = {
        struct Row: Decodable { let name: String; let host: String }
        guard let url = Bundle.main.url(forResource: "Sites", withExtension: "json"), let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.map { SiteEntry(name: $0.name, host: $0.host) }
    }()

    private var inline: (text: String, selectedRange: NSRange)?
    private var pendingDelete = false
    private let remote = RemoteSuggest()   // one pending request and one in-flight task per bar
    private var animatedHeight: CGFloat?
    private var timer: Timer?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Uptime of the last open motion start, and every frame it drew (uptime, card height): what cb-motion checks.
    var motionStart: TimeInterval = 0
    var motionLog: [(t: TimeInterval, h: CGFloat)] = []
#if NOCHE_TESTHOOKS
    /// The last mouse-down the click-outside monitor handled (and handed back untouched).
    var mouseSeen: NSEvent?
#endif

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init()
        view.field.delegate = self
        view.onRowClick = { [weak self] i in self?.rowClicked(i) }
        view.go.onClick = { [weak self] in self?.commit(newTab: false) }
    }

    // MARK: open and close

    var showsStarters: Bool { placement == .newTab && state.typed.isEmpty }
    var displayRows: [BarRow] { showsStarters ? Self.starters : state.rows.map(BarRow.suggestion) }

    /// The text a page's address shows in the bar: `https://` and a trailing "/" dropped, anything else (http, file, about) as it is, so Return
    /// on the untouched text loads the same page.
    static func displayText(_ url: String) -> String {
        var s = url
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasSuffix("/") { s.removeLast() }
        return s == "about:blank" ? "" : s
    }

    /// Cmd+L and the toolbar's address area: a New Tab focuses its card, a loaded page opens the overlay.
    func openFromShortcut() {
        if isOpen, placement == .newTab { return focusField() }
        guard owner.activeTab != nil, !owner.newTabShown else { return }
        openOverlay()
    }

    /// The address the overlay opened with, for the Escape that finds it untouched.
    private var prefilled = ""

    func openOverlay() {
        guard let tab = owner.activeTab, let id = owner.list.activeID else { return }
        if !(isOpen && placement == .overlay) {
            close(restoreFocus: false)
            placement = .overlay
            overlayTabID = id
            state = CommandBarState(typed: Self.displayText(owner.shownURL(tab)))
            prefilled = state.typed
            inline = nil
            attach()
            setText(state.typed)
            render()
            if BarHook.on("BAR_NOMOTION") { animatedHeight = nil; relayout() } else { startMotion() }
        }
        focusField()
    }

    func showCard() {
        close(restoreFocus: false)
        placement = .newTab
        overlayTabID = nil
        state = CommandBarState()
        inline = nil
        attach()
        setText("")
        render()
        focusField()
    }

    func hideCard() { if isOpen, placement == .newTab { close(restoreFocus: false) } }

    func focusField() {
        guard isOpen, let ns = owner.nsWindow else { return }
        // Already editing: asking again would end the editing first, and that closes an overlay.
        if view.field.currentEditor() == nil, !BarHook.on("BAR_NOFOCUS") { ns.makeFirstResponder(view.field) }
        view.field.currentEditor()?.selectAll(nil)
        owner.window.keysHeld = true  // the engine's own focus requests are refused from here to the close, an unfocus or a click outside (CefFocusHandler)
        guardKeys()
    }

    /// The engine finishes a hand-back to the page (a close's `focusActiveContent`) on its own later turn, and that turn is not offered to the focus handler. A bar
    /// opened inside that window keeps the keys: while the guard runs, the page taking them back puts the field first responder again. The guard runs for
    /// `keysGuardSpan` after the hand-back, and for as long as the engine has not reported the page got the keys (OnGotFocus) up to `keysGuardCap`, then a
    /// short tail after the report. A click, an unfocus or a close ends the guard (the person decides).
    /// A poll, not a key-value observer: AppKit does not announce a first responder change to an observer.
    private var keysGuard: Timer?
    private static let keysGuardSpan: TimeInterval = 0.75, keysGuardCap: TimeInterval = 3, keysGuardTail: TimeInterval = 0.1

    private func guardRuns() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime, w: NCWindow = owner.window, t = w.lastFocusHandback
        if now < t + Self.keysGuardSpan { return true }
        if BarHook.on("BAR_NOGOTFOCUS") { return false }  // negative control: only the fixed span
        if w.focusHandbackPending, now < t + Self.keysGuardCap { return true }
        return w.lastGotFocus >= t && now < w.lastGotFocus + Self.keysGuardTail
    }

    private func guardKeys() {
        guard !BarHook.on("BAR_NOKEEPKEYS"), keysGuard == nil, guardRuns() else { return }  // negative control: the late hand-back wins
        let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, self.guardRuns() else { self?.endKeysGuard(); return }
                if self.view.field.currentEditor() == nil { self.focusField() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        keysGuard = t
    }

    private func endKeysGuard() { keysGuard?.invalidate(); keysGuard = nil }

    private func attach() {
        isOpen = true
        owner.overlay.addSubview(view, positioned: .below, relativeTo: owner.border)
        owner.toolbar.address.isHidden = placement == .overlay
        if !BarHook.on("BAR_NOOUTSIDE") {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.mouseDown(event)
#if NOCHE_TESTHOOKS
                    self?.mouseSeen = event
#endif
                }
                return event  // always untouched: the click still reaches what is under it
            }
        }
        if let ns = owner.nsWindow {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: ns, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.placement == .overlay { self?.close(restoreFocus: false) } }
            }
        }
    }

    /// Closing is instant. The page gets typing back when the bar was dismissed by the keyboard (Escape, Return); a click outside lets the click decide.
    func close(restoreFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        owner.window.keysHeld = false
        endKeysGuard()
        stopMotion()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let editing = view.field.currentEditor() != nil
        view.removeFromSuperview()
        owner.toolbar.address.isHidden = false
        if editing, let ns = owner.nsWindow { ns.makeFirstResponder(ns.contentView) }
        if restoreFocus { owner.window.focusActiveContent() }
        remote.request("", searchTemplate: owner.app.searchTemplate, enabled: false) { _ in }
        state = CommandBarState()
        inline = nil
    }

    /// The card stays; the field editor goes and the page view (when there is one) gets typing.
    func unfocusCard(restoreFocus: Bool = true) {
        owner.window.keysHeld = false
        endKeysGuard()
        if let ns = owner.nsWindow, view.field.currentEditor() != nil { ns.makeFirstResponder(ns.contentView) }
        if restoreFocus { owner.window.focusActiveContent() }
    }

    func teardown() {
        close(restoreFocus: false)
        timer?.invalidate()
    }

    private func mouseDown(_ event: NSEvent) {
        guard isOpen, event.window === owner.nsWindow else { return }
        endKeysGuard()
        if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return }
        if placement == .overlay { close(restoreFocus: false) } else { unfocusCard(restoreFocus: false) }
    }

    // MARK: motion (elapsed time, not a display link: a hidden window gets no frames)

    private func startMotion() {
        motionStart = ProcessInfo.processInfo.systemUptime
        animatedHeight = OverlayMotion.height(at: 0)
        relayout()
        log()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The last frame lands on time even when a tick is late.
        let started = motionStart
        DispatchQueue.main.asyncAfter(deadline: .now() + ChromeStyle.barMotionDuration + 0.002) { [weak self] in
            MainActor.assumeIsolated { if let self, self.motionStart == started, self.animatedHeight != nil { self.tick() } }
        }
    }

    private func tick() {
        guard animatedHeight != nil else { return stopMotion() }
        let t = ProcessInfo.processInfo.systemUptime - motionStart
        if t >= ChromeStyle.barMotionDuration { animatedHeight = nil; stopMotion() } else { animatedHeight = OverlayMotion.height(at: t) }
        relayout()
        log()
    }

    private func log() {
#if NOCHE_TESTHOOKS
        motionLog.append((ProcessInfo.processInfo.systemUptime, view.frame.height))
#endif
    }

    private func stopMotion() {
        timer?.invalidate()
        timer = nil
        if animatedHeight != nil { animatedHeight = nil; relayout() }
    }

    // MARK: layout and rendering

    func relayout() {
        guard isOpen, view.superview != nil else { return }
        let size = owner.overlay.bounds.size
        let n = displayRows.count
        let f = CommandBarLayout.frames(placement: placement, rows: BarHook.on("BAR_LAYOUT") ? 0 : n, cardX: owner.cardX, window: size)
        view.squareTop = placement == .overlay
        view.apply(f, height: min(f.card.height, animatedHeight ?? f.card.height), newTab: placement == .newTab, pill: !showsStarters && n > 0)
        if placement == .newTab { owner.newTabPage?.placeOrb(above: f.card, windowHeight: size.height) }
    }

    private func render() {
        let top = state.rows.first?.kind
        view.setIcon(!showsStarters && state.selected == 0 && top != nil && top != .query && top != .remoteQuery ? "globe" : "magnifyingglass")
        view.setRows(displayRows, selected: showsStarters ? nil : state.selected)
        relayout()
    }

    // MARK: text

    private var editorText: String { view.field.currentEditor()?.string ?? view.field.stringValue }

    private func setText(_ s: String, selection: NSRange? = nil) {
        if let ed = view.field.currentEditor() {
            ed.string = s
            ed.selectedRange = selection ?? NSRange(location: (s as NSString).length, length: 0)
        } else {
            view.field.stringValue = s
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isOpen, let ed = view.field.currentEditor() else { return }
        let deleting = pendingDelete
        pendingDelete = false
        state.typed = ed.string
        refresh(deleting: deleting)
    }

    /// While the keys guard is on the field editor refuses to resign: the engine's late hand-back to the page (a makeFirstResponder) fails, and no key of that moment
    /// goes to the page. A person's own moves end the guard first (a click, Escape, a close).
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool { keysGuard == nil }

    /// A dismissed field editor ends an overlay (the card stays), unless the keys guard is on: then the page took the keys in the engine's late hand-back and the
    /// guard's next tick gives them back.
    func controlTextDidEndEditing(_ obj: Notification) {
        if isOpen, placement == .overlay, keysGuard == nil { close(restoreFocus: false) }
    }

    /// What one ranking reads, copied on the main thread so the work can run anywhere. The bookmarks are the app's list (kept between changes, so a deleted one
    /// is gone from the next keystroke); the pages are read from the store here, off the main thread when this runs in the background.
    private struct RankJob: Sendable {
        let q: String, store: Store?, tabs: [TabItem], sites: [SiteEntry], remote: [String], active: TabID?, marks: [BookmarkCandidate]
        func run() -> [Suggestion] {
            let first = q.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? q
            let pages = ((try? store?.pageCandidates(prefix: first, limit: 50)) ?? nil) ?? []
            return SuggestionRanker.rank(query: q, pages: pages, tabs: tabs, sites: sites, remote: remote, activeTabID: active, bookmarks: marks)
        }
    }

    private func job(_ q: String) -> RankJob {
        RankJob(q: q, store: owner.app.writer?.store, tabs: owner.list.items, sites: Self.sites, remote: state.remote, active: owner.list.activeID,
                marks: BarHook.on("BM_NOSUGGEST") ? [] : owner.app.bookmarkCandidates)
    }

    /// A ranking waits here until its rows land; `settle()` runs it on the spot when the person acts before then.
    private var pendingRank: (q: String, deleting: Bool?)?
    private var generation = 0
#if NOCHE_TESTHOOKS
    /// Test only: seconds a ranking for this query is held back before it lands (a slow older result).
    var rankDelay: ((String) -> TimeInterval)?
#endif

    /// Ranks off the main thread; only the newest ranking lands, an older one never replaces a newer one. `deleting` nil: no inline completion (remote rows arriving).
    private func startRank(_ q: String, deleting: Bool?) {
        generation += 1
        let gen = generation
        guard !q.isEmpty else { pendingRank = nil; return land([], deleting: deleting) }
        pendingRank = (q, deleting)
        let job = job(q)
        var delay = 0.0
#if NOCHE_TESTHOOKS
        delay = rankDelay?(q) ?? 0
#endif
        let typed = state.typed
        Task.detached(priority: .userInitiated) { [weak self, delay] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let rows = job.run()
            await MainActor.run {
                // negative control: RANK_STALE lets any result land
                guard let self, BarHook.on("RANK_STALE") || (gen == self.generation && self.isOpen && self.state.typed == typed) else { return }
                self.pendingRank = nil
                self.land(rows, deleting: deleting)
            }
        }
    }

    /// Return, the arrows and Tab act on the rows of the text in the field, not on the ones before the last keystroke.
    private func settle() {
        guard let p = pendingRank else { return }
        generation += 1
        pendingRank = nil
        guard p.q == state.typed.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        land(job(p.q).run(), deleting: p.deleting)
    }

    private func land(_ rows: [Suggestion], deleting: Bool?) {
        state.rows = rows
        if let deleting {
            state.selected = 0
            inline = nil
            // Text still being composed (IME) is never rewritten: setText would end the composition (negative control: BAR_IME ignores it).
            let composing = (view.field.currentEditor() as? NSTextView)?.hasMarkedText() == true && !BarHook.on("BAR_IME")
            if !composing, let c = InlineAutocomplete.completion(typed: state.typed, topHit: state.rows.first, justDeleted: BarHook.on("BAR_INLINE") ? false : deleting) {
                inline = c
                setText(c.text, selection: c.selectedRange)
            }
        }
        render()
    }

    private func refresh(deleting: Bool) {
        stopMotion()
        let typed = state.typed
        let q = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        state.remote = state.remote.filter { $0.lowercased().hasPrefix(q.lowercased()) }
        state.selected = 0
        inline = nil
        startRank(q, deleting: deleting)
        // The typed character is drawn now; rows follow when the ranking lands (the earlier rows stay until then).
        render()
        let enabled = ((try? owner.app.writer?.store.setting("suggestRemote")) ?? nil) == "1"
        remote.request(typed, searchTemplate: owner.app.searchTemplate, enabled: enabled || BarHook.on("REMOTE_IGNORE_OFF")) { [weak self] rows in self?.remoteArrived(rows, for: typed) }
    }

    /// Remote rows join after the literal query, only while the selection is still on the first row and the text is the one they answer.
    private func remoteArrived(_ rows: [String], for typed: String) {
        guard isOpen, state.typed == typed, state.selected == 0 else { return }
        state.remote = rows
        startRank(typed.trimmingCharacters(in: .whitespacesAndNewlines), deleting: pendingRank?.deleting)  // a keystroke's ranking still waiting keeps its inline completion
    }

    // MARK: keys (they arrive as commands from the field editor)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case #selector(NSResponder.cancelOperation(_:)):
            if BarHook.on("BAR_ESC") { return true }
            escape()
        case #selector(NSResponder.moveDown(_:)):
            if !BarHook.on("BAR_NOARROWS") { move(1) }
        case #selector(NSResponder.moveUp(_:)):
            if !BarHook.on("BAR_NOARROWS") { move(-1) }
        case #selector(NSResponder.insertTab(_:)):
            tab()
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)):
            // Only a delete that will change text arms the "just deleted" flag: on an empty field or at the end of the text it would
            // otherwise stay set (no change notification clears it) and skip the next completion.
            let r = textView.selectedRange, n = (textView.string as NSString).length
            let forward = selector == #selector(NSResponder.deleteForward(_:))
            if r.length > 0 || (forward ? r.location < n : r.location > 0) || BarHook.on("BAR_STALEDELETE") { pendingDelete = true }
            return false
        default:
            return false
        }
        return true
    }

    /// Escape: text and rows go first (an untouched prefilled address closes the overlay at once); on an empty bar an overlay closes and the card gives up focus.
    private func escape() {
        // An overlay whose text is still the page's own address: one Escape closes it (negative control: BAR_ESCPREFILL clears first).
        if placement == .overlay, !prefilled.isEmpty, editorText == prefilled, !BarHook.on("BAR_ESCPREFILL") { return close() }
        if !state.typed.isEmpty || !editorText.isEmpty {
            state = CommandBarState()
            inline = nil
            setText("")
            remote.request("", searchTemplate: owner.app.searchTemplate, enabled: false) { _ in }
            render()
        } else if placement == .overlay {
            close()
        } else {
            unfocusCard()
        }
    }

    private func rowText(_ row: Suggestion) -> String {
        switch row.kind {
        case .query, .remoteQuery: return row.title
        default: return row.url.map(urlDisplay) ?? row.title
        }
    }

    /// Selects row |i| and shows its text in the field; the first row shows the typed text with the inline remainder selected.
    private func select(_ i: Int) {
        state.selected = i
        if i == 0 {
            if let inline { setText(inline.text, selection: inline.selectedRange) } else { setText(state.typed) }
        } else {
            setText(rowText(state.rows[i]))
        }
        render()
    }

    private func move(_ delta: Int) {
        settle()
        guard !state.rows.isEmpty else { return }
        let i = min(max(state.selected + delta, 0), state.rows.count - 1)
        if i != state.selected { select(i) }
    }

    /// Tab accepts the inline remainder (caret to the end); without one it acts like Down.
    private func tab() {
        settle()
        guard let inline, state.selected == 0 else { return move(1) }
        state.typed = inline.text
        setText(inline.text)
        refresh(deleting: true)
    }

    private func rowClicked(_ i: Int) {
        if showsStarters {
            state.typed = Self.starters[i].title
            setText(state.typed)
            refresh(deleting: true)
            focusField()
        } else if i < state.rows.count {
            generation += 1  // the row clicked is the one on screen: no ranking lands over it
            pendingRank = nil
            state.selected = i
            commit(newTab: false)
        }
    }

    // MARK: running a row

    func commit(newTab: Bool) {
        settle()
        if state.rows.isEmpty, state.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if placement == .overlay { close() } else { unfocusCard() }
            return
        }
        run(state.rows[safe: state.selected], newTab: newTab)
    }

    /// Runs a row (nil: the typed text). Every route re-checks the scheme allowlist; a tab row switches and loads nothing.
    func run(_ row: Suggestion?, newTab: Bool) {
        if BarHook.on("BAR_NOGO") { return }
        var route = CommandRouter.route(row, typed: state.typed, searchTemplate: owner.app.searchTemplate)
        var inNewTab = newTab
        if BarHook.on("BAR_ROUTE"), let row, row.kind == .page, let u = row.url, let url = URL(string: u) { route = .navigate(url) }  // negative control: no allowlist
        if BarHook.on("BAR_DUPTAB"), let row, row.tabID != nil, let u = row.url, let url = URL(string: u) { route = .navigate(url); inNewTab = true }  // negative control
        switch route {
        case .navigate(let url):
            guard BarHook.on("BAR_ROUTE") || AddressInput.allowedSchemes.contains(url.scheme?.lowercased() ?? "") else { return }
            let card = placement == .newTab
            close(restoreFocus: false)
            if card, !inNewTab { owner.leaveNewTab() }
            owner.navigate(url, newTab: inNewTab)
            owner.window.focusActiveContent()
            // The page view may only just be back on screen after a New Tab.
            if card { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in MainActor.assumeIsolated { self?.owner.window.focusActiveContent() } } }
        case .switchTo(let id):
            close(restoreFocus: false)
            owner.switchTo(id)
            owner.window.focusActiveContent()
        case .none:
            break
        }
    }
}
