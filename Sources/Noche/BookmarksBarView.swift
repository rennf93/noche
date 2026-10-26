import AppKit
import NocheStore

/// One chip of the bookmarks bar (live-ui.md section 2, "bookmarks folder chip"): a folder or page icon, the title and, for a folder, a chevron.
/// Like `ChromeButton` it acts on mouse-up inside, so synthesized events can drive it.
final class BookmarkChipView: NSView {
    override var isFlipped: Bool { true }
    let bookmark: Bookmark?          // nil: the overflow chip
    var onClick: ((NSEvent) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }
    private let titleText: String
    private let icon: String
    private let isFolder: Bool

    /// The width a chip needs for |title|: 8 pt padding, the 14 pt icon, 6 pt gap, the text, and 6 + 10 pt for a folder's chevron.
    static func width(for title: String, folder: Bool) -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: ChromeStyle.chipFont]).width.rounded(.up)
        return min(ChromeStyle.chipMaxWidth, 8 + ChromeStyle.chipIcon + 6 + text + (folder ? 16 : 0) + 8)
    }

    init(bookmark: Bookmark?, frame: NSRect) {
        self.bookmark = bookmark
        isFolder = bookmark.map { $0.kind == .folder } ?? true
        titleText = bookmark?.title ?? ""
        icon = bookmark == nil ? "chevron.right.2" : isFolder ? "folder" : "globe"
        super.init(frame: frame)
        setAccessibilityIdentifier(bookmark == nil ? "bookmarks.overflow" : "bookmarks.item")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(bookmark?.title ?? "More bookmarks")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            ChromeStyle.chipHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: ChromeStyle.chipRadius, yRadius: ChromeStyle.chipRadius).fill()
        }
        let s = ChromeStyle.chipIcon
        ChromeStyle.symbol(icon, size: s - 2, color: ChromeStyle.iconColor)?.draw(in: NSRect(x: 8, y: (bounds.height - s) / 2, width: s, height: s))
        guard bookmark != nil else { return }
        let textX = 8 + s + 6, room = bounds.width - textX - 8 - (isFolder ? 16 : 0)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: ChromeStyle.chipFont, .foregroundColor: ChromeStyle.chipText, .paragraphStyle: para]
        let h = (titleText as NSString).size(withAttributes: attrs).height
        (titleText as NSString).draw(in: NSRect(x: textX, y: (bounds.height - h) / 2, width: max(0, room), height: h), withAttributes: attrs)
        if isFolder {
            ChromeStyle.symbol("chevron.down", size: 8, color: ChromeStyle.iconColor)?.draw(in: NSRect(x: bounds.width - 8 - 10, y: (bounds.height - 10) / 2, width: 10, height: 10))
        }
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(event) }
    }
}

/// The bookmarks bar: the "Bookmarks Bar" root's children as chips, from x 12 of the card, 4 pt apart. A chip that does not fit goes behind a final
/// overflow chip, which opens a menu of the rest.
final class BookmarksBarView: NSView {
    override var isFlipped: Bool { true }
    private(set) var items: [Bookmark] = []
    private(set) var chips: [BookmarkChipView] = []
    private(set) var overflow: [Bookmark] = []
    private(set) var overflowChip: BookmarkChipView?
    /// A chip was used: a page opens (in a new tab for a Cmd click or a middle click), a folder (or the overflow chip, with nil) shows its menu.
    var onOpen: ((Bookmark, Bool) -> Void)?
    var onMenu: ((Bookmark?, BookmarkChipView) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("bookmarks.bar")
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}  // the bar takes the press: the toolbar behind it must not drag the window

    private var laidOut: CGFloat = -1   // the width the chips were placed for; -1 forces the next layout

    func set(_ new: [Bookmark]) {
        guard new != items || laidOut < 0 else { return }
        items = new
        laidOut = -1
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    func relayout() {
        guard bounds.width != laidOut else { return }
        laidOut = bounds.width
        chips.forEach { $0.removeFromSuperview() }
        overflowChip?.removeFromSuperview()
        chips = []
        overflow = []
        overflowChip = nil
        let more = BookmarkChipView.width(for: "", folder: false)
        let limit = bounds.width - ChromeStyle.chipX
        var x = ChromeStyle.chipX
        for (i, b) in items.enumerated() {
            let w = BookmarkChipView.width(for: b.title, folder: b.kind == .folder)
            let last = i == items.count - 1
            if x + w > limit - (last ? 0 : more + ChromeStyle.chipPitch) {
                overflow = Array(items[i...])
                let chip = BookmarkChipView(bookmark: nil, frame: NSRect(x: x, y: ChromeStyle.chipY, width: more, height: ChromeStyle.chipHeight))
                chip.onClick = { [weak self, weak chip] _ in if let chip { self?.onMenu?(nil, chip) } }
                addSubview(chip)
                overflowChip = chip
                return
            }
            let chip = BookmarkChipView(bookmark: b, frame: NSRect(x: x, y: ChromeStyle.chipY, width: w, height: ChromeStyle.chipHeight))
            chip.onClick = { [weak self, weak chip] e in
                guard let self, let chip else { return }
                if b.kind == .folder { onMenu?(b, chip) } else { onOpen?(b, e.modifierFlags.contains(.command) || e.type == .otherMouseUp) }
            }
            addSubview(chip)
            chips.append(chip)
            x += w + ChromeStyle.chipPitch
        }
    }
}
