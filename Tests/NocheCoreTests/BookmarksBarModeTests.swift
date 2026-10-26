import XCTest
@testable import NocheCore

final class BookmarksBarModeTests: XCTestCase {
    func testVisibility() {
        XCTAssertTrue(BookmarksBarMode.always.visible(onNewTab: false))
        XCTAssertTrue(BookmarksBarMode.always.visible(onNewTab: true))
        XCTAssertFalse(BookmarksBarMode.newTabOnly.visible(onNewTab: false))
        XCTAssertTrue(BookmarksBarMode.newTabOnly.visible(onNewTab: true))
        XCTAssertFalse(BookmarksBarMode.never.visible(onNewTab: true))
    }

    func testToggleFlipsWhatIsShown() {
        XCTAssertEqual(BookmarksBarMode.newTabOnly.toggled(onNewTab: false), .always)
        XCTAssertEqual(BookmarksBarMode.newTabOnly.toggled(onNewTab: true), .never)
        XCTAssertEqual(BookmarksBarMode.always.toggled(onNewTab: false), .never)
        XCTAssertEqual(BookmarksBarMode.never.toggled(onNewTab: true), .always)
    }

    func testStoredValueAndDefault() {
        XCTAssertEqual(BookmarksBarMode(stored: nil), .newTabOnly)
        XCTAssertEqual(BookmarksBarMode(stored: "garbage"), .newTabOnly)
        for m in [BookmarksBarMode.always, .newTabOnly, .never] { XCTAssertEqual(BookmarksBarMode(stored: m.rawValue), m) }
    }
}
