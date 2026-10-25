import XCTest
@testable import NocheCore

final class MarkdownLinkTests: XCTestCase {
    func testPlain() { XCTAssertEqual(MarkdownLink.make(title: "B Page", url: "http://h/b.html"), "[B Page](http://h/b.html)") }

    func testTitleEscapesBackslashFirstThenBrackets() {
        XCTAssertEqual(MarkdownLink.make(title: "a\\b] c [d", url: "http://h/"), "[a\\\\b\\] c \\[d](http://h/)")
    }

    func testTitleWhitespaceCollapses() {
        XCTAssertEqual(MarkdownLink.make(title: "  one\n\ttwo \r\n three  ", url: "http://h/"), "[one two three](http://h/)")
    }

    func testUrlEncodesParensAndSpaces() {
        XCTAssertEqual(MarkdownLink.make(title: "t", url: "http://h/a b(c)d"), "[t](http://h/a%20b%28c%29d)")
    }

    func testEmptyTitleUsesAddress() {
        XCTAssertEqual(MarkdownLink.make(title: " \n ", url: "http://h/x"), "[http://h/x](http://h/x)")
    }
}
