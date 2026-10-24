import XCTest
@testable import NocheCore

final class InlineAutocompleteTests: XCTestCase {
    private func hit(_ url: String, kind: Suggestion.Kind = .page) -> Suggestion {
        Suggestion(kind: kind, title: "t", url: url, tabID: nil, frecency: 1)
    }

    func testCompletesPrefixKeepingTypedCase() {
        let r = InlineAutocomplete.completion(typed: "ExAm", topHit: hit("https://www.example.com/path"), justDeleted: false)
        XCTAssertEqual(r?.text, "ExAmple.com/path")
        XCTAssertEqual(r?.selectedRange, NSRange(location: 4, length: 12))
    }
    func testNoneAfterDelete() {
        XCTAssertNil(InlineAutocomplete.completion(typed: "exam", topHit: hit("https://example.com"), justDeleted: true))
    }
    func testNoneForTitleOnlyMatch() {
        XCTAssertNil(InlineAutocomplete.completion(typed: "gat", topHit: hit("https://x.com/a"), justDeleted: false))
    }
    func testNoneWithSpaceOrEmptyOrFullMatchOrNonPage() {
        XCTAssertNil(InlineAutocomplete.completion(typed: "exa mple", topHit: hit("https://example.com"), justDeleted: false))
        XCTAssertNil(InlineAutocomplete.completion(typed: "", topHit: hit("https://example.com"), justDeleted: false))
        XCTAssertNil(InlineAutocomplete.completion(typed: "example.com", topHit: hit("https://example.com/"), justDeleted: false))
        XCTAssertNil(InlineAutocomplete.completion(typed: "exam", topHit: hit("https://example.com", kind: .goTo), justDeleted: false))
        XCTAssertNil(InlineAutocomplete.completion(typed: "exam", topHit: nil, justDeleted: false))
    }
}
