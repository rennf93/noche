import AppKit

/// Placeholder tab strip. Draws static tab cells and a "+" affordance; the
/// real strip (tab model, drag reorder, overflow, audio indicators) is a
/// phase-2 gate, this only reserves the chrome region and proves layout.
final class TabStripView: NSView {
    private struct Tab {
        let title: String
        let active: Bool
    }

    private let tabs: [Tab] = [
        Tab(title: "New Tab", active: true),
        Tab(title: "New Tab 2", active: false),
    ]

    private static let stripHeight: CGFloat = 48
    private static let tabWidth: CGFloat = 200
    private static let tabPadding: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("TabStripView is created in code only")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let stripBackground = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        stripBackground.setFill()
        dirtyRect.fill()

        let topInset: CGFloat = 6
        let tabHeight = Self.stripHeight - topInset * 2
        var x: CGFloat = Self.tabPadding

        for tab in tabs {
            drawTab(
                at: NSRect(x: x, y: topInset, width: Self.tabWidth, height: tabHeight),
                title: tab.title,
                active: tab.active
            )
            x += Self.tabWidth + Self.tabPadding
        }

        drawPlusButton(at: NSRect(x: x, y: topInset, width: tabHeight, height: tabHeight))
    }

    private func drawTab(at rect: NSRect, title: String, active: Bool) {
        let fill = active
            ? NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
            : NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        fill.setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: active ? .medium : .regular),
            .foregroundColor: active
                ? NSColor(calibratedWhite: 0.92, alpha: 1)
                : NSColor(calibratedWhite: 0.65, alpha: 1),
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        text.draw(at: origin)
    }

    private func drawPlusButton(at rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        circle.fill()

        let cross = "+"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1),
        ]
        let text = NSAttributedString(string: cross, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
