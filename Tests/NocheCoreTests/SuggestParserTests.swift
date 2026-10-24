import XCTest
@testable import NocheCore

final class SuggestParserTests: XCTestCase {
    private func parse(_ s: String) -> [String] { SuggestParser.parse(Data(s.utf8)) }

    func testOpenSearch() {
        XCTAssertEqual(parse(#"["weather",["weather","weather tomorrow"],[],{"google:x":1}]"#), ["weather", "weather tomorrow"])
    }
    func testDuckDuckGo() {
        XCTAssertEqual(parse(#"[{"phrase":"weather"},{"phrase":"weather map"},{"other":1}]"#), ["weather", "weather map"])
    }
    func testGarbage() {
        XCTAssertEqual(parse("<html>502 Bad Gateway</html>"), [])
        XCTAssertEqual(parse(#"{"a":1}"#), [])
        XCTAssertEqual(parse("[]"), [])
        XCTAssertEqual(parse(#"["q",5]"#), [])
        XCTAssertEqual(SuggestParser.parse(Data()), [])
    }
    func testOversizedDroppedAndCappedAtFour() {
        let long = String(repeating: "a", count: 201)
        XCTAssertEqual(parse(#"["q",["\#(long)","1","2","3","4","5"]]"#), ["1", "2", "3", "4"])
    }
}
