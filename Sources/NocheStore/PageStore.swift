import Foundation
import GRDB
import NocheCore

struct PageRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "page"
    var url: String
    var host: String
    var title: String
    var visitCount: Int
    var typedCount: Int
    var lastVisitAt: Double

    var candidate: PageCandidate {
        PageCandidate(url: url, host: host, title: title, visitCount: visitCount, typedCount: typedCount,
                      lastVisitAt: Date(timeIntervalSince1970: lastVisitAt))
    }
}

extension Store {
    /// Records one http(s) visit: one live page row per profile and URL, plus a visit row. Other schemes are ignored.
    public func recordVisit(url: String, title: String, typed: Bool, at: Date) throws {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = c.host?.lowercased(), !host.isEmpty else { return }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let t = at.timeIntervalSince1970, n = now().timeIntervalSince1970
        try db.write { db in
            let pid = Schema.defaultProfileID
            var pageId = try String.fetchOne(db, sql: "SELECT id FROM page WHERE profileId = ? AND url = ? AND deletedAt IS NULL",
                                             arguments: [pid, url])
            if let id = pageId {
                try db.execute(sql: """
                    UPDATE page SET visitCount = visitCount + 1, typedCount = typedCount + ?, lastVisitAt = ?,
                      title = CASE WHEN ? = '' THEN title ELSE ? END,
                      titleFolded = CASE WHEN ? = '' THEN titleFolded ELSE ? END, updatedAt = ? WHERE id = ?
                    """, arguments: [typed ? 1 : 0, t, title, title, title.lowercased(), title.lowercased(), n, id])
            } else {
                let id = UUID().uuidString
                pageId = id
                try db.execute(sql: """
                    INSERT INTO page (id, profileId, url, host, title, titleFolded, visitCount, typedCount, lastVisitAt, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                    """, arguments: [id, pid, url, host, title, title.lowercased(), typed ? 1 : 0, t, n, n])
            }
            try db.execute(sql: "INSERT INTO visit (id, pageId, visitedAt, transition, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, pageId, t, typed ? "typed" : "link", n, n])
        }
    }

    /// Changes only the live row for |url|.
    public func updateTitle(url: String, title: String) throws {
        let n = now().timeIntervalSince1970
        try db.write {
            try $0.execute(sql: "UPDATE page SET title = ?, titleFolded = ?, updatedAt = ? WHERE profileId = ? AND url = ? AND deletedAt IS NULL",
                           arguments: [title, title.lowercased(), n, Schema.defaultProfileID, url])
        }
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Newest first. Matches host prefix, url prefix (also without the scheme and "www."), title word prefix and title prefix.
    /// URLs are stored verbatim (a #fragment makes a separate row; normalizing is the caller's policy).
    /// The scheme-less url match is four LIKEs on |url|, no extra column. Ranking is the caller's job.
    public func pageCandidates(prefix: String, limit: Int = 50) throws -> [PageCandidate] {
        guard !prefix.isEmpty else { return [] }
        let q = Self.escapeLike(typedWithoutSchemeAndWww(prefix).lowercased()), tq = q
        return try db.read { db in
            try PageRow.all().live()
                .filter(sql: """
                    profileId = :pid AND (host LIKE :q || '%' ESCAPE '\\' OR url LIKE 'http://' || :q || '%' ESCAPE '\\'
                     OR url LIKE 'https://' || :q || '%' ESCAPE '\\' OR url LIKE 'https://www.' || :q || '%' ESCAPE '\\'
                     OR url LIKE 'http://www.' || :q || '%' ESCAPE '\\'
                     OR titleFolded LIKE '% ' || :tq || '%' ESCAPE '\\'
                     OR titleFolded LIKE :tq || '%' ESCAPE '\\')
                    """, arguments: ["q": q, "tq": tq, "pid": Schema.defaultProfileID])
                .order(Column("lastVisitAt").desc, Column("rowid").desc)
                .limit(limit)
                .fetchAll(db).map(\.candidate)
        }
    }

    /// One candidate per host: summed counts, newest lastVisitAt, url and title of the newest page of that host. Newest host first.
    public func hostCandidates(prefix: String, limit: Int = 50) throws -> [PageCandidate] {
        guard !prefix.isEmpty else { return [] }
        let rows = try db.read { db in
            try PageRow.all().live()
                .filter(sql: "profileId = :pid AND host LIKE :q || '%' ESCAPE '\\'",
                        arguments: ["q": Self.escapeLike(prefix), "pid": Schema.defaultProfileID])
                .order(Column("lastVisitAt").desc, Column("rowid").desc)
                .fetchAll(db).map(\.candidate)
        }
        var order: [String] = [], byHost: [String: PageCandidate] = [:]
        for r in rows {
            if let h = byHost[r.host] {
                byHost[r.host] = PageCandidate(url: h.url, host: h.host, title: h.title, visitCount: h.visitCount + r.visitCount,
                                               typedCount: h.typedCount + r.typedCount, lastVisitAt: h.lastVisitAt)
            } else {
                order.append(r.host)
                byHost[r.host] = r
            }
        }
        return order.prefix(limit).compactMap { byHost[$0] }
    }
}
