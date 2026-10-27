import AppKit
import CefBridge
import NocheCore
import NocheStore

/// The list is the order of record: close successor, next and previous, Cmd+1 to Cmd+9 and the moves read and change it, not the engine's strip.
extension BrowserWindowController {
    /// The window's tabs in Noche's order (the list is the order of record), then any the engine has that the list has not heard of yet
    /// (opened in the same turn), in strip order.
    func orderedTabs() -> [NCTab] {
        let known = list.items.compactMap { engineTab($0) }
        return known + window.tabs.filter { t in !known.contains { $0 === t } }
    }

    /// Cmd+1 to Cmd+8 and Cmd+9: the tab at |index| of the list (nil: the last).
    func selectTab(at index: Int?) {
        note("selectTab")
        closeNext.removeAll()
#if NOCHE_TESTHOOKS
        // Negative control: the engine strip's order instead of the list's.
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_LIST_ORDER"] == "1" {
            let strip = window.tabs
            guard let i = index.map({ min($0, strip.count - 1) }) ?? strip.indices.last, strip.indices.contains(i) else { return }
            intendedActive = strip[i]; window.activateTab(strip[i]); return
        }
#endif
        let items = list.items
        guard let i = index.map({ min($0, items.count - 1) }) ?? items.indices.last, items.indices.contains(i) else { return }
        activate(items[i])
    }

    func isClosing(_ tab: NCTab) -> Bool {
        closing[tab.identifier].map { ProcessInfo.processInfo.systemUptime - $0 < Self.closeStale } ?? false
    }

    /// The first tab of |tab|'s hand-over chain that is neither closing nor gone (asked of the engine's strip, which is current
    /// even before the delegate has heard of a tab opened in the same turn).
    func survivor(from tab: NCTab?) -> NCTab? {
        var t = tab
        let strip = window.tabs
        for _ in 0..<100 {
            guard let c = t else { return nil }
            if !isClosing(c), strip.contains(where: { $0 === c }) { return c }
            t = closeNext[c.identifier]
        }
        return nil
    }

    /// Closes the selected tab; once it is gone the row below becomes selected (the one above for the last row). The selection does
    /// not move before that: a page can refuse to close. A tab that is already closing hands the focus to the tab that follows it, so
    /// a burst of Cmd+W closes one tab each. Decided from the engine's own tab strip, which is current even when callbacks lag.
    func closeActiveTab() {
        note("closeTab")
        guard let active = survivor(from: intendedActive ?? activeTab) else { return }
        if let blank = keepEngineTab(closing: active) {
            closeNext[active.identifier] = blank
        } else {
            let open = orderedTabs().filter { !isClosing($0) }
            if let i = open.firstIndex(where: { $0 === active }) {
                closeNext[active.identifier] = i + 1 < open.count ? open[i + 1] : (i > 0 ? open[i - 1] : nil)
            }
        }
        closing[active.identifier] = ProcessInfo.processInfo.systemUptime
        active.close()
    }

    func selectNextTab() { note("nextTab"); step(1) }
    func selectPreviousTab() { note("previousTab"); step(-1) }

    func step(_ delta: Int) {
        closeNext.removeAll()
        guard let id = intendedActive.flatMap({ ids[$0.identifier] }) ?? list.activeID,
              let target = delta > 0 ? list.next(after: id) : list.previous(before: id),
              let t = item(withID: target) else { return }
        activate(t)
    }

    /// IDC_MOVE_TAB_NEXT and _PREVIOUS: the active tab one step along the list (the order of record); at an end nothing happens.
    func moveTab(_ delta: Int) {
        note("moveTab")
        closeNext.removeAll()
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_MOVE"] == "1" { return }  // negative control
#endif
        guard let id = intendedActive.flatMap({ ids[$0.identifier] }) ?? list.activeID,
              let i = list.items.firstIndex(where: { $0.id == id }), list.items.indices.contains(i + delta) else { return }
        list.move(id, to: i + delta)
        refresh()
        changed()
    }
}
