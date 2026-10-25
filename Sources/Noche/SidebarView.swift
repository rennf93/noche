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

/// The sidebar (live-ui.md section 3): traffic lights on top, then a scrolling list with the New Tab row and one row per tab.
/// The vibrancy behind it is the backdrop, so this view draws no background. The list scrolls (overlay scroller) below the 48 pt strip
/// of the traffic lights; row positions are the spec's window positions when scrolled to the top.
final class SidebarView: DragView {
    static let strip: CGFloat = 48
    private static let bottomPad: CGFloat = 12
    let lights: [TrafficLightView] = ChromeStyle.trafficColors.map { color in
        let v = TrafficLightView(frame: .zero)
        v.color = color
        return v
    }
    let scroll = NSScrollView()
    let document = DragView()
    let newTabRow = NewTabRowView(frame: .zero)
    private(set) var rows: [TabRowView] = []
    private var lastSelected: Int?
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onTabMenu: ((Int, NSPoint) -> Void)?      // row index, click in window coordinates
    var onEmptyMenu: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("sidebar")
        for (i, light) in lights.enumerated() {
            light.frame = NSRect(x: ChromeStyle.trafficX[i], y: ChromeStyle.trafficY, width: ChromeStyle.trafficSize, height: ChromeStyle.trafficSize)
            light.setAccessibilityIdentifier(["window.close", "window.minimize", "window.zoom"][i])
            light.setAccessibilityElement(true)
            light.setAccessibilityRole(.button)
            light.setAccessibilityLabel(["Close", "Minimize", "Zoom"][i])
            addSubview(light)
        }
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        newTabRow.frame = NSRect(x: ChromeStyle.rowX, y: ChromeStyle.newTabY - Self.strip, width: ChromeStyle.rowWidth, height: ChromeStyle.newTabHeight)
        newTabRow.setAccessibilityIdentifier("sidebar.newTab")
        document.addSubview(newTabRow)
        addSubview(scroll)
        updateScroll()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScroll()
    }

    private func updateScroll() {
        scroll.frame = NSRect(x: 0, y: Self.strip, width: bounds.width, height: max(0, bounds.height - Self.strip))
        let content = rows.last.map { $0.frame.maxY + Self.bottomPad } ?? newTabRow.frame.maxY + Self.bottomPad
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(content, scroll.bounds.height))
    }

    /// A right click on no row (the rows take their own): the sidebar's menu.
    override func rightMouseDown(with event: NSEvent) { onEmptyMenu?(event.locationInWindow) }

    func setTrafficLightsHidden(_ hidden: Bool) { lights.forEach { $0.isHidden = hidden } }

    /// One row per entry, in order; rows are reused. A changed selection is scrolled into view.
    func setRows(_ entries: [(title: String, favicon: NSImage?)], selected: Int?) {
        while rows.count > entries.count { rows.removeLast().removeFromSuperview() }
        while rows.count < entries.count {
            let row = TabRowView(frame: .zero)
            row.onSelect = { [weak self, weak row] in if let self, let row, let i = self.rows.firstIndex(of: row) { self.onSelect?(i) } }
            row.onClose = { [weak self, weak row] in if let self, let row, let i = self.rows.firstIndex(of: row) { self.onClose?(i) } }
            row.onContextMenu = { [weak self, weak row] p in if let self, let row, let i = self.rows.firstIndex(of: row) { self.onTabMenu?(i, p) } }
            document.addSubview(row)
            rows.append(row)
        }
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: ChromeStyle.rowX, y: ChromeStyle.rowY(i) - Self.strip, width: ChromeStyle.rowWidth, height: ChromeStyle.rowHeight)
            row.setAccessibilityIdentifier("sidebar.tab.\(i)")
            row.configure(title: entries[i].title, favicon: entries[i].favicon, selected: i == selected)
        }
        updateScroll()
        if let selected, selected != lastSelected, selected < rows.count {
            document.scrollToVisible(rows[selected].frame.insetBy(dx: 0, dy: -6))
        }
        lastSelected = selected
    }
}
