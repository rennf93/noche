import XCTest
@testable import NocheCore

final class SettingKeysTests: XCTestCase {
    func testEmojiForNewGroupsKeyAndPick() {
        XCTAssertEqual(SettingKeys.key("emojiForNewGroups")?.defaultValue, "0")
        XCTAssertTrue(SettingKeys.isValid("emojiForNewGroups", "1") && !SettingKeys.isValid("emojiForNewGroups", "2"))
        XCTAssertEqual(GroupEmoji.pick(0), GroupEmoji.list[0])
        XCTAssertEqual(GroupEmoji.pick(GroupEmoji.list.count), GroupEmoji.list[0])
        XCTAssertEqual(GroupEmoji.pick(-5), GroupEmoji.list[0])
        XCTAssertEqual(Set(GroupEmoji.list).count, GroupEmoji.list.count)
    }
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
    func testDiscardAfterMinutesReadsOnlyValidStoredValues() {
        for (stored, want) in [(nil, 120), ("0", 120), ("-5", 120), ("1", 1), ("525600", 525600), ("525601", 120), ("abc", 120), ("", 120), ("90", 90)] as [(String?, Int)] {
            XCTAssertEqual(SettingKeys.discardAfterMinutes(stored: stored), want, "stored \(stored ?? "nil")")
        }
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
    func testTabBehaviorKeysAndReaders() {
        XCTAssertEqual(SettingKeys.key("addNewTabsToTop")?.defaultValue, "1")
        XCTAssertEqual(SettingKeys.key("warnBeforeClosingLastTab")?.defaultValue, "1")
        XCTAssertEqual(SettingKeys.key("autoGroupMeetings")?.defaultValue, "0")
        for (stored, want) in [(nil, true), ("0", false), ("1", true), ("2", true), ("", true)] as [(String?, Bool)] {
            XCTAssertEqual(SettingKeys.bool("addNewTabsToTop", stored: stored), want, "stored \(stored ?? "nil")")
        }
        XCTAssertFalse(SettingKeys.bool("autoGroupMeetings", stored: nil))
        XCTAssertTrue(SettingKeys.bool("autoGroupMeetings", stored: "1"))
        let args = ["Noche", "--selftest-setting", "addNewTabsToTop=0", "--selftest-setting", "warnBeforeClosingLastTab=0", "--selftest-setting", "autoGroupMeetings=1", "--selftest-setting", "addNewTabsToTop=2"]
        XCTAssertEqual(SettingKeys.flagSettings(args).map { "\($0.0)=\($0.1)" }, ["addNewTabsToTop=0", "warnBeforeClosingLastTab=0", "autoGroupMeetings=1"])
    }
    func testValueReadersTakeTheTableDefault() {
        for (stored, want) in [(nil, "preserve"), ("close", "close"), ("preserve", "preserve"), ("bogus", "preserve"), ("", "preserve"), ("0", "preserve"), ("1", "preserve")] as [(String?, String)] {
            XCTAssertEqual(SettingKeys.value("quitBehavior", stored: stored), want, "quitBehavior \(stored ?? "nil")")
        }
        for name in ["suggestRemote", "emojiForNewGroups"] {
            XCTAssertFalse(SettingKeys.bool(name, stored: nil), name)
            XCTAssertFalse(SettingKeys.bool(name, stored: "0"), name)
            XCTAssertFalse(SettingKeys.bool(name, stored: "x"), name)
            XCTAssertTrue(SettingKeys.bool(name, stored: "1"), name)
        }
        XCTAssertTrue(SettingKeys.bool("hapticReorder", stored: "junk"))
    }
    func testDownloadsRemovedAndNewWindowProfileAreInTheTable() {
        XCTAssertEqual(SettingKeys.key(SettingKeys.downloadsRemoved)?.defaultValue, "")
        XCTAssertEqual(SettingKeys.key(SettingKeys.newWindowProfile)?.defaultValue, "")
        XCTAssertEqual(SettingKeys.text(SettingKeys.downloadsRemoved, stored: nil), "")
        XCTAssertEqual(SettingKeys.text(SettingKeys.newWindowProfile, stored: "p1"), "p1")
    }
}
