import AppKit

/// The find pill (M1.4): field, "n of m" count, previous, next and close, drawn by Noche at the card's top right. Chromium's own find bar never shows.
/// Buttons act on mouse-up inside, like every chrome button.
final class FindBarView: NSView {
    override var isFlipped: Bool { true }
    let field = NSTextField()
    let count = NSTextField(labelWithString: "")
    let previous = ChromeButton(symbol: "chevron.up", identifier: "find.previous", label: "Previous Match")
    let next = ChromeButton(symbol: "chevron.down", identifier: "find.next", label: "Next Match")
    let close = ChromeButton(symbol: "xmark", identifier: "find.close", label: "Close Find")

    /// "3 of 5", "0 of 0" for a search with no match, "" before anything was typed.
    var countText = "" {
        didSet { count.stringValue = countText; count.setAccessibilityValue(countText) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("find.bar")
        let cell = CommandBarFieldCell(textCell: "")
        cell.isEditable = true
        cell.isScrollable = true
        cell.lineBreakMode = .byClipping
        field.cell = cell
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = ChromeStyle.barTitle
        field.font = ChromeStyle.barRowFont
        field.maximumNumberOfLines = 1
        field.placeholderAttributedString = NSAttributedString(string: "Find in page", attributes: [.foregroundColor: ChromeStyle.barPlaceholder, .font: ChromeStyle.barRowFont])
        field.setAccessibilityIdentifier("find.field")
        field.setAccessibilityLabel("Find in page")
        count.font = ChromeStyle.barRowFont
        count.textColor = ChromeStyle.barHost
        count.alignment = .right
        count.setAccessibilityIdentifier("find.count")
        count.setAccessibilityLabel("Match count")
        for v in [field, count, previous, next, close] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The buttons and the count keep their size at the right; the field takes what is left (126 pt at the full 308 pt width).
    override func layout() {
        super.layout()
        let w = bounds.width
        for (i, b) in [previous, next, close].enumerated() { b.frame.origin = NSPoint(x: w - 104 + 34 * CGFloat(i), y: 2) }
        count.frame = NSRect(x: w - 166, y: 9, width: 58, height: 18)
        field.frame = NSRect(x: 14, y: 8, width: max(0, w - 182), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        ChromeStyle.barFill.setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
    }
}
