import XCTest
@testable import NocheCore

final class OverlayMotionTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(OverlayMotion.height(at: 0), 41)
        XCTAssertEqual(OverlayMotion.height(at: 0.107), 107)
        XCTAssertEqual(OverlayMotion.height(at: 5), 107)
        XCTAssertEqual(OverlayMotion.height(at: -1), 41)
    }
    func testMonotonic() {
        var last: CGFloat = 0
        for i in 0...200 {
            let h = OverlayMotion.height(at: Double(i) * 0.001)
            XCTAssertGreaterThanOrEqual(h, last)
            last = h
        }
    }
    // Captured samples sit 17 ms apart after the start frame; the fitted curve is within 2 pt of each.
    func testCapturedSamples() {
        let samples: [(TimeInterval, CGFloat)] = [(0.025, 76), (0.042, 92), (0.058, 101), (0.075, 103.5), (0.092, 105.5), (0.107, 107)]
        for (t, h) in samples { XCTAssertEqual(OverlayMotion.height(at: t), h, accuracy: 2, "t=\(t)") }
    }
}
