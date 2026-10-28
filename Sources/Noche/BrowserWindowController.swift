import AppKit
import CefBridge
import NocheCore
import NocheStore

/// One window: the engine window, its tab list, and the AppKit chrome around the page.
@MainActor
final class BrowserWindowController: NSObject, NCWindowDelegate {
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
    var typedLoads: [Int: String] = [:]   // engine id to the address a typed load was asked for
    var recordedTitle: [Int: String] = [:]
    var titleThrottle = TitleThrottle(interval: BarHook.on("NO_TITLE_THROTTLE") ? 0 : BrowserWindowController.titleInterval)  // negative control: no minimum interval

    let backdrop = BackdropView(frame: .zero)
    let overlay = ChromeOverlayView(frame: .zero)
    let border = WindowBorderView(frame: .zero)
    let sidebar = SidebarView(frame: .zero)
    let toolbar = ToolbarView(frame: .zero)
    var installed = false
    let findBar = FindBarView(frame: .zero)
    /// Find state per tab (engine id): the pill's text and the last count and active match the engine reported. A tab with no entry is not searching.
    var finds: [Int: FindState] = [:]
    let permissionPrompt = PermissionPromptView(frame: .zero)
    let bookmarksBar = BookmarksBarView(frame: .zero)
    let bookmarkEditor = BookmarkEditView(frame: .zero)
    /// What Bookmark All Tabs saves (the tabs when the card opened), and the tab the Cmd+D card belongs to.
    var bookmarkTabs: [(title: String, url: String)] = []
    var bookmarkEditorTab: Int?
    /// The address of the page the card was opened on: its Remove deletes every bookmark of that page (`AppDelegate.bookmarks(ofPage:)`).
    var bookmarkEditorPage = ""
    /// What the card's Remove took, one undo action per Remove (every copy of the page comes back together).
    /// The tree revision right after that Remove: any other change since expires the entry (`bookmarkUndoValid`).
    var bookmarkUndoRevision = -1
    let bookmarkUndo: UndoManager = { let m = UndoManager(); m.groupsByEvent = false; return m }()
    /// Site permission requests the engine waits for, oldest first; the card shows the first one of the active tab.
    var permissionQueue: [PermissionRequest] = []
    var lastFindText = ""   // the window's last search text: Cmd+F and Cmd+G open the pill with it after Escape, as Chrome does
    var findShownFor: Int?   // the tab whose state the pill shows now; nil with the pill hidden
    /// Built on first use, so a window that never used the bar never builds its view (and its teardown skips it).
    var madeCommandBar: CommandBarController?
    var commandBar: CommandBarController {
        if let c = madeCommandBar { return c }
        let c = CommandBarController(owner: self)
        madeCommandBar = c
        return c
    }
    var newTabShown = false
    var newTabTabID: TabID?
    var reportedActive: TabID?   // the tab the bridge last announced as active (or the window's first)
    var newTabPage: NewTabPageView?
    var focusWhenInstalled = false     // Open Command Bar came before the chrome existed (a window opened for it)
    var sidebarHidden = false
    /// Restoring: the saved tabs are still being added to the engine, so a snapshot now would be partial (and would tombstone tabs).
    var restoring = false
    /// A refresh is queued for this run-loop turn: every change in the turn shares one.
    var refreshQueued = false
    let id: UUID
    /// |item| is the saved tab a restore or a reopen brings back (its stamp, and for a reopen its pin, group and titles).
    struct PendingTab { let id: TabID; let url: String; let index: Int?; var item: TabItem? = nil }
    struct Restore {
        var tabs: [(id: TabID, url: String)]
        var selected: TabID?
        var sidebarHidden: Bool
        var fullScreen: Bool
        var isZoomed = false
        /// The saved window's tabs and structure; the structure goes back once every saved tab is in (|applySavedStructure|).
        var items: [TabID: TabItem] = [:]
        var groups: [TabGroup] = []
        var topOrder: [TopRef] = []
        var dayOrder: [TopRef] = []
        var favicons: [TabID: String] = [:]
        /// Every saved tab in saved order (|tabs| are the ones that get an engine tab; the others, the pinned ones, restore dormant). Empty: |tabs|.
        var order: [TabID] = []
    }
    /// Identity (id, address, index) for the tabs Noche itself asked the engine to add, keyed by the NCTab `addTab` returned: a reopened
    /// tab and the restored tabs after the first keep their saved identity, and a tab the engine adds on its own (Cmd+T through Chrome,
    /// window.open, target=_blank) never takes one. The restored window's first tab is created with the window: it is |initialPending|.
    var pendingByTab: [Int: PendingTab] = [:]
    var initialPending: PendingTab?
    /// New Tab in Group and Duplicate (a group): the group an engine tab joins once it arrives. |template| makes the group when it is not in the list yet.
    struct GroupJoin { let group: GroupID; let template: TabGroup? }
    var groupJoins: [Int: GroupJoin] = [:]
    var restoreRest: [PendingTab] = []
    var firstAdded = false
    var skipActivation: TabID?           // the restore's own activation of the selected tab is not the user using it
    var restore: Restore?
    var restoreAdded = 0
    var restoreStarted = false
    /// The last favicon of a tab that went dormant: shown until it wakes (not stored, so a relaunch shows the placeholder).
    var dormantIcons: [TabID: NSImage] = [:]
    /// How long a restore waits for its tabs before it applies the saved structure to the ones that arrived.
#if NOCHE_TESTHOOKS
    static var restoreFallback: TimeInterval = 15
    /// Test support (pin-launch-held): the restore never asks the engine for its last tab, as if it had not arrived.
    static var holdLastRestoreTab = false
    /// Test support (pin-dormant): the next close Noche starts is held, with the tab already marked closing, until |releaseHeldClose|.
    static var holdNextClose = false
    static var heldClose: (() -> Void)?
    static func releaseHeldClose() { let c = heldClose; heldClose = nil; c?() }
#else
    static let restoreFallback: TimeInterval = 15
#endif
    let initialFrame: NSRect
    var normalFrame: NSRect?            // the frame before full screen, which is what a snapshot stores then
    var lastFrame: NSRect?              // the window's frame as of the last move or resize: a window the engine closed on its own is revived there
    var faviconSeeds: [TabID: (url: String, icon: String)] = [:]   // saved icon address, used until the page reports its own
    var windowClosing = false           // close() was asked: the tabs that go with the window are not "closed tabs"
    var observers: [NSObjectProtocol] = []
    var cardX = ChromeStyle.sidebarWidth
    var animation: (start: TimeInterval, from: CGFloat, to: CGFloat, duration: TimeInterval, overshoot: Bool)?
    var animationTimer: Timer?
    /// When each tab last stopped being the active one: a tab used for hours is idle from when it was left, not from when it was selected.
    var leftAt: [TabID: Date] = [:]
    var discardTimer: Timer?
    var sweeping = false   // a discard sweep is running (its media questions are asynchronous)
#if NOCHE_TESTHOOKS
    /// Test support: how many times each Noche action ran (all windows), the Chrome commands received, where the card was
    /// every time it moved, and where Copy URL writes.
    static var actionCounts: [String: Int] = [:]
    /// Test support: every tab the discard policy asked the engine to discard (the engine refuses some itself, so the policy is read here).
    static var discardCalls: [TabID] = []
    static var commandLog: [Int] = []
    static var pasteboard = NSPasteboard.general
    /// Print, Inspect Elements and JavaScript Console are counted but not run (a hidden run must not raise print or DevTools windows).
    static var suppressChrome = false
    static var strayWindows: [NSWindow] = []
    /// The last sharing picker File > Share... made and the items it was given.
    static var lastShare: (picker: NSSharingServicePicker, items: [Any])?
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
            let all = restore.tabs.map { PendingTab(id: $0.id, url: $0.url, index: nil, item: restore.items[$0.id]) }
            initialPending = all.first
            restoreRest = Array(all.dropFirst())
            for (id, t) in restore.items { if let icon = restore.favicons[id] { faviconSeeds[id] = (t.url, icon) } }  // the dormant ones too: they keep their icon address and show it
            // A saved window whose tabs never arrive must not stay unsaved forever: the saved structure goes onto the tabs that came, and
            // the ones that did not stay as dormant tabs at their saved addresses.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreFallback) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.restore != nil else { return }
                    if BarHook.on("FALLBACK_BARE") { self.restoring = false; return }  // negative control: the old fallback, no saved structure
                    self.finishRestore()
                    self.refresh()
                    self.changed()
                }
            }
        }
        window = NCWindow(url: url, frame: frame, mode: app.hidden ? .hidden : .normal, delegate: self)
        window.webInsets = ChromeLayout(size: frame.size, cardX: cardX, barHeight: app.barMode.visible(onNewTab: false) ? ChromeStyle.bookmarksBarHeight : 0).webInsets
        window.webCornerRadius = ChromeStyle.cardRadius
        window.minimumContentSize = NSSize(width: ChromeStyle.minimumWindowWidth, height: 0)
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
        startDiscardTimer()
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
        findBar.isHidden = true
        overlay.addSubview(findBar)
        overlay.addSubview(permissionPrompt)
        setUpPermissionPrompt()
        overlay.addSubview(bookmarksBar)
        overlay.addSubview(bookmarkEditor)
        setUpBookmarks()
        overlay.addSubview(border)
        setUpFind()
        toolbar.zoom.onClick = { [weak self] in self?.zoom(0) }

        sidebar.lights[0].onClick = { [weak self] in self?.close() }
        sidebar.lights[1].onClick = { [weak self] in self?.nsWindow?.miniaturize(nil) }
        sidebar.lights[2].onClick = { [weak self] in self?.nsWindow?.zoom(nil) }
        sidebar.newTabRow.onClick = { [weak self] in self?.newTab() }
        sidebar.downloadButton.onClick = { [weak self] in self?.app.downloads.show() }
        observers.append(center.addObserver(forName: DownloadsController.changed, object: app.downloads, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebar.downloadButton.progress = self?.app.downloads.ring }
        })
        sidebar.downloadButton.progress = app.downloads.ring
        sidebar.content = { [weak self] entry in self?.sidebarContent(for: entry) }
        sidebar.onSelect = { [weak self] id in self?.row(of: id).map { self?.selectRow($0) } }
        sidebar.onClose = { [weak self] id in self?.row(of: id).map { self?.closeRow($0) } }
        sidebar.onReset = { [weak self] id in self?.resetToPinned(id) }
        sidebar.onTabMenu = { [weak self] id, p in self?.row(of: id).map { self?.showTabMenu(row: $0, at: p) } }
        sidebar.onToggleGroup = { [weak self] g in self?.toggleGroup(g) }
        sidebar.onGroupMenu = { [weak self] g, p in self?.showGroupMenu(group: g, at: p) }
        sidebar.onRenameTab = { [weak self] id, text in self?.renameTab(id, to: text) }
        sidebar.onRenameGroup = { [weak self] g, text in self?.renameGroup(g, to: text) }
        sidebar.groupColor = { [weak self] g in self?.group(withID: g)?.colorIndex ?? 0 }
        sidebar.onEmptyMenu = { [weak self] p in self?.showSidebarMenu(at: p) }
        toolbar.toggle.onClick = { [weak self] in self?.toggleSidebar() }
        toolbar.back.onClick = { [weak self] in self?.goBack() }
        toolbar.forward.onClick = { [weak self] in self?.goForward() }
        toolbar.reload.onClick = { [weak self] in self?.reload() }
        toolbar.address.onClick = { [weak self] in self?.focusAddress() }
        applyLayout()
        refreshNow()
        if focusWhenInstalled { focusWhenInstalled = false; focusAddress() }
        if restore?.sidebarHidden == true { toggleSidebar() }
        // A hidden test window never takes a Space.
        if restore?.fullScreen == true, !app.hidden { ns.toggleFullScreen(nil) }
    }

    func applyLayout() {
        guard installed else { return }
        let layout = ChromeLayout(size: overlay.bounds.size, cardX: cardX, barHeight: barPushesPage && !BarHook.on("BM_NOPUSH") ? ChromeStyle.bookmarksBarHeight : 0, barShown: barVisible)
        backdrop.card.frame = layout.card
        bookmarksBar.frame = layout.bookmarksBar
        bookmarksBar.isHidden = !barVisible
        bookmarkEditor.frame = layout.bookmarkEditor
        toolbar.frame = layout.toolbar
        findBar.frame = layout.findBar
        permissionPrompt.frame = layout.permissionPrompt
        sidebar.frame = layout.sidebar
        window.webInsets = layout.webInsets
        updateNewTabFrame()
        commandBar.relayout()
#if NOCHE_TESTHOOKS
        cardLog.append((ProcessInfo.processInfo.systemUptime, cardX))
#endif
    }

    func shownURL(_ tab: NCTab) -> String { failed[tab.identifier]?.url ?? tab.url }

    /// Asks for a refresh: every change in one run-loop turn (a burst of title and load updates) is one `refreshNow`.
    func refresh() {
        guard installed, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshNow() } }
    }

    func refreshNow() {
        refreshQueued = false
        guard installed else { return }
        sidebar.setEntries(list.layout(), selected: list.activeID)
        let tab = activeTab
        toolbar.back.isEnabled = tab?.canGoBack ?? false
        toolbar.forward.isEnabled = tab?.canGoForward ?? false
        toolbar.address.stringValue = tab.map { shownURL($0) == "about:blank" ? "" : (app.showFullURL ? shownURL($0) : AddressInput.displayHost(shownURL($0))) } ?? ""
        toolbar.address.isHidden = commandBar.isOpen && commandBar.placement == .overlay
        syncFind()
        syncZoom()
        syncPermissionPrompt()
        syncBookmarkEditor()
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

    /// Cmd+L, File > Open Command Bar, the engine's focus-location command and a click on the toolbar's address area.
    func focusAddress() {
        note("focusAddress")
        guard installed else { focusWhenInstalled = true; return }
        commandBar.openFromShortcut()
    }

    /// Our own navigation actions end the "failed load" display: the error page's load end says nothing about the next page.
    func navigated() { if let tab = activeTab { failed[tab.identifier] = nil } }
    func goBack() { note("back"); navigated(); activeTab?.goBack() }
    func goForward() { note("forward"); navigated(); activeTab?.goForward() }
    func reload() { note("reload"); navigated(); activeTab?.reload() }
    func forceReload() { note("forceReload"); navigated(); activeTab?.reloadIgnoringCache() }
    /// `step` 1 zooms in, -1 out and 0 resets; the engine moves through Chromium's preset factors (`CefBrowserHost::Zoom`, 25 to 500 percent).
    func zoom(_ step: Int) {
        note("zoom")
        guard let tab = activeTab else { return }
#if NOCHE_TESTHOOKS
        if BarHook.on("ZOOM_WINDOW") {  // negative control: a window appears on zoom, as the engine's bubble would
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 266), styleMask: .titled, backing: .buffered, defer: false)
            Self.strayWindows.append(w)
            w.orderFront(nil)
        }
#endif
        tab.zoomStep(step)
        syncZoom()
        // The engine applies the level on its own turn in some paths: read it again once it did.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.syncZoom() } }
    }
    func showDevTools() {
        note("devTools")
        activeTab?.showDevTools()
    }
    func copyURL(of tab: NCTab? = nil) {
        note("copyURL")
        guard let url = (tab ?? activeTab)?.url else { return }
        let board = pasteboard
        board.clearContents()
        board.setString(url, forType: .string)
    }

    /// The engine tab of a list item; nil for a dormant tab.
    func engineTab(_ item: TabItem) -> NCTab? { item.engineID.flatMap { tabs[$0] } }

    func selectRow(_ i: Int) {
        guard i < list.items.count else { return }
        activate(list.items[i])
    }

    func closeRow(_ i: Int) {
        guard i < list.items.count, let tab = engineTab(list.items[i]) else { return }
        closeTab(tab)
    }

    func closeTab(_ tab: NCTab) {
        guard !isClosing(tab) else { return }
        if tab === activeTab { closeActiveTab() } else { closing[tab.identifier] = ProcessInfo.processInfo.systemUptime; tab.close() }
    }

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
    static var find = -1, findNext = -1, findPrevious = -1, closeFindOrStop = -1, showDownloads = -1, showHistory = -1

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
        find = id("IDC_FIND"); findNext = id("IDC_FIND_NEXT"); findPrevious = id("IDC_FIND_PREVIOUS"); closeFindOrStop = id("IDC_CLOSE_FIND_OR_STOP"); showDownloads = id("IDC_SHOW_DOWNLOADS"); showHistory = id("IDC_SHOW_HISTORY")  // Noche's own find pill answers all three: Chromium's find bar never shows
    }
}
