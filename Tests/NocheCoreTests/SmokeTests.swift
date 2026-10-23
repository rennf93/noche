import XCTest
@testable import NocheCore

final class SmokeTests: XCTestCase {
    func testNoSmokeFlagMeansNil() {
        XCTAssertNil(SmokeOptions.parse(["Noche"]))
    }
    func testParsesURLAndDefaultTimeout() {
        let o = SmokeOptions.parse(["Noche", "--smoke-url", "http://127.0.0.1:8123/smoke.html"])
        XCTAssertEqual(o?.url.absoluteString, "http://127.0.0.1:8123/smoke.html")
        XCTAssertEqual(o?.timeout, 30)
    }
    func testParsesTimeout() {
        XCTAssertEqual(SmokeOptions.parse(["N", "--smoke-url", "http://a.b/", "--smoke-timeout", "5"])?.timeout, 5)
    }
    func testRejectsMissingOrBadValues() {
        XCTAssertNil(SmokeOptions.parse(["N", "--smoke-url"]))
        XCTAssertNil(SmokeOptions.parse(["N", "--smoke-url", "not a url"]))
        XCTAssertNil(SmokeOptions.parse(["N", "--smoke-url", "http://a.b/", "--smoke-timeout", "0"]))
    }
    func testLinesAndExitCodes() {
        XCTAssertEqual(SmokeEvent.loadEnd(status: 200, title: "Noche Smoke Fixture").line,
                       "NOCHE_SMOKE load_end status=200 title=Noche Smoke Fixture")
        XCTAssertEqual(SmokeEvent.loadEnd(status: 200, title: "x").exitCode, 0)
        XCTAssertEqual(SmokeEvent.loadError(code: -102).line, "NOCHE_SMOKE load_error code=-102")
        XCTAssertEqual(SmokeEvent.loadError(code: -102).exitCode, 2)
        XCTAssertEqual(SmokeEvent.timeout.line, "NOCHE_SMOKE timeout")
        XCTAssertEqual(SmokeEvent.timeout.exitCode, 1)
        XCTAssertEqual(SmokeEvent.alreadyRunning.line, "NOCHE already running")
        XCTAssertEqual(SmokeEvent.alreadyRunning.exitCode, 3)
    }
}
