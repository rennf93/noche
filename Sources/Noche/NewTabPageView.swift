import AppKit

/// A static grain disc (the reference's orb is a 6 s video, not needed): a radial gradient with a fixed noise speckle.
final class OrbView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let disc = NSBezierPath(ovalIn: bounds)
        ctx.saveGState()
        disc.addClip()
        NSGradient(starting: NSColor(hex: 0x767676), ending: NSColor(hex: 0x464646))?.draw(in: disc, relativeCenterPosition: NSPoint(x: -0.3, y: 0.4))
        // Grain: a fixed pseudo-random speckle (a linear congruential sequence, so every draw is identical).
        var seed: UInt32 = 0x1F2E3D4C
        for _ in 0..<400 {
            seed = seed &* 1664525 &+ 1013904223
            let x = CGFloat(seed >> 8 & 0xFFFF) / 65535 * bounds.width
            seed = seed &* 1664525 &+ 1013904223
            let y = CGFloat(seed >> 8 & 0xFFFF) / 65535 * bounds.height
            NSColor(white: (seed & 1) == 0 ? 0.85 : 0.2, alpha: 0.18).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }
        ctx.restoreGState()
    }
}

/// The New Tab surface: behind-window vibrancy over the web rect (so the opaque card fill does not show) and the orb above the command bar's card.
/// Not flipped, so the layer's bottom corners are MinY (the page view has square top corners and round bottom ones).
final class NewTabPageView: NSView {
    let effect = NSVisualEffectView()
    let orb = OrbView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("newTabPage")
        wantsLayer = true
        layer?.cornerRadius = ChromeStyle.cardRadius
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        addSubview(orb)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The orb sits 24 pt above the card, centered on it, 62 pt across (note section 1b); |card| is in window points, origin top-left.
    func placeOrb(above card: CGRect, windowHeight: CGFloat) {
        let topLeftY = card.minY - 24 - 62
        let hostY = windowHeight - (topLeftY + 62)
        orb.frame = NSRect(x: card.midX - 31 - frame.minX, y: hostY - frame.minY, width: 62, height: 62)
    }
}
