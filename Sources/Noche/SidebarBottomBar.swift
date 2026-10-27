import AppKit

/// The sidebar's bottom row (note 1.4, live-ui.md section 3): the downloads button at the left, a dot for the one Space in the middle
/// and the Spaces chevron at the right. There is a single Space in M1.6, so the dot and the chevron are drawn and inert.
final class SidebarBottomBar: DragView {
    let downloadButton = DownloadButtonView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(downloadButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The reference's 18 pt box starts at x 14; the 36 pt button is centered on the same icon.
        downloadButton.frame.origin = NSPoint(x: 14 + 9 - DownloadButtonView.size.width / 2, y: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = ChromeStyle.spaceDot
        ChromeStyle.spaceDotActive.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: ChromeStyle.bottomIconY - d / 2, width: d, height: d)).fill()
        if let chevron = ChromeStyle.symbol("chevron.down", size: 10, color: ChromeStyle.sidebarIcon) {
            let s = chevron.size
            chevron.draw(in: NSRect(x: bounds.maxX - 32 + 9 - s.width / 2, y: ChromeStyle.bottomIconY - s.height / 2, width: s.width, height: s.height))
        }
    }
}
