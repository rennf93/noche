import Foundation
import CoreGraphics

public struct CommandBarFrames: Equatable, Sendable {
    public var card: CGRect
    public var input: CGRect
    public var rows: [CGRect]
    public var chip: CGRect
    /// Beside the send circle (empty bar): send.minX - 42.
    public var mic: CGRect
    /// Beside the Go pill (typed text): go.minX - 42.
    public var micWithGo: CGRect
    /// The 34 pt send circle (empty bar).
    public var send: CGRect
    /// The 102x34 "Go" pill (typed text, rows shown).
    public var go: CGRect
}

/// The overlay right edge is 264.5 from the window edge: the note's widths (1801 shown, 1991 hidden) differ by one point between the two states, so this sits within 0.5 of both.
/// Window points, top-left origin, same convention as ChromeLayout. The geometry is measured, see the M1.3 note.
public enum CommandBarLayout {
    public enum Placement: Sendable { case newTab, overlay }

    /// cardX is the web card's left edge: 197 with the sidebar shown, 6 hidden, anything in between mid-slide.
    public static func frames(placement: Placement, rows rowCount: Int, cardX: CGFloat, window: CGSize) -> CommandBarFrames {
        let n = min(max(rowCount, 0), 6)
        let header: CGFloat = placement == .newTab ? 60 : 55
        let card: CGRect
        switch placement {
        case .newTab:
            let area = window.width - 6 - cardX
            card = CGRect(x: cardX + (area - 774) / 2, y: window.height / 2 - 78, width: 774, height: 0)
        case .overlay:
            card = CGRect(x: cardX + 106, y: 0, width: max(0, window.width - 264.5 - (cardX + 106)), height: 0)
        }
        let pillTop: CGFloat = n == 0 ? 60 : header + 40 * CGFloat(n) + 13
        var c = card
        c.size.height = pillTop + 47
        let send = CGRect(x: c.maxX - 13 - 34, y: c.minY + pillTop, width: 34, height: 34)
        let go = CGRect(x: c.maxX - 13 - 102, y: send.minY, width: 102, height: 34)
        let inputY: CGFloat = placement == .newTab ? 18 : 17
        let inputH: CGFloat = placement == .newTab ? 23 : 20
        return CommandBarFrames(
            card: c,
            input: CGRect(x: c.minX + 44, y: c.minY + inputY, width: max(0, c.width - 44 - 16), height: inputH),
            rows: (0..<n).map { CGRect(x: c.minX + 8, y: c.minY + header + 40 * CGFloat($0) + 2, width: max(0, c.width - 16), height: 36) },
            chip: CGRect(x: c.minX + 13, y: send.minY + 3, width: 142, height: 28),
            mic: CGRect(x: send.minX - 42, y: send.minY, width: 34, height: 34),
            micWithGo: CGRect(x: go.minX - 42, y: send.minY, width: 34, height: 34),
            send: send, go: go)
    }
}
