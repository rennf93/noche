import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Saving and reopening: the snapshot the store writer takes and Reopen Closed Tab's identity hand-over.
extension BrowserWindowController {
    /// The store's view of this window; nil while the saved tabs are still being added.
    func snapshot(zOrder: Int) -> WindowSnapshot? {
        guard !restoring else { return nil }
        let ns = nsWindow
        let full = ns?.styleMask.contains(.fullScreen) == true
        let frame = full ? (normalFrame ?? ns?.frame ?? initialFrame) : (ns?.frame ?? initialFrame)
        let meta = Dictionary(uniqueKeysWithValues: list.items.map { item -> (TabID, TabMeta) in
            let icon = engineTab(item)?.faviconURL ?? faviconSeeds[item.id].flatMap { $0.url == item.url ? $0.icon : nil }
            return (item.id, TabMeta(faviconURL: icon))
        })
        return WindowSnapshot(id: id, frame: frame, isFullScreen: full, isZoomed: ns?.isZoomed ?? false, sidebarWidth: Double(ChromeStyle.sidebarWidth),
                              sidebarMode: sidebarHidden ? "hidden" : "shown", tabs: list.items, selectedTabID: list.activeID, zOrder: zOrder, tabMeta: meta,
                              groups: list.groups, topOrder: list.topOrder, dayOrder: list.dayOrder)
    }

    func changed(geometry: Bool = false) { if !restoring { app.writer?.markDirty(window: id, geometry: geometry) } }

    /// Reopen Closed Tab: the tab keeps its id, goes to |index| (clamped) and becomes active.
    /// False when the engine could not add the tab (the caller puts it back on the closed list).
    @discardableResult
    func reopen(_ item: TabItem, at index: Int) -> Bool {
        closeNext.removeAll()
        guard let tab = window.addTab(withURL: item.url, activate: true) else { return false }
        var reopened = item
        reopened.lastActiveAt = Date()   // a reopen is a use of the tab
        pendingByTab[tab.identifier] = PendingTab(id: item.id, url: item.url, index: index, item: reopened)
        intendedActive = tab
        return true
    }
}
