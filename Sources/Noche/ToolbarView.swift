import AppKit

/// A 32x32 toolbar button (live-ui.md section 2). It acts on mouse-up inside, with no tracking loop, so synthesized
/// events can drive it.
final class ChromeButton: NSView {
    override var isFlipped: Bool { true }
    let symbol: String
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true; setAccessibilityEnabled(isEnabled) } }
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, identifier: String, label: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: ChromeStyle.buttonSize, height: ChromeStyle.buttonSize))
        setAccessibilityIdentifier(identifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
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
    let toggle = ChromeButton(symbol: "sidebar.left", identifier: "toolbar.sidebarToggle", label: "Toggle Sidebar")
    let back = ChromeButton(symbol: "chevron.left", identifier: "toolbar.back", label: "Back")
    let forward = ChromeButton(symbol: "chevron.right", identifier: "toolbar.forward", label: "Forward")
    let reload = ChromeButton(symbol: "arrow.clockwise", identifier: "toolbar.reload", label: "Reload")
    let address: AddressLabel = {
        let field = AddressLabel()
        field.cell = CenteredTextFieldCell(textCell: "")
        return field
    }()
    let divider = DividerView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("toolbar")
        for (i, b) in [toggle, back, forward, reload].enumerated() {
            // y is relative to the toolbar, which starts at the card top (6)
            b.frame.origin = NSPoint(x: ChromeStyle.buttonInset + ChromeStyle.buttonPitch * CGFloat(i), y: ChromeStyle.buttonY - ChromeStyle.inset)
            addSubview(b)
        }
        address.isEditable = false  // the command bar edits the address (M1.3); a click here opens it
        address.isSelectable = false
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
        address.setAccessibilityLabel("Address")
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

/// The toolbar's address text: display only. A click opens the command bar.
final class AddressLabel: NSTextField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class DividerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.dividerColor.setFill()
        bounds.fill()
    }
}

/// A text cell whose line sits in the vertical middle of its box (also while editing).
class CenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        var r = rect
        let h = cellSize(forBounds: rect).height
        r.origin.y += (rect.height - h) / 2
        r.size.height = h
        return r
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect { centered(super.titleRect(forBounds: rect)) }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) { super.drawInterior(withFrame: centered(cellFrame), in: controlView) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
