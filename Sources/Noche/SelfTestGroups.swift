#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Groups and the complete sidebar menus (M1.6 Task 4): `groups`, `group-colors`, `group-menus` and `rename-tab`.
extension SelfTest {
    func groupMenu(_ c: BrowserWindowController, _ g: GroupID) async -> ContextMenus.Pending? {
        ContextMenus.dismiss(choosing: nil)  // a menu still held is ended first, never dropped
        guard let row = c.sidebar.groupRow(g), rightClick(row) != nil else { return nil }
        return await ctxMenu("group", seconds: 3)
    }

    func tabMenu(_ c: BrowserWindowController, _ id: TabID) async -> ContextMenus.Pending? {
        ContextMenus.dismiss(choosing: nil)
        guard let row = c.sidebar.rows.first(where: { $0.tabID == id }), rightClick(row) != nil else { return nil }
        return await ctxMenu("tab", seconds: 3)
    }

    func sidebarMenu(_ c: BrowserWindowController) async -> ContextMenus.Pending? {
        ContextMenus.dismiss(choosing: nil)
        let sidebar = c.sidebar
        guard let hit = rightClick(sidebar, at: NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.height - 60)), !(hit is TabRowView), hit.isDescendant(of: sidebar) else { return nil }
        return await ctxMenu("sidebar", seconds: 3)
    }

    /// What the inline field's keys do: Return commits |text|, Escape cancels it.
    func typeName(_ f: RenameField, _ text: String, cancel: Bool = false) {
        f.stringValue = text
        _ = f.control(f, textView: NSTextView(), doCommandBy: cancel ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertNewline(_:)))
    }

    func storedGroups() -> [TabGroup] {
        app.writer?.flush()
        return ((try? app.writer?.store.loadWindows()) ?? []).flatMap(\.groups)
    }

    func choose(_ menu: NSMenu, _ title: String) { ContextMenus.dismiss(choosing: item(menu, title)) }

    // MARK: groups

    /// Note 5.2 `groups` (and T4.2): Ctrl+Cmd+N makes a group around the active tab with its name in edit (Return commits, Escape cancels), the
    /// chevron click collapses and opens it, Move to Group and New Tab in Group (Opt+Cmd+T, disabled off a group) fill it, Pin and Unpin move it
    /// between the two containers, Copy All Links, Duplicate and Move to Bookmark Bar act, Delete asks first when it holds more than one tab and
    /// closes them, Separate Tabs keeps them, and the sidebar menu's New Group makes an empty one.
    func groups() async {
        guard await ready(), let c = ctl, let win else { return }
        guard await openTabs(3) else { return finish(false, "extra tabs never appeared") }
        Confirm.asked = []
        Confirm.answer = true
        BrowserWindowController.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.noche.selftest"))
        BrowserWindowController.pasteboard.clearContents()
        let t = c.list.items.map(\.id)  // A, B, C
        let moveToGroup = menuItem("Move to Group")
        moveToGroup?.menu?.update()
        guard moveToGroup?.isEnabled == false else { return finish(false, "Tabs > Move to Group is enabled in a window with no group") }
        line("info", "step: Ctrl+Cmd+N on B: a group where B was, B in it, its name in e")
        guard await select(c, t[1]) else { return finish(false, "tab B did not activate") }
        guard key("n", code: 45, [.control, .command], menuOnly: true) else { return finish(false, "Ctrl+Cmd+N was not handled") }
        guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id else { return finish(false, "Ctrl+Cmd+N made \(c.list.groups.count) groups, want 1") }
        guard c.list.groups[0].name == "Untitled", !c.list.groups[0].isCollapsed, entry(c, t[1])?.groupID == g, c.list.dayOrder == [.tab(t[0]), .group(g), .tab(t[2])], c.list.activeID == t[1] else {
            return finish(false, "the new group is \(c.list.groups[0]) with B in \(String(describing: entry(c, t[1])?.groupID)), day list \(c.list.dayOrder), want Untitled, open, around B where it was")
        }
        guard await until(5, { c.sidebar.groupRow(g)?.renameField.isEditing == true }), let field = c.sidebar.groupRow(g)?.renameField else { return finish(false, "the new group's name is not in edit") }
        guard (try? app.writer?.store.setting("emojiForNewGroups")).flatMap({ $0 }) == "1", c.list.groups[0].icon == GroupEmoji.pick(0) else {
            return finish(false, "with emojiForNewGroups=1 (--selftest-setting) the new group's icon is \(String(describing: c.list.groups[0].icon)), want \(GroupEmoji.pick(0))")
        }
        guard c.frame(ofIdentifier: "sidebar.group.0") != nil else { return finish(false, "no sidebar.group.0 view") }
        typeName(field, "Reading")
        guard c.list.groups[0].name == "Reading", !field.isEditing else { return finish(false, "Return left the group named \(c.list.groups[0].name), editing \(field.isEditing), want Reading") }
        guard await until(5, { c.sidebar.groupRow(g)?.name == "Reading" }), storedGroups().first?.name == "Reading" else { return finish(false, "the row or the store does not show Reading: \(storedGroups().map(\.name))") }
        line("info", "step: Rename... from the group menu, then Escape: the name stays.")
        guard let m0 = await groupMenu(c, g) else { return finish(false, "no group menu from a right click on the group row") }
        choose(m0.menu, "Rename...")
        guard await until(5, { c.sidebar.groupRow(g)?.renameField.isEditing == true }), let f2 = c.sidebar.groupRow(g)?.renameField else { return finish(false, "Rename... did not start the edit") }
        typeName(f2, "Nope", cancel: true)
        guard c.list.groups[0].name == "Reading", !f2.isEditing else { return finish(false, "Escape left the name \(c.list.groups[0].name) and editing \(f2.isEditing)") }
        line("info", "step: The chevron: a click collapses (B's row goes), a second open")
        let rows = rowCount
        guard let row = c.sidebar.groupRow(g), click(row) else { return finish(false, "could not click the group row") }
        guard await until(5, { c.list.groups[0].isCollapsed && self.rowCount == rows - 1 }) else { return finish(false, "a click left collapsed=\(c.list.groups[0].isCollapsed) and \(rowCount) rows, want collapsed and \(rows - 1)") }
        guard let again = c.sidebar.groupRow(g), click(again) else { return finish(false, "could not click the collapsed group row") }
        guard await until(5, { !c.list.groups[0].isCollapsed && self.rowCount == rows }) else { return finish(false, "a second click left collapsed=\(c.list.groups[0].isCollapsed) and \(rowCount) rows, want open and \(rows)") }
        line("info", "step: Move to Group: C's menu lists Reading; the pick puts C at th")
        guard let cm = await tabMenu(c, t[2]), let mg = item(cm.menu, "Move to Group"), mg.isEnabled, mg.submenu?.items.map(\.title) == ["PINNED", "Reading"], mg.submenu?.items.first?.isEnabled == false, mg.submenu?.items.last?.state == .off else {
            return finish(false, "C's Move to Group menu is \(String(describing: (await tabMenu(c, t[2]))?.menu.items.first { $0.title == "Move to Group" }?.submenu?.items.map(\.title))), want enabled with a disabled PINNED header, then Reading")
        }
        ContextMenus.dismiss(choosing: mg.submenu?.items.last)
        guard await until(5, { self.entry(c, t[2])?.groupID == g }), c.list.items.filter({ $0.groupID == g }).map(\.id) == [t[1], t[2]], !c.list.groups[0].isCollapsed, c.list.dayOrder == [.tab(t[0]), .group(g)] else {
            return finish(false, "Move to Group left C in \(String(describing: entry(c, t[2])?.groupID)), the group holds \(c.list.items.filter { $0.groupID == g }.count), day list \(c.list.dayOrder)")
        }
        line("info", "step: B's menu shows its own group checked, and so does the Tabs m")
        guard let bm = await tabMenu(c, t[1]), item(bm.menu, "Move to Group")?.submenu?.items.last?.state == .on else { return finish(false, "B's Move to Group does not check Reading") }
        ContextMenus.dismiss(choosing: nil)
        guard let bar = menuItem("Move to Group")?.submenu else { return finish(false, "no Tabs > Move to Group submenu") }
        bar.update()
        bar.delegate?.menuNeedsUpdate?(bar)  // AppKit asks the delegate just before it shows the menu (update() does not)
        moveToGroup?.menu?.update()
        guard bar.items.map(\.title) == ["PINNED", "Reading"], bar.items.first?.isEnabled == false, bar.items.last?.state == .on, moveToGroup?.isEnabled == true else {
            return finish(false, "Tabs > Move to Group lists \(bar.items.map(\.title)) (header enabled \(String(describing: bar.items.first?.isEnabled)), enabled \(String(describing: moveToGroup?.isEnabled))), want a disabled PINNED header, then Reading checked for B, the item enabled")
        }
        line("info", "step: New Tab in Group (Opt+Cmd+T): disabled while the active tab ")
        guard await select(c, t[0]) else { return finish(false, "tab A did not activate") }
        let newInGroup = menuItem("New Tab in Group")
        newInGroup?.menu?.update()
        guard newInGroup?.isEnabled == false else { return finish(false, "New Tab in Group is enabled on A, which is in no group") }
        key("t", code: 17, [.option, .command], menuOnly: true)
        try? await Task.sleep(for: .milliseconds(700))
        guard win.tabs.count == 3, c.list.items.count == 3 else { return finish(false, "Opt+Cmd+T on a tab outside a group opened a tab (\(win.tabs.count) engine tabs)") }
        guard await select(c, t[1]) else { return finish(false, "tab B did not activate") }
        newInGroup?.menu?.update()
        guard newInGroup?.isEnabled == true else { return finish(false, "New Tab in Group is disabled on B, which is in a group") }
        key("t", code: 17, [.option, .command], menuOnly: true)
        guard await until(10, { win.tabs.count == 4 && c.list.items.count == 4 }), let n = c.list.items.first(where: { !t.contains($0.id) })?.id else { return finish(false, "Opt+Cmd+T opened no tab (\(win.tabs.count) engine tabs)") }
        guard await until(5, { self.entry(c, n)?.groupID == g && c.list.activeID == n }), c.list.items.filter({ $0.groupID == g }).map(\.id) == [t[1], t[2], n] else {
            return finish(false, "the new tab is in \(String(describing: entry(c, n)?.groupID)), active \(c.list.activeID == n), the group holds \(c.list.items.filter { $0.groupID == g }.count), want it last in the group and active")
        }
        line("info", "step: Pin moves the group to the persistent area, Unpin back to th")
        guard let pm = await groupMenu(c, g), pm.menu.items.first?.title == "Pin" else { return finish(false, "the day group's menu does not start with Pin") }
        choose(pm.menu, "Pin")
        guard await until(5, { c.list.groups[0].isPinned && c.list.topOrder == [.group(g)] && c.list.dayOrder == [.tab(t[0])] }) else { return finish(false, "Pin left pinned=\(c.list.groups[0].isPinned), persistent \(c.list.topOrder), day \(c.list.dayOrder)") }
        guard let um = await groupMenu(c, g), um.menu.items.first?.title == "Unpin" else { return finish(false, "the pinned group's menu does not start with Unpin") }
        choose(um.menu, "Unpin")
        guard await until(5, { !c.list.groups[0].isPinned && c.list.topOrder.isEmpty && c.list.dayOrder == [.group(g), .tab(t[0])] }) else { return finish(false, "Unpin left pinned=\(c.list.groups[0].isPinned), persistent \(c.list.topOrder), day \(c.list.dayOrder)") }
        line("info", "step: Copy All Links: every member's address, one per line.")
        let urls = c.list.items.filter { $0.groupID == g }.map(\.url)
        guard let lm = await groupMenu(c, g) else { return finish(false, "no group menu for Copy All Links") }
        choose(lm.menu, "Copy All Links")
        guard BrowserWindowController.pasteboard.string(forType: .string) == urls.joined(separator: "\n") else { return finish(false, "Copy All Links wrote \(BrowserWindowController.pasteboard.string(forType: .string) ?? "nil"), want \(urls)") }
        line("info", "step: Duplicate: a second group, same name and color, a tab at eac")
        guard let dm = await groupMenu(c, g) else { return finish(false, "no group menu for Duplicate") }
        choose(dm.menu, "Duplicate")
        guard await until(15, { win.tabs.count == 7 && c.list.groups.count == 2 }), let copy = c.list.groups.first(where: { $0.id != g })?.id else { return finish(false, "Duplicate left \(win.tabs.count) engine tabs and \(c.list.groups.count) groups, want 7 and 2") }
        guard await until(15, { c.list.items.filter { $0.groupID == copy }.map(\.url) == urls }) else { return finish(false, "the copy holds \(c.list.items.filter { $0.groupID == copy }.map(\.url)), want \(urls)") }
        guard c.group(withID: copy)?.name == "Reading", c.group(withID: copy)?.colorIndex == c.group(withID: g)?.colorIndex else { return finish(false, "the copy is \(String(describing: c.group(withID: copy)))") }
        line("info", "step: Move to Group lists the pinned group first, in both menus.")
        c.togglePin(group: copy)  // the later group pinned: B's group (first in the list) is checked after the header and the pinned copy
        guard await until(5, { c.group(withID: copy)?.isPinned == true }), let om = await tabMenu(c, t[1]), let oi = item(om.menu, "Move to Group")?.submenu?.items else { return finish(false, "no Move to Group menu with a pinned copy") }
        bar.update()
        bar.delegate?.menuNeedsUpdate?(bar)
        guard oi.map(\.title) == ["PINNED", "Reading", "Reading"], oi.map(\.state) == [.off, .off, .on], bar.items.map(\.title) == ["PINNED", "Reading", "Reading"], bar.items.map(\.state) == [.off, .off, .on] else {
            return finish(false, "with the later group pinned the tab menu lists \(oi.map { "\($0.title) \($0.state == .on ? "on" : "off")" }) and Tabs > Move to Group \(bar.items.map { "\($0.title) \($0.state == .on ? "on" : "off")" }), want PINNED, the pinned copy, then B's own group checked")
        }
        ContextMenus.dismiss(choosing: nil)
        c.togglePin(group: copy)
        guard await until(5, { c.group(withID: copy)?.isPinned == false }) else { return finish(false, "the copy did not unpin") }
        line("info", "step: Duplicate on a pinned group: the copy is pinned too")
        c.togglePin(group: g)
        guard await until(5, { c.group(withID: g)?.isPinned == true }), let pdm = await groupMenu(c, g) else { return finish(false, "no pinned group to duplicate") }
        choose(pdm.menu, "Duplicate")
        guard await until(15, { win.tabs.count == 10 && c.list.groups.count == 3 }), let pcopy = c.list.groups.first(where: { $0.id != g && $0.id != copy })?.id else { return finish(false, "the pinned Duplicate left \(win.tabs.count) engine tabs and \(c.list.groups.count) groups, want 10 and 3") }
        guard await until(15, { c.members(of: pcopy).map(\.url) == urls }), c.group(withID: pcopy)?.isPinned == true, c.list.topOrder.contains(.group(pcopy)) else {
            return finish(false, "the copy of a pinned group is pinned \(String(describing: c.group(withID: pcopy)?.isPinned)), persistent area \(c.list.topOrder), holds \(c.members(of: pcopy).count) tabs")
        }
        guard let pxm = await groupMenu(c, pcopy) else { return finish(false, "no menu for the pinned copy") }
        choose(pxm.menu, "Delete")  // answered yes (Confirm.answer is still true)
        guard await until(15, { c.group(withID: pcopy) == nil && win.tabs.count == 7 }) else { return finish(false, "deleting the pinned copy left \(win.tabs.count) engine tabs") }
        c.togglePin(group: g)
        guard await until(5, { c.group(withID: g)?.isPinned == false }) else { return finish(false, "the group did not unpin") }
        Confirm.asked = []
        Confirm.answer = false
        guard let xm = await groupMenu(c, copy) else { return finish(false, "no group menu for Delete") }
        choose(xm.menu, "Delete")
        guard Confirm.asked.count == 1, Confirm.asked[0].message == "Delete \"Reading\"?", c.list.groups.count == 2, win.tabs.count == 7 else {
            return finish(false, "Delete on a 3-tab group asked \(Confirm.asked.map(\.message)) and left \(c.list.groups.count) groups and \(win.tabs.count) engine tabs, want one question, then 2 groups and 7 tabs (answer: cancel)")
        }
        Confirm.answer = true
        guard let ym = await groupMenu(c, copy) else { return finish(false, "no group menu for the confirmed Delete") }
        choose(ym.menu, "Delete")
        guard Confirm.asked.count == 2, await until(15, { c.list.groups.count == 1 && win.tabs.count == 4 && c.list.items.count == 4 }), app.writer?.hasClosed == true else {
            return finish(false, "the confirmed Delete left \(c.list.groups.count) groups, \(win.tabs.count) engine tabs, \(c.list.items.count) items, asked \(Confirm.asked.count), reopen list \(String(describing: app.writer?.hasClosed))")
        }
        line("info", "step: Move to Bookmark Bar: the group's pages become a folder on t")
        guard let store = app.writer?.store, let bar = (try? store.bookmarkRoots().first).flatMap({ $0 }) else { return finish(false, "no bookmarks bar root") }
        guard let km = await groupMenu(c, g), item(km.menu, "Move to Bookmark Bar")?.isEnabled == true else { return finish(false, "Move to Bookmark Bar is disabled on a group of web pages") }
        let members = c.list.items.filter { $0.groupID == g }.map(\.url)
        choose(km.menu, "Move to Bookmark Bar")
        guard await until(5, { c.list.groups.isEmpty }), let folder = ((try? store.bookmarkChildren(of: bar.id)) ?? []).first(where: { $0.title == "Reading" }),
              ((try? store.bookmarkChildren(of: folder.id)) ?? []).compactMap(\.url) == members.filter { c.isWeb($0) }, win.tabs.count == 4 else {
            return finish(false, "Move to Bookmark Bar left \(c.list.groups.count) groups, folder \(String(describing: ((try? store.bookmarkChildren(of: bar.id)) ?? []).map(\.title))), \(win.tabs.count) engine tabs")
        }
        line("info", "step: Separate Tabs and a one-tab Delete: a group around B, then a")
        let bID = t[1]
        c.newGroupWithTab(bID)
        guard await until(5, { c.list.groups.count == 1 }), let g2 = c.list.groups.first?.id, c.sidebar.groupRow(g2).map({ $0.renameField.cancel(); return true }) == true, let mb = await groupMenu(c, g2) else { return finish(false, "no second group") }
        choose(mb.menu, "Separate Tabs")
        guard await until(5, { c.list.groups.isEmpty && c.list.items.allSatisfy { $0.groupID == nil } && win.tabs.count == 4 }) else { return finish(false, "Separate Tabs left \(c.list.groups.count) groups and \(win.tabs.count) engine tabs") }
        c.newGroupWithTab(t[0])
        guard await until(5, { c.list.groups.count == 1 }), let g3 = c.list.groups.first?.id, c.sidebar.groupRow(g3).map({ $0.renameField.cancel(); return true }) == true, let mc = await groupMenu(c, g3) else { return finish(false, "no group around A") }
        choose(mc.menu, "Delete")
        guard Confirm.asked.count == 2, await until(10, { c.list.groups.isEmpty && win.tabs.count == 3 && c.list.items.count == 3 }) else { return finish(false, "deleting a one-tab group asked \(Confirm.asked.count) times (want still 2) and left \(c.list.groups.count) groups, \(win.tabs.count) engine tabs") }
        line("info", "step: New Group in the sidebar menu: an empty group at the top of ")
        guard let sm = await sidebarMenu(c), item(sm.menu, "New Group")?.isEnabled == true else { return finish(false, "no enabled New Group in the sidebar menu") }
        choose(sm.menu, "New Group")
        guard await until(5, { c.list.groups.count == 1 }), let g4 = c.list.groups.first?.id, c.list.dayOrder.first == .group(g4), c.list.items.allSatisfy({ $0.groupID == nil }) else { return finish(false, "New Group made \(c.list.groups.count) groups, day list \(c.list.dayOrder)") }
        guard await until(5, { c.sidebar.groupRow(g4)?.renameField.isEditing == true }), let f4 = c.sidebar.groupRow(g4)?.renameField else { return finish(false, "the empty group's name is not in edit") }
        typeName(f4, "Ideas")
        guard c.list.groups[0].name == "Ideas", storedGroups().first?.name == "Ideas" else { return finish(false, "the empty group is named \(c.list.groups[0].name), stored \(storedGroups().map(\.name))") }
        line("info", "step: a join whose tab closes is dropped.")
        guard let victim = win.tabs.first(where: { $0 !== c.activeTab }) else { return finish(false, "no tab to close") }
        c.groupJoins[victim.identifier] = .init(group: g4, template: nil)
        let before = win.tabs.count
        c.closeTab(victim)
        guard await until(10, { win.tabs.count == before - 1 }), c.groupJoins.isEmpty else { return finish(false, "after the tab closed \(c.groupJoins.count) joins are left, want 0") }
        finish(violations.isEmpty, "Ctrl+Cmd+N groups the active tab with its name in edit (Return commits, Escape cancels), a click collapses and opens it, Move to Group and Opt+Cmd+T (disabled off a group) fill it, Pin and Unpin move it, Copy All Links, Duplicate (a pinned group's copy is pinned) and Move to Bookmark Bar act, Delete asks first for 3 tabs (refused: nothing closes) and not for 1, Separate Tabs keeps the tabs, the sidebar menu's New Group makes an empty one, Tabs > Move to Group is disabled without a group and lists a disabled PINNED header first, a join whose tab closes is dropped \(violations)")
    }

    // MARK: group-colors

    func pixelDump(_ v: NSView, in rect: NSRect) -> String {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return "no rep" }
        v.cacheDisplay(in: v.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / v.bounds.width
        var best: NSColor?
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) { for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > (best?.alphaComponent ?? 0) { best = c }
        } }
        return "scale \(scale) best \(String(describing: best))"
    }

    /// A group row of its own, set up like |row| and tinted with |rgb| (a hand-listed color): the reference the row's icon is compared with. It is the
    /// same view class drawing the same symbol through the same call, so the comparison needs no tolerance.
    func referenceRow(like row: GroupRowView, _ rgb: UInt32) -> GroupRowView {
        let ref = GroupRowView(frame: row.frame)
        ref.configure(name: row.name, icon: row.icon, colorIndex: 0, collapsed: row.isCollapsed, hasActive: false)
        ref.tintOverride = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        return ref
    }

    /// The open group's outline as drawn from a hand-listed color: a 1 pt rounded stroke at 0.55 over a white 5% fill, the same recipe as the sidebar's box.
    final class OutlineReference: NSView {
        let rgb: UInt32
        init(_ rgb: UInt32, size: NSSize) { self.rgb = rgb; super.init(frame: NSRect(origin: .zero, size: size)) }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.05).setFill()
            path.fill()
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 0.55).setStroke()
            path.stroke()
        }
    }

    /// The mean color of the at-least-half-opaque pixels of |rect| of |v|, drawn, and how many there are.
    func meanColor(_ v: NSView, in rect: NSRect) -> (rgb: [CGFloat], n: Int) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return ([0, 0, 0], 0) }
        // The view's own draw, not its layer: a hidden window gets no frames, so a layer-backed view's backing store (and any fade of it) is not the view's current drawing.
        v.displayIgnoringOpacity(v.bounds, in: gc)
        let scale = CGFloat(rep.pixelsWide) / v.bounds.width
        var sum: [CGFloat] = [0, 0, 0], n = 0
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                sum[0] += c.redComponent; sum[1] += c.greenComponent; sum[2] += c.blueComponent; n += 1
            }
        }
        return (n == 0 ? sum : sum.map { $0 / CGFloat(n) }, n)
    }

    /// The palette index whose reference icon looks most like |rect| of |v| (squared distance of the mean colors, no tolerance), the icon's pixel count,
    /// and the margin by which the winner beats the runner-up.
    func nearestSwatch(_ v: GroupRowView, in rect: NSRect, palette: [UInt32]) -> (index: Int, n: Int, distance: CGFloat, margin: CGFloat, detail: String) {
        let got = meanColor(v, in: rect)
        let refs = palette.map { rgb -> [CGFloat] in
            let ref = referenceRow(like: v, rgb)
            v.superview?.addSubview(ref)  // beside the row: the same appearance and backdrop
            defer { ref.removeFromSuperview() }
            return meanColor(ref, in: rect).rgb
        }
        let d = refs.map { r in zip(r, got.rgb).map { pow($0 - $1, 2) }.reduce(0, +) }
        let best = d.firstIndex(of: d.min()!)!, runnerUp = d.enumerated().filter { $0.offset != best }.map(\.element).min()!
        return (best, got.n, d[best], runnerUp - d[best], "mean \(got.rgb.map { ($0 * 1000).rounded() / 1000 }) distances \(d.map { ($0 * 1000).rounded() / 1000 }) refs \(refs.map { $0.map { ($0 * 1000).rounded() / 1000 } })")
    }

    /// The most opaque pixel in a narrow band across the left edge of |box| (the outline's line), unpremultiplied.
    func edge(_ v: NSView, of box: CGRect) -> NSColor? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / v.bounds.width
        var best: NSColor?
        for x in (Int(box.minX * scale) - 1)...(Int(box.minX * scale) + 3) {
            guard let c = rep.colorAt(x: x, y: Int(box.midY * scale))?.usingColorSpace(.sRGB) else { continue }
            if c.alphaComponent > (best?.alphaComponent ?? 0) { best = c }
        }
        return best
    }

    /// A reference drawn through the row's own path matches the row within this squared distance, and the winner leads the runner-up by at least |colorMargin|
    /// (amber and orange, the closest pair, are about 0.05 apart).
    static let colorExact: CGFloat = 0.002, colorMargin: CGFloat = 0.01

    /// Note 1.3 `group-colors`: the 8 swatches of the group menu, in order, set `colorIndex` (stored too) and tint the group's icon and its
    /// outline. The colors are listed here by hand, and read back from the pixels the row and the outline draw.
    func groupColors() async {
        guard await ready(), let c = ctl else { return }
        let palette: [UInt32] = [0xF2F2F7, 0x30D158, 0x0A84FF, 0xBF5AF2, 0xFFB340, 0xFF6482, 0xFF453A, 0xFF9F0A]  // white, green, blue, purple, amber, pink, red, orange
        let a = c.list.items[0].id
        c.newGroupWithTab(a)
        guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id else { return finish(false, "no group") }
        guard await until(5, { c.sidebar.groupRow(g)?.renameField.isEditing == true }), let field = c.sidebar.groupRow(g)?.renameField else { return finish(false, "the group's name is not in edit") }
        typeName(field, "Colors")
        guard await until(5, { c.sidebar.groupRow(g)?.name == "Colors" && !c.sidebar.boxesView.boxes.isEmpty }) else { return finish(false, "no group row or outline box") }
        var weakest = CGFloat.greatestFiniteMagnitude  // the smallest margin by which a winner beat its runner-up, icon or outline
        for (i, rgb) in palette.enumerated() {
            guard let m = await groupMenu(c, g), let colors = item(m.menu, "Colors"), let swatches = colors.view as? SwatchRowView else { return finish(false, "swatch \(i): no Colors row with a swatch view in the group menu") }
            guard ChromeStyle.groupColors.count == 8, swatches.selected == (i == 0 ? 0 : i - 1) else { return finish(false, "swatch \(i): the row shows \(swatches.selected) selected, want \(i == 0 ? 0 : i - 1)") }
            swatches.pick(i)
            ContextMenus.dismiss(choosing: nil)
            guard await until(5, { c.list.groups[0].colorIndex == i }) else { return finish(false, "swatch \(i): colorIndex is \(c.list.groups[0].colorIndex)") }
            guard storedGroups().first?.colorIndex == i else { return finish(false, "swatch \(i): the stored colorIndex is \(String(describing: storedGroups().first?.colorIndex))") }
            guard await until(5, { c.sidebar.groupRow(g)?.colorIndex == i }), let row = c.sidebar.groupRow(g) else { return finish(false, "swatch \(i): the row did not take the color") }
            // The icon: pixels of the expected color in the icon's rect, and none of any other swatch's.
            let icon = NSRect(x: ChromeStyle.faviconX - ChromeStyle.rowX, y: (row.bounds.height - ChromeStyle.groupIconSize) / 2, width: ChromeStyle.groupIconSize, height: ChromeStyle.groupIconSize)
            row.clearHover()  // the right click that opened the menu left the pointer on the row: its hover fill sits under the icon
            let (nearest, painted, own, margin, detail) = nearestSwatch(row, in: icon, palette: palette)
            guard painted >= 3, nearest == i, own <= Self.colorExact, margin >= Self.colorMargin else { return finish(false, "swatch \(i): the icon (\(painted) pixels) looks most like swatch \(nearest) of the hand-listed colors, want \(i), at distance \(own) (want at most \(Self.colorExact)) beating the runner-up by \(margin) (want at least \(Self.colorMargin)) (\(detail))") }
            weakest = min(weakest, margin)
            // The outline of the open group.
            guard await until(5, { c.sidebar.boxesView.boxes.first?.colorIndex == i }), let box = c.sidebar.boxesView.boxes.first, let px = edge(c.sidebar.boxesView, of: box.frame) else { return finish(false, "swatch \(i): no outline box") }
            if i == 0 {
                guard px.alphaComponent < 0.3, px.redComponent > 0.85, px.blueComponent > 0.85 else { return finish(false, "swatch 0: the outline is rgba \(px.redComponent), \(px.greenComponent), \(px.blueComponent), \(px.alphaComponent), want a faint white") }
            } else {
                // Compared with the outline drawn here in each hand-listed color at 0.55 (white 5% fill under it), through the same bitmap path.
                let box0 = NSRect(x: 0, y: 0, width: box.frame.width, height: box.frame.height)
                let refs = palette.map { rgb -> NSColor? in
                    let ref = OutlineReference(rgb, size: box0.size)
                    c.sidebar.boxesView.superview?.addSubview(ref)  // beside the outlines: the same appearance and backdrop
                    defer { ref.removeFromSuperview() }
                    return edge(ref, of: box0)
                }
                func dist(_ r: NSColor?) -> CGFloat {  // the same path and recipe as the box: no tolerance
                    guard let r else { return 9 }
                    return pow(r.redComponent - px.redComponent, 2) + pow(r.greenComponent - px.greenComponent, 2) + pow(r.blueComponent - px.blueComponent, 2) + pow(r.alphaComponent - px.alphaComponent, 2)
                }
                let d = refs.map(dist)
                let best = d.firstIndex(of: d.min()!)!, runnerUp = d.enumerated().filter { $0.offset != best }.map(\.element).min()!
                guard px.alphaComponent > 0.4, best == i, d[best] <= Self.colorExact, runnerUp - d[best] >= Self.colorMargin else {
                    return finish(false, "swatch \(i): the outline is rgba \(px.redComponent), \(px.greenComponent), \(px.blueComponent), \(px.alphaComponent) and looks most like swatch \(best) of the hand-listed colors at 0.55, distance \(d[best]) (want at most \(Self.colorExact)) beating the runner-up by \(runnerUp - d[best]) (want at least \(Self.colorMargin)) (distances \(d.map { ($0 * 1000).rounded() / 1000 }))")
                }
                weakest = min(weakest, runnerUp - d[best])
            }
        }
        finish(violations.isEmpty, "least margin \(weakest) (want \(Self.colorMargin)): the 8 swatches in order (white, green, blue, purple, amber, pink, red, orange) set colorIndex 0 to 7, stored, and the icon and the outline of the open group draw in that color (read back from the pixels, each within \(Self.colorExact) of its reference with no white mixed in, every winner ahead of the runner-up by at least the least margin over the 8 swatches) \(violations)")
    }

    // MARK: group-menus

    /// Live-ui.md section 3, the three menus (titles and enabled state; the separators are builder calls, see the README): the tab row's, the
    /// group's (day, pinned and empty) and the empty space's. Only the later features are disabled (Chat With, Open as Split, Move to Profile,
    /// New Live Group, Move to Window until Task 5b); a disabled item acts on nothing.
    func groupMenus() async {
        guard await ready(), let c = ctl else { return }
        guard await openTabs(2) else { return finish(false, "extra tabs never appeared") }
        let t = c.list.items.map(\.id)
        let tabWant = ["Pin", "---", "Chat With This Tab", "Open as Split", "---", "Duplicate", "New Group with Tab", "Move to Group", "Move to Profile", "---",
                       "Copy Link", "---", "Rename...", "Change Icon...", "Edit Pinned Page", "---", "Close"]
        guard let m1 = await tabMenu(c, t[1]) else { return finish(false, "no tab menu") }
        guard titles(m1.menu) == tabWant else { return finish(false, "tab menu \(titles(m1.menu)), want \(tabWant)") }
        guard enabledTitles(m1.menu) == ["Pin", "Duplicate", "New Group with Tab", "Copy Link", "Rename...", "Change Icon...", "Close"] else { return finish(false, "tab menu enabled \(enabledTitles(m1.menu)) with no group") }
        BrowserWindowController.actionCounts = [:]
        for later in ["Chat With This Tab", "Open as Split", "Move to Profile", "Move to Group", "Edit Pinned Page"] {
            ContextMenus.dismiss(choosing: item(m1.menu, later))
            guard BrowserWindowController.actionCounts.isEmpty else { return finish(false, "\(later) acted: \(BrowserWindowController.actionCounts)") }
            guard await tabMenu(c, t[1]) != nil else { return finish(false, "no tab menu again") }
        }
        // A group of B: the tab menus list it, the group menu is the section 3 list with the group's name in Chat With.
        c.newGroupWithTab(t[1])
        guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id else { return finish(false, "no group") }
        guard await until(5, { c.sidebar.groupRow(g)?.renameField.isEditing == true }), let field = c.sidebar.groupRow(g)?.renameField else { return finish(false, "the name is not in edit") }
        typeName(field, "Reading")
        guard await until(5, { c.sidebar.groupRow(g)?.name == "Reading" }) else { return finish(false, "the row did not show Reading") }
        guard let m2 = await tabMenu(c, t[0]), item(m2.menu, "Move to Group")?.isEnabled == true, item(m2.menu, "Move to Group")?.submenu?.items.map(\.title) == ["PINNED", "Reading"], item(m2.menu, "Move to Group")?.submenu?.items.first?.isEnabled == false else { return finish(false, "A's Move to Group does not list a disabled PINNED header, then Reading") }
        let groupWant = ["Pin", "---", "New Tab in Group", "Chat With \"Reading\"", "---", "Separate Tabs", "Duplicate", "Move to Window", "Move to Profile", "Copy All Links",
                         "---", "Colors", "---", "Rename...", "Change Icon...", "---", "Move to Bookmark Bar", "Delete"]
        guard let gm = await groupMenu(c, g) else { return finish(false, "no group menu") }
        guard titles(gm.menu) == groupWant else { return finish(false, "group menu \(titles(gm.menu)), want \(groupWant)") }
        let groupEnabled = ["Pin", "New Tab in Group", "Separate Tabs", "Duplicate", "Copy All Links", "Colors", "Rename...", "Change Icon...", "Move to Bookmark Bar", "Delete"]
        guard enabledTitles(gm.menu) == groupEnabled else { return finish(false, "group menu enabled \(enabledTitles(gm.menu)), want \(groupEnabled)") }
        guard sameKey(item(gm.menu, "New Tab in Group"), menuItem("New Tab in Group")) else { return finish(false, "New Tab in Group's key differs from the menu bar's") }
        guard (item(gm.menu, "Colors")?.view as? SwatchRowView)?.selected == 0 else { return finish(false, "the Colors row is not the swatch view with white selected") }
        BrowserWindowController.actionCounts = [:]
        for later in ["Chat With \"Reading\"", "Move to Window", "Move to Profile"] {
            ContextMenus.dismiss(choosing: item(gm.menu, later))
            guard BrowserWindowController.actionCounts.isEmpty else { return finish(false, "\(later) acted: \(BrowserWindowController.actionCounts)") }
            guard await groupMenu(c, g) != nil else { return finish(false, "no group menu again") }
        }
        // The pinned group says Unpin; an empty one cannot copy links or go to the bar.
        c.togglePin(group: g)
        guard await until(5, { c.list.groups[0].isPinned }), let pm = await groupMenu(c, g), pm.menu.items.first?.title == "Unpin", titles(pm.menu).dropFirst() == groupWant.dropFirst() else { return finish(false, "the pinned group's menu does not start with Unpin and keep the rest") }
        c.newGroup()
        guard await until(5, { c.list.groups.count == 2 }), let e = c.list.groups.first(where: { $0.id != g })?.id, await until(5, { c.sidebar.groupRow(e) != nil }) else { return finish(false, "no empty group") }
        c.sidebar.groupRow(e)?.renameField.cancel()
        guard let em = await groupMenu(c, e) else { return finish(false, "no menu for the empty group") }
        guard enabledTitles(em.menu) == ["Pin", "New Tab in Group", "Separate Tabs", "Duplicate", "Colors", "Rename...", "Change Icon...", "Delete"] else { return finish(false, "the empty group's enabled items are \(enabledTitles(em.menu))") }
        // The empty space.
        let sideWant = ["New Tab", "Reopen Closed Tab", "---", "New Group", "New Live Group", "New Profile...", "---", "Bookmark All Tabs", "---", "Show Tabs in Sidebar", "Auto-Hide Tabs", "---", "Close All Tabs"]
        guard let sm = await sidebarMenu(c) else { return finish(false, "no sidebar menu") }
        guard titles(sm.menu) == sideWant else { return finish(false, "sidebar menu \(titles(sm.menu)), want \(sideWant)") }
        guard enabledTitles(sm.menu) == ["New Tab", "New Group", "Bookmark All Tabs", "Auto-Hide Tabs", "Close All Tabs"] else { return finish(false, "sidebar menu enabled \(enabledTitles(sm.menu))") }
        ContextMenus.dismiss(choosing: nil)
        finish(violations.isEmpty, "the tab, group (day, pinned, empty) and empty-space menus list the section 3 items in order with only the later features disabled (Chat With, Open as Split, Move to Profile, Move to Window, New Live Group, New Profile..., Show Tabs in Sidebar), the group menu carries the swatch row and the tab menus list the groups, a disabled item acts on nothing \(violations)")
    }

    // MARK: rename-tab

    /// Two phases. Phase 1: Rename... (the tab menu, the Tabs menu and a pinned tile's popover) sets a title that shows over the page's and stays when
    /// the page's title changes; Escape cancels, an empty name clears it. Phase 2, after a relaunch: both custom titles are still there.
    func renameTab() async {
        let page = fixture("b.html")
        if phase == 1 {
            guard await ready(), let c = ctl, let win, let writer = app.writer else { return }
            _ = win.addTab(withURL: page, activate: false)
            guard await until(20, { c.list.items.count == 2 && c.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "phase 1: titles \(c.list.items.map(\.title))") }
            let t = c.list.items.map(\.id)
            let pageTitles = c.list.items.map(\.title)
            guard pageTitles == ["Noche App Fixture", "B Page"] else { return finish(false, "phase 1: page titles \(pageTitles)") }
            // The tab menu's Rename...: the field starts on the shown title.
            guard let m = await tabMenu(c, t[1]) else { return finish(false, "phase 1: no tab menu") }
            choose(m.menu, "Rename...")
            guard let field = c.sidebar.rows.first(where: { $0.tabID == t[1] })?.renameField, field.isEditing, field.stringValue == "B Page" else { return finish(false, "phase 1: Rename... did not start an edit on \"B Page\"") }
            typeName(field, "Mine")
            guard await until(5, { c.sidebar.rows.first { $0.tabID == t[1] }?.titleField.stringValue == "Mine" }), entry(c, t[1])?.customTitle == "Mine", entry(c, t[1])?.title == "B Page" else {
                return finish(false, "phase 1: the row shows \(String(describing: c.sidebar.rows.first { $0.tabID == t[1] }?.titleField.stringValue)), custom \(String(describing: entry(c, t[1])?.customTitle)), page \(entry(c, t[1])?.title ?? "nil"), want Mine over B Page")
            }
            // The page's title changes (a new page): the custom title stays.
            c.engineTab(entry(c, t[1])!)?.loadURL(fixture("find.html"))
            guard await until(10, { self.entry(c, t[1])?.title == "Find Fixture" }), c.sidebar.rows.first(where: { $0.tabID == t[1] })?.titleField.stringValue == "Mine" else {
                return finish(false, "phase 1: after the page's title became \(entry(c, t[1])?.title ?? "nil") the row shows \(String(describing: c.sidebar.rows.first { $0.tabID == t[1] }?.titleField.stringValue)), want Mine")
            }
            // The Tabs menu's Rename... acts on the active tab; Escape cancels.
            guard await select(c, t[1]), fire("Rename...") else { return finish(false, "phase 1: Tabs > Rename... did not run") }
            guard let f2 = c.sidebar.rows.first(where: { $0.tabID == t[1] })?.renameField, f2.isEditing, f2.stringValue == "Mine" else { return finish(false, "phase 1: Tabs > Rename... did not start on Mine") }
            typeName(f2, "Nope", cancel: true)
            guard entry(c, t[1])?.customTitle == "Mine", !f2.isEditing else { return finish(false, "phase 1: Escape left \(String(describing: entry(c, t[1])?.customTitle))") }
            // A name, then an empty one on the first tab: the page's title comes back.
            guard let m0 = await tabMenu(c, t[0]) else { return finish(false, "phase 1: no menu for tab A") }
            choose(m0.menu, "Rename...")
            guard let f3 = c.sidebar.rows.first(where: { $0.tabID == t[0] })?.renameField, f3.isEditing else { return finish(false, "phase 1: no edit on A") }
            typeName(f3, "Zed")
            guard await until(5, { self.entry(c, t[0])?.customTitle == "Zed" }) else { return finish(false, "phase 1: A is \(String(describing: entry(c, t[0])?.customTitle)), want Zed") }
            guard let m3 = await tabMenu(c, t[0]) else { return finish(false, "phase 1: no menu for A again") }
            choose(m3.menu, "Rename...")
            guard let f4 = c.sidebar.rows.first(where: { $0.tabID == t[0] })?.renameField, f4.isEditing, f4.stringValue == "Zed" else { return finish(false, "phase 1: the second edit did not start on Zed") }
            typeName(f4, "")
            guard await until(5, { self.entry(c, t[0])?.customTitle == nil && c.sidebar.rows.first { $0.tabID == t[0] }?.titleField.stringValue == "Noche App Fixture" }) else {
                return finish(false, "phase 1: an empty name left \(String(describing: entry(c, t[0])?.customTitle)) and the row \(String(describing: c.sidebar.rows.first { $0.tabID == t[0] }?.titleField.stringValue))")
            }
            // The page's own title typed over a custom one goes back to following the page (a custom title equal to the page's is none).
            guard await until(5, { self.entry(c, t[0])?.title == "Noche App Fixture" }), let m4 = await tabMenu(c, t[0]) else { return finish(false, "phase 1: no menu for A before the page-title rename") }
            choose(m4.menu, "Rename...")
            guard let f5 = c.sidebar.rows.first(where: { $0.tabID == t[0] })?.renameField, f5.isEditing else { return finish(false, "phase 1: no edit on A for Zed") }
            typeName(f5, "Zed")
            guard await until(5, { self.entry(c, t[0])?.customTitle == "Zed" }), let m5 = await tabMenu(c, t[0]) else { return finish(false, "phase 1: A is \(String(describing: entry(c, t[0])?.customTitle)), want Zed") }
            choose(m5.menu, "Rename...")
            guard let f6 = c.sidebar.rows.first(where: { $0.tabID == t[0] })?.renameField, f6.isEditing else { return finish(false, "phase 1: no edit on A for the page title") }
            typeName(f6, "Noche App Fixture")
            guard await until(5, { self.entry(c, t[0])?.customTitle == nil && c.sidebar.rows.first { $0.tabID == t[0] }?.titleField.stringValue == "Noche App Fixture" }) else {
                return finish(false, "phase 1: typing the page's own title left the custom title \(String(describing: entry(c, t[0])?.customTitle)) and the row \(String(describing: c.sidebar.rows.first { $0.tabID == t[0] }?.titleField.stringValue)), want none and the page's title")
            }
            // Pin A: a tile shows no title, its Rename... is a small popover with the same field.
            guard await select(c, t[0]) else { return finish(false, "phase 1: A did not activate") }
            pinKey()
            guard await pinned(c, t[0], true), await until(5, { self.tile(0) != nil }), let tl = tile(0), rightClick(tl) != nil, let tm = await ctxMenu("tab", seconds: 3) else { return finish(false, "phase 1: no tile menu") }
            choose(tm.menu, "Rename...")
            guard let pf = RenamePopover.pending, pf.isEditing, pf.stringValue == "Noche App Fixture" else { return finish(false, "phase 1: the tile's Rename... did not open the field") }
            typeName(pf, "Tile")
            guard await until(5, { self.entry(c, t[0])?.customTitle == "Tile" }) else { return finish(false, "phase 1: the tile rename left \(String(describing: entry(c, t[0])?.customTitle))") }
            guard stored(t[0])?.customTitle == "Tile", stored(t[1])?.customTitle == "Mine" else { return finish(false, "phase 1: stored titles \(String(describing: stored(t[0])?.customTitle)), \(String(describing: stored(t[1])?.customTitle))") }
            writer.flush()
            return finish(violations.isEmpty, "phase 1: Rename... (tab menu, Tabs menu, a pinned tile's popover) set Mine and Tile over the page titles, the page's title changing left Mine, Escape kept it, an empty name cleared Zed, the page's own title typed over Zed cleared it, stored \(violations)")
        }
        guard await until(30, { self.restoredUp(1) }), let c = ctl else { return finish(false, "phase 2: no restored window") }
        guard await until(20, { c.list.items.count == 2 }) else { return finish(false, "phase 2: \(c.list.items.count) items") }
        let items = c.list.items
        guard items[0].customTitle == "Tile", items[1].customTitle == "Mine", items[0].isPinned else { return finish(false, "phase 2: custom titles \(items.map { $0.customTitle ?? "nil" }), pinned \(items[0].isPinned), want Tile and Mine") }
        guard await until(20, { !(c.list.items[1].title.isEmpty) }), c.list.items[1].title != "Mine" else { return finish(false, "phase 2: the page's title is \(c.list.items[1].title)") }
        guard await until(5, { c.sidebar.rows.first?.titleField.stringValue == "Mine" }) else { return finish(false, "phase 2: the row shows \(String(describing: c.sidebar.rows.first?.titleField.stringValue)), page title \(c.list.items[1].title), want Mine") }
        finish(violations.isEmpty, "phase 2: the custom titles Tile (pinned, dormant) and Mine (over the page's \(c.list.items[1].title)) survive the relaunch and the row shows Mine \(violations)")
    }
    // MARK: group-icons, group-restore-relaunch, group-rename-scroll

    /// Picks |icon| in the open Change Icon picker (a cell, or Remove Icon for nil) the way a click does; false when no picker is open or the picker stays.
    func pickIcon(_ icon: String?) -> Bool {
        guard let picker = IconPicker.pending?.view else { return false }
        if let icon {
            guard let cell = picker.cells.first(where: { $0.icon == icon }) else { return false }
            cell.performClick(nil)
        } else {
            picker.removeButton.performClick(nil)
        }
        return IconPicker.pending == nil
    }

    /// The image of tab |id|'s row once it has not changed for 0.6 s (the favicon replaces the default image when the engine reports it); the last one read after 8 s.
    func settledRowImage(_ c: BrowserWindowController, _ id: TabID) async -> NSImage? {
        var last: NSImage?, since = Date()
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            let now = c.sidebar.rows.first(where: { $0.tabID == id })?.faviconView.image
            if now !== last { last = now; since = Date() } else if now != nil, Date().timeIntervalSince(since) >= 0.6 { return now }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return last
    }

    /// The icon of tab |id|'s row is the cached image of |icon| (nil: it is not).
    func rowShows(_ c: BrowserWindowController, _ id: TabID, _ icon: String?) -> Bool {
        guard let image = c.sidebar.rows.first(where: { $0.tabID == id })?.faviconView.image else { return false }
        return icon.flatMap { IconRender.cached($0) }.map { image === $0 } ?? true
    }

    /// Change Icon on a tab and on a group, through the menus: an emoji cell, a symbol cell, then Remove Icon. Each pick sets `customIcon` (the tab) or the
    /// group's `icon` (list and store) and the row shows it; Remove Icon clears both.
    func groupIcons() async {
        guard await ready(), let c = ctl else { return }
        guard await openTabs(2) else { return finish(false, "extra tabs never appeared") }
        let t = c.list.items.map(\.id)
        IconPicker.dismiss()
        // Ruling M92: the page's favicon arrives on its own turn and replaces the default image, so |before| is read once the row's image has held still.
        guard let before = await settledRowImage(c, t[1]) else { return finish(false, "tab B's row shows no image before any icon is picked") }  // its favicon, or the default
        for (label, icon) in [("an emoji", "📌"), ("a symbol", "star")] {
            line("info", "step: Change Icon on a tab, \(label).")
            guard let m = await tabMenu(c, t[1]) else { return finish(false, "no tab menu") }
            choose(m.menu, "Change Icon...")
            guard IconPicker.pending != nil, pickIcon(icon) else { return finish(false, "Change Icon... did not open a picker with \(icon), or the pick left it open") }
            guard await until(5, { self.entry(c, t[1])?.customIcon == icon && self.rowShows(c, t[1], icon) }) else {
                return finish(false, "after picking \(icon) the tab's customIcon is \(String(describing: entry(c, t[1])?.customIcon)) and its row shows it: \(rowShows(c, t[1], icon))")
            }
            guard stored(t[1])?.customIcon == icon else { return finish(false, "the stored customIcon is \(String(describing: stored(t[1])?.customIcon)), want \(icon)") }
        }
        guard let rm = await tabMenu(c, t[1]) else { return finish(false, "no tab menu for Remove Icon") }
        choose(rm.menu, "Change Icon...")
        guard pickIcon(nil), await until(5, { self.entry(c, t[1])?.customIcon == nil && !(self.rowShows(c, t[1], "star")) }), stored(t[1])?.customIcon == nil else {
            return finish(false, "Remove Icon left customIcon \(String(describing: entry(c, t[1])?.customIcon)), stored \(String(describing: stored(t[1])?.customIcon)), row still the symbol \(rowShows(c, t[1], "star"))")
        }
        guard await until(5, { c.sidebar.rows.first(where: { $0.tabID == t[1] })?.faviconView.image === before }) else {
            return finish(false, "after Remove Icon the row shows \(String(describing: c.sidebar.rows.first { $0.tabID == t[1] }?.faviconView.image)), want the page's favicon or the default icon it showed before (\(before))")
        }
        c.newGroupWithTab(t[0])
        guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id, c.sidebar.groupRow(g).map({ $0.renameField.cancel(); return true }) == true else { return finish(false, "no group") }
        for (label, icon) in [("an emoji", "🔥"), ("a symbol", "bolt")] {
            line("info", "step: Change Icon on a group, \(label).")
            guard let m = await groupMenu(c, g) else { return finish(false, "no group menu") }
            choose(m.menu, "Change Icon...")
            guard IconPicker.pending != nil, pickIcon(icon) else { return finish(false, "the group's Change Icon... did not open a picker with \(icon), or the pick left it open") }
            guard await until(5, { c.list.groups[0].icon == icon && c.sidebar.groupRow(g)?.icon == icon }), storedGroups().first?.icon == icon else {
                return finish(false, "after picking \(icon) the group's icon is \(String(describing: c.list.groups[0].icon)), its row \(String(describing: c.sidebar.groupRow(g)?.icon)), stored \(String(describing: storedGroups().first?.icon))")
            }
        }
        guard let gm = await groupMenu(c, g) else { return finish(false, "no group menu for Remove Icon") }
        choose(gm.menu, "Change Icon...")
        guard pickIcon(nil), await until(5, { c.list.groups[0].icon == nil && c.sidebar.groupRow(g)?.icon == nil }), storedGroups().first?.icon == nil else {
            return finish(false, "Remove Icon left the group's icon \(String(describing: c.list.groups[0].icon)), row \(String(describing: c.sidebar.groupRow(g)?.icon)), stored \(String(describing: storedGroups().first?.icon))")
        }
        finish(violations.isEmpty, "Change Icon... on a tab and on a group (menus, then a picked cell): an emoji and a symbol set customIcon or the group's icon (list, store and the row's image or glyph), Remove Icon clears them and the row shows the page's favicon (or the default icon) again \(violations)")
    }

    /// Two phases. Phase 1: a group is named, colored (pink), given an emoji and collapsed, and a tab gets a symbol icon. Phase 2, after a relaunch: the
    /// group's name, color, icon and collapsed state, and the tab's icon, are all back, in the list and on the rows.
    func groupRestore() async {
        if phase == 1 {
            guard await ready(), let c = ctl, let win, let writer = app.writer else { return }
            _ = win.addTab(withURL: fixture("b.html"), activate: false)
            guard await until(20, { c.list.items.count == 2 && c.list.items.allSatisfy { !$0.title.isEmpty } }) else { return finish(false, "phase 1: titles \(c.list.items.map(\.title))") }
            let t = c.list.items.map(\.id)
            guard await select(c, t[0]) else { return finish(false, "phase 1: tab A did not activate") }
            IconPicker.dismiss()
            c.newGroupWithTab(t[1])
            guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id, await until(5, { c.sidebar.groupRow(g)?.renameField.isEditing == true }), let field = c.sidebar.groupRow(g)?.renameField else { return finish(false, "phase 1: no group") }
            typeName(field, "Kept")
            c.setGroupColor(g, 5)
            c.changeIcon(group: g)
            guard pickIcon("🔥") else { return finish(false, "phase 1: the group's picker did not take 🔥") }
            c.changeIcon(tab: t[0])
            guard pickIcon("star") else { return finish(false, "phase 1: the tab's picker did not take star") }
            c.toggleGroup(g)
            guard await until(5, { c.list.groups[0].isCollapsed && c.list.groups[0].icon == "🔥" && c.list.groups[0].colorIndex == 5 && self.entry(c, t[0])?.customIcon == "star" }) else { return finish(false, "phase 1: the group is \(c.list.groups[0]), tab A's icon \(String(describing: entry(c, t[0])?.customIcon))") }
            writer.flush()
            guard let sg = storedGroups().first, sg.name == "Kept", sg.colorIndex == 5, sg.icon == "🔥", sg.isCollapsed, stored(t[0])?.customIcon == "star" else {
                return finish(false, "phase 1: stored group \(String(describing: storedGroups().first)), tab A's stored icon \(String(describing: stored(t[0])?.customIcon))")
            }
            return finish(violations.isEmpty, "phase 1: a group named Kept, pink, with an emoji, collapsed, and a tab with a symbol icon are stored \(violations)")
        }
        guard await until(30, { self.restoredUp(1) }), let c = ctl else { return finish(false, "phase 2: no restored window") }
        guard await until(20, { c.list.items.count == 2 && c.list.groups.count == 1 }) else { return finish(false, "phase 2: \(c.list.items.count) items, \(c.list.groups.count) groups") }
        let g = c.list.groups[0]
        guard g.name == "Kept", g.colorIndex == 5 else { return finish(false, "phase 2: the group is \(g.name) with color \(g.colorIndex), want Kept and 5") }
        guard g.icon == "🔥" else { return finish(false, "phase 2: the group's icon is \(String(describing: g.icon)), want 🔥") }
        guard g.isCollapsed, c.list.items.filter({ $0.groupID == g.id }).count == 1 else { return finish(false, "phase 2: the group is collapsed \(g.isCollapsed) holding \(c.list.items.filter { $0.groupID == g.id }.count) tabs, want collapsed with 1") }
        guard let a = c.list.items.first(where: { $0.groupID == nil }), a.customIcon == "star" else { return finish(false, "phase 2: tab A's customIcon is \(String(describing: c.list.items.first { $0.groupID == nil }?.customIcon)), want star") }
        guard await until(5, { c.sidebar.groupRow(g.id)?.icon == "🔥" && c.sidebar.groupRow(g.id)?.colorIndex == 5 && c.sidebar.groupRow(g.id)?.isCollapsed == true && self.rowShows(c, a.id, "star") }) else {
            return finish(false, "phase 2: the group's row shows icon \(String(describing: c.sidebar.groupRow(g.id)?.icon)), color \(String(describing: c.sidebar.groupRow(g.id)?.colorIndex)), and tab A's row shows the symbol: \(rowShows(c, a.id, "star"))")
        }
        finish(violations.isEmpty, "phase 2: the group Kept (pink, 🔥, collapsed, one tab) and tab A's symbol icon survive the relaunch, in the list and on the rows \(violations)")
    }

    /// A rename in progress on a group row that scrolls out of the 40 view window is cancelled: 60 tabs under 2 open groups, the first group's name is edited
    /// to "Half" (no Return), the row scrolls away, and the name is still Reading.
    func groupRenameScroll() async {
        guard await ready(), let c = ctl else { return }
        var items = (0..<60).map { TabItem(id: TabID(), engineID: $0, url: "https://site\($0).example/", title: "Tab \($0)", isLoading: false) }
        let g = TabGroup(id: GroupID(), name: "Reading", colorIndex: 0, icon: nil, isCollapsed: false, isPinned: false)
        for i in 0..<2 { items[i].groupID = g.id }
        guard let seeded = TabList(items: items, groups: [g], topOrder: [], dayOrder: [.group(g.id)] + items[2...].map { .tab($0.id) }, activeID: items[59].id) else { return finish(false, "no seeded list") }
        c.testSeed(seeded)
        c.beginRename(group: g.id)
        guard let field = c.sidebar.groupRow(g.id)?.renameField, field.isEditing else { return finish(false, "the group's name is not in edit") }
        field.stringValue = "Half"  // typed, not committed
        let scroll = c.sidebar.scroll
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, c.sidebar.document.frame.height - scroll.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        guard c.sidebar.groupRow(g.id) == nil else { return finish(false, "the group row still has a view at the end of the list") }
        guard !field.isEditing, c.list.groups[0].name == "Reading" else { return finish(false, "the row scrolled out while editing: the group is named \(c.list.groups[0].name), the field editing \(field.isEditing), want Reading and the edit ended") }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        guard await until(5, { c.sidebar.groupRow(g.id)?.name == "Reading" && c.sidebar.groupRow(g.id)?.renameField.isEditing == false }) else { return finish(false, "back at the top the row shows \(String(describing: c.sidebar.groupRow(g.id)?.name))") }
        finish(violations.isEmpty, "a rename typed to Half and not committed is cancelled when the row scrolls out: the name stays Reading, the field is not left in edit, and the row is back as Reading \(violations)")
    }

    // MARK: rename-focus

    /// The tab's row field, in edit with the first responder on it (not on the page): Rename... from the tab's menu.
    func startTabRename(_ c: BrowserWindowController, _ id: TabID) async -> RenameField? {
        guard let m = await tabMenu(c, id) else { return nil }
        choose(m.menu, "Rename...")
        guard let f = c.sidebar.rows.first(where: { $0.tabID == id })?.renameField, f.isEditing, let ns = c.nsWindow, ns.firstResponder === f.currentEditor(), !inPage() else { return nil }
        return f
    }

    /// How a rename ends (rulings M89 and M90). Escape on a tab rename and on a group rename gives focus back to the page, as Return does; a click elsewhere (the
    /// command bar's field takes first responder while the rename is open) commits and leaves focus on that control; a rename whose row scrolled out gives focus
    /// back to the page; and Return on an untouched rename of a blank tab sets no custom title.
    func renameFocus() async {
        guard await ready(), let c = ctl, let win, let ns = c.nsWindow else { return }
        guard await openTabs(2) else { return finish(false, "extra tabs never appeared") }
        let t = c.list.items.map(\.id)
        line("info", "step: Return on an untouched rename of a blank tab sets no custom title.")
        _ = win.addTab(withURL: "about:blank", activate: false)
        guard await until(10, { c.list.items.count == 3 }), let b = c.list.items.first(where: { !t.contains($0.id) }), b.url == "about:blank", b.customTitle == nil, TabList.displayTitle(for: b) == "New Tab" else {
            return finish(false, "no blank third tab with no custom title: \(c.list.items.map { "\($0.url) \(String(describing: $0.customTitle))" })")
        }
        guard let fb = await startTabRename(c, b.id), fb.stringValue == "New Tab" else { return finish(false, "Rename... on the blank tab did not start an edit on \"New Tab\"") }
        typeName(fb, fb.stringValue)  // Return, the field untouched
        try? await Task.sleep(for: .milliseconds(300))
        guard !fb.isEditing, entry(c, b.id)?.customTitle == nil, stored(b.id)?.customTitle == nil else {
            return finish(false, "Return on an untouched rename of the blank tab left customTitle \(String(describing: entry(c, b.id)?.customTitle)), stored \(String(describing: stored(b.id)?.customTitle)), want none")
        }
        line("info", "step: Escape on a tab rename returns focus to the page.")
        guard let f1 = await startTabRename(c, t[1]) else { return finish(false, "Rename... on a tab did not give the field first responder (\(String(describing: ns.firstResponder)))") }
        typeName(f1, "Nope", cancel: true)
        guard await until(5, { self.inPage() }) else { return finish(false, "after Escape on a tab rename the first responder is \(String(describing: ns.firstResponder)), want the page") }
        guard !f1.isEditing, entry(c, t[1])?.customTitle == nil else { return finish(false, "Escape left editing \(f1.isEditing) and customTitle \(String(describing: entry(c, t[1])?.customTitle))") }
        line("info", "step: Escape on a group rename returns focus to the page.")
        c.newGroupWithTab(t[1])
        guard await until(5, { c.list.groups.count == 1 }), let g = c.list.groups.first?.id, await until(5, { c.sidebar.groupRow(g)?.renameField.isEditing == true }), let fg = c.sidebar.groupRow(g)?.renameField,
              ns.firstResponder === fg.currentEditor(), !inPage() else { return finish(false, "the new group's name field does not hold first responder (\(String(describing: ns.firstResponder)))") }
        typeName(fg, "Nope", cancel: true)
        guard await until(5, { self.inPage() }) else { return finish(false, "after Escape on a group rename the first responder is \(String(describing: ns.firstResponder)), want the page") }
        guard c.list.groups[0].name == "Untitled", !fg.isEditing else { return finish(false, "Escape left the group named \(c.list.groups[0].name), editing \(fg.isEditing)") }
        line("info", "step: a click elsewhere commits and leaves focus on the control that was clicked (a plain field, then the address field).")
        guard let host = win.chromeHost, let fp = await startTabRename(c, t[0]) else { return finish(false, "Rename... on tab A did not give the field first responder (\(String(describing: ns.firstResponder)))") }
        let other = NSTextField(frame: NSRect(x: 300, y: 300, width: 200, height: 24))
        host.addSubview(other)
        defer { other.removeFromSuperview() }
        fp.stringValue = "Plain"  // typed, not committed
        guard ns.makeFirstResponder(other) else { return finish(false, "a plain field refused first responder") }
        try? await Task.sleep(for: .milliseconds(500))  // a focus hand-back to the page would come in a turn of its own
        guard ns.firstResponder === other.currentEditor(), !inPage(), !fp.isEditing, entry(c, t[0])?.customTitle == "Plain" else {
            return finish(false, "after a click on a plain field the first responder is \(String(describing: ns.firstResponder)) (want that field's editor), the rename is editing \(fp.isEditing) with customTitle \(String(describing: entry(c, t[0])?.customTitle)) (want Plain)")
        }
        other.removeFromSuperview()
        guard let f2 = await startTabRename(c, t[0]) else { return finish(false, "Rename... on tab A did not give the field first responder (\(String(describing: ns.firstResponder)))") }
        f2.stringValue = "Clicked"  // typed, not committed
        cmdL()  // the address field takes first responder: what a click on it does
        guard await until(5, { self.barOpen() && self.barEditor != nil && ns.firstResponder === self.barEditor }) else { return finish(false, "Cmd+L did not give the command bar's field first responder (\(String(describing: ns.firstResponder)))") }
        try? await Task.sleep(for: .milliseconds(500))  // a focus hand-back to the page would come in a turn of its own
        guard ns.firstResponder === barEditor, barOpen(), !inPage(), !f2.isEditing, entry(c, t[0])?.customTitle == "Clicked" else {
            return finish(false, "after the click the first responder is \(String(describing: ns.firstResponder)) (want the address field's editor), the rename is editing \(f2.isEditing) with customTitle \(String(describing: entry(c, t[0])?.customTitle)) (want Clicked)")
        }
        closeBarNow()  // the bar's close hands focus back to the page, in a turn of the engine's own
        guard await until(5, { self.inPage() }) else { return finish(false, "closing the command bar did not give focus back to the page (\(String(describing: ns.firstResponder)))") }
        try? await Task.sleep(for: .milliseconds(500))
        line("info", "step: a rename whose row scrolled out gives focus back to the page.")
        var items = (0..<60).map { TabItem(id: TabID(), engineID: $0, url: "https://site\($0).example/", title: "Tab \($0)", isLoading: false) }
        let sg = TabGroup(id: GroupID(), name: "Reading", colorIndex: 0, icon: nil, isCollapsed: false, isPinned: false)
        for i in 0..<2 { items[i].groupID = sg.id }
        guard let seeded = TabList(items: items, groups: [sg], topOrder: [], dayOrder: [.group(sg.id)] + items[2...].map { .tab($0.id) }, activeID: items[59].id) else { return finish(false, "no seeded list") }
        c.testSeed(seeded)
        c.beginRename(group: sg.id)
        guard let fs = c.sidebar.groupRow(sg.id)?.renameField, fs.isEditing, ns.firstResponder === fs.currentEditor() else { return finish(false, "the seeded group's name field does not hold first responder (\(String(describing: ns.firstResponder)))") }
        let scroll = c.sidebar.scroll
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, c.sidebar.document.frame.height - scroll.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        guard !fs.isEditing, await until(5, { self.inPage() }) else { return finish(false, "after the row scrolled out the field editing is \(fs.isEditing) and the first responder is \(String(describing: ns.firstResponder)), want the page") }
        finish(violations.isEmpty, "Return on an untouched rename of a blank tab sets no custom title (list and store); Escape on a tab rename and on a group rename, and a rename whose row scrolled out, give focus back to the page; a click elsewhere (the command bar's field) commits the rename and leaves focus on that field \(violations)")
    }
}
#endif
