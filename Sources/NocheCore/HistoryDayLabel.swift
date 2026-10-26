import Foundation

/// The header of a day in the History window: Today, Yesterday, or the full date.
public enum HistoryDayLabel {
    public static func title(for day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? Locale.current
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: day)
    }
}
