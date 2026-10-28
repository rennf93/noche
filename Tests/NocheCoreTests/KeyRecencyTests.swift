import XCTest
@testable import NocheCore

final class KeyRecencyTests: XCTestCase {
    func testMostRecentKeyWindowWins() {
        var r = KeyRecency<String>()
        r.becameKey("a"); r.becameKey("b"); r.becameKey("a")
        XCTAssertEqual(r.mostRecent(among: ["a", "b", "c"]), "a")  // c is the newest window but was never key
        r.becameKey("c"); r.becameKey("b")
        XCTAssertEqual(r.mostRecent(among: ["a", "b", "c"]), "b")
    }

    func testClosedWindowFallsBackToThePreviousOne() {
        var r = KeyRecency<String>()
        r.becameKey("a"); r.becameKey("b"); r.becameKey("c")
        XCTAssertEqual(r.mostRecent(among: ["a", "b"]), "b")  // c is gone
        r.remove("b")
        XCTAssertEqual(r.mostRecent(among: ["a", "b"]), "a")
    }

    func testNoneWasKey() {
        var r = KeyRecency<String>()
        XCTAssertNil(r.mostRecent(among: ["a"]))
        r.becameKey("z")
        XCTAssertNil(r.mostRecent(among: ["a"]))
    }

    func testBecomingKeyTwiceKeepsOneEntry() {
        var r = KeyRecency<Int>()
        for _ in 0..<5 { r.becameKey(1); r.becameKey(2) }
        r.remove(2)
        XCTAssertEqual(r.mostRecent(among: [1, 2]), 1)
    }

    func testFrontToBackPutsKeyOrderFirstThenTheRestInGivenOrder() {
        var r = KeyRecency<String>()
        r.becameKey("b"); r.becameKey("c"); r.becameKey("a")
        XCTAssertEqual(r.frontToBack(among: ["a", "b", "c", "d", "e"]), ["a", "c", "b", "d", "e"])  // never-key windows follow, oldest first
        XCTAssertEqual(r.frontToBack(among: ["e", "b"]), ["b", "e"])
    }
}
