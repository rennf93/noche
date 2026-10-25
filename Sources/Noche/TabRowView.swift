import AppKit

/// One tab row (live-ui.md section 3): favicon, title that fades out instead of an ellipsis, hover and selected fills.
final class TabRowView: NSView {
    override var isFlipped: Bool { true }
    let faviconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    private(set) var showsPlaceholder = true
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?   // the click in window coordinates
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    let fade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        faviconView.wantsLayer = true
        faviconView.layer?.cornerRadius = 4
        faviconView.layer?.masksToBounds = true
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = ChromeStyle.font
        titleField.textColor = ChromeStyle.titleColor
        titleField.alignment = .left
        titleField.cell?.lineBreakMode = .byClipping  // never an ellipsis
        titleField.cell?.truncatesLastVisibleLine = false
        titleField.maximumNumberOfLines = 1
        titleField.usesSingleLineMode = true
        titleField.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        titleField.layer?.mask = fade
        setAccessibilityElement(true)  // one button per tab: the title is its label, the selection its state
        setAccessibilityRole(.button)
        faviconView.setAccessibilityElement(false)
        titleField.setAccessibilityElement(false)
        addSubview(faviconView)
        addSubview(titleField)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Child frames are window points: the row sits at x 6, so favicon x 14 and title x 37 are 8 and 31 inside it.
    override func layout() {
        super.layout()
        let y: CGFloat = 10
        faviconView.frame = NSRect(x: ChromeStyle.faviconX - ChromeStyle.rowX, y: y, width: ChromeStyle.faviconSize, height: ChromeStyle.faviconSize)
        let tx = ChromeStyle.titleX - ChromeStyle.rowX
        titleField.frame = NSRect(x: tx, y: y, width: bounds.width - tx, height: 18)
        fade.frame = titleField.bounds
        let w = max(titleField.bounds.width, 1)
        fade.locations = [0, NSNumber(value: Double(max(0, w - ChromeStyle.titleFade) / w)), 1]
    }

    func configure(title: String, favicon: NSImage?, selected: Bool) {
        titleField.stringValue = title
        showsPlaceholder = favicon == nil
        faviconView.image = favicon ?? ChromeStyle.symbol("globe", size: 14, color: ChromeStyle.newTabColor)
        isSelected = selected
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.rowRadius, yRadius: ChromeStyle.rowRadius)
        if isSelected {
            ChromeStyle.rowSelectedFill.setFill()
            path.fill()
            ChromeStyle.rowSelectedBorder.setStroke()
            path.stroke()
        } else if isHovered {
            ChromeStyle.rowHover.setFill()
            path.fill()
        }
    }

    /// The row takes every click inside it, whatever subview is under the point.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseUp(with event: NSEvent) { onClose?() }  // middle click
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event.locationInWindow) }
}

/// The "New Tab" row below the (future) pinned grid.
final class NewTabRowView: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            ChromeStyle.rowHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: ChromeStyle.rowRadius, yRadius: ChromeStyle.rowRadius).fill()
        }
        let icon = ChromeStyle.symbol("plus", size: 14, color: ChromeStyle.newTabColor)
        let ix = ChromeStyle.faviconX - ChromeStyle.rowX
        icon?.draw(in: NSRect(x: ix, y: (bounds.height - 14) / 2, width: 14, height: 14))
        let text = NSAttributedString(string: "New Tab", attributes: [.font: ChromeStyle.font, .foregroundColor: ChromeStyle.newTabColor])
        let tx = ChromeStyle.titleX - ChromeStyle.rowX
        text.draw(at: NSPoint(x: tx, y: (bounds.height - text.size().height) / 2))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
