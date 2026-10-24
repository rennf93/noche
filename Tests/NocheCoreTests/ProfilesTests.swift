import XCTest
@testable import NocheCore

final class ProfilesTests: XCTestCase {
    func testNameValidation() throws {
        XCTAssertEqual(try ProfileRules.validName("  Work  ", existing: ["Mine"]), "Work")
        XCTAssertThrowsError(try ProfileRules.validName("   ", existing: [])) { XCTAssertEqual($0 as? ProfileNameError, .empty) }
        XCTAssertThrowsError(try ProfileRules.validName(String(repeating: "a", count: 41), existing: [])) {
            XCTAssertEqual($0 as? ProfileNameError, .tooLong)
        }
        XCTAssertEqual(try ProfileRules.validName(String(repeating: "a", count: 40), existing: []).count, 40)
        XCTAssertThrowsError(try ProfileRules.validName(" mine", existing: ["Mine"])) { XCTAssertEqual($0 as? ProfileNameError, .duplicate) }
    }

    func testNextColor() {
        XCTAssertEqual(ProfileRules.nextColor(used: []), 0)
        XCTAssertEqual(ProfileRules.nextColor(used: [0, 1, 3]), 2)
        XCTAssertEqual(ProfileRules.nextColor(used: [0, 1, 2, 3, 4, 5, 6, 7]), 0)
        XCTAssertEqual(ProfileRules.nextColor(used: [0, 0, 1, 2, 3, 4, 5, 6, 7, 7, 1]), 2)
        XCTAssertEqual(ProfileRules.nextColor(used: [0, 1, 2, 3, 4, 5, 6, 7, 3, 3, 0, 0]), 1)
    }

    func testNextDirName() {
        XCTAssertEqual(ProfileRules.nextDirName(existing: []), "Default")
        XCTAssertEqual(ProfileRules.nextDirName(existing: ["Default"]), "Profile 1")
        XCTAssertEqual(ProfileRules.nextDirName(existing: ["Default", "Profile 1", "Profile 3"]), "Profile 4")
        XCTAssertEqual(ProfileRules.nextDirName(existing: ["Default", "Profile 12", "Profile x", "Other"]), "Profile 13")
    }

    func testSwitchOrder() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(ProfileRules.switched(from: "a", in: order, forward: true), "b")
        XCTAssertEqual(ProfileRules.switched(from: "c", in: order, forward: true), "a")
        XCTAssertEqual(ProfileRules.switched(from: "a", in: order, forward: false), "c")
        XCTAssertEqual(ProfileRules.switched(from: "b", in: order, forward: false), "a")
        XCTAssertEqual(ProfileRules.switched(from: "zz", in: order, forward: true), "a")
        XCTAssertNil(ProfileRules.switched(from: "a", in: [], forward: true))
    }

    func testDeleteClosesOnlyOwnWindows() {
        let windows = [("w1", "p1"), ("w2", "p2"), ("w3", "p3"), ("w4", "p1")]
        XCTAssertEqual(ProfileRules.windowsClosed(deleting: "p1", windows: windows), ["w1", "w4"])
        XCTAssertEqual(ProfileRules.windowsClosed(deleting: "p3", windows: windows), ["w3"])
    }

    func testSweepCandidates() {
        let r = ProfileRules.sweepCandidates(tombstonedDirs: ["Default", "Profile 2", "Profile 3", "Profile 3", "Profile x", "Local State", "Profile 4"],
                                             liveDirs: ["Profile 4"])
        XCTAssertEqual(r, ["Profile 2", "Profile 3"])
    }

    func testPaletteOrderAndComponents() {
        XCTAssertEqual(ProfilePalette.names, ["white", "green", "blue", "purple", "amber", "pink", "red", "orange"])
        XCTAssertEqual(ProfilePalette.colors.count, 8)
        for c in ProfilePalette.colors { for v in [c.r, c.g, c.b] { XCTAssertTrue((0...1).contains(v)) } }
        XCTAssertEqual(ProfilePalette.colors[0].r, 252.0 / 255, accuracy: 1e-9)
    }
}
