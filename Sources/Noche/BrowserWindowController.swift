import AppKit
import CefBridge
import NocheCore
import NocheStore

/// One window: the engine window, its tab list, and the AppKit chrome around the page.
@MainActor
final class BrowserWindowController: NSObject, NCWindowDelegate, NSTextFieldDelegate {
    unowned let app: AppDelegate
    var window: NCWindow!
    var list = TabList()
    var tabs: [Int: NCTab] = [:]       // engine id to tab
    var ids: [Int: TabID] = [:]        // engine id to Noche id
    /// The tab our own last action made active, until the engine's callback confirms it: the engine's active tab lags behind
    /// a burst of Cmd+T and Cmd+W.
    var intendedActive: NCTab?
    /// The URL whose load failed, with the URL the tab had then: the tab keeps its old URL while the error page shows.
    var failed: [Int: (url: String, shown: String)] = [:]
    /// Close requested, OnBeforeClose not yet seen: engine id to the uptime of the request. A page may cancel its close (a beforeunload
    /// dialog answered Stay), so an entry ends when the bridge reports the cancellation, or after |closeStale| seconds as a fallback.
    var closing: [Int: TimeInterval] = [:]
    /// A tab being closed as the selected one, to the tab that becomes selected once it is gone. The selection moves only when the
    /// close is confirmed (didClose), never before.
    var closeNext: [Int: NCTab] = [:]
    static let closeStale: TimeInterval = 10
    /// Tabs (engine ids) whose next load came from the address entry: that visit is a typed one. Cleared when the load ends or fails.
    var typedLoads = Set<Int>()
    var recordedTitle: [Int: String] = [:]

    let backdrop = BackdropView(frame: .zero)
    let overlay = ChromeOverlayView(frame: .zero)
    let border = WindowBorderView(frame: .zero)
    let sidebar = SidebarView(frame: .zero)
    let toolbar = ToolbarView(frame: .zero)
    var installed = false
    var focusWhenInstalled = false     // Open Command Bar came before the chrome existed (a window opened for it)
    var sidebarHidden = false
    /// Restoring: the saved tabs are still being added to the engine, so a snapshot now would be partial (and would tombstone tabs).
    var restoring = false
    let id: UUID
    struct PendingTab { let id: TabID; let url: String; let index: Int? }
    struct Restore {
        var tabs: [(id: TabID, url: String)]
        var selected: TabID?
        var sidebarHidden: Bool
        var fullScreen: Bool
        var isZoomed = false
        var lastActive: [TabID: Date]
        var favicons: [TabID: String] = [:]
    }
    /// Identity (id, address, index) for the tabs Noche itself asked the engine to add, keyed by the NCTab `addTab` returned: a reopened
    /// tab and the restored tabs after the first keep their saved identity, and a tab the engine adds on its own (Cmd+T through Chrome,
    /// window.open, target=_blank) never takes one. The restored window's first tab is created with the window: it is |initialPending|.
    var pendingByTab: [Int: PendingTab] = [:]
    var initialPending: PendingTab?
    var restoreRest: [PendingTab] = []
    var firstAdded = false
    var skipActivation: TabID?           // the restore's own activation of the selected tab is not the user using it
    var restore: Restore?
    var restoreAdded = 0
    var restoreStarted = false
    let initialFrame: NSRect
    var normalFrame: NSRect?            // the frame before full screen, which is what a snapshot stores then
    var lastActive: [TabID: Date] = [:]
    var faviconSeeds: [TabID: (url: String, icon: String)] = [:]   // saved icon address, used until the page reports its own
    var windowClosing = false           // close() was asked: the tabs that go with the window are not "closed tabs"
    var observers: [NSObjectProtocol] = []
    var cardX = ChromeStyle.sidebarWidth
    var animation: (start: TimeInterval, from: CGFloat, to: CGFloat, duration: TimeInterval, overshoot: Bool)?
    var animationTimer: Timer?
#if NOCHE_TESTHOOKS
    /// Test support: how many times each Noche action ran (all windows), the Chrome commands received, where the card was
    /// every time it moved, and where Copy URL writes.
    static var actionCounts: [String: Int] = [:]
    static var commandLog: [Int] = []
    static var pasteboard = NSPasteboard.general
    var toggleStart: TimeInterval = 0, toggleEnd: TimeInterval = 0
    var cardLog: [(t: TimeInterval, x: CGFloat)] = []
#endif

    init(app: AppDelegate, id: UUID = UUID(), url: String, frame: NSRect, restore: Restore? = nil) {
        self.app = app
        self.id = id
        self.initialFrame = frame
        self.restore = restore
        super.init()
        if let restore {
            restoring = true
            let all = restore.tabs.map { PendingTab(id: $0.id, url: $0.url, index: nil) }
            initialPending = all.first
            restoreRest = Array(all.dropFirst())
            lastActive = restore.lastActive
            for t in restore.tabs { if let icon = restore.favicons[t.id] { faviconSeeds[t.id] = (t.url, icon) } }
            // A saved window whose tabs never arrive must not stay unsaved forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in MainActor.assumeIsolated { self?.restoring = false } }
        }
        window = NCWindow(url: url, frame: frame, mode: app.hidden ? .hidden : .normal, delegate: self)
        window.webInsets = ChromeLayout(size: frame.size, cardX: cardX).webInsets
        window.webCornerRadius = ChromeStyle.cardRadius
    }

    var nsWindow: NSWindow? { window.nsWindow }
    var activeTab: NCTab? { window.activeTab }

    static func note(_ action: String) {
#if NOCHE_TESTHOOKS
        actionCounts[action, default: 0] += 1
#endif
    }
    func note(_ action: String) { Self.note(action) }
    var pasteboard: NSPasteboard {
#if NOCHE_TESTHOOKS
        Self.pasteboard
#else
        NSPasteboard.general
#endif
    }

    // MARK: chrome

    /// The engine window exists a little after init; the chrome goes in as soon as it does.
    func installChrome() {
        guard !installed else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NOCHROME"] == "1" { return }  // negative control: no chrome views
#endif
        guard let ns = window.nsWindow, let host = window.chromeHost, let content = ns.contentView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in MainActor.assumeIsolated { self?.installChrome() } }
            return
        }
        installed = true
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: ns, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.changed(geometry: true) } })
        }
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: ns, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.normalFrame = self?.nsWindow?.frame }
        })
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
        if focusWhenInstalled { focusWhenInstalled = false; focusAddress() }
        if restore?.sidebarHidden == true { toggleSidebar() }
        // A hidden test window never takes a Space.
        if restore?.fullScreen == true, !app.hidden { ns.toggleFullScreen(nil) }
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

    func shownURL(_ tab: NCTab) -> String { failed[tab.identifier]?.url ?? tab.url }

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
        changed()
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

    func tick() {
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
        windowClosing = true
        window.close()
    }

    func focusAddress() {
        note("focusAddress")
        guard installed, let ns = nsWindow else { focusWhenInstalled = true; return }
        toolbar.address.stringValue = activeTab.map { shownURL($0) == "about:blank" ? "" : shownURL($0) } ?? ""
        ns.makeFirstResponder(toolbar.address)
        toolbar.address.currentEditor()?.selectAll(nil)
    }

    /// Our own navigation actions end the "failed load" display: the error page's load end says nothing about the next page.
    func navigated() { if let tab = activeTab { failed[tab.identifier] = nil } }
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

    func selectRow(_ i: Int) {
        closeNext.removeAll()
        guard i < list.items.count, let tab = tabs[list.items[i].engineID] else { return }
        window.activateTab(tab)
    }

    func closeRow(_ i: Int) {
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
                typedLoads.insert(tab.identifier)
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

    func endEditing() {
        guard let ns = nsWindow else { return }
        ns.makeFirstResponder(ns.contentView)
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) { refresh() }

    // MARK: test support

    /// Frame of the identified view in window points, origin top-left.
    func frame(ofIdentifier id: String) -> CGRect? {
        guard let host = window.chromeHost, let view = find(id, in: host) else { return nil }
        return view.convert(view.bounds, to: overlay)
    }

    func view(withIdentifier id: String) -> NSView? { window.chromeHost.flatMap { find(id, in: $0) } }

    func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for s in view.subviews { if let v = find(id, in: s) { return v } }
        return nil
    }
}

/// Chrome command ids Noche answers itself, looked up by name in the running engine (vendor/cef/include/cef_command_ids.h has
/// the names), so an engine update that renumbers them cannot silently break the shortcuts. Call `resolve()` once the engine started.
@MainActor
enum ChromeCommand {
    static var back = -1, forward = -1, reload = -1, reloadBypassingCache = -1, reloadClearingCache = -1
    static var newWindow = -1, closeWindow = -1, newTab = -1, closeTab = -1, selectNextTab = -1, selectPreviousTab = -1
    static var restoreTab = -1, selectTab0 = -1, selectLastTab = -1, moveTabNext = -1, moveTabPrevious = -1
    static var zoomPlus = -1, zoomNormal = -1, zoomMinus = -1, focusLocation = -1, devTools = -1

    static func resolve() {
        func id(_ name: String) -> Int {
            let n = NCEngine.chromeCommandIdNamed(name)
            if n < 0 { FileHandle.standardError.write(Data("NOCHE unknown Chrome command \(name)\n".utf8)) }
            return n
        }
        back = id("IDC_BACK"); forward = id("IDC_FORWARD"); reload = id("IDC_RELOAD")
        reloadBypassingCache = id("IDC_RELOAD_BYPASSING_CACHE"); reloadClearingCache = id("IDC_RELOAD_CLEARING_CACHE")
        newWindow = id("IDC_NEW_WINDOW"); closeWindow = id("IDC_CLOSE_WINDOW"); newTab = id("IDC_NEW_TAB"); closeTab = id("IDC_CLOSE_TAB")
        selectNextTab = id("IDC_SELECT_NEXT_TAB"); selectPreviousTab = id("IDC_SELECT_PREVIOUS_TAB")
        restoreTab = id("IDC_RESTORE_TAB"); selectLastTab = id("IDC_SELECT_LAST_TAB")
        moveTabNext = id("IDC_MOVE_TAB_NEXT"); moveTabPrevious = id("IDC_MOVE_TAB_PREVIOUS")  // 34032 and 34033 in cef_command_ids.h
        selectTab0 = id("IDC_SELECT_TAB_0")  // IDC_SELECT_TAB_1 to _7 follow it (34018 to 34025 in cef_command_ids.h)
        zoomPlus = id("IDC_ZOOM_PLUS"); zoomNormal = id("IDC_ZOOM_NORMAL"); zoomMinus = id("IDC_ZOOM_MINUS")
        focusLocation = id("IDC_FOCUS_LOCATION"); devTools = id("IDC_DEV_TOOLS")
    }
}
