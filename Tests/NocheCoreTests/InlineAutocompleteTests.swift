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
    func testAccentedAndCjk() {
        let r = InlineAutocomplete.completion(typed: "CAF", topHit: hit("https://café.example/x"), justDeleted: false)
        XCTAssertEqual(r?.text, "CAFé.example/x")
        XCTAssertEqual(r?.selectedRange, NSRange(location: 3, length: 11))
        let c = InlineAutocomplete.completion(typed: "日本", topHit: hit("https://日本語.jp/ホーム"), justDeleted: false)
        XCTAssertEqual(c?.text, "日本語.jp/ホーム")
        XCTAssertEqual(c?.selectedRange, NSRange(location: 2, length: 8))
        XCTAssertNil(InlineAutocomplete.completion(typed: "İ", topHit: hit("https://x.com"), justDeleted: false))
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
