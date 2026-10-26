import XCTest
@testable import NocheCore

final class PermissionTextTests: XCTestCase {
    private func text(camera: Bool = false, microphone: Bool = false, geolocation: Bool = false, notifications: Bool = false, screen: Bool = false) -> String {
        PermissionRequestText.text(camera: camera, microphone: microphone, geolocation: geolocation, notifications: notifications, screen: screen)
    }

    func testNamedKinds() {
        XCTAssertEqual(text(geolocation: true), "wants to use your location")
        XCTAssertEqual(text(camera: true, microphone: true), "wants to use your camera and microphone")
        XCTAssertEqual(text(notifications: true), "wants to show notifications")
    }

    func testScreenCaptureIsNamed() {
        XCTAssertEqual(text(screen: true), "wants to share your screen")
        XCTAssertEqual(text(microphone: true, screen: true), "wants to share your screen and use your microphone")
    }

    func testNothingNamed() {
        XCTAssertEqual(text(), "wants to use a browser feature")
    }
}
