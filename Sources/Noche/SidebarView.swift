import AppKit

/// A window control drawn as a plain circle (the window is frameless, so there are no system buttons).
final class TrafficLightView: NSView {
    override var isFlipped: Bool { true }
    var color = NSColor.gray
    var onClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func mouseDown(with event: NSEvent) {}
}

/// The sidebar (live-ui.md section 3): traffic lights, the New Tab row and one row per tab. The vibrancy behind it
/// is the backdrop, so this view draws no background. It is not scrollable in M1.1 (shortcut: rows past the window height are clipped).
final class SidebarView: DragView {
    let lights: [TrafficLightView] = ChromeStyle.trafficColors.map { color in
        let v = TrafficLightView(frame: .zero)
        v.color = color
        return v
    }
    let newTabRow = NewTabRowView(frame: .zero)
    private(set) var rows: [TabRowView] = []
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("sidebar")
        for (i, light) in lights.enumerated() {
            light.frame = NSRect(x: ChromeStyle.trafficX[i], y: ChromeStyle.trafficY, width: ChromeStyle.trafficSize, height: ChromeStyle.trafficSize)
            light.setAccessibilityIdentifier(["window.close", "window.minimize", "window.zoom"][i])
            addSubview(light)
        }
        newTabRow.frame = NSRect(x: ChromeStyle.rowX, y: ChromeStyle.newTabY, width: ChromeStyle.rowWidth, height: ChromeStyle.newTabHeight)
        newTabRow.setAccessibilityIdentifier("sidebar.newTab")
        addSubview(newTabRow)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTrafficLightsHidden(_ hidden: Bool) { lights.forEach { $0.isHidden = hidden } }

    /// One row per entry, in order; rows are reused.
    func setRows(_ entries: [(title: String, favicon: NSImage?)], selected: Int?) {
        while rows.count > entries.count { rows.removeLast().removeFromSuperview() }
        while rows.count < entries.count {
            let row = TabRowView(frame: .zero)
            row.onSelect = { [weak self, weak row] in if let self, let row, let i = self.rows.firstIndex(of: row) { self.onSelect?(i) } }
            row.onClose = { [weak self, weak row] in if let self, let row, let i = self.rows.firstIndex(of: row) { self.onClose?(i) } }
            addSubview(row)
            rows.append(row)
        }
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: ChromeStyle.rowX, y: ChromeStyle.rowY(i), width: ChromeStyle.rowWidth, height: ChromeStyle.rowHeight)
            row.setAccessibilityIdentifier("sidebar.tab.\(i)")
            row.configure(title: entries[i].title, favicon: entries[i].favicon, selected: i == selected)
        }
    }
}
