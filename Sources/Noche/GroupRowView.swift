import AppKit
import NocheCore

/// A group's header row (note 1.3): icon, name, a chevron that turns down when the group is open, and a dot while the group is
/// closed over the active tab. The children are ordinary tab rows below it.
final class GroupRowView: NSView {
    override var isFlipped: Bool { true }
    var groupID: GroupID?
    var onClick: (() -> Void)?
    private var name = "", icon: String?, colorIndex = 0
    private(set) var isCollapsed = true
    private var hasActive = false
    private var configured = false
    private let chevron = CALayer()
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.bounds = CGRect(x: 0, y: 0, width: ChromeStyle.groupChevronSize, height: ChromeStyle.groupChevronSize)
        layer?.addSublayer(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A view taken from the pool is not under the pointer until AppKit says so.
    func clearHover() { isHovered = false }

    func configure(name: String, icon: String?, colorIndex: Int, collapsed: Bool, hasActive: Bool) {
        let turned = configured && collapsed != isCollapsed
        self.name = name; self.icon = icon; self.colorIndex = colorIndex; self.hasActive = hasActive
        isCollapsed = collapsed
        configured = true
        if chevron.contents == nil, let img = ChromeStyle.symbol("chevron.right", size: ChromeStyle.groupChevronSize, color: ChromeStyle.groupChevron) {
            chevron.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            chevron.contentsScale = window?.backingScaleFactor ?? 2
        }
        let angle: CGFloat = collapsed ? 0 : .pi / 2
        if turned {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = collapsed ? CGFloat.pi / 2 : 0
            a.toValue = angle
            a.duration = ChromeStyle.groupChevronDuration
            chevron.add(a, forKey: "turn")
        }
        chevron.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        setAccessibilityLabel(name)
        setAccessibilityValue(collapsed ? "collapsed" : "expanded")
        needsLayout = true
        needsDisplay = true
    }

    private var labelWidth: CGFloat {
        let max = bounds.width - (ChromeStyle.titleX - ChromeStyle.rowX) - ChromeStyle.groupChevronGap - ChromeStyle.groupChevronSize - 12
        return min(NSAttributedString(string: name, attributes: [.font: ChromeStyle.groupFont]).size().width, Swift.max(0, max))
    }

    override func layout() {
        super.layout()
        let x = ChromeStyle.titleX - ChromeStyle.rowX + labelWidth + ChromeStyle.groupChevronGap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.position = CGPoint(x: x + ChromeStyle.groupChevronSize / 2, y: bounds.midY)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            ChromeStyle.rowHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: ChromeStyle.rowRadius, yRadius: ChromeStyle.rowRadius).fill()
        }
        let tint = ChromeStyle.groupColors[Swift.min(Swift.max(colorIndex, 0), ChromeStyle.groupColors.count - 1)]
        let ix = ChromeStyle.faviconX - ChromeStyle.rowX, iy = (bounds.height - ChromeStyle.groupIconSize) / 2
        if let icon, !icon.isEmpty, NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil {
            // An emoji (or any text) icon.
            NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: ChromeStyle.groupIconSize - 2)])
                .draw(at: NSPoint(x: ix, y: iy - 1))
        } else {
            ChromeStyle.symbol(icon.flatMap { $0.isEmpty ? nil : $0 } ?? "folder", size: ChromeStyle.groupIconSize, color: tint)?
                .draw(in: NSRect(x: ix, y: iy, width: ChromeStyle.groupIconSize, height: ChromeStyle.groupIconSize))
        }
        let text = NSAttributedString(string: name, attributes: [.font: ChromeStyle.groupFont, .foregroundColor: NSColor.white])
        let tx = ChromeStyle.titleX - ChromeStyle.rowX
        text.draw(in: NSRect(x: tx, y: (bounds.height - text.size().height) / 2, width: labelWidth + 2, height: text.size().height))
        if isCollapsed, hasActive {
            let d = ChromeStyle.groupActiveDot
            let dx = tx + labelWidth + ChromeStyle.groupChevronGap + ChromeStyle.groupChevronSize + 6
            ChromeStyle.groupActiveDotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: dx, y: (bounds.height - d) / 2, width: d, height: d)).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
