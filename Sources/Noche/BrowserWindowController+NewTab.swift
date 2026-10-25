import AppKit
import CefBridge
import NocheCore

/// The New Tab surface and what the command bar does to the window: a blank tab shows the card over a hidden page surface.
extension BrowserWindowController {
    func isBlank(_ item: TabItem) -> Bool { item.url.isEmpty || item.url == "about:blank" }

    /// Called when the bridge reports a tab active (|activated|) and on every update of the tab. The surface is hidden only from here, never
    /// right after addTab: the engine's own later active-tab report clears it (ruling R14), so an activation report asserts it again.
    func syncNewTab(activated: Bool) {
        guard installed else { return }
        if activated { reportedActive = list.activeID }
        if commandBar.isOpen, commandBar.placement == .overlay, commandBar.overlayTabID != list.activeID { commandBar.close(restoreFocus: false) }
        guard let id = list.activeID, let item = list.items.first(where: { $0.id == id }), isBlank(item), !item.isLoading, failed[item.engineID] == nil else {
            leaveNewTab()
            return
        }
        if newTabTabID == id {
            if !window.webContentHidden { window.webContentHidden = true }
            return
        }
        if activated || reportedActive == id { showNewTab(id) }
    }

    func showNewTab(_ id: TabID) {
        guard let host = window.chromeHost else { return }
        if newTabPage == nil {
            let page = NewTabPageView(frame: .zero)
            host.addSubview(page, positioned: .below, relativeTo: overlay)
            newTabPage = page
        }
        newTabShown = true
        newTabTabID = id
        window.webContentHidden = true
        applyLayout()
        commandBar.showCard()
    }

    func leaveNewTab() {
        newTabTabID = nil
        guard newTabShown else { return }
        newTabShown = false
        newTabPage?.removeFromSuperview()
        newTabPage = nil
        commandBar.hideCard()
        window.webContentHidden = false
    }

    /// The page surface rect, in host coordinates (origin bottom-left): the web insets.
    func updateNewTabFrame() {
        guard let page = newTabPage else { return }
        let insets = ChromeLayout(size: overlay.bounds.size, cardX: cardX).webInsets
        let size = overlay.bounds.size
        page.frame = NSRect(x: insets.left, y: insets.bottom, width: size.width - insets.left - insets.right, height: size.height - insets.top - insets.bottom)
    }

    /// A command bar navigation: the active tab, or a new tab (Cmd+Return). Both are typed visits.
    func navigate(_ url: URL, newTab: Bool) {
        if newTab {
            closeNext.removeAll()
            if let tab = window.addTab(withURL: url.absoluteString, activate: true) { typedLoads.insert(tab.identifier); intendedActive = tab }
            return
        }
        guard let tab = activeTab else { return }
        failed[tab.identifier] = nil
        typedLoads.insert(tab.identifier)
        tab.loadURL(url.absoluteString)
    }

    /// A tab row: the existing tab becomes active, nothing loads and no tab is added.
    func switchTo(_ id: TabID) {
        closeNext.removeAll()
        guard let item = list.items.first(where: { $0.id == id }), let tab = tabs[item.engineID] else { return }
        window.activateTab(tab)
    }
}
