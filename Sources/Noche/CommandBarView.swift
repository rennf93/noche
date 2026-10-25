import AppKit
import NocheCore

/// The input's cell: the line sits in the middle of the box, the field editor gets a white caret and the #787d86b2 selection (the inline remainder).
final class CommandBarFieldCell: CenteredTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let tv = editor as? NSTextView {
            tv.insertionPointColor = .white
            tv.selectedTextAttributes = [.backgroundColor: ChromeStyle.barSelectedText]
            tv.drawsBackground = false
            // An address bar is not prose: no smart quotes or dashes, no spelling, replacement, completion or writing-tools popups.
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isAutomaticLinkDetectionEnabled = false
            tv.isAutomaticDataDetectionEnabled = false
            tv.isAutomaticTextCompletionEnabled = false
            tv.isContinuousSpellCheckingEnabled = false
            tv.isGrammarCheckingEnabled = false
            if #available(macOS 15, *) { tv.writingToolsBehavior = .none }
        }
        return editor
    }
}

/// A button drawn by hand that acts on mouse-up inside (no tracking loop).
class BarButton: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    init(identifier: String, label: String) {
        super.init(frame: .zero)
        setAccessibilityIdentifier(identifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// "Add tabs or files": inert until M2 (no AI in M1.3).
final class ChipButton: BarButton {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        ChromeStyle.barBorder.setStroke()
        path.stroke()
        if let plus = ChromeStyle.symbol("plus", size: 11, color: ChromeStyle.barChipText) {
            plus.draw(in: NSRect(x: 12, y: (bounds.height - plus.size.height) / 2, width: plus.size.width, height: plus.size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ChromeStyle.barChipText]
        let size = ("Add tabs or files" as NSString).size(withAttributes: attrs)
        ("Add tabs or files" as NSString).draw(at: NSPoint(x: 30, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

final class MicButton: BarButton {
    override func draw(_ dirtyRect: NSRect) {
        if let mic = ChromeStyle.symbol("mic", size: 15, color: ChromeStyle.barMic) {
            mic.draw(in: NSRect(x: (bounds.width - mic.size.width) / 2, y: (bounds.height - mic.size.height) / 2, width: mic.size.width, height: mic.size.height))
        }
    }
}

/// The send circle while there are no rows to run, the "Go" pill with a return glyph once there are.
final class GoButton: BarButton {
    var isPill = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if isPill {
            ChromeStyle.barGoFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 17, yRadius: 17).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ChromeStyle.barGoText]
            let size = ("Go" as NSString).size(withAttributes: attrs)
            let glyph = ChromeStyle.symbol("return", size: 12, color: ChromeStyle.barGoText)
            let total = size.width + 6 + (glyph?.size.width ?? 0)
            let x = (bounds.width - total) / 2
            ("Go" as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            glyph?.draw(in: NSRect(x: x + size.width + 6, y: (bounds.height - glyph!.size.height) / 2, width: glyph!.size.width, height: glyph!.size.height))
        } else {
            ChromeStyle.barSendFill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            if let arrow = ChromeStyle.symbol("arrow.up", size: 14, color: ChromeStyle.barMic) {
                arrow.draw(in: NSRect(x: (bounds.width - arrow.size.width) / 2, y: (bounds.height - arrow.size.height) / 2, width: arrow.size.width, height: arrow.size.height))
            }
        }
    }
}

/// The bar itself: card, input row, up to 6 rows, footer. All geometry arrives as CommandBarFrames (window points); this view draws and forwards.
final class CommandBarView: NSView {
    override var isFlipped: Bool { true }
    let field = NSTextField()
    let iconView = NSImageView()
    let chip = ChipButton(identifier: "commandBar.chip", label: "Add tabs or files")
    let mic = MicButton(identifier: "commandBar.mic", label: "Voice input")
    let go = GoButton(identifier: "commandBar.go", label: "Go")
    private(set) var rowViews: [SuggestionRowView] = []
    var squareTop = false { didSet { needsDisplay = true } }
    var onRowClick: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityIdentifier("commandBar")
        let cell = CommandBarFieldCell(textCell: "")
        cell.isEditable = true
        cell.isScrollable = true
        cell.lineBreakMode = .byClipping
        field.cell = cell
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.maximumNumberOfLines = 1
        field.placeholderAttributedString = NSAttributedString(string: "Ask anything...", attributes: [.foregroundColor: ChromeStyle.barPlaceholder, .font: ChromeStyle.barInputFontNewTab])
        field.setAccessibilityIdentifier("commandBar.input")
        field.setAccessibilityLabel("Address or search")
        iconView.imageScaling = .scaleNone
        for v in [iconView, field, chip, mic, go] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var r = bounds.insetBy(dx: 0.5, dy: 0.5)
        // On a loaded page the top edge is the window's: its corners are square, the border is not drawn there.
        if squareTop { r.origin.y -= 20; r.size.height += 20 }
        let path = NSBezierPath(roundedRect: r, xRadius: ChromeStyle.barRadius, yRadius: ChromeStyle.barRadius)
        ChromeStyle.barFill.setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
    }

    func setIcon(_ symbol: String) {
        iconView.image = ChromeStyle.symbol(symbol, size: 13, color: ChromeStyle.barPlaceholder)
    }

    /// Frames come in window coordinates; the bar's own origin is the card's top-left. |height| clips the card while it grows open.
    func apply(_ f: CommandBarFrames, height: CGFloat, newTab: Bool, pill: Bool) {
        let o = f.card.origin
        func local(_ r: CGRect) -> NSRect { NSRect(x: r.minX - o.x, y: r.minY - o.y, width: r.width, height: r.height) }
        frame = NSRect(x: f.card.minX, y: f.card.minY, width: f.card.width, height: height)
        field.frame = local(f.input)
        field.font = newTab ? ChromeStyle.barInputFontNewTab : ChromeStyle.barInputFontOverlay
        iconView.frame = NSRect(x: 20, y: field.frame.midY - 8, width: 20, height: 16)
        chip.frame = local(f.chip)
        go.frame = local(pill ? f.go : f.send)
        go.isPill = pill
        mic.frame = local(pill ? f.micWithGo : f.mic)
        for (i, v) in rowViews.enumerated() { if i < f.rows.count { v.frame = local(f.rows[i]) } }
        needsDisplay = true
    }

    func setRows(_ rows: [BarRow], selected: Int?) {
        while rowViews.count < rows.count {
            let v = SuggestionRowView(frame: .zero)
            let i = rowViews.count
            v.setAccessibilityIdentifier("commandBar.row.\(i)")
            v.onClick = { [weak self] in self?.onRowClick?(i) }
            rowViews.append(v)
            addSubview(v)
        }
        while rowViews.count > rows.count { rowViews.removeLast().removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            rowViews[i].content = r
            rowViews[i].isSelected = i == selected
        }
    }
}
