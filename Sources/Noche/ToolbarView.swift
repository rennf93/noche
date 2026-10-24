import AppKit

/// A 32x32 toolbar button (live-ui.md section 2). It acts on mouse-up inside, with no tracking loop, so synthesized
/// events can drive it.
final class ChromeButton: NSView {
    override var isFlipped: Bool { true }
    let symbol: String
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, identifier: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: ChromeStyle.buttonSize, height: ChromeStyle.buttonSize))
        setAccessibilityIdentifier(identifier)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            ChromeStyle.buttonHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: ChromeStyle.buttonRadius, yRadius: ChromeStyle.buttonRadius).fill()
        }
        let image = ChromeStyle.symbol(symbol, size: 16, color: isEnabled ? ChromeStyle.iconColor : ChromeStyle.iconDisabled)
        if let image {
            image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Toolbar above the page: sidebar toggle, back, forward, reload, the address text and the divider. It is transparent;
/// the card behind it supplies the #1f1f1f.
final class ToolbarView: DragView {
    let toggle = ChromeButton(symbol: "sidebar.left", identifier: "toolbar.sidebarToggle")
    let back = ChromeButton(symbol: "chevron.left", identifier: "toolbar.back")
    let forward = ChromeButton(symbol: "chevron.right", identifier: "toolbar.forward")
    let reload = ChromeButton(symbol: "arrow.clockwise", identifier: "toolbar.reload")
    let address = NSTextField()
    let divider = DividerView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("toolbar")
        for (i, b) in [toggle, back, forward, reload].enumerated() {
            // y is relative to the toolbar, which starts at the card top (6)
            b.frame.origin = NSPoint(x: ChromeStyle.buttonInset + ChromeStyle.buttonPitch * CGFloat(i), y: ChromeStyle.buttonY - ChromeStyle.inset)
            addSubview(b)
        }
        address.isEditable = true
        address.isBezeled = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.font = ChromeStyle.font
        address.textColor = ChromeStyle.addressColor
        address.cell?.lineBreakMode = .byClipping
        address.cell?.isScrollable = true
        address.maximumNumberOfLines = 1
        address.placeholderString = ""
        address.setAccessibilityIdentifier("toolbar.address")
        addSubview(address)
        divider.setAccessibilityIdentifier("toolbar.divider")
        addSubview(divider)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        address.frame = NSRect(x: ChromeStyle.addressInset, y: ChromeStyle.addressY - ChromeStyle.inset,
                               width: max(0, bounds.width - ChromeStyle.addressInset - 12), height: ChromeStyle.addressHeight)
        divider.frame = NSRect(x: 0, y: ChromeStyle.dividerY - ChromeStyle.inset, width: bounds.width, height: 1)
    }
}

final class DividerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.dividerColor.setFill()
        bounds.fill()
    }
}
