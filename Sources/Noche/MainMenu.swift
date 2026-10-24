import AppKit

/// The M1.1 main menu (titles and shortcuts from live-ui.md section 9, the reference's app menu named Noche). App actions
/// target the AppDelegate, which routes them to the active window's controller; the edit items go to that window's first responder
/// (the address field's editor or the page), key window or not.
@MainActor
enum MainMenu {
    static func build(app: AppDelegate) -> NSMenu {
        let cmd: NSEvent.ModifierFlags = .command
        let shift: NSEvent.ModifierFlags = [.command, .shift]
        func a(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = item(title, action, key, mods)
            i.target = app
            return i
        }
        let main = ShortcutMenu()
        main.addItem(submenu("Noche", [
            item("About Noche", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Noche", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Noche", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            a("New Tab", #selector(AppDelegate.newTab(_:)), "t"),
            a("New Window", #selector(AppDelegate.newWindowMenu(_:)), "n"),
            a("Open Command Bar", #selector(AppDelegate.openCommandBar(_:)), "l"),
            .separator(),
            a("Close Window", #selector(AppDelegate.closeWindowMenu(_:)), "w", shift),
            a("Close Tab", #selector(AppDelegate.closeTab(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            a("Undo", #selector(AppDelegate.undo(_:)), "z"),
            a("Redo", #selector(AppDelegate.redo(_:)), "z", shift),
            .separator(),
            a("Cut", #selector(AppDelegate.cut(_:)), "x"),
            a("Copy", #selector(AppDelegate.copy(_:)), "c"),
            a("Copy URL", #selector(AppDelegate.copyURL(_:)), "c", shift),
            a("Paste", #selector(AppDelegate.paste(_:)), "v"),
            a("Select All", #selector(AppDelegate.selectAll(_:)), "a"),
        ]))
        let developer = submenu("Developer", [
            a("Developer Tools", #selector(AppDelegate.developerTools(_:)), "i", [.command, .option]),
        ])
        main.addItem(submenu("View", [
            a("Refresh", #selector(AppDelegate.refresh(_:)), "r"),
            a("Force Refresh the Page", #selector(AppDelegate.forceRefresh(_:)), "r", shift),
            .separator(),
            a("Auto-Hide Tabs", #selector(AppDelegate.toggleSidebar(_:)), "s"),
            .separator(),
            a("Zoom to Actual Size", #selector(AppDelegate.zoomActual(_:)), "0"),
            a("Zoom In", #selector(AppDelegate.zoomIn(_:)), "+", cmd),
            a("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-", cmd),
            .separator(),
            developer,
        ]))
        main.addItem(submenu("Tabs", [
            a("Go Back", #selector(AppDelegate.goBack(_:)), "[", cmd),
            a("Go Forward", #selector(AppDelegate.goForward(_:)), "]", cmd),
            a("Next Tab", #selector(AppDelegate.nextTab(_:)), "]", shift),
            a("Previous Tab", #selector(AppDelegate.previousTab(_:)), "[", shift),
        ]))
        main.addItem(submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ]))
        return main
    }

    /// `title|key|modifiers` per item in order, a submenu's own line first; separators are left out.
    static func dump(_ menu: NSMenu) -> [String] {
        var out: [String] = []
        for i in menu.items where !i.isSeparatorItem {
            var mods: [String] = []
            let m = i.keyEquivalentModifierMask
            if m.contains(.control) { mods.append("ctrl") }
            if m.contains(.option) { mods.append("opt") }
            if m.contains(.shift) { mods.append("shift") }
            if m.contains(.command) { mods.append("cmd") }
            // AppKit rewrites "[" and "]" to the layout's own keys (the Spanish layout gives "ñ" and "´"): report the US ones.
            let key = ["ñ": "[", "´": "]"][i.keyEquivalent] ?? i.keyEquivalent
            out.append("\(i.title)|\(key)|\(i.keyEquivalent.isEmpty ? "" : mods.joined(separator: "+"))")
            if let sub = i.submenu { out += dump(sub) }
        }
        return out
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = true
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}

/// The main menu with exact shortcut matching. AppKit's own matching lets a plain Cmd+W or Cmd+] fire Close Window or Next Tab
/// (the Shift item listed first), so an item whose key and full modifier set equal the event's wins; everything else falls back to AppKit.
final class ShortcutMenu: NSMenu {
    private static let unshifted: [Character: Character] = ["{": "[", "}": "]", "+": "=", "_": "-"]
    private static let shifted = Dictionary(uniqueKeysWithValues: unshifted.map { ($1, $0) })

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typed = [event.charactersIgnoringModifiers, event.characters].compactMap { $0?.lowercased() }.compactMap(\.first)
        let keys = Set(typed + typed.compactMap { Self.unshifted[$0] } + typed.compactMap { Self.shifted[$0] })
#if NOCHE_TESTHOOKS
        // Negative control: AppKit's own matching only.
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NOEXACT"] == "1" { return super.performKeyEquivalent(with: event) }
#endif
        // A shifted key typed with Shift (Cmd+Shift+= is "+" on a US layout) matches the item keyed "+" that has no Shift of its own.
        let viaShift = Set(typed.compactMap { Self.shifted[$0] })
        if let item = match(self, keys, mods) ?? (mods.contains(.shift) ? match(self, viaShift, mods.subtracting(.shift)) : nil), let menu = item.menu {
            menu.update()
            if item.isEnabled, let i = menu.items.firstIndex(of: item) { menu.performActionForItem(at: i) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func match(_ menu: NSMenu, _ keys: Set<Character>, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu.items {
            if let sub = item.submenu, let hit = match(sub, keys, mods) { return hit }
            if let c = item.keyEquivalent.lowercased().first, keys.contains(c), item.keyEquivalentModifierMask == mods { return item }
        }
        return nil
    }
}
