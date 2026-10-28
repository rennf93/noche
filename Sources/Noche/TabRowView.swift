import AppKit
import NocheCore

/// One tab row (live-ui.md section 3): favicon, title that fades out instead of an ellipsis, hover and selected fills.
final class TabRowView: NSView {
    override var isFlipped: Bool { true }
    let faviconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    private(set) var showsPlaceholder = true
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?   // the click in window coordinates
    var onReset: (() -> Void)?                // the return glyph was clicked: back to the pinned page
    /// A pinned row off its pinned page: hovering it shows the return glyph at its right edge.
    private(set) var canReset = false
    var showsResetGlyph: Bool { canReset && isHovered }
    var resetGlyphRect: NSRect {
        let s = ChromeStyle.resetGlyphSize
        return NSRect(x: bounds.maxX - s - ChromeStyle.resetGlyphInset - 4, y: (bounds.height - s) / 2, width: s, height: s)
    }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    let fade = CAGradientLayer()
    let renameField = RenameField()
    var onRename: ((String) -> Void)?         // the inline field committed this title
    var onDragStart: ((NSEvent) -> Void)?     // a press moved 3 pt: the row's drag
    private var trigger = DragTrigger()
    var tabID: TabID?
    private var level = 0

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
        renameField.onCommit = { [weak self] text in self?.titleField.isHidden = false; self?.onRename?(text) }
        renameField.onCancel = { [weak self] in self?.titleField.isHidden = false }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The title becomes an inline field (Return commits, Escape cancels).
    func beginRename() {
        titleField.isHidden = true
        renameField.begin(titleField.stringValue, font: ChromeStyle.font, frame: titleField.frame, in: self)
    }

    /// Child frames are window points: the row sits at x 6, so favicon x 14 and title x 37 are 8 and 31 inside it.
    override func layout() {
        super.layout()
        let y: CGFloat = 10
        let indent = ChromeStyle.groupIndent * CGFloat(level)
        faviconView.frame = NSRect(x: ChromeStyle.faviconX - ChromeStyle.rowX + indent, y: y, width: ChromeStyle.faviconSize, height: ChromeStyle.faviconSize)
        let tx = ChromeStyle.titleX - ChromeStyle.rowX + indent
        titleField.frame = NSRect(x: tx, y: y, width: bounds.width - tx, height: 18)
        fade.frame = titleField.bounds
        let w = max(titleField.bounds.width, 1)
        fade.locations = [0, NSNumber(value: Double(max(0, w - ChromeStyle.titleFade) / w)), 1]
    }

    private var shown: (title: String, favicon: NSImage?, selected: Bool, level: Int, dormant: Bool, canReset: Bool)?
    private static let placeholder = ChromeStyle.symbol("globe", size: 14, color: ChromeStyle.newTabColor)

    /// A refresh configures every realized row; one whose content did not change does nothing.
    /// A view taken from the pool is not under the pointer until AppKit says so.
    func clearHover() { renameField.cancel(); isHovered = false }
    /// The pointer entering or leaving (the checks call it: a hidden window gets no tracking events).
    func hover(_ on: Bool) { isHovered = on }

    func configure(title: String, favicon: NSImage?, selected: Bool, level: Int = 0, dormant: Bool = false, canReset: Bool = false) {
        if let s = shown, s.title == title, s.favicon === favicon, s.selected == selected, s.level == level, s.dormant == dormant, s.canReset == canReset { return }
        shown = (title, favicon, selected, level, dormant, canReset)
        if canReset != self.canReset { self.canReset = canReset; needsDisplay = true }
        if level != self.level { self.level = level; needsLayout = true }
        alphaValue = dormant ? ChromeStyle.dormantAlpha : 1
        titleField.stringValue = title
        showsPlaceholder = favicon == nil
        faviconView.image = favicon ?? Self.placeholder
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
        if showsResetGlyph, let g = ChromeStyle.symbol("arrow.uturn.backward", size: ChromeStyle.resetGlyphSize - 2, color: ChromeStyle.resetGlyphColor) {
            g.draw(in: resetGlyphRect)
        }
    }

    /// The row takes every click inside it, whatever subview is under the point.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return renameField.isEditing && hit.isDescendant(of: renameField) ? hit : self  // the field takes its own clicks while it edits
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        if renameField.isEditing { return }
        if event.modifierFlags.contains(.control) { onContextMenu?(event.locationInWindow); return }  // Control-click is a right click
        if showsResetGlyph, resetGlyphRect.contains(convert(event.locationInWindow, from: nil)) { onReset?(); return }
        trigger.press(event)
        onSelect?()
    }
    override func mouseDragged(with event: NSEvent) { if trigger.moved(event) { onDragStart?(event) } }
    override func mouseUp(with event: NSEvent) { _ = trigger.release() }
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
