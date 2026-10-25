import AppKit
import NocheCore

/// What an enable rule may look at: the app and the window the menu acts on (nil with no window open).
@MainActor
struct MenuContext {
    let app: AppDelegate
    let window: BrowserWindowController?
}

/// One row of the menu bar. The key and modifiers are not stored here: they come from NocheCore's `ShortcutDefaults` by |id|, so a chord
/// has one source of truth. |action| nil means the item is present but disabled until its feature arrives (|milestone| says when).
@MainActor
struct MenuEntry {
    typealias Rule = @MainActor (MenuContext) -> Bool
    var title: String
    var id: String?
    var action: Selector?
    var viaResponder = false          // nil target: the responder chain (the page, the field editor, NSApp or the window) answers
    var enabled: Rule = { $0.window != nil }
    var state: Rule?                  // checkmark
    var submenu: [MenuEntry]?
    var separator = false
    var tag = 0
    var milestone: String?
    var role: Role?
    enum Role { case services, windows, help }

    var chord: Chord? { id.flatMap(ShortcutDefaults.chord(for:)) }
    var key: String { chord?.menuKey.key ?? "" }
    var modifiers: NSEvent.ModifierFlags { chord?.menuKey.mods ?? [] }
}

/// A key command with no menu item: answered by `ShortcutMenu` with the same exact matching as the items.
@MainActor
struct MenuCommand {
    let title: String
    let id: String
    let run: @MainActor (AppDelegate) -> Void
    var chord: Chord { ShortcutDefaults.chord(for: id)! }
}

extension Chord {
    /// The NSMenuItem form: Shift+= is "+" with no Shift of its own (Cmd++ is Zoom In), Cmd+Shift+; is ":" with Command only.
    var menuKey: (key: String, mods: NSEvent.ModifierFlags) {
        var m: NSEvent.ModifierFlags = []
        if mods & Chord.cmd != 0 { m.insert(.command) }
        if mods & Chord.shift != 0 { m.insert(.shift) }
        if mods & Chord.opt != 0 { m.insert(.option) }
        if mods & Chord.ctrl != 0 { m.insert(.control) }
        if m.contains(.shift), key == "=" { return ("+", m.subtracting(.shift)) }
        if m == [.command, .shift], key == ";" { return (":", .command) }
        let named = ["pagedown": NSPageDownFunctionKey, "pageup": NSPageUpFunctionKey, "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey]
        if let f = named[key], let u = UnicodeScalar(f) { return (String(u), m) }
        return (["return": "\r", "tab": "\t"][key] ?? key, m)
    }
}

/// The menu bar of live-ui.md section 9 (the reference's app menu named Noche) as data; `MainMenu.build` turns it into the NSMenu and
/// tests/fixtures/app/menu-expected.txt, transcribed from section 9, is what the `menu-diff` check compares the live bar with.
@MainActor
enum MenuTable {
    static let mark = NSUserInterfaceItemIdentifier("noche.menu")
    private typealias E = MenuEntry

    private static let always: E.Rule = { _ in true }
    private static let hasWindow: E.Rule = { $0.window != nil }
    private static let sep = E(title: "", separator: true)

    /// A working item whose target is the AppDelegate.
    private static func app(_ title: String, _ id: String?, _ action: Selector, enabled: @escaping E.Rule = hasWindow, state: E.Rule? = nil, tag: Int = 0) -> E {
        E(title: title, id: id, action: action, enabled: enabled, state: state, tag: tag)
    }
    /// A standard system action on the responder chain (the field editor or the page, NSApp, the window).
    private static func std(_ title: String, _ action: Selector, _ id: String? = nil) -> E { E(title: title, id: id, action: action, viaResponder: true) }
    /// Present and disabled until |milestone|.
    private static func later(_ title: String, _ id: String?, _ milestone: String) -> E { E(title: title, id: id, milestone: milestone) }
    private static func later(_ title: String, _ milestone: String) -> E { E(title: title, milestone: milestone) }
    private static func menu(_ title: String, _ items: [E], role: E.Role? = nil) -> E { E(title: title, submenu: items, role: role) }

    static let bar: [MenuEntry] = [
        menu("Noche", [
            std("About Noche", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            later("Check for Updates...", "help.checkForUpdates", "M1.8"),
            sep,
            later("Settings...", "noche.settings", "M1.8"),
            later("Import from Another Browser...", "M1.10"),
            sep,
            menu("Services", [], role: .services),
            sep,
            std("Hide Noche", #selector(NSApplication.hide(_:)), "app.hide"),
            std("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "app.hideOthers"),
            std("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep,
            std("Quit Noche", #selector(NSApplication.terminate(_:)), "app.quit"),
        ]),
        menu("File", [
            app("New Tab", "file.newTab", #selector(AppDelegate.newTab(_:)), enabled: always),
            later("New Tab in Group", "file.newTabInGroup", "M1.6"),
            app("New Window", "file.newWindow", #selector(AppDelegate.newWindowMenu(_:)), enabled: always),
            later("New Incognito Window", "file.newIncognitoWindow", "M1.7"),
            app("Reopen Closed Tab", "file.reopenClosedTab", #selector(AppDelegate.reopenClosedTab(_:)),
                enabled: { !$0.app.closing && ($0.app.writer?.hasClosed ?? false) }),  // disabled while the closed list is empty (M1.2)
            sep,
            later("Chat...", "file.chat", "M2"),
            later("Focus Chat", "file.focusChat", "M2"),
            sep,
            app("Open Command Bar", "file.openCommandBar", #selector(AppDelegate.openCommandBar(_:)), enabled: always),
            sep,
            app("Close Window", "file.closeWindow", #selector(AppDelegate.closeWindowMenu(_:))),
            app("Close Tab", "file.closeTab", #selector(AppDelegate.closeTab(_:))),
            app("Close All Tabs", "file.closeAllTabs", #selector(AppDelegate.closeAllTabs(_:))),
            later("Clean Up Tabs", "file.cleanUpTabs", "M1.6"),
            sep,
            app("Share...", "file.share", #selector(AppDelegate.share(_:)),
                enabled: { $0.window?.activeTab.map { ["http", "https"].contains(URL(string: $0.url)?.scheme?.lowercased() ?? "") } ?? false }),
            app("Print...", "file.print", #selector(AppDelegate.printPage(_:))),
        ]),
        menu("Edit", [
            std("Undo", NSSelectorFromString("undo:"), "edit.undo"),
            std("Redo", NSSelectorFromString("redo:"), "edit.redo"),
            sep,
            std("Cut", #selector(NSText.cut(_:)), "edit.cut"),
            std("Copy", #selector(NSText.copy(_:)), "edit.copy"),
            app("Copy URL", "edit.copyURL", #selector(AppDelegate.copyURL(_:))),
            app("Copy URL as Markdown", "edit.copyURLMarkdown", #selector(AppDelegate.copyURLMarkdown(_:))),
            std("Paste", #selector(NSText.paste(_:)), "edit.paste"),
            std("Paste and Match Style", NSSelectorFromString("pasteAsPlainText:"), "edit.pasteMatchStyle"),
            std("Delete", #selector(NSText.delete(_:))),
            std("Select All", #selector(NSText.selectAll(_:)), "edit.selectAll"),
            sep,
            menu("Find", [
                later("Find...", "edit.find", "M1.4 task 4"),
                later("Find Next", "edit.findNext", "M1.4 task 4"),
                later("Find Previous", "edit.findPrevious", "M1.4 task 4"),
                later("Use Selection for Find", "M1.4 task 4"),
            ]),
            sep,
            menu("Spelling and Grammar", [
                std("Show Spelling and Grammar", NSSelectorFromString("showGuessPanel:"), "edit.showSpelling"),
                std("Check Document Now", NSSelectorFromString("checkSpelling:"), "edit.checkSpelling"),
                sep,
                std("Check Spelling While Typing", NSSelectorFromString("toggleContinuousSpellChecking:")),
                std("Check Grammar With Spelling", NSSelectorFromString("toggleGrammarChecking:")),
                std("Correct Spelling Automatically", NSSelectorFromString("toggleAutomaticSpellingCorrection:")),
            ]),
            menu("Substitutions", [
                std("Show Substitutions", NSSelectorFromString("orderFrontSubstitutionsPanel:")),
                sep,
                std("Smart Copy/Paste", NSSelectorFromString("toggleSmartInsertDelete:")),
                std("Smart Quotes", NSSelectorFromString("toggleAutomaticQuoteSubstitution:")),
                std("Smart Dashes", NSSelectorFromString("toggleAutomaticDashSubstitution:")),
                std("Smart Links", NSSelectorFromString("toggleAutomaticLinkDetection:")),
                std("Data Detectors", NSSelectorFromString("toggleAutomaticDataDetection:")),
                std("Text Replacement", NSSelectorFromString("toggleAutomaticTextReplacement:")),
            ]),
            menu("Transformations", [
                std("Make Upper Case", NSSelectorFromString("uppercaseWord:")),
                std("Make Lower Case", NSSelectorFromString("lowercaseWord:")),
                std("Capitalize", NSSelectorFromString("capitalizeWord:")),
            ]),
            menu("Speech", [
                std("Start Speaking", NSSelectorFromString("startSpeaking:")),
                std("Stop Speaking", NSSelectorFromString("stopSpeaking:")),
            ]),
            menu("AutoFill", [
                later("Contact...", "M1.10"),
                later("Passwords...", "M1.10"),
                later("Credit Card...", "M1.10"),
            ]),
            sep,
            std("Start Dictation...", NSSelectorFromString("startDictation:")),
            std("Emoji & Symbols", NSSelectorFromString("orderFrontCharacterPalette:")),
        ]),
        menu("View", [
            menu("Appearance", [
                app("Automatic", nil, #selector(AppDelegate.setAppearance(_:)), enabled: always, state: { _ in NSApp.appearance == nil }, tag: 0),
                app("Light", nil, #selector(AppDelegate.setAppearance(_:)), enabled: always, state: { _ in NSApp.appearance?.name == .aqua }, tag: 1),
                app("Dark", nil, #selector(AppDelegate.setAppearance(_:)), enabled: always, state: { _ in NSApp.appearance?.name == .darkAqua }, tag: 2),
            ]),
            sep,
            app("Refresh", "view.refresh", #selector(AppDelegate.refresh(_:))),
            app("Force Refresh the Page", "view.forceRefresh", #selector(AppDelegate.forceRefresh(_:))),
            sep,
            later("Show Tabs in Sidebar", "view.showTabsInSidebar", "M1.6"),
            app("Auto-Hide Tabs", "view.autoHideTabs", #selector(AppDelegate.toggleSidebar(_:)), state: { $0.window?.sidebarHidden == true }),
            sep,
            later("Open Split Pane", "view.openSplitPane", "M1.10"),
            later("Focus Next Split Pane", "view.focusNextSplitPane", "M1.10"),
            later("Focus Previous Split Pane", "view.focusPreviousSplitPane", "M1.10"),
            sep,
            menu("Show Bookmarks Bar", [
                later("Always", "view.bookmarksBar.always", "M1.5"),
                later("On New Tab Only", "view.bookmarksBar.newTabOnly", "M1.5"),
                later("Never", "view.bookmarksBar.never", "M1.5"),
                sep,
                later("Toggle Bookmarks Bar", "view.toggleBookmarksBar", "M1.5"),
            ]),
            app("Show Full URL", nil, #selector(AppDelegate.toggleFullURL(_:)), enabled: always, state: { $0.app.showFullURL }),
            sep,
            app("Zoom to Actual Size", "view.zoomActualSize", #selector(AppDelegate.zoomActual(_:))),
            app("Zoom In", "view.zoomIn", #selector(AppDelegate.zoomIn(_:))),
            app("Zoom Out", "view.zoomOut", #selector(AppDelegate.zoomOut(_:))),
            sep,
            std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:))),
            sep,
            menu("Developer", [
                app("Developer Tools", "view.developerTools", #selector(AppDelegate.developerTools(_:))),
                app("Inspect Elements", "view.inspectElements", #selector(AppDelegate.inspectElements(_:))),
                app("JavaScript Console", "view.javaScriptConsole", #selector(AppDelegate.javaScriptConsole(_:))),
            ]),
        ]),
        menu("Tabs", [
            app("Go Back", "tabs.goBack", #selector(AppDelegate.goBack(_:)), enabled: { $0.window?.activeTab?.canGoBack ?? false }),
            app("Go Forward", "tabs.goForward", #selector(AppDelegate.goForward(_:)), enabled: { $0.window?.activeTab?.canGoForward ?? false }),
            app("Next Tab", "tabs.nextTab", #selector(AppDelegate.nextTab(_:))),
            app("Previous Tab", "tabs.previousTab", #selector(AppDelegate.previousTab(_:))),
            sep,
            later("Search Tabs...", "tabs.searchTabs", "M1.6"),
            later("Pin", "tabs.pinTab", "M1.6"),
            app("Duplicate", "tabs.duplicateTab", #selector(AppDelegate.duplicateTab(_:))),
            sep,
            later("New Group with Tab", "tabs.newGroupWithTabs", "M1.6"),
            later("Move to Group", "M1.6"),
            later("Move to Profile", "M1.7"),
            later("Move to Window", "M1.6"),
            sep,
            later("Rename...", "M1.6"),
            later("Change Icon...", "M1.6"),
        ]),
        menu("Bookmarks", [
            later("Bookmark This Page", "bookmarks.add", "M1.5"),
            later("Manage Bookmarks", "bookmarks.manage", "M1.5"),
            sep,
            later("Bookmarks Bar", "M1.5"),
            later("Other Bookmarks", "M1.5"),
        ]),
        menu("History", [
            app("Show History...", "history.show", #selector(AppDelegate.showHistory(_:)), enabled: always),  // chrome://history until M1.5
        ]),
        menu("Extensions", [
            later("Add Extension...", "M1.9"),
            later("Manage Extensions...", "M1.9"),
            later("Pin Extensions...", "M1.9"),
        ]),
        menu("Window", [
            std("Minimize", #selector(NSWindow.performMiniaturize(_:)), "app.minimize"),
            std("Minimize All", #selector(NSApplication.miniaturizeAll(_:)), "app.minimizeAll"),
            app("Arrange in Front", nil, #selector(AppDelegate.arrangeWindowsInFront(_:)), enabled: always),  // not NSApp's own selector: AppKit retitles that one "Bring All to Front"
            sep,
            app("Downloads", "window.downloads", #selector(AppDelegate.showDownloads(_:)), enabled: always),  // chrome://downloads until M1.5
            app("Task Manager", nil, #selector(AppDelegate.taskManager(_:)), enabled: { $0.window?.activeTab?.canExecuteChromeCommandNamed("IDC_TASK_MANAGER") ?? false }),
            later("Merge All Windows", "window.mergeAllWindows", "M1.6"),
        ], role: .windows),
        menu("Help", [
            app("Copy Diagnostics", "help.copyDiagnostics", #selector(AppDelegate.copyDiagnostics(_:)), enabled: always),
        ], role: .help),
    ]

    /// The row with this shortcut id (the context menus reuse its title, key, enable rule and checkmark).
    static func entry(id: String) -> MenuEntry? {
        func find(_ entries: [MenuEntry]) -> MenuEntry? {
            for e in entries { if e.id == id { return e }; if let f = find(e.submenu ?? []) { return f } }
            return nil
        }
        return find(bar)
    }

    /// Key commands the reference menu has no item for (M1.2's Cmd+1 to Cmd+9 and the tab moves): they keep working through `ShortcutMenu`.
    static let commands: [MenuCommand] = (1...8).map { n in
        MenuCommand(title: "Select Tab \(n)", id: "tabs.selectTab.\(n)") { $0.active?.selectTab(at: n - 1) }
    } + [
        MenuCommand(title: "Select Last Tab", id: "tabs.selectLastTab") { $0.active?.selectTab(at: nil) },
        MenuCommand(title: "Move Tab Forward", id: "tabs.moveTabForward") { $0.active?.moveTab(1) },
        MenuCommand(title: "Move Tab Backward", id: "tabs.moveTabBackward") { $0.active?.moveTab(-1) },
    ]
}
