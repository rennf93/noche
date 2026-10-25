import AppKit

/// The zoom indicator (M1.4): the page's zoom as a percent, in the toolbar, shown only when it is not 100 percent. A click resets to 100 percent.
/// Chromium's own zoom bubble is off in the engine (patch 0007).
final class ZoomPillView: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }
    /// The zoom factor in percent, as Chromium derives it from the level (`blink::ZoomLevelToZoomFactor`: 1.2 raised to the level).
    var percent = 100 {
        didSet { setAccessibilityValue("\(percent)%"); needsDisplay = true }
    }

    static func percent(forLevel level: Double) -> Int { Int((pow(1.2, level) * 100).rounded()) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: ChromeStyle.zoomWidth, height: ChromeStyle.zoomHeight))
        setAccessibilityIdentifier("toolbar.zoom")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Zoom")
        setAccessibilityValue("100%")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isHovered ? ChromeStyle.barRowSelected : ChromeStyle.barFill).setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: ChromeStyle.barRowFont, .foregroundColor: ChromeStyle.barTitle]
        let text = "\(percent)%" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}  // the toolbar behind it drags the window: this pill takes the press
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
