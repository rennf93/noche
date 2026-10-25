import AppKit
import CefBridge

/// What the pill shows for one tab.
struct FindState {
    var text = ""
    var count = 0
    var active = 0
    var fresh = false   // a new session started and its first match is not active yet
    var latest = -1     // the largest search identifier the engine reported for this tab
    var floor = -1      // replies up to this identifier belong to a search that a new one replaced
    var countText: String { text.isEmpty ? "" : "\(active) of \(count)" }
}

/// Find in page (M1.4): the engine searches (`NCTab.find`), Noche draws the pill. Chromium's find bar is never asked for: Find, Find Next and Find Previous
/// are answered here, from the menu and from the engine's own accelerators (`shouldHandleChromeCommand`).
extension BrowserWindowController: NSTextFieldDelegate {
    func setUpFind() {
        findBar.field.delegate = self
        findBar.previous.onClick = { [weak self] in self?.findStep(forward: false) }
        findBar.next.onClick = { [weak self] in self?.findStep(forward: true) }
        findBar.close.onClick = { [weak self] in self?.closeFind() }
    }

    /// Cmd+F: the pill opens on the active tab (with the text it had) and its field takes focus with the text selected.
    func openFind(text: String? = nil, counted: Bool = true) {
        if counted { note("find") }
        guard installed, let tab = activeTab else { return }
        var state = finds[tab.identifier] ?? FindState()
        let shown = findShownFor == tab.identifier, changed = text.map { $0 != state.text } ?? false
        if let text { state.text = text }
        finds[tab.identifier] = state
        syncFind(search: false)
        if let ns = nsWindow {
            ns.makeFirstResponder(findBar.field)
            findBar.field.currentEditor()?.selectAll(nil)
        }
        // After the field took focus (a search started before it is lost to the page losing focus).
        if text != nil, shown ? changed : true, !state.text.isEmpty { findBar.field.stringValue = state.text; search(tab, forward: true, next: false) }
    }

    /// Cmd+G and Shift+Cmd+G: the next or previous match; with nothing searched yet they open the pill.
    func findStep(forward: Bool) {
        note(forward ? "findNext" : "findPrevious")
        guard let tab = activeTab else { return }
        guard let state = finds[tab.identifier], !state.text.isEmpty else { return openFind(counted: false) }
        if BarHook.on("FIND_NOSTEP") { return }  // negative control: the step does nothing
        search(tab, forward: forward || BarHook.on("FIND_PREVFWD"), next: true)  // negative control: Shift+Cmd+G steps forward
    }

    /// Escape and the close button: the engine drops the highlight and the selection, the pill goes, the page gets focus back.
    func closeFind() {
        guard let tab = activeTab else { return }
        tab.stopFinding(!BarHook.on("FIND_NOCLEAR"))  // negative control: the selection stays
        finds[tab.identifier] = nil
        syncFind()
        window.focusActiveContent()
    }

    /// Edit > Find > Use Selection for Find: the page's selected text becomes the search text.
    func useSelectionForFind() {
        note("useSelectionForFind")
        if BarHook.on("FIND_NOSELECT") { return }  // negative control: the item does nothing
        guard let tab = activeTab else { return }
        tab.evaluateJavaScript("window.getSelection().toString()") { [weak self] json, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, tab === self.activeTab, let json, let data = json.data(using: .utf8),
                          let raw = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return }
                    // Whitespace trimmed, the first line, at most 255 characters (Chromium's find box takes what it is given: this keeps a paragraph out of the pill).
                    let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isNewline }.prefix(255))
                    guard !text.isEmpty else { return }
                    self.openFind(text: text, counted: false)
                }
            }
        }
    }

    private func search(_ tab: NCTab, forward: Bool, next: Bool) {
        guard var state = finds[tab.identifier] else { return }
        state.fresh = !next
        if !next {  // a new session: nothing of the last one is active any more
            if !BarHook.on("FIND_STALE") { state.active = 0 }  // negative control: the last session's active match stays
            state.count = 0
            state.floor = state.latest
        }
        finds[tab.identifier] = state
        tab.find(state.text, forward: forward, matchCase: false, findNext: next)
    }

    /// Shows the pill for the active tab when it is searching (and re-runs its search: the highlight does not survive a tab switch for sure), hides it otherwise.
    func syncFind(search run: Bool = true) {
        guard installed else { return }
        let tab = activeTab
        let want = tab.flatMap { finds[$0.identifier] != nil ? $0.identifier : nil }
        guard want != findShownFor else { return }
        // The tab being left (still searching) keeps no highlights; the search re-runs when it is shown again.
        if let old = findShownFor, finds[old] != nil, !BarHook.on("FIND_NOLEAVESTOP") { window.tabs.first { $0.identifier == old }?.stopFinding(false) }
        findShownFor = want
        guard let tab, let want, let state = finds[want] else { findBar.isHidden = true; return }
        findBar.isHidden = false
        findBar.field.stringValue = state.text
        findBar.countText = state.countText
        if run, !state.text.isEmpty { search(tab, forward: true, next: false) }
    }

    /// After a pinch or Cmd+scroll event: the level now, and once more when the engine has applied it.
    func syncZoomSoon() {
        if BarHook.on("ZOOM_NOFOLLOW") { return }  // negative control: the pill ignores pinch and Cmd+scroll
        syncZoom()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in MainActor.assumeIsolated { self?.syncZoom() } }
    }

    func syncZoom() {
        guard installed else { return }
        let percent = ZoomPillView.percent(forLevel: activeTab?.zoomLevel ?? 0)
        let show = percent != 100 && !BarHook.on("ZOOM_NOPILL")  // negative control: the pill never shows
        toolbar.zoom.percent = percent
        if toolbar.zoom.isHidden == show { toolbar.zoom.isHidden = !show; toolbar.needsLayout = true }
    }

    /// Chromium's find bar closes when the main frame commits another document, a reload included (find_bar_controller.cc:277-312, NavigationEntryCommitted:
    /// `is_navigation_to_different_page()` is `is_main_frame && !is_same_document`, content/public/browser/navigation_details.h:62; EndFindSession keeps the
    /// selection and clears the results). A same-document navigation never reaches here. Not taken over: its branch for a bar opened after the navigation started
    /// (find_bar_controller.cc:293-309) needs the start of the navigation, which the bridge does not report; the session ends in both cases.
    func window(_ window: NCWindow, tabDidCommitNewDocument tab: NCTab) {
        guard finds[tab.identifier] != nil, !BarHook.on("FIND_NONAV") else { return }  // negative control: the session survives a navigation
        tab.stopFinding(false)
        finds[tab.identifier] = nil
        syncFind()
    }

    func window(_ window: NCWindow, tab: NCTab, didFindMatches count: Int, active ordinal: Int, final: Bool, identifier: Int) {
        guard var state = finds[tab.identifier], identifier > state.floor || BarHook.on("FIND_NOFLOOR") else { return }  // closed meanwhile, or a search a newer one replaced
        state.latest = max(state.latest, identifier)
        // A partial update leaves what it does not know at -1 (and the active match at 0 while it is still counting).
        if count >= 0 { state.count = count }
        if ordinal > 0 { state.active = ordinal }
        if state.count == 0 { state.active = 0 }
        // A new session reports its matches with none active (ordinal 0): the first one is activated once the count is final.
        if final, state.fresh {
            state.fresh = false
            if state.count > 0, state.active == 0 { tab.find(state.text, forward: true, matchCase: false, findNext: true) }
        }
        finds[tab.identifier] = state
        if findShownFor == tab.identifier { findBar.countText = state.countText }
    }

    // MARK: the pill's field

    func controlTextDidChange(_ obj: Notification) {
        guard let tab = activeTab, var state = finds[tab.identifier], obj.object as? NSTextField === findBar.field else { return }
        state.text = findBar.field.stringValue
        if state.text.isEmpty { state.count = 0; state.active = 0; tab.stopFinding(true) }
        finds[tab.identifier] = state
        findBar.countText = state.countText
        if !state.text.isEmpty { search(tab, forward: true, next: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === findBar.field else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): findStep(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
        case #selector(NSResponder.cancelOperation(_:)): closeFind()
        default: return false
        }
        return true
    }
}
