#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore

/// Menu checks: the live bar against tests/fixtures/app/menu-expected.txt, disabled items that stay inert, and the items that have no shortcut.
extension SelfTest {
    /// `<menu path>|<title>|<key>|<modifiers>|<enabled>` for every Noche-marked item, depth first (a submenu's own line first). Items AppKit
    /// adds itself (the Window menu's tiling rows and window list, the Help search field) have no mark and are the "system rows": left out.
    /// Enabled is r for a nil-targeted item (the responder chain decides and a hidden window is never key). The Services submenu is the system's.
    func menuLines(_ menu: NSMenu, path: String) -> [String] {
        menu.update()
        var out: [String] = []
        for i in menu.items where i.identifier == MenuTable.mark {
            if i.isSeparatorItem { out.append("\(path)|---|||-"); continue }
            var mods: [String] = []
            let m = i.keyEquivalentModifierMask
            if m.contains(.control) { mods.append("ctrl") }
            if m.contains(.option) { mods.append("opt") }
            if m.contains(.shift) { mods.append("shift") }
            if m.contains(.command) { mods.append("cmd") }
            // AppKit rewrites "[" and "]" to the layout's own keys (the Spanish layout gives "ñ" and "´"): report the US ones.
            let key = ["ñ": "[", "´": "]", "¿": ":", "¡": ";", "`": "'"][i.keyEquivalent] ?? i.keyEquivalent
            // Task Manager is enabled exactly when the engine can execute IDC_TASK_MANAGER: asserted by menu-diff, not written down.
            let enabled = i.title == "Task Manager" ? "e" : i.submenu != nil ? "1" : (i.action != nil && i.target == nil ? "r" : (i.isEnabled ? "1" : "0"))
            out.append("\(path)|\(i.title.replacingOccurrences(of: "…", with: "..."))|\(key)|\(key.isEmpty ? "" : mods.joined(separator: "+"))|\(enabled)")
            // The bar lists its menus first; below the bar a submenu's lines follow its own line.
            if path != "bar", let sub = i.submenu, i.title != "Services" { out += menuLines(sub, path: "\(path)/\(i.title)") }
        }
        if path == "bar" {
            for i in menu.items where i.identifier == MenuTable.mark { if let sub = i.submenu { out += menuLines(sub, path: i.title) } }
        }
        return out
    }

    func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items { if i.title == title, i.identifier == MenuTable.mark { return i }; if let s = i.submenu, let f = find(s) { return f } }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    /// The item's action sent the way a click sends it (validated first); false when the item is disabled.
    @discardableResult
    func fire(_ title: String) -> Bool {
        guard let i = menuItem(title) else { keyLog.append("no menu item \(title)"); return false }
        i.menu?.update()
        guard i.isEnabled, let action = i.action else { return false }
        return NSApp.sendAction(action, to: i.target, from: i)
    }

    func menuDiff() async {
        guard await ready(), let bar = NSApp.mainMenu else { return }
        guard let data = try? Data(contentsOf: URL(string: fixture("menu-expected.txt"))!), let text = String(data: data, encoding: .utf8) else {
            return finish(false, "no menu-expected.txt from the fixture server")
        }
        let want = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.hasPrefix("#") }
        var got = menuLines(bar, path: "bar")
        // Key commands with no menu item, after the menu lines.
        got += ((bar as? ShortcutMenu)?.commands ?? []).map { c in
            var mods: [String] = []
            if c.chord.mods & Chord.ctrl != 0 { mods.append("ctrl") }
            if c.chord.mods & Chord.opt != 0 { mods.append("opt") }
            if c.chord.mods & Chord.shift != 0 { mods.append("shift") }
            if c.chord.mods & Chord.cmd != 0 { mods.append("cmd") }
            return "command|\(c.title)|\(c.chord.key)|\(mods.joined(separator: "+"))|1"
        }
        // r in the expected file means the responder chain decides: only the line's other fields are compared.
        func same(_ g: String, _ w: String) -> Bool {
            if g == w { return true }
            let gp = g.split(separator: "|", omittingEmptySubsequences: false), wp = w.split(separator: "|", omittingEmptySubsequences: false)
            return gp.count == 5 && wp.count == 5 && gp[4] == "r" && wp[4] == "r" && gp[0..<4] == wp[0..<4]
        }
        if got.count != want.count || !zip(got, want).allSatisfy(same) {
            let first = zip(got, want).enumerated().first { !same($0.element.0, $0.element.1) }
            let at = first?.offset ?? min(got.count, want.count)
            return finish(false, "menu differs: \(got.count) lines vs \(want.count) expected; first difference at line \(at): live \(got[safe: at] ?? "none"), expected \(want[safe: at] ?? "none")")
        }
        // A disabled-until-later item says which milestone it waits for (the table row), and an enabled one has none.
        var undated: [String] = []
        func walk(_ entries: [MenuEntry]) {
            for e in entries {
                if e.action == nil, e.submenu == nil, !e.separator, (e.milestone ?? "").isEmpty { undated.append(e.title) }
                walk(e.submenu ?? [])
            }
        }
        walk(MenuTable.bar)
        guard undated.isEmpty else { return finish(false, "disabled items without a milestone: \(undated)") }
        // Every nil-targeted row has the expected standard action and no target (hand-written list, not read from the table).
        let selectors: [String: String] = [
            "About Noche": "orderFrontStandardAboutPanel:", "Hide Noche": "hide:", "Hide Others": "hideOtherApplications:", "Show All": "unhideAllApplications:",
            "Quit Noche": "terminate:", "Undo": "undo:", "Redo": "redo:", "Cut": "cut:", "Copy": "copy:", "Paste": "paste:",
            "Paste and Match Style": "pasteAsPlainText:", "Delete": "delete:", "Select All": "selectAll:",
            "Show Spelling and Grammar": "showGuessPanel:", "Check Document Now": "checkSpelling:", "Check Spelling While Typing": "toggleContinuousSpellChecking:",
            "Check Grammar With Spelling": "toggleGrammarChecking:", "Correct Spelling Automatically": "toggleAutomaticSpellingCorrection:",
            "Show Substitutions": "orderFrontSubstitutionsPanel:", "Smart Copy/Paste": "toggleSmartInsertDelete:", "Smart Quotes": "toggleAutomaticQuoteSubstitution:",
            "Smart Dashes": "toggleAutomaticDashSubstitution:", "Smart Links": "toggleAutomaticLinkDetection:", "Data Detectors": "toggleAutomaticDataDetection:",
            "Text Replacement": "toggleAutomaticTextReplacement:", "Make Upper Case": "uppercaseWord:", "Make Lower Case": "lowercaseWord:", "Capitalize": "capitalizeWord:",
            "Start Speaking": "startSpeaking:", "Stop Speaking": "stopSpeaking:", "Start Dictation...": "startDictation:", "Emoji & Symbols": "orderFrontCharacterPalette:",
            "Enter Full Screen": "toggleFullScreen:", "Minimize": "performMiniaturize:", "Minimize All": "miniaturizeAll:"]
        var badSelectors: [String] = [], seen = 0
        func walkLive(_ m: NSMenu) {
            for i in m.items where i.identifier == MenuTable.mark {
                if let a = i.action, i.target == nil, !i.isSeparatorItem {
                    seen += 1
                    let title = i.title.replacingOccurrences(of: "…", with: "...")
                    if selectors[title] != NSStringFromSelector(a) { badSelectors.append("\(title): \(NSStringFromSelector(a)), want \(selectors[title] ?? "none")") }
                }
                if let s = i.submenu, i.title != "Services" { walkLive(s) }
            }
        }
        walkLive(bar)
        guard badSelectors.isEmpty, seen == selectors.count else { return finish(false, "nil-targeted items: \(seen) of \(selectors.count), wrong selectors \(badSelectors)") }
        // Task Manager follows the engine: enabled exactly when it can execute IDC_TASK_MANAGER.
        let canTaskManager = win?.activeTab?.canExecuteChromeCommandNamed("IDC_TASK_MANAGER") ?? false
        let tm = menuItem("Task Manager"); tm?.menu?.update()
        guard tm?.isEnabled == canTaskManager else { return finish(false, "Task Manager enabled \(String(describing: tm?.isEnabled)) but the engine's CanExecute is \(canTaskManager)") }
        line("info", "IDC_TASK_MANAGER CanExecute \(canTaskManager)")
        let nilTargeted = got.filter { $0.hasSuffix("|r") }.count
        finish(violations.isEmpty, "\(got.count) lines (menus, items, separators and \(MenuTable.commands.count) key commands) equal menu-expected.txt, \(nilTargeted) nil-targeted responder items, every disabled item names a milestone \(violations)")
    }

    func menuDisabled() async {
        guard await ready(), let ctl, let bar = NSApp.mainMenu else { return }
        _ = menuLines(bar, path: "bar")  // validates every menu
        var disabled: [NSMenuItem] = []
        func walk(_ m: NSMenu) {
            for i in m.items {
                if i.identifier == MenuTable.mark, !i.isEnabled, !i.keyEquivalent.isEmpty { disabled.append(i) }
                if let s = i.submenu { walk(s) }
            }
        }
        walk(bar)
        guard disabled.count >= 20 else { return finish(false, "only \(disabled.count) disabled items with a key, expected at least 20") }
        BrowserWindowController.actionCounts = [:]; BrowserWindowController.commandLog = []
        let rows = rowCount, windows = app.controllers.count, tabs = ctl.window.tabs.count
        var handled = 0
        for i in disabled {
            let isPlus = i.keyEquivalent == "+"
            if key(isPlus ? "=" : i.keyEquivalent, code: 0, isPlus ? i.keyEquivalentModifierMask.union(.shift) : i.keyEquivalentModifierMask, chars: i.keyEquivalent, menuOnly: true) { handled += 1 }
        }
        try? await Task.sleep(for: .milliseconds(500))
        let counts = BrowserWindowController.actionCounts, log = BrowserWindowController.commandLog
        guard counts.isEmpty, log.isEmpty else { return finish(false, "disabled items acted: actions \(counts), Chrome commands \(log)") }
        guard rowCount == rows, app.controllers.count == windows, ctl.window.tabs.count == tabs else {
            return finish(false, "disabled items changed the window: rows \(rowCount) of \(rows), windows \(app.controllers.count) of \(windows), tabs \(ctl.window.tabs.count) of \(tabs)")
        }
        // Positive control: the same route does fire an enabled item.
        key("r", code: 15, menuOnly: true)
        try? await Task.sleep(for: .milliseconds(300))
        guard BrowserWindowController.actionCounts == ["reload": 1] else { return finish(false, "positive control: Cmd+R acted \(BrowserWindowController.actionCounts), want [reload: 1]") }
        // The blank state: with one blank tab Close All Tabs would close nothing, so the row is disabled and its key does nothing.
        ctl.window.activeTab?.loadURL("about:blank")
        guard await until(10, { ctl.hasOnlyBlankTab }) else { return finish(false, "the tab never became blank (\(ctl.window.activeTab?.url ?? "nil"))") }
        _ = menuLines(bar, path: "bar")
        guard let closeAll = menuItem("Close All Tabs"), !closeAll.isEnabled else { return finish(false, "Close All Tabs is enabled in a window with one blank tab") }
        BrowserWindowController.actionCounts = [:]
        key("k", code: 40, [.command, .shift], menuOnly: true)
        try? await Task.sleep(for: .milliseconds(300))
        guard BrowserWindowController.actionCounts.isEmpty else { return finish(false, "Close All Tabs acted on a blank tab: \(BrowserWindowController.actionCounts)") }
        finish(violations.isEmpty, "\(disabled.count) disabled items with a key equivalent (\(handled) swallowed by the menu) ran no action, logged no Chrome command and changed no window; the positive control Cmd+R reloaded once; with one blank tab Close All Tabs is disabled and its key does nothing \(violations)")
    }

    /// The items with no shortcut, plus Appearance. (The keyed ones are in shortcuts-once.)
    func menuActions() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab else { return }
        var bad: [String] = []
        func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
        func reset() { BrowserWindowController.actionCounts = [:]; BrowserWindowController.commandLog = [] }

        // Tabs > Duplicate: a second tab at the same address, active, in the list and in the engine.
        reset()
        guard fire("Duplicate") else { return finish(false, "Tabs > Duplicate is not enabled in a one-tab window") }
        guard await until(10, { rowCount == 2 && win.tabs.count == 2 && ctl.list.items.count == 2 }) else {
            return finish(false, "Duplicate left \(rowCount) rows, \(win.tabs.count) engine tabs, \(ctl.list.items.count) list items (actions \(BrowserWindowController.actionCounts))")
        }
        await settle()
        if BrowserWindowController.actionCounts != ["duplicateTab": 1] { bad.append("Duplicate acted \(BrowserWindowController.actionCounts)") }
        let urls = ctl.list.items.map(\.url)
        if urls.count != 2 || urls[0] != urls[1] || urls[0] != tab.url { bad.append("Duplicate urls \(urls), want two of \(tab.url)") }
        if win.activeTab === tab { bad.append("the original tab is still active after Duplicate") }

        // View > Show Full URL: the toolbar address shows the whole address, then the host again.
        let full = ctl.toolbar.address.stringValue
        guard let active = win.activeTab else { return finish(false, "no active tab") }
        let host = URL(string: active.url)?.host ?? ""
        if full != host { bad.append("before Show Full URL the address shows \(full), want \(host)") }
        fire("Show Full URL")
        if !(await until(5, { ctl.toolbar.address.stringValue == active.url })) { bad.append("with Show Full URL the address shows \(ctl.toolbar.address.stringValue), want \(active.url)") }
        let fullItem = menuItem("Show Full URL")
        fullItem?.menu?.update()
        if fullItem?.state != .on { bad.append("Show Full URL has no checkmark while on") }
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_FULLURL"] == "1" { app.showFullURL = false; app.controllers.forEach { $0.refresh() } }  // negative control: the setting is lost at once
        fire("Show Full URL")
        if !(await until(5, { ctl.toolbar.address.stringValue == host })) { bad.append("after Show Full URL again the address shows \(ctl.toolbar.address.stringValue), want \(host)") }

        // View > Appearance: Dark, Light, Automatic set NSApp.appearance.
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        func appearance(_ title: String, _ want: NSAppearance.Name?) {
            fire(title)
            if NSApp.appearance?.name != want { bad.append("\(title) left the appearance \(NSApp.appearance?.name.rawValue ?? "nil"), want \(want?.rawValue ?? "nil")") }
            if menuItem(title).map({ $0.menu?.update(); return $0.state != .on }) ?? true { bad.append("\(title) is not checked after choosing it") }
        }
        appearance("Dark", .darkAqua); appearance("Light", .aqua); appearance("Automatic", nil)
        // File > Share...: the sharing picker is made with the tab's address as its only item and is not shown (hidden run).
        BrowserWindowController.suppressChrome = true
        BrowserWindowController.lastShare = nil
        reset()
        if !fire("Share...") { bad.append("File > Share... is not enabled on a web page") }
        let shared = BrowserWindowController.lastShare?.items.compactMap { ($0 as? URL)?.absoluteString }
        if shared != [active.url] || BrowserWindowController.lastShare?.items.count != 1 { bad.append("Share made a picker for \(String(describing: shared)), want [\(active.url)]") }
        if BrowserWindowController.actionCounts != ["share": 1] { bad.append("Share acted \(BrowserWindowController.actionCounts)") }

        // Help > Copy Diagnostics: the pasteboard text has Noche's version and build, the engine's cef_version and macOS's version, each read from outside the app.
        BrowserWindowController.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.noche.selftest"))
        BrowserWindowController.pasteboard.clearContents()
        reset()
        fire("Copy Diagnostics")
        let text = BrowserWindowController.pasteboard.string(forType: .string) ?? ""
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = (try? String(contentsOf: repo.appendingPathComponent("vendor/CEF-VERSION.txt"), encoding: .utf8))?.split(separator: "\n").first { $0.hasPrefix("cef_version=") }.map { String($0.dropFirst("cef_version=".count)) } ?? "?"
        let plist = (try? String(contentsOf: repo.appendingPathComponent("Resources/App/Info.plist.template"), encoding: .utf8)) ?? ""
        func plistValue(_ key: String) -> String {
            guard let r = plist.range(of: "<key>\(key)</key><string>"), let e = plist[r.upperBound...].range(of: "</string>") else { return "?" }
            return String(plist[r.upperBound..<e.lowerBound])
        }
        let sw = Process(), swOut = Pipe()
        sw.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers"); sw.arguments = ["-productVersion"]; sw.standardOutput = swOut
        try? sw.run(); sw.waitUntilExit()
        let macOS = String(data: swOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let lines = text.split(separator: "\n").map(String.init)
        if lines.count != 3 || lines[0] != "Noche \(plistValue("CFBundleShortVersionString")) (build \(plistValue("CFBundleVersion")))" || lines[1] != "Engine (CEF) \(engine)" || !lines[2].hasPrefix("macOS ") || !lines[2].contains(macOS) {
            bad.append("diagnostics text \(lines), want Noche \(plistValue("CFBundleShortVersionString")) (build \(plistValue("CFBundleVersion"))), Engine (CEF) \(engine), macOS ... \(macOS)")
        }
        if BrowserWindowController.actionCounts != ["copyDiagnostics": 1] { bad.append("Copy Diagnostics acted \(BrowserWindowController.actionCounts)") }

        // Window > Task Manager: enabled exactly when the engine can execute IDC_TASK_MANAGER; executed for real, the windows that appear are recorded (and closed).
        BrowserWindowController.suppressChrome = false
        let can = active.canExecuteChromeCommandNamed("IDC_TASK_MANAGER")
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        reset()
        let ran = fire("Task Manager")
        if ran != can { bad.append("Task Manager fired \(ran) but CanExecute is \(can)") }
        if can {
            _ = await until(3, { NSApp.windows.contains { !before.contains(ObjectIdentifier($0)) } })
            let fresh = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
            line("info", "IDC_TASK_MANAGER CanExecute true, executed once, new windows \(fresh.count) \(fresh.map { NSStringFromClass(type(of: $0)) + ":" + $0.title })")
            if BrowserWindowController.actionCounts != ["taskManager": 1] { bad.append("Task Manager acted \(BrowserWindowController.actionCounts)") }
            fresh.forEach { $0.close() }
        } else {
            line("info", "IDC_TASK_MANAGER CanExecute false: the engine cannot run it on this tab, so the item is disabled and nothing was executed")
        }
        finish(bad.isEmpty && violations.isEmpty, "Duplicate (2 tabs, same address, new one active, one action), Show Full URL on and off with its checkmark, Appearance Dark, Light, Automatic with their checkmarks, Share (picker made with the address, not shown), Copy Diagnostics (3 lines checked against files and sw_vers), Task Manager (follows CanExecute) \(bad) \(violations)")
    }
}
#endif
