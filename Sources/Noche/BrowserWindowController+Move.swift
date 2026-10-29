import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Move to Window and Merge All Windows (M1.6 Task 5b). A move is not a close: the tab or group leaves this window's list (the engine tab of a
/// loaded tab closes, with back, forward and scroll: README known limit), arrives in the other window with the same `TabID` or `GroupID`
/// (a loaded tab through `pendingByTab`, so the destination's engine tab takes the id), and neither window's store loses it.
extension BrowserWindowController {
    /// Every window is the default profile until M1.7 gives windows their own: a move and a merge stay inside one.
    var profileID: String { "default" }
    /// This window gave items to a new window that has not saved yet: it is not a destination or a merge target until it has (a short wait, normally
    /// about a second), because its own save is held and would leave what arrives in no window.
    var isHeld: Bool { app.writer?.holds[id] != nil }
    func sameProfile(_ other: BrowserWindowController) -> Bool { other.profileID == profileID }

    enum Movable { case tab(TabID), group(GroupID) }
    enum Piece { case tab(TabItem), group(TabGroup, [TabItem]) }

    /// What leaves a window, as the destination takes it: dormant copies of the items in landing order, the ones that had an engine tab (they
    /// load again at their address; a merge sends none), the one to activate and the icons.
    struct Departure {
        var pieces: [Piece] = []
        var loaded: [(id: TabID, url: String)] = []
        var active: TabID?
        var favicons: [TabID: String] = [:]
        var images: [TabID: NSImage] = [:]
        var items: [TabItem] {
            pieces.flatMap { p -> [TabItem] in
                switch p {
                case .tab(let t): return [t]
                case .group(_, let kids): return kids
                }
            }
        }
        var groups: [TabGroup] {
            pieces.compactMap { p -> TabGroup? in
                if case .group(let g, _) = p { return g }
                return nil
            }
        }
    }

    /// The title the Move to Window menus give this window: its active tab's.
    var windowMenuTitle: String { list.activeID.map { list.displayTitle(of: $0) } ?? "New Tab" }

    // MARK: menu

    /// What both Move to Window menus list: this window (checked, disabled), the other windows of the profile by their active tab's title, a
    /// separator and New Window with one row per profile (only the window's own profile is live: a move across profiles is Move to Profile, M1.7).
    func moveToWindowEntries(_ what: Movable) -> [CtxEntry] {
        typealias E = CtxEntry
        let others = app.windowsFrontToBack.filter { $0 !== self && sameProfile($0) }
        let profiles = app.profileChoices.map { p -> E in
            p.own ? E(title: p.name, run: { [weak self] in self?.move(what, to: nil) }) : .later(p.name, "M1.7")
        }
        return [E(title: windowMenuTitle, run: {}, enabled: false, checked: true)]
            + others.map { w in E(title: w.windowMenuTitle, run: { [weak self, weak w] in if let w { self?.move(what, to: w) } }, enabled: !w.restoring && !w.isHeld) }
            + [.sep, E(title: "New Window", run: {}, children: profiles)]
    }

    // MARK: moving

    /// Moves a tab or a group to |target|, or to a new window with nil. Nothing happens for a window that is still restoring, closing or held.
    func move(_ what: Movable, to target: BrowserWindowController?) {
        note("moveToWindow")
        if BarHook.on("MOVE_NOOP") { return }  // negative control: the menu item does nothing
        guard !restoring, !windowClosing, !app.closing, target.map({ $0 !== self && !$0.restoring && !$0.windowClosing && (!$0.isHeld || BarHook.on("MOVE_HELDDEST")) && sameProfile($0) }) ?? true,
              let d = leave(what) else { return }
        let giving = list.items.isEmpty
        if let target {
            target.receive(d)
            changed()
            app.writer?.saveNow(BarHook.on("MOVE_SRCFIRST") ? [id, target.id] : [target.id] + (giving ? [] : [id]))  // the destination first: the rows re-home to it before this window drops what it gave up (the hook: the source first)
            if BarHook.on("MOVE_ASCLOSE") { for l in d.loaded { d.items.first { $0.id == l.id }.map { app.writer?.closed(tab: $0, window: id, index: 0) } } }  // negative control: a moved tab is a closed one
            if giving, !BarHook.on("MOVE_NOGIVEUP") { giveUp() }  // the hook: the window that gave everything up stays open
            app.bringForward(target)
        } else {
            let frame = app.cascadedFrame(from: nsWindow?.frame)
            let new = app.newWindow(for: d, frame: frame)
            // This window waits for every new window it gave to (a set: a second move must not drop the first's wait). Each saves once its restore
            // ended; the last one frees this window to save (or close, which drops its rows, also when it closed meanwhile), so the store never holds
            // the items in neither window: the rows are keyed by id and a save of the new window re-homes them first.
            let app = self.app, source = id
            if !BarHook.on("MOVE_NOHOLD") { app.writer?.hold(source, until: new.id) }  // the hook: never held
            new.afterRestore = { [weak self, weak new] in
                guard let w = app.writer, let new else { return }
                w.saveNow([new.id])
                guard w.release(source, after: new.id) else { return }
                guard let self, !self.windowClosing else { return }
                if giving { if !BarHook.on("MOVE_NOGIVEUP") { self.giveUp() } } else { w.saveNow([source]) }
            }
            changed()
        }
    }

    /// The list change and the engine's part in the window that gives the items up. The engine tabs of loaded items close without a closed-tab
    /// record (they are not in the list any more); the active tab hands over as when it closes, and a window left with only dormant tabs
    /// opens a blank day tab first (the window always keeps an engine tab, T3.1).
    private func leave(_ what: Movable) -> Departure? {
        let wasActive = list.activeID
        let gone: [TabItem], group: TabGroup?, successor: TabID?
        switch what {
        case .tab(let id):
            guard let out = list.extract(id) else { return nil }
            (gone, group, successor) = ([out.item], nil, out.successor)
        case .group(let g):
            guard let out = list.extract(group: g) else { return nil }
            (gone, group, successor) = (out.items, out.group, out.successor)
        }
        var d = Departure()
        let engine = gone.compactMap { t in engineTab(t).map { (item: t, tab: $0) } }
        for t in gone {
            var copy = t
            copy.engineID = nil; copy.isLoading = false
            if let e = engine.first(where: { $0.item.id == t.id }) {
                if !t.isDiscarded || BarHook.on("MOVE_WAKEDISC") { d.loaded.append((t.id, t.url.isEmpty ? "about:blank" : t.url)) }  // a discarded tab moves dormant (its engine tab still closes here); the hook loads it
                if let icon = e.tab.faviconURL { d.favicons[t.id] = icon }
                if let image = e.tab.favicon { d.images[t.id] = image }
            } else {
                if BarHook.on("MOVE_WAKE") { d.loaded.append((t.id, t.url.isEmpty ? "about:blank" : t.url)) }  // negative control: a dormant tab loads in the destination
                if let icon = faviconSeeds[t.id], icon.url == t.url { d.favicons[t.id] = icon.icon }
                if let image = dormantIcons[t.id] { d.images[t.id] = image }
            }
            dormantIcons[t.id] = nil; faviconSeeds[t.id] = nil; leftAt[t.id] = nil
            if group == nil { d.pieces.append(.tab(copy)) }
        }
        if let group { d.pieces.append(.group(group, gone.map { var c = $0; c.engineID = nil; c.isLoading = false; return c })) }
        d.active = d.loaded.contains { $0.id == wasActive } ? wasActive : (BarHook.on("MOVE_GROUPACTIVE") ? d.loaded.last : d.loaded.first)?.id  // the hook: the last loaded tab of a group takes over
        if !list.items.isEmpty, gone.contains(where: { $0.id == wasActive }) {
            closeNext.removeAll()
            if let s = successor, let next = item(withID: s).flatMap(engineTab) {
                intendedActive = next; window.activateTab(next)
            } else {
                intendedActive = window.addTab(withURL: "about:blank", activate: true)
            }
        }
        if !list.items.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            for e in engine { if intendedActive === e.tab { intendedActive = nil }; closing[e.tab.identifier] = now; e.tab.close() }
        }
        refresh()
        return d
    }

    /// This window holds nothing now: it closes as when its last tab closes (the engine tabs go with it, not on the closed list).
    private func giveUp() {
        windowClosing = true
        window.close()
    }

    /// The destination: dormant copies go to the end of their kind of container (a group to the end of its area, a tile to the end of the grid,
    /// a loose tab out of a group to the day list), then each loaded one gets an engine tab at its address that takes its id.
    func receive(_ d: Departure) {
        for piece in d.pieces {
            switch piece {
            case .tab(let t): list.insertNew(t, opener: nil, addToTop: false, activate: false)
            case .group(var g, let kids):
                if BarHook.on("MOVE_NOCOLLAPSE") { g.isCollapsed = false }  // negative control: a moved group opens
                list.adopt(group: g, items: kids)
            }
        }
        for t in d.items {
            if let icon = d.favicons[t.id] { faviconSeeds[t.id] = (t.url, icon) }
            if let image = d.images[t.id] { dormantIcons[t.id] = image }
        }
        closeNext.removeAll()
        for l in d.loaded {
            guard let tab = window.addTab(withURL: l.url, activate: l.id == d.active) else { continue }
            if !BarHook.on("MOVE_NEWID") { pendingByTab[tab.identifier] = PendingTab(id: l.id, url: l.url, index: nil) }  // negative control: the engine tab takes a new id
            if l.id == d.active { intendedActive = tab }
        }
        refresh()
        changed()
    }

    // MARK: merge

    /// Everything this window holds as dormant copies in the order a merge lands it: the grid tiles, the persistent area, then the day list.
    func mergeDeparture() -> Departure {
        var d = Departure()
        func dormant(_ t: TabItem) -> TabItem {
            var c = t
            c.engineID = nil; c.isLoading = false
            if c.isPinned, let pinned = c.pinnedURL { c.url = pinned }  // a pinned tab goes dormant at its pinned page, as when its engine tab closes
            if let tab = engineTab(t) {
                if let icon = tab.faviconURL { d.favicons[t.id] = icon }
                if let image = tab.favicon { d.images[t.id] = image }
            } else {
                if let icon = faviconSeeds[t.id], icon.url == t.url { d.favicons[t.id] = icon.icon }
                if let image = dormantIcons[t.id] { d.images[t.id] = image }
            }
            return c
        }
        func pieces(_ refs: [TopRef]) {
            for r in refs {
                switch r {
                case .tab(let id): if let t = item(withID: id) { d.pieces.append(.tab(dormant(t))) }
                case .group(let g): if let grp = group(withID: g) { d.pieces.append(.group(grp, members(of: g).map(dormant))) }
                }
            }
        }
        for t in list.items where t.isPinned && t.inGrid { d.pieces.append(.tab(dormant(t))) }
        pieces(list.topOrder)
        pieces(list.dayOrder)
        if BarHook.on("MERGE_LOAD") { d.loaded = list.items.filter { engineTab($0) != nil }.map { ($0.id, $0.url) } }  // negative control: the merged tabs load in the target
        return d
    }

    /// Takes every item of |source| into this window, dormant; the caller closes |source| once the store holds them here.
    func absorb(_ source: BrowserWindowController) {
        let d = source.mergeDeparture()
        receive(d)
        source.list = TabList()  // nothing left to save under the source's id
        source.refresh()
    }
}

extension AppDelegate {
    /// Window > Merge All Windows: the front window is the target; every other window of its profile moves in, front to back, all dormant
    /// (their engine tabs close with the windows), so only the target's own loaded tabs stay loaded.
    func mergeAllWindows() {
        guard !closing, let target = active, !target.restoring, !target.windowClosing, !target.isHeld || BarHook.on("MERGE_HELDTARGET") else { return }
        let sources = windowsFrontToBack.filter { $0 !== target && target.sameProfile($0) && !$0.restoring && !$0.windowClosing }
        guard !sources.isEmpty else { return }
        BrowserWindowController.note("mergeAllWindows")
        if BarHook.on("MERGE_NOOP") { return }  // negative control: the menu item does nothing
        for s in sources { target.absorb(s) }
        writer?.saveNow([target.id])   // the store holds everything in the target before a source's rows are dropped with its window
        for s in sources where !BarHook.on("MERGE_NOCLOSE") { s.windowClosing = true; s.window.close() }  // the hook: the source windows stay open
        bringForward(target)
    }

    /// The windows of the front window's profile (a merge needs two).
    func canMerge(_ w: BrowserWindowController) -> Bool { !w.isHeld && controllers.filter { w.sameProfile($0) && !$0.windowClosing && (!$0.restoring || BarHook.on("MERGE_COUNTRESTORING")) }.count >= 2 }  // a restoring window is not merged: Merge would do nothing

    /// The profiles the New Window submenu lists: the store's, the window's own marked. Without a store (it failed to open) the default one.
    var profileChoices: [(name: String, own: Bool)] {
        let stored = ((try? writer?.store.profiles()) ?? nil) ?? []
        return stored.isEmpty ? [("Default", true)] : stored.map { ($0.name, $0.isDefault) }
    }

    /// A new window that starts with what left another one: its loaded tabs get engine tabs (the first is the window's own), the rest of the
    /// items are dormant, and a blank tab opens when nothing was loaded.
    @discardableResult
    func newWindow(for d: BrowserWindowController.Departure, frame: NSRect) -> BrowserWindowController {
        let blank = TabID()
        let tabs = d.loaded.isEmpty ? [(id: blank, url: "about:blank")] : d.loaded.map { (id: $0.id, url: $0.url) }
        let restore = BrowserWindowController.Restore(
            tabs: tabs, selected: d.active ?? tabs[0].id, sidebarHidden: false, fullScreen: false,
            items: Dictionary(uniqueKeysWithValues: d.items.map { ($0.id, $0) }), groups: d.groups,
            favicons: d.favicons, order: d.items.map(\.id) + (d.loaded.isEmpty ? [blank] : []))
        newWindow(url: tabs[0].url, frame: frame, restore: restore)
        let c = controllers.last!
        for (id, image) in d.images { c.dormantIcons[id] = image }
        return c
    }
}

/// Tabs > Move to Window lists the window's choices each time it opens (rows without the table's mark: they are not part of the table).
@MainActor
final class MoveToWindowMenuDelegate: NSObject, NSMenuDelegate {
    unowned let app: AppDelegate
    init(app: AppDelegate) { self.app = app }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false  // the rows carry their own enabled state (this window's is checked and off)
        guard let c = app.active, let id = c.list.activeID else { return }
        let built = ContextMenus.menu(c.moveToWindowEntries(.tab(id)))
        for i in built.items { built.removeItem(i); menu.addItem(i) }
    }
}
