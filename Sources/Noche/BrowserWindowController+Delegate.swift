import AppKit
import CefBridge
import NocheCore
import NocheStore

extension BrowserWindowController {
    // MARK: NCWindowDelegate

    func item(for tab: NCTab) -> TabItem {
        let id = ids[tab.identifier] ?? TabID()
        ids[tab.identifier] = id
        return TabItem(id: id, engineID: tab.identifier, url: tab.url, title: tab.title, isLoading: tab.isLoading)
    }

    func window(_ window: NCWindow, didAdd tab: NCTab, active: Bool) {
        installChrome()
        tabs[tab.identifier] = tab
        var pending = pendingByTab.removeValue(forKey: tab.identifier)
        if !firstAdded, pending == nil { pending = initialPending; initialPending = nil }
        firstAdded = true
        if let pending { ids[tab.identifier] = pending.id }
        // The new tab goes right after the tab before it in the engine's strip (a popup after its opener); one the engine appended goes
        // last in the list, which can differ from the strip after a reopen put a tab in the middle.
        let strip = window.tabs
        let at = strip.firstIndex(where: { $0 === tab })
        let before = at.flatMap { $0 > 0 && $0 < strip.count - 1 ? strip[$0 - 1] : nil }
        var added = item(for: tab)
        if let pending { added.url = pending.url }   // the saved address until the engine reports its own
        list.insert(added, after: before.flatMap { ids[$0.identifier] }, activate: active)
        if let at = pending?.index { list.move(added.id, to: at) }
        if lastActive[added.id] == nil { lastActive[added.id] = Date() }
        if let restore {
            if !restoreStarted {
                restoreStarted = true
                for p in restoreRest { if let t = window.addTab(withURL: p.url, activate: false) { pendingByTab[t.identifier] = p } }
            }
            if let pending, pending.index == nil {
                restoreAdded += 1
                if added.id == restore.selected, !active { skipActivation = added.id; window.activateTab(tab); intendedActive = tab }
                if restoreAdded == restore.tabs.count {
                    restoring = false; self.restore = nil
                    if restore.isZoomed, !restore.fullScreen { nsWindow?.zoom(nil) }
                }
            }
        }
        refresh()
        changed()
        // The window's own first tab is never announced as an activation.
        if active, list.items.count == 1 { syncNewTab(activated: true) }
        app.tabAdded(tab)
    }

    func window(_ window: NCWindow, didActivate tab: NCTab, previous: NCTab?) {
        if let id = ids[tab.identifier] {
            // Using a tab stamps it; the restore's own activation (and the engine re-announcing the active tab) does not.
            if id == skipActivation { skipActivation = nil } else if list.activeID != id { lastActive[id] = Date() }
            list.activate(id)
        }
        if intendedActive === tab { intendedActive = nil }
        refresh()
        changed()
        syncNewTab(activated: true)
        app.tabActivated(tab)
    }

    func window(_ window: NCWindow, didClose tab: NCTab) {
        let successor = closeNext.removeValue(forKey: tab.identifier)
        var gone: (item: TabItem, index: Int)?
        if let id = ids[tab.identifier], let i = list.items.firstIndex(where: { $0.id == id }) {
            gone = (list.items[i], i)
            _ = list.remove(id)
        }
        tabs[tab.identifier] = nil
        ids[tab.identifier] = nil
        typedLoads[tab.identifier] = nil
        recordedTitle[tab.identifier] = nil
        failed[tab.identifier] = nil
        closing[tab.identifier] = nil
        if intendedActive === tab { intendedActive = nil }
        // The close is confirmed: the selection moves to the tab chosen when it was asked for.
        if let next = survivor(from: successor) { intendedActive = next; window.activateTab(next) }
        refresh()
        // The tab closed alone (Cmd+W, its close button, the page): it goes on the closed list. Closing with its window or at quit does not.
        if let gone, !windowClosing, !app.closing { app.writer?.closed(tab: gone.item, window: id, index: gone.index) }
        app.tabClosed(tab)
    }

    /// The page refused to close (beforeunload answered Stay): the tab stays, selected as it was.
    func window(_ window: NCWindow, didCancelCloseOf tab: NCTab) {
        // A window close that a page refused is over: later Cmd+W closes are closed tabs again.
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_STICKY_CLOSING"] != "1" { windowClosing = false }  // negative control: the old sticky flag
#else
        windowClosing = false
#endif
        closing[tab.identifier] = nil
        closeNext[tab.identifier] = nil
    }

    func window(_ window: NCWindow, didUpdate tab: NCTab) {
        // The next committed navigation of the tab, whatever caused it, ends the failed display.
        if let f = failed[tab.identifier], tab.url != f.shown, tab.url != f.url { failed[tab.identifier] = nil }
        if let id = ids[tab.identifier] { list.update(id, url: shownURL(tab), title: tab.title, isLoading: tab.isLoading) }
        recordTitle(tab)
        refresh()
        changed()
        syncNewTab(activated: false)
        app.tabUpdated(tab)
    }

    func window(_ window: NCWindow, tab: NCTab, didFinishLoadWithStatus status: Int) {
        recordVisit(tab, status: status)
        app.tabLoaded(tab, status: status)
    }

    func window(_ window: NCWindow, tab: NCTab, didFailLoadWithCode code: Int, url: String) {
        // Every terminal outcome ends a typed load. An abort ends it only when it is the abort of the typed address itself (a typed load replaced
        // by a later typed one must not lose the later mark); an error always does.
        func bare(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        if code != -3 || typedLoads[tab.identifier].map({ bare($0) == bare(url) }) == true {
#if NOCHE_TESTHOOKS
            if !(code == -3 && ProcessInfo.processInfo.environment["NOCHE_TEST_TYPED_STICKY"] == "1") { typedLoads[tab.identifier] = nil }  // negative control: an abort leaves the mark
#else
            typedLoads[tab.identifier] = nil
#endif
        }
        guard code != -3 else { return }  // ERR_ABORTED: a navigation replaced by another, not a failure
        failed[tab.identifier] = (url, tab.url)
        if let id = ids[tab.identifier] { list.update(id, url: url, title: tab.title, isLoading: false) }
        refresh()
        app.tabLoadFailed(code: code)
    }

    /// Chrome commands that duplicate a Noche action run the Noche action and are answered YES.
    func window(_ window: NCWindow, handlePreemptedKey event: NSEvent) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }

    func window(_ window: NCWindow, shouldHandleChromeCommand commandId: Int) -> Bool {
#if NOCHE_TESTHOOKS
        Self.commandLog.append(commandId)
#endif
        switch commandId {
        case ChromeCommand.newTab: newTab()
        case ChromeCommand.closeTab: closeActiveTab()
        case ChromeCommand.selectNextTab: selectNextTab()
        case ChromeCommand.selectPreviousTab: selectPreviousTab()
        case ChromeCommand.selectTab0...ChromeCommand.selectTab0 + 7 where ChromeCommand.selectTab0 >= 0: selectTab(at: commandId - ChromeCommand.selectTab0)
        case ChromeCommand.selectLastTab: selectTab(at: nil)
        case ChromeCommand.moveTabNext: moveTab(1)
        case ChromeCommand.moveTabPrevious: moveTab(-1)
        case ChromeCommand.newWindow: app.newWindowAction()
        case ChromeCommand.restoreTab: app.reopenClosedTab(nil)
        case ChromeCommand.closeWindow: close()
        case ChromeCommand.back: goBack()
        case ChromeCommand.forward: goForward()
        case ChromeCommand.reload: reload()
        case ChromeCommand.reloadBypassingCache, ChromeCommand.reloadClearingCache: forceReload()
        case ChromeCommand.focusLocation:
            if BarHook.on("BAR_NOFOCUSLOC") { return false }  // negative control: the engine's focus-location command is not answered
            focusAddress()
        case ChromeCommand.zoomPlus: zoom(0.5)
        case ChromeCommand.zoomMinus: zoom(-0.5)
        case ChromeCommand.zoomNormal: zoom(nil)
        case ChromeCommand.devTools: showDevTools()
        default: return false
        }
        return true
    }

#if NOCHE_TESTHOOKS
    func testBeginWindowClose() { windowClosing = true }  // what close() sets, without closing the window
#endif

    func windowDidClose(_ window: NCWindow) {
        animationTimer?.invalidate()
        madeCommandBar?.teardown()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        app.controllerClosed(self)
    }
}
