import XCTest
import GRDB
@testable import NocheStore

final class HistoryQueriesTests: XCTestCase {
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    // 2001-09-09 01:46:40 UTC
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000_000_000 + s) }

    func testGroupedByInjectedLocalDayNewestFirst() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: at(0))
        try s.recordVisit(url: "https://b.com/", title: "B", typed: false, at: at(3600))
        try s.recordVisit(url: "https://c.com/", title: "C", typed: false, at: at(-86400))
        let utc = try s.historyDays(calendar: cal("UTC"))
        XCTAssertEqual(utc.count, 2)
        XCTAssertEqual(utc[0].visits.map(\.title), ["B", "A"])
        XCTAssertEqual(utc[0].visits[0].url, "https://b.com/")
        XCTAssertEqual(utc[1].visits.map(\.title), ["C"])
        XCTAssertEqual(utc[0].day, cal("UTC").startOfDay(for: at(0)))
        // 2001-09-09 01:46 UTC is still 09-08 evening in Los Angeles, so the two visits there fall on different days than in UTC.
        let la = try s.historyDays(calendar: cal("America/Los_Angeles"))
        XCTAssertEqual(la.map { $0.visits.count }, [2, 1])
        XCTAssertNotEqual(la[0].day, utc[0].day)
    }

    func testMidnightStraddleDiffersByZone() throws {
        let s = try Store.inMemory()
        let la = cal("America/Los_Angeles")
        let midnight = la.date(from: DateComponents(year: 2026, month: 5, day: 10))!
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: midnight.addingTimeInterval(-60))
        try s.recordVisit(url: "https://b.com/", title: "B", typed: false, at: midnight.addingTimeInterval(60))
        XCTAssertEqual(try s.historyDays(calendar: la).map { $0.visits.count }, [1, 1])
        XCTAssertEqual(try s.historyDays(calendar: cal("UTC")).map { $0.visits.count }, [2])
    }

    func testDSTDayIsOneGroup() throws {
        let s = try Store.inMemory()
        let la = cal("America/Los_Angeles")
        let start = la.startOfDay(for: la.date(from: DateComponents(year: 2026, month: 3, day: 8))!)
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: start.addingTimeInterval(60))
        try s.recordVisit(url: "https://b.com/", title: "B", typed: false, at: start.addingTimeInterval(23 * 3600 - 60))
        let days = try s.historyDays(calendar: la)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].visits.count, 2)
        XCTAssertEqual(days[0].day, start)
    }

    func testSearchCaseFoldedTitleOrURLWithEscapingAndLimit() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/x", title: "Ärger Heute", typed: false, at: at(1))
        try s.recordVisit(url: "https://b.com/100%_sure", title: "Other", typed: false, at: at(2))
        try s.recordVisit(url: "https://c.com/1000x", title: "Third", typed: false, at: at(3))
        func titles(_ q: String) throws -> [String] { try s.historyDays(calendar: cal("UTC"), search: q).flatMap(\.visits).map(\.title) }
        XCTAssertEqual(try titles("ärger"), ["Ärger Heute"])
        XCTAssertEqual(try titles("HEUTE"), ["Ärger Heute"])
        XCTAssertEqual(try titles("B.COM"), ["Other"])
        XCTAssertEqual(try titles("100%_"), ["Other"])
        XCTAssertEqual(try titles("nomatch"), [])
        XCTAssertEqual(try s.historyDays(calendar: cal("UTC"), limit: 2).flatMap(\.visits).count, 2)
    }

    func testDeletePageTombstonesVisitsAndHidesFromCandidates() throws {
        let s = try Store.inMemory()
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: at(1))
        try s.recordVisit(url: "https://a.com/", title: "A", typed: false, at: at(2))
        try s.recordVisit(url: "https://b.com/", title: "B", typed: false, at: at(3))
        XCTAssertEqual(try s.pageCandidates(prefix: "a.com").count, 1)
        try s.deletePage(url: "https://a.com/")
        XCTAssertTrue(try s.pageCandidates(prefix: "a.com").isEmpty)
        XCTAssertEqual(try s.historyDays(calendar: cal("UTC")).flatMap(\.visits).map(\.title), ["B"])
        try s.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM visit WHERE deletedAt IS NOT NULL"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM page WHERE deletedAt IS NOT NULL"), 1)
        }
    }
}
