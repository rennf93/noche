import XCTest
@testable import NocheCore

/// The hover reveal's timing (spec row 107): 150 ms in the 6 pt strip, 400 ms away from the sidebar widened by 8 pt, and what holds it back.
final class SidebarRevealPolicyTests: XCTestCase {
    private var p = SidebarRevealPolicy()

    private func revealed(at t: TimeInterval = 0) {
        _ = p.update(now: t, x: 3, held: false, editing: false)
        XCTAssertEqual(p.update(now: t + 0.15, x: 3, held: false, editing: false), .reveal)
    }

    func testTheStripRevealsAfterTheDwell() {
        XCTAssertEqual(p.update(now: 0, x: 3, held: false, editing: false), .none)
        XCTAssertEqual(p.deadline, 0.15)
        XCTAssertEqual(p.update(now: 0.149, x: 3, held: false, editing: false), .none)
        XCTAssertEqual(p.update(now: 0.15, x: 3, held: false, editing: false), .reveal)
        XCTAssertTrue(p.revealed)
    }

    func testLeavingTheStripBeforeTheDwellStartsOver() {
        _ = p.update(now: 0, x: 3, held: false, editing: false)
        _ = p.update(now: 0.1, x: 40, held: false, editing: false)
        XCTAssertNil(p.deadline)
        XCTAssertEqual(p.update(now: 0.2, x: 3, held: false, editing: false), .none)
        XCTAssertEqual(p.update(now: 0.34, x: 3, held: false, editing: false), .none)
        XCTAssertEqual(p.update(now: 0.35, x: 3, held: false, editing: false), .reveal)
    }

    func testOnlyTheStripCounts() {
        for x in [6.0, 10, 150, -1] {
            _ = p.update(now: 0, x: x, held: false, editing: false)
            XCTAssertEqual(p.update(now: 1, x: x, held: false, editing: false), .none, "x \(x)")
        }
        XCTAssertEqual(p.update(now: 2, x: nil, held: false, editing: false), .none)
    }

    func testAMenuADragOrAButtonRestartsTheDwell() {
        _ = p.update(now: 0, x: 3, held: false, editing: false)
        XCTAssertEqual(p.update(now: 0.14, x: 3, held: true, editing: false), .none)
        XCTAssertEqual(p.deadline, 0.14 + SidebarRevealPolicy.recheck)
        XCTAssertEqual(p.update(now: 0.5, x: 3, held: false, editing: false), .none)
        XCTAssertEqual(p.update(now: 0.65, x: 3, held: false, editing: false), .reveal)
    }

    func testATextFieldBlocksTheRevealAtTheEndOfTheDwellOnly() {
        _ = p.update(now: 0, x: 3, held: false, editing: false)
        XCTAssertEqual(p.update(now: 0.15, x: 3, held: false, editing: true), .none)
        XCTAssertFalse(p.revealed)
        XCTAssertNil(p.deadline)  // nothing to wait for: only a pointer event asks again
        XCTAssertEqual(p.update(now: 0.2, x: 3, held: false, editing: false), .reveal)  // the answer changed: the dwell was already served
    }

    func testItHidesFourHundredMillisecondsAfterLeavingTheWidenedSidebar() {
        revealed()
        XCTAssertEqual(p.update(now: 1, x: 205, held: false, editing: false), .none)  // 197 + 8 is still outside, 204.9 is not
        XCTAssertEqual(p.update(now: 1.39, x: 204.9, held: false, editing: false), .none)
        XCTAssertNil(p.deadline)
        XCTAssertEqual(p.update(now: 2, x: 400, held: false, editing: false), .none)
        XCTAssertEqual(p.deadline, 2.4)
        XCTAssertEqual(p.update(now: 2.399, x: 400, held: false, editing: false), .none)
        XCTAssertEqual(p.update(now: 2.4, x: 400, held: false, editing: false), .hide)  // 2 + 0.4
        XCTAssertFalse(p.revealed)
    }

    func testComingBackBeforeTheDelayKeepsItOpen() {
        revealed()
        _ = p.update(now: 1, x: 400, held: false, editing: false)
        _ = p.update(now: 1.3, x: 100, held: false, editing: false)
        XCTAssertEqual(p.update(now: 1.8, x: 400, held: false, editing: false), .none)  // the delay counts from the new exit
        XCTAssertEqual(p.update(now: 2.21, x: 400, held: false, editing: false), .hide)
    }

    func testAWindowExitCountsAsLeaving() {
        revealed()
        _ = p.update(now: 1, x: nil, held: false, editing: false)
        XCTAssertEqual(p.update(now: 1.4, x: nil, held: false, editing: false), .hide)
    }

    func testAHeldStateNeverHidesAndRestartsTheDelay() {
        revealed()
        _ = p.update(now: 1, x: 400, held: false, editing: false)
        XCTAssertEqual(p.update(now: 1.5, x: 400, held: true, editing: false), .none)
        XCTAssertEqual(p.update(now: 1.6, x: 400, held: false, editing: false), .none)
        XCTAssertEqual(p.update(now: 1.9, x: 400, held: false, editing: false), .none)  // the delay counts from 1.6, not from 1
        XCTAssertEqual(p.update(now: 2.01, x: 400, held: false, editing: false), .hide)
    }

    func testEndForgetsEverything() {
        revealed()
        p.end()
        XCTAssertFalse(p.revealed)
        XCTAssertNil(p.deadline)
        XCTAssertEqual(p.update(now: 5, x: 400, held: false, editing: false), .none)
    }
}
