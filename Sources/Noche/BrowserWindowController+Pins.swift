import AppKit
import CefBridge
import NocheCore

/// Pinned tabs (M1.6 Task 3): Pin and Unpin, the pinned page, and dormant tabs (a list item with no engine tab).
extension BrowserWindowController {
    func item(withID id: TabID) -> TabItem? { list.items.first { $0.id == id } }

    /// Whether the active tab is pinned (the Tabs menu shows Unpin then).
    var activeIsPinned: Bool { list.activeID.flatMap { item(withID: $0) }?.isPinned == true }

    /// Tabs > Pin (Shift+Cmd+D) on the active tab, or the context menu's Pin and Unpin on |target|.
    func togglePin(of target: TabID? = nil) {
        note("pinTab")
        if BarHook.on("PIN_NOOP") { return }  // negative control: Pin does nothing
        guard let id = target ?? list.activeID, let t = item(withID: id) else { return }
        if t.isPinned { list.unpin(id) } else { list.pin(id) }
        refresh()
        changed()
    }

    // MARK: the pinned page

    /// Back to the pinned page: the same engine tab loads |pinnedURL| (a dormant tab wakes at it).
    func resetToPinned(_ id: TabID) {
        note("resetPinned")
        if BarHook.on("PIN_NORESET") { return }  // negative control: Reset to Pinned Page does nothing
        guard let t = item(withID: id), t.isPinned, let pinned = t.pinnedURL else { return }
        if t.isDiscarded && BarHook.on("DISCARD_NORESET") { return }  // negative control: Reset does nothing on a discarded tab
        guard let tab = engineTab(t) else { return wake(t) }
        _ = list.resetToPinned(id)
        failed[tab.identifier] = nil
        tab.loadURL(pinned)
        refresh()
        changed()
    }

    /// Use Current Page as Pinned Page.
    func usePinnedPage(_ id: TabID) {
        note("usePinnedPage")
        guard list.usePinnedPage(id) else { return }
        refresh()
        changed()
    }

    func copyPinnedURL(_ id: TabID) {
        guard let pinned = item(withID: id)?.pinnedURL else { return }
        copyText(pinned, note: "copyPinnedURL")
    }

    /// Copy Link on a tab with no engine tab: its stored address.
    func copyText(_ text: String, note n: String) {
        note(n)
        let board = pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: dormant tabs

    /// Selects a tab: its engine tab becomes active; a dormant one gets a new engine tab first.
    func activate(_ t: TabItem) {
        closeNext.removeAll()
        // A discarded tab has its engine tab: it reloads in place. The hook opens a second engine tab for it instead (a duplicate).
        if t.isDiscarded && BarHook.on("DISCARD_WAKE") { _ = window.addTab(withURL: t.url, activate: true); return }
        if let tab = engineTab(t) { intendedActive = tab; window.activateTab(tab) } else { wake(t) }
    }

    /// A dormant tab gets an engine tab at its pinned page (its address when it has none) and becomes active; the tab keeps its id and
    /// place (|window(_:didAdd:active:)| takes the engine tab for it). A second request while the first is still arriving does nothing.
    func wake(_ t: TabItem) {
        guard t.engineID == nil, !pendingByTab.values.contains(where: { $0.id == t.id }) else { return }
        note("wakeTab")
        let url = (t.pinnedURL ?? t.url).isEmpty ? "about:blank" : (t.pinnedURL ?? t.url)
        closeNext.removeAll()
        guard let tab = window.addTab(withURL: url, activate: true) else { return }
        pendingByTab[tab.identifier] = PendingTab(id: t.id, url: url, index: nil)
        intendedActive = tab
    }

    /// A pinned tab whose engine tab closed (Cmd+W, its page) stays as a dormant tile; nothing else does, and not when the window itself
    /// is closing or the app is quitting.
    func goesDormant(_ t: TabItem) -> Bool {
        t.isPinned && !windowClosing && !app.closing && !BarHook.on("PIN_CLOSE")  // the hook: a pinned tab closes like any other
    }

    /// The window always keeps an engine tab. When |tab| is the only one and it would close or go dormant (a pinned tab goes dormant, and
    /// a window that holds dormant tabs must not close), a blank day tab opens first and becomes the selection. Nil when none is needed.
    func keepEngineTab(closing tab: NCTab) -> NCTab? {
        if BarHook.on("PIN_NOBLANK") { return nil }  // negative control: the last engine tab closes alone
        let open = orderedTabs().filter { !isClosing($0) }
        guard open.count == 1, open[0] === tab else { return nil }
        let pinned = ids[tab.identifier].flatMap { item(withID: $0) }?.isPinned == true
        // A pinned tab already closing (a burst of Cmd+W) is about to be dormant, though the list does not say so yet.
        let dormantSoon = orderedTabs().contains { isClosing($0) && ids[$0.identifier].flatMap { item(withID: $0) }?.isPinned == true }
        guard pinned || (dormantSoon && !BarHook.on("PIN_NOSOON")) || list.items.contains(where: { $0.engineID == nil }) else { return nil }
        closeNext.removeAll()
        let blank = window.addTab(withURL: "about:blank", activate: true)
        intendedActive = blank
        return blank
    }

    /// The engine tab of |id| is gone and the tab stays: it keeps its place and goes dormant at its pinned page.
    func becomeDormant(_ id: TabID, last tab: NCTab) {
        dormantIcons[id] = tab.favicon
        if let icon = tab.faviconURL, let pinned = item(withID: id)?.pinnedURL { faviconSeeds[id] = (pinned, icon) }
        if let pinned = item(withID: id)?.pinnedURL { list.update(id, url: pinned, title: item(withID: id)?.title ?? "", isLoading: false) }
        list.setEngineID(id, nil)
    }
}

extension BrowserWindowController {
    /// A dormant tile's icon after a relaunch: the saved icon address is fetched once (no cookies, 5 s, http or https only, 1 MB at most)
    /// and shown until the tab wakes and the page reports its own.
    func loadDormantIcon(_ id: TabID) {
        if BarHook.on("PIN_NOICON") { return }  // negative control: a restored dormant tile keeps the globe
        guard dormantIcons[id] == nil, let seed = faviconSeeds[id], let url = URL(string: seed.icon), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        Task { [weak self] in
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 5)), data.count <= 1_000_000,
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data), let self else { return }
            guard self.item(withID: id)?.engineID == nil else { return }
            self.dormantIcons[id] = image
            self.refresh()
        }
    }
}

