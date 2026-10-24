import Foundation
import GRDB

public struct HistoryVisit: Equatable, Sendable {
    public let url: String
    public let title: String
    public let visitedAt: Date
}

public struct HistoryDay: Equatable, Sendable {
    /// Start of the local day in the calendar's time zone.
    public let day: Date
    public let visits: [HistoryVisit]
}

extension Store {
    /// Live visits of live pages, newest first, grouped by |calendar| day. |search| is a case-folded substring of title or URL.
    /// |limit| caps the number of visits.
    public func historyDays(calendar: Calendar, search: String = "", limit: Int = 500) throws -> [HistoryDay] {
        var sql = """
            SELECT page.url, page.title, visit.visitedAt FROM visit JOIN page ON page.id = visit.pageId
            WHERE visit.deletedAt IS NULL AND page.deletedAt IS NULL AND page.profileId = ?
            """
        var args: [any DatabaseValueConvertible] = [Schema.defaultProfileID]
        if !search.isEmpty {
            sql += " AND (swiftLowercaseString(page.title) LIKE ? ESCAPE '\\' OR swiftLowercaseString(page.url) LIKE ? ESCAPE '\\')"
            let q = "%" + Self.escapeLike(search.lowercased()) + "%"
            args += [q, q]
        }
        sql += " ORDER BY visit.visitedAt DESC, visit.rowid DESC LIMIT ?"
        args.append(limit)
        let rows = try db.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }
        var days: [HistoryDay] = [], day: Date?, cur: [HistoryVisit] = []
        for r in rows {
            let v = HistoryVisit(url: r["url"], title: r["title"], visitedAt: Date(timeIntervalSince1970: r["visitedAt"]))
            let d = calendar.startOfDay(for: v.visitedAt)
            if d != day {
                if let day { days.append(HistoryDay(day: day, visits: cur)) }
                day = d
                cur = []
            }
            cur.append(v)
        }
        if let day { days.append(HistoryDay(day: day, visits: cur)) }
        return days
    }

    /// Tombstones the live page for |url| and all its visits in one transaction.
    public func deletePage(url: String) throws {
        let n = now().timeIntervalSince1970
        try db.write { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM page WHERE profileId = ? AND url = ? AND deletedAt IS NULL",
                                               arguments: [Schema.defaultProfileID, url]) else { return }
            try db.execute(sql: "UPDATE visit SET deletedAt = ?, updatedAt = ? WHERE pageId = ? AND deletedAt IS NULL", arguments: [n, n, id])
            try db.execute(sql: "UPDATE page SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [n, n, id])
        }
    }
}
