import XCTest
@testable import NocheCore

final class ShortcutsTests: XCTestCase {
    private let expected: [String] = [
        "Noche|noche.settings|Settings|⌘,",
        "File|file.newTab|New Tab|⌘T",
        "File|file.newTabInGroup|New Tab in Group|⌥⌘T",
        "File|file.newWindow|New Window|⌘N",
        "File|file.newIncognitoWindow|New Incognito Window|⇧⌘N",
        "File|file.reopenClosedTab|Reopen Closed Tab|⇧⌘T",
        "File|file.chat|Chat...|⌘E",
        "File|file.newChat*|New Chat|⇧⌘E",
        "File|file.focusChat|Focus Chat|⌃⌘E",
        "File|file.sendChatPromptNow*|Send Chat Prompt Now|⌘↩",
        "File|file.openDailyBrief*|Open Daily Brief|⇧⌘M",
        "File|file.openCommandBar|Open Command Bar|⌘L",
        "File|file.closeWindow|Close Window|⇧⌘W",
        "File|file.closeTab|Close Tab|⌘W",
        "File|file.closeAllTabs|Close All Tabs|⇧⌘K",
        "File|file.cleanUpTabs|Clean Up Tabs|⌥⌘K",
        "File|file.share|Share...|-",
        "File|file.print|Print...|⌘P",
        "Edit|edit.copyURL|Copy URL|⇧⌘C",
        "Edit|edit.copyURLMarkdown|Copy URL as Markdown|⌥⇧⌘C",
        "Edit|edit.find|Find...|⌘F",
        "Edit|edit.findNext|Find Next|⌘G",
        "Edit|edit.findPrevious|Find Previous|⇧⌘G",
        "View|view.refresh|Refresh|⌘R",
        "View|view.forceRefresh|Force Refresh the Page|⇧⌘R",
        "View|view.showTabsInSidebar|Show Tabs in Sidebar|⇧⌘S",
        "View|view.autoHideTabs|Auto-Hide Tabs|⌘S",
        "View|view.openSplitPane|Open Split Pane|⌃+",
        "View|view.focusNextSplitPane|Focus Next Split Pane|⌃⇧'",
        "View|view.focusPreviousSplitPane|Focus Previous Split Pane|⌃⇧[",
        "View|view.bookmarksBar.always|Always|-",
        "View|view.bookmarksBar.newTabOnly|On New Tab Only|-",
        "View|view.bookmarksBar.never|Never|-",
        "View|view.toggleBookmarksBar|Toggle Bookmarks Bar|⇧⌘B",
        "View|view.zoomActualSize|Zoom to Actual Size|⌘0",
        "View|view.zoomIn|Zoom In|⌘+",
        "View|view.zoomOut|Zoom Out|⌘-",
        "View|view.developerTools|Developer Tools|⌥⌘I",
        "View|view.inspectElements|Inspect Elements|⌥⌘C",
        "View|view.javaScriptConsole|JavaScript Console|⌥⌘J",
        "Tabs|tabs.goBack|Go Back|⌘[",
        "Tabs|tabs.goForward|Go Forward|⌘]",
        "Tabs|tabs.nextTab|Next Tab|⇧⌘]",
        "Tabs|tabs.previousTab|Previous Tab|⇧⌘[",
        "Tabs|tabs.previousProfile*|Previous Profile|⌥⌘←",
        "Tabs|tabs.nextProfile*|Next Profile|⌥⌘→",
        "Tabs|tabs.searchTabs|Search Tabs...|⇧⌘A",
        "Tabs|tabs.pinTab|Pin/Unpin Tab|⇧⌘D",
        "Tabs|tabs.duplicateTab|Duplicate Tab|-",
        "Tabs|tabs.resetPinnedTab*|Reset Pinned Tab to Base URL|-",
        "Tabs|tabs.newGroupWithTabs|New Group with Tabs|⌃⌘N",
        "Tabs|tabs.switcherForward*|Tab Switcher (forward)|⌃⇥",
        "Tabs|tabs.switcherBackward*|Tab Switcher (backward)|⌃⇧⇥",
        "Bookmarks|bookmarks.add|Add to Bookmarks...|⌘D",
        "Bookmarks|bookmarks.manage|Manage Bookmarks|⌥⌘B",
        "History|history.show|Show History...|⌘Y",
        "Window|window.downloads|Downloads|⇧⌘J",
    ] + (1...9).map { "Window|tabs.switchProfile.\($0)|Switch to Profile \($0)|⌃\($0)" } + [
        "Window|window.openProfileSwitcher*|Open Profile Switcher|⇧⌘P",
        "Window|window.mergeAllWindows|Merge All Windows|-",
        "Help|help.checkForUpdates|Check for Updates...|-",
        "Help|help.copyDiagnostics|Copy Diagnostics|-",
    ]

    func testDefaultsMatchNote() {
        let actual = ShortcutDefaults.table.map {
            "\($0.section)|\($0.id)\($0.referenceOnly ? "*" : "")|\($0.title)|\($0.defaultChord?.glyphs ?? "-")"
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(ShortcutDefaults.table.map(\.id)).count, ShortcutDefaults.table.count)
        let search = ShortcutDefaults.table.first { $0.id == "tabs.searchTabs" }
        XCTAssertEqual(search?.defaultChord, Chord("a", Chord.cmd | Chord.shift))
        XCTAssertTrue(ShortcutDefaults.table.filter(\.referenceOnly).allSatisfy { $0.milestone != nil })
        XCTAssertTrue(ShortcutDefaults.table.filter { !$0.referenceOnly }.allSatisfy { $0.milestone == nil })
        XCTAssertTrue(ShortcutRegistry().conflicts().isEmpty)
    }

    func testChordValidity() {
        XCTAssertTrue(Chord("t", Chord.cmd).isValid)
        XCTAssertTrue(Chord("1", Chord.ctrl).isValid)
        XCTAssertTrue(Chord("tab", Chord.ctrl).isValid)
        XCTAssertTrue(Chord("left", Chord.shift).isValid)
        XCTAssertTrue(Chord("f5", Chord.shift).isValid)
        XCTAssertFalse(Chord("t", 0).isValid)
        XCTAssertFalse(Chord("t", Chord.shift).isValid)
        XCTAssertFalse(Chord("return", Chord.shift).isValid)
        var r = ShortcutRegistry()
        XCTAssertEqual(r.set("file.newTab", Chord("t", Chord.shift)), .invalid("Include Command, Control or Option"))
        XCTAssertEqual(r.set("file.newTab", Chord("j", 0)), .invalid("Include Command, Control or Option"))
        XCTAssertEqual(r.changeCount, 0)
        XCTAssertEqual(r.effective("file.newTab"), Chord("t", Chord.cmd))
    }

    func testReservedChordsRefused() {
        var r = ShortcutRegistry()
        for key in ["q", "h", "m", "z", "x", "c", "v", "a"] {
            XCTAssertEqual(r.set("file.share", Chord(key, Chord.cmd)), .reserved, key)
        }
        XCTAssertEqual(r.set("file.share", Chord("h", Chord.cmd | Chord.opt)), .reserved)
        XCTAssertNil(r.effective("file.share"))
        XCTAssertEqual(r.changeCount, 0)
    }

    func testConflictReplaceKeepBoth() {
        var r = ShortcutRegistry()
        let c = Chord("t", Chord.cmd)
        XCTAssertEqual(r.set("file.share", c), .conflict("file.newTab"))
        XCTAssertNil(r.effective("file.share"))
        XCTAssertEqual(r.replace("file.share", c), .ok)
        XCTAssertEqual(r.effective("file.share"), c)
        XCTAssertNil(r.effective("file.newTab"))
        XCTAssertEqual(r.action(matching: c), "file.share")

        var k = ShortcutRegistry()
        XCTAssertEqual(k.keepBoth("file.share", c), .ok)
        XCTAssertEqual(k.effective("file.share"), c)
        XCTAssertEqual(k.effective("file.newTab"), c)
        XCTAssertEqual(k.conflicts(), [["file.newTab", "file.share"]])
        XCTAssertEqual(k.action(matching: c), "file.newTab")
        XCTAssertEqual(k.search("", filter: .conflicts).map(\.id), ["file.newTab", "file.share"])
        // while both hold it, re-setting reports the other holder
        XCTAssertEqual(k.set("file.newTab", c), .conflict("file.share"))
        var fresh = ShortcutRegistry(); XCTAssertEqual(fresh.set("file.newTab", c), .ok)
    }

    func testClearVsReset() {
        var r = ShortcutRegistry()
        r.clear("file.newTab")
        XCTAssertNil(r.effective("file.newTab"))
        XCTAssertNil(r.action(matching: Chord("t", Chord.cmd)))
        XCTAssertEqual(r.search("", filter: .noShortcut).first { $0.id == "file.newTab" }?.id, "file.newTab")
        XCTAssertEqual(r.search("", filter: .customized).map(\.id), ["file.newTab"])
        r.reset("file.newTab")
        XCTAssertEqual(r.effective("file.newTab"), Chord("t", Chord.cmd))
        XCTAssertTrue(r.search("", filter: .customized).isEmpty)
        XCTAssertEqual(r.set("file.newTab", Chord("y", Chord.cmd | Chord.opt)), .ok)
        XCTAssertEqual(r.effective("file.newTab"), Chord("y", Chord.cmd | Chord.opt))
        // setting the default back is not a customization
        XCTAssertEqual(r.set("file.newTab", Chord("t", Chord.cmd)), .ok)
        XCTAssertTrue(r.search("", filter: .customized).isEmpty)
    }

    func testResetAll() {
        var r = ShortcutRegistry()
        r.clear("file.newTab")
        _ = r.set("file.share", Chord("y", Chord.cmd | Chord.opt))
        r.resetAll()
        XCTAssertEqual(r.effective("file.newTab"), Chord("t", Chord.cmd))
        XCTAssertNil(r.effective("file.share"))
        XCTAssertTrue(r.search("", filter: .customized).isEmpty)
    }

    func testSystemConflictWarnsOnly() {
        var r = ShortcutRegistry()
        let c = Chord("y", Chord.cmd | Chord.opt)
        XCTAssertFalse(r.systemConflict(c, system: []))
        XCTAssertTrue(r.systemConflict(c, system: [c]))
        XCTAssertTrue(r.systemConflict(Chord("space", Chord.cmd), system: []))
        XCTAssertTrue(r.systemConflict(Chord("tab", Chord.cmd), system: []))
        XCTAssertTrue(r.systemConflict(Chord("left", Chord.ctrl), system: []))
        XCTAssertEqual(r.set("file.share", c), .ok)
    }

    func testGlyphAndSpoken() {
        XCTAssertEqual(Chord("t", Chord.cmd | Chord.shift).glyphs, "⇧⌘T")
        XCTAssertEqual(Chord("t", Chord.cmd | Chord.shift).spoken, "shift cmd t")
        XCTAssertEqual(Chord("'", Chord.ctrl | Chord.shift).glyphs, "⌃⇧'")
        XCTAssertEqual(Chord("'", Chord.ctrl | Chord.shift).spoken, "ctrl shift '")
        XCTAssertEqual(Chord("left", Chord.cmd | Chord.opt).glyphs, "⌥⌘←")
        XCTAssertEqual(Chord("left", Chord.cmd | Chord.opt).spoken, "opt cmd left")
        XCTAssertEqual(Chord("return", Chord.cmd).glyphs, "⌘↩")
        XCTAssertEqual(Chord("tab", Chord.ctrl | Chord.shift).glyphs, "⌃⇧⇥")
        XCTAssertEqual(Chord("f12", Chord.opt).glyphs, "⌥F12")
        XCTAssertEqual(Chord("space", Chord.cmd).glyphs, "⌘Space")
        XCTAssertEqual(Chord("delete", Chord.cmd).glyphs, "⌘⌫")
        XCTAssertEqual(Chord("esc", Chord.cmd).glyphs, "⌘⎋")
        XCTAssertEqual(Chord("t", Chord.ctrl | Chord.opt | Chord.shift | Chord.cmd).glyphs, "⌃⌥⇧⌘T")
    }

    func testOverridesRoundTripAndMerge() throws {
        var a = ShortcutRegistry()
        _ = a.set("file.share", Chord("y", Chord.cmd | Chord.opt), at: 10)
        a.clear("file.newTab", at: 10)
        let data = try JSONEncoder().encode(a.overrides)
        let back = try JSONDecoder().decode(ShortcutOverrides.self, from: data)
        XCTAssertEqual(back, a.overrides)
        XCTAssertEqual(ShortcutRegistry(overrides: back).effective("file.share"), Chord("y", Chord.cmd | Chord.opt))
        XCTAssertNil(ShortcutRegistry(overrides: back).effective("file.newTab"))

        var mine = a.overrides
        var other = ShortcutOverrides()
        other.set("file.share", Chord("u", Chord.cmd | Chord.opt), at: 20)   // newer wins
        other.set("file.newTab", Chord("n", Chord.cmd | Chord.opt), at: 5)   // older loses
        other.reset("file.print", at: 7)                                     // new tombstone
        mine.merge(other)
        XCTAssertEqual(mine.entries["file.share"]?.chord, Chord("u", Chord.cmd | Chord.opt))
        XCTAssertNil(mine.entries["file.newTab"]?.chord)
        XCTAssertNotNil(mine.entries["file.newTab"])
        XCTAssertEqual(mine.entries["file.print"]?.reset, true)
    }

    func testImportIgnoresUnknownIds() {
        var o = ShortcutOverrides()
        o.set("file.share", Chord("y", Chord.cmd | Chord.opt), at: 1)
        o.set("bogus.action", Chord("b", Chord.cmd), at: 1)
        var r = ShortcutRegistry()
        o.set("file.print", Chord("p", 0), at: 1)                          // invalid
        o.set("file.closeTab", Chord("q", Chord.cmd), at: 1)               // reserved
        o.set("file.openCommandBar", Chord("t", Chord.cmd), at: 1)         // conflicts with New Tab
        let report = r.importOverrides(o)
        XCTAssertEqual(report.unknown, ["bogus.action"])
        XCTAssertEqual(report.rejected, ["file.closeTab", "file.print"])
        XCTAssertEqual(report.conflicts, [["file.newTab", "file.openCommandBar"]])
        XCTAssertEqual(r.effective("file.print"), Chord("p", Chord.cmd))
        XCTAssertEqual(r.effective("file.closeTab"), Chord("w", Chord.cmd))
        XCTAssertEqual(r.effective("file.share"), Chord("y", Chord.cmd | Chord.opt))
        XCTAssertNil(r.overrides.entries["bogus.action"])
    }

    func testSearchAndFilters() {
        let r = ShortcutRegistry()
        XCTAssertEqual(r.search("").count, ShortcutDefaults.table.count)
        XCTAssertEqual(r.search("new incognito").map(\.id), ["file.newIncognitoWindow"])
        XCTAssertEqual(r.search("NEW INCOGNITO").map(\.id), ["file.newIncognitoWindow"])
        XCTAssertTrue(r.search("history").map(\.id).contains("history.show"))
        XCTAssertEqual(r.search("bookmarks").map(\.section).filter { $0 == "Bookmarks" }.count, 2)
        XCTAssertTrue(r.search("shift cmd a").map(\.id).contains("tabs.searchTabs"))
        XCTAssertTrue(r.search("⇧⌘A").map(\.id).contains("tabs.searchTabs"))
        XCTAssertTrue(r.search("jävascript").map(\.id).contains("view.javaScriptConsole"))
        XCTAssertTrue(r.search("zzzz").isEmpty)
        XCTAssertEqual(r.search("", filter: .referenceOnly).count, ShortcutDefaults.table.filter(\.referenceOnly).count)
        XCTAssertEqual(r.search("", filter: .noShortcut).count, ShortcutDefaults.table.filter { $0.defaultChord == nil }.count)
        XCTAssertTrue(r.search("", filter: .customized).isEmpty)
        XCTAssertTrue(r.search("", filter: .conflicts).isEmpty)
        XCTAssertEqual(r.search("", filter: .all).count, ShortcutDefaults.table.count)
    }

    func testShiftedSymbolsCanonical() {
        let plus = Chord("=", Chord.cmd | Chord.shift)
        XCTAssertEqual(Chord("+", Chord.cmd), plus)
        XCTAssertEqual(Chord("+", Chord.cmd | Chord.shift), plus)
        XCTAssertEqual(plus.glyphs, "⌘+")
        XCTAssertEqual(plus.spoken, "cmd +")
        let r = ShortcutRegistry()
        XCTAssertEqual(r.action(matching: Chord("+", Chord.cmd | Chord.shift)), "view.zoomIn")
        XCTAssertEqual(r.action(matching: Chord("=", Chord.cmd | Chord.shift)), "view.zoomIn")
        XCTAssertEqual(r.action(matching: Chord("+", Chord.ctrl | Chord.shift)), "view.openSplitPane")
        XCTAssertEqual(r.action(matching: Chord("\"", Chord.ctrl | Chord.shift)), "view.focusNextSplitPane")
        XCTAssertEqual(r.action(matching: Chord("{", Chord.ctrl | Chord.shift)), "view.focusPreviousSplitPane")
        XCTAssertEqual(Chord("!", Chord.cmd), Chord("1", Chord.cmd | Chord.shift))
        let data = try! JSONEncoder().encode(Chord("+", Chord.cmd))
        XCTAssertEqual(try! JSONDecoder().decode(Chord.self, from: data), plus)
        let legacy = #"{"key":"+","mods":1}"#.data(using: .utf8)!
        XCTAssertEqual(try! JSONDecoder().decode(Chord.self, from: legacy), plus)
    }

    func testSpokenTokensAnyOrder() {
        let r = ShortcutRegistry()
        XCTAssertTrue(r.search("cmd shift t").map(\.id).contains("file.reopenClosedTab"))
        XCTAssertTrue(r.search("shift cmd t").map(\.id).contains("file.reopenClosedTab"))
        XCTAssertFalse(r.search("cmd shift t").map(\.id).contains("file.newTab"))
    }

    func testMilestoneCaptions() {
        func m(_ id: String) -> String? { ShortcutDefaults.table.first { $0.id == id }?.milestone }
        for id in ["tabs.previousProfile", "tabs.nextProfile", "window.openProfileSwitcher"] { XCTAssertEqual(m(id), "Arrives in M1.7") }
        for id in ["tabs.switcherForward", "tabs.switcherBackward", "tabs.resetPinnedTab"] { XCTAssertEqual(m(id), "Arrives in M1.6") }
        XCTAssertEqual(m("file.newChat"), "Arrives in M2")
        XCTAssertEqual(m("file.sendChatPromptNow"), "Arrives in M2")
        XCTAssertEqual(m("file.openDailyBrief"), "Arrives in M3")
        XCTAssertNil(m("help.checkForUpdates"))
    }

    func testResetWithoutEntryLeavesNoTombstone() {
        var r = ShortcutRegistry()
        r.reset("file.newTab")
        XCTAssertTrue(r.overrides.entries.isEmpty)
        r.clear("file.newTab"); r.reset("file.newTab")
        XCTAssertEqual(r.overrides.entries["file.newTab"]?.reset, true)
    }

    /// The menu bar's chords come from one place: Settings rows through `table`, the fixed ones (system and non-menu commands) through `fixed`.
    func testFixedChordsForMenuAndCommands() {
        XCTAssertTrue(Set(ShortcutDefaults.fixed.keys).isDisjoint(with: ShortcutDefaults.table.map(\.id)))
        XCTAssertEqual(ShortcutDefaults.chord(for: "file.openCommandBar"), Chord("l", Chord.cmd))
        XCTAssertEqual(ShortcutDefaults.chord(for: "edit.pasteMatchStyle"), Chord("v", Chord.cmd | Chord.shift))
        XCTAssertEqual(ShortcutDefaults.chord(for: "edit.showSpelling"), Chord("\u{3a}", Chord.cmd))
        XCTAssertEqual(ShortcutDefaults.chord(for: "tabs.selectTab.1"), Chord("1", Chord.cmd))
        XCTAssertEqual(ShortcutDefaults.chord(for: "tabs.selectLastTab"), Chord("9", Chord.cmd))
        XCTAssertEqual(ShortcutDefaults.chord(for: "tabs.moveTabForward"), Chord("pagedown", Chord.ctrl | Chord.shift))
        XCTAssertNil(ShortcutDefaults.chord(for: "file.share"))
        XCTAssertNil(ShortcutDefaults.chord(for: "no.such.id"))
        let own = Array(ShortcutDefaults.fixed.values)
        XCTAssertEqual(Set(own).count, own.count)
        XCTAssertTrue(Set(own).isDisjoint(with: ShortcutDefaults.table.compactMap { $0.defaultChord }))
        XCTAssertTrue(own.allSatisfy { $0.isValid })
    }
}
