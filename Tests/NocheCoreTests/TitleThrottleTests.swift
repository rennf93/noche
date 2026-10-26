import XCTest
@testable import NocheCore

final class TitleThrottleTests: XCTestCase {
    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    /// A title that changes every 100 ms for 10 s, with the deferred flush run when it is due: at most one write per interval, and the last title is written.
    func testFastChangingTitleWritesOncePerIntervalAndKeepsTheLast() {
        var th = TitleThrottle(interval: 2)
        var writes: [(at: Double, title: Int)] = []
        var flushAt: Double?
        var latest = 0
        var step = 0
        while step <= 100 || flushAt != nil {
            let now = Double(step) / 10
            if let due = flushAt, due <= now {  // the timer fires before the next change
                th.flushed(1, now: t(due)); writes.append((due, latest)); flushAt = nil
            }
            if step <= 100 {
                latest = step
                switch th.offer(1, now: t(now)) {
                case .writeNow: writes.append((now, latest))
                case .later(let at): flushAt = at.timeIntervalSince1970 - 1_000_000
                case .pending: break
                }
            }
            step += 1
        }
        XCTAssertLessThanOrEqual(writes.count, 7)  // writes at 0, 2, 4, 6, 8, 10 and the last flush at 12 (101 changes without the throttle)
        for (a, b) in zip(writes, writes.dropFirst()) { XCTAssertGreaterThanOrEqual(b.at - a.at, 2 - 1e-9) }
        XCTAssertEqual(writes.last?.title, 100)
    }

    func testIdleTitleWritesNowAndTabsAreIndependent() {
        var th = TitleThrottle(interval: 2)
        XCTAssertEqual(th.offer(1, now: t(0)), .writeNow)
        XCTAssertEqual(th.offer(2, now: t(0.1)), .writeNow)
        XCTAssertEqual(th.offer(1, now: t(10)), .writeNow)
        XCTAssertEqual(th.offer(1, now: t(10.5)), .later(t(12)))
        XCTAssertEqual(th.offer(1, now: t(10.6)), .pending)
        th.forget(1)
        XCTAssertEqual(th.offer(1, now: t(10.7)), .writeNow)
        var none = TitleThrottle(interval: 0)
        XCTAssertEqual(none.offer(1, now: t(0)), .writeNow)
        XCTAssertEqual(none.offer(1, now: t(0)), .writeNow)
    }
}
