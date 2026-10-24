import Foundation
import GRDB

public enum PermissionDecision: String, Sendable { case allow, block }

public struct PermissionRecord: Equatable, Sendable {
    public let origin: String
    public let kind: String
    public let decision: PermissionDecision
    public let updatedAt: Date
}

struct PermissionRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "sitePermission"
    var origin: String
    var kind: String
    var decision: String
    var updatedAt: Double
}

extension Store {
    /// |origin| is stored as given (scheme://host[:port]); scheme and port make distinct origins. The old live row is tombstoned.
    public func setPermission(origin: String, kind: String, decision: PermissionDecision) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            try Self.tombstonePermission(db, origin: origin, kind: kind, at: t)
            try db.execute(sql: """
                INSERT INTO sitePermission (id, profileId, origin, kind, decision, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, Schema.defaultProfileID, origin, kind, decision.rawValue, t, t])
        }
    }

    public func permission(origin: String, kind: String) throws -> PermissionDecision? {
        try db.read { db in
            try PermissionRow.all().live()
                .filter(Column("profileId") == Schema.defaultProfileID && Column("origin") == origin && Column("kind") == kind)
                .fetchOne(db).flatMap { PermissionDecision(rawValue: $0.decision) }
        }
    }

    public func removePermission(origin: String, kind: String) throws {
        let t = now().timeIntervalSince1970
        try db.write { try Self.tombstonePermission($0, origin: origin, kind: kind, at: t) }
    }

    /// Live decisions, ordered by origin then kind.
    public func permissions() throws -> [PermissionRecord] {
        try db.read { db in
            try PermissionRow.all().live().filter(Column("profileId") == Schema.defaultProfileID)
                .order(Column("origin"), Column("kind")).fetchAll(db).compactMap { r in
                    PermissionDecision(rawValue: r.decision).map {
                        PermissionRecord(origin: r.origin, kind: r.kind, decision: $0, updatedAt: Date(timeIntervalSince1970: r.updatedAt))
                    }
                }
        }
    }

    private static func tombstonePermission(_ db: Database, origin: String, kind: String, at t: Double) throws {
        try PermissionRow.all().live()
            .filter(Column("profileId") == Schema.defaultProfileID && Column("origin") == origin && Column("kind") == kind)
            .updateAll(db, Column("deletedAt").set(to: t), Column("updatedAt").set(to: t))
    }
}
