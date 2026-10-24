/// Default table, section and row order exactly as research note m1-8-settings 3.1 (dispatch ties resolve by table order).
/// Key characters are US-layout. Reference-only rows carry the milestone caption shown in the detail pane.
extension ShortcutDefaults {
    public static let table: [ShortcutAction] = {
        let c = Chord.cmd, s = Chord.shift, o = Chord.opt, k = Chord.ctrl
        var t: [ShortcutAction] = []
        func add(_ section: String, _ rows: [(String, String, Chord?, String?)]) {
            t += rows.map { action(section, $0.0, $0.1, $0.2, milestone: $0.3) }
        }
        add("Noche", [("noche.settings", "Settings", Chord(",", c), nil)])
        add("File", [
            ("file.newTab", "New Tab", Chord("t", c), nil),
            ("file.newTabInGroup", "New Tab in Group", Chord("t", o | c), nil),
            ("file.newWindow", "New Window", Chord("n", c), nil),
            ("file.newIncognitoWindow", "New Incognito Window", Chord("n", s | c), nil),
            ("file.reopenClosedTab", "Reopen Closed Tab", Chord("t", s | c), nil),
            ("file.chat", "Chat...", Chord("e", c), nil),
            ("file.newChat", "New Chat", Chord("e", s | c), "Arrives in M2"),
            ("file.focusChat", "Focus Chat", Chord("e", k | c), nil),
            ("file.sendChatPromptNow", "Send Chat Prompt Now", Chord("return", c), "Arrives in M2"),
            ("file.openDailyBrief", "Open Daily Brief", Chord("m", s | c), "Arrives in M3"),
            ("file.openCommandBar", "Open Command Bar", Chord("l", c), nil),
            ("file.closeWindow", "Close Window", Chord("w", s | c), nil),
            ("file.closeTab", "Close Tab", Chord("w", c), nil),
            ("file.closeAllTabs", "Close All Tabs", Chord("k", s | c), nil),
            ("file.cleanUpTabs", "Clean Up Tabs", Chord("k", o | c), nil),
            ("file.share", "Share...", nil, nil),
            ("file.print", "Print...", Chord("p", c), nil),
        ])
        add("Edit", [
            ("edit.copyURL", "Copy URL", Chord("c", s | c), nil),
            ("edit.copyURLMarkdown", "Copy URL as Markdown", Chord("c", o | s | c), nil),
            ("edit.find", "Find...", Chord("f", c), nil),
            ("edit.findNext", "Find Next", Chord("g", c), nil),
            ("edit.findPrevious", "Find Previous", Chord("g", s | c), nil),
        ])
        add("View", [
            ("view.refresh", "Refresh", Chord("r", c), nil),
            ("view.forceRefresh", "Force Refresh the Page", Chord("r", s | c), nil),
            ("view.showTabsInSidebar", "Show Tabs in Sidebar", Chord("s", s | c), nil),
            ("view.autoHideTabs", "Auto-Hide Tabs", Chord("s", c), nil),
            ("view.openSplitPane", "Open Split Pane", Chord("=", k | s), nil),
            ("view.focusNextSplitPane", "Focus Next Split Pane", Chord("'", k | s), nil),
            ("view.focusPreviousSplitPane", "Focus Previous Split Pane", Chord(";", k | s), nil),
            ("view.bookmarksBar.always", "Always", nil, nil),
            ("view.bookmarksBar.newTabOnly", "On New Tab Only", nil, nil),
            ("view.bookmarksBar.never", "Never", nil, nil),
            ("view.toggleBookmarksBar", "Toggle Bookmarks Bar", Chord("b", s | c), nil),
            ("view.zoomActualSize", "Zoom to Actual Size", Chord("0", c), nil),
            ("view.zoomIn", "Zoom In", Chord("=", c | s), nil),
            ("view.zoomOut", "Zoom Out", Chord("-", c), nil),
            ("view.developerTools", "Developer Tools", Chord("i", o | c), nil),
            ("view.inspectElements", "Inspect Elements", Chord("c", o | c), nil),
            ("view.javaScriptConsole", "JavaScript Console", Chord("j", o | c), nil),
        ])
        add("Tabs", [
            ("tabs.goBack", "Go Back", Chord("[", c), nil),
            ("tabs.goForward", "Go Forward", Chord("]", c), nil),
            ("tabs.nextTab", "Next Tab", Chord("]", s | c), nil),
            ("tabs.previousTab", "Previous Tab", Chord("[", s | c), nil),
            ("tabs.previousProfile", "Previous Profile", Chord("left", o | c), "Arrives in M1.7"),
            ("tabs.nextProfile", "Next Profile", Chord("right", o | c), "Arrives in M1.7"),
            ("tabs.searchTabs", "Search Tabs...", Chord("a", s | c), nil),
            ("tabs.pinTab", "Pin/Unpin Tab", Chord("d", s | c), nil),
            ("tabs.duplicateTab", "Duplicate Tab", nil, nil),
            ("tabs.resetPinnedTab", "Reset Pinned Tab to Base URL", nil, "Arrives in M1.6"),
            ("tabs.newGroupWithTabs", "New Group with Tabs", Chord("n", k | c), nil),
            ("tabs.switcherForward", "Tab Switcher (forward)", Chord("tab", k), "Arrives in M1.6"),
            ("tabs.switcherBackward", "Tab Switcher (backward)", Chord("tab", k | s), "Arrives in M1.6"),
        ])
        add("Bookmarks", [
            ("bookmarks.add", "Add to Bookmarks...", Chord("d", c), nil),
            ("bookmarks.manage", "Manage Bookmarks", Chord("b", o | c), nil),
        ])
        add("History", [("history.show", "Show History...", Chord("y", c), nil)])
        add("Window", [("window.downloads", "Downloads", Chord("j", s | c), nil)]
            + (1...9).map { ("tabs.switchProfile.\($0)", "Switch to Profile \($0)", Chord(String($0), k), nil) }
            + [("window.openProfileSwitcher", "Open Profile Switcher", Chord("p", s | c), "Arrives in M1.7"),
               ("window.mergeAllWindows", "Merge All Windows", nil, nil)])
        add("Help", [("help.checkForUpdates", "Check for Updates...", nil, nil), ("help.copyDiagnostics", "Copy Diagnostics", nil, nil)])
        return t
    }()
}
