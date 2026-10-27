import XCTest
@testable import NocheCore

final class SettingKeysTests: XCTestCase {
    func testEveryDefaultIsValidAndNamesAreUnique() {
        XCTAssertEqual(Set(SettingKeys.all.map(\.name)).count, SettingKeys.all.count)
        for k in SettingKeys.all { XCTAssertTrue(k.isValid(k.defaultValue), "\(k.name) default \(k.defaultValue)") }
    }
    func testTheKeysThatExistToday() {
        XCTAssertEqual(SettingKeys.key("quitBehavior")?.defaultValue, "preserve")
        XCTAssertEqual(SettingKeys.key("suggestRemote")?.defaultValue, "0")
        XCTAssertEqual(SettingKeys.key(BookmarksBarMode.settingKey)?.defaultValue, BookmarksBarMode.newTabOnly.rawValue)
        XCTAssertNil(SettingKeys.key("nope"))
    }
    func testValidation() {
        XCTAssertTrue(SettingKeys.isValid("quitBehavior", "close"))
        XCTAssertFalse(SettingKeys.isValid("quitBehavior", "Close"))
        XCTAssertTrue(SettingKeys.isValid("suggestRemote", "1"))
        XCTAssertFalse(SettingKeys.isValid("suggestRemote", "true"))
        XCTAssertFalse(SettingKeys.isValid("suggestRemote", ""))
        for m in BookmarksBarMode.allCases { XCTAssertTrue(SettingKeys.isValid(BookmarksBarMode.settingKey, m.rawValue)) }
        XCTAssertFalse(SettingKeys.isValid("unknown", "1"))
    }
    func testDiscardAfterMinutes() {
        let k = SettingKeys.key("discardAfterMinutes")
        XCTAssertEqual(k?.defaultValue, "120")
        XCTAssertTrue(SettingKeys.isValid("discardAfterMinutes", "1") && SettingKeys.isValid("discardAfterMinutes", "120"))
        XCTAssertFalse(SettingKeys.isValid("discardAfterMinutes", "0") || SettingKeys.isValid("discardAfterMinutes", "x"))
    }
    func testIntRangeType() {
        let k = SettingKey(name: "n", type: .int(1...5), defaultValue: "3")
        XCTAssertTrue(k.isValid("1") && k.isValid("5"))
        XCTAssertFalse(k.isValid("0") || k.isValid("6") || k.isValid("x") || k.isValid("2.5"))
    }
    func testRepeatedFlagsAllCountAndInvalidOnesAreDropped() {
        let args = ["Noche", "--selftest", "x", "--selftest-setting", "quitBehavior=close", "--selftest-setting", "suggestRemote=1",
                    "--selftest-setting", "bookmarksBar=always", "--selftest-setting", "suggestRemote=maybe", "--selftest-setting", "nokey=1",
                    "--selftest-setting", "novalue", "--selftest-setting"]
        let got = SettingKeys.flagSettings(args)
        XCTAssertEqual(got.map { "\($0.0)=\($0.1)" }, ["quitBehavior=close", "suggestRemote=1", "bookmarksBar=always"])
    }
    func testAValueMayContainEquals() {
        let k = SettingKey(name: "t", type: .text, defaultValue: "")
        XCTAssertTrue(k.isValid("a=b"))
    }
}
