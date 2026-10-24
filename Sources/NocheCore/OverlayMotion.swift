import Foundation

public enum OverlayMotion {
    static let duration: TimeInterval = 0.107

    /// Overlay open height: cubic ease-out from 41 to 107 pt over 107 ms.
    public static func height(at elapsed: TimeInterval) -> CGFloat {
        let u = min(max(elapsed / duration, 0), 1)
        return 41 + 66 * CGFloat(1 - pow(1 - u, 3))
    }
}
