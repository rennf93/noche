#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Synthesized input for the checks: key equivalents routed like NSApplication does, typed text, mouse clicks.
extension SelfTest {
    /// A key equivalent the way NSApplication routes it: the window first, then the main menu.
    @discardableResult
    func key(_ ch: String, code: UInt16, _ mods: NSEvent.ModifierFlags = .command, chars: String? = nil) -> Bool {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ns.windowNumber, context: nil,
              characters: chars ?? ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return false }
        let byWindow = ns.performKeyEquivalent(with: ev)
        let byMenu = byWindow ? false : (NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false)
        keyLog.append("\(ch)\(mods.contains(.shift) ? "+shift" : ""):window=\(byWindow),menu=\(byMenu) menuClass=\(NSApp.mainMenu.map { String(describing: type(of: $0)) } ?? "nil") ig=\(ev.charactersIgnoringModifiers ?? "nil") chars=\(ev.characters ?? "nil") mods=\(ev.modifierFlags.rawValue)")
        return byWindow || byMenu
    }
    func cmdT() { key("t", code: 17) }
    func cmdW() { key("w", code: 13) }
    // Shifted punctuation: the shifted character, and the plain one ignoring modifiers (the matcher accepts either).
    func nextTab() { shortcut("Next Tab") }
    func previousTab() { shortcut("Previous Tab") }
    /// The key of the menu item as the live menu reports it (AppKit remaps "[" and "]" to the layout's keys).
    func shortcut(_ title: String) {
        func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items { if i.title == title, !i.keyEquivalent.isEmpty { return i }; if let s = i.submenu, let f = find(s) { return f } }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap(find) else { keyLog.append("no menu item \(title)"); return }
        key(item.keyEquivalent, code: 0, item.keyEquivalentModifierMask)
    }
    func cmdL() { key("l", code: 37) }
    func cmdS() { key("s", code: 1) }

    /// Typed text goes to the first responder as key events.
    func typeText(_ text: String) {
        guard let ns = ctl?.nsWindow else { return }
        for ch in text {
            let s = String(ch)
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: ns.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                         isARepeat: false, keyCode: 0) { ns.firstResponder?.keyDown(with: ev) }
        }
    }
    func pressReturn() {
        guard let ns = ctl?.nsWindow, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: ns.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                              isARepeat: false, keyCode: 36) else { return }
        ns.firstResponder?.keyDown(with: ev)
    }

    /// A left click (or a middle click) at the middle of |v|: found by hit testing the window's frame view, the way the window
    /// would, then delivered to the view that was hit. False when |v| is not what is under that point (clipped, covered).
    @discardableResult
    func click(_ v: NSView, middle: Bool = false) -> Bool {
        guard let ns = ctl?.nsWindow, let host = ctl?.window.chromeHost else { return false }
        let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        guard let hit = host.hitTest(host.convert(p, from: nil)), hit === v || hit.isDescendant(of: v) else { return false }
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: ns.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if middle {
            if let up = ev(.otherMouseUp) { hit.otherMouseUp(with: up) }
        } else {
            if let down = ev(.leftMouseDown) { hit.mouseDown(with: down) }
            if let up = ev(.leftMouseUp) { hit.mouseUp(with: up) }
        }
        return true
    }

    func findView(ofClass name: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if NSStringFromClass(type(of: view)) == name { return view }
        for s in view.subviews { if let v = findView(ofClass: name, in: s) { return v } }
        return nil
    }
}
#endif
