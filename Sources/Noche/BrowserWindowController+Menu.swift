import AppKit
import CefBridge
import NocheCore

/// The actions of the menu items that need the window: each counts once under its own name and acts on the active tab.
extension BrowserWindowController {
    /// A new active tab at |url|, the way New Tab opens one.
    func openInNewTab(_ url: String, note n: String) {
        note(n)
        closeNext.removeAll()
        intendedActive = window.addTab(withURL: url, activate: true)
    }

    /// Tabs > Duplicate on the active tab; a tab's context menu passes its own.
    func duplicateTab(of target: NCTab? = nil) {
        note("duplicateTab")
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_DUPLICATE"] == "1" { return }  // negative control
#endif
        guard let tab = target ?? activeTab else { return }
        closeNext.removeAll()
        intendedActive = window.addTab(withURL: shownURL(tab), activate: true)
    }

    /// More day tabs than this and Close All Tabs asks first.
    static let closeAllConfirmAbove = 5

    /// The engine tabs of the day tabs (unpinned, ungrouped) that are not closing: what Close All Tabs closes, and the rule that enables it.
    var closableDayTabs: [NCTab] {
        list.items.filter { !$0.isPinned && $0.groupID == nil }.compactMap { engineTab($0) }.filter { !isClosing($0) }
    }

    /// File > Close All Tabs: the day tabs close (asked first above |closeAllConfirmAbove|); pinned tabs and groups stay. The window keeps an
    /// engine tab: one blank tab opens first when nothing else would be left. Only this window's tabs count.
    func closeAllTabs() {
        note("closeAllTabs")
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_CLOSEALL"] == "1" { return }  // negative control
#endif
        let day = BarHook.on("CLOSEALL_ALL") ? orderedTabs().filter { !isClosing($0) } : closableDayTabs  // the hook: pinned and grouped tabs close too
        guard !day.isEmpty else { return }
        if day.count > Self.closeAllConfirmAbove, !BarHook.on("CLOSEALL_NOCONFIRM"),  // the hook: no question is asked
           !Confirm.ask(.init(message: "Close \(day.count) tabs?", detail: "Pinned tabs and groups stay open.", button: "Close Tabs")) { return }
        let others = orderedTabs().filter { t in !isClosing(t) && !day.contains { $0 === t } }
        let active = intendedActive ?? activeTab
        closeNext.removeAll()
        if others.isEmpty, !BarHook.on("CLOSEALL_NOBLANK") {  // the hook: the window is left with no engine tab
            intendedActive = window.addTab(withURL: "about:blank", activate: true)
        } else if let active, let next = others.first, day.contains(where: { $0 === active }) {
            closeNext[active.identifier] = next
        }
        let now = ProcessInfo.processInfo.systemUptime
        for tab in day { closing[tab.identifier] = now; tab.close() }
    }

    /// A bool setting of the profile: the stored value, the table's default when unset or invalid.
    func flag(_ key: String) -> Bool {
        SettingKeys.bool(key, stored: (try? app.writer?.store.setting(key)).flatMap { $0 })
    }

    /// Edit > Copy URL as Markdown: `[title](url)` (see `MarkdownLink` for the escaping).
    func copyURLMarkdown() {
        note("copyURLMarkdown")
        guard let tab = activeTab else { return }
        let board = pasteboard
        board.clearContents()
        board.setString(MarkdownLink.make(title: tab.title, url: tab.url), forType: .string)
    }

    /// File > Share...: the system sharing picker for the active tab's address, anchored to the toolbar.
    func share() {
        note("share")
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_SHARE"] == "1" { return }  // negative control
#endif
        guard let tab = activeTab, let url = URL(string: tab.url), let anchor = toolbar as NSView? else { return }
        let picker = NSSharingServicePicker(items: [url])
#if NOCHE_TESTHOOKS
        Self.lastShare = (picker, [url])
        if Self.suppressChrome { return }  // a hidden run creates the picker but never shows it
#endif
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// The pasteboard the menu writes to (a test pasteboard in hooks builds).
    static var board: NSPasteboard {
#if NOCHE_TESTHOOKS
        pasteboard
#else
        NSPasteboard.general
#endif
    }

    /// Help > Copy Diagnostics: Noche's version and build, the engine's version as compiled in, and macOS's, on the pasteboard.
    static func diagnosticsText() -> String {
        let info = Bundle.main.infoDictionary
        return """
        Noche \(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))
        Engine (CEF) \(NCEngine.cefVersion())
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }

    static func copyDiagnostics() {
        note("copyDiagnostics")
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_DIAG"] == "1" { return }  // negative control
#endif
        board.clearContents()
        board.setString(diagnosticsText(), forType: .string)
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
