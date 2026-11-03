#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import NocheCore

/// The hover reveal (M1.6 Task 8). A hidden window gets no tracking-area events and is never key (G5), so the pointer is moved through `pointerMoved(toX:)`, the one
/// entry the strip's tracking area and the monitor also call; what the real pointer does over the page view is an owner check.
extension SelfTest {
    /// Spec 5.2 "hover reveal" and T8.2: with the sidebar hidden, a click at x 3 is not taken by the strip; the pointer resting in the strip for 150 ms slides the sidebar to
    /// x 0 within 150 + 130 + 50 ms while the card stays at 6; it is gone 400 + 150 ms after the pointer left the sidebar widened by 8 pt; no reveal with a context menu
    /// open, during a sidebar drag, with a text field focused in the page, with a button down or in the first 150 ms; Cmd+S while revealed makes it permanent with no jump.
    func hoverReveal() async {
        guard await ready(), let ctl, let host = ctl.window.chromeHost, let tab = ctl.activeTab, let first = ctl.list.items.first?.id else { return }
        var bad: [String] = []
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func x() -> CGFloat { ctl.sidebar.frame.minX }
        func away() -> Bool { abs(x() + 197) < 0.01 }
        func onScreen() -> Bool { abs(x()) < 0.01 }
        func lightsShown() -> Bool { !ctl.sidebar.lights.contains { $0.isHidden } }
        func expect(_ ok: Bool, _ what: String) { if !ok { bad.append(what) } }
        func settle() async { ctl.reveal.pointerMoved(toX: 600); _ = await until(3, { away() && ctl.reveal.progress == 0 }) }

        ctl.reveal.buttonDown = { false }  // the real mouse is the owner's: a button held in any app would hold the reveal back
        cmdS()
        guard await until(3, { ctl.sidebarHidden && ctl.animation == nil && ctl.toggleEnd > 0 }) else { return finish(false, "Cmd+S did not hide the sidebar") }
        expect(away() && ctl.cardX == 6 && ctl.reveal.progress == 0, "hidden: sidebar at \(x()), card at \(ctl.cardX), progress \(ctl.reveal.progress)")

        // T8.2: the strip is hit-test transparent, so a click at x 3 reaches what is under it (the page's own view starts at the card).
        let hit = host.hitTest(host.convert(NSPoint(x: 3, y: 500), from: nil))
        expect(hit.map { $0 !== ctl.overlay && !$0.isDescendant(of: ctl.overlay) } ?? true, "a click at x 3 was taken by \(hit.map { String(describing: type(of: $0)) } ?? "nil") of the overlay")

        // The dwell, the slide, the card. cardLog gets a frame whenever the card moves: the reveal adds none that is not at 6.
        let log = ctl.cardLog.count
        ctl.reveal.pointerMoved(toX: 3)
        await wait(100)
        expect(away(), "100 ms in the strip: the sidebar is already at \(x())")
        await wait(230)
        expect(onScreen(), "330 ms after entering the strip the sidebar is at \(x()), want 0")
        expect(ctl.cardX == 6 && ctl.cardLog[log...].allSatisfy { $0.x == 6 } && ctl.frame(ofIdentifier: "card")?.minX == 6, "the card moved: cardX \(ctl.cardX), frames \(ctl.cardLog[log...].map(\.x))")
        expect(lightsShown() && !ctl.sidebar.isHidden && ctl.sidebar.frame.intersects(ctl.overlay.bounds), "revealed without its traffic lights or off screen (lights shown \(lightsShown()))")

        // Away: the margin is 8 pt (x 203 is on the sidebar), then 400 ms and the 125 ms hide.
        ctl.reveal.pointerMoved(toX: 203)
        await wait(600)
        expect(onScreen(), "the pointer 6 pt off the sidebar's edge for 600 ms: the sidebar is at \(x())")
        ctl.reveal.pointerMoved(toX: 300)
        await wait(250)
        expect(onScreen(), "250 ms after leaving the sidebar it is at \(x()), want it still on screen (the delay is 400 ms)")
        await wait(300)
        expect(away() && ctl.sidebar.lights.allSatisfy(\.isHidden), "550 ms after leaving the sidebar it is at \(x()), lights hidden \(ctl.sidebar.lights.allSatisfy(\.isHidden))")

        // Only the strip: x 10 reveals nothing.
        ctl.reveal.pointerMoved(toX: 10)
        await wait(400)
        expect(away(), "the pointer at x 10 for 400 ms: the sidebar is at \(x())")
        await settle()

        // Guards: each is on while the pointer rests in the strip for 400 ms, then off.
        func guarded(_ name: String, on: () async -> Void, off: () async -> Void) async {
            await on()
            ctl.reveal.pointerMoved(toX: 3)
            await wait(400)
            expect(away(), "\(name): the sidebar is at \(x()), want it hidden")
            await settle()
            await off()
        }
        await guarded("context menu", on: {
            ctl.showSidebarMenu(at: NSPoint(x: 300, y: 300))
            if !ContextMenus.tracking { bad.append("context menu: no menu is open") }
        }, off: { ContextMenus.dismiss(choosing: nil) })
        await guarded("sidebar drag", on: { ctl.sidebar.dragBegan(.tab(first)) }, off: { ctl.sidebar.dragEnded(dropped: false) })
        await guarded("button down", on: { ctl.reveal.buttonDown = { true } }, off: { ctl.reveal.buttonDown = { false } })
        await guarded("text field", on: {
            let focused = await evaluate(tab, "document.body.innerHTML = '<input id=\"i\">'; document.getElementById('i').focus(); document.activeElement.id")
            if focused?.contains("i") != true { bad.append("text field: the input did not take focus (\(focused ?? "nil"))") }
        }, off: { _ = await evaluate(tab, "document.activeElement.blur(); 1") })
        expect(!ContextMenus.tracking && ctl.sidebar.drag == nil, "a guard was left on")

        // Everything off again: the reveal works, and Cmd+S while revealed makes it permanent: the card slides in and the sidebar never moves left.
        ctl.reveal.pointerMoved(toX: 3)
        await wait(330)
        expect(onScreen(), "after the guards: the sidebar is at \(x()), want 0")
        var left = x()
        cmdS()
        left = min(left, x())
        let end = Date().addingTimeInterval(2)
        while ctl.toggleEnd == 0 && Date() < end { await wait(2); left = min(left, x()) }
        expect(left > -0.01, "Cmd+S while revealed: the sidebar jumped to \(left)")
        expect(!ctl.sidebarHidden && ctl.cardX == 197 && onScreen() && ctl.reveal.progress == 0 && !ctl.reveal.policy.revealed && lightsShown() && ctl.reveal.backing.isHidden,
               "Cmd+S while revealed ended with hidden \(ctl.sidebarHidden), card \(ctl.cardX), sidebar \(x()), progress \(ctl.reveal.progress), revealed \(ctl.reveal.policy.revealed)")
        expect(BrowserWindowController.actionCounts["toggleSidebar"] == 2, "the reveal toggled the sidebar: \(BrowserWindowController.actionCounts)")
        finish(bad.isEmpty && violations.isEmpty, "click at x 3 reaches the page, 150 ms dwell then x 0 by 330 ms with the card at 6 and the lights shown, hidden 550 ms after leaving the margin, no reveal with a menu, a drag, a button or a text field, Cmd+S makes it permanent \(bad) \(violations)")
    }
}
#endif
