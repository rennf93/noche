/// Default table, section and row order exactly as research note m1-8-settings 3.1 (dispatch ties resolve by table order).
/// Key characters are US-layout. Reference-only rows carry the milestone caption shown in the detail pane.
extension ShortcutDefaults {
    public static let table: [ShortcutAction] = {
        let c = Chord.cmd, s = Chord.shift, o = Chord.opt, k = Chord.ctrl
        var t: [ShortcutAction] = []
        func add(_ section: String, _ rows: [(String, String, Chord?, Bool)]) {
            t += rows.map { action(section, $0.0, $0.1, $0.2, ref: $0.3) }
        }
        add("Noche", [("noche.settings", "Settings", Chord(",", c), false)])
        add("File", [
            ("file.newTab", "New Tab", Chord("t", c), false),
            ("file.newTabInGroup", "New Tab in Group", Chord("t", o | c), false),
            ("file.newWindow", "New Window", Chord("n", c), false),
            ("file.newIncognitoWindow", "New Incognito Window", Chord("n", s | c), false),
            ("file.reopenClosedTab", "Reopen Closed Tab", Chord("t", s | c), false),
            ("file.chat", "Chat...", Chord("e", c), false),
            ("file.newChat", "New Chat", Chord("e", s | c), true),
            ("file.focusChat", "Focus Chat", Chord("e", k | c), false),
            ("file.sendChatPromptNow", "Send Chat Prompt Now", Chord("return", c), true),
            ("file.openDailyBrief", "Open Daily Brief", Chord("m", s | c), true),
            ("file.openCommandBar", "Open Command Bar", Chord("l", c), false),
            ("file.closeWindow", "Close Window", Chord("w", s | c), false),
            ("file.closeTab", "Close Tab", Chord("w", c), false),
            ("file.closeAllTabs", "Close All Tabs", Chord("k", s | c), false),
            ("file.cleanUpTabs", "Clean Up Tabs", Chord("k", o | c), false),
            ("file.share", "Share...", nil, false),
            ("file.print", "Print...", Chord("p", c), false),
        ])
        add("Edit", [
            ("edit.copyURL", "Copy URL", Chord("c", s | c), false),
            ("edit.copyURLMarkdown", "Copy URL as Markdown", Chord("c", o | s | c), false),
            ("edit.find", "Find...", Chord("f", c), false),
            ("edit.findNext", "Find Next", Chord("g", c), false),
            ("edit.findPrevious", "Find Previous", Chord("g", s | c), false),
        ])
        add("View", [
            ("view.refresh", "Refresh", Chord("r", c), false),
            ("view.forceRefresh", "Force Refresh the Page", Chord("r", s | c), false),
            ("view.showTabsInSidebar", "Show Tabs in Sidebar", Chord("s", s | c), false),
            ("view.autoHideTabs", "Auto-Hide Tabs", Chord("s", c), false),
            ("view.openSplitPane", "Open Split Pane", Chord("+", k), false),
            ("view.focusNextSplitPane", "Focus Next Split Pane", Chord("'", k | s), false),
            ("view.focusPreviousSplitPane", "Focus Previous Split Pane", Chord(";", k | s), false),
            ("view.bookmarksBar.always", "Always", nil, false),
            ("view.bookmarksBar.newTabOnly", "On New Tab Only", nil, false),
            ("view.bookmarksBar.never", "Never", nil, false),
            ("view.toggleBookmarksBar", "Toggle Bookmarks Bar", Chord("b", s | c), false),
            ("view.zoomActualSize", "Zoom to Actual Size", Chord("0", c), false),
            ("view.zoomIn", "Zoom In", Chord("+", c), false),
            ("view.zoomOut", "Zoom Out", Chord("-", c), false),
            ("view.developerTools", "Developer Tools", Chord("i", o | c), false),
            ("view.inspectElements", "Inspect Elements", Chord("c", o | c), false),
            ("view.javaScriptConsole", "JavaScript Console", Chord("j", o | c), false),
        ])
        add("Tabs", [
            ("tabs.goBack", "Go Back", Chord("[", c), false),
            ("tabs.goForward", "Go Forward", Chord("]", c), false),
            ("tabs.nextTab", "Next Tab", Chord("]", s | c), false),
            ("tabs.previousTab", "Previous Tab", Chord("[", s | c), false),
            ("tabs.previousProfile", "Previous Profile", Chord("left", o | c), true),
            ("tabs.nextProfile", "Next Profile", Chord("right", o | c), true),
            ("tabs.searchTabs", "Search Tabs...", Chord("a", s | c), false),
            ("tabs.pinTab", "Pin/Unpin Tab", Chord("d", s | c), false),
            ("tabs.duplicateTab", "Duplicate Tab", nil, false),
            ("tabs.resetPinnedTab", "Reset Pinned Tab to Base URL", nil, true),
            ("tabs.newGroupWithTabs", "New Group with Tabs", Chord("n", k | c), false),
            ("tabs.switcherForward", "Tab Switcher (forward)", Chord("tab", k), true),
            ("tabs.switcherBackward", "Tab Switcher (backward)", Chord("tab", k | s), true),
        ])
        add("Bookmarks", [
            ("bookmarks.add", "Add to Bookmarks...", Chord("d", c), false),
            ("bookmarks.manage", "Manage Bookmarks", Chord("b", o | c), false),
        ])
        add("History", [("history.show", "Show History...", Chord("y", c), false)])
        add("Window", [("window.downloads", "Downloads", Chord("j", s | c), false)]
            + (1...9).map { ("tabs.switchProfile.\($0)", "Switch to Profile \($0)", Chord(String($0), k), false) }
            + [("window.openProfileSwitcher", "Open Profile Switcher", Chord("p", s | c), true),
               ("window.mergeAllWindows", "Merge All Windows", nil, false)])
        add("Help", [("help.copyDiagnostics", "Copy Diagnostics", nil, false)])
        return t
    }()
}
