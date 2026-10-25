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
        /// The table's US key for the item. AppKit rewrites `keyEquivalent` for the machine's layout (a Spanish layout turns "[" into "ñ"), so
        /// `ShortcutMenu` matches an event against both.
        nonisolated let usKey: String
        @MainActor init(_ entry: MenuEntry) { self.entry = entry; usKey = entry.key }
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
#if NOCHE_TESTHOOKS
        // Negative control for menu-diff's selector check: Copy carries Paste's action.
        let action = ProcessInfo.processInfo.environment["NOCHE_TEST_MENU_SELECTOR"] == "1" && e.title == "Copy" ? #selector(NSText.paste(_:)) : e.action
#else
        let action = e.action
#endif
        let i = NSMenuItem(title: e.title, action: action, keyEquivalent: e.key)
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
    /// Every US shifted pair: the shifted character and its key. A chord typed with Shift (Cmd+Shift+; is ":" on a US layout, Ctrl+Shift+' is '"')
    /// matches an item keyed by the shifted character that has no Shift of its own, and one keyed by the base key with Shift.
    private static let unshifted: [Character: Character] = {
        var m: [Character: Character] = ["{": "[", "}": "]", "+": "=", "_": "-", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\", "~": "`"]
        for (s, d) in zip("!@#$%^&*()", "1234567890") { m[s] = d }
        return m
    }()
    private static let shifted = Dictionary(uniqueKeysWithValues: unshifted.map { ($1, $0) })
    var commands: [(chord: Chord, title: String, run: () -> Void)] = []

    /// The item whose key and full modifier set equal the event's, wherever it is in the bar. In three steps, so a chord never lands on a neighbour:
    /// the exact typed key (Cmd+; is Check Document Now, never Show Spelling, which sits earlier in the menu), then the mapped keys, then the
    /// shifted symbol of any of them with Shift taken out (Shift+Cmd+; is Cmd+:). Real events come in two shapes, Shift kept in
    /// charactersIgnoringModifiers (":") or folded (";"); both land on the same item.
    func item(for event: NSEvent) -> NSMenuItem? {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typed = [event.charactersIgnoringModifiers, event.characters].compactMap { $0?.lowercased() }.compactMap(\.first)
        let keys = Set(typed + typed.compactMap { Self.unshifted[$0] } + typed.compactMap { Self.shifted[$0] })
        var viaShift = Set(keys.compactMap { Self.shifted[$0] })
        var exact: NSMenuItem? = match(self, Set(typed), mods)
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_SHIFTMAP"] == "1" { viaShift = [] }  // negative control: no shifted-punctuation matching
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_EXACTFIRST"] == "1" { exact = nil }  // negative control: mapped keys at once, first item in menu order wins
#endif
        return exact ?? match(self, keys, mods) ?? (mods.contains(.shift) ? match(self, viaShift, mods.subtracting(.shift)) : nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typed = [event.charactersIgnoringModifiers, event.characters].compactMap { $0?.lowercased() }.compactMap(\.first)
        let keys = Set(typed + typed.compactMap { Self.unshifted[$0] } + typed.compactMap { Self.shifted[$0] })
#if NOCHE_TESTHOOKS
        // Negative control: AppKit's own matching only.
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NOEXACT"] == "1" { return super.performKeyEquivalent(with: event) }
#endif
        if let item = item(for: event), let menu = item.menu {
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
            let own = [item.keyEquivalent, (item.representedObject as? MainMenu.Rule)?.usKey ?? ""].compactMap { $0.lowercased().first }
            if own.contains(where: keys.contains), item.keyEquivalentModifierMask == mods { return item }
        }
        return nil
    }
}
