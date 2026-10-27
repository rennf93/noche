import AppKit

/// The sidebar's bottom row (note 1.4, live-ui.md section 3): the downloads button at the left, a dot for the one Space in the middle
/// and the Spaces chevron at the right. There is a single Space in M1.6, so the dot and the chevron are drawn and inert.
final class SidebarBottomBar: DragView {
    let downloadButton = DownloadButtonView(frame: .zero)
    /// The dot and the chevron, in the bar's coordinates (the check reads them).
    var spaceDotFrame: NSRect {
        let d = ChromeStyle.spaceDot
        return NSRect(x: ChromeStyle.spaceDotCenterX - d / 2, y: ChromeStyle.bottomIconY - d / 2, width: d, height: d)
    }
    var chevronCenter: NSPoint { NSPoint(x: ChromeStyle.spacesChevronCenterX, y: ChromeStyle.bottomIconY) }

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
        ChromeStyle.spaceDotActive.setFill()
        NSBezierPath(ovalIn: BarHook.on("SB_BARDRAW") ? spaceDotFrame.offsetBy(dx: 4, dy: 0) : spaceDotFrame).fill()  // the hook: the dot is drawn 4 pt right of where the geometry says
        if let chevron = ChromeStyle.symbol("chevron.down", size: 10, color: ChromeStyle.sidebarIcon) {
            let s = chevron.size
            chevron.draw(in: NSRect(x: chevronCenter.x - s.width / 2, y: chevronCenter.y - s.height / 2, width: s.width, height: s.height))
        }
    }
}
