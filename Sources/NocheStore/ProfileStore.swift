import Foundation
import GRDB
import NocheCore

public enum ProfileError: Error, Equatable, Sendable {
    case invalidName(ProfileNameError), invalidColor, notFound, lastProfile, corruptRetainedDirs, shareSelf, shareChain
}

/// What the app must do after a delete: |clearChromiumData| is true when the profile owned the `Default` directory, which stays
/// on disk (the engine's incognito parent) and must be emptied through ClearBrowsingData instead of being swept.
public struct ProfileDeletion: Equatable, Sendable {
    public let clearChromiumData: Bool
}

public struct Profile: Equatable, Sendable {
    public let id: String
    public let name: String
    public let colorIndex: Int
    public let chromiumDirName: String
    public let isDefault: Bool
    public let position: Int
    public let shareWithProfileId: String?
}

struct ProfileRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "profile"
    var id: String, name: String, colorIndex: Int, chromiumDirName: String, isDefault: Bool, position: Int
    var shareWithProfileId: String?
    var profile: Profile {
        Profile(id: id, name: name, colorIndex: colorIndex, chromiumDirName: chromiumDirName, isDefault: isDefault,
                position: position, shareWithProfileId: shareWithProfileId)
    }
}

extension Store {
    static let newWindowProfileKey = "newWindowProfileId"

    /// Live profiles in list order.
    public func profiles() throws -> [Profile] { try db.read { try Self.liveProfiles($0).map(\.profile) } }

    private static func liveProfiles(_ db: Database) throws -> [ProfileRow] {
        try ProfileRow.all().live().order(Column("position"), Column("createdAt")).fetchAll(db)
    }

    private static func live(_ db: Database, _ id: String) throws -> ProfileRow {
        guard let r = try ProfileRow.all().live().filter(Column("id") == id).fetchOne(db) else { throw ProfileError.notFound }
        return r
    }

    private static func name(_ raw: String, excluding id: String?, _ db: Database) throws -> String {
        do {
            return try ProfileRules.validName(raw, existing: liveProfiles(db).filter { $0.id != id }.map(\.name))
        } catch let e as ProfileNameError { throw ProfileError.invalidName(e) }
    }

    private static func checkColor(_ i: Int) throws {
        guard (0..<ProfilePalette.colors.count).contains(i) else { throw ProfileError.invalidColor }
    }

    private static func renumber(_ db: Database, _ ids: [String]) throws {
        for (i, id) in ids.enumerated() { try db.execute(sql: "UPDATE profile SET position = ? WHERE id = ?", arguments: [i, id]) }
    }

    /// The directory name comes from every name ever assigned (tombstones included), so after the first profile `Default` is never
    /// handed to a new profile, even when its owner was deleted; new profiles always get `Profile <n>`.
    /// One transaction: validates, assigns the next directory name and position, adds the default space and both bookmark roots.
    @discardableResult
    public func createProfile(name: String, colorIndex: Int) throws -> Profile {
        try Self.checkColor(colorIndex)
        let t = now().timeIntervalSince1970
        return try db.write { db in
            let name = try Self.name(name, excluding: nil, db)
            // retained dirs count too: no row names them any more, but their numbers must not be reused.
            let dir = ProfileRules.nextDirName(existing: try String.fetchAll(db, sql: "SELECT chromiumDirName FROM profile") + Self.retained(db))
            let position = (try Int.fetchOne(db, sql: "SELECT max(position) FROM profile WHERE deletedAt IS NULL") ?? -1) + 1
            let id = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO profile (id, name, colorIndex, chromiumDirName, isDefault, position, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, name, colorIndex, dir, dir == "Default", position, t, t])
            try db.execute(sql: "INSERT INTO space (id, profileId, name, createdAt, updatedAt) VALUES (?, ?, 'Default', ?, ?)",
                           arguments: [UUID().uuidString, id, t, t])
            try Schema.ensureBookmarkRoots(db, profileId: id, at: t)
            return try Self.live(db, id).profile
        }
    }

    public func renameProfile(id: String, name: String) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            _ = try Self.live(db, id)
            let name = try Self.name(name, excluding: id, db)
            try db.execute(sql: "UPDATE profile SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, t, id])
        }
    }

    public func setProfileColor(id: String, colorIndex: Int) throws {
        try Self.checkColor(colorIndex)
        let t = now().timeIntervalSince1970
        try db.write { db in
            _ = try Self.live(db, id)
            try db.execute(sql: "UPDATE profile SET colorIndex = ?, updatedAt = ? WHERE id = ?", arguments: [colorIndex, t, id])
        }
    }

    /// Moves to |index| (clamped) and renumbers live positions 0..n-1.
    public func moveProfile(id: String, to index: Int) throws {
        try db.write { db in
            var ids = try Self.liveProfiles(db).map(\.id)
            guard let from = ids.firstIndex(of: id) else { throw ProfileError.notFound }
            ids.remove(at: from)
            ids.insert(id, at: max(0, min(index, ids.count)))
            try Self.renumber(db, ids)
        }
    }

    /// |target| nil clears. A profile cannot share with itself, and sharing is one level: a profile others share with cannot
    /// share, and one that shares cannot be a target.
    public func setShareWith(profileId: String, target: String?) throws {
        let t = now().timeIntervalSince1970
        try db.write { db in
            _ = try Self.live(db, profileId)
            if let target {
                if target == profileId { throw ProfileError.shareSelf }
                let tr = try Self.live(db, target)
                let sharedWith = try Self.liveProfiles(db).contains { $0.shareWithProfileId == profileId }
                if tr.shareWithProfileId != nil || sharedWith { throw ProfileError.shareChain }
            }
            try db.execute(sql: "UPDATE profile SET shareWithProfileId = ?, updatedAt = ? WHERE id = ?", arguments: [target, t, profileId])
        }
    }

    /// Tombstones the profile with its spaces, groups, windows and tabs. The tombstone keeps its directory name (the counter needs it).
    /// Profiles sharing with it keep their browsing data: the first sharer (by position) takes over the directory, the other
    /// sharers now share with it, and no data clear is requested. The sharer's previous directory may hold its pre-sharing data,
    /// so it is recorded in |retainedProfileDirs()| instead of being swept or forgotten. With no sharer, |clearChromiumData| is true
    /// when the profile owned `Default`. Closing the profile's own windows is the caller's job.
    @discardableResult
    public func deleteProfile(id: String) throws -> ProfileDeletion {
        let t = now().timeIntervalSince1970
        return try db.write { db in
            let row = try Self.live(db, id)
            let all = try Self.liveProfiles(db)
            if all.count == 1 { throw ProfileError.lastProfile }
            let mark = "deletedAt = ?, updatedAt = ? WHERE deletedAt IS NULL AND "
            try db.execute(sql: "UPDATE tab SET \(mark) windowId IN (SELECT id FROM window WHERE profileId = ?)", arguments: [t, t, id])
            try db.execute(sql: "UPDATE tabGroup SET \(mark) (spaceId IN (SELECT id FROM space WHERE profileId = ?) OR windowId IN (SELECT id FROM window WHERE profileId = ?))",
                           arguments: [t, t, id, id])
            try db.execute(sql: "UPDATE window SET \(mark) profileId = ?", arguments: [t, t, id])
            try db.execute(sql: "UPDATE space SET \(mark) profileId = ?", arguments: [t, t, id])
            let sharers = all.filter { $0.shareWithProfileId == id }
            if let f = sharers.first {
                try db.execute(sql: "UPDATE profile SET chromiumDirName = ?, isDefault = ?, shareWithProfileId = NULL, updatedAt = ? WHERE id = ?",
                               arguments: [row.chromiumDirName, row.chromiumDirName == "Default", t, f.id])
                try db.execute(sql: "UPDATE profile SET shareWithProfileId = ?, updatedAt = ? WHERE shareWithProfileId = ?", arguments: [f.id, t, id])
                try Self.retain(db, f.chromiumDirName, at: t)
            }
            try db.execute(sql: "UPDATE profile SET \(mark) id = ?", arguments: [t, t, id])
            try Self.renumber(db, all.map(\.id).filter { $0 != id })
            return ProfileDeletion(clearChromiumData: sharers.isEmpty && row.chromiumDirName == "Default")
        }
    }

    static let retainedDirsKey = "retainedProfileDirs"

    private static func retained(_ db: Database) throws -> [String] {
        let raw = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ? AND deletedAt IS NULL", arguments: [retainedDirsKey])
        // Missing means none; garbage must throw, or the next write would drop the list and numbers could be reused.
        guard let raw else { return [] }
        guard let dirs = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { throw ProfileError.corruptRetainedDirs }
        return dirs
    }

    private static func retain(_ db: Database, _ dir: String, at t: Double) throws {
        var dirs = try retained(db)
        if !dirs.contains(dir) { dirs.append(dir) }
        let json = String(decoding: try JSONEncoder().encode(dirs), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO setting (key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt, deletedAt = NULL
            """, arguments: [retainedDirsKey, json, t])
    }

    /// Directories a profile stopped using when it took over a deleted profile's directory; never swept, offered for cleanup later.
    public func retainedProfileDirs() throws -> [String] { try db.read { try Self.retained($0) } }

    /// Stored "New windows open with" profile, or the first live profile when none is stored or it is gone.
    public func newWindowProfileId() throws -> String? {
        let stored = try setting(Self.newWindowProfileKey)
        let live = try profiles()
        return live.first { $0.id == stored }?.id ?? live.first?.id
    }

    public func setNewWindowProfileId(_ id: String) throws {
        _ = try db.read { try Self.live($0, id) }
        try setSetting(Self.newWindowProfileKey, id)
    }

    /// Tombstoned `Profile <n>` directories safe to remove before CefInitialize: not the directory of a live profile or of the
    /// profile it shares with.
    public func sweepableProfileDirs() throws -> [String] {
        try db.read { db in
            let live = try Self.liveProfiles(db)
            let dirs = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.chromiumDirName) })
            let liveDirs = live.flatMap { [$0.chromiumDirName] + [$0.shareWithProfileId.flatMap { dirs[$0] }].compactMap { $0 } }
            let dead = try String.fetchAll(db, sql: "SELECT chromiumDirName FROM profile WHERE deletedAt IS NOT NULL ORDER BY position, createdAt")
            return ProfileRules.sweepCandidates(tombstonedDirs: dead, liveDirs: liveDirs + (try Self.retained(db)))
        }
    }
}
