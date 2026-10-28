import AppKit

/// Draws a custom icon (an emoji or an SF Symbol name) as an image: a tab's own icon in place of its favicon.
@MainActor
enum IconRender {
    private static var images: [String: NSImage] = [:]
    /// The tab-row size, kept: a row compares images by identity, so the same icon must give the same image.
    static func cached(_ icon: String) -> NSImage? {
        if let i = images[icon] { return i }
        guard let i = image(icon, size: ChromeStyle.tileFaviconSize, color: NSColor.white.withAlphaComponent(0.85)) else { return nil }
        images[icon] = i
        return i
    }

    static func image(_ icon: String, size: CGFloat, color: NSColor) -> NSImage? {
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil { return ChromeStyle.symbol(icon, size: size, color: color) }
        let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: size - 2)])
        let box = text.size()
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            text.draw(at: NSPoint(x: (rect.width - box.width) / 2, y: (rect.height - box.height) / 2))
            return true
        }
    }
}

/// The Change Icon popover's content (note 2): a grid of emoji, a grid of symbols, a button for the system character palette and one that
/// removes the icon. |onPick| gets the chosen icon, or nil for "Remove Icon".
final class IconPickerView: NSView {
    static let emoji = ["😀", "😎", "🤔", "😴", "🔥", "⭐️", "❤️", "💡", "📌", "📚", "🎵", "🎮", "🎬", "📷", "✈️", "🏠",
                        "💼", "🛒", "💰", "🧪", "🛠", "🎨", "📰", "🌍", "☕️", "🍕", "⚽️", "🚗", "🌱", "🐶", "🐱", "🎁"]
    static let symbols = ["folder", "star", "heart", "bookmark", "tag", "flag", "bolt", "flame", "leaf", "cloud", "moon", "sun.max",
                          "book", "graduationcap", "briefcase", "cart", "creditcard", "gamecontroller", "music.note", "film",
                          "camera", "house", "airplane", "wrench.and.screwdriver"]
    final class Cell: NSButton { var icon: String? }

    override var isFlipped: Bool { true }
    var onPick: ((String?) -> Void)?
    private(set) var cells: [Cell] = []
    let removeButton = NSButton(title: "Remove Icon", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let cell = ChromeStyle.iconCell, cols = ChromeStyle.iconColumns, pad = ChromeStyle.iconPickerPad
        var y = pad
        func grid(_ icons: [String]) {
            for (i, icon) in icons.enumerated() {
                let b = Cell(frame: NSRect(x: pad + CGFloat(i % cols) * cell, y: y + CGFloat(i / cols) * cell, width: cell, height: cell))
                b.icon = icon
                b.isBordered = false
                b.target = self
                b.action = #selector(picked(_:))
                b.setAccessibilityLabel(icon)
                if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                    b.image = ChromeStyle.symbol(icon, size: 15, color: NSColor.white.withAlphaComponent(0.85))
                    b.imagePosition = .imageOnly
                } else {
                    b.title = icon
                    b.font = .systemFont(ofSize: 18)
                }
                addSubview(b)
                cells.append(b)
            }
            y += CGFloat((icons.count + cols - 1) / cols) * cell + 8
        }
        grid(Self.emoji)
        grid(Self.symbols)
        let palette = NSButton(title: "Emoji & Symbols", target: self, action: #selector(openPalette))
        palette.bezelStyle = .rounded
        palette.frame = NSRect(x: pad, y: y, width: 130, height: 24)
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.frame = NSRect(x: pad + 138, y: y, width: 100, height: 24)
        addSubview(palette)
        addSubview(removeButton)
        setFrameSize(NSSize(width: pad * 2 + cell * CGFloat(cols), height: y + 24 + pad))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked(_ sender: Cell) { onPick?(sender.icon) }
    @objc private func remove() { onPick?(nil) }
    @objc private func openPalette() { NSApp.orderFrontCharacterPalette(nil) }
}

/// Where the picker shows. Test builds keep it here instead of opening a popover (a hidden window is never key); a check picks a cell.
@MainActor
enum IconPicker {
#if NOCHE_TESTHOOKS
    static var pending: (view: IconPickerView, finish: () -> Void)?
    static func dismiss() { let p = pending; pending = nil; p?.finish() }
#endif

    static func present(from anchor: NSView, pick: @escaping (String?) -> Void) {
        let view = IconPickerView(frame: .zero)
#if NOCHE_TESTHOOKS
        view.onPick = { icon in dismiss(); pick(icon) }
        pending = (view, {})
#else
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        view.onPick = { [weak popover] icon in popover?.close(); pick(icon) }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
#endif
    }
}
