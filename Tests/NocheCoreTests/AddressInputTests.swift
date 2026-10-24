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
    func testSchemeAllowlist() {
        let g = "https://www.google.com/search?q="
        XCTAssertEqual(r("javascript:alert(1)"), g + "javascript%3Aalert%281%29")
        XCTAssertEqual(r("javascript://%0aalert(1)"), g + "javascript%3A%2F%2F%250aalert%281%29")
        XCTAssertEqual(r("data:text/html,x"), g + "data%3Atext%2Fhtml%2Cx")
        XCTAssertEqual(r("ABOUT:blank"), "about:blank")
        XCTAssertEqual(r("HTTPS://Example.com"), "https://Example.com")
        XCTAssertEqual(r("view-source:https://a.b/c"), "view-source:https://a.b/c")
        XCTAssertEqual(r("chrome-extension://abc/x.html"), "chrome-extension://abc/x.html")
        XCTAssertEqual(r("ftp://a.b/c"), g + "ftp%3A%2F%2Fa.b%2Fc")
    }
    func testWhitespaceOnlyIsNil() { XCTAssertNil(r("   ")) }
    func testDisplayHost() {
        XCTAssertEqual(AddressInput.displayHost("https://www.example.com/a"), "example.com")
        XCTAssertEqual(AddressInput.displayHost("about:blank"), "about:blank")
    }
}
