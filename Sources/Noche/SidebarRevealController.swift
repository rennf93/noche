import AppKit
import CefBridge
import NocheCore

/// The 6 pt strip at the window's left edge. It only watches the pointer (a tracking area) and takes no click, so a click there reaches what is under it.
final class RevealStripView: NSView {
    var onMove: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { BarHook.on("REVEAL_STRIPHIT") ? self : nil }  // the hook: the strip takes the click
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil).x) }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil).x) }
    /// Leaving the strip is a move to where the pointer went: a dwell still pending must not fire for a pointer that is gone, whatever the monitor sees.
    override func mouseExited(with event: NSEvent) { if !BarHook.on("REVEAL_NOEXIT") { onMove?(convert(event.locationInWindow, from: nil).x) } }  // the hook: the exit is ignored
}

/// The sidebar's panel while it overlays the page: the page is no vibrancy, so rows drawn straight over it would show it through.
final class RevealBackingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ChromeStyle.revealFill.cgColor
        layer?.borderColor = ChromeStyle.cardBorder.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = ChromeStyle.cardRadius
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Auto-hide's hover reveal (M1.6 Task 8, spec row 107): with the sidebar hidden, the pointer resting in the 6 pt strip slides it in over the page (the card
/// does not move) and it slides out again once the pointer has been away. The timing is `SidebarRevealPolicy`; this class feeds it the pointer and the
/// guards, runs the slide (same curves as the toggle, `ChromeStyle.eased`) and answers the toggle: Cmd+S or the button while revealed makes the sidebar permanent.
/// The pointer comes from the strip's tracking area and a local monitor (a CEF view may swallow mouseMoved); both call `pointerMoved(toX:)`, which the checks call too.
@MainActor
final class SidebarRevealController {
    unowned let owner: BrowserWindowController
    private(set) var policy = SidebarRevealPolicy()
    /// 0 hidden, 1 on screen, a little over 1 at the top of the show curve.
    private(set) var progress: CGFloat = 0
    let strip = RevealStripView(frame: .zero)
    let backing = RevealBackingView(frame: .zero)
    /// A mouse button is down (a drag in the page or a selection too): no reveal and no hide. A check replaces it.
    var buttonDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    private var pointerX: CGFloat?
    /// The page's answer for this visit to the strip (nil: not in yet); |visit| tells an answer from an earlier visit.
    private var editing: Bool?
    private var asked = false
    private var visit = 0
    private var wake: Timer?
    private var sliding: (start: TimeInterval, from: CGFloat, to: CGFloat, duration: TimeInterval, overshoot: Bool)?
    private var slideTimer: Timer?
    private var monitor: Any?
    private var menuOpen = false
    private var observers: [NSObjectProtocol] = []

    init(owner: BrowserWindowController) {
        self.owner = owner
        policy.strip = BarHook.on("REVEAL_WIDESTRIP") ? 20 : ChromeStyle.revealStrip   // the hook: the strip is wider than 6 pt
        policy.dwell = BarHook.on("REVEAL_NODWELL") ? 0 : ChromeStyle.revealDwell       // the hook: no dwell
        policy.hideDelay = BarHook.on("REVEAL_NOHIDEDELAY") ? 0 : ChromeStyle.revealHideDelay  // the hook: it hides at once
        policy.margin = BarHook.on("REVEAL_NOMARGIN") ? 0 : ChromeStyle.revealMargin     // the hook: no margin around the sidebar
        policy.sidebarWidth = ChromeStyle.sidebarWidth
        strip.onMove = { [weak self] x in self?.pointerMoved(toX: x) }
    }

    /// Called once the chrome is built: the monitor and the main menu's tracking (the context menus say so through `ContextMenus.tracking`).
    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let ns = self.owner.nsWindow, event.window === ns { self.pointerMoved(toX: self.owner.overlay.convert(event.locationInWindow, from: nil).x) }
            }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.menuOpen = true } })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false; self?.evaluate() }
        })
    }

    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        wake?.invalidate(); slideTimer?.invalidate()
    }

    /// The pointer is at |x| in window points (the strip's tracking area, the monitor, or a check).
    func pointerMoved(toX x: CGFloat) { pointerX = x; evaluate() }
    /// The pointer left the window.
    func pointerLeft() { pointerX = nil; evaluate() }

    private var held: Bool {
        (ContextMenus.tracking || menuOpen) && !BarHook.on("REVEAL_MENU")
            || owner.sidebar.drag != nil && !BarHook.on("REVEAL_DRAG")
            || buttonDown() && !BarHook.on("REVEAL_BUTTON")
            || owner.animation != nil   // the card is sliding (a toggle): nothing to reveal yet
    }

    private func evaluate() {
        wake?.invalidate(); wake = nil
        guard owner.installed, owner.sidebarHidden else { return }
        let x = pointerX.map(Double.init)
        let inStrip = x.map { $0 >= 0 && $0 < policy.strip } ?? false
        if !policy.revealed {
            if inStrip { askEditor() } else { editing = nil; asked = false; visit += 1 }
        }
        switch policy.update(now: ProcessInfo.processInfo.systemUptime, x: x, held: held, editing: editing == true && !BarHook.on("REVEAL_EDIT")) {
        case .reveal: show()
        case .hide:
            if !BarHook.on("REVEAL_NORESET") { editing = nil; asked = false; visit += 1 }  // the hook: the next visit reuses the last answer
            slide(to: 0)
        case .none: break
        }
        if let d = policy.deadline {
            let t = Timer(timeInterval: max(0.001, d - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            RunLoop.main.add(t, forMode: .common)
            wake = t
        }
    }

    /// Asks the page once per visit to the strip, so the answer is usually in before the dwell ends. An unknown (no answer in time, no page) never blocks, and an
    /// answer after the reveal began changes nothing.
    private func askEditor() {
        guard !asked, let tab = owner.activeTab else { return }
        asked = true
        let mine = visit
        Task { @MainActor in
            let answer = await owner.isEditingText(tab, within: ChromeStyle.revealAnswerWait)
            if mine == visit, !policy.revealed { editing = answer }
        }
    }

    private func show() {
        if !BarHook.on("REVEAL_NOLIGHTS") { owner.sidebar.setTrafficLightsHidden(false) }  // the hook: the lights stay hidden
        if BarHook.on("REVEAL_MOVECARD") { owner.cardX = ChromeStyle.sidebarWidth; owner.applyLayout() }  // the hook: the reveal pushes the card
        slide(to: 1)
    }

    private func slide(to: CGFloat) {
        sliding = (ProcessInfo.processInfo.systemUptime, progress, to, to > progress ? ChromeStyle.showDuration : ChromeStyle.hideDuration, to > progress)
        if slideTimer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
            RunLoop.main.add(t, forMode: .common)
            slideTimer = t
        }
        step()
    }

    private func step() {
        guard let s = sliding else { return }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - s.start) / s.duration)
        progress = t >= 1 ? s.to : s.from + (s.to - s.from) * ChromeStyle.eased(t, overshoot: s.overshoot)
        owner.placeSidebar()
        if t >= 1 {
            sliding = nil
            slideTimer?.invalidate(); slideTimer = nil
            if progress == 0, owner.sidebarHidden, owner.animation == nil { owner.sidebar.setTrafficLightsHidden(true) }
        }
    }

    /// The toggle (Cmd+S, the button, the menu) just flipped `sidebarHidden`. Shown: the reveal is over, but the sidebar stays where it is until the card has
    /// slid in (`toggleFinished`), so it never jumps. Hidden again before that: the reveal slides out with the card.
    func toggled() {
        wake?.invalidate(); wake = nil
        sliding = nil; slideTimer?.invalidate(); slideTimer = nil
        if owner.sidebarHidden {
            if progress > 0 { slide(to: 0) }
        } else {
            policy.end()
            editing = nil; asked = false; visit += 1
            if BarHook.on("REVEAL_JUMP") { progress = 0; owner.placeSidebar() }  // the hook: the sidebar goes back where the card is, then follows it
        }
    }

    /// The card has slid in: the sidebar is its own again.
    func toggleFinished() {
        guard progress != 0 else { return }
        progress = 0
        owner.placeSidebar()
    }
}

extension BrowserWindowController {
    /// Whether the active page has a text field focused (CDP: the focused element through open shadow roots and same-origin frames is an input, a textarea, a select
    /// or editable). Nil when no answer came in |wait| (no page, a timeout, an error). A text field inside a cross-process frame is not seen (README known limit).
    func isEditingText(_ tab: NCTab, within wait: TimeInterval) async -> Bool? {
        let js = """
        (function () { var a = document.activeElement;
          for (var i = 0; i < 20 && a; i++) {
            if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue }
            if (a.tagName === 'IFRAME' || a.tagName === 'FRAME') { try { var d = a.contentDocument; if (d && d.activeElement) { a = d.activeElement; continue } } catch (e) {} }
            break }
          if (!a) return false;
          return a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable === true })()
        """
        let r = await cdp(tab, "Runtime.evaluate", ["expression": js, "returnByValue": true, "userGesture": false], until: Date().addingTimeInterval(wait))
        guard r.result?["exceptionDetails"] == nil, let v = (r.result?["result"] as? [String: Any])?["value"] as? Bool else { return nil }
        return v
    }

    /// The sidebar's place (and its panel's) for the card and the reveal as they are now.
    func placeSidebar() {
        let layout = ChromeLayout(size: overlay.bounds.size, cardX: cardX, reveal: reveal.progress)
        sidebar.frame = layout.sidebar
        reveal.backing.frame = CGRect(x: layout.sidebar.minX - ChromeStyle.cardRadius, y: ChromeStyle.inset, width: ChromeStyle.sidebarWidth + ChromeStyle.cardRadius, height: max(0, layout.size.height - 2 * ChromeStyle.inset))
        reveal.backing.isHidden = reveal.progress <= 0
    }
}
