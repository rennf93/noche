import Foundation
import CoreGraphics

/// The pinned grid's geometry (note 1.2): 41 pt tiles, 7 pt apart across and 6 pt down (pitch 47), 6 pt from each side.
public enum PinnedGrid {
    public static let tile: CGFloat = 41
    public static let margin: CGFloat = 6
    public static let columnPitch: CGFloat = 48
    public static let rowPitch: CGFloat = 47

    /// How many tiles fit across |width|: floor((width - 12 + 7) / 48), at least 1.
    public static func columns(_ width: CGFloat) -> Int {
        max(1, Int(((width - 2 * margin + (columnPitch - tile)) / columnPitch).rounded(.down)))
    }

    /// The rows |count| tiles take.
    public static func rows(count: Int, width: CGFloat) -> Int {
        count <= 0 ? 0 : (count + columns(width) - 1) / columns(width)
    }

    /// Tile |index|'s frame, relative to the grid's top.
    public static func frame(index: Int, width: CGFloat) -> CGRect {
        let c = columns(width)
        return CGRect(x: margin + columnPitch * CGFloat(index % c), y: rowPitch * CGFloat(index / c), width: tile, height: tile)
    }

    /// The slot a point (relative to the grid's top) is over, clamped to 0...count (count: after the last tile).
    public static func slot(at point: CGPoint, count: Int, width: CGFloat) -> Int {
        let c = columns(width)
        let col = min(max(Int(((point.x - margin) / columnPitch).rounded(.down)), 0), c - 1)
        let row = max(Int((point.y / rowPitch).rounded(.down)), 0)
        return min(row * c + col, max(count, 0))
    }
}
