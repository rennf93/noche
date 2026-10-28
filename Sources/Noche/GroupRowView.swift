import AppKit
import NocheCore

/// A group's header row (note 1.3): icon, name, a chevron that turns down when the group is open, and a dot while the group is
/// closed over the active tab. The children are ordinary tab rows below it.
final class GroupRowView: NSView {
    override var isFlipped: Bool { true }
    var groupID: GroupID?
    var onClick: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?   // the click in window coordinates
    var onRename: ((String) -> Void)?         // the inline field committed this name
    var onDragStart: ((NSEvent) -> Void)?     // a press moved 3 pt: the group's drag
    private var trigger = DragTrigger()
    private(set) var name = "", icon: String?, colorIndex = 0
    private(set) var isCollapsed = true
    private var hasActive = false
    private var configured = false
    private let chevron = CALayer()
    let renameField = RenameField()
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.bounds = CGRect(x: 0, y: 0, width: ChromeStyle.groupChevronSize, height: ChromeStyle.groupChevronSize)
        layer?.addSublayer(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        renameField.onCommit = { [weak self] text in self?.onRename?(text); self?.needsDisplay = true }
        renameField.onCancel = { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A view taken from the pool is not under the pointer until AppKit says so; a rename in progress ends (the view is for another group).
    func clearHover() { renameField.cancel(); isHovered = false; configured = false }

    /// The color the icon is drawn in.
    private static let untinted = BarHook.on("GRP_NOICONTINT")  // negative control: the icon stays white
#if NOCHE_TESTHOOKS
    var tintOverride: NSColor?  // group-colors draws its references through a row of its own, in a color it lists by hand
#endif
    var iconTint: NSColor {
#if NOCHE_TESTHOOKS
        if let tintOverride { return tintOverride }
#endif
        return ChromeStyle.groupColors[Self.untinted ? 0 : Swift.min(Swift.max(colorIndex, 0), ChromeStyle.groupColors.count - 1)]
    }

    /// The name becomes an inline field (Return commits, Escape cancels).
    func beginRename() {
        let tx = ChromeStyle.titleX - ChromeStyle.rowX
        renameField.begin(name, font: ChromeStyle.groupFont, frame: NSRect(x: tx, y: (bounds.height - 18) / 2, width: Swift.max(40, bounds.width - tx - 8), height: 18), in: self)
        needsDisplay = true
    }  // a reused view animates nothing for another group's state

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
        let tint = iconTint
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
        if renameField.isEditing { return }
        text.draw(in: NSRect(x: tx, y: (bounds.height - text.size().height) / 2, width: labelWidth + 2, height: text.size().height))
        if isCollapsed, hasActive {
            let d = ChromeStyle.groupActiveDot
            let dx = tx + labelWidth + ChromeStyle.groupChevronGap + ChromeStyle.groupChevronSize + 6
            ChromeStyle.groupActiveDotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: dx, y: (bounds.height - d) / 2, width: d, height: d)).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return renameField.isEditing && hit.isDescendant(of: renameField) ? hit : self  // the field takes its own clicks while it edits
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        if renameField.isEditing { return }
        if event.modifierFlags.contains(.control) { onContextMenu?(event.locationInWindow); return }  // Control-click is a right click
        trigger.press(event)  // the click lands on release: a press that moves is a drag, which must not open or close the group
    }
    override func mouseDragged(with event: NSEvent) { if trigger.moved(event) { onDragStart?(event) } }
    override func mouseUp(with event: NSEvent) { if trigger.release(), bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }  // released inside the row
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event.locationInWindow) }
}
