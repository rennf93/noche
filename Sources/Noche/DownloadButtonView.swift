import AppKit

/// The sidebar's bottom-left button (live-ui.md section 3, bottom row, icon 14, #666): opens the Downloads window and shows a progress ring
/// around its icon while anything downloads. The reference's 18 pt box is widened to 36 pt so the ring fits (builder call, docs/app/README.md).
final class DownloadButtonView: NSView {
    static let size = NSSize(width: 36, height: 40)
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    /// nil when idle (no ring); 0 to 1 while a download runs or waits paused.
    var progress: Double? {
        didSet {
            guard progress != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        setAccessibilityIdentifier("sidebar.downloads")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Downloads")
        toolTip = "Downloads"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        if let image = ChromeStyle.symbol(progress == nil ? "arrow.down.circle" : "arrow.down", size: 14, color: ChromeStyle.sidebarIcon) {
            image.draw(in: NSRect(x: c.x - image.size.width / 2, y: c.y - image.size.height / 2, width: image.size.width, height: image.size.height))
        }
        guard let progress, !BarHook.on("DL_NORING") else { return }
        let r = ChromeStyle.downloadRingRadius
        let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        track.lineWidth = ChromeStyle.downloadRingWidth
        ChromeStyle.downloadRingTrack.setStroke()
        track.stroke()
        guard progress > 0 else { return }
        // The view is flipped: a clockwise arc from 12 o'clock goes toward larger angles on screen.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * CGFloat(progress), clockwise: false)
        arc.lineWidth = ChromeStyle.downloadRingWidth
        arc.lineCapStyle = .round
        ChromeStyle.downloadRing.setStroke()
        arc.stroke()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
