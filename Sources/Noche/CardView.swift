import AppKit

/// The rounded card behind the page: fill and 1 pt border (live-ui.md section 2). Below the Views content view.
final class CardView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.cardRadius, yRadius: ChromeStyle.cardRadius)
        ChromeStyle.cardFill.setFill()
        path.fill()
        ChromeStyle.cardBorder.setStroke()
        path.stroke()
    }
}

/// Everything below the Views content view: window-wide vibrancy (rounded to the window) and the card.
final class BackdropView: NSView {
    override var isFlipped: Bool { true }
    let vibrancy = NSVisualEffectView()
    let card = CardView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        let r = ChromeStyle.windowRadius
        let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        vibrancy.maskImage = mask
        vibrancy.frame = bounds
        vibrancy.autoresizingMask = [.width, .height]
        card.setAccessibilityIdentifier("card")
        addSubview(vibrancy)
        addSubview(card)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Above the Views content view: sidebar, toolbar and the window border. Clicks fall through wherever nothing is drawn.
final class ChromeOverlayView: NSView {
    override var isFlipped: Bool { true }
    var onResize: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

/// The 1 pt window border (live-ui.md section 2), drawn over everything.
final class WindowBorderView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.windowBorder.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.windowRadius, yRadius: ChromeStyle.windowRadius).stroke()
    }
}

/// A view that drags the window from its empty area (the window has no title bar).
class DragView: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
