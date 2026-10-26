import XCTest
@testable import NocheCore

final class HistoryDayLabelTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testTodayYesterdayAndOlder() {
        let now = date(2026, 10, 26, 0)  // a minute after midnight in the fixed zone's day
        let label = { (d: Date) in HistoryDayLabel.title(for: self.cal.startOfDay(for: d), calendar: self.cal, now: now) }
        XCTAssertEqual(label(date(2026, 10, 26, 8)), "Today")
        XCTAssertEqual(label(date(2026, 10, 25, 23)), "Yesterday")
        XCTAssertEqual(label(date(2026, 10, 24)), "Saturday, October 24, 2026")
        XCTAssertEqual(label(date(2025, 12, 31)), "Wednesday, December 31, 2025")
    }

    func testTheGivenCalendarDecidesTheDay() {
        // 00:30 on the 26th in Madrid is 22:30 on the 25th in UTC: the same instants are Today in one calendar and Today minus one in the other.
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = date(2026, 10, 26, 0).addingTimeInterval(1800)
        XCTAssertEqual(HistoryDayLabel.title(for: cal.startOfDay(for: now), calendar: cal, now: now), "Today")
        XCTAssertEqual(HistoryDayLabel.title(for: utc.startOfDay(for: now.addingTimeInterval(-3600)), calendar: utc, now: now), "Today")
        XCTAssertEqual(HistoryDayLabel.title(for: utc.startOfDay(for: now.addingTimeInterval(-3 * 3600)), calendar: utc, now: now), "Today")
        XCTAssertEqual(HistoryDayLabel.title(for: utc.startOfDay(for: now.addingTimeInterval(-24 * 3600)), calendar: utc, now: now), "Yesterday")
    }
}
