import AppKit

/// The site permission prompt (M1.5 builder call, no capture exists; docs/app/README.md "Builder calls and rulings"): a card under the toolbar at the
/// card's top left with the site, what it asks for, Block and Allow, and a close button (a one-time dismiss). Chromium's own bubble never shows.
final class PermissionPromptView: NSView {
    override var isFlipped: Bool { true }
    let site = NSTextField(labelWithString: "")
    let text = NSTextField(labelWithString: "")
    let block = PromptButton(title: "Block", identifier: "perm.block", primary: false)
    let allow = PromptButton(title: "Allow", identifier: "perm.allow", primary: true)
    let close = ChromeButton(symbol: "xmark", identifier: "perm.close", label: "Dismiss")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("perm.prompt")
        site.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        site.textColor = ChromeStyle.barTitle
        site.lineBreakMode = .byTruncatingMiddle
        site.setAccessibilityIdentifier("perm.site")
        text.font = ChromeStyle.barRowFont
        text.textColor = ChromeStyle.barHost
        text.lineBreakMode = .byTruncatingTail
        text.setAccessibilityIdentifier("perm.text")
        for v in [site, text, block, allow, close] as [NSView] { addSubview(v) }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// How often the card went from hidden to shown (test support: a stored decision must never show it).
    private(set) var shownCount = 0

    func show(site siteText: String, request: String) {
        if isHidden { shownCount += 1 }
        site.stringValue = siteText
        text.stringValue = request
        isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        site.frame = NSRect(x: 16, y: 12, width: max(0, w - 64), height: 18)
        text.frame = NSRect(x: 16, y: 32, width: max(0, w - 32), height: 18)
        close.frame.origin = NSPoint(x: w - 40, y: 4)
        allow.frame = NSRect(x: w - 16 - 84, y: bounds.height - 12 - 30, width: 84, height: 30)
        block.frame = NSRect(x: allow.frame.minX - 8 - 84, y: allow.frame.minY, width: 84, height: 30)
    }

    override func mouseDown(with event: NSEvent) {}  // the card takes the press, the toolbar behind it must not drag the window

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.barRadius, yRadius: ChromeStyle.barRadius)
        ChromeStyle.barFill.setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
    }
}

/// A text button of the prompt in the command bar's tokens: the primary one is the light "go" pill.
final class PromptButton: NSButton {
    init(title: String, identifier: String, primary: Bool) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = (primary ? ChromeStyle.barGoFill : ChromeStyle.barSendFill).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: primary ? ChromeStyle.barGoText : ChromeStyle.barTitle,
        ])
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
}
