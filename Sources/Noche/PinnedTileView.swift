import AppKit
import NocheCore

/// One tile of the pinned grid (note 1.2): a 41 pt rounded square with the favicon in the middle. Dormant tiles draw the favicon at 0.45.
final class PinnedTileView: NSView {
    override var isFlipped: Bool { true }
    let faviconView = NSImageView()
    var tabID: TabID?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?   // the click in window coordinates
    var onReset: (() -> Void)?                // the return glyph was clicked: back to the pinned page
    private(set) var showsPlaceholder = true
    /// The tab is not on its pinned page (|url| differs from |pinnedURL|): hovering the tile shows the return glyph.
    private(set) var canReset = false
    var showsResetGlyph: Bool { canReset && isHovered }
    /// Where the glyph sits, top right of the tile.
    var resetGlyphRect: NSRect {
        let s = ChromeStyle.resetGlyphSize
        return NSRect(x: bounds.maxX - s - ChromeStyle.resetGlyphInset, y: ChromeStyle.resetGlyphInset, width: s, height: s)
    }
    private var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isLoading = false { didSet { if isLoading != oldValue { needsDisplay = true } } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        faviconView.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addSubview(faviconView)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let s = ChromeStyle.tileFaviconSize
        faviconView.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    }

    /// A view taken from the pool is not under the pointer until AppKit says so.
    func clearHover() { isHovered = false }
    /// The pointer entering or leaving (the checks call it: a hidden window gets no tracking events).
    func hover(_ on: Bool) { isHovered = on }

    private static let placeholder = ChromeStyle.symbol("globe", size: 14, color: ChromeStyle.newTabColor)

    func configure(title: String, favicon: NSImage?, selected: Bool, dormant: Bool, loading: Bool, canReset: Bool = false) {
        if canReset != self.canReset { self.canReset = canReset }
        showsPlaceholder = favicon == nil
        faviconView.image = favicon ?? Self.placeholder
        faviconView.alphaValue = dormant ? ChromeStyle.dormantAlpha : 1
        isSelected = selected
        isLoading = loading
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.tileRadius, yRadius: ChromeStyle.tileRadius)
        (isHovered ? ChromeStyle.tileHoverFill : ChromeStyle.tileFill).setFill()
        path.fill()
        ChromeStyle.tileBorder.setStroke()
        path.stroke()
        if isSelected {
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: ChromeStyle.tileRadius, yRadius: ChromeStyle.tileRadius)
            inner.lineWidth = ChromeStyle.tileSelectedWidth
            ChromeStyle.tileSelectedStroke.setStroke()
            inner.stroke()
        }
        if showsResetGlyph, let g = ChromeStyle.symbol("arrow.uturn.backward", size: ChromeStyle.resetGlyphSize - 2, color: ChromeStyle.resetGlyphColor) {
            g.draw(in: resetGlyphRect)
        }
        if isLoading {
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: ChromeStyle.tileFaviconSize / 2 + ChromeStyle.tileLoadingGap, startAngle: -90, endAngle: 90)
            arc.lineWidth = ChromeStyle.tileLoadingWidth
            ChromeStyle.tileSelectedStroke.setStroke()
            arc.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event.locationInWindow); return }  // Control-click is a right click
        if showsResetGlyph, resetGlyphRect.contains(convert(event.locationInWindow, from: nil)) { onReset?(); return }
        onSelect?()
    }
    override func otherMouseUp(with event: NSEvent) { onClose?() }  // middle click
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event.locationInWindow) }
}
