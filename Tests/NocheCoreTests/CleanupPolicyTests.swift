import XCTest
@testable import NocheCore

/// Automatic cleanup's schedule and skip rules (T7.4, spec row 102), and which tabs are candidates (the boundary, Never, never the pinned, active or loading).
final class CleanupPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5_000_000)
    private let day: TimeInterval = 86_400

    func testTheLaunchRunIsDueAndAnHourLaterTheNextOne() {
        XCTAssertTrue(CleanupPolicy.isDue(now: t0, lastRun: nil))
        XCTAssertFalse(CleanupPolicy.isDue(now: t0.addingTimeInterval(3599), lastRun: t0))
        XCTAssertTrue(CleanupPolicy.isDue(now: t0.addingTimeInterval(3600), lastRun: t0))
    }

    func testPresentingHoldsTheRunBackAndItStaysDue() {
        XCTAssertFalse(CleanupPolicy.shouldRun(now: t0, lastRun: nil, lastTypedAt: nil, presenting: true))
        XCTAssertTrue(CleanupPolicy.shouldRun(now: t0.addingTimeInterval(1), lastRun: nil, lastTypedAt: nil, presenting: false))
    }

    func testTypingInTheLastTenSecondsHoldsTheRunBack() {
        XCTAssertFalse(CleanupPolicy.shouldRun(now: t0, lastRun: nil, lastTypedAt: t0, presenting: false))
        XCTAssertFalse(CleanupPolicy.shouldRun(now: t0.addingTimeInterval(9.9), lastRun: nil, lastTypedAt: t0, presenting: false))
        XCTAssertTrue(CleanupPolicy.shouldRun(now: t0.addingTimeInterval(10), lastRun: nil, lastTypedAt: t0, presenting: false))
        XCTAssertTrue(CleanupPolicy.shouldRun(now: t0, lastRun: nil, lastTypedAt: t0.addingTimeInterval(-3600), presenting: false))
    }

    func testNotDueNeverRuns() {
        XCTAssertFalse(CleanupPolicy.shouldRun(now: t0.addingTimeInterval(60), lastRun: t0, lastTypedAt: nil, presenting: false))
    }

    private func list() -> (TabList, [String: TabID]) {
        var l = TabList()
        var ids: [String: TabID] = [:]
        func add(_ name: String, daysAgo: Double, pinned: Bool = false, loading: Bool = false, active: Bool = false) {
            let t = TabItem(id: TabID(), engineID: nil, url: "https://\(name).example/", title: name, isLoading: loading, lastActiveAt: t0.addingTimeInterval(-daysAgo * day))
            l.insertNew(t, opener: nil, addToTop: false, activate: active)
            if pinned { l.pin(t.id) }
            ids[name] = t.id
        }
        add("active", daysAgo: 30, active: true)
        add("old", daysAgo: 8)
        add("edge", daysAgo: 7)
        add("six", daysAgo: 6)
        add("pinned", daysAgo: 30, pinned: true)
        add("loading", daysAgo: 30, loading: true)
        add("audible", daysAgo: 30)
        return (l, ids)
    }

    func testCandidatesUseAStrictBoundaryAndSkipPinnedActiveLoadingAndExcluded() {
        let (l, id) = list()
        let got = Set(l.cleanupCandidates(now: t0, threshold: 7 * day, excluding: [id["audible"]!]))
        XCTAssertEqual(got, [id["old"]!])  // exactly 7 days stays, 6 days stays
        XCTAssertEqual(Set(l.cleanupCandidates(now: t0, threshold: 7 * day - 1)), [id["old"]!, id["edge"]!, id["audible"]!])
        XCTAssertEqual(Set(l.cleanupCandidates(now: t0, threshold: day)), [id["old"]!, id["edge"]!, id["six"]!, id["audible"]!])
    }

    func testNeverArchivesNothing() {
        let (l, _) = list()
        XCTAssertEqual(l.cleanupCandidates(now: t0, threshold: nil), [])
    }

    func testAGroupedAndADormantTabAreCandidatesAndKeepTheirGroup() {
        var (l, id) = list()
        let g = l.createGroup(with: id["old"]!)!
        l.setGroup(id["edge"]!, g)
        XCTAssertTrue(l.cleanupCandidates(now: t0, threshold: 7 * day - 1).contains(id["old"]!))
        l.archive([id["old"]!], now: t0)
        XCTAssertEqual(l.archived.first?.groupID, g)
        XCTAssertTrue(l.restore(id["old"]!))
        XCTAssertEqual(l.items.first { $0.id == id["old"]! }?.groupID, g)
    }
}
