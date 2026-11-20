import UIKit
import XCTest

final class BodyAvatarUITests: XCTestCase {
    @MainActor
    func testRotateZoomResetAndSelectOrgans() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let map = app.tabBars.buttons["Карта тела"]
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        map.tap()

        let avatar = app.descendants(matching: .any)["map.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 8))
        let initial = "Сердце, поворот 0°, масштаб 100%"
        waitForValue(initial, of: avatar)
        let front = XCTAttachment(screenshot: app.screenshot())
        front.name = "Founder-preview-avatar"
        front.lifetime = .keepAlways
        add(front)

        let left = avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.55))
        let right = avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.55))
        left.press(forDuration: 0.1, thenDragTo: right)
        XCTAssertNotEqual(avatar.value as? String, initial)
        avatar.pinch(withScale: 1.6, velocity: 1.0)
        XCTAssertFalse((avatar.value as? String ?? "").hasSuffix("масштаб 100%"))
        app.buttons["map.reset"].tap()
        waitForValue(initial, of: avatar)

        // The front-facing liver projects just below the heart on the viewer's left.
        avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.37)).tap()
        let title = app.staticTexts["map.region.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Печень")
        XCTAssertTrue(title.isHittable)
        app.buttons["Почки"].tap()
        XCTAssertEqual(title.label, "Почки")
    }

    private func waitForValue(_ value: String, of element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
