#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Tab cleanup and the archive (M1.6 Task 7c). The clock is injected (`app.cleanup.now`) and every tab's stamp is set against it; the toast is an overlay view, so the
/// checks click its Undo button directly (a hidden window is never key, G5).
extension SelfTest {
    func cleanUpKey() { _ = key("k", code: 40, [.command, .option], chars: "k", menuOnly: true) }

    /// Opt+Cmd+K archives only the tabs unused for longer than 7 days, never a pinned one, the active one, one playing audio or one whose page cannot say; a grouped tab keeps
    /// its group, a dormant one is archived with no close call, and none goes on the closed list. The toast says how many, Search Tabs finds each, Undo puts them back where they
    /// were (dormant), restoring the grouped one from Search Tabs puts it back in its group, and the stored threshold (Never, 30 days, 1 day) is read at each run.
    func cleanup() async {
        guard await ready(), let c = ctl, let win, let writer = app.writer else { return }
        let store = writer.store, now = Date(), day = 86_400.0, started = Date()
        func stage(_ n: String) { line("info", "stage \(n) at \(Int(Date().timeIntervalSince(started))) s") }
        app.cleanup.now = { now }
        app.cleanup.timerEnabled = false
        guard await openTabs(8, page: "b.html") else { return finish(false, "8 tabs never appeared (rows \(rowCount))") }
        let audioURL = fixture("audio.html"), crossURL = fixture("media-host.html?src=" + fixture("b.html").replacingOccurrences(of: "127.0.0.1", with: "localhost"))
        _ = win.addTab(withURL: audioURL, activate: false)
        _ = win.addTab(withURL: crossURL, activate: false)
        guard await until(25, { win.tabs.count == 10 && c.list.items.count == 10 && c.list.items.contains { $0.url == audioURL } && c.list.items.contains { $0.url == crossURL } && c.list.items.allSatisfy { !$0.isLoading } }) else { return finish(false, "the audio and frame tabs never loaded") }
        guard let t0 = c.list.items.first(where: { $0.url == fixture("") })?.id, let audio = c.list.items.first(where: { $0.url == audioURL })?.id, let cross = c.list.items.first(where: { $0.url == crossURL })?.id else { return finish(false, "no tab found by address") }
        let plain = Array(c.list.items.filter { $0.url == fixture("b.html") }.map(\.id).reversed())  // opening order
        guard plain.count == 7, c.list.activeID == t0 else { return finish(false, "\(plain.count) plain tabs, active is the first tab \(c.list.activeID == t0), want 7 and true") }
        let (eight, six, seven, pin, grp, dorm, disc) = (plain[0], plain[1], plain[2], plain[3], plain[4], plain[5], plain[6])
        for (id, name) in [(eight, "zday"), (six, "zsix"), (seven, "zseven"), (pin, "zpin"), (grp, "zgrp"), (dorm, "zdorm"), (disc, "zdisc"), (audio, "zplay"), (cross, "zframe")] { c.renameTab(id, to: name) }
        guard let g = c.list.createGroup(with: grp) else { return finish(false, "no group") }
        _ = c.list.setGroup(six, g)
        c.refresh(); c.changed()
        c.togglePin(of: pin)
        guard await pinned(c, pin, true) else { return finish(false, "the tab did not pin") }
        // A dormant day tab: pinned, closed (the pin goes dormant), unpinned.
        c.togglePin(of: dorm)
        guard await pinned(c, dorm, true), let row = c.list.items.firstIndex(where: { $0.id == dorm }) else { return finish(false, "the tab to make dormant did not pin") }
        c.closeRow(row)
        guard await until(10, { self.entry(c, dorm)?.engineID == nil }) else { return finish(false, "the pinned tab did not go dormant") }
        c.togglePin(of: dorm)
        guard await pinned(c, dorm, false), entry(c, dorm)?.engineID == nil else { return finish(false, "the dormant tab did not unpin (still dormant: \(entry(c, dorm)?.engineID == nil))") }
        guard await discardNow(c, disc) else { return finish(false, "the tab to discard was not reported discarded") }
        guard let audioTab = c.engineTab(entry(c, audio)!) else { return finish(false, "no engine tab for the audio page") }
        guard await until(10, { self.entry(c, audio)?.title == "Audio Page" }) else { return finish(false, "the audio page never loaded") }
        _ = await evaluate(audioTab, "document.getElementById('a').play().catch(e => { window.__playErr = String(e) }); 1")
        var playing = false
        for _ in 0..<100 where !playing { playing = await c.isPlayingMedia(audioTab) == true; if !playing { try? await Task.sleep(for: .milliseconds(100)) } }
        guard playing else { return finish(false, "the audio element is not playing (play error \(await evaluate(audioTab, "String(window.__playErr)") ?? "nil"))") }
        try? await Task.sleep(for: .milliseconds(1500))  // the cross-origin frame's own load
        // Last used: 8 days ago (the day tab, the grouped, the dormant, the discarded, the audio and the frame tab), 6 days, exactly 7 days, a pinned one 30 days ago, and the first tab now.
        for (id, days) in [(eight, 8.0), (six, 6), (seven, 7), (pin, 30), (grp, 8), (dorm, 8), (disc, 8), (audio, 8), (cross, 8)] { c.list.markActive(id, at: now.addingTimeInterval(-days * day)) }
        c.list.markActive(t0, at: now)  // the active tab (markActive also selects it in the list, as it was)
        c.refresh(); c.changed()
        let itemsBefore = c.list.items.map(\.id), dayBefore = c.list.dayOrder, engineBefore = win.tabs.count
        let all = Set(itemsBefore), toArchive: Set<TabID> = [eight, grp, dorm, disc]
        func archivedSet() -> Set<TabID> { Set(((try? store.archivedTabs(matching: "")) ?? []).map(\.tab.id)) }
        var toastLifetime: TimeInterval?
        func run(toast wanted: Bool, _ what: String) async -> Bool {
            let before = c.cleanupRuns
            c.toast.hide()
            cleanUpKey()
            guard await until(40, { c.cleanupRuns == before + 1 }) else { finish(false, "\(what): Opt+Cmd+K ran no cleanup (keys \(keyLog.suffix(1)))"); return false }
            try? await Task.sleep(for: .milliseconds(200))
            if c.toast.isHidden != wanted {
                if wanted { toastLifetime = c.toast.timer?.isValid == true ? c.toast.timer?.fireDate.timeIntervalSinceNow : nil; c.toast.timer?.invalidate() }  // a slow machine must not expire it under the check; the expiry is tested below
                return true
            }
            finish(false, "\(what): the toast is \(c.toast.isHidden ? "hidden" : "shown: \(c.toast.label.stringValue)"), want it \(wanted ? "shown" : "hidden")")
            return false
        }

        stage("setup done")
        // Default (7 days): one frame tab cannot answer (an injected attach error), so it is skipped.
        BrowserWindowController.archiveCloseCalls = []
        BrowserWindowController.testFailAttach = true
        guard await run(toast: true, "7 days") else { return }
        BrowserWindowController.testFailAttach = false
        guard archivedSet() == toArchive else { return finish(false, "7 days: archived \(archivedSet().map { entry(c, $0)?.customTitle ?? "?" }), want exactly the 8 day tab, the grouped, the dormant and the discarded tab (not the 6 day, the exactly 7 day, the pinned, the active, the audio or the frame tab)") }
        for a in (try? store.archivedTabs(matching: "")) ?? [] {
            guard abs((a.tab.archivedAt ?? .distantPast).timeIntervalSince(now)) < 0.01 else { return finish(false, "an archived tab has archivedAt \(String(describing: a.tab.archivedAt)), want the injected clock \(now)") }
            if a.tab.id == grp { guard a.tab.groupID == g else { return finish(false, "the grouped tab was archived with group \(String(describing: a.tab.groupID)), want \(g)") } }
        }
        guard Set(c.list.items.map(\.id)) == all.subtracting(toArchive) else { return finish(false, "after cleanup the list holds \(c.list.items.compactMap { $0.customTitle }), want it without the archived four") }
        guard await until(15, { win.tabs.count == engineBefore - 3 && c.sidebar.rows.allSatisfy { !($0.tabID.map(toArchive.contains) ?? false) } }) else { return finish(false, "after cleanup \(win.tabs.count) engine tabs (want \(engineBefore - 3)), rows of archived tabs still drawn \(c.sidebar.rows.filter { ($0.tabID.map(toArchive.contains) ?? false) }.count)") }
        let closes = BrowserWindowController.archiveCloseCalls
        guard Set(closes) == [eight, grp, disc], closes.count == 3 else { return finish(false, "cleanup closed \(closes.map { entry(c, $0)?.customTitle ?? "gone" }), want the loaded three (the dormant tab has no close call)") }
        try? await Task.sleep(for: .milliseconds(1000))
        guard ((try? store.closedTabs(matching: "")) ?? []).isEmpty, !writer.hasClosed else { return finish(false, "archived tabs are on the closed list: \(((try? store.closedTabs(matching: "")) ?? []).map(\.tab.customTitle))") }
        guard c.toast.label.stringValue == "4 tabs archived", let f = c.frame(ofIdentifier: "toast"), f.width == ChromeStyle.toastWidth, f.height == ChromeStyle.toastHeight, f.maxY <= c.overlay.bounds.height, abs(f.midX - (c.cardX + c.overlay.bounds.width - ChromeStyle.inset) / 2) < 2 else {
            return finish(false, "the toast reads '\(c.toast.label.stringValue)' at \(String(describing: c.frame(ofIdentifier: "toast"))), want '4 tabs archived' 320 by 44 at the bottom of the page card")
        }
        guard let left = toastLifetime, left <= ToastView.lifetime, left > ToastView.lifetime - 3 else { return finish(false, "the toast had a lifetime timer of \(String(describing: toastLifetime)) s, want \(ToastView.lifetime)") }
        stage("7 days run checked")
        // Search Tabs finds each archived tab.
        let card = c.searchTabsCard
        card.open()
        for (name, id) in [("zday", eight), ("zgrp", grp), ("zdorm", dorm), ("zdisc", disc)] {
            card.setQuery(name)
            guard card.results.map(\.id) == [id], case .archived = card.results[0].source else { return finish(false, "Search Tabs for '\(name)' lists \(card.results.map(\.title)), want the archived tab") }
        }
        card.close(restoreFocus: false)
        stage("searched")
        // Undo: every tab back in its container at its index, dormant, out of the archive; the toast goes.
        c.toast.undo.performClick(nil)
        guard c.toast.isHidden, c.list.items.map(\.id) == itemsBefore, c.list.dayOrder == dayBefore else { return finish(false, "after Undo the list is \(c.list.items.compactMap { $0.customTitle }) (want \(itemsBefore.compactMap { entry(c, $0)?.customTitle })), day order equal \(c.list.dayOrder == dayBefore), toast hidden \(c.toast.isHidden)") }
        guard archivedSet().isEmpty, toArchive.allSatisfy({ entry(c, $0)?.engineID == nil && entry(c, $0)?.archivedAt == nil }), entry(c, grp)?.groupID == g, win.tabs.count == engineBefore - 3 else {
            return finish(false, "after Undo the store still archives \(archivedSet().count), or a restored tab is not dormant in its group (group \(String(describing: entry(c, grp)?.groupID)) want \(g), \(win.tabs.count) engine tabs, want \(engineBefore - 3))")
        }
        guard await until(8, { self.stored(grp) != nil && self.stored(eight) != nil }) else { return finish(false, "the restored tabs are not in the store's window") }

        stage("undone")
        // No candidate: nothing changes and no toast. Never archives nothing; 30 days has no tab that old (the pinned tab is never one).
        for (value, label) in [("never", "Never"), ("30d", "30 days")] {
            guard setSetting("cleanupThreshold", value) else { return finish(false, "could not store the setting") }
            guard await run(toast: false, label), archivedSet().isEmpty, c.list.items.map(\.id) == itemsBefore else { return finish(false, "\(label): archived \(archivedSet().count), list changed \(c.list.items.map(\.id) != itemsBefore)") }
        }
        stage("never and 30d")
        // 7 days again, nothing injected: the frame tab can answer (nothing plays) and is archived with the others; the audio tab stays. Restoring the grouped tab from
        // Search Tabs puts it back in its group (at the end).
        guard setSetting("cleanupThreshold", "7d") else { return finish(false, "could not store the setting") }
        guard await run(toast: true, "7 days again") else { return }
        guard archivedSet() == toArchive.union([cross]) else { return finish(false, "7 days with every page answering: archived \(archivedSet().map { entry(c, $0)?.customTitle ?? "?" }), want the four and the frame tab") }
        guard c.toast.label.stringValue == "5 tabs archived" else { return finish(false, "the toast reads '\(c.toast.label.stringValue)', want '5 tabs archived'") }
        card.open()
        card.setQuery("zgrp")
        guard card.results.map(\.id) == [grp] else { return finish(false, "Search Tabs for 'zgrp' lists \(card.results.map(\.title))") }
        card.commit()
        guard await until(20, { self.entry(c, grp)?.engineID != nil && win.tabs.count == engineBefore - 3 }), entry(c, grp)?.groupID == g, c.list.items.filter({ $0.groupID == g }).map(\.id) == [six, grp] else {
            return finish(false, "restoring the grouped tab from Search Tabs: group \(String(describing: entry(c, grp)?.groupID)) want \(g), members \(c.list.items.filter { $0.groupID == g }.compactMap(\.customTitle)), want [zsix, zgrp]")
        }
        stage("restored from search")
        // 1 day: the setting is read at each run; the 6 and the exactly 7 day tabs go now (the restored one was used just now).
        guard setSetting("cleanupThreshold", "1d") else { return finish(false, "could not store the setting") }
        guard await run(toast: true, "1 day"), archivedSet().isSuperset(of: [six, seven]), !archivedSet().contains(grp), !archivedSet().contains(pin), !archivedSet().contains(audio), c.toast.label.stringValue == "2 tabs archived" else {
            return finish(false, "1 day: \(archivedSet().count) tabs archived in all, toast '\(c.toast.label.stringValue)', want the 6 and the 7 day tabs only (2)")
        }
        // The toast's lifetime: its timer hides it.
        c.toast.show("lifetime") {}
        guard let timer = c.toast.timer, timer.isValid, abs(timer.fireDate.timeIntervalSinceNow - ToastView.lifetime) < 1 else { return finish(false, "a new toast has no lifetime timer") }
        timer.fire()
        guard c.toast.isHidden else { return finish(false, "the toast stayed after its lifetime ended") }
        finish(violations.isEmpty, "Opt+Cmd+K at 7 days archived only the 8 day day tab, the grouped one (group kept), the dormant one (no close call) and the discarded one, none on the closed list, and skipped the 6 day, the exactly 7 day, the pinned, the active, the audio and an unanswerable frame tab; the toast read '4 tabs archived' and Search Tabs found each; Undo put them back dormant at their indexes; Never and 30 days archived nothing with no toast; 7 days with every page answering archived the frame tab too and a restore from Search Tabs put the grouped tab back in its group; 1 day archived the 6 and 7 day tabs; the toast hides after \(Int(ToastView.lifetime)) s \(violations)")
    }

    // MARK: auto-cleanup

    /// Automatic cleanup. Phase 1 stamps two tabs 8 days old (the first tab stays fresh and active) and quits. Phase 2, the relaunch: the launch run archives them after the restore (once);
    /// then with the clock injected: an hour later the job runs once, not twice and not before the hour; typing in the last 10 s and a presentation hold it back (it runs when they end);
    /// an archived tab past 30 days is tombstoned by the hourly run, also with the threshold Never.
    func autoCleanup() async {
        let day = 86_400.0
        if phase == 1 {
            guard await ready(), let c = ctl, let writer = app.writer else { return }
            app.cleanup.timerEnabled = false
            guard await openTabs(4, page: "b.html") else { return finish(false, "phase 1: 4 tabs never appeared (rows \(rowCount))") }
            let ids = Array(c.list.items.map(\.id).reversed())  // opening order: the first tab, then three
            guard let first = c.list.items.first(where: { $0.url == fixture("") })?.id else { return finish(false, "phase 1: no first tab") }
            let others = ids.filter { $0 != first }
            for (n, id) in others.enumerated() { c.renameTab(id, to: ["zold1", "zold2", "zfresh"][n]) }
            let now = Date()
            for id in others.prefix(2) { c.list.markActive(id, at: now.addingTimeInterval(-8 * day)) }
            c.list.markActive(others[2], at: now)
            c.list.markActive(first, at: now)
            c.refresh(); c.changed()
            writer.flush()
            return finish(violations.isEmpty, "phase 1: two tabs stamped 8 days old, two fresh, saved; quitting \(violations)")
        }
        guard await until(30, { self.restoredUp(1) }), let c = ctl, let writer = app.writer else { return finish(false, "phase 2: no restored window") }
        let store = writer.store
        guard await until(30, { self.app.cleanup.runCount >= 1 }) else { return finish(false, "phase 2: the launch run never happened (runs \(app.cleanup.runCount), tabs \(c.list.items.count))") }
        app.cleanup.timerEnabled = false
        func archivedNames() -> [String] { ((try? store.archivedTabs(matching: "")) ?? []).compactMap(\.tab.customTitle).sorted() }
        guard app.cleanup.runCount == 1, app.cleanup.lastRunAfterRestore, archivedNames() == ["zold1", "zold2"] else {
            return finish(false, "the launch run: \(app.cleanup.runCount) runs, after the restore \(app.cleanup.lastRunAfterRestore), archived \(archivedNames()), list \(c.list.items.compactMap(\.customTitle)) (\(c.list.items.count) tabs), want one run after the restore that archived zold1 and zold2")
        }
        guard c.list.items.count == 2, c.list.items.contains(where: { $0.customTitle == "zfresh" }) else { return finish(false, "after the launch run the list holds \(c.list.items.compactMap(\.customTitle)) (\(c.list.items.count) tabs), want the first tab and zfresh") }
        guard let base = app.cleanup.lastRun else { return finish(false, "no last run") }
        var clock = base
        app.cleanup.now = { clock }
        var presenting = false
        app.cleanup.presenting = { presenting }
        let hour = CleanupPolicy.interval
        let fresh = c.list.items.first { $0.customTitle == "zfresh" }!.id, first = c.list.items.first { $0.customTitle != "zfresh" }!.id
        func ticked() async -> Bool { await app.cleanup.tick() }

        // An hour later the job runs once; ticks before the hour and a second tick after it run nothing.
        clock = base.addingTimeInterval(hour - 60)
        guard await ticked() == false, app.cleanup.runCount == 1 else { return finish(false, "a tick 59 minutes after the launch run ran the job (\(app.cleanup.runCount) runs)") }
        clock = base.addingTimeInterval(hour)
        guard await ticked(), app.cleanup.runCount == 2, await ticked() == false, app.cleanup.runCount == 2 else { return finish(false, "an hour after the launch run the job ran \(app.cleanup.runCount - 1) times, want once (a second tick must not run it)") }

        // Typing in the last 10 s holds the job back; it runs once the 10 s have passed. A key pressed in Noche counts (the real monitor).
        clock = base.addingTimeInterval(2 * hour)
        c.list.markActive(fresh, at: clock.addingTimeInterval(-8 * day))
        c.list.markActive(first, at: clock)  // the first tab is selected again
        c.refresh(); c.changed()
        sendKey("x", code: 7, [])
        guard app.cleanup.lastTypedAt == clock else { return finish(false, "a key pressed in Noche was not recorded as typing (last typed \(String(describing: app.cleanup.lastTypedAt)), want \(clock))") }
        guard await ticked() == false, app.cleanup.runCount == 2 else { return finish(false, "the job ran with a key typed 0 s ago") }
        clock = clock.addingTimeInterval(9)
        guard await ticked() == false, app.cleanup.runCount == 2 else { return finish(false, "the job ran 9 s after typing") }
        // Presenting holds it back too, and the job stays due.
        clock = clock.addingTimeInterval(2)
        presenting = true
        guard await ticked() == false, app.cleanup.runCount == 2, entry(c, fresh) != nil else { return finish(false, "the job ran while presenting (\(app.cleanup.runCount) runs)") }
        presenting = false
        guard await ticked(), app.cleanup.runCount == 3, await until(15, { self.entry(c, fresh) == nil }), archivedNames() == ["zfresh", "zold1", "zold2"] else { return finish(false, "after typing and the presentation ended the job ran \(app.cleanup.runCount - 2) times and archived \(archivedNames()), want once, with zfresh archived too") }

        // Retention: zold1 and zold2 were archived at the launch run (30 days and an hour ago now), zfresh two hours and 11 s after it (29 days 22 hours ago): the hourly run
        // tombstones the first two only, whatever the threshold.
        clock = base.addingTimeInterval(30 * day + hour)
        guard await ticked(), app.cleanup.runCount == 4, archivedNames() == ["zfresh"] else { return finish(false, "the hourly run past 30 days left \(archivedNames()) archived, want only zfresh (zold1 and zold2 tombstoned)") }
        guard setSetting("cleanupThreshold", "never") else { return finish(false, "could not store the setting") }
        clock = base.addingTimeInterval(30 * day + 3 * hour)
        guard await ticked(), app.cleanup.runCount == 5, archivedNames().isEmpty else { return finish(false, "with Never the hourly run left \(archivedNames()) archived, want zfresh tombstoned too") }
        // The real presentation provider answers (the owner's Mac decides what: the check only asks that it does not fault).
        line("info", "SystemPresentation.isPresenting() on this Mac: \(SystemPresentation.isPresenting())")
        finish(violations.isEmpty, "phase 2: the launch run came once, after the restore, and archived the two 8 day tabs; no run 59 minutes later, one run at the hour, none on a second tick; a key typed in Noche and a presentation held the job back and it ran once they ended; an archived tab past 30 days was tombstoned by the hourly run, with Never too \(violations)")
    }
}
#endif
