import XCTest
@testable import NocheCore

final class CommandRouterTests: XCTestCase {
    private let template = AddressInput.defaultSearchTemplate
    private func route(_ typed: String, _ row: Suggestion? = nil) -> CommandRouter.Route {
        CommandRouter.route(row, typed: typed, searchTemplate: template)
    }
    private func isSearch(_ r: CommandRouter.Route) -> Bool {
        if case .navigate(let u) = r { return u.host == "www.google.com" }
        return false
    }

    func testDisallowedSchemesSearch() {
        for t in ["javascript:alert(1)", "data:text/html,x", "ftp://x"] { XCTAssertTrue(isSearch(route(t)), t) }
    }
    func testTypedUrlsNavigate() {
        for t in ["https://a.b", "localhost:3000", "about:blank", "chrome://extensions"] {
            guard case .navigate(let u) = route(t) else { return XCTFail(t) }
            XCTAssertFalse(isSearch(.navigate(u)), t)
        }
    }
    func testEmptyTypedIsNone() { XCTAssertEqual(route("  "), .none) }

    func testRows() {
        let page = Suggestion(kind: .page, title: "t", url: "https://a.com/x", tabID: nil, frecency: 1)
        XCTAssertEqual(route("a", page), .navigate(URL(string: "https://a.com/x")!))
        let bad = Suggestion(kind: .page, title: "t", url: "javascript:alert(1)", tabID: nil, frecency: 1)
        XCTAssertEqual(route("a", bad), .none)
        let ftp = Suggestion(kind: .site, title: "t", url: "ftp://a.com", tabID: nil, frecency: 0)
        XCTAssertEqual(route("a", ftp), .none)
        let id = TabID()
        let tab = Suggestion(kind: .tab, title: "t", url: "https://a.com", tabID: id, frecency: 0)
        XCTAssertEqual(route("a", tab), .switchTo(id))
        let badTab = Suggestion(kind: .tab, title: "t", url: "data:text/html,x", tabID: id, frecency: 0)
        XCTAssertEqual(route("a", badTab), .switchTo(id))
        let q = Suggestion(kind: .query, title: "hello", url: nil, tabID: nil, frecency: 0)
        XCTAssertTrue(isSearch(route("hello", q)))
        let go = Suggestion(kind: .goTo, title: "example.com", url: "https://example.com", tabID: nil, frecency: 0)
        XCTAssertEqual(route("example.com", go), .navigate(URL(string: "https://example.com")!))
    }
}
