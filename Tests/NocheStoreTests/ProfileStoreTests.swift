import XCTest
import GRDB
import NocheCore
@testable import NocheStore

final class ProfileStoreTests: XCTestCase {
    private let def = Schema.defaultProfileID

    func testV4UpgradeKeepsDataAndDensePositions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let pool = try DatabasePool(path: file.path)
        try Schema.migrator.migrate(pool, upTo: "v3")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value, updatedAt) VALUES ('k', 'v', 1)")
            try db.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt) VALUES ('b', 'B', 'Profile 1', 0, 20, 20)")
            try db.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt) VALUES (?, 'A', 'Default', 1, 10, 10)", arguments: [Schema.defaultProfileID])
            try db.execute(sql: "INSERT INTO profile (id, name, chromiumDirName, isDefault, createdAt, updatedAt, deletedAt) VALUES ('c', 'C', 'Profile 2', 0, 15, 15, 16)")
        }
        try pool.close()
        let s = try Store.open(at: file)
        XCTAssertEqual(try s.setting("k"), "v")
        try s.db.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"), ["v1", "v2", "v3", "v4", "v5-page-title-folded", "v6-sidebar-depth"])
        }
        let live = try s.profiles()
        XCTAssertEqual(live.map(\.id), [def, "b"])
        XCTAssertEqual(live.map(\.position), [0, 1])
        try s.db.read { XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT position FROM profile WHERE id = 'c'"), 0) }
        XCTAssertNil(live[0].shareWithProfileId)
    }

    func testFreshStoreHasOneDefaultProfile() throws {
        let s = try Store.inMemory()
        let p = try s.profiles()
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].id, def)
        XCTAssertEqual(p[0].chromiumDirName, "Default")
        XCTAssertEqual(p[0].position, 0)
    }

    func testCreateAssignsDirPositionSpaceAndRoots() throws {
        let s = try Store.inMemory()
        let p = try s.createProfile(name: " Work ", colorIndex: 2)
        XCTAssertEqual(p.name, "Work")
        XCTAssertEqual(p.colorIndex, 2)
        XCTAssertEqual(p.chromiumDirName, "Profile 1")
        XCTAssertEqual(p.position, 1)
        XCTAssertFalse(p.isDefault)
        try s.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM space WHERE profileId = ? AND deletedAt IS NULL", arguments: [p.id]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM bookmark WHERE profileId = ? AND parentId IS NULL", arguments: [p.id]), 2)
        }
        XCTAssertEqual(try s.profiles().map(\.name), ["Default", "Work"])
    }

    func testCreateValidatesAndNeverReusesDirNames() throws {
        let s = try Store.inMemory()
        XCTAssertThrowsError(try s.createProfile(name: "default", colorIndex: 0)) {
            XCTAssertEqual($0 as? ProfileError, .invalidName(.duplicate))
        }
        XCTAssertThrowsError(try s.createProfile(name: "", colorIndex: 0)) { XCTAssertEqual($0 as? ProfileError, .invalidName(.empty)) }
        XCTAssertThrowsError(try s.createProfile(name: "X", colorIndex: 8)) { XCTAssertEqual($0 as? ProfileError, .invalidColor) }
        let a = try s.createProfile(name: "A", colorIndex: 0)
        try s.deleteProfile(id: a.id)
        let b = try s.createProfile(name: "A", colorIndex: 0)
        XCTAssertEqual(a.chromiumDirName, "Profile 1")
        XCTAssertEqual(b.chromiumDirName, "Profile 2")
    }

    func testRenameAndColor() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        try s.renameProfile(id: a.id, name: "  Alpha ")
        try s.renameProfile(id: a.id, name: "ALPHA")  // same profile keeps its own name case-insensitively
        XCTAssertThrowsError(try s.renameProfile(id: a.id, name: "default")) { XCTAssertEqual($0 as? ProfileError, .invalidName(.duplicate)) }
        try s.setProfileColor(id: a.id, colorIndex: 5)
        let got = try XCTUnwrap(s.profiles().first { $0.id == a.id })
        XCTAssertEqual(got.name, "ALPHA")
        XCTAssertEqual(got.colorIndex, 5)
        XCTAssertThrowsError(try s.setProfileColor(id: a.id, colorIndex: -1)) { XCTAssertEqual($0 as? ProfileError, .invalidColor) }
        XCTAssertThrowsError(try s.renameProfile(id: "nope", name: "Z")) { XCTAssertEqual($0 as? ProfileError, .notFound) }
    }

    func testMoveKeepsDensePositions() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        let b = try s.createProfile(name: "B", colorIndex: 2)
        try s.moveProfile(id: b.id, to: 0)
        XCTAssertEqual(try s.profiles().map(\.id), [b.id, def, a.id])
        XCTAssertEqual(try s.profiles().map(\.position), [0, 1, 2])
        try s.moveProfile(id: b.id, to: 99)
        XCTAssertEqual(try s.profiles().map(\.id), [def, a.id, b.id])
    }

    func testShareWithRules() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        let b = try s.createProfile(name: "B", colorIndex: 2)
        let c = try s.createProfile(name: "C", colorIndex: 3)
        XCTAssertThrowsError(try s.setShareWith(profileId: a.id, target: a.id)) { XCTAssertEqual($0 as? ProfileError, .shareSelf) }
        try s.setShareWith(profileId: a.id, target: b.id)
        XCTAssertEqual(try s.profiles().first { $0.id == a.id }?.shareWithProfileId, b.id)
        // b is shared with, so b cannot share with another; and c cannot share with a (a already shares).
        XCTAssertThrowsError(try s.setShareWith(profileId: b.id, target: c.id)) { XCTAssertEqual($0 as? ProfileError, .shareChain) }
        XCTAssertThrowsError(try s.setShareWith(profileId: c.id, target: a.id)) { XCTAssertEqual($0 as? ProfileError, .shareChain) }
        XCTAssertThrowsError(try s.setShareWith(profileId: c.id, target: "nope")) { XCTAssertEqual($0 as? ProfileError, .notFound) }
        try s.setShareWith(profileId: a.id, target: nil)
        XCTAssertNil(try s.profiles().first { $0.id == a.id }?.shareWithProfileId)
        try s.setShareWith(profileId: b.id, target: c.id)
    }

    func testDeleteTombstonesEverythingAndGuards() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        let sharer = try s.createProfile(name: "S", colorIndex: 2)
        try s.setShareWith(profileId: sharer.id, target: a.id)
        try s.db.write { db in
            let sp = try String.fetchOne(db, sql: "SELECT id FROM space WHERE profileId = ?", arguments: [a.id])!
            try db.execute(sql: "INSERT INTO window (id, profileId, createdAt, updatedAt) VALUES ('w', ?, 1, 1)", arguments: [a.id])
            try db.execute(sql: "INSERT INTO tab (id, windowId, spaceId, url, position, lastActiveAt, createdAt, updatedAt) VALUES ('t', 'w', ?, 'u', 0, 1, 1, 1)", arguments: [sp])
        }
        try s.deleteProfile(id: a.id)
        XCTAssertEqual(try s.profiles().map(\.id), [def, sharer.id])
        XCTAssertEqual(try s.profiles().map(\.position), [0, 1])
        XCTAssertNil(try s.profiles().last?.shareWithProfileId)
        try s.db.read { db in
            for t in ["space WHERE profileId", "window WHERE profileId"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(t) = ? AND deletedAt IS NULL", arguments: [a.id]), 0, t)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE id = 't' AND deletedAt IS NULL"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT chromiumDirName FROM profile WHERE id = ? AND deletedAt IS NOT NULL", arguments: [a.id]), "Profile 1")
        }
        XCTAssertEqual(try s.deleteProfile(id: sharer.id), ProfileDeletion(clearChromiumData: false))
        XCTAssertThrowsError(try s.deleteProfile(id: "nope")) { XCTAssertEqual($0 as? ProfileError, .notFound) }
        XCTAssertThrowsError(try s.deleteProfile(id: def)) { XCTAssertEqual($0 as? ProfileError, .lastProfile) }
    }

    func testNewWindowProfileIdFallsBack() throws {
        let s = try Store.inMemory()
        XCTAssertEqual(try s.newWindowProfileId(), def)
        let a = try s.createProfile(name: "A", colorIndex: 1)
        try s.setNewWindowProfileId(a.id)
        XCTAssertEqual(try s.newWindowProfileId(), a.id)
        try s.deleteProfile(id: a.id)
        XCTAssertEqual(try s.newWindowProfileId(), def)
        XCTAssertThrowsError(try s.setNewWindowProfileId("nope")) { XCTAssertEqual($0 as? ProfileError, .notFound) }
    }

    func testSweepDirsFromStore() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        let b = try s.createProfile(name: "B", colorIndex: 2)
        try s.setShareWith(profileId: b.id, target: a.id)
        try s.deleteProfile(id: a.id)
        // b took over a's dir, so nothing is sweepable; b's old dir is retained.
        XCTAssertEqual(try s.sweepableProfileDirs(), [])
        let c = try s.createProfile(name: "C", colorIndex: 3)
        try s.deleteProfile(id: c.id)
        XCTAssertEqual(try s.sweepableProfileDirs(), ["Profile 3"])
    }

    func testDeletingDefaultOwnerClearsChromiumDataAndKeepsDefaultDir() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        try s.setNewWindowProfileId(def)
        XCTAssertEqual(try s.deleteProfile(id: def), ProfileDeletion(clearChromiumData: true))
        XCTAssertEqual(try s.profiles().map(\.id), [a.id])
        XCTAssertEqual(try s.newWindowProfileId(), a.id)
        XCTAssertEqual(try s.sweepableProfileDirs(), [])
        let b = try s.createProfile(name: "B", colorIndex: 2)
        XCTAssertEqual(b.chromiumDirName, "Profile 2")
        try s.deleteProfile(id: b.id)
        XCTAssertThrowsError(try s.deleteProfile(id: a.id)) { XCTAssertEqual($0 as? ProfileError, .lastProfile) }
        XCTAssertEqual(try s.sweepableProfileDirs(), ["Profile 2"])
    }

    func testSharerTakesOverDeletedProfileDir() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)  // Profile 1
        let f = try s.createProfile(name: "F", colorIndex: 2)  // Profile 2, first sharer
        let g = try s.createProfile(name: "G", colorIndex: 3)  // Profile 3
        try s.setShareWith(profileId: f.id, target: a.id)
        try s.setShareWith(profileId: g.id, target: a.id)
        XCTAssertEqual(try s.deleteProfile(id: a.id), ProfileDeletion(clearChromiumData: false))
        let live = try s.profiles()
        let nf = try XCTUnwrap(live.first { $0.id == f.id }), ng = try XCTUnwrap(live.first { $0.id == g.id })
        XCTAssertEqual(nf.chromiumDirName, "Profile 1")
        XCTAssertNil(nf.shareWithProfileId)
        XCTAssertEqual(ng.shareWithProfileId, f.id)
        XCTAssertEqual(try s.retainedProfileDirs(), ["Profile 2"])
        XCTAssertEqual(try s.sweepableProfileDirs(), [])
        XCTAssertEqual(try s.createProfile(name: "H", colorIndex: 4).chromiumDirName, "Profile 4")
    }

    func testSharerTakingDefaultSkipsClearAndBecomesDefault() throws {
        let s = try Store.inMemory()
        let f = try s.createProfile(name: "F", colorIndex: 1)
        try s.setShareWith(profileId: f.id, target: def)
        XCTAssertEqual(try s.deleteProfile(id: def), ProfileDeletion(clearChromiumData: false))
        let nf = try XCTUnwrap(s.profiles().first)
        XCTAssertEqual(nf.chromiumDirName, "Default")
        XCTAssertTrue(nf.isDefault)
        XCTAssertEqual(try s.retainedProfileDirs(), ["Profile 1"])
        XCTAssertEqual(try s.sweepableProfileDirs(), [])
    }

    func testCorruptRetainedDirsBlockWritesAndKeepRawValue() throws {
        let s = try Store.inMemory()
        let a = try s.createProfile(name: "A", colorIndex: 1)
        let f = try s.createProfile(name: "F", colorIndex: 2)
        try s.setShareWith(profileId: f.id, target: a.id)
        try s.setSetting("retainedProfileDirs", "not json")
        func corrupt(_ body: () throws -> Void) { XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? ProfileError, .corruptRetainedDirs) } }
        corrupt { _ = try s.createProfile(name: "B", colorIndex: 3) }
        corrupt { try s.deleteProfile(id: a.id) }
        corrupt { _ = try s.retainedProfileDirs() }
        XCTAssertEqual(try s.setting("retainedProfileDirs"), "not json")
        XCTAssertEqual(try s.profiles().count, 3)  // the failed delete rolled back
    }
}
