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
        guard let cm = await tabMenu(c, t[2]), let mg = item(cm.menu, "Move to Group"), mg.isEnabled, mg.submenu?.items.map(\.title) == ["Reading"], mg.submenu?.items.first?.state == .off else {
            return finish(false, "C's Move to Group menu is \(String(describing: (await tabMenu(c, t[2]))?.menu.items.first { $0.title == "Move to Group" }?.submenu?.items.map(\.title))), want enabled with Reading")
        }
        ContextMenus.dismiss(choosing: mg.submenu?.items.first)
        guard await until(5, { self.entry(c, t[2])?.groupID == g }), c.list.items.filter({ $0.groupID == g }).map(\.id) == [t[1], t[2]], !c.list.groups[0].isCollapsed, c.list.dayOrder == [.tab(t[0]), .group(g)] else {
            return finish(false, "Move to Group left C in \(String(describing: entry(c, t[2])?.groupID)), the group holds \(c.list.items.filter { $0.groupID == g }.count), day list \(c.list.dayOrder)")
        }
        line("info", "step: B's menu shows its own group checked, and so does the Tabs m")
        guard let bm = await tabMenu(c, t[1]), item(bm.menu, "Move to Group")?.submenu?.items.first?.state == .on else { return finish(false, "B's Move to Group does not check Reading") }
        ContextMenus.dismiss(choosing: nil)
        guard let bar = menuItem("Move to Group")?.submenu else { return finish(false, "no Tabs > Move to Group submenu") }
        bar.update()
        bar.delegate?.menuNeedsUpdate?(bar)  // AppKit asks the delegate just before it shows the menu (update() does not)
        guard bar.items.map(\.title) == ["Reading"], bar.items.first?.state == .on else { return finish(false, "Tabs > Move to Group lists \(bar.items.map(\.title)), want Reading checked for B") }
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
        finish(violations.isEmpty, "Ctrl+Cmd+N groups the active tab with its name in edit (Return commits, Escape cancels), a click collapses and opens it, Move to Group and Opt+Cmd+T (disabled off a group) fill it, Pin and Unpin move it, Copy All Links, Duplicate and Move to Bookmark Bar act, Delete asks first for 3 tabs (refused: nothing closes) and not for 1, Separate Tabs keeps the tabs, the sidebar menu's New Group makes an empty one \(violations)")
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

    /// A view that draws the folder symbol in |rgb| the way the group row does, written out here from the hand-listed colors: the reference the
    /// row's icon is compared with, through the same bitmap path (the bitmap's color space shifts a thin stroke, so a bare color match reads nothing).
    final class IconReference: NSView {
        let rgb: UInt32, icon: NSRect
        /// |icon| is where the row draws the symbol inside a view of |size|: the same fractional position gives the same antialiasing.
        init(_ rgb: UInt32, size: NSSize, icon: NSRect) { self.rgb = rgb; self.icon = icon; super.init(frame: NSRect(origin: .zero, size: size)); wantsLayer = true }  // layer-backed like the row: the same compositing
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
            guard let base = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return }
            NSImage(size: base.size, flipped: false) { r in base.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true }.draw(in: icon)
        }
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
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return ([0, 0, 0], 0) }
        v.cacheDisplay(in: v.bounds, to: rep)
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

    /// The palette index whose reference icon looks most like |rect| of |v|, with the icon's pixel count.
    func nearestSwatch(_ v: NSView, in rect: NSRect, palette: [UInt32]) -> (index: Int, n: Int, detail: String) {
        let got = meanColor(v, in: rect)
        let refs = palette.map { meanColor(IconReference($0, size: v.bounds.size, icon: rect), in: rect).rgb }
        // The row's thin stroke is a little paler than the reference's: each reference may be mixed with up to 30% white before the comparison.
        let d = refs.map { r in stride(from: 0.0, through: 0.3, by: 0.01).map { t in zip(r, got.rgb).map { pow($0 * (1 - t) + t - $1, 2) }.reduce(0, +) }.min()! }
        return (d.firstIndex(of: d.min()!)!, got.n, "mean \(got.rgb.map { ($0 * 1000).rounded() / 1000 }) distances \(d.map { ($0 * 1000).rounded() / 1000 }) refs \(refs.map { $0.map { ($0 * 1000).rounded() / 1000 } })")
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
            let (nearest, painted, detail) = nearestSwatch(row, in: icon, palette: palette)
            guard painted >= 3, nearest == i else { return finish(false, "swatch \(i): the icon (\(painted) pixels) looks most like swatch \(nearest) of the hand-listed colors, want \(i) (\(detail))") }
            // The outline of the open group.
            guard await until(5, { c.sidebar.boxesView.boxes.first?.colorIndex == i }), let box = c.sidebar.boxesView.boxes.first, let px = edge(c.sidebar.boxesView, of: box.frame) else { return finish(false, "swatch \(i): no outline box") }
            if i == 0 {
                guard px.alphaComponent < 0.3, px.redComponent > 0.85, px.blueComponent > 0.85 else { return finish(false, "swatch 0: the outline is rgba \(px.redComponent), \(px.greenComponent), \(px.blueComponent), \(px.alphaComponent), want a faint white") }
            } else {
                // Compared with the outline drawn here in each hand-listed color at 0.55 (white 5% fill under it), through the same bitmap path.
                let box0 = NSRect(x: 0, y: 0, width: box.frame.width, height: box.frame.height)
                let refs = palette.map { edge(OutlineReference($0, size: box0.size), of: box0) }
                func dist(_ r: NSColor?) -> CGFloat {  // as for the icon: the reference may be mixed with up to 30% white
                    guard let r else { return 9 }
                    return stride(from: 0.0, through: 0.3, by: 0.01).map { t in pow(r.redComponent * (1 - t) + t - px.redComponent, 2) + pow(r.greenComponent * (1 - t) + t - px.greenComponent, 2) + pow(r.blueComponent * (1 - t) + t - px.blueComponent, 2) + pow(r.alphaComponent - px.alphaComponent, 2) }.min()!
                }
                let d = refs.map(dist)
                guard px.alphaComponent > 0.4, d.firstIndex(of: d.min()!) == i else {
                    return finish(false, "swatch \(i): the outline is rgba \(px.redComponent), \(px.greenComponent), \(px.blueComponent), \(px.alphaComponent) and looks most like swatch \(d.firstIndex(of: d.min()!) ?? -1) of the hand-listed colors at 0.55")
                }
            }
        }
        finish(violations.isEmpty, "the 8 swatches in order (white, green, blue, purple, amber, pink, red, orange) set colorIndex 0 to 7, stored, and the icon and the outline of the open group draw in that color (read back from the pixels) \(violations)")
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
        guard let m2 = await tabMenu(c, t[0]), item(m2.menu, "Move to Group")?.isEnabled == true, item(m2.menu, "Move to Group")?.submenu?.items.map(\.title) == ["Reading"] else { return finish(false, "A's Move to Group does not list Reading") }
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
            return finish(violations.isEmpty, "phase 1: Rename... (tab menu, Tabs menu, a pinned tile's popover) set Mine and Tile over the page titles, the page's title changing left Mine, Escape kept it, an empty name cleared Zed, stored \(violations)")
        }
        guard await until(30, { self.restoredUp(1) }), let c = ctl else { return finish(false, "phase 2: no restored window") }
        guard await until(20, { c.list.items.count == 2 }) else { return finish(false, "phase 2: \(c.list.items.count) items") }
        let items = c.list.items
        guard items[0].customTitle == "Tile", items[1].customTitle == "Mine", items[0].isPinned else { return finish(false, "phase 2: custom titles \(items.map { $0.customTitle ?? "nil" }), pinned \(items[0].isPinned), want Tile and Mine") }
        guard await until(20, { !(c.list.items[1].title.isEmpty) }), c.list.items[1].title != "Mine" else { return finish(false, "phase 2: the page's title is \(c.list.items[1].title)") }
        guard await until(5, { c.sidebar.rows.first?.titleField.stringValue == "Mine" }) else { return finish(false, "phase 2: the row shows \(String(describing: c.sidebar.rows.first?.titleField.stringValue)), page title \(c.list.items[1].title), want Mine") }
        finish(violations.isEmpty, "phase 2: the custom titles Tile (pinned, dormant) and Mine (over the page's \(c.list.items[1].title)) survive the relaunch and the row shows Mine \(violations)")
    }
}
#endif
