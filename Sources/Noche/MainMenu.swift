import AppKit
import NocheCore

/// The menu bar, built from `MenuTable.bar` (live-ui.md section 9). App actions target the AppDelegate, which routes them to the active window's
/// controller; the standard items have no target: they go to the key window's first responder through the responder chain (the command bar's
/// field editor or the page). Every item built here carries `MenuTable.mark` and a `MenuRule` that the AppDelegate validates it with.
@MainActor
enum MainMenu {
    /// The item's table row, kept on the item (representedObject) so validation and the checks can read its rule.
    final class Rule: NSObject {
        let entry: MenuEntry
        init(_ entry: MenuEntry) { self.entry = entry }
    }

    static func build(app: AppDelegate) -> NSMenu {
        let main = ShortcutMenu()
        main.commands = MenuTable.commands.map { c in (c.chord, c.title, { [unowned app] in c.run(app) }) }
        for entry in MenuTable.bar { main.addItem(item(entry, app: app)) }
        return main
    }

    private static func item(_ e: MenuEntry, app: AppDelegate) -> NSMenuItem {
        if e.separator {
            let s = NSMenuItem.separator()
            s.identifier = MenuTable.mark
            return s
        }
#if NOCHE_TESTHOOKS
        // Negative control for menu-diff: the table loses History > Show History...
        let drift = ProcessInfo.processInfo.environment["NOCHE_TEST_MENU_DRIFT"] == "1"
#else
        let drift = false
#endif
        let i = NSMenuItem(title: e.title, action: e.action, keyEquivalent: e.key)
        i.keyEquivalentModifierMask = e.modifiers
        i.target = e.viaResponder ? nil : (e.action == nil ? nil : app)
        i.tag = e.tag
        i.identifier = MenuTable.mark
        i.representedObject = Rule(e)
        if let sub = e.submenu {
            let menu = NSMenu(title: e.title)
            menu.autoenablesItems = true
            for s in sub where !(drift && s.title == "Show History...") { menu.addItem(item(s, app: app)) }
            i.submenu = menu
            switch e.role {
            case .services: NSApp.servicesMenu = menu
            case .windows: NSApp.windowsMenu = menu
            case .help: NSApp.helpMenu = menu
            case nil: break
            }
        }
        return i
    }
}

/// The main menu with exact shortcut matching. AppKit's own matching lets a plain Cmd+W or Cmd+] fire Close Window or Next Tab
/// (the Shift item listed first), so an item whose key and full modifier set equal the event's wins; a key that matches nothing exactly is left to the page.
/// Key commands that have no menu item (`MenuTable.commands`) are matched the same way after the items.
final class ShortcutMenu: NSMenu {
    private static let unshifted: [Character: Character] = ["{": "[", "}": "]", "+": "=", "_": "-"]
    private static let shifted = Dictionary(uniqueKeysWithValues: unshifted.map { ($1, $0) })
    var commands: [(chord: Chord, title: String, run: () -> Void)] = []

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
#if NOCHE_TESTHOOKS
            // Negative control for menu-disabled: a disabled item acts anyway.
            if ProcessInfo.processInfo.environment["NOCHE_TEST_MENU_NODISABLE"] == "1" { item.isEnabled = true }
#endif
            if item.isEnabled, let i = menu.items.firstIndex(of: item) { menu.performActionForItem(at: i) }
            return true
        }
        if let c = commands.first(where: { c in
            let k = c.chord.menuKey
            return k.mods == mods && k.key.lowercased().first.map(keys.contains) == true
        }) {
            c.run()
            return true
        }
        // Not AppKit's own matching: it ignores extra Shift and Option, so a plain Cmd+K would fire Close All Tabs (Shift+Cmd+K) instead of reaching the page.
        return false
    }

    private func match(_ menu: NSMenu, _ keys: Set<Character>, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu.items {
            if let sub = item.submenu, let hit = match(sub, keys, mods) { return hit }
            if let c = item.keyEquivalent.lowercased().first, keys.contains(c), item.keyEquivalentModifierMask == mods { return item }
        }
        return nil
    }
}
