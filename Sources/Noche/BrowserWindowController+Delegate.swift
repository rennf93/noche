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
        // A dormant tab waking (a click, Cmd+1, a reset), or a restored tab that came after the fallback: the tab is in the list already
        // and takes the engine tab, keeping its place.
        if let pending, let t = item(withID: pending.id) {
            list.setEngineID(t.id, tab.identifier)
            list.update(t.id, url: pending.url, title: t.title, isLoading: tab.isLoading)
            if active { list.markActive(t.id, at: Date()) }
            dormantIcons[t.id] = nil
            refresh()
            changed()
            syncNewTab(activated: active)
            app.tabAdded(tab)
            return
        }
        // The new tab goes right after the tab before it in the engine's strip (a popup after its opener); one the engine appended goes
        // last in the list, which can differ from the strip after a reopen put a tab in the middle.
        let strip = window.tabs
        let at = strip.firstIndex(where: { $0 === tab })
        let before = at.flatMap { $0 > 0 && $0 < strip.count - 1 ? strip[$0 - 1] : nil }
        var added = item(for: tab)
        if let pending { added.url = pending.url }   // the saved address until the engine reports its own
        if let saved = pending?.item {
            added.lastActiveAt = saved.lastActiveAt   // a restored tab keeps its stamp
            if pending?.index != nil {                 // a reopened tab keeps its pin, group and titles too
                added.isPinned = saved.isPinned; added.inGrid = saved.inGrid; added.pinnedURL = saved.pinnedURL
                added.groupID = saved.groupID; added.customTitle = saved.customTitle; added.customIcon = saved.customIcon
            }
        }
        list.insertNew(added, opener: before.flatMap { ids[$0.identifier] }, addToTop: false, activate: active)
        if let at = pending?.index { list.move(added.id, to: at) }  // the index is inside the tab's own container (|containerIndex|)
        if let restore {
            if !restoreStarted {
                restoreStarted = true
                for (n, p) in restoreRest.enumerated() {
#if NOCHE_TESTHOOKS
                    if Self.holdLastRestoreTab, n == restoreRest.count - 1 { continue }  // pin-launch-held: this tab never arrives
#endif
                    if let t = window.addTab(withURL: p.url, activate: false) { pendingByTab[t.identifier] = p }
                }
            }
            if let pending, pending.index == nil {
                restoreAdded += 1
                if added.id == restore.selected, !active { skipActivation = added.id; window.activateTab(tab); intendedActive = tab }
                if restoreAdded == restore.tabs.count { finishRestore() }
            }
        }
        refresh()
        changed()
        // The window's own first tab is never announced as an activation.
        if active, list.items.count == 1 { syncNewTab(activated: true) }
        app.tabAdded(tab)
    }

    /// Every saved tab is in, or the wait ran out: the saved structure goes onto the list and the restore ends.
    func finishRestore() {
        guard let r = restore else { return }
        if !BarHook.on("RESTORE_FLAT") { applySavedStructure(r) }  // negative control: the tabs stay the day tabs they were added as
        restoring = false
        restore = nil
        if r.isZoomed, !r.fullScreen { nsWindow?.zoom(nil) }
    }

    /// The saved pins, groups, titles and order go back once every saved tab is in: the tabs were added one by one as day tabs. A saved tab
    /// that got no engine tab (a pinned one, which restores dormant, or one that never arrived) is put in as a dormant tab at its saved
    /// address. A window saved with none of them, and every tab in, is left as it is.
    func applySavedStructure(_ r: Restore) {
        let saved = r.order.isEmpty ? r.tabs.map(\.id) : r.order
        let live = Dictionary(uniqueKeysWithValues: list.items.map { ($0.id, $0) })
        let structured = !r.groups.isEmpty || r.items.values.contains(where: { $0.isPinned || $0.groupID != nil || $0.customTitle != nil || $0.customIcon != nil })
        guard structured || saved.contains(where: { live[$0] == nil && r.items[$0] != nil }) else { return }
        var items: [TabItem] = []
        for id in saved {
            if var t = live[id] {
                if let s = r.items[id] {
                    t.isPinned = s.isPinned; t.inGrid = s.inGrid; t.pinnedURL = s.pinnedURL
                    t.groupID = s.groupID; t.customTitle = s.customTitle; t.customIcon = s.customIcon
                }
                items.append(t)
            } else if var s = r.items[id] {
                s.engineID = nil; s.isLoading = false
                items.append(s)
            }
        }
        let placed = Set(saved)
        items += list.items.filter { !placed.contains($0.id) }  // tabs the engine added on its own
        let rebuilt = TabList.restored(items: items, groups: r.groups, topOrder: r.topOrder, dayOrder: r.dayOrder, activeID: list.activeID, current: list)
        if !rebuilt.intact { FileHandle.standardError.write(Data("NOCHE restore: the saved structure was refused; kept every saved tab, groups and order may be lost\n".utf8)) }
        list = rebuilt.list
        for t in list.items where t.engineID == nil { loadDormantIcon(t.id) }
    }

    func window(_ window: NCWindow, didActivate tab: NCTab, previous: NCTab?) {
        if let p = previous, let pid = ids[p.identifier] { leftAt[pid] = Date() }
        if let id = ids[tab.identifier] {
            // Using a tab stamps it; the restore's own activation (and the engine re-announcing the active tab) does not.
            if id == skipActivation { skipActivation = nil; list.activate(id) } else if list.activeID != id { list.markActive(id, at: Date()) }
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
        var dormant = false
        if let id = ids[tab.identifier], let i = list.items.firstIndex(where: { $0.id == id }) {
            let t = list.items[i]
            gone = (t, BarHook.on("REOPEN_FLAT") ? i : (list.containerIndex(of: id) ?? i))  // negative control: the flat position, as before
            if goesDormant(t) {
                dormant = true
                becomeDormant(id, last: tab)
                // The selection moves on as in |remove|, without stamping the tab it lands on.
                if list.activeID == id, let next = survivor(from: successor), let nid = ids[next.identifier] { list.activate(nid) }
            } else {
                _ = list.remove(id)
            }
        }
        tabs[tab.identifier] = nil
        if let id = ids[tab.identifier] { leftAt[id] = nil }
        ids[tab.identifier] = nil
        typedLoads[tab.identifier] = nil
        recordedTitle[tab.identifier] = nil
        flushTitle(tab.identifier)  // a title held back is stored before the tab goes
        titleThrottle.forget(tab.identifier)
        failed[tab.identifier] = nil
        finds[tab.identifier] = nil
        closing[tab.identifier] = nil
        dropPermissionRequests(of: tab)
        if intendedActive === tab { intendedActive = nil }
        // The close is confirmed: the selection moves to the tab chosen when it was asked for.
        if let next = survivor(from: successor) { intendedActive = next; window.activateTab(next) }
        refresh()
        // The tab closed alone (Cmd+W, its close button, the page): it goes on the closed list. Closing with its window or at quit does not.
        if let gone, !dormant, !windowClosing, !app.closing { app.writer?.closed(tab: gone.item, window: id, index: gone.index) }
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
        if let id = ids[tab.identifier] {
            list.update(id, url: shownURL(tab), title: tab.title, isLoading: tab.isLoading)
            list.setDiscarded(id, tab.isDiscarded)
        }
        recordTitle(tab)
        refresh()
        changed()
        syncNewTab(activated: false)
        app.tabUpdated(tab)
    }

    func window(_ window: NCWindow, tab: NCTab, didFinishLoadWithStatus status: Int) {
        recordVisit(tab, status: status)
        if tab === activeTab { syncZoom() }  // the host zoom of the page that loaded
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

    /// A key the bridge claimed before the page: the claimed Escape closes the find pill, any other chord goes through the main menu.
    func window(_ window: NCWindow, handlePreemptedKey event: NSEvent) {
        if event.keyCode == 53 { closeFind(); return }  // the claimed Escape (windowShouldClaimEscape)
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    }

    /// Escape with the page focused closes the find pill: claimed only while the pill shows for the active tab and focus is not in its field (the field handles Escape itself).
    func windowShouldClaimEscape(_ window: NCWindow) -> Bool {
        guard let tab = activeTab, findShownFor == tab.identifier, findBar.field.currentEditor() == nil, !commandBar.isOpen else { return false }
        return true
    }

    /// Chrome commands that duplicate a Noche action run the Noche action and are answered YES.
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
        case ChromeCommand.zoomPlus: zoom(1)
        case ChromeCommand.zoomMinus: zoom(-1)
        case ChromeCommand.zoomNormal: zoom(0)
        case ChromeCommand.devTools: showDevTools()
        case ChromeCommand.showDownloads: app.showDownloads(nil)  // Cmd+Opt+L: Noche's window, not Chromium's page
        case ChromeCommand.showHistory where !BarHook.on("HIST_NOCMD"): app.showHistory(nil)  // Cmd+Y: Noche's window, not Chromium's page
        case ChromeCommand.find: openFind()
        case ChromeCommand.findNext: findStep(forward: true)
        case ChromeCommand.findPrevious: findStep(forward: false)
        case ChromeCommand.closeFindOrStop where findShownFor != nil && !BarHook.on("FIND_NOCLOSECMD"): closeFind()  // only while the pill shows; else the engine stops the load
        default: return false
        }
        return true
    }

#if NOCHE_TESTHOOKS
    func testBeginWindowClose() { windowClosing = true }  // what close() sets, without closing the window
#endif

    func windowDidClose(_ window: NCWindow) {
        animationTimer?.invalidate()
        discardTimer?.invalidate()
        madeCommandBar?.teardown()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if app.revive(self) { return }
        app.controllerClosed(self)
    }
}
