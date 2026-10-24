import XCTest
@testable import NocheCore

final class AddressInputTests: XCTestCase {
    private func r(_ s: String) -> String? {
        AddressInput.resolve(s, searchTemplate: AddressInput.defaultSearchTemplate)?.absoluteString
    }

    func testBareHostGetsHTTPS() { XCTAssertEqual(r("example.com"), "https://example.com") }
    func testLocalAndIPGetHTTP() {
        XCTAssertEqual(r("localhost:8080/x"), "http://localhost:8080/x")
        XCTAssertEqual(r("127.0.0.1:3000"), "http://127.0.0.1:3000")
        XCTAssertEqual(r("[::1]:8080"), "http://[::1]:8080")
    }
    func testSchemesUnchanged() {
        for s in ["https://a.b/c?d", "file:///tmp/a.html", "chrome://extensions", "about:blank"] {
            XCTAssertEqual(r(s), s)
        }
    }
    func testSearch() {
        let g = "https://www.google.com/search?q="
        XCTAssertEqual(r("two words"), g + "two%20words")
        XCTAssertEqual(r("foo"), g + "foo")
        XCTAssertEqual(r("a.b c"), g + "a.b%20c")
        XCTAssertEqual(r("https://"), g + "https%3A%2F%2F")
    }
    func testWhitespaceOnlyIsNil() { XCTAssertNil(r("   ")) }
    func testDisplayHost() {
        XCTAssertEqual(AddressInput.displayHost("https://www.example.com/a"), "example.com")
        XCTAssertEqual(AddressInput.displayHost("about:blank"), "about:blank")
    }
}
