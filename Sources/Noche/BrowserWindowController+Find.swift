import AppKit
import CefBridge

/// What the pill shows for one tab.
struct FindState {
    var text = ""
    var count = 0
    var active = 0
    var fresh = false   // a new session started and its first match is not active yet
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
        if let text { state.text = text }
        finds[tab.identifier] = state
        syncFind()
        if let ns = nsWindow {
            ns.makeFirstResponder(findBar.field)
            findBar.field.currentEditor()?.selectAll(nil)
        }
        if text != nil, !state.text.isEmpty { search(tab, forward: true, next: false) }
    }

    /// Cmd+G and Shift+Cmd+G: the next or previous match; with nothing searched yet they open the pill.
    func findStep(forward: Bool) {
        note(forward ? "findNext" : "findPrevious")
        guard let tab = activeTab else { return }
        guard let state = finds[tab.identifier], !state.text.isEmpty else { return openFind(counted: false) }
        if BarHook.on("FIND_NOSTEP") { return }  // negative control: the step does nothing
        search(tab, forward: forward, next: true)
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
                          let text = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String, !text.isEmpty else { return }
                    self.openFind(text: text, counted: false)
                }
            }
        }
    }

    private func search(_ tab: NCTab, forward: Bool, next: Bool) {
        guard var state = finds[tab.identifier] else { return }
        state.fresh = !next
        finds[tab.identifier] = state
        tab.find(state.text, forward: forward, matchCase: false, findNext: next)
    }

    /// Shows the pill for the active tab when it is searching (and re-runs its search: the highlight does not survive a tab switch for sure), hides it otherwise.
    func syncFind() {
        guard installed else { return }
        let tab = activeTab
        let want = tab.flatMap { finds[$0.identifier] != nil ? $0.identifier : nil }
        guard want != findShownFor else { return }
        findShownFor = want
        guard let tab, let want, let state = finds[want] else { findBar.isHidden = true; return }
        findBar.isHidden = false
        findBar.field.stringValue = state.text
        findBar.countText = state.countText
        if !state.text.isEmpty { search(tab, forward: true, next: false) }
    }

    func syncZoom() {
        guard installed else { return }
        let percent = ZoomPillView.percent(forLevel: activeTab?.zoomLevel ?? 0)
        let show = percent != 100 && !BarHook.on("ZOOM_NOPILL")  // negative control: the pill never shows
        toolbar.zoom.percent = percent
        if toolbar.zoom.isHidden == show { toolbar.zoom.isHidden = !show; toolbar.needsLayout = true }
    }

    func window(_ window: NCWindow, tab: NCTab, didFindMatches count: Int, active ordinal: Int, final: Bool) {
        guard var state = finds[tab.identifier] else { return }  // closed meanwhile
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
