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

    /// The tile width and how many tiles fit the strip: tiles shrink to fit down to `switcherMinTileWidth`, below that the strip shows as many as fit and scrolls.
    private var fit: (width: CGFloat, count: Int) {
        let n = max(tiles.count, 1), gap = ChromeStyle.switcherGap
        if BarHook.on("SWITCH_FIXEDSTEP") { return (ChromeStyle.switcherTileWidth, n) }  // the hook: the fixed 120 + 8 step, whatever the window
        let inner = bounds.width - 2 * ChromeStyle.switcherPad
        let count = Int(min(CGFloat(n), max(1, ((inner + gap) / (ChromeStyle.switcherMinTileWidth + gap)).rounded(.down))))
        return (min(ChromeStyle.switcherTileWidth, (inner - CGFloat(count - 1) * gap) / CGFloat(count)), count)
    }

    /// The tiles drawn: all of them while they fit, else a window of them that ends on the selected tile once it passes the last that fits.
    var drawnRange: Range<Int> {
        let count = fit.count
        let first = BarHook.on("SWITCH_FIXEDSTEP") ? 0 : min(max(0, selected - count + 1), max(0, tiles.count - count))
        return first..<min(tiles.count, first + count)
    }

    func tileFrame(_ i: Int) -> NSRect {
        let f = fit
        return NSRect(x: ChromeStyle.switcherPad + CGFloat(i - drawnRange.lowerBound) * (f.width + ChromeStyle.switcherGap), y: ChromeStyle.switcherPad,
                      width: f.width, height: ChromeStyle.switcherTileHeight)
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
        for i in drawnRange {
            let t = tiles[i], r = tileFrame(i)
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

#if NOCHE_TESTHOOKS
    /// A hidden run has no real Control key: the checks say whether it is down (nil: ask the system).
    static var testControl: Bool?
#endif
    /// Is Control down now (the hardware state, not the event that started the session).
    private var controlDown: Bool {
#if NOCHE_TESTHOOKS
        if let t = Self.testControl { return t }
#endif
        return NSEvent.modifierFlags.contains(.control)
    }

    var selectedID: TabID? { order.indices.contains(index) ? order[index] : nil }

    func press(forward: Bool) {
        if !isActive { begin(forward: forward); return }
        settle()
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
        // Ctrl may be up already (released before this turn, or the row was clicked in the menu): a quick tap, committed at once.
        if !controlDown, !BarHook.on("SWITCH_NOCTRLCHECK") { commit(); return }  // the hook: the session stays open
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

    /// A tab that closed during the session leaves its order; the selection goes to the next live tab of the strip, so Tab and Shift+Tab step over live tiles only.
    private func settle() {
        let n = order.count
        if BarHook.on("SWITCH_NOFOLLOW") { return }  // the hook: the index stays where it was
        guard let i = (0..<n).map({ (index + $0) % n }).first(where: { owner.item(withID: order[$0]) != nil }) else { return }
        if BarHook.on("SWITCH_KEEPGONE") { index = i; return }  // the hook: a gone tab keeps its slot, so a step back lands on it and settles forward again
        let id = order[i]
        order.removeAll { owner.item(withID: $0) == nil }
        index = order.firstIndex(of: id) ?? 0
    }

    /// The strip again after the window's list changed (a tab closed, moved away or archived): the gone tile goes, the highlight stays on its tab.
    func reload() { if isShown, !BarHook.on("SWITCH_NORELOAD") { show() } }  // the hook: a tile stays until the release

    private func show() {
        guard isActive else { return }
        settle()
        view.tiles = order.compactMap { id in owner.item(withID: id).map { .init(id: id, title: owner.shownTitle($0), icon: owner.icon(of: $0)) } }
        view.selected = BarHook.on("SWITCH_NOFOLLOW") ? index : view.tiles.firstIndex { $0.id == selectedID } ?? 0  // the hook: the index into the uncompacted order
        let overlay = owner.overlay
        let w = min(TabSwitcherView.width(for: view.tiles.count), overlay.bounds.width - 2 * ChromeStyle.inset), h = TabSwitcherView.height
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
        settle()
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
