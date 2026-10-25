import AppKit
import CefBridge

/// The actions of the menu items that need the window: each counts once under its own name and acts on the active tab.
extension BrowserWindowController {
    /// A new active tab at |url|, the way New Tab opens one.
    func openInNewTab(_ url: String, note n: String) {
        note(n)
        closeNext.removeAll()
        intendedActive = window.addTab(withURL: url, activate: true)
    }

    func duplicateTab() {
        note("duplicateTab")
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_DUPLICATE"] == "1" { return }  // negative control
#endif
        guard let tab = activeTab else { return }
        closeNext.removeAll()
        intendedActive = window.addTab(withURL: shownURL(tab), activate: true)
    }

    /// File > Close All Tabs: every tab of the window closes but one blank tab (a lone blank tab is left as it is).
    func closeAllTabs() {
        note("closeAllTabs")
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_CLOSEALL"] == "1" { return }  // negative control
#endif
        let open = orderedTabs().filter { !isClosing($0) }
        if open.count == 1, open[0].url == "about:blank" { return }
        closeNext.removeAll()
        intendedActive = window.addTab(withURL: "about:blank", activate: true)
        let now = ProcessInfo.processInfo.systemUptime
        for tab in open { closing[tab.identifier] = now; tab.close() }
    }

    /// Edit > Copy URL as Markdown: `[title](url)`, the title standing in for itself when the page has none.
    func copyURLMarkdown() {
        note("copyURLMarkdown")
        guard let tab = activeTab else { return }
        let title = (tab.title.isEmpty ? tab.url : tab.title).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let board = pasteboard
        board.clearContents()
        board.setString("[\(title)](\(tab.url))", forType: .string)
    }

    func printPage() {
        note("print")
#if NOCHE_TESTHOOKS
        if Self.suppressChrome { return }
#endif
        activeTab?.printPage()
    }

    /// A Chrome command run on the active tab when the engine can (Inspect Elements, JavaScript Console).
    func chromeCommand(_ name: String, note n: String) {
        note(n)
#if NOCHE_TESTHOOKS
        if Self.suppressChrome { return }
#endif
        _ = activeTab?.executeChromeCommandNamed(name)
    }
}
