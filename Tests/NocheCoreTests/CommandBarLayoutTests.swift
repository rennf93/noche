import XCTest
@testable import NocheCore

final class CommandBarLayoutTests: XCTestCase {
    private let window = CGSize(width: 2368, height: 1436)
    private func eq(_ a: CGFloat, _ b: CGFloat, _ m: String = "", line: UInt = #line) { XCTAssertEqual(a, b, accuracy: 0.5, m, line: line) }

    func testNewTab() {
        for (cardX, x) in [(197.0, 893.0), (6.0, 797.0)] {
            for (n, h) in [(0, 107.0), (3, 240.0), (6, 360.0)] {
                let f = CommandBarLayout.frames(placement: .newTab, rows: n, cardX: cardX, window: window)
                eq(f.card.minX, x); eq(f.card.minY, 640); eq(f.card.width, 774); eq(f.card.height, h)
                XCTAssertEqual(f.rows.count, n)
            }
        }
        let f = CommandBarLayout.frames(placement: .newTab, rows: 6, cardX: 197, window: window)
        eq(f.go.minY - f.card.minY, 313); eq(f.go.width, 102); eq(f.go.height, 34)
        eq(f.go.maxX - f.card.minX, 774 - 13); eq(f.go.minX - f.card.minX, 659)
        eq(f.rows[0].minY - f.card.minY, 62); eq(f.rows[0].height, 36); eq(f.rows[0].minX - f.card.minX, 8)
        eq(f.rows[1].minY - f.rows[0].minY, 40)
        eq(f.micWithGo.minX - f.card.minX, 617); eq(f.micWithGo.minY, f.go.minY); eq(f.chip.minX - f.card.minX, 13); eq(f.chip.width, 142)
        let e = CommandBarLayout.frames(placement: .newTab, rows: 3, cardX: 197, window: window)
        eq(e.send.minX - e.card.minX, 727); eq(e.send.width, 34); eq(e.mic.minX, e.send.minX - 42); eq(e.send.minY - e.card.minY, 193)
        eq(e.input.minX - e.card.minX, 44)
    }

    func testRowsClampedAndTinyWindow() {
        XCTAssertEqual(CommandBarLayout.frames(placement: .overlay, rows: 9, cardX: 197, window: window).rows.count, 6)
        XCTAssertEqual(CommandBarLayout.frames(placement: .overlay, rows: -2, cardX: 197, window: window).rows.count, 0)
        let tiny = CommandBarLayout.frames(placement: .overlay, rows: 3, cardX: 197, window: CGSize(width: 300, height: 200))
        XCTAssertGreaterThanOrEqual(tiny.card.width, 0)
        XCTAssertGreaterThanOrEqual(tiny.input.width, 0)
        XCTAssertTrue(tiny.rows.allSatisfy { $0.width >= 0 })
    }

    func testOverlay() {
        for (cardX, x, w) in [(197.0, 303.0, 1801.0), (6.0, 112.0, 1991.0)] {
            for (n, h) in [(0, 107.0), (6, 355.0)] {
                let f = CommandBarLayout.frames(placement: .overlay, rows: n, cardX: cardX, window: window)
                eq(f.card.minX, x); eq(f.card.width, w); eq(f.card.minY, 0); eq(f.card.height, h)
            }
        }
        let f = CommandBarLayout.frames(placement: .overlay, rows: 6, cardX: 197, window: window)
        eq(f.send.minY, 308); eq(f.rows[0].minY, 57); eq(f.rows[0].minX, 311); eq(f.rows[0].maxX, 2095)
        eq(f.card.maxX, 2103)
        eq(CommandBarLayout.frames(placement: .overlay, rows: 0, cardX: 197, window: window).send.minY, 60)
    }
}
