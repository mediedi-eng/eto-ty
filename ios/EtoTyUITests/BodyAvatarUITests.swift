import UIKit
import XCTest

final class BodyAvatarUITests: XCTestCase {
    @MainActor
    func testRotateZoomResetAndSelectOrgans() throws {
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
        let firstPixels = try XCTUnwrap(sampleStage(avatar.screenshot().image))
        assertVisibleFigure(firstPixels)
        let front = XCTAttachment(screenshot: app.screenshot())
        front.name = "Founder-preview-avatar"
        front.lifetime = .keepAlways
        add(front)

        let left = avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.55))
        let right = avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.55))
        left.press(forDuration: 0.1, thenDragTo: right)
        XCTAssertNotEqual(avatar.value as? String, initial)
        let rotated = try XCTUnwrap(sampleStage(avatar.screenshot().image))
        let changed = stride(from: 0, to: firstPixels.count, by: 4).filter {
            abs(Int(firstPixels[$0]) - Int(rotated[$0])) > 24
        }.count
        XCTAssertGreaterThan(changed, 180, "Dragging must rotate the rendered geometry")
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

    // Sample the UIKit screenshot so a blank Metal layer or missing image fails CI.
    private func sampleStage(_ screenshot: UIImage) -> [UInt8]? {
        guard let image = screenshot.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 160 * 200 * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 160, height: 200,
                bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 200))
            return true
        }
        return drew ? pixels : nil
    }

    private func assertVisibleFigure(_ pixels: [UInt8]) {
        var top = 0, torso = 0, bottom = 0, heart = 0
        for y in 4..<195 {
            for x in 35..<125 {
                let i = (160 * y + x) * 4
                let red = Int(pixels[i]), green = Int(pixels[i + 1]), blue = Int(pixels[i + 2])
                if red > 56 && red > green + 9 && red > blue + 6 {
                    if y < 46 { top += 1 } else if y < 145 { torso += 1 } else { bottom += 1 }
                }
                if (36..<164).contains(y) && (54..<106).contains(x) &&
                    red > 155 && red > green + 42 && red > blue + 38 { heart += 1 }
            }
        }
        XCTAssertGreaterThan(top, 85, "Head and shoulders must be visible")
        XCTAssertGreaterThan(torso, 450, "Torso and limbs must be visible")
        XCTAssertGreaterThan(bottom, 85, "Lower legs and feet must be visible")
        XCTAssertGreaterThan(heart, 35, "The selected heart must be illuminated")
    }

    private func waitForValue(_ value: String, of element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
