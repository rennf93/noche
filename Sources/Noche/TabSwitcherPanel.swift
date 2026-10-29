import AppKit
import NocheCore

/// The Ctrl+Tab strip: up to 8 tiles (favicon over title) in most-recently-used order, the selected one filled like a selected command bar row.
/// It draws from its model; the controller owns the session.
final class TabSwitcherView: NSView {
    override var isFlipped: Bool { true }
    struct Tile: Equatable {
        var id: TabID
        var title: String
        var icon: NSImage?
        static func == (a: Tile, b: Tile) -> Bool { a.id == b.id && a.title == b.title && a.icon === b.icon }
    }
    var tiles: [Tile] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    private static let placeholder = ChromeStyle.symbol("globe", size: 20, color: ChromeStyle.barPlaceholder)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("tabSwitcher")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // a strip for the eyes: the keys decide

    /// The window-width the strip needs for |count| tiles.
    static func width(for count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        return 2 * ChromeStyle.switcherPad + n * ChromeStyle.switcherTileWidth + (n - 1) * ChromeStyle.switcherGap
    }
    static var height: CGFloat { 2 * ChromeStyle.switcherPad + ChromeStyle.switcherTileHeight }

    func tileFrame(_ i: Int) -> NSRect {
        NSRect(x: ChromeStyle.switcherPad + CGFloat(i) * (ChromeStyle.switcherTileWidth + ChromeStyle.switcherGap), y: ChromeStyle.switcherPad,
               width: ChromeStyle.switcherTileWidth, height: ChromeStyle.switcherTileHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.barRadius, yRadius: ChromeStyle.barRadius)
        ChromeStyle.barFill.setFill()
        card.fill()
        ChromeStyle.barBorder.setStroke()
        card.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: ChromeStyle.switcherFont, .foregroundColor: ChromeStyle.barTitle, .paragraphStyle: style]
        for (i, t) in tiles.enumerated() {
            let r = tileFrame(i)
            if i == selected {
                ChromeStyle.barRowSelected.setFill()
                NSBezierPath(roundedRect: r, xRadius: ChromeStyle.barRowRadius, yRadius: ChromeStyle.barRowRadius).fill()
            }
            let side = ChromeStyle.switcherIconSize
            let icon = NSRect(x: r.midX - side / 2, y: r.minY + 12, width: side, height: side)
            if let image = t.icon ?? Self.placeholder { image.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            (t.title as NSString).draw(with: NSRect(x: r.minX + 8, y: icon.maxY + 8, width: r.width - 16, height: r.maxY - icon.maxY - 12),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }
}

/// Ctrl+Tab and Ctrl+Shift+Tab (M1.6 Task 6). The bridge claims the chords ahead of the engine; each press advances through the tabs by recency, the strip shows
/// from the second press or after `switcherShowDelay`, and letting go of Ctrl commits (a flagsChanged monitor). A release before the strip showed is a quick tap:
/// it switches to the previous tab with no overlay.
@MainActor
final class TabSwitcherController {
    unowned let owner: BrowserWindowController
    let view = TabSwitcherView(frame: .zero)
    /// The tabs of the session, most recent first, and the one a release would switch to.
    private(set) var order: [TabID] = []
    private(set) var index = 0
    private(set) var isActive = false
    private(set) var isShown = false
    /// How many times the strip was put on screen (a quick tap leaves it alone).
    private(set) var shownCount = 0
    private var showTimer: Timer?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(owner: BrowserWindowController) { self.owner = owner }

    var selectedID: TabID? { order.indices.contains(index) ? order[index] : nil }

    func press(forward: Bool) {
        if !isActive { begin(forward: forward); return }
        let n = order.count
        index = forward ? (index + 1) % n : (index - 1 + n) % n
        show()
    }

    private func begin(forward: Bool) {
        let limit = BarHook.on("SWITCH_NOLIMIT") ? 100 : ChromeStyle.switcherLimit  // the hook: no limit of 8 tiles
        var ids = BarHook.on("SWITCH_LISTORDER") ? Array(owner.list.items.map(\.id).prefix(limit)) : owner.list.mru(limit: limit)  // the hook: list order, not recency
        if let active = owner.list.activeID {  // the tab on screen is the first of the order whatever its stamp says
            ids.removeAll { $0 == active }
            ids.insert(active, at: 0)
            ids = Array(ids.prefix(limit))
        }
        guard ids.count > 1 else { return }  // nothing to switch to
        order = ids
        index = forward ? 1 : ids.count - 1
        isActive = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { if !event.modifierFlags.contains(.control), !BarHook.on("SWITCH_NORELEASE") { self?.commit() } }  // the hook: letting go commits nothing
            return event
        }
        // Ctrl can be let go in another app (a Cmd+Tab away): the release is never seen here, so the session ends without a switch.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        let t = Timer(timeInterval: ChromeStyle.switcherShowDelay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.show() } }
        RunLoop.main.add(t, forMode: .common)
        showTimer = t
        if BarHook.on("SWITCH_EAGER") { show() }  // the hook: the strip shows at once, a quick tap is not quick
    }

    private func show() {
        guard isActive else { return }
        view.tiles = order.compactMap { id in owner.item(withID: id).map { .init(id: id, title: owner.shownTitle($0), icon: owner.icon(of: $0)) } }
        view.selected = index
        let overlay = owner.overlay
        let w = min(TabSwitcherView.width(for: view.tiles.count), overlay.bounds.width), h = TabSwitcherView.height
        view.frame = NSRect(x: (overlay.bounds.width - w) / 2, y: (overlay.bounds.height - h) / 2, width: w, height: h)
        if !isShown {
            isShown = true
            shownCount += 1
            overlay.addSubview(view, positioned: .below, relativeTo: owner.border)
        }
    }

    /// Ctrl was let go: the selected tab comes forward.
    func commit() {
        guard isActive else { return }
        let target = selectedID
        end()
        if let id = target, let item = owner.item(withID: id) { owner.activate(item) }
    }

    func cancel() { end() }

    private func end() {
        isActive = false
        isShown = false
        showTimer?.invalidate()
        showTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        view.removeFromSuperview()
    }

    func teardown() { end() }
}

extension BrowserWindowController {
    /// Ctrl+Tab (|forward|) or Ctrl+Shift+Tab: starts the switcher or advances it.
    func switcherPress(forward: Bool) {
        note("tabSwitcher")
        if let bar = madeCommandBar, bar.isOpen, bar.placement == .overlay { bar.close(restoreFocus: false) }
        madeSearch?.close(restoreFocus: false)
        tabSwitcher.press(forward: forward)
    }
}
