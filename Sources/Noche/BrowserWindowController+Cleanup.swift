import AppKit
import CefBridge
import NocheCore

/// Tab cleanup (M1.6 Task 7c, spec rows 101 to 103): tabs not used for longer than `cleanupThreshold` are archived, by File > Clean Up Tabs
/// (Opt+Cmd+K, with a toast and Undo) and by `CleanupService` (at launch and hourly, no toast). An archived tab leaves the list and its engine tab
/// closes without a closed-list entry; the store keeps its row (window, group, address, titles) and Search Tabs lists it under Archived.
extension BrowserWindowController {
    /// A tab of a cleanup run as it left the list: the item (group id kept) and its index inside its container, for Undo.
    struct ArchivedTab { let item: TabItem; let index: Int }

    /// The threshold in seconds (default 7 days); nil is Never.
    var cleanupThreshold: TimeInterval? {
        SettingKeys.cleanupThreshold(stored: BarHook.on("CLEANUP_IGNORESETTING") ? nil : (try? app.writer?.store.setting("cleanupThreshold")).flatMap { $0 })  // the hook: the stored value is never read
    }

    /// File > Clean Up Tabs: archives this window's stale tabs now and says how many, with Undo. No candidate: nothing changes and no toast.
    func cleanUpTabsCommand() {
        note("cleanUpTabs")
        Task { @MainActor in await cleanUpTabs(now: app.cleanup.now(), toast: true) }
    }

    /// Archives the tabs unused for longer than the threshold at |now|: never a pinned, active, loading or closing tab, nor one whose page is playing
    /// media or cannot say (a loaded tab is asked, a dormant or discarded one has no page and is not). The window is saved first, the store archives
    /// the rows, the tabs leave the list and each engine tab closes without a closed-list entry. |toast| shows the count with Undo. Returns how many.
    @discardableResult
    func cleanUpTabs(now: Date, toast showToast: Bool) async -> Int {
        // A pass already running (the hourly job, the command) finishes first and this one runs right after it: never skipped, never silent (the hook: the old guard).
        while cleaning {
            if BarHook.on("CLEANUP_NOWAITBUSY") { return 0 }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard installed, !restoring, !app.closing, let writer = app.writer else { return 0 }
        let threshold = cleanupThreshold  // nil is Never: no candidate, the run still counts
        cleaning = true
        defer { cleaning = false; cleanupRuns += 1 }
        // The media question shares the discard sweep's DevTools sessions: one at a time.
        while sweeping { try? await Task.sleep(for: .milliseconds(200)) }
        sweeping = true
        defer { sweeping = false }
        func candidates() -> [TabID] {
            let busy = Set(list.items.filter { t in engineTab(t).map { isClosing($0) || $0 === window.activeTab || $0 === intendedActive } ?? false }.map(\.id))
            return list.cleanupCandidates(now: now, threshold: BarHook.on("CLEANUP_BOUNDARY") ? threshold.map { $0 - 1 } : threshold, excluding: busy)  // the hook: a tab used exactly the threshold ago goes too
        }
        var asked: [TabID: Int] = [:]  // the engine id the page was asked on (-1: no page to ask)
        for id in candidates() {
            guard let t = item(withID: id) else { continue }
            // A loaded page is asked; a dormant tab has none and a discarded one gave its page back (the hook asks it too).
            if let tab = engineTab(t), !t.isDiscarded || BarHook.on("CLEANUP_ASKDISCARDED"), !BarHook.on("CLEANUP_NOMEDIA") {
                let playing = await isPlayingMedia(tab)
                if BarHook.on("CLEANUP_UNKNOWNOK") ? playing == true : playing != false { continue }  // playing, or the page could not say: skipped (the hook: only a yes skips)
            }
            asked[id] = engineTab(t)?.identifier ?? -1
        }
        // The pages answered over some time: a tab used, closed or loading since is not a candidate any more, and one whose engine tab changed was not asked.
        let wanted = candidates().filter { id in item(withID: id).map { asked[id] == (engineTab($0)?.identifier ?? -1) } ?? false }
        guard !wanted.isEmpty else { return 0 }
        writer.saveNow([id])
        do { try writer.store.archive(ids: wanted, at: now) } catch {
            FileHandle.standardError.write(Data("NOCHE cleanup: archive failed: \(error)\n".utf8))
            return 0
        }
        var gone: [ArchivedTab] = []
        for id in wanted {
            guard let t = item(withID: id) else { continue }
            gone.append(ArchivedTab(item: t, index: list.containerIndex(of: id) ?? 0))
            let tab = engineTab(t)
            _ = list.extract(id)
            leftAt[id] = nil; dormantIcons[id] = nil; faviconSeeds[id] = nil
#if NOCHE_TESTHOOKS
            if BarHook.on("CLEANUP_CLOSEDLIST"), !gone.isEmpty { writer.closed(tab: t, window: self.id, index: gone[gone.count - 1].index) }  // the hook: the closed list gets the tab
            if tab != nil || BarHook.on("CLEANUP_CLOSEDORMANT") { Self.archiveCloseCalls.append(id) }  // the hook: a dormant tab counts as closed too
#endif
            if let tab {  // a dormant tab has no engine tab and no close call
                closing[tab.identifier] = ProcessInfo.processInfo.systemUptime
                tab.close()
            }
        }
        refresh()
        changed()
        if showToast, !gone.isEmpty, !BarHook.on("CLEANUP_NOTOAST") {
            toast.show(gone.count == 1 ? "1 tab archived" : "\(gone.count) tabs archived") { [weak self] in if !BarHook.on("CLEANUP_NOUNDO") { self?.undoCleanup(gone) } }  // the hook: Undo does nothing
        }
        return gone.count
    }

    /// Undo of a run: one store transaction takes the tabs out of the archive and each comes back dormant to the container it left, at its index
    /// (a group that is gone since means the day list), in the reverse of the order they left so every index is what it was. A tab whose id is in the list
    /// already stays archived (the store and the list agree) and the others are restored. Each restored tab is stamped as used now (the run's clock), so the next
    /// hourly run does not archive it again.
    func undoCleanup(_ run: [ArchivedTab]) {
        let ids = run.map(\.item.id).filter { item(withID: $0) == nil }
        guard let store = app.writer?.store, let back = try? store.restoreArchived(ids: ids) else { return }
        let stamp = app.cleanup.now()
        let byID = Dictionary(back.map { ($0.tab.id, $0) }, uniquingKeysWith: { a, _ in a })
        for a in run.reversed() {
            guard let r = byID[a.item.id] else { continue }
            var tab = r.tab
            if !BarHook.on("CLEANUP_NOSTAMP") { tab.lastActiveAt = stamp }  // the hook: the restored tab keeps its old stamp
            guard list.insertNew(tab, opener: nil, addToTop: true, activate: false) else { continue }
            if !BarHook.on("CLEANUP_UNDOTOP") { list.move(a.item.id, to: a.index) }  // the hook: the tab stays where the restore put it (the top of the day list)
            if let icon = r.faviconURL { faviconSeeds[a.item.id] = (r.tab.url, icon); loadDormantIcon(a.item.id) }
        }
        refresh()
        changed()
    }
}
