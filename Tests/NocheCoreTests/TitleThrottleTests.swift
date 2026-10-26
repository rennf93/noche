import XCTest
@testable import NocheCore

final class TitleThrottleTests: XCTestCase {
    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }
    private func p(_ url: String, _ title: String) -> TitleThrottle.Pending { .init(url: url, title: title) }

    /// A title that changes every 100 ms for 10 s, with the deferred flush run when it is due: at most one write per interval, and the last title is written.
    func testFastChangingTitleWritesOncePerIntervalAndKeepsTheLast() {
        var th = TitleThrottle(interval: 2)
        var writes: [(at: Double, title: String)] = []
        var flushAt: Double?
        var step = 0
        while step <= 100 || flushAt != nil {
            let now = Double(step) / 10
            if let due = flushAt, due <= now {  // the timer fires before the next change
                if let w = th.take(1, now: t(due), onlyIfDue: true) { writes.append((due, w.title)) }
                flushAt = nil
            }
            if step <= 100 {
                switch th.offer(1, url: "u", title: "T\(step)", now: t(now)) {
                case .writeNow: writes.append((now, "T\(step)"))
                case .later(let at): flushAt = at.timeIntervalSince1970 - 1_000_000
                case .pending: break
                }
            }
            step += 1
        }
        XCTAssertLessThanOrEqual(writes.count, 7)  // writes at 0, 2, 4, 6, 8, 10 and the last flush at 12 (101 changes without the throttle)
        for (a, b) in zip(writes, writes.dropFirst()) { XCTAssertGreaterThanOrEqual(b.at - a.at, 2 - 1e-9) }
        XCTAssertEqual(writes.last?.title, "T100")
    }

    func testIdleTitleWritesNowAndTabsAreIndependent() {
        var th = TitleThrottle(interval: 2)
        XCTAssertEqual(th.offer(1, url: "u", title: "a", now: t(0)), .writeNow)
        XCTAssertEqual(th.offer(2, url: "u", title: "a", now: t(0.1)), .writeNow)
        XCTAssertEqual(th.offer(1, url: "u", title: "a", now: t(10)), .writeNow)
        XCTAssertEqual(th.offer(1, url: "u", title: "b", now: t(10.5)), .later(t(12)))
        XCTAssertEqual(th.offer(1, url: "u", title: "c", now: t(10.6)), .pending)
        th.forget(1)
        XCTAssertEqual(th.offer(1, url: "u", title: "d", now: t(10.7)), .writeNow)
        var none = TitleThrottle(interval: 0)
        XCTAssertEqual(none.offer(1, url: "u", title: "a", now: t(0)), .writeNow)
        XCTAssertEqual(none.offer(1, url: "u", title: "b", now: t(0)), .writeNow)
    }

    /// A title offered inside the interval is held with the address it belongs to; a navigation takes it (the old title for the old address), and the
    /// timer that was armed for it, firing later, finds nothing (and never an unrelated newer pair before its own due time).
    func testPendingKeepsItsAddressAcrossANavigationAndAStaleTimerWritesNothing() {
        var th = TitleThrottle(interval: 2)
        XCTAssertEqual(th.offer(1, url: "http://a/", title: "A1", now: t(0)), .writeNow)
        XCTAssertEqual(th.offer(1, url: "http://a/", title: "A2", now: t(0.5)), .later(t(2)))
        XCTAssertEqual(th.peek(1), p("http://a/", "A2"))
        XCTAssertEqual(th.take(1, now: t(0.6), onlyIfDue: false), p("http://a/", "A2"))  // the navigation
        XCTAssertNil(th.peek(1))
        XCTAssertEqual(th.offer(1, url: "http://b/", title: "B1", now: t(0.7)), .later(t(2.6)))  // the flush at 0.6 restarted the interval
        XCTAssertNil(th.take(1, now: t(2), onlyIfDue: true))  // the first timer fires: not due for the new pair
        XCTAssertEqual(th.take(1, now: t(2.6), onlyIfDue: true), p("http://b/", "B1"))
    }

    /// A tab close, a window close and the quit take what is pending.
    func testCloseAndQuitTakePendingTitles() {
        var th = TitleThrottle(interval: 2)
        _ = th.offer(1, url: "u1", title: "a", now: t(0)); _ = th.offer(1, url: "u1", title: "b", now: t(0.1))
        _ = th.offer(2, url: "u2", title: "a", now: t(0)); _ = th.offer(2, url: "u2", title: "c", now: t(0.1))
        _ = th.offer(3, url: "u3", title: "a", now: t(0))
        XCTAssertEqual(th.take(1, now: t(0.2), onlyIfDue: false), p("u1", "b"))
        th.forget(1)
        let rest = th.drain(now: t(0.3))
        XCTAssertEqual(rest.map(\.id), [2])
        XCTAssertEqual(rest.map(\.pending), [p("u2", "c")])
        XCTAssertTrue(th.drain(now: t(0.4)).isEmpty)
    }
}
