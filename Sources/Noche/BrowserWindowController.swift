import AppKit
import CefBridge
import NocheCore

/// One window: the engine window, its tab list, and the AppKit chrome around the page.
@MainActor
final class BrowserWindowController: NSObject, NCWindowDelegate, NSTextFieldDelegate {
    private unowned let app: AppDelegate
    private(set) var window: NCWindow!
    private(set) var list = TabList()
    private var tabs: [Int: NCTab] = [:]       // engine id to tab
    private var ids: [Int: TabID] = [:]        // engine id to Noche id
    /// The tab our own last action made active, until the engine's callback confirms it: the engine's active tab lags behind
    /// a burst of Cmd+T and Cmd+W.
    private var intendedActive: NCTab?
    /// The URL whose load failed, with the URL the tab had then: the tab keeps its old URL while the error page shows.
    private var failed: [Int: (url: String, shown: String)] = [:]
    /// Close requested, OnBeforeClose not yet seen: engine id to the uptime of the request. A page may cancel its close (a beforeunload
    /// dialog answered Stay), so an entry ends when the bridge reports the cancellation, or after |closeStale| seconds as a fallback.
    private var closing: [Int: TimeInterval] = [:]
    /// A tab being closed as the selected one, to the tab that becomes selected once it is gone. The selection moves only when the
    /// close is confirmed (didClose), never before.
    private var closeNext: [Int: NCTab] = [:]
    private static let closeStale: TimeInterval = 10

    private let backdrop = BackdropView(frame: .zero)
    private let overlay = ChromeOverlayView(frame: .zero)
    private let border = WindowBorderView(frame: .zero)
    let sidebar = SidebarView(frame: .zero)
    let toolbar = ToolbarView(frame: .zero)
    private var installed = false
    private(set) var sidebarHidden = false
    private(set) var cardX = ChromeStyle.sidebarWidth
    private var animation: (start: TimeInterval, from: CGFloat, to: CGFloat, duration: TimeInterval, overshoot: Bool)?
    private var animationTimer: Timer?
#if NOCHE_TESTHOOKS
    /// Test support: how many times each Noche action ran (all windows), the Chrome commands received, where the card was
    /// every time it moved, and where Copy URL writes.
    static var actionCounts: [String: Int] = [:]
    static var commandLog: [Int] = []
    static var pasteboard = NSPasteboard.general
    var toggleStart: TimeInterval = 0, toggleEnd: TimeInterval = 0
    var cardLog: [(t: TimeInterval, x: CGFloat)] = []
#endif

    init(app: AppDelegate, url: String, frame: NSRect) {
        self.app = app
        super.init()
        window = NCWindow(url: url, frame: frame, mode: app.hidden ? .hidden : .normal, delegate: self)
        window.webInsets = ChromeLayout(size: frame.size, cardX: cardX).webInsets
        window.webCornerRadius = ChromeStyle.cardRadius
    }

    var nsWindow: NSWindow? { window.nsWindow }
    private var activeTab: NCTab? { window.activeTab }

    static func note(_ action: String) {
#if NOCHE_TESTHOOKS
        actionCounts[action, default: 0] += 1
#endif
    }
    private func note(_ action: String) { Self.note(action) }
    private var pasteboard: NSPasteboard {
#if NOCHE_TESTHOOKS
        Self.pasteboard
#else
        NSPasteboard.general
#endif
    }

    // MARK: chrome

    /// The engine window exists a little after init; the chrome goes in as soon as it does.
    private func installChrome() {
        guard !installed else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NOCHROME"] == "1" { return }  // negative control: no chrome views
#endif
        guard let ns = window.nsWindow, let host = window.chromeHost, let content = ns.contentView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in MainActor.assumeIsolated { self?.installChrome() } }
            return
        }
        installed = true
        ns.isOpaque = false
        ns.backgroundColor = .clear
        ns.appearance = NSAppearance(named: .darkAqua)
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop, positioned: .below, relativeTo: content)
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onResize = { [weak self] in self?.applyLayout() }
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        border.frame = overlay.bounds
        border.autoresizingMask = [.width, .height]
        overlay.addSubview(sidebar)
        overlay.addSubview(toolbar)
        overlay.addSubview(border)

        sidebar.lights[0].onClick = { [weak self] in self?.close() }
        sidebar.lights[1].onClick = { [weak self] in self?.nsWindow?.miniaturize(nil) }
        sidebar.lights[2].onClick = { [weak self] in self?.nsWindow?.zoom(nil) }
        sidebar.newTabRow.onClick = { [weak self] in self?.newTab() }
        sidebar.onSelect = { [weak self] i in self?.selectRow(i) }
        sidebar.onClose = { [weak self] i in self?.closeRow(i) }
        toolbar.toggle.onClick = { [weak self] in self?.toggleSidebar() }
        toolbar.back.onClick = { [weak self] in self?.goBack() }
        toolbar.forward.onClick = { [weak self] in self?.goForward() }
        toolbar.reload.onClick = { [weak self] in self?.reload() }
        toolbar.address.delegate = self
        applyLayout()
        refresh()
    }

    func applyLayout() {
        guard installed else { return }
        let layout = ChromeLayout(size: overlay.bounds.size, cardX: cardX)
        backdrop.card.frame = layout.card
        toolbar.frame = layout.toolbar
        sidebar.frame = layout.sidebar
        window.webInsets = layout.webInsets
#if NOCHE_TESTHOOKS
        cardLog.append((ProcessInfo.processInfo.systemUptime, cardX))
#endif
    }

    private func shownURL(_ tab: NCTab) -> String { failed[tab.identifier]?.url ?? tab.url }

    func refresh() {
        guard installed else { return }
        let entries = list.items.map { (title: list.displayTitle(of: $0.id), favicon: tabs[$0.engineID]?.favicon) }
        sidebar.setRows(entries, selected: list.items.firstIndex { $0.id == list.activeID })
        let tab = activeTab
        toolbar.back.isEnabled = tab?.canGoBack ?? false
        toolbar.forward.isEnabled = tab?.canGoForward ?? false
        if toolbar.address.currentEditor() == nil {
            toolbar.address.stringValue = tab.map { shownURL($0) == "about:blank" ? "" : AddressInput.displayHost(shownURL($0)) } ?? ""
        }
    }

    // MARK: sidebar motion (live-ui.md section 8)

    func toggleSidebar() {
        note("toggleSidebar")
#if NOCHE_TESTHOOKS
        toggleStart = ProcessInfo.processInfo.systemUptime
        toggleEnd = 0
#endif
        sidebarHidden.toggle()
        let to: CGFloat = sidebarHidden ? ChromeStyle.inset : ChromeStyle.sidebarWidth
        if !sidebarHidden { sidebar.setTrafficLightsHidden(false) }
        animation = (ProcessInfo.processInfo.systemUptime, cardX, to, sidebarHidden ? ChromeStyle.hideDuration : ChromeStyle.showDuration, !sidebarHidden)
        if animationTimer == nil {
            // Computed from elapsed time on the main thread: a hidden window gets no display-link frames.
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
        // The last frame lands on time even when a tick is late.
        let started = animation?.start
        DispatchQueue.main.asyncAfter(deadline: .now() + (animation?.duration ?? 0)) { [weak self] in
            MainActor.assumeIsolated { if let self, self.animation?.start == started { self.tick() } }
        }
        tick()
    }

    private func tick() {
        guard let a = animation else { return }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - a.start) / a.duration)
        let u = CGFloat(t) - 1
        let c = ChromeStyle.overshootBack
        let eased = a.overshoot ? 1 + (c + 1) * u * u * u + c * u * u : 1 + u * u * u  // ease-out-back for show, cubic ease-out for hide
        cardX = t >= 1 ? a.to : a.from + (a.to - a.from) * eased
        applyLayout()
        if t >= 1 {
            animation = nil
#if NOCHE_TESTHOOKS
            toggleEnd = ProcessInfo.processInfo.systemUptime
#endif
            animationTimer?.invalidate()
            animationTimer = nil
            if sidebarHidden { sidebar.setTrafficLightsHidden(true) }
        }
    }

    // MARK: actions (menu, shortcuts, chrome buttons and engine commands all land here)

    func newTab() {
        note("newTab")
        closeNext.removeAll()  // the new tab is the selection now
        intendedActive = window.addTab(withURL: "about:blank", activate: true)
    }

    func close() {
        note("closeWindow")
        window.close()
    }

    private func isClosing(_ tab: NCTab) -> Bool {
        closing[tab.identifier].map { ProcessInfo.processInfo.systemUptime - $0 < Self.closeStale } ?? false
    }

    /// The first tab of |tab|'s hand-over chain that is neither closing nor gone (asked of the engine's strip, which is current
    /// even before the delegate has heard of a tab opened in the same turn).
    private func survivor(from tab: NCTab?) -> NCTab? {
        var t = tab
        let strip = window.tabs
        for _ in 0..<100 {
            guard let c = t else { return nil }
            if !isClosing(c), strip.contains(where: { $0 === c }) { return c }
            t = closeNext[c.identifier]
        }
        return nil
    }

    /// Closes the selected tab; once it is gone the row below becomes selected (the one above for the last row). The selection does
    /// not move before that: a page can refuse to close. A tab that is already closing hands the focus to the tab that follows it, so
    /// a burst of Cmd+W closes one tab each. Decided from the engine's own tab strip, which is current even when callbacks lag.
    func closeActiveTab() {
        note("closeTab")
        guard let active = survivor(from: intendedActive ?? activeTab) else { return }
        let open = window.tabs.filter { !isClosing($0) }
        if let i = open.firstIndex(where: { $0 === active }) {
            closeNext[active.identifier] = i + 1 < open.count ? open[i + 1] : (i > 0 ? open[i - 1] : nil)
        }
        closing[active.identifier] = ProcessInfo.processInfo.systemUptime
        active.close()
    }

    func selectNextTab() { note("nextTab"); step(1) }
    func selectPreviousTab() { note("previousTab"); step(-1) }

    private func step(_ delta: Int) {
        closeNext.removeAll()
        guard let id = intendedActive.flatMap({ ids[$0.identifier] }) ?? list.activeID,
              let target = delta > 0 ? list.next(after: id) : list.previous(before: id),
              let engineID = list.items.first(where: { $0.id == target })?.engineID, let tab = tabs[engineID] else { return }
        intendedActive = tab
        window.activateTab(tab)
    }

    func focusAddress() {
        note("focusAddress")
        guard installed, let ns = nsWindow else { return }
        toolbar.address.stringValue = activeTab.map { shownURL($0) == "about:blank" ? "" : shownURL($0) } ?? ""
        ns.makeFirstResponder(toolbar.address)
        toolbar.address.currentEditor()?.selectAll(nil)
    }

    /// Our own navigation actions end the "failed load" display: the error page's load end says nothing about the next page.
    private func navigated() { if let tab = activeTab { failed[tab.identifier] = nil } }
    func goBack() { note("back"); navigated(); activeTab?.goBack() }
    func goForward() { note("forward"); navigated(); activeTab?.goForward() }
    func reload() { note("reload"); navigated(); activeTab?.reload() }
    func forceReload() { note("forceReload"); navigated(); activeTab?.reloadIgnoringCache() }
    func zoom(_ delta: Double?) {
        note("zoom")
        guard let tab = activeTab else { return }
        tab.zoomLevel = delta.map { min(5, max(-5, tab.zoomLevel + $0)) } ?? 0
    }
    func showDevTools() {
        note("devTools")
        activeTab?.showDevTools()
    }
    func copyURL() {
        note("copyURL")
        guard let url = activeTab?.url else { return }
        let board = pasteboard
        board.clearContents()
        board.setString(url, forType: .string)
    }

    private func selectRow(_ i: Int) {
        closeNext.removeAll()
        guard i < list.items.count, let tab = tabs[list.items[i].engineID] else { return }
        window.activateTab(tab)
    }

    private func closeRow(_ i: Int) {
        guard i < list.items.count, let tab = tabs[list.items[i].engineID], !isClosing(tab) else { return }
        if tab === activeTab { closeActiveTab() } else { closing[tab.identifier] = ProcessInfo.processInfo.systemUptime; tab.close() }
    }

    // MARK: address field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = toolbar.address.stringValue
            if let url = AddressInput.resolve(text, searchTemplate: app.searchTemplate), let tab = activeTab {
                failed[tab.identifier] = nil
                tab.loadURL(url.absoluteString)
            }
            endEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            return true
        default:
            return false
        }
    }

    private func endEditing() {
        guard let ns = nsWindow else { return }
        ns.makeFirstResponder(ns.contentView)
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) { refresh() }

    // MARK: NCWindowDelegate

    private func item(for tab: NCTab) -> TabItem {
        let id = ids[tab.identifier] ?? TabID()
        ids[tab.identifier] = id
        return TabItem(id: id, engineID: tab.identifier, url: tab.url, title: tab.title, isLoading: tab.isLoading)
    }

    func window(_ window: NCWindow, didAdd tab: NCTab, active: Bool) {
        installChrome()
        tabs[tab.identifier] = tab
        // Keep the rows in the engine's strip order: the new tab goes right after the tab before it in the strip.
        let strip = window.tabs
        let before = strip.firstIndex(where: { $0 === tab }).flatMap { $0 > 0 ? strip[$0 - 1] : nil }
        list.insert(item(for: tab), after: before.flatMap { ids[$0.identifier] }, activate: active)
        refresh()
        app.tabAdded(tab)
    }

    func window(_ window: NCWindow, didActivate tab: NCTab, previous: NCTab?) {
        if let id = ids[tab.identifier] { list.activate(id) }
        if intendedActive === tab { intendedActive = nil }
        refresh()
        app.tabActivated(tab)
    }

    func window(_ window: NCWindow, didClose tab: NCTab) {
        let successor = closeNext.removeValue(forKey: tab.identifier)
        if let id = ids[tab.identifier] { _ = list.remove(id) }
        tabs[tab.identifier] = nil
        ids[tab.identifier] = nil
        failed[tab.identifier] = nil
        closing[tab.identifier] = nil
        if intendedActive === tab { intendedActive = nil }
        // The close is confirmed: the selection moves to the tab chosen when it was asked for.
        if let next = survivor(from: successor) { intendedActive = next; window.activateTab(next) }
        refresh()
        app.tabClosed(tab)
    }

    /// The page refused to close (beforeunload answered Stay): the tab stays, selected as it was.
    func window(_ window: NCWindow, didCancelCloseOf tab: NCTab) {
        closing[tab.identifier] = nil
        closeNext[tab.identifier] = nil
    }

    func window(_ window: NCWindow, didUpdate tab: NCTab) {
        // The next committed navigation of the tab, whatever caused it, ends the failed display.
        if let f = failed[tab.identifier], tab.url != f.shown, tab.url != f.url { failed[tab.identifier] = nil }
        if let id = ids[tab.identifier] { list.update(id, url: shownURL(tab), title: tab.title, isLoading: tab.isLoading) }
        refresh()
        app.tabUpdated(tab)
    }

    func window(_ window: NCWindow, tab: NCTab, didFinishLoadWithStatus status: Int) {
        app.tabLoaded(tab, status: status)
    }

    func window(_ window: NCWindow, tab: NCTab, didFailLoadWithCode code: Int, url: String) {
        guard code != -3 else { return }  // ERR_ABORTED: a navigation replaced by another, not a failure
        failed[tab.identifier] = (url, tab.url)
        if let id = ids[tab.identifier] { list.update(id, url: url, title: tab.title, isLoading: false) }
        refresh()
        app.tabLoadFailed(code: code)
    }

    /// Chrome commands that duplicate a Noche action run the Noche action and are answered YES.
    func window(_ window: NCWindow, shouldHandleChromeCommand commandId: Int) -> Bool {
#if NOCHE_TESTHOOKS
        Self.commandLog.append(commandId)
#endif
        switch commandId {
        case ChromeCommand.newTab: newTab()
        case ChromeCommand.closeTab: closeActiveTab()
        case ChromeCommand.selectNextTab: selectNextTab()
        case ChromeCommand.selectPreviousTab: selectPreviousTab()
        case ChromeCommand.newWindow: app.newWindowAction()
        case ChromeCommand.closeWindow: close()
        case ChromeCommand.back: goBack()
        case ChromeCommand.forward: goForward()
        case ChromeCommand.reload: reload()
        case ChromeCommand.reloadBypassingCache, ChromeCommand.reloadClearingCache: forceReload()
        case ChromeCommand.focusLocation: focusAddress()
        case ChromeCommand.zoomPlus: zoom(0.5)
        case ChromeCommand.zoomMinus: zoom(-0.5)
        case ChromeCommand.zoomNormal: zoom(nil)
        case ChromeCommand.devTools: showDevTools()
        default: return false
        }
        return true
    }

    func windowDidClose(_ window: NCWindow) {
        animationTimer?.invalidate()
        app.controllerClosed(self)
    }

    // MARK: test support

    /// Frame of the identified view in window points, origin top-left.
    func frame(ofIdentifier id: String) -> CGRect? {
        guard let host = window.chromeHost, let view = find(id, in: host) else { return nil }
        return view.convert(view.bounds, to: overlay)
    }

    func view(withIdentifier id: String) -> NSView? { window.chromeHost.flatMap { find(id, in: $0) } }

    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for s in view.subviews { if let v = find(id, in: s) { return v } }
        return nil
    }
}

/// Chrome command ids Noche answers itself (vendor/cef/include/cef_command_ids.h).
enum ChromeCommand {
    static let back = 33000, forward = 33001, reload = 33002, reloadBypassingCache = 33007, reloadClearingCache = 33009
    static let newWindow = 34000, closeWindow = 34012, newTab = 34014, closeTab = 34015
    static let selectNextTab = 34016, selectPreviousTab = 34017
    static let zoomPlus = 38001, zoomNormal = 38002, zoomMinus = 38003, focusLocation = 39001, devTools = 40004
}
