import AppKit

/// The group menu's row of 8 color swatches (live-ui.md section 3: ~18 px circles, pitch 24, the chosen one ringed in white).
final class SwatchRowView: NSView {
    override var isFlipped: Bool { true }
    var onPick: ((Int) -> Void)?
    private(set) var selected: Int

    init(selected: Int) {
        self.selected = selected
        let inset = ChromeStyle.swatchRowInset
        super.init(frame: NSRect(x: 0, y: 0, width: inset * 2 + ChromeStyle.swatchPitch * CGFloat(ChromeStyle.groupColors.count), height: ChromeStyle.swatchRowHeight))
        setAccessibilityElement(true)
        setAccessibilityLabel("Colors")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The circle of swatch |i| (its cell is |swatchPitch| wide).
    func swatchRect(_ i: Int) -> NSRect {
        let s = ChromeStyle.swatchSize
        return NSRect(x: ChromeStyle.swatchRowInset + ChromeStyle.swatchPitch * CGFloat(i) + (ChromeStyle.swatchPitch - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    }

    /// Choosing swatch |i|: its color is set and the menu closes.
    func pick(_ i: Int) {
        guard ChromeStyle.groupColors.indices.contains(i) else { return }
        selected = i
        needsDisplay = true
        onPick?(i)
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, color) in ChromeStyle.groupColors.enumerated() {
            let r = swatchRect(i)
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            if i == selected {
                ChromeStyle.swatchRing.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = ChromeStyle.groupColors.indices.first(where: { swatchRect($0).insetBy(dx: -3, dy: -3).contains(p) }) { pick(i) }
    }
}
