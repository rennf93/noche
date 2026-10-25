import AppKit
import NocheCore

/// What one row shows: a suggestion, or one of the New Tab card's inert starter rows.
struct BarRow: Equatable {
    var kind: String
    var title: String
    var url: String
    var symbol: String
    var hint: String?

    static func suggestion(_ s: Suggestion) -> BarRow {
        let symbol: String
        switch s.kind {
        case .query, .remoteQuery: symbol = "magnifyingglass"
        case .tab: symbol = "macwindow"
        case .page, .site, .goTo: symbol = "globe"
        }
        return BarRow(kind: String(describing: s.kind), title: s.title, url: s.url ?? "", symbol: symbol, hint: s.tabID != nil ? "Switch to Tab" : nil)
    }
    static func starter(_ symbol: String, _ text: String) -> BarRow { BarRow(kind: "starter", title: text, url: "", symbol: symbol, hint: nil) }
}

/// One 36 pt row (note section 1a): icon at card+22, text at card+44, "Title" white then " - host" gray, a hint pill for rows that
/// switch to an open tab. It acts on mouse-up inside, with no tracking loop, so synthesized events can drive it.
final class SuggestionRowView: NSView {
    override var isFlipped: Bool { true }
    var content = BarRow(kind: "", title: "", url: "", symbol: "globe", hint: nil) { didSet { needsDisplay = true; syncAccessibility() } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func syncAccessibility() {
        setAccessibilityLabel(content.title)
        setAccessibilityValue("\(content.kind)|\(content.title)|\(content.url)")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            ChromeStyle.barRowSelected.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: ChromeStyle.barRowRadius, yRadius: ChromeStyle.barRowRadius).fill()
        }
        if let icon = ChromeStyle.symbol(content.symbol, size: 13, color: ChromeStyle.barPlaceholder) {
            icon.draw(in: NSRect(x: 14, y: (bounds.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        }
        var textRight = bounds.width - 16
        if let hint = content.hint {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ChromeStyle.barHost]
            let size = (hint as NSString).size(withAttributes: attrs)
            let pill = NSRect(x: bounds.width - 12 - size.width - 16, y: (bounds.height - 20) / 2, width: size.width + 16, height: 20)
            ChromeStyle.barHintFill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
            (hint as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + (20 - size.height) / 2), withAttributes: attrs)
            textRight = pill.minX - 8
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: content.title, attributes: [.font: ChromeStyle.barRowFont, .foregroundColor: ChromeStyle.barTitle, .paragraphStyle: style])
        if content.kind == "page" || content.kind == "tab" || content.kind == "site", let r = content.title.range(of: " - ", options: .backwards) {
            let from = content.title.distance(from: content.title.startIndex, to: r.lowerBound)
            text.addAttribute(.foregroundColor, value: ChromeStyle.barHost, range: NSRange(location: from, length: (content.title as NSString).length - from))
        }
        let h = text.size().height
        text.draw(in: NSRect(x: 36, y: (bounds.height - h) / 2, width: max(0, textRight - 36), height: h))
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
